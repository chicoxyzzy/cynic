//! WebAssembly module → WAT text, for the playground's "wasm" inspector
//! tab (the structure + disassembly analog of the JS AST / bytecode
//! views). Lives at the library boundary — not under `runtime/wasm/` —
//! because it is a *display* concern: the engine never needs it, but
//! surfacing it here lets `zig build test` exercise the printer (the
//! playground entry that calls it is wasm32-only). Mirrors the rationale
//! for `wasm_format.zig` / `wasm_diag.zig`.
//!
//! Output is flat WAT (§6.4.5-style): each instruction on its own line,
//! `block` / `loop` / `if` raising indentation and closed by `end`, so
//! the text tracks the bytecode 1:1 (a faithful disassembly, not the
//! folded s-expression form). The module header renders types, imports,
//! memories, tables, globals, the start function, and exports.
//!
//! Robustness: a malformed or unsupported function body (a truncated
//! immediate, an opcode outside the set Sarcasm decodes, a SIMD/`0xfd`
//! instruction) emits an inline `(; … ;)` note and stops *that* body
//! rather than failing the whole dump — the inspector degrades, it does
//! not abort. Decoding never reads past `FuncBody.bytes`.

const std = @import("std");
const module_mod = @import("runtime/wasm/module.zig");
const types = @import("runtime/wasm/types.zig");
const reader_mod = @import("runtime/wasm/reader.zig");
const opcodes = @import("runtime/wasm/opcodes.zig");

const Module = module_mod.Module;
const FuncType = types.FuncType;
const ValType = types.ValType;
const Op = opcodes.Op;
const Reader = reader_mod.Reader;

const Buf = std.ArrayListUnmanaged(u8);

/// Render `module` as WAT text. Caller owns the returned slice.
pub fn toWat(allocator: std.mem.Allocator, module: *const Module) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(allocator);
    try appendModule(allocator, &buf, module);
    return buf.toOwnedSlice(allocator);
}

/// `toWat` over the realm's opaque `last_wasm_module` pointer (which is a
/// `*const Module`), so callers — the playground entry — need not name
/// the engine's module type.
pub fn toWatOpaque(allocator: std.mem.Allocator, module_ptr: *const anyopaque) ![]u8 {
    const m: *const Module = @ptrCast(@alignCast(module_ptr));
    return toWat(allocator, m);
}

