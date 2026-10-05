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
//!                               [--quiet] [--write-results] [--spasm]
//!                               [--require-spasm-entry]

const std = @import("std");
const cynic = @import("cynic");
const wasm = cynic.wasm;

/// Mirrors the interpreter's null-reference sentinel.
const REF_NULL: u128 = std.math.maxInt(u128);

const Counts = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,
    spasm_runs: u64 = 0,
    spasm_compiles: u64 = 0,
    spasm_refusals: u64 = 0,
    spasm_refused_reference_signatures: u64 = 0,
    spasm_refused_vector_signatures: u64 = 0,
    spasm_refusal_stages: [wasm.spasm_refusal_stage_count]u64 = std.mem.zeroes([wasm.spasm_refusal_stage_count]u64),
    spasm_refused_opcodes: [256]u64 = std.mem.zeroes([256]u64),
    spasm_refused_opcode_overflow: u64 = 0,
    spasm_refused_misc_subopcodes: [wasm.spasm_refusal_misc_subopcode_count]u64 = std.mem.zeroes([wasm.spasm_refusal_misc_subopcode_count]u64),
    spasm_refused_misc_subopcode_other: u64 = 0,
    spasm_refused_simd_subopcodes: [wasm.spasm_refusal_simd_subopcode_count]u64 = @splat(0),
    spasm_refused_simd_subopcode_other: u64 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.pass += other.pass;
        self.fail += other.fail;
        self.skip += other.skip;
        self.spasm_runs += other.spasm_runs;
        self.spasm_compiles += other.spasm_compiles;
        self.spasm_refusals += other.spasm_refusals;
        self.spasm_refused_reference_signatures += other.spasm_refused_reference_signatures;
        self.spasm_refused_vector_signatures += other.spasm_refused_vector_signatures;
        for (&self.spasm_refusal_stages, other.spasm_refusal_stages) |*total, count| total.* += count;
        for (&self.spasm_refused_opcodes, other.spasm_refused_opcodes) |*total, count| total.* += count;
        self.spasm_refused_opcode_overflow += other.spasm_refused_opcode_overflow;
        for (&self.spasm_refused_misc_subopcodes, other.spasm_refused_misc_subopcodes) |*total, count| total.* += count;
        self.spasm_refused_misc_subopcode_other += other.spasm_refused_misc_subopcode_other;
        for (&self.spasm_refused_simd_subopcodes, other.spasm_refused_simd_subopcodes) |*total, count| total.* += count;
        self.spasm_refused_simd_subopcode_other += other.spasm_refused_simd_subopcode_other;
    }
};

const Options = struct {
    gen_dir: []const u8 = ".zig-cache/wasm-testsuite",
    filter: ?[]const u8 = null,
    quiet: bool = false,
    write_results: bool = false,
    /// Force the Spasm baseline JIT on for every instantiated module
    /// (docs/jit.md §6/§12 step 4 — the wasm analog of test262's
    /// `--jit`). A `--spasm` run must produce the same pass-set as the
    /// default interpreter run: that diff is the goes-live correctness
    /// gate (compilable functions run native, everything else degrades).
    spasm: bool = false,
    /// Fail unless a forced-Spasm run actually enters generated code. Semantic
    /// parity alone is insufficient because an all-interpreter fallback can
    /// produce the same pass set while leaving the native tier broken.
    require_spasm_entry: bool = false,
    /// Headline floor. Exit 2 if `pass%` falls below it (0 = no gate).
    /// Mirrors the test262 harness so CI can gate the Sarcasm engine.
    min_pass_pct: f64 = 0.0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var options_arena = std.heap.ArenaAllocator.init(gpa);
    defer options_arena.deinit();
    var opts: Options = .{};
    {
        var iter = init.minimal.args.iterate();
        _ = iter.next(); // skip the binary path
        while (iter.next()) |a| {
            if (std.mem.startsWith(u8, a, "--gen-dir=")) {
                opts.gen_dir = try options_arena.allocator().dupe(u8, a["--gen-dir=".len..]);
            } else if (std.mem.startsWith(u8, a, "--filter=")) {
                opts.filter = try options_arena.allocator().dupe(u8, a["--filter=".len..]);
            } else if (std.mem.eql(u8, a, "--quiet")) {
                opts.quiet = true;
            } else if (std.mem.eql(u8, a, "--write-results")) {
                opts.write_results = true;
            } else if (std.mem.eql(u8, a, "--spasm")) {
                opts.spasm = true;
            } else if (std.mem.eql(u8, a, "--require-spasm-entry")) {
                opts.require_spasm_entry = true;
            } else if (std.mem.startsWith(u8, a, "--min-pass-pct=")) {
                opts.min_pass_pct = std.fmt.parseFloat(f64, a["--min-pass-pct=".len..]) catch 0.0;
            } else if (std.mem.eql(u8, a, "--debug-loads")) {
                debug_loads = true;
            }
        }
    }

    if (opts.require_spasm_entry and !opts.spasm) {
        try std.Io.File.stderr().writeStreamingAll(io, "wasm-testsuite: --require-spasm-entry requires --spasm\n");
        std.process.exit(2);
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
    var harness_errors: u32 = 0;

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
        const c = runManifest(gpa, arena.allocator(), io, dir, entry.path, opts.spasm) catch |err| {
            // A broken fixture is not an engine rejection or an excluded
            // command. Keep it visible under --quiet and fail the whole run.
            harness_errors += 1;
            var line: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line, "  {s}: harness error {t}\n", .{ entry.path, err });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
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
    if (opts.spasm) {
        var spasm_line: [256]u8 = undefined;
        const spasm_summary = try std.fmt.bufPrint(
            &spasm_line,
            "Spasm engagement: {d} native entries, {d} compiled functions\n",
            .{ total.spasm_runs, total.spasm_compiles },
        );
        try std.Io.File.stdout().writeStreamingAll(io, spasm_summary);
        if (total.spasm_refusals != 0) try writeSpasmRefusalSummary(io, total);
    }

    if (harness_errors != 0) {
        const msg = try std.fmt.bufPrint(&line, "wasm spec testsuite: {d} harness error(s); results are incomplete\n", .{harness_errors});
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(2);
    }
    if (opts.write_results) try writeResults(gpa, io, total, files);

    // `--min-pass-pct` — gate the run on the headline pass% floor (the
    // same contract as the test262 harness). A regression that flips a
    // previously-passing command to failing drops `pct` below the floor
    // and exits 2 so CI fails; skipped commands (unimplemented proposals)
    // don't count against `pct`, so the floor stays meaningful.
    if (opts.filter == null and opts.min_pass_pct > 0.0 and pct < opts.min_pass_pct) {
        var fline: [256]u8 = undefined;
        const fmsg = try std.fmt.bufPrint(&fline, "wasm spec testsuite: pass% {d:.2} below --min-pass-pct floor {d:.2} (pass {d} / {d})\n", .{ pct, opts.min_pass_pct, total.pass, scored });
        try std.Io.File.stderr().writeStreamingAll(io, fmsg);
        std.process.exit(2);
    }
    if (opts.require_spasm_entry and total.spasm_runs == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, "wasm-testsuite: --require-spasm-entry failed -- no generated Spasm entry executed\n");
        std.process.exit(2);
    }
}

