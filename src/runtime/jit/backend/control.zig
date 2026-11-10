//! Non-allocating host polls at entry and backward edges. No language policy.
const std = @import("std");
const builtin = @import("builtin");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const call = @import("call.zig");
const scratch = @import("scratch.zig");
const fp_environment = @import("fp_environment.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;
const always = std.atomic.Value(bool).init(true);

pub const Control = struct {
    context: ?*anyopaque = null,
    /// Must not allocate, collect, re-enter language code, or retain arguments.
    poll_fn: *const fn (?*anyopaque) anyerror!void,
    /// Null polls every crossing. A false byte bypasses the callback entirely.
    wake_flag: ?*const std.atomic.Value(bool) = null,
};
pub const Invocation = struct {
    wake_flag: *const std.atomic.Value(bool),
    control: Control,
    failure: ?anyerror = null,

    pub fn init(control: Control) Invocation {
        return .{ .wake_flag = control.wake_flag orelse &always, .control = control };
    }
};

fn dispatch(invocation: *Invocation, _: [*]u64, _: u32) callconv(.c) u32 {
    invocation.control.poll_fn(invocation.control.context) catch |err| {
        invocation.failure = err;
        return 1;
    };
    return 0;
}

/// Every live edge value is already staged in transfer storage. No allocated
/// register may be live here; the caller reloads destination homes afterwards.
pub fn emit(m: *Machine, slot: usize, fp_slot: usize, failed: *Machine.Label) !void {
    var done: Machine.Label = .{};
    defer done.deinit(m.gpa);
    if (comptime is_x86) {
        try m.load64Disp32(.r11, .rdi, @intCast(slot * 8));
        try m.testReg64(.r11, .r11);
        try m.jumpCond(.equal, &done);
        try m.load64Disp32(.r11, .r11, @offsetOf(Invocation, "wake_flag"));
        // A byte load has acquire semantics under x86 TSO.
        try m.load8Disp32(.rax, .r11, 0);
        try m.testReg64(.rax, .rax);
        try m.jumpCond(.equal, &done);
    } else {
        try scratch.load(m, .x16, slot);
        try m.jumpCbz(.x16, &done);
        try m.emit(arm.ldrImm(.x16, .x16, @offsetOf(Invocation, "wake_flag")));
        try m.emit(arm.ldarb(.x16, .x16));
        try m.jumpCbz(.x16, &done);
    }
    try fp_environment.leave(m, fp_slot);
    try call.emitHelper(m, slot, 0, @intFromPtr(&dispatch));
    try fp_environment.reenter(m, fp_slot);
    if (comptime is_x86) {
        try m.testReg64(.rax, .rax);
        try m.jumpCond(.not_equal, failed);
    } else try m.jumpCbnz(.x2, failed);
    try m.bind(&done);
}
