//! Sarcasm conformance harness — scores the official WebAssembly spec
//! testsuite (the `.wast` corpus) against Cynic's WebAssembly engine.
//!
//! The `.wast` text format is preprocessed by `wast2json` (wabt) into a
//! JSON manifest plus `.wasm` binaries (see tools/wasm-testsuite-gen.sh);
//! Sarcasm itself only decodes binary modules. This harness walks the
//! generated directory, replays each command — `module`, `register`,
//! `assert_return`, `assert_trap`, `assert_invalid`, `assert_malformed`,
//! `assert_exhaustion`, `assert_uninstantiable`, `action` — including
//! cross-module linking (a registry of named/registered instances with
//! shared tables, memories, and host `spectest` objects) and tallies
//! plain pass/fail, the same shape as the test262 harness. The residual
//! skips (`assert_unlinkable`, text/quoted modules, a few unmodelled
//! value forms) are reported separately.
//!
//! Usage:
//!   zig build wasm-testsuite -- [--gen-dir=<dir>] [--filter=<s>]
//!                               [--quiet] [--write-results]

const std = @import("std");
const cynic = @import("cynic");
const wasm = cynic.wasm;

/// Mirrors the interpreter's null-reference sentinel.
const REF_NULL: u128 = std.math.maxInt(u128);

const Counts = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.pass += other.pass;
        self.fail += other.fail;
        self.skip += other.skip;
    }
};

const Options = struct {
    gen_dir: []const u8 = ".zig-cache/wasm-testsuite",
    filter: ?[]const u8 = null,
    quiet: bool = false,
    write_results: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var opts: Options = .{};
    {
        var iter = init.minimal.args.iterate();
        _ = iter.next(); // skip the binary path
        while (iter.next()) |a| {
            if (std.mem.startsWith(u8, a, "--gen-dir=")) {
                opts.gen_dir = try gpa.dupe(u8, a["--gen-dir=".len..]);
            } else if (std.mem.startsWith(u8, a, "--filter=")) {
                opts.filter = try gpa.dupe(u8, a["--filter=".len..]);
            } else if (std.mem.eql(u8, a, "--quiet")) {
                opts.quiet = true;
            } else if (std.mem.eql(u8, a, "--write-results")) {
                opts.write_results = true;
            } else if (std.mem.eql(u8, a, "--debug-loads")) {
                debug_loads = true;
            }
        }
    }

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, opts.gen_dir, .{ .iterate = true }) catch |err| {
        var line: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line, "wasm-testsuite: cannot open '{s}': {t} (run tools/wasm-testsuite-gen.sh)\n", .{ opts.gen_dir, err });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer dir.close(io);

    var total: Counts = .{};
    var files: u32 = 0;

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".json")) continue;
        if (opts.filter) |needle| {
            if (std.mem.indexOf(u8, entry.path, needle) == null) continue;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const c = runManifest(arena.allocator(), io, dir, entry.path) catch |err| {
            if (!opts.quiet) {
                var line: [512]u8 = undefined;
                const msg = try std.fmt.bufPrint(&line, "  {s}: harness error {t}\n", .{ entry.path, err });
                try std.Io.File.stderr().writeStreamingAll(io, msg);
            }
            continue;
        };
        total.add(c);
        files += 1;
        if (!opts.quiet) {
            var line: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line, "  {s}: {d} pass, {d} fail, {d} skip\n", .{ entry.path, c.pass, c.fail, c.skip });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
        }
    }

    const scored = total.pass + total.fail;
    const pct: f64 = if (scored == 0) 0 else @as(f64, @floatFromInt(total.pass)) * 100.0 / @as(f64, @floatFromInt(scored));
    var line: [512]u8 = undefined;
    const summary = try std.fmt.bufPrint(&line, "\nwasm spec testsuite: {d}/{d} pass ({d:.2}%), {d} skip across {d} files\n", .{ total.pass, scored, pct, total.skip, files });
    try std.Io.File.stdout().writeStreamingAll(io, summary);

    if (opts.write_results) try writeResults(gpa, io, total, files);
}

// ── per-manifest execution ──────────────────────────────────────────

