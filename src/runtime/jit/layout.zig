//! The JIT-stable layout contract (docs/jit.md §12 step 3a) — the
//! one module declaring every struct offset and bit pattern
//! compiled code may read. Machine code derives an offset nowhere
//! else; when a runtime struct changes shape, this file is the
//! single place the JIT notices, at comptime.
//!
//! Two layers of pinning:
//!   • comptime asserts on alignment / range, so an offset that
//!     stops fitting the scaled-load encodings fails the build;
//!   • an executable proof test (bottom) that emits real loads
//!     through these offsets against live engine values and
//!     compares with Zig-side reads. The one assumption Zig does
//!     not guarantee — a slice's pointer living at offset 0 — gets
//!     a runtime witness here rather than a comment.

const std = @import("std");
const builtin = @import("builtin");

const Value = @import("../value.zig").Value;
const heap_mod = @import("../heap.zig");
const Realm = @import("../realm.zig").Realm;
const GlobalBindings = @import("../realm.zig").GlobalBindings;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const chunk_mod = @import("../../bytecode/chunk.zig");
const ICCell = chunk_mod.ICCell;
const CallICCell = chunk_mod.CallICCell;
const CallFrame = @import("../lantern/interpreter.zig").CallFrame;

/// `CallFrame` — the frame-identity rule's contact surface
/// (docs/jit.md §4.2).
pub const frame = struct {
    pub const ip: u15 = @offsetOf(CallFrame, "ip");
    pub const accumulator: u15 = @offsetOf(CallFrame, "accumulator");
    pub const running_realm: u15 = @offsetOf(CallFrame, "running_realm");
    pub const this_value: u15 = @offsetOf(CallFrame, "this_value");
    pub const super_called_cell: u15 = @offsetOf(CallFrame, "super_called_cell");
};

/// `Realm` fields the back-edge safepoint and the global IC read.
/// Realm is large; consumers go through the shifted-add load
/// helpers, so these are plain usize offsets.
pub const realm = struct {
    pub const step_budget: usize = @offsetOf(Realm, "step_budget");
    pub const interrupt_raw: usize =
        @offsetOf(Realm, "interrupt") + @offsetOf(std.atomic.Value(bool), "raw");
    pub const proto_revision_counter: usize =
        @offsetOf(Realm, "proto_revision_counter");
    pub const globals_target: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "target");
    pub const globals_decl_revision: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "decl_revision");
};

/// `JSObject` — the property-IC fast path's contact surface. Slots
/// are split inline/overflow (V8 in-object-properties style); the
/// emitted accessor branches on `inline_slot_cap` exactly like
/// `JSObject.slotAt`.
pub const object = struct {
    pub const shape: u15 = @offsetOf(JSObject, "shape");
    pub const prototype: u15 = @offsetOf(JSObject, "prototype");
    pub const inline_slots: u15 = @offsetOf(JSObject, "inline_slots");
    /// Byte offset of `overflow_slots.items.ptr` — the
    /// slice-pointer-at-offset-0 assumption the proof test
    /// witnesses.
    pub const overflow_items_ptr: u15 =
        @offsetOf(JSObject, "overflow_slots") +
        @offsetOf(std.ArrayListUnmanaged(Value), "items");
    pub const inline_slot_cap: u32 = object_mod.inline_slot_cap;
};

/// `ICCell` — read as data by the Bistromath fast paths
/// (docs/jit.md §4.4); the GC weak-clear protocol stays untouched
/// because compiled code only ever loads these fields.
pub const ic_cell = struct {
    pub const shape: u15 = @offsetOf(ICCell, "shape");
    pub const slot: u15 = @offsetOf(ICCell, "slot");
    pub const proto: u15 = @offsetOf(ICCell, "proto");
    pub const proto_shape: u15 = @offsetOf(ICCell, "proto_shape");
    pub const proto_rev: u15 = @offsetOf(ICCell, "proto_rev");
};

/// `CallICCell` — the callee compare for compiled call sites
/// (docs/jit.md §12 step 3e).
pub const call_ic_cell = struct {
    pub const callee: u15 = @offsetOf(CallICCell, "callee");
};

/// NaN-box bit facts compiled tag checks bake as immediates —
/// re-exported from value.zig / heap.zig so they cannot drift.
pub const value_bits = struct {
    pub const tag_object_shifted: u64 = @as(u64, Value.tag_object) << 48;
    pub const pointer_mask: u64 = Value.pointer_mask;
    pub const kind_mask: u64 = heap_mod.kind_mask;
    pub const kind_object: u64 = heap_mod.kind_object;
};

