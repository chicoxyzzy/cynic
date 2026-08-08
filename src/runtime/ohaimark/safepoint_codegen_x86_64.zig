//! Ohaimark x86_64 backedge polling.
//!
//! The helper-free x86 subset transfers exact loop-header state back to
//! Lantern whenever collection, host interruption, or fuel work is pending.

const std = @import("std");

const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");

const heap_scratch: x86.Reg = .rax;
const value_scratch: x86.Reg = .rcx;
const threshold_scratch: x86.Reg = .r11;

pub fn emitPoll(
    machine: *x86.Masm,
    realm_register: x86.Reg,
    slow: *x86.Masm.Label,
) !void {
    if (realm_register == heap_scratch or
        realm_register == value_scratch or
        realm_register == threshold_scratch)
    {
        return error.InvalidRegister;
    }

    try emitLoadU64(machine, heap_scratch, realm_register, layout.realm.heap);

    try emitLoadU8(machine, value_scratch, heap_scratch, layout.heap.sweep_phase);
    try jumpIfNonzero(machine, value_scratch, slow);
    try emitLoadU8(machine, value_scratch, heap_scratch, layout.heap.marking_phase);
    try jumpIfNonzero(machine, value_scratch, slow);

    try emitLoadU32(machine, value_scratch, heap_scratch, layout.heap.allocs_since_gc);
    try emitLoadU32(
        machine,
        threshold_scratch,
        heap_scratch,
        layout.heap.gc_young_threshold,
    );
    try machine.cmpReg32(value_scratch, threshold_scratch);
    try machine.jumpCond(.above_or_equal, slow);

    try emitLoadU64(machine, value_scratch, heap_scratch, layout.heap.bytes_since_gc);
    try emitLoadU64(
        machine,
        threshold_scratch,
        heap_scratch,
        layout.heap.gc_byte_threshold,
    );
    try machine.cmpReg64(value_scratch, threshold_scratch);
    try machine.jumpCond(.above_or_equal, slow);

    try emitLoadU64(
        machine,
        value_scratch,
        realm_register,
        layout.realm.step_budget,
    );
    try machine.testReg64(value_scratch, value_scratch);
    try machine.jumpCond(.equal, slow);
    try emitLoadU8(
        machine,
        threshold_scratch,
        realm_register,
        layout.realm.interrupt_raw,
    );
    try jumpIfNonzero(machine, threshold_scratch, slow);
    try emitLoadU64(
        machine,
        threshold_scratch,
        realm_register,
        layout.realm.interrupt_hook,
    );
    try jumpIfNonzero(machine, threshold_scratch, slow);

    var consume_budget: x86.Masm.Label = .{};
    defer consume_budget.deinit(machine.gpa);
    var done: x86.Masm.Label = .{};
    defer done.deinit(machine.gpa);
    try machine.movImm64(threshold_scratch, std.math.maxInt(u64));
    try machine.cmpReg64(value_scratch, threshold_scratch);
    try machine.jumpCond(.not_equal, &consume_budget);
    try emitLoadU8(
        machine,
        threshold_scratch,
        realm_register,
        layout.realm.fuel_exhaustion,
    );
    try machine.testReg64(threshold_scratch, threshold_scratch);
    try machine.jumpCond(.equal, &done);

    try machine.bind(&consume_budget);
    try machine.subRegImm32(value_scratch, 1);
    try emitStoreU64(
        machine,
        realm_register,
        layout.realm.step_budget,
        value_scratch,
    );
    try machine.bind(&done);
}

fn jumpIfNonzero(
    machine: *x86.Masm,
    value: x86.Reg,
    target: *x86.Masm.Label,
) !void {
    try machine.testReg64(value, value);
    try machine.jumpCond(.not_equal, target);
}

fn emitLoadU64(
    machine: *x86.Masm,
    destination: x86.Reg,
    base: x86.Reg,
    offset: usize,
) !void {
    try machine.load64Disp32(destination, base, try displacement(offset));
}

fn emitLoadU32(
    machine: *x86.Masm,
    destination: x86.Reg,
    base: x86.Reg,
    offset: usize,
) !void {
    try machine.load32Disp32(destination, base, try displacement(offset));
}

fn emitLoadU8(
    machine: *x86.Masm,
    destination: x86.Reg,
    base: x86.Reg,
    offset: usize,
) !void {
    try machine.load8Disp32(destination, base, try displacement(offset));
}

fn emitStoreU64(
    machine: *x86.Masm,
    base: x86.Reg,
    offset: usize,
    source: x86.Reg,
) !void {
    try machine.store64Disp32(base, try displacement(offset), source);
}

fn displacement(offset: usize) !i32 {
    return std.math.cast(i32, offset) orelse error.InvalidLayout;
}