fn runManifest(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, json_path: []const u8) !Counts {
    const bytes = try dir.readFileAlloc(io, json_path, arena, .limited(64 * 1024 * 1024));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const commands = (root.object.get("commands") orelse return error.BadManifest).array.items;

    var counts: Counts = .{};
    var current: ?*wasm.Instance = null;

    // Cross-module linking registry: registered name → instance. Names
    // a `register` command exposes for a later module's imports.
    var registry: Registry = .{};
    {
        const m = try arena.create(wasm.Memory);
        m.* = .{ .data = try arena.alloc(u8, 64 * 1024), .max_pages = 2 };
        @memset(m.data, 0);
        registry.spectest_mem = m;
        const t = try arena.create(wasm.Table);
        t.* = .{ .elems = try arena.alloc(u128, 10), .max = 20 };
        @memset(t.elems, REF_NULL);
        registry.spectest_tab = t;
    }

    for (commands) |cmd_v| {
        const cmd = cmd_v.object;
        const kind = (cmd.get("type") orelse continue).string;

        if (std.mem.eql(u8, kind, "module")) {
            const res = loadModule(arena, io, dir, cmd, &registry) catch null;
            if (res) |loaded| {
                current = loaded.instance;
                // A named module ((module $M …)) is addressable by later
                // actions and registers via its internal name.
                if (cmd.get("name")) |n| registry.put(arena, n.string, loaded.instance) catch {};
            } else {
                current = null;
            }
        } else if (std.mem.eql(u8, kind, "register")) {
            // Expose an instance under its registration name so later
            // modules can import its exports. A `name` field selects a
            // specific named module; otherwise the current one is used.
            const as = if (cmd.get("as")) |a| a.string else "";
            const inst = if (cmd.get("name")) |n| (registry.get(n.string) orelse current) else current;
            if (inst) |i| {
                registry.put(arena, as, i) catch {};
            }
            // A register is not a scored assertion.
        } else if (std.mem.eql(u8, kind, "assert_return")) {
            const before = counts.fail;
            scoreReturn(arena, cmd, current, &registry, &counts);
            if (debug_loads and counts.fail > before) {
                const action = cmd.get("action").?.object;
                var line: [256]u8 = undefined;
                const fld = if (action.get("field")) |f| f.string else "?";
                const msg = std.fmt.bufPrint(&line, "    FAIL line {d}: {s}\n", .{ if (cmd.get("line")) |l| l.integer else 0, fld }) catch continue;
                std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            }
        } else if (std.mem.eql(u8, kind, "assert_trap") or std.mem.eql(u8, kind, "assert_exhaustion")) {
            scoreTrap(arena, cmd, current, &registry, &counts, std.mem.eql(u8, kind, "assert_exhaustion"));
        } else if (std.mem.eql(u8, kind, "assert_invalid") or std.mem.eql(u8, kind, "assert_malformed")) {
            scoreRejected(arena, io, dir, cmd, &counts);
        } else if (std.mem.eql(u8, kind, "action")) {
            const r = doAction(arena, cmd.get("action").?.object, current, &registry);
            switch (r) {
                .values => counts.pass += 1,
                else => counts.fail += 1,
            }
        } else if (std.mem.eql(u8, kind, "assert_uninstantiable")) {
            // Instantiate the module and expect a trap. Side effects that
            // ran before the trap (e.g. an active element segment writing
            // into a shared imported table) persist by design.
            const res = loadModule(arena, io, dir, cmd, &registry) catch null;
            if (res == null) counts.pass += 1 else counts.fail += 1;
        } else {
            // register / assert_unlinkable — not yet scored.
            counts.skip += 1;
        }
    }
    return counts;
}

const Loaded = struct { instance: *wasm.Instance, module: *wasm.Module };

var debug_loads = false;

/// Cross-module linking registry. A `register "name"` command binds the
/// current instance to a name; a later module importing `(name, field)`
/// resolves against it. Latest binding wins.
const Registry = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The `spectest` host module's memory (1 page, max 2) and table
    /// (10 funcref slots, max 20). Created once per manifest.
    spectest_mem: ?*wasm.Memory = null,
    spectest_tab: ?*wasm.Table = null,

    const Entry = struct { name: []const u8, inst: *wasm.Instance };

    fn put(self: *Registry, a: std.mem.Allocator, name: []const u8, inst: *wasm.Instance) !void {
        try self.entries.append(a, .{ .name = name, .inst = inst });
    }

    fn get(self: *const Registry, name: []const u8) ?*wasm.Instance {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.entries.items[i].name, name)) return self.entries.items[i].inst;
        }
        return null;
    }
};

