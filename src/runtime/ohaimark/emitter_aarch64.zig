//! Low-level AArch64 frame, move, and immediate-return emission for Ohaimark.
//!
//! This module preserves every callee-saved register claimed by the lowering
//! convention, pins the entry ABI, reserves the aligned spill area, initializes
//! tagged slots, and emits representation-bearing physical moves. Verified CFG
//! scheduling and guard exits live in `codegen_aarch64.zig`.

const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const Masm = @import("../jit/masm.zig").Masm;
const Value = @import("../value.zig").Value;
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const parallel_moves = @import("parallel_moves.zig");
const representation = @import("representation.zig");

const max_stack_adjust: u32 = 4_080;

pub fn emitPrologue(machine: *Masm, frame: lowering.FrameLayout) !void {
    try frame.verify();
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);

    try machine.emit(a64.stpPreIdxSp(.fp, .lr, -16));
    try machine.emit(a64.addRegSp(.fp, 0));
    try machine.emit(a64.stpPreIdxSp(.x19, .x20, -16));
    try machine.emit(a64.stpPreIdxSp(.x21, .x22, -16));
    try machine.emit(a64.stpPreIdxSp(.x23, .x24, -16));
    try machine.emit(a64.stpPreIdxSp(.x25, .x26, -16));
    try machine.emit(a64.stpPreIdxSp(.x27, .x28, -16));
    try adjustStack(machine, frame.spill_bytes, .reserve);
    try machine.emit(a64.addRegSp(lowering.spill_base_register, 0));
    try machine.emit(a64.movReg(lowering.realm_register, .x0));
    try machine.emit(a64.movReg(lowering.lantern_frame_register, .x1));
    try machine.emit(a64.movReg(lowering.lantern_registers_register, .x2));

    if (frame.tagged_slot_count != 0) {
        try machine.movImm64(lowering.transfer_scratch, Value.undefined_.bits);
        for (0..frame.tagged_slot_count) |slot| {
            const byte_offset: u15 = @intCast(try frame.taggedByteOffset(@intCast(slot)));
            try machine.emit(a64.strImm(
                lowering.transfer_scratch,
                lowering.spill_base_register,
                byte_offset,
            ));
        }
    }
}

pub fn emitEpilogue(machine: *Masm, frame: lowering.FrameLayout) !void {
    try frame.verify();
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);

    try adjustStack(machine, frame.spill_bytes, .release);
    try machine.emit(a64.ldpPostIdxSp(.x27, .x28, 16));
    try machine.emit(a64.ldpPostIdxSp(.x25, .x26, 16));
    try machine.emit(a64.ldpPostIdxSp(.x23, .x24, 16));
    try machine.emit(a64.ldpPostIdxSp(.x21, .x22, 16));
    try machine.emit(a64.ldpPostIdxSp(.x19, .x20, 16));
    try machine.emit(a64.ldpPostIdxSp(.fp, .lr, 16));
    try machine.emit(a64.ret());
}

pub fn emitMove(
    machine: *Masm,
    move: parallel_moves.Move,
    constants: []const Value,
) !void {
    parallel_moves.validateTypes(move) catch return error.InvalidMove;
    if (usesEmitterScratch(move.source) or usesEmitterScratch(move.destination)) {
        return error.InvalidMove;
    }
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);

    const destination_register: a64.Reg = switch (move.destination) {
        .register => |register| register,
        .tagged_stack, .int32_stack => lowering.transfer_scratch,
        .none, .immediate => return error.InvalidMove,
    };
    try loadSource(machine, move.source, move.source_kind, constants, destination_register);
    switch (move.conversion) {
        .none => {},
        .box_int32 => {
            const int32_tag_bits = @as(u64, Value.tag_int32) << 48;
            try machine.movImm64(lowering.boxing_scratch, int32_tag_bits);
            try machine.emit(a64.orrReg(
                destination_register,
                destination_register,
                lowering.boxing_scratch,
            ));
        },
        .check_int32 => return error.InvalidMove,
    }
    try storeDestination(machine, move.destination, move.destination_kind, destination_register);
}