// ── per-manifest execution ──────────────────────────────────────────

fn runManifest(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, json_path: []const u8, spasm_enabled: bool) !Counts {
    const bytes = try dir.readFileAlloc(io, json_path, arena, .limited(64 * 1024 * 1024));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return error.BadManifest;
    const command_list = root.object.get("commands") orelse return error.BadManifest;
    if (command_list != .array) return error.BadManifest;
    const commands = command_list.array.items;

    var counts: Counts = .{};
    var current: ?*wasm.Instance = null;
    var spasm_instances: std.ArrayListUnmanaged(*wasm.Instance) = .empty;

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
        if (cmd_v != .object) return error.BadManifest;
        const cmd = cmd_v.object;
        const kind = try requiredString(cmd, "type");
        // Call stacks and returned cells live only through this assertion;
        // module state and imported aliases keep the manifest's lifetime.
        var action_arena = std.heap.ArenaAllocator.init(gpa);
        defer action_arena.deinit();
        const scratch = action_arena.allocator();

        if (std.mem.eql(u8, kind, "module")) {
            // WABT's TallyCommand(OnModuleCommand) also counts plain module
            // commands: decoding, linking, initialization and start must work
            // even when the script has no later assertion against the module.
            switch (try loadModule(arena, io, dir, cmd, &registry, spasm_enabled)) {
                .loaded => |loaded| {
                    current = loaded.instance;
                    counts.pass += 1;
                    if (spasm_enabled) try spasm_instances.append(arena, loaded.instance);
                    if (try optionalString(cmd, "name")) |name|
                        try registry.put(arena, name, loaded.instance);
                },
                .rejected => {
                    current = null;
                    counts.fail += 1;
                },
                .unsupported => {
                    current = null;
                    counts.skip += 1;
                },
            }
        } else if (std.mem.eql(u8, kind, "register")) {
            // Expose an instance under its registration name so later
            // modules can import its exports. A `name` field selects a
            // specific named module; otherwise the current one is used.
            const as = try requiredString(cmd, "as");
            const inst = if (try optionalString(cmd, "name")) |name| registry.get(name) else current;
            // A failed/skipped module has already recorded its outcome.
            // Do not discard it and the remaining manifest as an IO failure
            // merely because its following registration has no instance.
            if (inst) |i| try registry.put(arena, as, i);
            // A register is not a scored assertion.
        } else if (std.mem.eql(u8, kind, "assert_return")) {
            const before = counts.fail;
            scoreReturn(scratch, cmd, current, &registry, &counts);
            if (debug_loads and counts.fail > before) {
                const action = cmd.get("action").?.object;
                var line: [256]u8 = undefined;
                const fld = if (action.get("field")) |f| f.string else "?";
                const msg = std.fmt.bufPrint(&line, "    FAIL line {d}: {s}\n", .{ if (cmd.get("line")) |l| l.integer else 0, fld }) catch continue;
                std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            }
        } else if (std.mem.eql(u8, kind, "assert_trap") or std.mem.eql(u8, kind, "assert_exhaustion")) {
            scoreTrap(scratch, cmd, current, &registry, &counts, std.mem.eql(u8, kind, "assert_exhaustion"));
        } else if (std.mem.eql(u8, kind, "assert_invalid") or std.mem.eql(u8, kind, "assert_malformed")) {
            try scoreRejected(arena, io, dir, cmd, &counts);
        } else if (std.mem.eql(u8, kind, "action")) {
            const r = doAction(scratch, cmd.get("action").?.object, current, &registry);
            switch (r) {
                .values => counts.pass += 1,
                else => counts.fail += 1,
            }
        } else if (std.mem.eql(u8, kind, "assert_uninstantiable")) {
            // Instantiate the module and expect a trap. Side effects that
            // ran before the trap (e.g. an active element segment writing
            // into a shared imported table) persist by design.
            switch (try loadModule(arena, io, dir, cmd, &registry, spasm_enabled)) {
                .loaded => counts.fail += 1,
                .unsupported => counts.skip += 1,
                .rejected => |rejection| {
                    if ((rejection.phase == .initialize or rejection.phase == .start) and isWasmTrap(rejection.err))
                        counts.pass += 1
                    else
                        counts.fail += 1;
                },
            }
        } else {
            // assert_unlinkable and unsupported script commands are not scored.
            counts.skip += 1;
        }
    }
    for (spasm_instances.items) |instance| {
        counts.spasm_runs += instance.spasm_runs;
        counts.spasm_compiles += instance.spasm_compiles;
        counts.spasm_refusals += instance.spasm_refusals;
        counts.spasm_refused_reference_signatures += instance.spasm_refused_reference_signatures;
        counts.spasm_refused_vector_signatures += instance.spasm_refused_vector_signatures;
        for (&counts.spasm_refusal_stages, instance.spasm_refusal_stages) |*total, count| total.* += count;
        for (instance.spasm_refused_opcodes) |entry| {
            if (entry.count != 0) counts.spasm_refused_opcodes[entry.opcode] += entry.count;
        }
        counts.spasm_refused_opcode_overflow += instance.spasm_refused_opcode_overflow;
        for (&counts.spasm_refused_misc_subopcodes, instance.spasm_refused_misc_subopcodes) |*total, count| total.* += count;
        counts.spasm_refused_misc_subopcode_other += instance.spasm_refused_misc_subopcode_other;
        for (&counts.spasm_refused_simd_subopcodes, instance.spasm_refused_simd_subopcodes) |*total, count| total.* += count;
        counts.spasm_refused_simd_subopcode_other += instance.spasm_refused_simd_subopcode_other;
    }
    return counts;
}