fn appendModule(a: std.mem.Allocator, buf: *Buf, m: *const Module) !void {
    try buf.appendSlice(a, "(module\n");

    // §5.5.4 types.
    for (m.types, 0..) |ft, i| {
        try print(a, buf, "  (type (;{d};) ", .{i});
        try appendFuncType(a, buf, ft);
        try buf.appendSlice(a, ")\n");
    }

    // §5.5.5 imports.
    for (m.imports) |imp| {
        try buf.appendSlice(a, "  (import ");
        try appendString(a, buf, imp.module);
        try buf.append(a, ' ');
        try appendString(a, buf, imp.name);
        try buf.append(a, ' ');
        switch (imp.desc) {
            .func => |t| try print(a, buf, "(func (type {d}))", .{t}),
            .table => |tt| {
                try buf.appendSlice(a, "(table ");
                try appendLimits(a, buf, tt.limits);
                try buf.append(a, ' ');
                try buf.appendSlice(a, valTypeName(tt.elem));
                try buf.append(a, ')');
            },
            .mem => |mt| {
                try buf.appendSlice(a, "(memory ");
                try appendLimits(a, buf, mt.limits);
                try buf.append(a, ')');
            },
            .global => |gt| {
                try buf.appendSlice(a, "(global ");
                try appendGlobalType(a, buf, gt);
                try buf.append(a, ')');
            },
            .tag => |t| try print(a, buf, "(tag (type {d}))", .{t}),
        }
        try buf.appendSlice(a, ")\n");
    }

    // §5.5.7 tables.
    for (m.tables, 0..) |tt, i| {
        try print(a, buf, "  (table (;{d};) ", .{i});
        try appendLimits(a, buf, tt.limits);
        try buf.append(a, ' ');
        try buf.appendSlice(a, valTypeName(tt.elem));
        try buf.appendSlice(a, ")\n");
    }

    // §5.5.8 memories.
    for (m.mems, 0..) |mt, i| {
        try print(a, buf, "  (memory (;{d};) ", .{i});
        try appendLimits(a, buf, mt.limits);
        try buf.appendSlice(a, ")\n");
    }

    // §5.5.9 globals (the initializer expression is raw bytes; note it).
    for (m.globals, 0..) |g, i| {
        try print(a, buf, "  (global (;{d};) ", .{i});
        try appendGlobalType(a, buf, g.type);
        try buf.appendSlice(a, " (; init ;))\n");
    }

    // §5.5.6 functions + §5.5.13 bodies, paired positionally.
    for (m.funcs, 0..) |type_idx, i| {
        appendFunc(a, buf, m, i, type_idx) catch |e| switch (e) {
            error.OutOfMemory => return e,
        };
    }

    // §5.5.11 start.
    if (m.start) |s| try print(a, buf, "  (start {d})\n", .{s});

    // §5.5.10 exports.
    for (m.exports) |exp| {
        try buf.appendSlice(a, "  (export ");
        try appendString(a, buf, exp.name);
        switch (exp.desc) {
            .func => |x| try print(a, buf, " (func {d}))\n", .{x}),
            .table => |x| try print(a, buf, " (table {d}))\n", .{x}),
            .mem => |x| try print(a, buf, " (memory {d}))\n", .{x}),
            .global => |x| try print(a, buf, " (global {d}))\n", .{x}),
            .tag => |x| try print(a, buf, " (tag {d}))\n", .{x}),
        }
    }

    // Element / data segments are captured raw (§5.5.12 / §5.5.14); note
    // their counts rather than decoding the per-segment structure.
    if (m.elements_count > 0) try print(a, buf, "  (; {d} element segment(s) ;)\n", .{m.elements_count});
    if (m.data_count_in_section > 0) try print(a, buf, "  (; {d} data segment(s) ;)\n", .{m.data_count_in_section});

    try buf.appendSlice(a, ")\n");
}

/// `(func (;i;) (type t) (local …)` header, the disassembled body, and
/// the closing `)`. A malformed body emits an inline note and stops.
fn appendFunc(a: std.mem.Allocator, buf: *Buf, m: *const Module, i: usize, type_idx: u32) error{OutOfMemory}!void {
    try print(a, buf, "  (func (;{d};) (type {d})", .{ i, type_idx });

    if (i >= m.code.len) {
        try buf.appendSlice(a, " (; missing body ;))\n");
        return;
    }
    var r = Reader.init(m.code[i].bytes);

    // Locals header: a vector of (count, valtype) runs.
    if (readLocals(a, buf, &r)) |_| {} else |_| {
        try buf.appendSlice(a, " (; malformed locals ;))\n");
        return;
    }
    try buf.append(a, '\n');

    disasmBody(a, buf, &r) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    try buf.appendSlice(a, "  )\n");
}

fn readLocals(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    const runs = try r.uleb(u32);
    if (runs == 0) return;
    try buf.appendSlice(a, " (local");
    var run: u32 = 0;
    while (run < runs) : (run += 1) {
        const n = try r.uleb(u32);
        const vt = try types.readValType(r);
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            try buf.append(a, ' ');
            try buf.appendSlice(a, valTypeName(vt));
        }
    }
    try buf.append(a, ')');
}