/// Emit the first executable graph subset: a return whose producer was
/// rematerialized by specialization. Non-immediate values wait for general
/// node scheduling and entry/edge materialization.
pub fn emitConstantReturn(
    machine: *Masm,
    frame: lowering.FrameLayout,
    source: parallel_moves.Location,
    source_kind: representation.Kind,
    conversion: representation.Conversion,
    constants: []const Value,
) !void {
    if (source != .immediate) return error.UnsupportedNode;
    const move: parallel_moves.Move = .{
        .source = source,
        .destination = .{ .register = .x0 },
        .source_kind = source_kind,
        .destination_kind = .tagged,
        .conversion = conversion,
    };
    parallel_moves.validateTypes(move) catch return error.InvalidMove;
    try frame.verify();
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);
    try emitPrologue(machine, frame);
    try emitMove(machine, move, constants);
    try emitEpilogue(machine, frame);
}

fn loadSource(
    machine: *Masm,
    source: parallel_moves.Location,
    kind: representation.Kind,
    constants: []const Value,
    destination: a64.Reg,
) !void {
    switch (source) {
        .none => return error.InvalidMove,
        .immediate => |immediate| try machine.movImm64(
            destination,
            try immediateBits(immediate, kind, constants),
        ),
        .register => |register| {
            if (register != destination) try machine.emit(a64.movReg(destination, register));
        },
        .tagged_stack => |offset| try machine.emit(a64.ldrImm(
            destination,
            lowering.spill_base_register,
            try taggedOffset(offset),
        )),
        .int32_stack => |offset| try machine.emit(a64.ldrImmW(
            destination,
            lowering.spill_base_register,
            try int32Offset(offset),
        )),
    }
}

fn storeDestination(
    machine: *Masm,
    destination: parallel_moves.Location,
    kind: representation.Kind,
    source: a64.Reg,
) !void {
    switch (destination) {
        .none, .immediate => return error.InvalidMove,
        .register => {},
        .tagged_stack => |offset| {
            if (kind != .tagged) return error.InvalidMove;
            try machine.emit(a64.strImm(
                source,
                lowering.spill_base_register,
                try taggedOffset(offset),
            ));
        },
        .int32_stack => |offset| {
            if (kind != .int32) return error.InvalidMove;
            try machine.emit(a64.strImmW(
                source,
                lowering.spill_base_register,
                try int32Offset(offset),
            ));
        },
    }
}

fn immediateBits(
    immediate: ir.Immediate,
    kind: representation.Kind,
    constants: []const Value,
) !u64 {
    return switch (kind) {
        .none => error.InvalidMove,
        .int32 => switch (immediate) {
            .int32 => |value| @as(u32, @bitCast(value)),
            else => error.InvalidMove,
        },
        .tagged => switch (immediate) {
            .undefined_ => Value.undefined_.bits,
            .null_ => Value.null_.bits,
            .true_ => Value.true_.bits,
            .false_ => Value.false_.bits,
            .hole => Value.hole_.bits,
            .int32 => error.InvalidMove,
            .constant_pool => |index| blk: {
                if (index >= constants.len) return error.InvalidMove;
                const value = constants[index];
                if (value.isHeapValue()) return error.UnsupportedConstant;
                break :blk value.bits;
            },
        },
    };
}

fn usesEmitterScratch(location: parallel_moves.Location) bool {
    return switch (location) {
        .register => |register| register == lowering.transfer_scratch or
            register == lowering.boxing_scratch,
        .none, .immediate, .tagged_stack, .int32_stack => false,
    };
}

fn taggedOffset(offset: u32) !u15 {
    if (offset > 32_760 or offset % 8 != 0) return error.InvalidMove;
    return @intCast(offset);
}

fn int32Offset(offset: u32) !u14 {
    if (offset > 16_380 or offset % 4 != 0) return error.InvalidMove;
    return @intCast(offset);
}

const StackAdjustment = enum {
    reserve,
    release,
};

fn adjustStack(machine: *Masm, byte_count: u32, direction: StackAdjustment) !void {
    if (byte_count % 16 != 0) return error.InvalidLowering;
    var remaining = byte_count;
    while (remaining != 0) {
        const chunk: u12 = @intCast(@min(remaining, max_stack_adjust));
        try machine.emit(switch (direction) {
            .reserve => a64.subSpImm(chunk),
            .release => a64.addSpImm(chunk),
        });
        remaining -= chunk;
    }
}

comptime {
    std.debug.assert(lowering.callee_save_bytes == 6 * 16);
}
