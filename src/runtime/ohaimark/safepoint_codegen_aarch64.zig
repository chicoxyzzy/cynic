//! Ohaimark AArch64 backedge polling.
//!
//! The current optimized subset allocates nothing and calls no helpers. A
//! pending collector slice, fuel exhaustion, interrupt hook, or cooperative
//! interrupt therefore exits to Lantern at the loop header instead of calling
//! into runtime code with optimized-only roots. `codegen_aarch64.zig` rebuilds
//! that precise frame state on the cold edge before the native frame returns.

const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const layout = @import("../jit/layout.zig");
const Masm = @import("../jit/masm.zig").Masm;

const heap_scratch: a64.Reg = .x12;
const value_scratch: a64.Reg = .x13;
const threshold_scratch: a64.Reg = .x14;

/// Emit the fast half of Lantern's `runSafePoint` contract. Any work that can
/// allocate, collect, or invoke host code branches to `slow`; only the no-work
/// path decrements the shared step budget in native code.
pub fn emitPoll(
    machine: *Masm,
    realm_register: a64.Reg,
    slow: *Masm.Label,
) !void {
    if (realm_register == heap_scratch or
        realm_register == value_scratch or
        realm_register == threshold_scratch)
    {
        return error.InvalidRegister;
    }

    try emitLoadU64(machine, heap_scratch, realm_register, layout.realm.heap);

    // Incremental work must keep making progress even when this optimized loop
    // allocates nothing. Lantern owns the actual mark/sweep slice.
    try emitLoadU8(machine, value_scratch, heap_scratch, layout.heap.sweep_phase);
    try machine.jumpCbnz(value_scratch, slow);
    try emitLoadU8(machine, value_scratch, heap_scratch, layout.heap.marking_phase);
    try machine.jumpCbnz(value_scratch, slow);

    try emitLoadU32(machine, value_scratch, heap_scratch, layout.heap.allocs_since_gc);
    try emitLoadU32(machine, threshold_scratch, heap_scratch, layout.heap.gc_young_threshold);
    try machine.emit(a64.cmpRegW(value_scratch, threshold_scratch));
    try machine.jumpCond(.cs, slow);

    try emitLoadU64(machine, value_scratch, heap_scratch, layout.heap.bytes_since_gc);
    try emitLoadU64(machine, threshold_scratch, heap_scratch, layout.heap.gc_byte_threshold);
    try machine.emit(a64.cmpReg(value_scratch, threshold_scratch));
    try machine.jumpCond(.cs, slow);

    // Match Realm.pollExecution exactly: an exhausted budget wins over an
    // interrupt, interruption wins over the decrement, and the default maxInt
    // sentinel remains unchanged. Hooks execute only after Lantern owns the
    // reconstructed frame.
    try emitLoadU64(machine, value_scratch, realm_register, layout.realm.step_budget);
    try machine.jumpCbz(value_scratch, slow);
    try emitLoadU8(machine, threshold_scratch, realm_register, layout.realm.interrupt_raw);
    try machine.jumpCbnz(threshold_scratch, slow);
    try emitLoadU64(machine, threshold_scratch, realm_register, layout.realm.interrupt_hook);
    try machine.jumpCbnz(threshold_scratch, slow);

    var consume_budget: Masm.Label = .{};
    defer consume_budget.deinit(machine.gpa);
    var done: Masm.Label = .{};
    defer done.deinit(machine.gpa);
    try machine.movImm64(threshold_scratch, std.math.maxInt(u64));
    try machine.emit(a64.cmpReg(value_scratch, threshold_scratch));
    try machine.jumpCond(.ne, &consume_budget);
    try emitLoadU8(machine, threshold_scratch, realm_register, layout.realm.fuel_exhaustion);
    try machine.jumpCbz(threshold_scratch, &done);

    try machine.bind(&consume_budget);
    try machine.emit(a64.subImm(value_scratch, value_scratch, 1, false));
    try emitStoreU64(
        machine,
        value_scratch,
        realm_register,
        layout.realm.step_budget,
        threshold_scratch,
    );
    try machine.bind(&done);
}

fn emitLoadU64(machine: *Masm, destination: a64.Reg, base: a64.Reg, offset: usize) !void {
    if (offset % 8 != 0) return error.InvalidLayout;
    if (offset <= 32_760) {
        try machine.emit(a64.ldrImm(destination, base, @intCast(offset)));
        return;
    }
    try emitPageBase(machine, destination, base, offset);
    try machine.emit(a64.ldrImm(destination, destination, @intCast(offset & 0xFFF)));
}

fn emitLoadU32(machine: *Masm, destination: a64.Reg, base: a64.Reg, offset: usize) !void {
    if (offset % 4 != 0) return error.InvalidLayout;
    if (offset <= 16_380) {
        try machine.emit(a64.ldrImmW(destination, base, @intCast(offset)));
        return;
    }
    try emitPageBase(machine, destination, base, offset);
    try machine.emit(a64.ldrImmW(destination, destination, @intCast(offset & 0xFFF)));
}

fn emitLoadU8(machine: *Masm, destination: a64.Reg, base: a64.Reg, offset: usize) !void {
    if (offset <= 4095) {
        try machine.emit(a64.ldrbImm(destination, base, @intCast(offset)));
        return;
    }
    try emitPageBase(machine, destination, base, offset);
    try machine.emit(a64.ldrbImm(destination, destination, @intCast(offset & 0xFFF)));
}

fn emitStoreU64(
    machine: *Masm,
    source: a64.Reg,
    base: a64.Reg,
    offset: usize,
    address_scratch: a64.Reg,
) !void {
    if (offset % 8 != 0 or address_scratch == source or address_scratch == base) {
        return error.InvalidLayout;
    }
    if (offset <= 32_760) {
        try machine.emit(a64.strImm(source, base, @intCast(offset)));
        return;
    }
    try emitPageBase(machine, address_scratch, base, offset);
    try machine.emit(a64.strImm(source, address_scratch, @intCast(offset & 0xFFF)));
}

fn emitPageBase(
    machine: *Masm,
    destination: a64.Reg,
    base: a64.Reg,
    offset: usize,
) !void {
    if (destination == base) return error.InvalidRegister;
    const pages = offset >> 12;
    if (pages == 0 or pages > std.math.maxInt(u12)) return error.InvalidLayout;
    try machine.emit(a64.addImm(destination, base, @intCast(pages), true));
}