/// Disassemble the instruction stream up to the body-terminating `end`,
/// each instruction rendered as `<raw bytes>  <mnemonic> <operands>`.
/// `block` / `loop` / `if` raise indentation; their `end` lowers it and
/// prints `end`. The outermost `end` closes the function (rendered by
/// the caller's `)`), so it is consumed silently. Any decode failure or
/// unsupported opcode appends a note and stops.
fn disasmBody(a: std.mem.Allocator, buf: *Buf, r: *Reader) error{OutOfMemory}!void {
    var depth: u32 = 0; // structured-control nesting within the body
    var line: Buf = .empty; // scratch for the current mnemonic + operands
    defer line.deinit(a);
    while (true) {
        const start = r.pos; // first byte of this instruction
        const opbyte = r.byte() catch return; // ran out — done
        const op = std.enums.fromInt(Op, opbyte) orelse {
            line.clearRetainingCapacity();
            try print(a, &line, "(; unknown opcode 0x{x:0>2} — disassembly stopped ;)", .{opbyte});
            try emitInstr(a, buf, r.bytes[start..r.pos], depth, line.items);
            return;
        };

        if (op == .end) {
            if (depth == 0) return; // function terminator
            depth -= 1;
            try emitInstr(a, buf, r.bytes[start..r.pos], depth, "end");
            continue;
        }
        if (op == .@"else") {
            // Sits between the if's arms: render at the if's level, body
            // depth unchanged.
            try emitInstr(a, buf, r.bytes[start..r.pos], if (depth == 0) 0 else depth - 1, "else");
            continue;
        }

        line.clearRetainingCapacity();
        try appendMnemonic(a, &line, op);
        appendImmediates(a, &line, r, op, opbyte) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try line.appendSlice(a, " (; truncated — disassembly stopped ;)");
                try emitInstr(a, buf, r.bytes[start..r.pos], depth, line.items);
                return;
            },
        };
        try emitInstr(a, buf, r.bytes[start..r.pos], depth, line.items);

        switch (op) {
            .block, .loop, .@"if", .try_table => depth += 1,
            else => {},
        }
    }
}

/// Emit one disassembled instruction: indentation, the raw byte encoding
/// (space-separated two-digit hex), two spaces, then `text` (the mnemonic
/// and its operands).
fn emitInstr(a: std.mem.Allocator, buf: *Buf, bytes: []const u8, depth: u32, text: []const u8) error{OutOfMemory}!void {
    try indent(a, buf, depth);
    try appendHex(a, buf, bytes);
    try buf.appendSlice(a, "  ");
    try buf.appendSlice(a, text);
    try buf.append(a, '\n');
}

/// Space-separated two-digit hex for `bytes` (no per-byte allocation).
fn appendHex(a: std.mem.Allocator, buf: *Buf, bytes: []const u8) error{OutOfMemory}!void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        if (i != 0) try buf.append(a, ' ');
        try buf.append(a, digits[b >> 4]);
        try buf.append(a, digits[b & 0x0f]);
    }
}

