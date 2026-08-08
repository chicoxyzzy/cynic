//! Target-independent compact call/construct handoff.
//!
//! Generated code stages an exact Lantern frame before calling these helpers.
//! They revalidate weak IC facts, admit only ordinary bytecode functions, and
//! append a child frame without running JavaScript. Every miss is
//! transactional and returns `tier_down` for replay by Lantern.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const CallICCell = chunk_mod.CallICCell;
const Chunk = chunk_mod.Chunk;
const Op = @import("../../bytecode/op.zig").Op;
const call_mod = @import("../lantern/call.zig");
const lantern = @import("../lantern/interpreter.zig");
const JSFunction = @import("../function.zig").JSFunction;
const heap_mod = @import("../heap.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");

pub const no_this_register: u64 = std.math.maxInt(u64);

inline fn directCallTierDown() u32 {
    return @intFromEnum(call_mod.JitPushStatus.tier_down);
}

const MonomorphicCall = struct {
    callee: *JSFunction,
    cell: *const CallICCell,
    args_start: usize,
    argc: u8,
};

const MonomorphicPropertyCall = struct {
    callee: *JSFunction,
    this_bits: u64,
    args_start: usize,
    argc: u8,
};

fn monomorphicCall(
    frame: *lantern.CallFrame,
    callee_raw: u64,
    argc_raw: u64,
    feedback_raw: u64,
) ?MonomorphicCall {
    const callee = std.math.cast(u8, callee_raw) orelse return null;
    const argc = std.math.cast(u8, argc_raw) orelse return null;
    const feedback_index = std.math.cast(u16, feedback_raw) orelse return null;
    const callee_index: usize = callee;
    const args_start = callee_index + 1;
    const args_end = args_start + @as(usize, argc);
    if (callee_index >= frame.registers.len or
        args_end > frame.registers.len or
        feedback_index >= frame.chunk.inline_call_caches.len)
    {
        return null;
    }
    const callee_fn = heap_mod.valueAsFunction(frame.registers[callee]) orelse
        return null;
    const cell = &frame.chunk.inline_call_caches[feedback_index];
    const cached = cell.callee orelse return null;
    if (cached != callee_fn) return null;
    return .{
        .callee = callee_fn,
        .cell = cell,
        .args_start = args_start,
        .argc = argc,
    };
}

fn monomorphicPropertyCall(
    realm: *Realm,
    frame: *lantern.CallFrame,
    receiver_raw: u64,
    argc_raw: u64,
    load_feedback_raw: u64,
    call_feedback_raw: u64,
) ?MonomorphicPropertyCall {
    const receiver_register = std.math.cast(u8, receiver_raw) orelse return null;
    const argc = std.math.cast(u8, argc_raw) orelse return null;
    const load_feedback = std.math.cast(u16, load_feedback_raw) orelse return null;
    const call_feedback = std.math.cast(u16, call_feedback_raw) orelse return null;
    const receiver_index: usize = receiver_register;
    const args_start = std.math.add(usize, receiver_index, 1) catch return null;
    const args_end = std.math.add(usize, args_start, @as(usize, argc)) catch
        return null;
    const load_index = std.math.cast(usize, load_feedback) orelse return null;
    const call_index = std.math.cast(usize, call_feedback) orelse return null;
    if (receiver_index >= frame.registers.len or
        args_end > frame.registers.len or
        load_index >= frame.chunk.inline_load_caches.len or
        call_index >= frame.chunk.inline_call_caches.len)
    {
        return null;
    }

    const this_value = frame.registers[receiver_index];
    const receiver = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const load_cell = &frame.chunk.inline_load_caches[load_index];
    const receiver_shape = load_cell.shape orelse return null;
    if (load_cell.kind != .data or receiver_shape != receiver.shape) return null;
    const slot = std.math.cast(usize, load_cell.slot) orelse return null;
    const callee_value = if (load_cell.proto) |proto| blk: {
        if (receiver.prototype != proto or
            proto.shape != load_cell.proto_shape or
            load_cell.proto_rev != realm.proto_revision_counter or
            slot >= proto.slotCount())
        {
            return null;
        }
        break :blk proto.slotAt(slot);
    } else blk: {
        if (slot >= receiver.slotCount()) return null;
        break :blk receiver.slotAt(slot);
    };
    const callee = heap_mod.valueAsFunction(callee_value) orelse return null;
    const call_cell = &frame.chunk.inline_call_caches[call_index];
    const cached = call_cell.callee orelse return null;
    if (cached != callee) return null;
    return .{
        .callee = callee,
        .this_bits = this_value.bits,
        .args_start = args_start,
        .argc = argc,
    };
}

