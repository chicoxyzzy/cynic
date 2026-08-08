//! Small x86_64 lowering primitives shared by compact leaves and CFG codegen.

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");
const Value = @import("../value.zig").Value;
const deopt_physical = @import("deopt_physical.zig");
const frame_recovery = @import("frame_recovery.zig");
const ir = @import("ir.zig");

pub const Range = struct {
    start: usize,
    len: usize,
};

pub fn nodeInputs(graph: *const ir.Graph, node: ir.Node) !Range {
    const start: usize = @intCast(node.input_start);
    const len: usize = @intCast(node.input_count);
    if (start > graph.inputs.len or len > graph.inputs.len - start) {
        return error.MalformedGraph;
    }
    return .{ .start = start, .len = len };
}

pub const FrameLocation = frame_recovery.Location;
pub const frame_move_scratch: x86.Reg = .rax;
pub const frame_cycle_scratch: x86.Reg = .r11;

pub fn emitFrameMove(
    machine: *x86.Masm,
    move: frame_recovery.Move,
) !void {
    switch (move.source) {
        .frame => |source| try emitFrameLoad(
            machine,
            source,
            frame_move_scratch,
        ),
        .cycle_scratch => try machine.movReg64(
            frame_move_scratch,
            frame_cycle_scratch,
        ),
    }
    try emitFrameStore(machine, move.destination, frame_move_scratch);
}

pub fn emitFrameLoad(
    machine: *x86.Masm,
    source: FrameLocation,
    destination: x86.Reg,
) !void {
    switch (source) {
        .accumulator => try machine.load64Disp32(
            destination,
            .rsi,
            layout.frame.accumulator,
        ),
        .register => |register| try machine.load64Disp32(
            destination,
            .rdx,
            try registerOffset(register),
        ),
    }
}

pub fn emitFrameStore(
    machine: *x86.Masm,
    destination: FrameLocation,
    source: x86.Reg,
) !void {
    switch (destination) {
        .accumulator => try machine.store64Disp32(
            .rsi,
            layout.frame.accumulator,
            source,
        ),
        .register => |register| try machine.store64Disp32(
            .rdx,
            try registerOffset(register),
            source,
        ),
    }
}

pub fn registerOffset(register: u8) !i32 {
    return std.math.cast(i32, @as(usize, register) * @sizeOf(Value)) orelse
        error.MalformedGraph;
}

pub fn immediateValueBits(
    chunk: *const Chunk,
    immediate: ir.Immediate,
) !u64 {
    return switch (immediate) {
        .undefined_ => Value.undefined_.bits,
        .null_ => Value.null_.bits,
        .true_ => Value.true_.bits,
        .false_ => Value.false_.bits,
        .hole => Value.hole_.bits,
        .int32 => |value| Value.fromInt32(value).bits,
        .constant_pool => |index| blk: {
            if (index >= chunk.constants.len) return error.MalformedGraph;
            const value = chunk.constants[index];
            if (value.isHeapValue()) return error.UnsupportedConstant;
            break :blk value.bits;
        },
    };
}

pub fn emitFrameState(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    point: deopt_physical.DecodedPoint,
) !void {
    var plan = try frame_recovery.Plan.build(allocator, point);
    defer plan.deinit();
    for (plan.steps) |step| switch (step) {
        .save_cycle => |source| try emitFrameLoad(
            machine,
            source,
            frame_cycle_scratch,
        ),
        .move => |move| try emitFrameMove(machine, move),
    };
    for (plan.externals) |external| {
        const immediate = switch (external.recovery) {
            .frame_accumulator, .frame_register => continue,
            .immediate => |value| value,
            .tagged_stack, .int32_stack => return error.UnsupportedGraph,
        };
        try machine.movImm64(
            frame_move_scratch,
            try immediateValueBits(chunk, immediate),
        );
        try emitFrameStore(
            machine,
            external.destination,
            frame_move_scratch,
        );
    }
}