fn writeSpasmRefusalSummary(io: std.Io, counts: Counts) !void {
    var line: [512]u8 = undefined;
    const stages = counts.spasm_refusal_stages;
    const summary = try std.fmt.bufPrint(
        &line,
        "Spasm refusals: {d} (limits {d}, signature {d}, bytecode {d}, opcode {d}, emission {d}, install {d})\n",
        .{ counts.spasm_refusals, stages[0], stages[1], stages[2], stages[3], stages[4], stages[5] },
    );
    try std.Io.File.stdout().writeStreamingAll(io, summary);

    if (stages[1] != 0) {
        const signatures = try std.fmt.bufPrint(
            &line,
            "  signature types: reference {d}, vector {d}, other {d} (first rejected type per function)\n",
            .{ counts.spasm_refused_reference_signatures, counts.spasm_refused_vector_signatures, stages[1] - counts.spasm_refused_reference_signatures - counts.spasm_refused_vector_signatures },
        );
        try std.Io.File.stdout().writeStreamingAll(io, signatures);
    }

    var selected = std.mem.zeroes([256]bool);
    var rank: usize = 0;
    while (rank < 5) : (rank += 1) {
        var best_opcode: ?u8 = null;
        var best_count: u64 = 0;
        for (counts.spasm_refused_opcodes, 0..) |count, opcode| {
            if (!selected[opcode] and count > best_count) {
                best_opcode = @intCast(opcode);
                best_count = count;
            }
        }
        const opcode = best_opcode orelse break;
        selected[opcode] = true;
        var top_line: [96]u8 = undefined;
        const top = try std.fmt.bufPrint(&top_line, "  refused opcode 0x{x:0>2}: {d}\n", .{ opcode, best_count });
        try std.Io.File.stdout().writeStreamingAll(io, top);
    }
    if (counts.spasm_refused_opcode_overflow != 0) {
        var overflow_line: [128]u8 = undefined;
        const overflow = try std.fmt.bufPrint(
            &overflow_line,
            "  compact per-instance opcode table overflow: {d}\n",
            .{counts.spasm_refused_opcode_overflow},
        );
        try std.Io.File.stdout().writeStreamingAll(io, overflow);
    }
    try writeSpasmSubopcodeSummary(io, 0xfc, counts.spasm_refused_misc_subopcodes, counts.spasm_refused_misc_subopcode_other);
    try writeSpasmSubopcodeSummary(io, 0xfd, counts.spasm_refused_simd_subopcodes, counts.spasm_refused_simd_subopcode_other);
}

