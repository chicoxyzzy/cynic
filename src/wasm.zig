//! WebAssembly entry module for the Cynic playground.
//!
//! Compiled as a `wasm32-freestanding` `ReleaseSmall` module by the
//! `zig build wasm` step. It exposes a small C-ABI surface the
//! browser front-end (`playground/playground.js`) drives:
//!
//!   cynic_alloc(len)            -> ptr     allocate a guest buffer
//!   cynic_free(ptr, len)        -> void    release a guest buffer
//!   cynic_eval(ptr, len)        -> ptr     run source, return a frame
//!   cynic_parse(ptr, len)       -> ptr     disassemble, return a frame
//!   cynic_result_ptr()          -> ptr     last result frame address
//!   cynic_result_len()          -> u32     last result frame length
//!   cynic_version_ptr/len()              the engine version string
//!
//! There is no libc. Allocation routes through a single
//! `std.heap.WasmAllocator`; the vendored QuickJS C calls back into
//! `cynic_host_alloc` / `cynic_host_free` / `cynic_host_realloc`
//! (see `src/wasm_shim.c`) so one allocator owns every byte.
//!
//! Result framing — `cynic_eval` returns a self-describing buffer
//! so the JS side needs no struct layout knowledge beyond the
//! 4-byte big-endian section lengths:
//!
//!   [u8  status]      0 = ok, 1 = uncaught throw, 2 = parse/compile error
//!   [u32 stdout_len]  big-endian
//!   [u8  stdout_len bytes]      captured console.log / print output
//!   [u32 value_len]   big-endian
//!   [u8  value_len bytes]       completion value, string form
//!   [u32 error_len]   big-endian
//!   [u8  error_len bytes]       error text (empty unless status != 0)
//!
//! `cynic_parse` returns the same frame shape; its `value` section
//! carries the bytecode disassembly text and `stdout` is empty.
//!
//! Strict-only by construction: the playground runs everything
//! through `Realm.evaluateScript`, the same host path `cynic run`
//! uses. There is no `eval` and no `Function(string)` — that is the
//! point of Cynic, and nothing here adds them.

const std = @import("std");
const cynic = @import("cynic");

const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;
const JSString = cynic.runtime.JSString;

// ---------------------------------------------------------------------------
// Allocator
// ---------------------------------------------------------------------------

/// Single module-wide allocator. `WasmAllocator` grows linear
/// memory with the `memory.grow` instruction on demand — there is
/// no fixed heap cap beyond the 4 GiB wasm32 address space and
/// whatever the host caps the instance at.
var wasm_allocator = std.heap.WasmAllocator{};
const gpa = std.mem.Allocator{
    .ptr = &wasm_allocator,
    .vtable = &std.heap.WasmAllocator.vtable,
};

/// Header prepended to every guest allocation so `cynic_free` and
/// the C `realloc` shim can recover the original slice length —
/// `WasmAllocator.free` needs the exact size back. We over-allocate
/// by 16 bytes (kept 16-aligned so the returned pointer stays
/// suitably aligned for any C use) and stash the length there.
const alloc_header = 16;

fn rawAlloc(len: usize) ?[*]u8 {
    const total = len + alloc_header;
    const slice = gpa.alloc(u8, total) catch return null;
    std.mem.writeInt(usize, slice[0..@sizeOf(usize)], total, .little);
    return slice.ptr + alloc_header;
}

fn rawFree(ptr: [*]u8) void {
    const base = ptr - alloc_header;
    const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    gpa.free(base[0..total]);
}

fn rawSize(ptr: [*]u8) usize {
    const base = ptr - alloc_header;
    return std.mem.readInt(usize, base[0..@sizeOf(usize)], .little) - alloc_header;
}

// ---------------------------------------------------------------------------
// C-ABI allocator hooks — called from src/wasm_shim.c
// ---------------------------------------------------------------------------

/// `malloc` for the vendored QuickJS C. Returns null on failure,
/// matching C semantics.
export fn cynic_host_alloc(n: usize) ?[*]u8 {
    if (n == 0) return rawAlloc(1);
    return rawAlloc(n);
}

export fn cynic_host_free(p: ?[*]u8) void {
    if (p) |ptr| rawFree(ptr);
}

