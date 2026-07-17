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
const Heap = heap_mod.Heap;
const Realm = @import("../realm.zig").Realm;
const GlobalBindings = @import("../realm.zig").GlobalBindings;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const chunk_mod = @import("../../bytecode/chunk.zig");
const LoadICCell = chunk_mod.LoadICCell;
const StoreICCell = chunk_mod.StoreICCell;
const CallICCell = chunk_mod.CallICCell;
const Shape = @import("../shape.zig").Shape;
const CallFrame = @import("../lantern/interpreter.zig").CallFrame;
const Environment = @import("../environment.zig").Environment;
const JSFunction = @import("../function.zig").JSFunction;

/// `CallFrame` — the frame-identity rule's contact surface
/// (docs/jit.md §4.2).
pub const frame = struct {
    pub const ip: u15 = @offsetOf(CallFrame, "ip");
    pub const accumulator: u15 = @offsetOf(CallFrame, "accumulator");
    pub const running_realm: u15 = @offsetOf(CallFrame, "running_realm");
    pub const this_value: u15 = @offsetOf(CallFrame, "this_value");
    pub const super_called_cell: u15 = @offsetOf(CallFrame, "super_called_cell");
    pub const env: u15 = @offsetOf(CallFrame, "env");
    pub const new_target: u15 = @offsetOf(CallFrame, "new_target");
    pub const home_object: u15 = @offsetOf(CallFrame, "home_object");
    pub const home_function: u15 = @offsetOf(CallFrame, "home_function");
    pub const owning_module: u15 = @offsetOf(CallFrame, "owning_module");
};

/// `JSFunction` — the self-tail-call jump-to-entry rebuild
/// (docs/jit.md §12 3e follow-up) reads the callee's capture set.
pub const function = struct {
    pub const chunk: u15 = @offsetOf(JSFunction, "chunk");
    pub const captured_env: u15 = @offsetOf(JSFunction, "captured_env");
    pub const home_object: u15 = @offsetOf(JSFunction, "home_object");
    pub const home_function: u15 = @offsetOf(JSFunction, "home_function");
    pub const super_called_cell: u15 = @offsetOf(JSFunction, "super_called_cell");
    pub const owning_module: u15 = @offsetOf(JSFunction, "owning_module");
    pub const realm: u15 = @offsetOf(JSFunction, "realm");
    pub const is_arrow: u15 = @offsetOf(JSFunction, "is_arrow");
    /// `[[Construct]]`'s instance prototype — the in-line `new_call`
    /// IC-hit guard (docs/jit.md §4.5) compares this against
    /// `CallICCell.proto` to catch a `C.prototype = …` reassignment.
    pub const prototype: u15 = @offsetOf(JSFunction, "prototype");
};

/// `Environment` — the lda_env / sta_env fixed-depth walks
/// (docs/jit.md §12 3g). `slots` is a []Value: pointer at +0
/// (the witnessed slice assumption), length at +8.
pub const env = struct {
    pub const parent: u15 = @offsetOf(Environment, "parent");
    pub const slots: u15 = @offsetOf(Environment, "slots");
    pub const slots_len: u15 = slots + @sizeOf(*Value);
};

/// `Realm` fields the back-edge safepoint and the global IC read.
/// Realm is large; consumers go through the shifted-add load
/// helpers, so these are plain usize offsets.
pub const realm = struct {
    pub const heap: usize = @offsetOf(Realm, "heap");
    pub const step_budget: usize = @offsetOf(Realm, "step_budget");
    pub const interrupt_raw: usize =
        @offsetOf(Realm, "interrupt") + @offsetOf(std.atomic.Value(bool), "raw");
    pub const interrupt_hook: usize = @offsetOf(Realm, "interrupt_hook");
    pub const proto_revision_counter: usize =
        @offsetOf(Realm, "proto_revision_counter");
    pub const globals_target: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "target");
    pub const globals_decl_revision: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "decl_revision");
    /// The §9.1.1.4 declarative-record slot caches (slice pointers
    /// at offset 0 — the same layout assumption the proof test
    /// witnesses for `overflow_slots`).
    pub const globals_decl_slots_ptr: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "decl_slots");
    pub const globals_decl_slots_len: usize =
        globals_decl_slots_ptr + @sizeOf(*Value);
    pub const globals_decl_const_flags_ptr: usize =
        @offsetOf(Realm, "globals") + @offsetOf(GlobalBindings, "decl_const_flags");
    /// Ohaimark loop-header OSR policy (docs/ohaimark.md §3.17). Bistromath
    /// backedges load this first so the default-off path stays a single
    /// compare against zero with no helper call.
    pub const ohaimark_osr_enabled: usize = @offsetOf(Realm, "ohaimark_osr_enabled");
};