fn writeSpasmSubopcodeSummary(io: std.Io, comptime prefix: u8, counts: anytype, other: u64) !void {
    var remaining = counts;
    var rank: usize = 0;
    while (rank < 5) : (rank += 1) {
        var best_subopcode: ?usize = null;
        var best_count: u64 = 0;
        for (remaining, 0..) |count, subopcode| {
            if (count > best_count) {
                best_subopcode = subopcode;
                best_count = count;
            }
        }
        const subopcode = best_subopcode orelse break;
        remaining[subopcode] = 0;
        var line: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &line,
            "  refused 0x{x} subopcode {d} ({s}): {d}\n",
            .{ prefix, subopcode, if (prefix == 0xfc) miscSubopcodeName(subopcode) else "SIMD", best_count },
        );
        try std.Io.File.stdout().writeStreamingAll(io, text);
    }
    if (other != 0) {
        var line: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &line,
            "  refused 0x{x} untracked subopcodes: {d}\n",
            .{ prefix, other },
        );
        try std.Io.File.stdout().writeStreamingAll(io, text);
    }
}

fn miscSubopcodeName(subopcode: usize) []const u8 {
    return switch (subopcode) {
        0 => "i32.trunc_sat_f32_s",
        1 => "i32.trunc_sat_f32_u",
        2 => "i32.trunc_sat_f64_s",
        3 => "i32.trunc_sat_f64_u",
        4 => "i64.trunc_sat_f32_s",
        5 => "i64.trunc_sat_f32_u",
        6 => "i64.trunc_sat_f64_s",
        7 => "i64.trunc_sat_f64_u",
        8 => "memory.init",
        9 => "data.drop",
        10 => "memory.copy",
        11 => "memory.fill",
        12 => "table.init",
        13 => "elem.drop",
        14 => "table.copy",
        15 => "table.grow",
        16 => "table.size",
        17 => "table.fill",
        else => "unknown",
    };
}

const Loaded = struct { instance: *wasm.Instance, module: *wasm.Module };
const LoadPhase = enum { decode, validate, link, initialize, start };
const LoadResult = union(enum) {
    loaded: Loaded,
    rejected: struct { phase: LoadPhase, err: anyerror },
    unsupported,
};

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.BadManifest;
    return value.string;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try optionalString(object, key)) orelse error.BadManifest;
}

fn binaryModule(cmd: std.json.ObjectMap) !bool {
    const form = (try optionalString(cmd, "module_type")) orelse return true;
    if (std.mem.eql(u8, form, "binary")) return true;
    if (std.mem.eql(u8, form, "text")) return false;
    return error.BadManifest;
}

fn rejectModule(io: std.Io, filename: []const u8, phase: LoadPhase, err: anyerror) !LoadResult {
    // Exhausting the harness's allocator says nothing about whether the
    // engine accepts the module. Never satisfy an expected rejection with it.
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (debug_loads) logLoadError(io, filename, @tagName(phase), err);
    return .{ .rejected = .{ .phase = phase, .err = err } };
}

fn isWasmTrap(err: anyerror) bool {
    return switch (err) {
        error.NullReference, error.Unreachable, error.IntegerDivideByZero, error.IntegerOverflow, error.InvalidConversionToInteger, error.OutOfBoundsMemoryAccess, error.OutOfBoundsTableAccess, error.UndefinedElement, error.UninitializedElement, error.IndirectCallTypeMismatch, error.UncaughtException, error.NullExnRef => true,
        // Exhaustion, host failures, unsupported calls and cancellation are
        // distinct from the traps/exceptions accepted by assert_uninstantiable.
        else => false,
    };
}

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
/// host objects or a registered export (aliased — §4.5.4 — so writes
/// are mutually visible).
fn resolveImports(arena: std.mem.Allocator, modp: *wasm.Module, registry: *const Registry) !wasm.Imports {
    var nfunc: usize = 0;
    var nglob: usize = 0;
    var ntab: usize = 0;
    var ntag: usize = 0;
    var nmem: usize = 0;
    for (modp.imports) |imp| {
        switch (imp.desc) {
            .func => nfunc += 1,
            .global => nglob += 1,
            .table => ntab += 1,
            .mem => nmem += 1,
            .tag => ntag += 1,
        }
    }
    if (modp.imports.len == 0) return .{};

    const funcs = try arena.alloc(wasm.FuncRef, nfunc);
    const globals = try arena.alloc(*wasm.Global, nglob);
    const tables = try arena.alloc(*wasm.Table, ntab);
    const tags = try arena.alloc(*const wasm.TagType, ntag);
    const memories = try arena.alloc(*wasm.Memory, nmem);
    var fi: usize = 0;
    var gi: usize = 0;
    var tj: usize = 0;
    var tk: usize = 0;
    var mj: usize = 0;
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
                    const v = spectestGlobal(imp.name) orelse return error.Unlinkable;
                    const g = try arena.create(wasm.Global);
                    g.* = .{ .value = v, .mutable = false };
                    globals[gi] = g;
                } else {
                    // Alias the provider's global (§4.5.4) — a mutable
                    // global's writes are visible through the importer.
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    globals[gi] = provider.exportedGlobal(imp.name) orelse return error.Unlinkable;
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
                    memories[mj] = registry.spectest_mem orelse return error.Unlinkable;
                } else {
                    const provider = registry.get(imp.module) orelse return error.Unlinkable;
                    memories[mj] = provider.exportedMemory(imp.name) orelse return error.Unlinkable;
                }
                mj += 1;
            },
            .tag => {
                const provider = registry.get(imp.module) orelse return error.Unlinkable;
                tags[tk] = provider.exportedTag(imp.name) orelse return error.Unlinkable;
                tk += 1;
            },
        }
    }
    // Memory imports alias the provider's `*Memory` (§4.5.4 — an
    // imported memory IS the provider's memory): a store through the
    // provider's exports is visible through the importer and vice
    // versa, which linking and the multi-memory split files assert.
    return .{ .funcs = funcs, .globals = globals, .tables = tables, .memories = memories, .share_memory = true, .tags = tags };
}