/// Append an instruction's operands. Returns a reader error on a
/// truncated immediate (the caller turns that into an inline note); an
/// opcode whose immediates Sarcasm does not lay out here (the `0xfd`
/// SIMD family) returns `error.Unsupported` to stop the body cleanly.
fn appendImmediates(a: std.mem.Allocator, buf: *Buf, r: *Reader, op: Op, opbyte: u8) !void {
    switch (opbyte) {
        // Block types: empty (0x40), a single value type, or a type index.
        0x02, 0x03, 0x04 => try appendBlockType(a, buf, r), // block / loop / if
        0x1f => { // try_table: block type then a catch vector
            try appendBlockType(a, buf, r);
            const catches = try r.uleb(u32);
            try print(a, buf, " (; {d} catch ;)", .{catches});
            // We cannot lay out the catch clauses' immediates here; stop.
            if (catches > 0) return error.Unsupported;
        },
        0x0c, 0x0d => try printU32(a, buf, r), // br / br_if  (labelidx)
        0xd5, 0xd6 => try printU32(a, buf, r), // br_on_null / br_on_non_null
        0x0e => { // br_table: vector of labels + default
            const n = try r.uleb(u32);
            var k: u32 = 0;
            while (k < n) : (k += 1) try print(a, buf, " {d}", .{try r.uleb(u32)});
            try print(a, buf, " {d}", .{try r.uleb(u32)}); // default
        },
        0x10, 0x12 => try printU32(a, buf, r), // call / return_call (funcidx)
        0x08 => try printU32(a, buf, r), // throw (tagidx)
        0xd2 => try printU32(a, buf, r), // ref_func (funcidx)
        0x14, 0x15 => try printU32(a, buf, r), // call_ref / return_call_ref (typeidx)
        0x11, 0x13 => { // call_indirect / return_call_indirect (typeidx, tableidx)
            try print(a, buf, " {d}", .{try r.uleb(u32)});
            try print(a, buf, " {d}", .{try r.uleb(u32)});
        },
        0x20...0x26 => try printU32(a, buf, r), // local/global/table get/set
        0x28...0x3e => try appendMemArg(a, buf, r), // loads / stores
        0x3f, 0x40 => _ = try r.uleb(u32), // memory.size / memory.grow (memidx; not shown)
        0x41 => try print(a, buf, " {d}", .{try r.sleb(i32)}), // i32.const
        0x42 => try print(a, buf, " {d}", .{try r.sleb(i64)}), // i64.const
        0x43 => try print(a, buf, " {d}", .{@as(f32, @bitCast(try r.u32le()))}), // f32.const
        0x44 => { // f64.const
            const bytes = try r.bytesN(8);
            const bits = std.mem.readInt(u64, bytes[0..8], .little);
            try print(a, buf, " {d}", .{@as(f64, @bitCast(bits))});
        },
        0xd0 => try appendHeapType(a, buf, r), // ref.null ht
        0x1c => { // select with explicit result types
            const n = try r.uleb(u32);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const vt = try types.readValType(r);
                try print(a, buf, " {s}", .{valTypeName(vt)});
            }
        },
        0xfc => try appendFcImmediates(a, buf, r), // bulk-memory / sat-trunc family
        0xfd => return error.Unsupported, // SIMD (v128) — variable immediates
        else => {}, // every other opcode is immediate-free
    }
    _ = op;
}

/// 0xFC-prefixed family. The saturating truncations (sub 0-7) take no
/// further operands; the bulk memory/table ops (8+) take 1-2 indices.
fn appendFcImmediates(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    const sub = try r.uleb(u32);
    try print(a, buf, " (;fc {d};)", .{sub});
    switch (sub) {
        0...7 => {}, // i32/i64 trunc_sat_f32/f64_s/u — no operands
        8 => { // memory.init: dataidx, memidx(0x00)
            try print(a, buf, " {d}", .{try r.uleb(u32)});
            _ = try r.uleb(u32);
        },
        9 => try print(a, buf, " {d}", .{try r.uleb(u32)}), // data.drop: dataidx
        10 => { // memory.copy: two memidx
            _ = try r.uleb(u32);
            _ = try r.uleb(u32);
        },
        11 => _ = try r.uleb(u32), // memory.fill: memidx
        12, 14 => { // table.init / table.copy: two indices
            try print(a, buf, " {d}", .{try r.uleb(u32)});
            try print(a, buf, " {d}", .{try r.uleb(u32)});
        },
        13, 15, 16, 17 => try print(a, buf, " {d}", .{try r.uleb(u32)}), // elem.drop / table grow/size/fill
        else => return error.Unsupported,
    }
}

fn appendBlockType(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    const b = try r.peek();
    if (b == 0x40) {
        _ = try r.byte(); // empty result
        return;
    }
    if (ValType.fromByte(b)) |vt| {
        _ = try r.byte();
        try print(a, buf, " (result {s})", .{valTypeName(vt)});
        return;
    }
    // Otherwise an s33 type index.
    const idx = try r.sleb(i64);
    try print(a, buf, " (type {d})", .{idx});
}