export fn cynic_host_realloc(p: ?[*]u8, n: usize) ?[*]u8 {
    const old = p orelse return cynic_host_alloc(n);
    if (n == 0) {
        rawFree(old);
        return null;
    }
    const old_len = rawSize(old);
    const fresh = rawAlloc(n) orelse return null;
    const copy = @min(old_len, n);
    @memcpy(fresh[0..copy], old[0..copy]);
    rawFree(old);
    return fresh;
}

// ---------------------------------------------------------------------------
// Guest buffer ABI — the JS side hands source in / reads results out
// ---------------------------------------------------------------------------

/// Allocate `len` bytes inside the module and return the offset.
/// The JS side writes UTF-8 source there before calling
/// `cynic_eval` / `cynic_parse`.
export fn cynic_alloc(len: u32) ?[*]u8 {
    if (len == 0) return rawAlloc(1);
    return rawAlloc(len);
}

/// Release a buffer obtained from `cynic_alloc`. `len` is accepted
/// for a symmetric ABI but unused — the length is recovered from
/// the allocation header.
export fn cynic_free(ptr: ?[*]u8, len: u32) void {
    _ = len;
    if (ptr) |p| rawFree(p);
}

// ---------------------------------------------------------------------------
// Result frame
// ---------------------------------------------------------------------------

/// The last result frame produced by `cynic_eval` / `cynic_parse`.
/// Owned by this module; freed and replaced on the next call. The
/// JS side reads it via `cynic_result_ptr` / `cynic_result_len`
/// immediately after the call returns.
var result_frame: []u8 = &.{};

fn freeResultFrame() void {
    if (result_frame.len != 0) {
        gpa.free(result_frame);
        result_frame = &.{};
    }
}

export fn cynic_result_ptr() ?[*]u8 {
    return if (result_frame.len == 0) null else result_frame.ptr;
}

export fn cynic_result_len() u32 {
    return @intCast(result_frame.len);
}

const Status = enum(u8) {
    ok = 0,
    threw = 1,
    parse_error = 2,
};

/// Build the framed result buffer (see the module doc-comment for
/// the layout) and install it as `result_frame`. On allocation
/// failure `result_frame` is left empty and the JS side sees a
/// zero-length result, which it treats as an internal error.
fn buildFrame(status: Status, stdout: []const u8, value: []const u8, err: []const u8) [*]u8 {
    freeResultFrame();
    const total = 1 + 4 + stdout.len + 4 + value.len + 4 + err.len;
    const buf = gpa.alloc(u8, total) catch {
        return @ptrFromInt(8); // non-null sentinel; len() reports 0
    };
    var w: usize = 0;
    buf[w] = @intFromEnum(status);
    w += 1;
    inline for (.{ stdout, value, err }) |section| {
        std.mem.writeInt(u32, buf[w..][0..4], @intCast(section.len), .big);
        w += 4;
        @memcpy(buf[w..][0..section.len], section);
        w += section.len;
    }
    result_frame = buf;
    return buf.ptr;
}

// ---------------------------------------------------------------------------
// cynic_eval — run source through the host evaluateScript path
// ---------------------------------------------------------------------------