/// `Heap` fields used only to detect pending collector work at a compiled
/// backedge. Ohaimark returns to Lantern before running that work, so generated
/// code never enters the collector with optimized-only roots.
pub const heap = struct {
    pub const allocs_since_gc: usize = @offsetOf(Heap, "allocs_since_gc");
    pub const bytes_since_gc: usize = @offsetOf(Heap, "bytes_since_gc");
    pub const gc_young_threshold: usize = @offsetOf(Heap, "gc_young_threshold");
    pub const gc_byte_threshold: usize = @offsetOf(Heap, "gc_byte_threshold");
    pub const marking_phase: usize = @offsetOf(Heap, "marking_phase");
    pub const sweep_phase: usize = @offsetOf(Heap, "sweep_phase");
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

/// `LoadICCell` — read as data by the Bistromath fast paths
/// (docs/jit.md §4.4); the GC weak-clear protocol stays untouched
/// because compiled code only ever loads these fields.
pub const load_ic_cell = struct {
    pub const shape: u15 = @offsetOf(LoadICCell, "shape");
    pub const slot: u15 = @offsetOf(LoadICCell, "slot");
    pub const kind: u12 = @offsetOf(LoadICCell, "kind");
    pub const proto: u15 = @offsetOf(LoadICCell, "proto");
    pub const proto_shape: u15 = @offsetOf(LoadICCell, "proto_shape");
    pub const proto_rev: u15 = @offsetOf(LoadICCell, "proto_rev");
    pub const synthetic_value: u15 = @offsetOf(LoadICCell, "synthetic_value");
    pub const kind_data: u8 = @intFromEnum(LoadICCell.Kind.data);
    pub const kind_synthetic_accessor: u8 = @intFromEnum(LoadICCell.Kind.synthetic_accessor);
};

/// Store-cache prefix consumed by Bistromath's same-shape write fast path.
/// Transition-only fields remain Lantern-owned and need no native offsets.
pub const store_ic_cell = struct {
    pub const shape: u15 = @offsetOf(StoreICCell, "shape");
    pub const slot: u15 = @offsetOf(StoreICCell, "slot");
};

/// `CallICCell` — the callee compare for compiled call sites
/// (docs/jit.md §12 step 3e).
pub const call_ic_cell = struct {
    pub const callee: u15 = @offsetOf(CallICCell, "callee");
    /// The resolved instance prototype cached for a `new_call` site
    /// (docs/jit.md §4.5) — the in-line construct guard.
    pub const proto: u15 = @offsetOf(CallICCell, "proto");
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
        frame.ip,                           frame.accumulator,
        frame.running_realm,                frame.this_value,
        frame.super_called_cell,            object.shape,
        object.prototype,                   object.inline_slots,
        object.overflow_items_ptr,          load_ic_cell.shape,
        load_ic_cell.proto,                 load_ic_cell.proto_shape,
        load_ic_cell.proto_rev,             load_ic_cell.synthetic_value,
        store_ic_cell.shape,                call_ic_cell.callee,
        realm.heap,                         realm.step_budget,
        realm.interrupt_hook,               realm.proto_revision_counter,
        realm.globals_target,               realm.globals_decl_revision,
        realm.globals_decl_slots_ptr,       realm.globals_decl_slots_len,
        realm.globals_decl_const_flags_ptr, heap.bytes_since_gc,
        heap.gc_byte_threshold,
    }) |off| std.debug.assert(off % 8 == 0);
    // `slot` is a u32 field — 4-aligned is enough (loaded via ldr-w
    // by the emitters... which use the 64-bit scaled form on an
    // 8-aligned base; keep it 4-aligned and loaded as the low half
    // only if the emitters say so. Today they load it 32-bit.)
    std.debug.assert(load_ic_cell.slot % 4 == 0);
    std.debug.assert(store_ic_cell.slot % 4 == 0);
    std.debug.assert(heap.allocs_since_gc % 4 == 0);
    std.debug.assert(heap.gc_young_threshold % 4 == 0);
    // The kind bits live inside the 8-byte alignment slack.
    std.debug.assert(heap_mod.kind_mask < 8);
    // `is_arrow` is a byte load (ldrb imm12).
    std.debug.assert(function.is_arrow < 4096);
    std.debug.assert(load_ic_cell.kind < 4096);
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

fn emitFieldLoadW(m: *masm_mod.Masm, off: usize) !void {
    if (off % 4 != 0) return error.InvalidLayout;
    if (off <= 16380) {
        try m.emit(a64.ldrImmW(.x0, .x0, @intCast(off)));
    } else {
        try m.emit(a64.addImm(.x0, .x0, @intCast(off >> 12), true));
        try m.emit(a64.ldrImmW(.x0, .x0, @intCast(off & 0xFFF)));
    }
    try m.emit(a64.ret());
}