fn loadModule(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    cmd: std.json.ObjectMap,
    registry: *const Registry,
    spasm_enabled: bool,
) !LoadResult {
    if (!try binaryModule(cmd)) return .unsupported;
    const filename = try requiredString(cmd, "filename");
    const bytes = try dir.readFileAlloc(io, filename, arena, .limited(64 * 1024 * 1024));
    const modp = try arena.create(wasm.Module);
    modp.* = wasm.decode(arena, bytes) catch |err| return rejectModule(io, filename, .decode, err);
    // Validate before looking up type-indexed imports. This also separates a
    // validation rejection from an active-segment trap during instantiate.
    // The prepared instance owns its own code; discard this validation scratch.
    {
        var validation = std.heap.ArenaAllocator.init(arena);
        defer validation.deinit();
        _ = wasm.validateModule(validation.allocator(), modp) catch |err|
            return rejectModule(io, filename, .validate, err);
    }
    const imports = resolveImports(arena, modp, registry) catch |err| return rejectModule(io, filename, .link, err);
    const ip = try arena.create(wasm.Instance);
    wasm.instantiate(ip, arena, arena, modp, imports) catch |err| return rejectModule(io, filename, .initialize, err);
    if (spasm_enabled) {
        ip.spasm_enabled = true;
        ip.spasm_diagnostics = true;
    }
    wasm.runStart(ip, arena) catch |err| return rejectModule(io, filename, .start, err);
    return .{ .loaded = .{ .instance = ip, .module = modp } };
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
    // Relaxed-SIMD ops are non-deterministic: the spec permits a range of
    // valid results, which wast2json emits as an `either` list (no single
    // `expected`). Accept the engine's result if it matches any option —
    // Sarcasm computes one deterministic value that must be among them.
    if (cmd.get("either")) |ei| {
        for (ei.array.items) |opt| {
            if (values.len == 1 and matchValue(opt.object, values[0])) {
                counts.pass += 1;
                return;
            }
        }
        counts.fail += 1;
        return;
    }
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

fn scoreRejected(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cmd: std.json.ObjectMap, counts: *Counts) !void {
    if (!try binaryModule(cmd)) {
        counts.skip += 1;
        return;
    }
    const filename = try requiredString(cmd, "filename");
    const bytes = try dir.readFileAlloc(io, filename, arena, .limited(64 * 1024 * 1024));
    const module = wasm.decode(arena, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        counts.pass += 1;
        return;
    };
    // These assertions concern decoding/validation only. Instantiating with
    // missing imports or trapping active segments could falsely pass a valid
    // module, and could mutate imported state before a later command.
    _ = wasm.validateModule(arena, &module) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        counts.pass += 1;
        return;
    };
    counts.fail += 1;
    if (debug_loads) {
        const txt = (try optionalString(cmd, "text")) orelse "?";
        var line: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line, "    WRONGLY-ACCEPTED {s}: {s}\n", .{ filename, txt });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
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
        return matchFloat(u32, s, @truncate(got));
    }
    if (std.mem.eql(u8, t, "f64")) {
        return matchFloat(u64, s, @truncate(got));
    }
    if (std.mem.eql(u8, t, "funcref")) {
        // A function reference's index cannot round-trip through the
        // JSON (`(ref.func)` means "some non-null funcref"), so match
        // on nullness only.
        if (std.mem.eql(u8, s, "null")) return got == REF_NULL;
        return got != REF_NULL;
    }
    if (std.mem.eql(u8, t, "externref")) {
        if (std.mem.eql(u8, s, "null")) return got == REF_NULL;
        const want = std.fmt.parseInt(u32, s, 10) catch return false;
        return @as(u32, @truncate(got)) == want;
    }
    return false;
}