pub fn pushMonomorphicDirectCall(
    realm: *Realm,
    frame: *lantern.CallFrame,
    this_register_raw: u64,
    callee_raw: u64,
    argc_raw: u64,
    feedback_raw: u64,
) callconv(.c) u32 {
    const this_register: ?u8 = if (this_register_raw == no_this_register)
        null
    else
        std.math.cast(u8, this_register_raw) orelse return directCallTierDown();
    if (this_register) |receiver| {
        if (@as(usize, receiver) >= frame.registers.len) {
            return directCallTierDown();
        }
    }
    const site = monomorphicCall(
        frame,
        callee_raw,
        argc_raw,
        feedback_raw,
    ) orelse return directCallTierDown();
    if (!directCallEligible(site.callee)) return directCallTierDown();
    const this_bits = if (this_register) |receiver|
        frame.registers[receiver].bits
    else
        Value.undefined_.bits;
    return call_mod.pushJitDirectCallFrame(
        realm,
        site.callee,
        this_bits,
        frame.registers.ptr + site.args_start,
        site.argc,
    );
}

pub fn pushMonomorphicPropertyCall(
    realm: *Realm,
    frame: *lantern.CallFrame,
    receiver_raw: u64,
    argc_raw: u64,
    load_feedback_raw: u64,
    call_feedback_raw: u64,
) callconv(.c) u32 {
    const site = monomorphicPropertyCall(
        realm,
        frame,
        receiver_raw,
        argc_raw,
        load_feedback_raw,
        call_feedback_raw,
    ) orelse return directCallTierDown();
    if (!directCallEligible(site.callee)) return directCallTierDown();
    return call_mod.pushJitDirectCallFrame(
        realm,
        site.callee,
        site.this_bits,
        frame.registers.ptr + site.args_start,
        site.argc,
    );
}

pub fn pushMonomorphicConstruct(
    realm: *Realm,
    frame: *lantern.CallFrame,
    ignored_this_register_raw: u64,
    callee_raw: u64,
    argc_raw: u64,
    feedback_raw: u64,
) callconv(.c) u32 {
    _ = ignored_this_register_raw;
    const site = monomorphicCall(
        frame,
        callee_raw,
        argc_raw,
        feedback_raw,
    ) orelse return directCallTierDown();
    if (!directConstructEligible(site.callee) or
        site.cell.proto != site.callee.prototype)
    {
        return directCallTierDown();
    }
    return call_mod.pushJitConstructFrame(
        realm,
        site.cell,
        site.callee,
        frame.registers.ptr + site.args_start,
        site.argc,
    );
}

fn directCallEligible(callee: *const JSFunction) bool {
    return callee.chunk != null and
        callee.native_callback == null and
        !callee.is_generator and
        !callee.is_async and
        callee.bound_target == null and
        callee.wrapped_target.isUndefined() and
        !callee.is_class_constructor and
        callee.revocable_proxy == null and
        callee.synth_accessor == null;
}

fn directConstructEligible(callee: *const JSFunction) bool {
    return callee.chunk != null and
        callee.native_callback == null and
        !callee.is_arrow and
        callee.has_construct and
        !callee.is_generator and
        !callee.is_async and
        callee.bound_target == null and
        callee.wrapped_target.isUndefined() and
        callee.revocable_proxy == null and
        callee.synth_accessor == null;
}