/// Compile and run `src[0..len]` as a Script body. Returns a
/// pointer to the framed result (also retrievable via
/// `cynic_result_ptr`). Captured `console.log` / `print` output,
/// the completion value's string form, and any uncaught exception
/// all land in the frame.
export fn cynic_eval(src: [*]const u8, len: u32) [*]u8 {
    const source = src[0..len];

    // Pre-parse with a diagnostics buffer so syntax errors surface
    // as readable text instead of a silent `undefined`. Cynic's
    // parser is diagnostic-collecting — it only returns
    // `error.ParseError` for fatal cases and otherwise yields a
    // (possibly partial) program with error-severity diagnostics
    // attached. The playground reports the first such diagnostic
    // and does NOT execute a program that failed to parse cleanly.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var diags: cynic.diagnostic.Diagnostics = .empty;
        const pre = cynic.parser.parseScript(arena.allocator(), source, &diags);
        if (pre) |_| {
            if (firstError(&diags)) |_| {
                var msg: std.ArrayListUnmanaged(u8) = .empty;
                defer msg.deinit(gpa);
                appendDiagnostics(&msg, &diags) catch {};
                return buildFrame(.parse_error, "", "", msg.items);
            }
        } else |_| {
            var msg: std.ArrayListUnmanaged(u8) = .empty;
            defer msg.deinit(gpa);
            appendDiagnostics(&msg, &diags) catch {};
            return buildFrame(.parse_error, "", "", msg.items);
        }
    }

    var realm = Realm.init(gpa);
    defer realm.deinit();
    realm.installBuiltins() catch {
        return buildFrame(.parse_error, "", "", "internal error: builtin install failed");
    };

    const outcome = cynic.runtime.evaluateScript(gpa, &realm, source) catch |err| {
        const msg = switch (err) {
            error.ParseError => "SyntaxError: failed to parse",
            error.CompileError => "SyntaxError: failed to compile",
            error.OutOfMemory => "RangeError: out of memory",
            error.InvalidOpcode => "InternalError: invalid opcode",
        };
        return buildFrame(.parse_error, realm.output.items, "", msg);
    };

    // §9.4 — finish the current Job before returning to the host
    // so `Promise.resolve(v).then(cb)` runs `cb`.
    cynic.runtime.interpreter.drainMicrotasks(gpa, &realm) catch {};

    var value_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer value_buf.deinit(gpa);
    var error_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer error_buf.deinit(gpa);

    switch (outcome) {
        .value, .yielded => |v| {
            appendValueText(&value_buf, v) catch {};
            return buildFrame(.ok, realm.output.items, value_buf.items, "");
        },
        .thrown => |v| {
            appendThrownText(&error_buf, v) catch {};
            return buildFrame(.threw, realm.output.items, "", error_buf.items);
        },
    }
}

// ---------------------------------------------------------------------------
// cynic_parse — bytecode disassembly (the "inspector" toggle)
// ---------------------------------------------------------------------------

/// Parse + compile `src[0..len]` as a Script and return a textual
/// bytecode disassembly in the frame's `value` section. Does NOT
/// execute the program. Used by the playground's bytecode-inspector
/// toggle.
export fn cynic_parse(src: [*]const u8, len: u32) [*]u8 {
    const source = src[0..len];

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var diags: cynic.diagnostic.Diagnostics = .empty;
    const program = cynic.parser.parseScript(aa, source, &diags) catch {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        appendDiagnostics(&msg, &diags) catch {};
        defer msg.deinit(gpa);
        return buildFrame(.parse_error, "", "", msg.items);
    };
    // A non-fatal parse can still have collected error diagnostics
    // — surface them rather than disassembling a malformed program.
    if (firstError(&diags) != null) {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        appendDiagnostics(&msg, &diags) catch {};
        defer msg.deinit(gpa);
        return buildFrame(.parse_error, "", "", msg.items);
    }

    var realm = Realm.init(gpa);
    defer realm.deinit();
    realm.installBuiltins() catch {
        return buildFrame(.parse_error, "", "", "internal error: builtin install failed");
    };

    var chunk = cynic.bytecode.compiler.compileScriptAsChunk(gpa, &realm, &program, source, null) catch {
        return buildFrame(.parse_error, "", "", "SyntaxError: failed to compile");
    };
    defer chunk.deinit(gpa);

    const text = cynic.bytecode.disasm.dump(gpa, &chunk) catch {
        return buildFrame(.parse_error, "", "", "internal error: disassembly failed");
    };
    defer gpa.free(text);

    return buildFrame(.ok, "", text, "");
}

// ---------------------------------------------------------------------------
// Version string
// ---------------------------------------------------------------------------

// Stamped by `build.zig` from `git rev-parse --short HEAD` at
// configure time, so the playground footer always names the exact
// commit the `.wasm` was built from. Falls back to "cynic-wasm
// unknown" when git isn't available (e.g. a source tarball build).
const version = @import("build_options").wasm_version;

export fn cynic_version_ptr() [*]const u8 {
    return version.ptr;
}

export fn cynic_version_len() u32 {
    return version.len;
}

// ---------------------------------------------------------------------------
// Value formatting
// ---------------------------------------------------------------------------

