//! Bytecode disassembler. Mirrors `src/ast/printer.zig` in spirit:
//! a deterministic, line-oriented dump used by golden tests and by
//! the `cynic` CLI when humans need to read what the compiler
//! emitted.
//!
//! Format (one instruction per line, indented two spaces):
//!
//! ```
//! (chunk regs=N consts=M
//! 0000 LdaSmi 1 [span]
//! 0005 Star r0 [span]
//!...
//! NNNN Return [span]
//! )
//! ```
//!
//! The leading offset is the byte index of the opcode within
//! `Chunk.code`. Operand formatting: registers as `rN`, constant
//! indices as `kN`, jump offsets as `+N` / `-N`. Source spans
//! are appended in `[start..end]` form when available — same
//! convention as the AST printer, so a developer can correlate
//! the two dumps side by side.

const std = @import("std");

const Op = @import("op.zig").Op;
const Chunk = @import("chunk.zig").Chunk;
const SourcePos = @import("chunk.zig").SourcePos;
const Value = @import("../runtime/value.zig").Value;

/// Allocate and return a textual disassembly of `chunk`. Caller
/// owns the returned slice (allocator-allocated).
pub fn dump(allocator: std.mem.Allocator, chunk: *const Chunk) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "(chunk regs={d} consts={d}", .{
        chunk.register_count, chunk.constants.len,
    });

    // Build a span-by-offset index so we don't do an O(N*M) lookup.
    // `source_positions` is already sorted; we walk both arrays in
    // lock-step.
    var sp_index: usize = 0;

    var i: usize = 0;
    while (i < chunk.code.len) {
        const op_byte = chunk.code[i];
        const op: Op = @enumFromInt(op_byte);
        const operand_size = Op.operandSize(op);

        try buf.append(allocator, '\n');
        try buf.print(allocator, "  {x:0>4} {s}", .{ i, Op.mnemonic(op) });

        // Format the operand, if any.
        switch (op) {
            .ldar, .star => {
                const r = chunk.code[i + 1];
                try buf.print(allocator, " r{d}", .{r});
            },
            .mov => {
                const src = chunk.code[i + 1];
                const dst = chunk.code[i + 2];
                try buf.print(allocator, " r{d} r{d}", .{ src, dst });
            },
            .add, .add_to_int32, .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .shl, .shr, .shr_u, .eq, .strict_eq, .neq, .strict_neq, .lt, .gt, .le, .ge, .instanceof_, .array_spread => {
                const r = chunk.code[i + 1];
                try buf.print(allocator, " r{d}", .{r});
            },
            .add_smi => {
                const r = chunk.code[i + 1];
                const imm = readI32(chunk.code, i + 2);
                try buf.print(allocator, " r{d} {d}", .{ r, imm });
            },
            .lda_constant => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " k{d}", .{k});
                if (k < chunk.constants.len) {
                    try buf.append(allocator, ' ');
                    try formatConstant(allocator, &buf, chunk.constants[k]);
                }
            },
            .lda_smi => {
                const v = readI32(chunk.code, i + 1);
                try buf.print(allocator, " {d}", .{v});
            },
            .jmp, .jmp_if_false, .jmp_if_true => {
                const o = readI16(chunk.code, i + 1);
                const target: i64 = @as(i64, @intCast(i + 1 + 2)) + o;
                try buf.print(allocator, " {s}{d} -> {x:0>4}", .{
                    if (o >= 0) "+" else "",
                    o,
                    @as(u64, @intCast(target)),
                });
            },
            .jmp_if_strict_eq, .jmp_if_strict_neq, .jmp_if_not_lt, .jmp_if_not_le, .jmp_if_not_gt, .jmp_if_not_ge => {
                const r = chunk.code[i + 1];
                const o = readI16(chunk.code, i + 2);
                const target: i64 = @as(i64, @intCast(i + 1 + 3)) + o;
                try buf.print(allocator, " r{d} {s}{d} -> {x:0>4}", .{
                    r,
                    if (o >= 0) "+" else "",
                    o,
                    @as(u64, @intCast(target)),
                });
            },
            .loop_inc_lt => {
                const r_counter = chunk.code[i + 1];
                const r_bound = chunk.code[i + 2];
                const o = readI16(chunk.code, i + 3);
                const target: i64 = @as(i64, @intCast(i + 1 + 4)) + o;
                try buf.print(allocator, " r{d} r{d} {s}{d} -> {x:0>4}", .{
                    r_counter,
                    r_bound,
                    if (o >= 0) "+" else "",
                    o,
                    @as(u64, @intCast(target)),
                });
            },
            .make_function => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " t{d}", .{k});
            },
            .make_class => {
                const k = readU16(chunk.code, i + 1);
                const r_keys_base = chunk.code[i + 3];
                const inner_slot = chunk.code[i + 4];
                if (inner_slot == 0xff) {
                    try buf.print(allocator, " c{d} keys=r{d}", .{ k, r_keys_base });
                } else {
                    try buf.print(allocator, " c{d} keys=r{d} inner=s{d}", .{ k, r_keys_base, inner_slot });
                }
            },
            .super_get => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " k{d}", .{k});
            },
            .lda_private => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " k{d}", .{k});
            },
            .sta_private => {
                const k = readU16(chunk.code, i + 1);
                const r = chunk.code[i + 3];
                try buf.print(allocator, " k{d} r{d}", .{ k, r });
            },
            .super_call => {
                const r = chunk.code[i + 1];
                const argc = chunk.code[i + 2];
                try buf.print(allocator, " r{d} ({d} args)", .{ r, argc });
            },
            .call, .new_call => {
                const r = chunk.code[i + 1];
                const argc = chunk.code[i + 2];
                try buf.print(allocator, " r{d} ({d} args)", .{ r, argc });
            },
            .call0, .call1, .call2, .call3 => {
                const r = chunk.code[i + 1];
                const argc = @intFromEnum(op) - @intFromEnum(Op.call0);
                try buf.print(allocator, " r{d} ({d} args)", .{ r, argc });
            },
            .call_method => {
                const r_recv = chunk.code[i + 1];
                const r_callee = chunk.code[i + 2];
                const argc = chunk.code[i + 3];
                try buf.print(allocator, " r{d}.r{d} ({d} args)", .{ r_recv, r_callee, argc });
            },
            .call_forward_args => {
                const r_callee = chunk.code[i + 1];
                const r_thisarg = chunk.code[i + 2];
                try buf.print(allocator, " r{d} this=r{d}", .{ r_callee, r_thisarg });
            },
            .make_environment => {
                const n = chunk.code[i + 1];
                try buf.print(allocator, " {d} slots", .{n});
            },
            .lda_env, .sta_env => {
                const depth = chunk.code[i + 1];
                const slot = chunk.code[i + 2];
                try buf.print(allocator, " ^{d} s{d}", .{ depth, slot });
            },
            .lda_property => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " k{d}", .{k});
            },
            .sta_property, .def_property, .lda_property_reg => {
                const k = readU16(chunk.code, i + 1);
                const r = chunk.code[i + 3];
                try buf.print(allocator, " k{d} r{d}", .{ k, r });
            },
            .def_template_property => {
                const k = readU16(chunk.code, i + 1);
                const r = chunk.code[i + 3];
                const slot = readU16(chunk.code, i + 4);
                try buf.print(allocator, " k{d} r{d} s{d}", .{ k, r, slot });
            },
            .lda_computed => {
                const r = chunk.code[i + 1];
                const slot = readU16(chunk.code, i + 2);
                try buf.print(allocator, " r{d} ic{d}", .{ r, slot });
            },
            .in_op => {
                const r = chunk.code[i + 1];
                const slot = readU16(chunk.code, i + 2);
                try buf.print(allocator, " r{d} ic{d}", .{ r, slot });
            },
            .sta_computed => {
                const r_obj = chunk.code[i + 1];
                const r_key = chunk.code[i + 2];
                const slot = readU16(chunk.code, i + 3);
                try buf.print(allocator, " r{d}[r{d}] ic{d}", .{ r_obj, r_key, slot });
            },
            .def_computed => {
                const r_obj = chunk.code[i + 1];
                const r_key = chunk.code[i + 2];
                try buf.print(allocator, " r{d}[r{d}]", .{ r_obj, r_key });
            },
            .lda_global, .sta_global => {
                const k = readU16(chunk.code, i + 1);
                try buf.print(allocator, " k{d}", .{k});
            },
            .lda_global_slot, .sta_global_slot, .sta_global_slot_init => {
                const slot = readU32(chunk.code, i + 1);
                try buf.print(allocator, " s{d}", .{slot});
            },
            .capture_unresolved_global, .sta_global_strict => {
                const k = readU16(chunk.code, i + 1);
                const r = chunk.code[i + 3];
                try buf.print(allocator, " k{d} r{d}", .{ k, r });
            },
            else => {}, // 0-operand
        }

        // Append the source span, if we recorded one for this offset.
        while (sp_index < chunk.source_positions.len and chunk.source_positions[sp_index].offset < i) : (sp_index += 1) {}
        if (sp_index < chunk.source_positions.len and chunk.source_positions[sp_index].offset == i) {
            const span = chunk.source_positions[sp_index].span;
            try buf.print(allocator, " [{d}..{d}]", .{ span.start, span.end });
        }

        i += 1 + operand_size;
    }
    try buf.append(allocator, '\n');
    try buf.append(allocator, ')');

    // Recurse into nested function templates. `MakeFunction t<N>`
    // references `chunk.function_templates[N]`; dumping them inline
    // lets a `--dump-bytecode` reader see the body of every
    // declared function in a single pass instead of having to
    // re-run the engine to introspect.
    for (chunk.function_templates, 0..) |*tpl, idx| {
        try buf.print(allocator, "\n\n; --- function template t{d}", .{idx});
        if (tpl.name) |n| try buf.print(allocator, " ({s})", .{n});
        try buf.print(allocator, " — {d} params, spec_length {d}", .{ tpl.param_count, tpl.spec_length });
        if (tpl.is_arrow) try buf.appendSlice(allocator, ", arrow");
        if (tpl.is_method) try buf.appendSlice(allocator, ", method");
        if (tpl.is_generator) try buf.appendSlice(allocator, ", generator");
        if (tpl.is_async) try buf.appendSlice(allocator, ", async");
        try buf.append(allocator, '\n');
        const inner = try dump(allocator, &tpl.chunk);
        defer allocator.free(inner);
        try buf.appendSlice(allocator, inner);
    }

    return buf.toOwnedSlice(allocator);
}

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn readI16(code: []const u8, at: usize) i16 {
    return @bitCast(readU16(code, at));
}