/// The `spectest` host module's functions are all `print*` — they take
/// arguments and return nothing. Modelled as a no-op.
fn spectestNoop(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
    _ = ctx;
    _ = args;
    @memset(results, 0);
}

/// The `spectest` host module's immutable globals, per the testsuite's
/// conventional definitions (global_i32 = 666, global_i64 = 666,
/// global_f32 = 666.6, global_f64 = 666.6).
fn spectestGlobal(name: []const u8) ?u128 {
    if (std.mem.eql(u8, name, "global_i32")) return 666;
    if (std.mem.eql(u8, name, "global_i64")) return 666;
    if (std.mem.eql(u8, name, "global_f32")) return @as(u32, @bitCast(@as(f32, 666.6)));
    if (std.mem.eql(u8, name, "global_f64")) return @as(u64, @bitCast(@as(f64, 666.6)));
    return null;
}

/// Resolve a module's imports for cross-module linking. Functions and
/// globals link to `spectest` host definitions or a registered
/// instance's exports; memory and table imports link to the `spectest`
/// host objects or a registered export (snapshotted by the importer).
fn resolveImports(arena: std.mem.Allocator, modp: *wasm.Module, registry: *const Registry) !wasm.Imports {
    var nfunc: usize = 0;
    var nglob: usize = 0;
    var ntab: usize = 0;
    for (modp.imports) |imp| {
        switch (imp.desc) {
            .func => nfunc += 1,
            .global => nglob += 1,
            .table => ntab += 1,
            .mem => {},
        }
    }
    if (modp.imports.len == 0) return .{};

    const funcs = try arena.alloc(wasm.FuncRef, nfunc);
    const globals = try arena.alloc(u128, nglob);
    const tables = try arena.alloc(*wasm.Table, ntab);
    var memory: ?*const wasm.Memory = null;
    var fi: usize = 0;
    var gi: usize = 0;
    var tj: usize = 0;
    for (modp.imports) |imp| {
        switch (imp.desc) {
            .func => |type_idx| {
                if (std.mem.eql(u8, imp.module, "spectest")) {
                    const ft = modp.types[type_idx];
                    funcs[fi] = .{ .host = .{
                        .fn_ptr = spectestNoop,
                        .params = @intCast(ft.params.len),
                        .results = @intCast(ft.results.len),
                    } };
                } else {
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    funcs[fi] = provider.exportedFuncRef(imp.name) orelse return error.Unlinkable;
                }
                fi += 1;
            },
            .global => {
                if (std.mem.eql(u8, imp.module, "spectest")) {
                    globals[gi] = spectestGlobal(imp.name) orelse return error.Unlinkable;
                } else {
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    globals[gi] = provider.exportedGlobalValue(imp.name) orelse return error.Unlinkable;
                }
                gi += 1;
            },
            .table => {
                if (std.mem.eql(u8, imp.module, "spectest")) {
                    tables[tj] = registry.spectest_tab orelse return error.Unlinkable;
                } else {
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    tables[tj] = provider.exportedTable(imp.name) orelse return error.Unlinkable;
                }
                tj += 1;
            },
            .mem => {
                if (std.mem.eql(u8, imp.module, "spectest")) {
                    memory = registry.spectest_mem orelse return error.Unlinkable;
                } else {
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    memory = provider.exportedMemory(imp.name) orelse return error.Unlinkable;
                }
            },
        }
    }
    return .{ .funcs = funcs, .globals = globals, .tables = tables, .memory = memory };
}

fn loadModule(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cmd: std.json.ObjectMap, registry: *const Registry) !?Loaded {
    const filename = (cmd.get("filename") orelse return null).string;
    const bytes = dir.readFileAlloc(io, filename, arena, .limited(64 * 1024 * 1024)) catch return null;
    const modp = try arena.create(wasm.Module);
    modp.* = wasm.decode(arena, bytes) catch |err| {
        if (debug_loads) logLoadError(io, filename, "decode", err);
        return null;
    };
    const imports = resolveImports(arena, modp, registry) catch |err| {
        if (debug_loads) logLoadError(io, filename, "link", err);
        return null;
    };
    // The instance must outlive this call at a stable address: imports
    // reference it by pointer, and its funcrefs/functions resolve to it.
    const ip = try arena.create(wasm.Instance);
    wasm.instantiate(ip, arena, arena, modp, imports) catch |err| {
        if (debug_loads) logLoadError(io, filename, "instantiate", err);
        return null;
    };
    // §5.5.11 — the start function runs as part of instantiation; a trap
    // here means the module failed to instantiate.
    wasm.runStart(ip, arena) catch |err| {
        if (debug_loads) logLoadError(io, filename, "start", err);
        return null;
    };
    return .{ .instance = ip, .module = modp };
}