comptime {
    // The scaled 64-bit loads (`ldr Xt, [Xn, #imm]`) need 8-aligned
    // offsets; the slot accessors additionally index Value arrays.
    for ([_]usize{
        frame.ip,                  frame.accumulator,
        frame.running_realm,       frame.this_value,
        frame.super_called_cell,   object.shape,
        object.prototype,          object.inline_slots,
        object.overflow_items_ptr, ic_cell.shape,
        ic_cell.proto,             ic_cell.proto_shape,
        ic_cell.proto_rev,         call_ic_cell.callee,
        realm.step_budget,         realm.proto_revision_counter,
        realm.globals_target,      realm.globals_decl_revision,
    }) |off| std.debug.assert(off % 8 == 0);
    // `slot` is a u32 field — 4-aligned is enough (loaded via ldr-w
    // by the emitters... which use the 64-bit scaled form on an
    // 8-aligned base; keep it 4-aligned and loaded as the low half
    // only if the emitters say so. Today they load it 32-bit.)
    std.debug.assert(ic_cell.slot % 4 == 0);
    // The kind bits live inside the 8-byte alignment slack.
    std.debug.assert(heap_mod.kind_mask < 8);
}

// ── Executable proof ────────────────────────────────────────────────
// Emit real loads through the offsets above against live engine
// values and compare with Zig-side reads. aarch64 hosts only.

const code_alloc = @import("code_alloc.zig");
const masm_mod = @import("masm.zig");
const a64 = @import("asm_aarch64.zig");
const testing = std.testing;

const proof_supported = code_alloc.supported and builtin.cpu.arch == .aarch64;

/// Build `fn (base: u64) u64 { return *(base + off); }`.
fn emitFieldLoad(m: *masm_mod.Masm, off: usize) !void {
    if (off <= 32760) {
        try m.emit(a64.ldrImm(.x0, .x0, @intCast(off)));
    } else {
        try m.emit(a64.addImm(.x0, .x0, @intCast(off >> 12), true));
        try m.emit(a64.ldrImm(.x0, .x0, @intCast(off & 0xFFF)));
    }
    try m.emit(a64.ret());
}

fn loadVia(ca: *code_alloc.CodeAllocator, off: usize, base: *const anyopaque) !u64 {
    var m = masm_mod.Masm.init(testing.allocator);
    defer m.deinit();
    try emitFieldLoad(&m, off);
    const f = code_alloc.asFn(*const fn (u64) callconv(.c) u64, try m.install(ca));
    return f(@intFromPtr(base));
}

test "jit layout: machine loads match Zig reads on live values" {
    if (comptime !proof_supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 256 * 1024);
    defer ca.deinit();

    // CallFrame fields.
    var fr: CallFrame = undefined;
    fr.ip = 0xDEAD;
    fr.accumulator = Value.fromInt32(-7);
    try testing.expectEqual(@as(u64, 0xDEAD), try loadVia(&ca, frame.ip, &fr));
    try testing.expectEqual(fr.accumulator.bits, try loadVia(&ca, frame.accumulator, &fr));

    // Realm fields (init a real realm; no builtins needed).
    var realm_v = Realm.init(testing.allocator);
    defer realm_v.deinit();
    realm_v.step_budget = 424242;
    try testing.expectEqual(@as(u64, 424242), try loadVia(&ca, realm.step_budget, &realm_v));
    try testing.expectEqual(
        realm_v.proto_revision_counter,
        try loadVia(&ca, realm.proto_revision_counter, &realm_v),
    );
    try testing.expectEqual(
        realm_v.globals.decl_revision,
        try loadVia(&ca, realm.globals_decl_revision, &realm_v),
    );

    // JSObject: shape / prototype / inline slot / overflow slot —
    // the last is the slice-layout witness.
    const obj = try realm_v.heap.allocateObject();
    try obj.resizeSlots(testing.allocator, object.inline_slot_cap + 2);
    obj.setSlot(1, Value.fromInt32(11));
    obj.setSlot(object.inline_slot_cap + 1, Value.fromInt32(99));
    try testing.expectEqual(
        @as(u64, @intFromPtr(obj.prototype orelse @as(?*JSObject, null))),
        try loadVia(&ca, object.prototype, obj),
    );
    const inline1 = try loadVia(&ca, object.inline_slots + 8, obj);
    try testing.expectEqual(obj.slotAt(1).bits, inline1);
    const overflow_base = try loadVia(&ca, object.overflow_items_ptr, obj);
    const overflow1: *const Value = @ptrFromInt(@as(usize, @intCast(overflow_base)) + 8);
    try testing.expectEqual(obj.slotAt(object.inline_slot_cap + 1).bits, overflow1.bits);

    // ICCell fields.
    var cell: ICCell = .{};
    cell.slot = 5;
    cell.proto_rev = 0xABCD_EF01;
    try testing.expectEqual(
        @as(u64, 0xABCD_EF01),
        try loadVia(&ca, ic_cell.proto_rev, &cell),
    );

    // Tag facts: a tagged object round-trips through the baked
    // masks exactly as `valueAsPlainObject` would decode it.
    const tagged = heap_mod.taggedObject(obj);
    try testing.expectEqual(value_bits.tag_object_shifted, tagged.bits & (@as(u64, 0xFFFF) << 48));
    try testing.expectEqual(value_bits.kind_object, tagged.bits & value_bits.kind_mask);
    const decoded = (tagged.bits & value_bits.pointer_mask) & ~value_bits.kind_mask;
    try testing.expectEqual(@intFromPtr(obj), @as(usize, @intCast(decoded)));
}