/// Core §2.2.3: canonical NaNs have only the top payload bit set;
/// arithmetic NaNs require that bit, but allow the remaining payload bits.
/// Compare bits without host FP operations that could quiet signaling NaNs.
fn matchFloat(comptime U: type, expected: []const u8, got: U) bool {
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const canonical: U = if (U == u32) 0x7fc0_0000 else 0x7ff8_0000_0000_0000;
    if (std.mem.eql(u8, expected, "nan:canonical")) return got & ~sign == canonical;
    if (std.mem.eql(u8, expected, "nan:arithmetic")) return got & canonical == canonical;
    // wast2json emits numeric bit patterns for exact expectations, even NaNs.
    const want = std.fmt.parseInt(U, expected, 10) catch return false;
    return got == want;
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
        if (is_float) {
            const matches = if (bits == 64)
                matchFloat(u64, lane.string, @truncate(got_lane))
            else
                matchFloat(u32, lane.string, @truncate(got_lane));
            if (!matches) return false;
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

fn expectJsonMatch(json: []const u8, got: u128, expected: bool) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(expected, matchValue(parsed.value.object, got));
}

fn expectScalarMatch(comptime U: type, value: []const u8, got: U, expected: bool) !void {
    var buffer: [128]u8 = undefined;
    const json = try std.fmt.bufPrint(&buffer, "{{\"type\":\"{s}\",\"value\":\"{s}\"}}", .{ if (U == u32) "f32" else "f64", value });
    try expectJsonMatch(json, got, expected);
}

fn testScalarNanMatch(comptime U: type, canonical: bool) !void {
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet_bit = if (U == u32) 22 else 51;
    const quiet: U = @as(U, 1) << quiet_bit;
    const token = if (canonical) "nan:canonical" else "nan:arithmetic";
    for ([_]U{ 0, sign }) |sign_bits| {
        try expectScalarMatch(U, token, sign_bits | exponent | quiet, true);
        for ([_]U{ 0, 1, exponent - 1, exponent }) |not_nan| {
            try expectScalarMatch(U, token, sign_bits | not_nan, false);
        }
        for (0..quiet_bit) |bit| {
            const payload = @as(U, 1) << @as(std.math.Log2Int(U), @intCast(bit));
            try expectScalarMatch(U, token, sign_bits | exponent | payload, false);
            try expectScalarMatch(U, token, sign_bits | exponent | quiet | payload, !canonical);
        }
        try expectScalarMatch(U, token, sign_bits | exponent | (quiet - 1), false);
        try expectScalarMatch(U, token, sign_bits | exponent | (quiet * 2 - 1), !canonical);
    }
}

// Small binaries keep accounting tests independent of wast2json and its feature flags.
const scoring_empty_module = "\x00asm\x01\x00\x00\x00";
const scoring_imported_start = scoring_empty_module ++
    "\x01\x04\x01\x60\x00\x00" ++
    "\x02\x12\x01\x08spectest\x05print\x00\x00" ++ "\x08\x01\x00";
const scoring_trapping_start = scoring_empty_module ++
    "\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x08\x01\x00" ++
    "\x0a\x05\x01\x03\x00\x00\x0b";
const scoring_invalid_module = scoring_empty_module ++
    "\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00" ++
    "\x0a\x04\x01\x02\x00\x0b";
const scoring_unlinked_module = scoring_empty_module ++
    "\x02\x0e\x01\x07missing\x01m\x02\x00\x01";
const scoring_oob_data = scoring_empty_module ++
    "\x05\x03\x01\x00\x00\x0b\x07\x01\x00\x41\x00\x0b\x01x";

fn expectManifestCounts(source: []const u8, module: ?[]const u8, expected: Counts) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "case.json", .data = source });
    if (module) |bytes| try tmp.dir.writeFile(io, .{ .sub_path = "case.wasm", .data = bytes });
    for ([_]bool{ false, true }) |spasm| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const actual = try runManifest(std.testing.allocator, arena.allocator(), io, tmp.dir, "case.json", spasm);
        try std.testing.expectEqual(expected.pass, actual.pass);
        try std.testing.expectEqual(expected.fail, actual.fail);
        try std.testing.expectEqual(expected.skip, actual.skip);
    }
}

test "wasm harness: standalone module commands are scored without later assertions" {
    const source =
        \\{"commands":[{"type":"module","filename":"case.wasm"}]}
    ;
    for ([_][]const u8{ scoring_empty_module, scoring_imported_start }) |bytes|
        try expectManifestCounts(source, bytes, .{ .pass = 1 });
    for ([_][]const u8{ "\x00asm", scoring_invalid_module, scoring_unlinked_module, scoring_trapping_start, scoring_oob_data }) |bytes|
        try expectManifestCounts(source, bytes, .{ .fail = 1 });
}