fn readU32(code: []const u8, at: usize) u32 {
    return @as(u32, code[at]) |
        (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) |
        (@as(u32, code[at + 3]) << 24);
}

fn readI32(code: []const u8, at: usize) i32 {
    const u: u32 = @as(u32, code[at]) |
        (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) |
        (@as(u32, code[at + 3]) << 24);
    return @bitCast(u);
}

fn formatConstant(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: Value) !void {
    if (v.isInt32()) {
        try buf.print(allocator, "(int {d})", .{v.asInt32()});
    } else if (v.isDouble()) {
        try buf.print(allocator, "(double {d})", .{v.asDouble()});
    } else if (v.isString()) {
        try buf.appendSlice(allocator, "(string)");
    } else if (v.isObject()) {
        try buf.appendSlice(allocator, "(object)");
    } else if (v.isBool()) {
        try buf.print(allocator, "(bool {})", .{v.asBool()});
    } else if (v.isNull()) {
        try buf.appendSlice(allocator, "null");
    } else if (v.isUndefined()) {
        try buf.appendSlice(allocator, "undefined");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Builder = @import("chunk.zig").Builder;
const Span = @import("../source.zig").Span;

test "disasm: empty chunk" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=0 consts=0
        \\)
    , out);
}

test "disasm: LdaSmi + Return" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 2 };
    try b.emitOp(.lda_smi, span);
    try b.emitI32(42);
    try b.emitOp(.return_, span);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=0 consts=0
        \\  0000 LdaSmi 42 [0..2]
        \\  0005 Return [0..2]
        \\)
    , out);
}