fn logLoadError(io: std.Io, filename: []const u8, phase: []const u8, err: anyerror) void {
    var line: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&line, "    LOAD-FAIL {s} ({s}): {t}\n", .{ filename, phase, err }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ── actions ─────────────────────────────────────────────────────────

const ActionResult = union(enum) {
    values: []const u128,
    err: anyerror,
    no_module,
    unsupported,
};

fn doAction(arena: std.mem.Allocator, action: std.json.ObjectMap, current: ?*wasm.Instance, registry: *const Registry) ActionResult {
    const atype = (action.get("type") orelse return .unsupported).string;
    const field = (action.get("field") orelse return .unsupported).string;
    // An action may target a named module (cross-module linking tests);
    // otherwise it targets the most recently instantiated one.
    const inst = blk: {
        if (action.get("module")) |mn| break :blk registry.get(mn.string) orelse current;
        break :blk current;
    } orelse return .no_module;
    const m = inst.module;

    if (std.mem.eql(u8, atype, "get")) {
        const gidx = exportIndex(m, field, .global) orelse return .no_module;
        const cell = inst.readGlobalByIndex(gidx) orelse return .unsupported;
        const out = arena.alloc(u128, 1) catch return .{ .err = error.OutOfMemory };
        out[0] = cell;
        return .{ .values = out };
    }

    if (!std.mem.eql(u8, atype, "invoke")) return .unsupported;
    const fidx = exportIndex(m, field, .func) orelse return .no_module;

    const args = encodeArgs(arena, action) catch return .unsupported;
    const result = wasm.invoke(inst, arena, fidx, args) catch |err| return .{ .err = err };
    return .{ .values = result };
}

fn scoreReturn(arena: std.mem.Allocator, cmd: std.json.ObjectMap, current: ?*wasm.Instance, registry: *const Registry, counts: *Counts) void {
    const r = doAction(arena, cmd.get("action").?.object, current, registry);
    const values = switch (r) {
        .values => |v| v,
        .unsupported => {
            counts.skip += 1;
            return;
        },
        else => {
            counts.fail += 1;
            return;
        },
    };
    const expected = (cmd.get("expected") orelse {
        counts.fail += 1;
        return;
    }).array.items;
    if (expected.len != values.len) {
        counts.fail += 1;
        return;
    }
    for (expected, values) |exp, got| {
        if (!matchValue(exp.object, got)) {
            counts.fail += 1;
            return;
        }
    }
    counts.pass += 1;
}

fn scoreTrap(arena: std.mem.Allocator, cmd: std.json.ObjectMap, current: ?*wasm.Instance, registry: *const Registry, counts: *Counts, exhaustion: bool) void {
    const r = doAction(arena, cmd.get("action").?.object, current, registry);
    switch (r) {
        .err => |err| {
            if (exhaustion) {
                if (err == error.CallStackExhausted or err == error.ValueStackOverflow) counts.pass += 1 else counts.fail += 1;
            } else {
                counts.pass += 1;
            }
        },
        .unsupported => counts.skip += 1,
        else => counts.fail += 1,
    }
}

fn scoreRejected(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cmd: std.json.ObjectMap, counts: *Counts) void {
    // Only binary modules carry a `.wasm` we can decode.
    const mt = cmd.get("module_type");
    if (mt == null or !std.mem.eql(u8, mt.?.string, "binary")) {
        counts.skip += 1;
        return;
    }
    const filename = (cmd.get("filename") orelse {
        counts.skip += 1;
        return;
    }).string;
    const bytes = dir.readFileAlloc(io, filename, arena, .limited(64 * 1024 * 1024)) catch {
        counts.fail += 1;
        return;
    };
    const decoded = wasm.decode(arena, bytes);
    if (decoded) |m| {
        const modp = arena.create(wasm.Module) catch {
            counts.fail += 1;
            return;
        };
        modp.* = m;
        // Decoded; expect validation (via instantiate) to reject it.
        const ip = arena.create(wasm.Instance) catch {
            counts.fail += 1;
            return;
        };
        if (wasm.instantiate(ip, arena, arena, modp, .{})) |_| {
            counts.fail += 1; // accepted a module the spec rejects
            if (debug_loads) {
                const txt = if (cmd.get("text")) |t| t.string else "?";
                var line: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&line, "    WRONGLY-ACCEPTED {s} L{d}: {s}\n", .{ filename, if (cmd.get("line")) |l| l.integer else 0, txt }) catch return;
                std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            }
        } else |_| {
            counts.pass += 1;
        }
    } else |_| {
        counts.pass += 1; // rejected at decode
    }
}