fn emitFieldLoadB(m: *masm_mod.Masm, off: usize) !void {
    if (off <= 4095) {
        try m.emit(a64.ldrbImm(.x0, .x0, @intCast(off)));
    } else {
        try m.emit(a64.addImm(.x0, .x0, @intCast(off >> 12), true));
        try m.emit(a64.ldrbImm(.x0, .x0, @intCast(off & 0xFFF)));
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

fn loadViaW(ca: *code_alloc.CodeAllocator, off: usize, base: *const anyopaque) !u32 {
    var m = masm_mod.Masm.init(testing.allocator);
    defer m.deinit();
    try emitFieldLoadW(&m, off);
    const f = code_alloc.asFn(*const fn (u64) callconv(.c) u32, try m.install(ca));
    return f(@intFromPtr(base));
}

fn loadViaB(ca: *code_alloc.CodeAllocator, off: usize, base: *const anyopaque) !u8 {
    var m = masm_mod.Masm.init(testing.allocator);
    defer m.deinit();
    try emitFieldLoadB(&m, off);
    const f = code_alloc.asFn(*const fn (u64) callconv(.c) u8, try m.install(ca));
    return f(@intFromPtr(base));
}

fn proofInterruptHook(ctx: ?*anyopaque) Realm.InterruptAction {
    _ = ctx;
    return .proceed;
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
    try testing.expectEqual(
        @as(u64, @intFromPtr(realm_v.heap)),
        try loadVia(&ca, realm.heap, &realm_v),
    );
    try testing.expectEqual(@as(u64, 424242), try loadVia(&ca, realm.step_budget, &realm_v));
    realm_v.setInterruptHook(proofInterruptHook, null);
    try testing.expectEqual(
        @as(u64, @intFromPtr(realm_v.interrupt_hook.?)),
        try loadVia(&ca, realm.interrupt_hook, &realm_v),
    );
    try testing.expectEqual(
        realm_v.proto_revision_counter,
        try loadVia(&ca, realm.proto_revision_counter, &realm_v),
    );
    try testing.expectEqual(
        realm_v.globals.decl_revision,
        try loadVia(&ca, realm.globals_decl_revision, &realm_v),
    );
    try realm_v.globals.installScriptLexBinding(testing.allocator, "layout", false);
    try testing.expectEqual(
        @as(u64, @intFromPtr(realm_v.globals.decl_slots.ptr)),
        try loadVia(&ca, realm.globals_decl_slots_ptr, &realm_v),
    );
    try testing.expectEqual(
        @as(u64, realm_v.globals.decl_slots.len),
        try loadVia(&ca, realm.globals_decl_slots_len, &realm_v),
    );

    // Heap safepoint fields: count/byte pressure and incremental phases.
    realm_v.heap.allocs_since_gc = 17;
    realm_v.heap.bytes_since_gc = 23;
    realm_v.heap.gc_young_threshold = 29;
    realm_v.heap.gc_byte_threshold = 31;
    try testing.expectEqual(
        @as(u32, 17),
        try loadViaW(&ca, heap.allocs_since_gc, realm_v.heap),
    );
    try testing.expectEqual(
        @as(u64, 23),
        try loadVia(&ca, heap.bytes_since_gc, realm_v.heap),
    );
    try testing.expectEqual(
        @as(u32, 29),
        try loadViaW(&ca, heap.gc_young_threshold, realm_v.heap),
    );
    try testing.expectEqual(
        @as(u64, 31),
        try loadVia(&ca, heap.gc_byte_threshold, realm_v.heap),
    );
    realm_v.heap.marking_phase = .marking;
    try testing.expectEqual(@as(u8, 1), try loadViaB(&ca, heap.marking_phase, realm_v.heap));
    realm_v.heap.marking_phase = .idle;
    realm_v.heap.sweep_phase = .sweeping;
    try testing.expectEqual(@as(u8, 1), try loadViaB(&ca, heap.sweep_phase, realm_v.heap));
    realm_v.heap.sweep_phase = .idle;

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

    // LoadICCell fields.
    var cell: LoadICCell = .{};
    cell.slot = 5;
    cell.proto_rev = 0xABCD_EF01;
    cell.synthetic_value = Value.fromInt32(77);
    try testing.expectEqual(
        @as(u64, 0xABCD_EF01),
        try loadVia(&ca, load_ic_cell.proto_rev, &cell),
    );
    try testing.expectEqual(
        Value.fromInt32(77).bits,
        try loadVia(&ca, load_ic_cell.synthetic_value, &cell),
    );

    var store_cell: StoreICCell = .{};
    var shape_witness: Shape = undefined;
    store_cell.shape = &shape_witness;
    try testing.expectEqual(
        @as(u64, @intFromPtr(&shape_witness)),
        try loadVia(&ca, store_ic_cell.shape, &store_cell),
    );

    // Tag facts: a tagged object round-trips through the baked
    // masks exactly as `valueAsPlainObject` would decode it.
    const tagged = heap_mod.taggedObject(obj);
    try testing.expectEqual(value_bits.tag_object_shifted, tagged.bits & (@as(u64, 0xFFFF) << 48));
    try testing.expectEqual(value_bits.kind_object, tagged.bits & value_bits.kind_mask);
    const decoded = (tagged.bits & value_bits.pointer_mask) & ~value_bits.kind_mask;
    try testing.expectEqual(@intFromPtr(obj), @as(usize, @intCast(decoded)));
}