test "wasm harness: uninstantiable requires an initialization or start trap" {
    const source =
        \\{"commands":[{"type":"assert_uninstantiable","filename":"case.wasm","module_type":"binary"}]}
    ;
    for ([_][]const u8{ scoring_trapping_start, scoring_oob_data }) |bytes|
        try expectManifestCounts(source, bytes, .{ .pass = 1 });
    for ([_][]const u8{ scoring_empty_module, "\x00asm", scoring_invalid_module, scoring_unlinked_module }) |bytes|
        try expectManifestCounts(source, bytes, .{ .fail = 1 });
}

test "wasm harness: rejected assertions do not confuse linking or runtime traps with validation" {
    inline for (.{ "assert_invalid", "assert_malformed" }) |kind| {
        const source = "{\"commands\":[{\"type\":\"" ++ kind ++ "\",\"filename\":\"case.wasm\",\"module_type\":\"binary\"}]}";
        for ([_][]const u8{ scoring_empty_module, scoring_unlinked_module, scoring_trapping_start, scoring_oob_data }) |bytes|
            try expectManifestCounts(source, bytes, .{ .fail = 1 });
        for ([_][]const u8{ "\x00asm", scoring_invalid_module }) |bytes|
            try expectManifestCounts(source, bytes, .{ .pass = 1 });
    }
}

test "wasm harness: missing module files remain infrastructure errors for every load command" {
    inline for (.{ "module", "assert_uninstantiable", "assert_invalid", "assert_malformed" }) |kind| {
        const source = "{\"commands\":[{\"type\":\"" ++ kind ++ "\",\"filename\":\"case.wasm\",\"module_type\":\"binary\"}]}";
        try std.testing.expectError(error.FileNotFound, expectManifestCounts(source, null, .{}));
    }
}

test "wasm harness: unsupported module forms and unlinkable assertions stay explicit skips" {
    try expectManifestCounts(
        \\{"commands":[{"type":"module","filename":"case.wat","module_type":"text"},
        \\{"type":"assert_uninstantiable","filename":"case.wat","module_type":"text"},
        \\{"type":"assert_malformed","filename":"case.wat","module_type":"text"},
        \\{"type":"assert_unlinkable","filename":"case.wasm","module_type":"binary"}]}
    , null, .{ .skip = 4 });
}

test "wasm harness: register after a failed or skipped module preserves its outcome" {
    try expectManifestCounts(
        \\{"commands":[{"type":"module","filename":"case.wasm"},
        \\{"type":"register","as":"failed"},
        \\{"type":"assert_uninstantiable","filename":"case.wasm","module_type":"binary"}]}
    , scoring_trapping_start, .{ .pass = 1, .fail = 1 });
    try expectManifestCounts(
        \\{"commands":[{"type":"module","filename":"case.wat","module_type":"text"},
        \\{"type":"register","as":"skipped"},
        \\{"type":"module","filename":"case.wasm"}]}
    , scoring_empty_module, .{ .pass = 1, .skip = 1 });
}

fn checkManifestAllocationFailures(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const counts = try runManifest(allocator, arena.allocator(), std.testing.io, dir, "case.json", false);
    try std.testing.expectEqual(@as(u32, 1), counts.pass);
    try std.testing.expectEqual(@as(u32, 0), counts.fail);
}

test "wasm harness: allocation failure cannot satisfy an expected instantiation trap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "case.wasm", .data = scoring_trapping_start });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "case.json", .data =
        \\{"commands":[{"type":"assert_uninstantiable","filename":"case.wasm","module_type":"binary"}]}
    });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkManifestAllocationFailures, .{tmp.dir});
}