// ── value encoding / comparison ─────────────────────────────────────

fn encodeArgs(arena: std.mem.Allocator, action: std.json.ObjectMap) ![]const u128 {
    const args = (action.get("args") orelse return &.{}).array.items;
    const cells = try arena.alloc(u128, args.len);
    for (args, 0..) |arg, i| {
        cells[i] = encodeValue(arg.object) orelse return error.Unsupported;
    }
    return cells;
}

fn encodeValue(v: std.json.ObjectMap) ?u128 {
    const t = (v.get("type") orelse return null).string;
    if (std.mem.eql(u8, t, "v128")) return encodeV128(v);
    const val = v.get("value") orelse return null;
    if (val != .string) return null;
    const s = val.string;
    if (std.mem.eql(u8, t, "i32") or std.mem.eql(u8, t, "f32")) {
        if (nanBits(s, false)) |b| return b;
        return std.fmt.parseInt(u32, s, 10) catch return null;
    }
    if (std.mem.eql(u8, t, "i64") or std.mem.eql(u8, t, "f64")) {
        if (nanBits(s, true)) |b| return b;
        return std.fmt.parseInt(u64, s, 10) catch return null;
    }
    if (std.mem.eql(u8, t, "funcref") or std.mem.eql(u8, t, "externref")) {
        if (std.mem.eql(u8, s, "null")) return REF_NULL;
        return std.fmt.parseInt(u32, s, 10) catch return null;
    }
    return null;
}

fn matchValue(v: std.json.ObjectMap, got: u128) bool {
    const t = (v.get("type") orelse return false).string;
    if (std.mem.eql(u8, t, "v128")) return matchV128(v, got);
    const val = v.get("value") orelse return false;
    if (val != .string) return false;
    const s = val.string;
    if (std.mem.eql(u8, t, "i32")) {
        const want = std.fmt.parseInt(u32, s, 10) catch return false;
        return @as(u32, @truncate(got)) == want;
    }
    if (std.mem.eql(u8, t, "i64")) {
        const want = std.fmt.parseInt(u64, s, 10) catch return false;
        return @as(u64, @truncate(got)) == want;
    }
    if (std.mem.eql(u8, t, "f32")) {
        const lo: u32 = @truncate(got);
        if (isNanToken(s)) return std.math.isNan(@as(f32, @bitCast(lo)));
        const want = std.fmt.parseInt(u32, s, 10) catch return false;
        return lo == want; // exact bits (handles ±0, exact floats)
    }
    if (std.mem.eql(u8, t, "f64")) {
        const lo: u64 = @truncate(got);
        if (isNanToken(s)) return std.math.isNan(@as(f64, @bitCast(lo)));
        const want = std.fmt.parseInt(u64, s, 10) catch return false;
        return lo == want;
    }
    if (std.mem.eql(u8, t, "funcref") or std.mem.eql(u8, t, "externref")) {
        if (std.mem.eql(u8, s, "null")) return got == REF_NULL;
        const want = std.fmt.parseInt(u32, s, 10) catch return false;
        return @as(u32, @truncate(got)) == want;
    }
    return false;
}

// ── v128 lane packing ───────────────────────────────────────────────

fn laneBits(lane_type: []const u8) ?u7 {
    if (std.mem.eql(u8, lane_type, "i8")) return 8;
    if (std.mem.eql(u8, lane_type, "i16")) return 16;
    if (std.mem.eql(u8, lane_type, "i32") or std.mem.eql(u8, lane_type, "f32")) return 32;
    if (std.mem.eql(u8, lane_type, "i64") or std.mem.eql(u8, lane_type, "f64")) return 64;
    return null;
}