fn appendHeapType(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    const ht = try r.sleb(i64);
    const name: []const u8 = switch (ht) {
        -0x10 => "func",
        -0x11 => "extern",
        -0x17 => "exn",
        else => null,
    } orelse {
        try print(a, buf, " {d}", .{ht}); // concrete type index
        return;
    };
    try print(a, buf, " {s}", .{name});
}

fn appendMemArg(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    const alignment = try r.uleb(u32);
    const offset = try r.uleb(u32);
    if (offset != 0) try print(a, buf, " offset={d}", .{offset});
    try print(a, buf, " align={d}", .{(@as(u64, 1) << @as(u6, @intCast(@min(alignment, 63))))});
}

fn printU32(a: std.mem.Allocator, buf: *Buf, r: *Reader) !void {
    try print(a, buf, " {d}", .{try r.uleb(u32)});
}

/// WAT mnemonic for an opcode. Namespace-prefixed instructions
/// (`i32_*`, `local_*`, `memory_*`, …) take a dot; the control / call
/// forms (`br_if`, `call_indirect`, `return_call`) keep underscores.
/// `select_t` renders as plain `select`.
fn appendMnemonic(a: std.mem.Allocator, buf: *Buf, op: Op) !void {
    if (op == .select_t) {
        try buf.appendSlice(a, "select");
        return;
    }
    const name = @tagName(op);
    if (firstDotIndex(name)) |dot| {
        try buf.appendSlice(a, name[0..dot]);
        try buf.append(a, '.');
        try buf.appendSlice(a, name[dot + 1 ..]);
    } else {
        try buf.appendSlice(a, name);
    }
}

/// Index of the underscore that should become a dot — only when `name`
/// begins with a value/storage namespace prefix. Returns null for
/// control-flow mnemonics that keep their underscores.
fn firstDotIndex(name: []const u8) ?usize {
    const namespaces = [_][]const u8{ "i32_", "i64_", "f32_", "f64_", "v128_", "local_", "global_", "table_", "ref_", "memory_" };
    for (namespaces) |ns| {
        if (std.mem.startsWith(u8, name, ns)) return ns.len - 1;
    }
    return null;
}

fn appendFuncType(a: std.mem.Allocator, buf: *Buf, ft: FuncType) !void {
    try buf.appendSlice(a, "(func");
    if (ft.params.len > 0) {
        try buf.appendSlice(a, " (param");
        for (ft.params) |p| try print(a, buf, " {s}", .{valTypeName(p)});
        try buf.append(a, ')');
    }
    if (ft.results.len > 0) {
        try buf.appendSlice(a, " (result");
        for (ft.results) |rt| try print(a, buf, " {s}", .{valTypeName(rt)});
        try buf.append(a, ')');
    }
    try buf.append(a, ')');
}

fn appendGlobalType(a: std.mem.Allocator, buf: *Buf, gt: types.GlobalType) !void {
    if (gt.mut == .mutable) {
        try print(a, buf, "(mut {s})", .{valTypeName(gt.val)});
    } else {
        try buf.appendSlice(a, valTypeName(gt.val));
    }
}

fn appendLimits(a: std.mem.Allocator, buf: *Buf, l: types.Limits) !void {
    try print(a, buf, "{d}", .{l.min});
    if (l.max) |mx| try print(a, buf, " {d}", .{mx});
}

fn valTypeName(vt: ValType) []const u8 {
    return switch (vt) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
        .v128 => "v128",
        .funcref => "funcref",
        .externref => "externref",
        .exnref => "exnref",
        else => "ref", // constructed (ref ht) forms — simplified
    };
}