pub fn afterBytecode(
    chunk: *const Chunk,
    bytecode_offset: u32,
    site: ir.DirectCallSite,
) !u32 {
    const pc = std.math.cast(usize, bytecode_offset) orelse
        return error.InvalidMetadata;
    if (pc >= chunk.code.len) return error.InvalidMetadata;
    const op: Op = @enumFromInt(chunk.code[pc]);
    const after = std.math.add(usize, pc, 1 + Op.operandSize(op)) catch
        return error.InvalidMetadata;
    if (after > chunk.code.len) return error.InvalidMetadata;
    switch (site) {
        .direct => |direct| {
            const kind: ir.DirectCall.Kind = switch (op) {
                .call_method8,
                .call8,
                .call0_8,
                .call1_8,
                .call2_8,
                .call3_8,
                => .call,
                .new_call8 => .construct,
                else => return error.InvalidMetadata,
            };
            const expects_receiver = op == .call_method8;
            if (direct.kind != kind or
                ((direct.this_register != null) != expects_receiver))
            {
                return error.InvalidMetadata;
            }
        },
        .property => |property| {
            const load_feedback = std.math.cast(
                u8,
                property.load_feedback_index,
            ) orelse return error.InvalidMetadata;
            const call_feedback = std.math.cast(
                u8,
                property.call_feedback_index,
            ) orelse return error.InvalidMetadata;
            if (op != .call_property8 or
                chunk.code[pc + 2] != property.receiver or
                chunk.code[pc + 3] != property.argc or
                chunk.code[pc + 4] != load_feedback or
                chunk.code[pc + 5] != call_feedback)
            {
                return error.InvalidMetadata;
            }
        },
    }
    return std.math.cast(u32, after) orelse error.InvalidMetadata;
}

pub fn validateRoots(
    point: deopt_physical.DecodedPoint,
    site: ir.DirectCallSite,
) !void {
    var rooted: [256]bool = @splat(false);
    for (point.slots) |slot| rooted[slot.register] = true;
    switch (site) {
        .direct => |direct| {
            if (direct.this_register) |receiver| {
                if (!rooted[receiver]) return error.InvalidMetadata;
            }
            try validateWindow(&rooted, direct.callee, direct.argc);
        },
        .property => |property| {
            try validateWindow(&rooted, property.receiver, property.argc);
        },
    }
}

fn validateWindow(rooted: *const [256]bool, base: u8, argc: u8) !void {
    if (!rooted[base]) return error.InvalidMetadata;
    const args_start = @as(usize, base) + 1;
    const args_end = args_start + @as(usize, argc);
    if (args_end > rooted.len) return error.InvalidMetadata;
    for (args_start..args_end) |register| {
        if (!rooted[register]) return error.InvalidMetadata;
    }
}

test "call handoff validates the complete rooted operand window" {
    var slots = [_]deopt_physical.Slot{
        .{ .register = 0, .recovery = .{ .frame_register = 0 } },
        .{ .register = 1, .recovery = .{ .frame_register = 1 } },
        .{ .register = 2, .recovery = .{ .frame_register = 2 } },
        .{ .register = 3, .recovery = .{ .frame_register = 3 } },
    };
    const point: deopt_physical.DecodedPoint = .{
        .allocator = std.testing.allocator,
        .bytecode_offset = 4,
        .accumulator = .frame_accumulator,
        .slots = &slots,
    };
    const site: ir.DirectCallSite = .{ .direct = .{
        .kind = .call,
        .this_register = 0,
        .callee = 1,
        .argc = 2,
        .feedback_index = 0,
    } };
    try validateRoots(point, site);

    var missing = point;
    missing.slots = slots[0..3];
    try std.testing.expectError(error.InvalidMetadata, validateRoots(missing, site));
}