test "wasm harness: action scratch does not accumulate in the manifest arena" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const bytes = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x05\x01\x01f\x00\x00" ++
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b";
    try tmp.dir.writeFile(io, .{ .sub_path = "constant.wasm", .data = bytes });
    const assertion =
        \\,{"type":"assert_return","action":{"type":"invoke","field":"f","args":[]},"expected":[{"type":"i32","value":"42"}]}
    ;
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(std.testing.allocator);
    try manifest.appendSlice(std.testing.allocator,
        \\{"commands":[{"type":"module","filename":"constant.wasm"}
    );
    for (0..32) |_| try manifest.appendSlice(std.testing.allocator, assertion);
    try manifest.appendSlice(std.testing.allocator, "]}");
    try tmp.dir.writeFile(io, .{ .sub_path = "constant.json", .data = manifest.items });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const counts = try runManifest(std.testing.allocator, arena.allocator(), io, tmp.dir, "constant.json", false);
    try std.testing.expectEqual(@as(u32, 33), counts.pass);
    try std.testing.expectEqual(@as(u32, 0), counts.fail);
    try std.testing.expect(arena.queryCapacity() < 2 * 1024 * 1024);
}

test "wasm harness: f32 canonical NaN matching" {
    try testScalarNanMatch(u32, true);
}

test "wasm harness: f64 canonical NaN matching" {
    try testScalarNanMatch(u64, true);
}

test "wasm harness: f32 arithmetic NaN matching" {
    try testScalarNanMatch(u32, false);
}

test "wasm harness: f64 arithmetic NaN matching" {
    try testScalarNanMatch(u64, false);
}

test "wasm harness: numeric float expectations retain exact bits" {
    inline for (.{ u32, u64 }) |U| {
        const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
        const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
        const quiet: U = if (U == u32) 0x0040_0000 else 0x0008_0000_0000_0000;
        for ([_]U{ 0, sign, 1, exponent, exponent | 1, sign | exponent | quiet | 7 }) |bits| {
            var buffer: [32]u8 = undefined;
            const value = try std.fmt.bufPrint(&buffer, "{d}", .{bits});
            try expectScalarMatch(U, value, bits, true);
            try expectScalarMatch(U, value, bits ^ 1, false);
            try expectScalarMatch(U, value, bits ^ sign, false);
        }
    }
}

test "wasm harness: mixed f32x4 NaN and exact lane expectations" {
    const json =
        \\{"type":"v128","lane_type":"f32","value":["nan:canonical","nan:arithmetic","2139095041","2147483648"]}
    ;
    const got: u128 = 0x80000000_7f800001_7fc00123_ffc00000;
    try expectJsonMatch(json, got, true);
    // Change each lane independently: noncanonical, signaling, exact
    // signaling payload, then the sign of an exact zero.
    for ([_]u128{ 1, @as(u128, 0x00400000) << 32, @as(u128, 1) << 64, @as(u128, 0x80000000) << 96 }) |change| {
        try expectJsonMatch(json, got ^ change, false);
    }
}

test "wasm harness: mixed f64x2 NaN and exact lane expectations" {
    const nan_json =
        \\{"type":"v128","lane_type":"f64","value":["nan:canonical","nan:arithmetic"]}
    ;
    const got: u128 = 0xfff8000000000123_7ff8000000000000;
    try expectJsonMatch(nan_json, got, true);
    try expectJsonMatch(nan_json, got ^ 1, false);
    try expectJsonMatch(nan_json, got ^ (@as(u128, 0x0008000000000000) << 64), false);
    const exact_json =
        \\{"type":"v128","lane_type":"f64","value":["9218868437227405313","9223372036854775808"]}
    ;
    const exact: u128 = 0x8000000000000000_7ff0000000000001;
    try expectJsonMatch(exact_json, exact, true);
    try expectJsonMatch(exact_json, exact ^ 1, false);
    try expectJsonMatch(exact_json, exact ^ (@as(u128, 1) << 127), false);
}

test "wasm harness: unknown NaN expectation tokens fail closed" {
    for ([_][]const u8{ "nan", "nan:unknown", "nan:canonical-extra", "nan:0x1" }) |token| {
        try expectScalarMatch(u32, token, 0x7fc00000, false);
        try expectScalarMatch(u64, token, 0x7ff8000000000000, false);
    }
    try expectJsonMatch(
        \\{"type":"v128","lane_type":"f32","value":["nan:unknown","0","0","0"]}
    , 0x7fc00000, false);
    try expectJsonMatch(
        \\{"type":"v128","lane_type":"f64","value":["0","nan:canonical-extra"]}
    , @as(u128, 0x7ff8000000000000) << 64, false);
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
        \\Scored by `zig build wasm-testsuite -Dwasm-corpus=vendor/wasm-testsuite`
        \\against the official WebAssembly spec testsuite (the `.wast` corpus,
        \\preprocessed with `wast2json --enable-tail-call --enable-relaxed-simd
        \\--enable-memory64 --enable-extended-const --enable-multi-memory
        \\--enable-function-references`). Each supported binary `module`, assertion,
        \\and `action` command is a plain pass or fail. A module must decode, validate,
        \\link, initialize, and run its start function successfully, even if no later
        \\assertion uses it. Registers are unscored. Explicit skips cover
        \\`assert_unlinkable`, text/quoted modules, unsupported script commands, and
        \\value forms the harness cannot compare. A decoder, validator, or start
        \\failure in a positive module command is a failure, never an implicit skip.
        \\
        \\**What `pass%` does and does not mean.** `pass%` is `100 ×
        \\passing / (passing + failing)` — the fraction of *scored* commands that
        \\pass, not the fraction of all WebAssembly implemented. Proposal files this
        \\`wast2json` cannot lower are logged conversion exclusions; they do not enter
        \\the command counts. This includes unimplemented WasmGC and the current exception-handling
        \\text syntax; exception handling is implemented and covered by engine unit tests.
        \\
        \\Expected uninstantiability requires a genuine trap or Wasm exception during
        \\initialization/start. Missing files, corrupt manifests, and allocation
        \\failures are harness errors: they fail the run even with `--quiet` and
        \\without a score floor, and prevent writing an incomplete scoreboard.
        \\`assert_invalid` and `assert_malformed` still share decoding/validation
        \\rejection checks; distinguishing those two phases and matching trap text
        \\are separate harness limitations.
        \\
        \\Scalar and vector `nan:canonical` expectations allow only the quiet
        \\payload bit; `nan:arithmetic` requires that bit and allows additional
        \\payload bits. Either sign is valid. Numeric expectations remain
        \\bit-exact, including signaling NaNs and signed zeros.
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