test "disasm: LdaConstant prints the constant value" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 4 };
    const k = try b.addConstant(Value.fromDouble(1.5));
    try b.emitOp(.lda_constant, span);
    try b.emitU16(k);
    try b.emitOp(.return_, span);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=0 consts=1
        \\  0000 LdaConstant k0 (double 1.5) [0..4]
        \\  0003 Return [0..4]
        \\)
    , out);
}

test "disasm: register operands" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 5 };
    const r = try b.reserveRegister();
    try b.emitOp(.star, span);
    try b.emitU8(r);
    try b.emitOp(.ldar, span);
    try b.emitU8(r);
    try b.emitOp(.return_, span);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=1 consts=0
        \\  0000 Star r0 [0..5]
        \\  0002 Ldar r0 [0..5]
        \\  0004 Return [0..5]
        \\)
    , out);
}

test "disasm: global-lexical slot opcodes print the slot index" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 3 };
    try b.emitOp(.lda_global_slot, span);
    try b.emitU32(0);
    try b.emitOp(.sta_global_slot, span);
    try b.emitU32(2);
    try b.emitOp(.sta_global_slot_init, span);
    try b.emitU32(5);
    try b.emitOp(.return_, span);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=0 consts=0
        \\  0000 LdaGlobalSlot s0 [0..3]
        \\  0005 StaGlobalSlot s2 [0..3]
        \\  000a StaGlobalSlotInit s5 [0..3]
        \\  000f Return [0..3]
        \\)
    , out);
}

test "disasm: jump shows target address" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 5 };
    try b.emitOp(.jmp, span);
    const patch = b.here();
    try b.emitI16(0);
    try b.emitOp(.lda_undefined, span);
    const target = b.here();
    try b.emitOp(.return_, span);
    try b.patchI16(patch, target);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const out = try dump(testing.allocator, &chunk);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\(chunk regs=0 consts=0
        \\  0000 Jmp +1 -> 0004 [0..5]
        \\  0003 LdaUndefined [0..5]
        \\  0004 Return [0..5]
        \\)
    , out);
}
