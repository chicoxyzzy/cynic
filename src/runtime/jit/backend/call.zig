//! Runtime boundary for the shared backend. No language objects or GC policy.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const memory = @import("memory.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub const saved_registers_offset = 1;
pub const saved_vectors_offset = saved_registers_offset + 4;
pub const captures_offset = saved_vectors_offset + 8;
pub const slot_count = captures_offset + ir.max_arguments;
pub const emit_loads = if (is_x86) 3 else 5;
pub const emit_stores = if (is_x86) 2 else 4;
pub const Site = struct {
    target: u64,
    site: u32,
    safepoint: u32,
    can_catch: bool = false,
    /// Payload lengths count 64-bit words; type lengths count logical values.
    argument_count: usize,
    capture_count: usize,
    result_count: usize,
    parameter_count: usize,
    result_type_count: usize,
    parameter_types: [ir.max_arguments]ir.Type = @splat(.i64),
    result_types: [ir.max_arguments]ir.Type = @splat(.i64),

    pub fn init(graph: ir.Graph, runtime_call: ir.Call, site: u32, can_catch: bool) Site {
        var result: Site = .{ .target = runtime_call.target, .site = site, .safepoint = runtime_call.safepoint.id, .can_catch = can_catch, .argument_count = ir.wordCount(runtime_call.parameter_types), .capture_count = graph.valueWords(runtime_call.safepoint.values), .result_count = ir.wordCount(runtime_call.result_types), .parameter_count = runtime_call.parameter_types.len, .result_type_count = runtime_call.result_types.len };
        @memcpy(result.parameter_types[0..runtime_call.parameter_types.len], runtime_call.parameter_types);
        @memcpy(result.result_types[0..runtime_call.result_types.len], runtime_call.result_types);
        return result;
    }
};
pub const Request = struct {
    target: u64,
    site: u32,
    safepoint: u32,
    /// Low word then high word for v128; scalar values occupy one word.
    arguments: []const u64,
    parameter_types: []const ir.Type,
    result_types: []const ir.Type,
    /// Fill every result. Separate from inputs; published only on success.
    results: []u64,
    captures: []const u64,
    /// Refresh descriptors here if the callback grows or replaces a store.
    memories: []memory.View,
};
pub const Runtime = struct {
    context: ?*anyopaque = null,
    /// Root frontend-owned references before allocation or language re-entry.
    /// Snapshots are borrowed for this call only and must not be retained.
    call: *const fn (?*anyopaque, Request) anyerror!void,
    /// Only invoke sites classify failed calls. True means frontend-owned
    /// exception state is ready for the handler; false propagates the error.
    /// Re-root the borrowed captures before allocating/re-entering here too.
    /// Failed call results are not valid and are never published.
    catch_exception: ?*const fn (?*anyopaque, Request, anyerror) anyerror!bool = null,
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
    // Borrow signature arrays instead of retaining a full metadata copy on
    // every recursive native call's host stack.
    const site = &invocation.sites[index];
    var results: [ir.max_arguments]u64 = @splat(0);
    const request: Request = .{
        .target = site.target,
        .site = site.site,
        .safepoint = site.safepoint,
        .arguments = slots[invocation.transfer_base..][0..site.argument_count],
        .parameter_types = site.parameter_types[0..site.parameter_count],
        .result_types = site.result_types[0..site.result_type_count],
        .results = results[0..site.result_count],
        .captures = slots[invocation.call_base + captures_offset ..][0..site.capture_count],
        .memories = invocation.memories,
    };
    invocation.runtime.call(invocation.runtime.context, request) catch |err| {
        if (site.can_catch) if (invocation.runtime.catch_exception) |classify| {
            const handled = classify(invocation.runtime.context, request, err) catch |failure| {
                invocation.failure = failure;
                return 1;
            };
            if (handled) return 2;
        };
        invocation.failure = err;
        return 1;
    };
    @memcpy(slots[invocation.transfer_base..][0..site.result_count], results[0..site.result_count]);
    return 0;
}

/// Inputs and live registers already reside in invocation scratch. Preserve
/// the scratch pointer, block budget, and return address over the C ABI call.
pub fn emit(m: *Machine, base: usize, index: u32) !void {
    return emitHelper(m, base, index, @intFromPtr(&dispatch));
}

pub fn emitHelper(m: *Machine, base: usize, index: u32, helper: usize) !void {
    if (comptime is_x86) {
        // SysV entry RSP is 8 mod 16; 24 bytes align the outbound call.
        try m.subRegImm32(.rsp, 24);
        try m.store64Disp32(.rsp, 0, .rdi);
        try m.store64Disp32(.rsp, 8, .rsi);
        try m.movReg64(.rsi, .rdi);
        try m.load64Disp32(.rdi, .rdi, @intCast(base * 8));
        try m.movImm32(.rdx, index);
        try m.movImm64(.r11, helper);
        try m.callReg(.r11);
        try m.load64Disp32(.rdi, .rsp, 0);
        try m.load64Disp32(.rsi, .rsp, 8);
        try m.addRegImm32(.rsp, 24);
    } else {
        try m.emit(arm.stpPreIdxSp(.x0, .lr, -16));
        try m.emit(arm.stpPreIdxSp(.x1, .fp, -16));
        try m.emit(arm.movReg(.x1, .x0));
        try scratch.load(m, .x0, base);
        try m.movImm64(.x2, index);
        try m.movImm64(.x16, helper);
        try m.emit(arm.blr(.x16));
        try m.emit(arm.movReg(.x2, .x0));
        try m.emit(arm.ldpPostIdxSp(.x1, .fp, 16));
        try m.emit(arm.ldpPostIdxSp(.x0, .lr, 16));
    }
}
