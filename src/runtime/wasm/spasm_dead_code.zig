//! Validated-bytecode skipping shared by Spasm backends.
//!
//! An unconditional branch makes the remainder of its current structured
//! frame unreachable. Baseline compilers still have to find that frame's
//! closing `end` without mistaking instruction immediates for opcodes. Unknown
//! immediate forms refuse transactionally rather than desynchronizing.

const Op = @import("opcodes.zig").Op;
const ValType = @import("types.zig").ValType;
const std = @import("std");

pub const FrameBoundary = enum { else_arm, end };

/// Advance `index` through the `end` that closes the current control frame.
/// Nested block/loop/if frames are consumed in full. An outer `else` is part
/// of the frame and therefore skipped rather than returned to the caller.
pub fn skipToFrameEnd(body: []const u8, index: *usize) ?void {
    while (true) {
        switch (skipToFrameBoundary(body, index) orelse return null) {
            .else_arm => {},
            .end => return,
        }
    }
}

/// Advance to the next boundary of the current structured arm. Unlike
/// `skipToFrameEnd`, this exposes an outer `else` so a baseline compiler can
/// resume emission for the reachable alternative after a terminating
/// instruction in the then-arm.
pub fn skipToFrameBoundary(body: []const u8, index: *usize) ?FrameBoundary {
    var depth: usize = 0;
    while (index.* < body.len) {
        const op: Op = @enumFromInt(body[index.*]);
        index.* += 1;
        switch (op) {
            .block, .loop, .@"if" => {
                skipLeb(body, index, 5) orelse return null; // block type: s33
                depth += 1;
            },
            .end => {
                if (depth == 0) return .end;
                depth -= 1;
            },
            .@"else" => if (depth == 0) return .else_arm,
            .select_t => {
                const count = readUleb32(body, index) orelse return null;
                var item: u32 = 0;
                while (item < count) : (item += 1) skipValType(body, index) orelse return null;
            },
            .br,
            .br_if,
            .local_get,
            .local_set,
            .local_tee,
            .global_get,
            .global_set,
            .memory_size,
            .memory_grow,
            .call,
            .ref_func,
            .table_get,
            .table_set,
            => _ = readUleb32(body, index) orelse return null,
            .call_indirect => {
                _ = readUleb32(body, index) orelse return null;
                _ = readUleb32(body, index) orelse return null;
            },
            .br_table => {
                const count = readUleb32(body, index) orelse return null;
                var label: u32 = 0;
                while (label <= count) : (label += 1) {
                    _ = readUleb32(body, index) orelse return null;
                }
            },
            .i32_const => skipLeb(body, index, 5) orelse return null,
            .i64_const => skipLeb(body, index, 10) orelse return null,
            .f32_const => skipBytes(body, index, 4) orelse return null,
            .f64_const => skipBytes(body, index, 8) orelse return null,
            .ref_null => skipLeb(body, index, 5) orelse return null, // heap type: s33
            .prefix_fc => skipMiscImmediate(body, index) orelse return null,
            .prefix_fd => skipSimdImmediate(body, index) orelse return null,
            .i32_load,
            .i64_load,
            .f32_load,
            .f64_load,
            .i32_load8_s,
            .i32_load8_u,
            .i32_load16_s,
            .i32_load16_u,
            .i64_load8_s,
            .i64_load8_u,
            .i64_load16_s,
            .i64_load16_u,
            .i64_load32_s,
            .i64_load32_u,
            .i32_store,
            .i64_store,
            .f32_store,
            .f64_store,
            .i32_store8,
            .i32_store16,
            .i64_store8,
            .i64_store16,
            .i64_store32,
            => skipMemArg(body, index) orelse return null,
            .@"unreachable",
            .nop,
            .drop,
            .select,
            .@"return",
            .i32_eqz,
            .i32_clz,
            .i32_ctz,
            .i32_popcnt,
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_lt_u,
            .i32_gt_s,
            .i32_gt_u,
            .i32_le_s,
            .i32_le_u,
            .i32_ge_s,
            .i32_ge_u,
            .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            .i64_eqz,
            .i64_clz,
            .i64_ctz,
            .i64_popcnt,
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            .f32_copysign,
            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            .f64_copysign,
            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            .i32_wrap_i64,
            .i32_trunc_f32_s,
            .i32_trunc_f32_u,
            .i32_trunc_f64_s,
            .i32_trunc_f64_u,
            .i64_extend_i32_s,
            .i64_extend_i32_u,
            .i64_trunc_f32_s,
            .i64_trunc_f32_u,
            .i64_trunc_f64_s,
            .i64_trunc_f64_u,
            .f32_convert_i32_s,
            .f32_convert_i32_u,
            .f32_convert_i64_s,
            .f32_convert_i64_u,
            .f32_demote_f64,
            .f64_convert_i32_s,
            .f64_convert_i32_u,
            .f64_convert_i64_s,
            .f64_convert_i64_u,
            .f64_promote_f32,
            .i32_reinterpret_f32,
            .i64_reinterpret_f64,
            .f32_reinterpret_i32,
            .f64_reinterpret_i64,
            .i32_extend8_s,
            .i32_extend16_s,
            .i64_extend8_s,
            .i64_extend16_s,
            .i64_extend32_s,
            .ref_is_null,
            => {},
            else => return null,
        }
    }
    return null;
}

