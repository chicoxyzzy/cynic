//! Runtime boundary for the shared backend. No language objects or GC policy.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const memory = @import("memory.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub const saved_registers_offset = 1;
pub const captures_offset = saved_registers_offset + 4;
pub const slot_count = captures_offset + ir.max_arguments;
pub const emit_loads = if (is_x86) 3 else 5;
pub const emit_stores = if (is_x86) 2 else 4;
pub const Site = struct {
    target: u32,
    site: u32,
    safepoint: u32,
    argument_count: usize,
    capture_count: usize,
    parameter_types: [ir.max_arguments]ir.Type = @splat(.i64),
    result_type: ?ir.Type,
};
pub const Request = struct {
    target: u32,
    site: u32,
    safepoint: u32,
    arguments: []const u64,
    parameter_types: []const ir.Type,
    result_type: ?ir.Type,
    captures: []const u64,
    /// Refresh descriptors here if the callback grows or replaces a store.
    memories: []memory.View,
};
pub const Runtime = struct {
    context: ?*anyopaque = null,
    /// Root frontend-owned references before allocation or language re-entry.
    /// Snapshots are borrowed for this call only and must not be retained.
    call: *const fn (?*anyopaque, Request) anyerror!u64,
};
pub const Invocation = struct {
    runtime: Runtime,
    sites: []const Site,
    memories: []memory.View,
    transfer_base: usize,
    call_base: usize,
    failure: ?anyerror = null,
};

fn dispatch(invocation: *Invocation, slots: [*]u64, index: u32) callconv(.c) u32 {
    if (index >= invocation.sites.len) {
        invocation.failure = error.InvalidNativeResult;
        return 1;
    }
    const site = invocation.sites[index];
    const result = invocation.runtime.call(invocation.runtime.context, .{
        .target = site.target,
        .site = site.site,
        .safepoint = site.safepoint,
        .arguments = slots[invocation.transfer_base..][0..site.argument_count],
        .parameter_types = site.parameter_types[0..site.argument_count],
        .result_type = site.result_type,
        .captures = slots[invocation.call_base + captures_offset ..][0..site.capture_count],
        .memories = invocation.memories,
    }) catch |err| {
        invocation.failure = err;
        return 1;
    };
    slots[invocation.transfer_base + ir.max_arguments] = result;
    return 0;
}

/// Inputs and live registers already reside in invocation scratch. Preserve
/// the scratch pointer, block budget, and return address over the C ABI call.
pub fn emit(m: *Machine, base: usize, index: u32) !void {
    if (comptime is_x86) {
        // SysV entry RSP is 8 mod 16; 24 bytes align the outbound call.
        try m.subRegImm32(.rsp, 24);
        try m.store64Disp32(.rsp, 0, .rdi);
        try m.store64Disp32(.rsp, 8, .rsi);
        try m.movReg64(.rsi, .rdi);
        try m.load64Disp32(.rdi, .rdi, @intCast(base * 8));
        try m.movImm32(.rdx, index);
        try m.movImm64(.r11, @intFromPtr(&dispatch));
        try m.callReg(.r11);
        try m.load64Disp32(.rdi, .rsp, 0);
        try m.load64Disp32(.rsi, .rsp, 8);
        try m.addRegImm32(.rsp, 24);
    } else {
        try m.emit(arm.stpPreIdxSp(.x0, .lr, -16));
        try m.emit(arm.stpPreIdxSp(.x1, .fp, -16));
        try m.emit(arm.movReg(.x1, .x0));
        try m.emit(arm.ldrImm(.x0, .x0, @intCast(base * 8)));
        try m.movImm64(.x2, index);
        try m.movImm64(.x16, @intFromPtr(&dispatch));
        try m.emit(arm.blr(.x16));
        try m.emit(arm.movReg(.x2, .x0));
        try m.emit(arm.ldpPostIdxSp(.x1, .fp, 16));
        try m.emit(arm.ldpPostIdxSp(.x0, .lr, 16));
    }
}