fn laneIsFloat(lane_type: []const u8) bool {
    return std.mem.eql(u8, lane_type, "f32") or std.mem.eql(u8, lane_type, "f64");
}

/// Parse one lane's value string into its unsigned bit pattern.
fn parseLane(lane_type: []const u8, s: []const u8) ?u128 {
    const is64 = std.mem.eql(u8, lane_type, "i64") or std.mem.eql(u8, lane_type, "f64");
    if (laneIsFloat(lane_type) and isNanToken(s)) {
        return if (is64) @as(u128, 0x7ff8000000000000) else @as(u128, 0x7fc00000);
    }
    if (is64) return std.fmt.parseInt(u64, s, 10) catch return null;
    return std.fmt.parseInt(u32, s, 10) catch return null;
}

fn encodeV128(v: std.json.ObjectMap) ?u128 {
    const lt = (v.get("lane_type") orelse return null).string;
    const lanes = (v.get("value") orelse return null).array.items;
    const bits = laneBits(lt) orelse return null;
    const mask: u128 = (@as(u128, 1) << bits) - 1;
    var result: u128 = 0;
    for (lanes, 0..) |lane, i| {
        if (lane != .string) return null;
        const lb = parseLane(lt, lane.string) orelse return null;
        result |= (lb & mask) << @intCast(@as(usize, i) * bits);
    }
    return result;
}

fn matchV128(v: std.json.ObjectMap, got: u128) bool {
    const lt = (v.get("lane_type") orelse return false).string;
    const lanes = (v.get("value") orelse return false).array.items;
    const bits = laneBits(lt) orelse return false;
    const mask: u128 = (@as(u128, 1) << bits) - 1;
    const is_float = laneIsFloat(lt);
    for (lanes, 0..) |lane, i| {
        if (lane != .string) return false;
        const got_lane = (got >> @intCast(@as(usize, i) * bits)) & mask;
        if (is_float and isNanToken(lane.string)) {
            const is_nan = if (bits == 64)
                std.math.isNan(@as(f64, @bitCast(@as(u64, @truncate(got_lane)))))
            else
                std.math.isNan(@as(f32, @bitCast(@as(u32, @truncate(got_lane)))));
            if (!is_nan) return false;
        } else {
            const want = parseLane(lt, lane.string) orelse return false;
            if (got_lane != (want & mask)) return false;
        }
    }
    return true;
}

fn isNanToken(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "nan");
}

/// Canonical NaN bit pattern for a NaN token in a scalar arg position.
fn nanBits(s: []const u8, is64: bool) ?u128 {
    if (!isNanToken(s)) return null;
    return if (is64) @as(u128, 0x7ff8000000000000) else @as(u128, 0x7fc00000);
}

// ── exports ─────────────────────────────────────────────────────────

fn exportIndex(m: *const wasm.Module, name: []const u8, comptime kind: enum { func, global }) ?u32 {
    for (m.exports) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        switch (kind) {
            .func => if (e.desc == .func) return e.desc.func,
            .global => if (e.desc == .global) return e.desc.global,
        }
    }
    return null;
}

// ── scoreboard ──────────────────────────────────────────────────────

fn writeResults(gpa: std.mem.Allocator, io: std.Io, total: Counts, files: u32) !void {
    const scored = total.pass + total.fail;
    const pct: f64 = if (scored == 0) 0 else @as(f64, @floatFromInt(total.pass)) * 100.0 / @as(f64, @floatFromInt(scored));
    const content = try std.fmt.allocPrint(gpa,
        \\# Sarcasm — WebAssembly spec testsuite results
        \\
        \\Scored by `zig build wasm-testsuite` against the official
        \\WebAssembly spec testsuite (the `.wast` corpus, preprocessed with
        \\`wast2json`). Each `assert_*` / `action` command is a plain pass or
        \\fail; commands that need cross-module linking or v128/ref values
        \\Sarcasm does not yet support are counted as skips.
        \\
        \\## Current scores
        \\
        \\| passing | failing | pass% | skipped | files |
        \\|---|---|---|---|---|
        \\| {d} | {d} | {d:.2} | {d} | {d} |
        \\
    , .{ total.pass, total.fail, pct, total.skip, files });
    defer gpa.free(content);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = "wasm-results.md", .data = content });
}