fn skipMiscImmediate(body: []const u8, index: *usize) ?void {
    const sub = readUleb32(body, index) orelse return null;
    switch (sub) {
        0...7 => {}, // saturating truncations
        8, 10, 12, 14 => {
            _ = readUleb32(body, index) orelse return null;
            _ = readUleb32(body, index) orelse return null;
        },
        9, 11, 13, 15, 16, 17 => _ = readUleb32(body, index) orelse return null,
        else => return null,
    }
}

fn skipSimdImmediate(body: []const u8, index: *usize) ?void {
    const sub = readUleb32(body, index) orelse return null;
    switch (sub) {
        12 => skipBytes(body, index, 16) orelse return null, // v128.const
        0, 11 => skipMemArg(body, index) orelse return null, // v128.load/store
        174 => {}, // i32x4.add
        else => return null,
    }
}

fn skipMemArg(body: []const u8, index: *usize) ?void {
    const flags = readUleb32(body, index) orelse return null;
    if (flags & 0x40 != 0) return null;
    _ = readUleb32(body, index) orelse return null;
}

fn skipValType(body: []const u8, index: *usize) ?void {
    if (index.* >= body.len) return null;
    const first = body[index.*];
    index.* += 1;
    if (ValType.fromByte(first) != null) return;
    if (first != 0x63 and first != 0x64) return null;
    skipLeb(body, index, 5) orelse return null;
}

fn skipBytes(body: []const u8, index: *usize, count: usize) ?void {
    if (index.* > body.len or count > body.len - index.*) return null;
    index.* += count;
}

fn skipLeb(body: []const u8, index: *usize, max_bytes: usize) ?void {
    var count: usize = 0;
    while (count < max_bytes and index.* < body.len) : (count += 1) {
        const byte = body[index.*];
        index.* += 1;
        if (byte & 0x80 == 0) return;
    }
    return null;
}

fn readUleb32(body: []const u8, index: *usize) ?u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (index.* < body.len) {
        const byte = body[index.*];
        index.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if (result > 0xffff_ffff) return null;
            return @intCast(result);
        }
        shift += 7;
        if (shift >= 35) return null;
    }
    return null;
}

test "skipToFrameEnd ignores opcode bytes inside immediates" {
    const body = [_]u8{
        @intFromEnum(Op.i32_const), 0x0b,
        @intFromEnum(Op.block),     0x40,
        @intFromEnum(Op.f64_const), 0x0b,
        0x05,                       0x0b,
        0x05,                       0x0b,
        0x05,                       0x0b,
        0x05,                       @intFromEnum(Op.end),
        @intFromEnum(Op.end),       @intFromEnum(Op.nop),
    };
    var index: usize = 0;
    try std.testing.expect(skipToFrameEnd(&body, &index) != null);
    try std.testing.expectEqual(body.len - 1, index);
}

test "skipToFrameEnd refuses a truncated immediate" {
    const body = [_]u8{ @intFromEnum(Op.i64_const), 0x80 };
    var index: usize = 0;
    try std.testing.expect(skipToFrameEnd(&body, &index) == null);
    try std.testing.expectEqual(body.len, index);
}

test "skipToFrameBoundary stops at the current if arm" {
    const body = [_]u8{
        @intFromEnum(Op.block),     0x40,
        @intFromEnum(Op.i32_const), 0x05,
        @intFromEnum(Op.end),       @intFromEnum(Op.@"else"),
        @intFromEnum(Op.i32_const), 0x0b,
        @intFromEnum(Op.end),
    };
    var index: usize = 0;
    try std.testing.expectEqual(FrameBoundary.else_arm, skipToFrameBoundary(&body, &index).?);
    try std.testing.expectEqual(@as(usize, 6), index);
    try std.testing.expectEqual(FrameBoundary.end, skipToFrameBoundary(&body, &index).?);
    try std.testing.expectEqual(body.len, index);
}