/// A WAT string literal: double-quoted, with the few escapes WAT names
/// need. Module/field names are validated UTF-8 (§5.2.4); keep them as-is
/// otherwise.
fn appendString(a: std.mem.Allocator, buf: *Buf, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn indent(a: std.mem.Allocator, buf: *Buf, depth: u32) !void {
    // Body instructions start at 4 spaces; each nesting level adds 2.
    var n: u32 = 0;
    while (n < 4 + depth * 2) : (n += 1) try buf.append(a, ' ');
}

fn print(a: std.mem.Allocator, buf: *Buf, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try buf.appendSlice(a, s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const decode = @import("runtime/wasm/decoder.zig").decode;

fn watOf(bytes: []const u8) ![]u8 {
    // The decoder's slices are owned by the allocator passed in (there
    // is no Module.deinit); an arena frees them all at once.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try decode(arena.allocator(), bytes);
    return toWat(testing.allocator, &m);
}

test "toWat: an (i32,i32)->i32 adder" {
    // (module (type (func (param i32 i32) (result i32)))
    //   (func (type 0) local.get 0; local.get 1; i32.add)
    //   (export "add" (func 0)))
    const bytes = [_]u8{
        0, 97, 115, 109, 1, 0, 0, 0, // \0asm v1
        1, 7, 1, 0x60, 2, 0x7f, 0x7f, 1, 0x7f, // type: (i32,i32)->i32
        3, 2, 1, 0, // func 0 : type 0
        7, 7, 1, 3, 'a', 'd', 'd', 0, 0, // export "add" func 0
        10, 9, 1, 7, 0, 0x20, 0, 0x20, 1, 0x6a, 0x0b, // code: local.get 0/1; i32.add; end
    };
    const wat = try watOf(&bytes);
    defer testing.allocator.free(wat);
    const expected =
        \\(module
        \\  (type (;0;) (func (param i32 i32) (result i32)))
        \\  (func (;0;) (type 0)
        \\    20 00  local.get 0
        \\    20 01  local.get 1
        \\    6a  i32.add
        \\  )
        \\  (export "add" (func 0))
        \\)
        \\
    ;
    try testing.expectEqualStrings(expected, wat);
}

test "toWat: i32.const immediate and a result-only type" {
    // (module (type (func (result i32))) (func (type 0) i32.const 7) (export "f" (func 0)))
    const bytes = [_]u8{
        0, 97, 115, 109, 1, 0, 0, 0,
        1, 5,   1, 0x60, 0, 1, 0x7f, // type: () -> i32
        3, 2,   1, 0,    7, 5, 1,
        1, 'f', 0, 0,
        10, 6, 1, 4, 0, 0x41, 7, 0x0b, // i32.const 7; end
    };
    const wat = try watOf(&bytes);
    defer testing.allocator.free(wat);
    const expected =
        \\(module
        \\  (type (;0;) (func (result i32)))
        \\  (func (;0;) (type 0)
        \\    41 07  i32.const 7
        \\  )
        \\  (export "f" (func 0))
        \\)
        \\
    ;
    try testing.expectEqualStrings(expected, wat);
}

test "mnemonic dotting: namespaces dot, control forms keep underscores" {
    var buf: Buf = .empty;
    defer buf.deinit(testing.allocator);
    const cases = [_]struct { op: Op, want: []const u8 }{
        .{ .op = .i32_add, .want = "i32.add" },
        .{ .op = .local_get, .want = "local.get" },
        .{ .op = .memory_size, .want = "memory.size" },
        .{ .op = .i32_trunc_f32_s, .want = "i32.trunc_f32_s" },
        .{ .op = .ref_is_null, .want = "ref.is_null" },
        .{ .op = .br_if, .want = "br_if" },
        .{ .op = .call_indirect, .want = "call_indirect" },
        .{ .op = .return_call, .want = "return_call" },
        .{ .op = .select_t, .want = "select" },
        .{ .op = .@"if", .want = "if" },
    };
    for (cases) |c| {
        buf.clearRetainingCapacity();
        try appendMnemonic(testing.allocator, &buf, c.op);
        try testing.expectEqualStrings(c.want, buf.items);
    }
}