/// Render `v` as the playground's display string. Primitives get
/// their natural form; objects / functions get a coarse tag — the
/// playground shows the completion value as a hint, not a full
/// inspector (that is what `console.log` inside the script is for).
fn appendValueText(buf: *std.ArrayListUnmanaged(u8), v: Value) !void {
    var scratch: [64]u8 = undefined;
    if (v.isInt32()) {
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&scratch, "{d}", .{v.asInt32()}));
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try buf.appendSlice(gpa, "NaN");
        } else if (std.math.isInf(d)) {
            try buf.appendSlice(gpa, if (d > 0) "Infinity" else "-Infinity");
        } else {
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&scratch, "{d}", .{d}));
        }
    } else if (v.isBool()) {
        try buf.appendSlice(gpa, if (v.asBool()) "true" else "false");
    } else if (v.isNull()) {
        try buf.appendSlice(gpa, "null");
    } else if (v.isUndefined()) {
        try buf.appendSlice(gpa, "undefined");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        try buf.appendSlice(gpa, s.bytes);
    } else if (cynic.runtime.heap.valueAsBigInt(v)) |bi| {
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&scratch, "{d}n", .{bi.value}));
    } else if (cynic.runtime.heap.isFunction(v)) {
        try buf.appendSlice(gpa, "[Function]");
    } else if (cynic.runtime.heap.isPlainObject(v)) {
        try buf.appendSlice(gpa, "[object Object]");
    } else {
        try buf.appendSlice(gpa, "[unknown]");
    }
}

/// Render an uncaught exception value. Error objects get the
/// idiomatic `Name: message` form by reading the `name` / `message`
/// own/proto properties; anything else falls back to plain value
/// text. Keeps the playground's error panel readable.
fn appendThrownText(buf: *std.ArrayListUnmanaged(u8), v: Value) !void {
    if (cynic.runtime.heap.valueAsPlainObject(v)) |obj| {
        const name = lookupString(obj, "name");
        const msg = lookupString(obj, "message");
        if (name != null or msg != null) {
            try buf.appendSlice(gpa, name orelse "Error");
            if (msg) |m| {
                if (m.len != 0) {
                    try buf.appendSlice(gpa, ": ");
                    try buf.appendSlice(gpa, m);
                }
            }
            return;
        }
    }
    try buf.appendSlice(gpa, "Uncaught: ");
    try appendValueText(buf, v);
}

/// Best-effort read of a string-valued own property. Walks the
/// prototype chain one hop for `name` (error names live on the
/// prototype). Returns null if absent or non-string.
fn lookupString(obj: *cynic.runtime.JSObject, key: []const u8) ?[]const u8 {
    if (obj.properties.get(key)) |p| {
        if (p.isString()) {
            const s: *JSString = @ptrCast(@alignCast(p.asString()));
            return s.bytes;
        }
    }
    if (obj.prototype) |proto| {
        if (proto.properties.get(key)) |p| {
            if (p.isString()) {
                const s: *JSString = @ptrCast(@alignCast(p.asString()));
                return s.bytes;
            }
        }
    }
    return null;
}

/// Return the first error-severity diagnostic, or null if the
/// buffer holds only warnings / notes.
fn firstError(diags: *const cynic.diagnostic.Diagnostics) ?cynic.diagnostic.Diagnostic {
    for (diags.items) |d| {
        if (d.severity == .err) return d;
    }
    return null;
}

/// Render the error-severity diagnostics as the playground's error
/// text — one `Class: code [start..end]` line each. Warnings and
/// notes are dropped (the playground reports failures, not lint).
fn appendDiagnostics(buf: *std.ArrayListUnmanaged(u8), diags: *const cynic.diagnostic.Diagnostics) !void {
    var wrote = false;
    for (diags.items) |d| {
        if (d.severity != .err) continue;
        if (wrote) try buf.append(gpa, '\n');
        wrote = true;
        var scratch: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&scratch, "{s}: {s} [{d}..{d}]", .{
            d.code.errorClass().name(),
            @tagName(d.code),
            d.span.start,
            d.span.end,
        });
        try buf.appendSlice(gpa, line);
        if (d.message.len != 0) {
            try buf.appendSlice(gpa, " — ");
            try buf.appendSlice(gpa, d.message);
        }
    }
    if (!wrote) {
        try buf.appendSlice(gpa, "SyntaxError: failed to parse");
    }
}

// ---------------------------------------------------------------------------
// Freestanding entry shims
// ---------------------------------------------------------------------------

/// `wasm32-freestanding` has no process model; the module is a
/// pure library of exports. A no-op `_start` keeps tooling that
/// expects a start function happy.
export fn _start() void {}
