//! §25.4 Atomics.
//!
//! The read-modify-write / load / store / compareExchange operations
//! are real hardware-atomic ops (SeqCst) on the integer typed array's
//! backing store — shared OR non-shared (Atomics is not restricted to
//! shared buffers, except `wait` / `notify`). `wait` parks on the
//! shared block's §25.4.11 wait list; `notify` wakes up to `count`
//! parked agents and returns how many it woke. The wait is a
//! bounded-sleep poll loop rather than a kernel futex because this Zig
//! build's `std.Thread` no longer re-exports `Futex` — see the
//! `Atomics.wait` poll loop.
//!
//! A default Cynic embedding is single-agent, so in practice there is
//! no other agent to wake: `notify` returns 0 and `wait` only ever
//! returns `"not-equal"` / `"timed-out"`. But the cross-agent substrate
//! (the wait list + the SeqCst memory model) is real and is exercised
//! by a host that runs several agents on their own threads sharing a
//! SharedArrayBuffer (e.g. the test262 `$262.agent` harness). See
//! `docs/sab-atomics.md`.

const std = @import("std");

// §25.4 — wasm32/wasm64 (the freestanding playground target) has no
// 64-bit atomic ops: `@atomicLoad` / `@atomicStore` / `@atomicRmw` /
// `@cmpxchgStrong` on a 64-bit type fail to compile there. That target
// is single-agent (no cross-thread SharedArrayBuffer), so a 64-bit op
// has no concurrent observer and degrades to a plain non-atomic
// load/store/rmw without changing observable behaviour. Every other
// target keeps true atomics. Guards the four element-width helpers.
const wide_atomics = !builtin.cpu.arch.isWasm();

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const ObjMod = @import("../object.zig");
const JSObject = ObjMod.JSObject;
const TypedKind = ObjMod.TypedKind;
const TypedView = ObjMod.TypedView;
const ta_mod = @import("typed_array.zig");
const promise_mod = @import("promise.zig");
const SharedDataBlock = @import("../shared_data_block.zig").SharedDataBlock;

/// Monotonic clock in milliseconds — the time base for an async waiter's
/// timeout deadline. Matches the host's clock so the deadline the host
/// polls against is the same scale.
fn nowMonoMs() f64 {
    if (builtin.os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000.0;
}
const Waiter = @import("../shared_data_block.zig").Waiter;
const builtin = @import("builtin");

/// Monotonic nanoseconds via the libc shim (the engine deliberately
/// avoids `std.Io`; see `currentTimeMs` in date.zig). `0` on a
/// libc-less freestanding target.
fn monoNowNs() u64 {
    if (builtin.os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Sleep ~`ns` nanoseconds via the libc shim (this Zig build's
/// `std.Thread` no longer re-exports `sleep`/`Futex`; see the
/// `Atomics.wait` poll loop). No-op on a libc-less freestanding target.
fn napNs(ns: u64) void {
    if (builtin.os.tag == .freestanding) return;
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// `Atomics.wait` poll interval: re-check the notify sequence every
/// ~100 µs. Bounds the wake latency (imperceptible to a JS waiter)
/// while keeping a parked agent off the CPU — a pure spin pegged a
/// core and saturated the machine when several agents waited at once.
const wait_poll_ns: u64 = 100 * std.time.ns_per_us;

const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const toNumber = intrinsics.toNumber;
const argOr = intrinsics.argOr;
const installToStringTag = intrinsics.installToStringTag;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;

pub fn install(realm: *Realm) !void {
    const atomics = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(atomics, realm.intrinsics.object_prototype);
    try installToStringTag(realm, atomics, "Atomics");
    try installNativeMethodOnProto(realm, atomics, "add", atomicsAdd, 3);
    try installNativeMethodOnProto(realm, atomics, "sub", atomicsSub, 3);
    try installNativeMethodOnProto(realm, atomics, "and", atomicsAnd, 3);
    try installNativeMethodOnProto(realm, atomics, "or", atomicsOr, 3);
    try installNativeMethodOnProto(realm, atomics, "xor", atomicsXor, 3);
    try installNativeMethodOnProto(realm, atomics, "exchange", atomicsExchange, 3);
    try installNativeMethodOnProto(realm, atomics, "compareExchange", atomicsCompareExchange, 4);
    try installNativeMethodOnProto(realm, atomics, "load", atomicsLoad, 2);
    try installNativeMethodOnProto(realm, atomics, "store", atomicsStore, 3);
    try installNativeMethodOnProto(realm, atomics, "isLockFree", atomicsIsLockFree, 1);
    try installNativeMethodOnProto(realm, atomics, "notify", atomicsNotify, 3);
    try installNativeMethodOnProto(realm, atomics, "wait", atomicsWait, 4);
    try installNativeMethodOnProto(realm, atomics, "waitAsync", atomicsWaitAsync, 4);
    try installNativeMethodOnProto(realm, atomics, "pause", atomicsPause, 0);
    try realm.globals.put(realm.allocator, "Atomics", heap_mod.taggedObject(atomics));
}

// ── validation (§25.4.3) ────────────────────────────────────────────

/// §25.4.3.1 ValidateIntegerTypedArray(typedArray, waitable). Returns
/// the view on success; throws TypeError otherwise. `waitable` further
/// restricts to Int32Array / BigInt64Array. Uint8ClampedArray and the
/// Float kinds are rejected (they share no atomic element type).
fn validateIntegerTypedArray(realm: *Realm, value: Value, waitable: bool) NativeError!*JSObject {
    const obj = heap_mod.valueAsPlainObject(value) orelse
        return throwTypeError(realm, "Atomics: argument is not an integer TypedArray");
    const tv = obj.getTypedView() orelse
        return throwTypeError(realm, "Atomics: argument is not an integer TypedArray");
    const ok = switch (tv.kind) {
        .int8, .uint8, .int16, .uint16, .int32, .uint32, .bigint64, .biguint64 =>
        // Uint8ClampedArray reuses kind=.uint8 but is not an integer
        // atomic element type.
        !std.mem.eql(u8, tv.name, "Uint8ClampedArray"),
        .float16, .float32, .float64 => false,
    };
    if (!ok) return throwTypeError(realm, "Atomics: argument is not an integer TypedArray");
    if (waitable and tv.kind != .int32 and tv.kind != .bigint64)
        return throwTypeError(realm, "Atomics.wait/notify require an Int32Array or BigInt64Array");
    if (tv.viewed.getArrayBuffer() == null)
        return throwTypeError(realm, "Atomics: TypedArray has a detached buffer");
    return obj;
}

/// Current element length of a (possibly length-tracking) view.
fn viewLength(tv: TypedView, buf: []const u8) usize {
    if (tv.length_tracking) {
        if (buf.len < tv.byte_offset) return 0;
        return (buf.len - tv.byte_offset) / tv.kind.elementSize();
    }
    return tv.length;
}

/// §7.1.22 ToIndex restricted for §25.4.3.2 ValidateAtomicAccess —
/// coerce to a non-negative integer; RangeError on negative / NaN /
/// non-integral / infinite.
fn toAtomicIndex(realm: *Realm, v: Value) NativeError!usize {
    const n = try toNumber(realm, v);
    const raw: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
    const trunc: f64 = if (std.math.isNan(raw)) 0 else if (std.math.isInf(raw)) raw else @trunc(raw);
    if (std.math.isInf(trunc) or trunc < 0 or trunc > 9007199254740991.0)
        return throwRangeError(realm, "Atomics: index out of range");
    return @intFromFloat(trunc);
}

/// §25.4.3.2 ValidateAtomicAccess — ToIndex(requestIndex) then bounds
/// against the view length. Returns the element index.
fn validateAtomicAccess(realm: *Realm, tv: TypedView, buf: []const u8, index_v: Value) NativeError!usize {
    const idx = try toAtomicIndex(realm, index_v);
    if (idx >= viewLength(tv, buf))
        return throwRangeError(realm, "Atomics: access index out of bounds");
    return idx;
}

// ── raw element op (§6.2.x GetModifySetValueInBuffer) ───────────────

const RmwOp = enum { add, sub, and_, or_, xor, exchange };

fn applyOp(comptime T: type, op: RmwOp, old: T, arg: T) T {
    return switch (op) {
        .add => old +% arg,
        .sub => old -% arg,
        .and_ => old & arg,
        .or_ => old | arg,
        .xor => old ^ arg,
        .exchange => arg,
    };
}

/// Coerce a JS value to the element kind's raw little-endian bits,
/// reusing the TypedArray store coercion (ToBigInt for the BigInt
/// kinds, ToNumber + modular truncation otherwise). Returns the low
/// `elementSize` bytes zero-extended into a u64. Runs the (possibly
/// user-observable) coercion the spec sequences before the in-buffer
/// read-modify-write.
fn coerceRawBits(realm: *Realm, kind: TypedKind, value: Value) NativeError!u64 {
    var scratch = std.mem.zeroes([8]u8);
    const coerced = try ta_mod.coerceForTypedSlot(realm, kind, value);
    ta_mod.writeTypedElement(&scratch, kind, 0, coerced);
    return std.mem.readInt(u64, scratch[0..8], .little);
}

/// Read the raw element bits at `byte_pos`, zero-extended to u64.
fn readRawBits(buf: []const u8, size: u8, byte_pos: usize) u64 {
    return switch (size) {
        1 => buf[byte_pos],
        2 => std.mem.readInt(u16, buf[byte_pos..][0..2], .little),
        4 => std.mem.readInt(u32, buf[byte_pos..][0..4], .little),
        8 => std.mem.readInt(u64, buf[byte_pos..][0..8], .little),
        else => unreachable,
    };
}

fn writeRawBits(buf: []u8, size: u8, byte_pos: usize, bits: u64) void {
    switch (size) {
        1 => buf[byte_pos] = @truncate(bits),
        2 => std.mem.writeInt(u16, buf[byte_pos..][0..2], @truncate(bits), .little),
        4 => std.mem.writeInt(u32, buf[byte_pos..][0..4], @truncate(bits), .little),
        8 => std.mem.writeInt(u64, buf[byte_pos..][0..8], bits, .little),
        else => unreachable,
    }
}

fn rmwBits(size: u8, op: RmwOp, old: u64, arg: u64) u64 {
    return switch (size) {
        1 => applyOp(u8, op, @truncate(old), @truncate(arg)),
        2 => applyOp(u16, op, @truncate(old), @truncate(arg)),
        4 => applyOp(u32, op, @truncate(old), @truncate(arg)),
        8 => applyOp(u64, op, old, arg),
        else => unreachable,
    };
}

// ── atomic element ops on a shared block (§25.4 memory model) ────────
//
// A SharedArrayBuffer's bytes are reachable from several agents, so a
// read-modify-write / load / store / compareExchange must be a single
// indivisible hardware-atomic operation, SeqCst — a plain
// read-then-write loses updates under contention. These run only for a
// shared buffer: its block is page-allocated (page-aligned base) and a
// TypedArray's byteOffset is always a multiple of its element size, so
// `byte_pos` is naturally aligned for the element type and the
// `@alignCast` can never fault. A non-shared buffer can't be observed
// by another agent, so it keeps the plain (single-agent) path — its
// GC-heap backing carries no alignment guarantee.

// A naturally-aligned `*T` view of `buf[byte_pos]`. The explicit local
// type gives `@ptrCast` / `@alignCast` their required result type. For
// a shared block the alignment is guaranteed (see the note above), so
// `@alignCast` never faults.
fn elemPtr(comptime T: type, buf: []u8, byte_pos: usize) *T {
    return @ptrCast(@alignCast(&buf[byte_pos]));
}
fn elemPtrConst(comptime T: type, buf: []const u8, byte_pos: usize) *const T {
    return @ptrCast(@alignCast(&buf[byte_pos]));
}

fn atomicLoadT(comptime T: type, buf: []const u8, byte_pos: usize) u64 {
    const ptr = elemPtrConst(T, buf, byte_pos);
    if (comptime @bitSizeOf(T) > 32 and !wide_atomics) return ptr.*;
    return @atomicLoad(T, ptr, .seq_cst);
}
fn atomicLoadBits(buf: []const u8, size: u8, byte_pos: usize) u64 {
    return switch (size) {
        1 => atomicLoadT(u8, buf, byte_pos),
        2 => atomicLoadT(u16, buf, byte_pos),
        4 => atomicLoadT(u32, buf, byte_pos),
        8 => atomicLoadT(u64, buf, byte_pos),
        else => unreachable,
    };
}

fn atomicStoreT(comptime T: type, buf: []u8, byte_pos: usize, bits: u64) void {
    const ptr = elemPtr(T, buf, byte_pos);
    if (comptime @bitSizeOf(T) > 32 and !wide_atomics) {
        ptr.* = @truncate(bits);
        return;
    }
    @atomicStore(T, ptr, @truncate(bits), .seq_cst);
}
fn atomicStoreBits(buf: []u8, size: u8, byte_pos: usize, bits: u64) void {
    switch (size) {
        1 => atomicStoreT(u8, buf, byte_pos, bits),
        2 => atomicStoreT(u16, buf, byte_pos, bits),
        4 => atomicStoreT(u32, buf, byte_pos, bits),
        8 => atomicStoreT(u64, buf, byte_pos, bits),
        else => unreachable,
    }
}

fn atomicRmwT(comptime T: type, comptime aop: std.builtin.AtomicRmwOp, buf: []u8, byte_pos: usize, arg: u64) u64 {
    const ptr = elemPtr(T, buf, byte_pos);
    if (comptime @bitSizeOf(T) > 32 and !wide_atomics) {
        const old = ptr.*;
        const v: T = @truncate(arg);
        ptr.* = switch (aop) {
            .Add => old +% v,
            .Sub => old -% v,
            .And => old & v,
            .Or => old | v,
            .Xor => old ^ v,
            .Xchg => v,
            else => unreachable,
        };
        return old;
    }
    return @atomicRmw(T, ptr, aop, @truncate(arg), .seq_cst);
}
/// Atomic read-modify-write; returns the OLD bits zero-extended to u64.
fn atomicRmwBits(buf: []u8, size: u8, byte_pos: usize, op: RmwOp, arg: u64) u64 {
    switch (op) {
        inline else => |o| {
            const aop: std.builtin.AtomicRmwOp = comptime switch (o) {
                .add => .Add,
                .sub => .Sub,
                .and_ => .And,
                .or_ => .Or,
                .xor => .Xor,
                .exchange => .Xchg,
            };
            return switch (size) {
                1 => atomicRmwT(u8, aop, buf, byte_pos, arg),
                2 => atomicRmwT(u16, aop, buf, byte_pos, arg),
                4 => atomicRmwT(u32, aop, buf, byte_pos, arg),
                8 => atomicRmwT(u64, aop, buf, byte_pos, arg),
                else => unreachable,
            };
        },
    }
}

fn atomicCasT(comptime T: type, buf: []u8, byte_pos: usize, expected: u64, replacement: u64) u64 {
    const ptr = elemPtr(T, buf, byte_pos);
    const exp: T = @truncate(expected);
    if (comptime @bitSizeOf(T) > 32 and !wide_atomics) {
        const cur = ptr.*;
        if (cur == exp) ptr.* = @truncate(replacement);
        return cur;
    }
    return @cmpxchgStrong(T, ptr, exp, @truncate(replacement), .seq_cst, .seq_cst) orelse exp;
}
/// Atomic compare-and-swap; returns the OLD bits (always), like the
/// spec's compareExchange. `@cmpxchgStrong` returns null when the swap
/// happened (old == expected), else the current value.
fn atomicCompareExchangeBits(buf: []u8, size: u8, byte_pos: usize, expected: u64, replacement: u64) u64 {
    return switch (size) {
        1 => atomicCasT(u8, buf, byte_pos, expected, replacement),
        2 => atomicCasT(u16, buf, byte_pos, expected, replacement),
        4 => atomicCasT(u32, buf, byte_pos, expected, replacement),
        8 => atomicCasT(u64, buf, byte_pos, expected, replacement),
        else => unreachable,
    };
}

/// Decode raw element bits back to the JS Value for `kind` (sign
/// extension / BigInt allocation), reusing the TypedArray read path.
fn bitsToValue(realm: *Realm, kind: TypedKind, bits: u64) Value {
    var scratch = std.mem.zeroes([8]u8);
    writeRawBits(&scratch, kind.elementSize(), 0, bits);
    return ta_mod.readTypedElement(realm, &scratch, kind, 0);
}

/// §25.4.{6,8} AtomicReadModifyWrite shared body.
fn atomicRmw(realm: *Realm, args: []const Value, op: RmwOp) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), false);
    const tv = obj.getTypedView().?;
    // §25.4.3.2 ValidateAtomicAccess (index) — before value coercion.
    const idx = try validateAtomicAccess(realm, tv, tv.viewed.getArrayBuffer().?, argOr(args, 1, Value.undefined_));
    const kind = tv.kind;
    const size = kind.elementSize();
    // §25.4.1.11 step 3 — coerce the operand (may run user code).
    const arg_bits = try coerceRawBits(realm, kind, argOr(args, 2, Value.undefined_));
    // Re-fetch the buffer: a user `valueOf` during coercion can detach
    // / resize a non-shared buffer.
    const buf = tv.viewed.getArrayBuffer() orelse return throwTypeError(realm, "Atomics: buffer detached during coercion");
    const byte_pos = tv.byte_offset + idx * size;
    if (byte_pos + size > buf.len) return throwRangeError(realm, "Atomics: access index out of bounds");
    // A shared buffer requires a real atomic RMW (other agents may touch
    // this slot concurrently); a non-shared buffer is single-agent, so a
    // plain read-then-write is observably atomic.
    if (tv.viewed.isSharedArrayBuffer())
        return bitsToValue(realm, kind, atomicRmwBits(buf, size, byte_pos, op, arg_bits));
    // Read the old value (the return) before overwriting.
    const old_val = ta_mod.readTypedElement(realm, buf, kind, byte_pos);
    const old_bits = readRawBits(buf, size, byte_pos);
    writeRawBits(buf, size, byte_pos, rmwBits(size, op, old_bits, arg_bits));
    return old_val;
}

fn atomicsAdd(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .add);
}
fn atomicsSub(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .sub);
}
fn atomicsAnd(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .and_);
}
fn atomicsOr(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .or_);
}
fn atomicsXor(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .xor);
}
fn atomicsExchange(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    return atomicRmw(realm, args, .exchange);
}

/// §25.4.6 Atomics.compareExchange(ta, index, expected, replacement).
fn atomicsCompareExchange(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), false);
    const tv = obj.getTypedView().?;
    const idx = try validateAtomicAccess(realm, tv, tv.viewed.getArrayBuffer().?, argOr(args, 1, Value.undefined_));
    const kind = tv.kind;
    const size = kind.elementSize();
    // Spec order: coerce expected, then replacement.
    const expected_bits = try coerceRawBits(realm, kind, argOr(args, 2, Value.undefined_));
    const replacement_bits = try coerceRawBits(realm, kind, argOr(args, 3, Value.undefined_));
    const buf = tv.viewed.getArrayBuffer() orelse return throwTypeError(realm, "Atomics: buffer detached during coercion");
    const byte_pos = tv.byte_offset + idx * size;
    if (byte_pos + size > buf.len) return throwRangeError(realm, "Atomics: access index out of bounds");
    // Shared → single atomic compare-and-swap; non-shared → plain.
    if (tv.viewed.isSharedArrayBuffer())
        return bitsToValue(realm, kind, atomicCompareExchangeBits(buf, size, byte_pos, expected_bits, replacement_bits));
    const old_val = ta_mod.readTypedElement(realm, buf, kind, byte_pos);
    const old_bits = readRawBits(buf, size, byte_pos);
    // Compare the width-truncated bit patterns.
    const mask: u64 = if (size == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(size * 8)) - 1;
    if ((old_bits & mask) == (expected_bits & mask)) {
        writeRawBits(buf, size, byte_pos, replacement_bits);
    }
    return old_val;
}

/// §25.4.10 Atomics.load(ta, index).
fn atomicsLoad(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), false);
    const tv = obj.getTypedView().?;
    const buf = tv.viewed.getArrayBuffer().?;
    const idx = try validateAtomicAccess(realm, tv, buf, argOr(args, 1, Value.undefined_));
    const size = tv.kind.elementSize();
    const byte_pos = tv.byte_offset + idx * size;
    if (tv.viewed.isSharedArrayBuffer())
        return bitsToValue(realm, tv.kind, atomicLoadBits(buf, size, byte_pos));
    return ta_mod.readTypedElement(realm, buf, tv.kind, byte_pos);
}

/// §25.4.13 Atomics.store(ta, index, value). Returns the coerced value
/// (NOT the truncated stored bits).
fn atomicsStore(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), false);
    const tv = obj.getTypedView().?;
    const idx = try validateAtomicAccess(realm, tv, tv.viewed.getArrayBuffer().?, argOr(args, 1, Value.undefined_));
    const kind = tv.kind;
    const size = kind.elementSize();
    const coerced = try ta_mod.coerceForTypedSlot(realm, kind, argOr(args, 2, Value.undefined_));
    const buf = tv.viewed.getArrayBuffer() orelse return throwTypeError(realm, "Atomics: buffer detached during coercion");
    const byte_pos = tv.byte_offset + idx * size;
    if (byte_pos + size > buf.len) return throwRangeError(realm, "Atomics: access index out of bounds");
    if (tv.viewed.isSharedArrayBuffer()) {
        // Extract the coerced element's raw bits, then store atomically.
        var scratch = std.mem.zeroes([8]u8);
        ta_mod.writeTypedElement(&scratch, kind, 0, coerced);
        atomicStoreBits(buf, size, byte_pos, readRawBits(&scratch, size, 0));
    } else {
        ta_mod.writeTypedElement(buf, kind, byte_pos, coerced);
    }
    // §25.4.13 step — store returns ToIntegerOrInfinity(value) for
    // non-BigInt element types (normalizing -0 → +0 and truncating the
    // fraction), NOT the width-truncated stored bits.
    if (kind.isBigInt()) return coerced;
    return integerNormalize(coerced);
}

/// ToIntegerOrInfinity applied to an already-ToNumber'd value:
/// truncate the fraction toward zero and normalize -0 to +0.
fn integerNormalize(v: Value) Value {
    const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    if (std.math.isNan(d)) return Value.fromInt32(0);
    if (std.math.isInf(d)) return Value.fromDouble(d);
    const t = @trunc(d);
    if (t == 0) return Value.fromInt32(0); // -0 → +0
    if (t >= -2147483648.0 and t <= 2147483647.0) return Value.fromInt32(@intFromFloat(t));
    return Value.fromDouble(t);
}

/// Atomics.pause(iterationNumber) — a microarchitectural hint
/// (TC39 proposal). Validates an optional integral argument and
/// returns undefined; Cynic has no spin-wait to hint, so it's a no-op.
fn atomicsPause(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const arg = argOr(args, 0, Value.undefined_);
    if (!arg.isUndefined()) {
        // The argument must already be an integral Number (no coercion).
        const integral = blk: {
            if (arg.isInt32()) break :blk true;
            if (!arg.isDouble()) break :blk false;
            const d = arg.asDouble();
            break :blk std.math.isFinite(d) and @trunc(d) == d;
        };
        if (!integral) return throwTypeError(realm, "Atomics.pause: argument must be an integral Number");
    }
    return Value.undefined_;
}

/// §25.4.9 Atomics.isLockFree(size). Lock-free for the platform's
/// 1/2/4/8-byte atomic widths (matching V8 on 64-bit).
fn atomicsIsLockFree(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const n = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const raw: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
    const lock_free = raw == 1 or raw == 2 or raw == 4 or raw == 8;
    return Value.fromBool(lock_free);
}

/// Coerce a `timeout` argument (§25.4.11/.x): `undefined` / `NaN` /
/// `+∞` → `null` (wait forever); else `max(ToInteger(t), 0)` ms as ns.
fn coerceTimeoutNs(realm: *Realm, v: Value) NativeError!?u64 {
    if (v.isUndefined()) return null;
    const n = try toNumber(realm, v);
    const d: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
    if (std.math.isNan(d) or (std.math.isInf(d) and d > 0)) return null;
    const ms = @max(@trunc(d), 0);
    const ns = ms * std.time.ns_per_ms;
    if (ns >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(ns);
}

/// §25.4.12 Atomics.notify(ta, index, count). Wakes up to `count`
/// agents parked in `Atomics.wait` on this (block, index); returns the
/// number woken. A non-shared buffer has no waiters → 0.
fn atomicsNotify(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), true);
    const tv = obj.getTypedView().?;
    const idx = try validateAtomicAccess(realm, tv, tv.viewed.getArrayBuffer().?, argOr(args, 1, Value.undefined_));
    // §25.4.12 — `count` defaults to +∞ (wake all), else max(ToInteger, 0).
    const count_v = argOr(args, 2, Value.undefined_);
    var count: u32 = std.math.maxInt(u32);
    if (!count_v.isUndefined()) {
        const n = try toNumber(realm, count_v);
        const d: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
        const c = @max(@trunc(if (std.math.isNan(d)) 0 else d), 0);
        count = if (std.math.isInf(c) or c > @as(f64, std.math.maxInt(u32))) std.math.maxInt(u32) else @intFromFloat(c);
    }
    // A non-shared buffer never has agents waiting on it. (The block
    // lives on the viewed SharedArrayBuffer, not the TypedArray.)
    const block = tv.viewed.getSharedBlock() orelse return Value.fromInt32(0);
    const byte_pos = tv.byte_offset + idx * tv.kind.elementSize();
    // Wake EXACTLY up to `count` waiters parked on this byte index and
    // report how many, under the wait-list lock.
    block.lockWaiters();
    const woken = block.wakeWaiters(byte_pos, count);
    block.unlockWaiters();
    return Value.fromInt32(@intCast(woken));
}

/// §25.4.11 Atomics.wait(ta, index, value, timeout). Requires a shared
/// Int32Array / BigInt64Array. Parks on the (block, index) wait list
/// until a `notify` wakes it (`"ok"`), the timeout elapses
/// (`"timed-out"`), or — checked up front — the current value differs
/// (`"not-equal"`).
fn atomicsWait(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), true);
    const tv = obj.getTypedView().?;
    // §25.4.11 step 4 — the buffer MUST be shared.
    if (!tv.viewed.isSharedArrayBuffer())
        return throwTypeError(realm, "Atomics.wait requires a shared Int32Array / BigInt64Array");
    const buf = tv.viewed.getArrayBuffer().?;
    const idx = try validateAtomicAccess(realm, tv, buf, argOr(args, 1, Value.undefined_));
    const kind = tv.kind;
    const size = kind.elementSize();
    // §25.4.11 step 6 — coerce `value`; step 7 — coerce `timeout`.
    const value_bits = try coerceRawBits(realm, kind, argOr(args, 2, Value.undefined_));
    const timeout_ns = try coerceTimeoutNs(realm, argOr(args, 3, Value.undefined_));
    const block = tv.viewed.getSharedBlock().?;
    const byte_pos = tv.byte_offset + idx * size;
    const mask: u64 = if (size == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(size * 8)) - 1;

    // §25.4.11 EnterCriticalSection: test the value and add the waiter
    // atomically w.r.t. `notify`, so a `notify` can't slip between the
    // test and the park (lost wakeup). The value read is the SeqCst
    // atomic load (another agent may store concurrently).
    block.lockWaiters();
    if ((atomicLoadBits(buf, size, byte_pos) & mask) != (value_bits & mask)) {
        block.unlockWaiters();
        return atomicsString(realm, "not-equal");
    }
    var w: Waiter = .{ .byte_pos = byte_pos };
    block.addWaiter(&w);
    block.unlockWaiters();

    // No real clock / no other threads on a freestanding target → don't
    // spin forever; unlink and report timed-out.
    if (builtin.os.tag == .freestanding) {
        block.lockWaiters();
        block.removeWaiter(&w);
        block.unlockWaiters();
        return atomicsString(realm, "timed-out");
    }

    // Park by polling our own `woken` flag (raised by `notify` under
    // the lock — so it wakes EXACTLY the agents notify chose). A poll
    // loop with a bounded sleep, because this Zig dev build's
    // std.Thread no longer re-exports Futex/Mutex/Condition; the sleep
    // keeps a parked agent off the CPU.
    const start_ns = monoNowNs();
    while (true) {
        if (w.woken.load(.acquire)) {
            block.lockWaiters();
            block.removeWaiter(&w);
            block.unlockWaiters();
            return atomicsString(realm, "ok");
        }
        if (timeout_ns) |ns| {
            if (monoNowNs() -% start_ns >= ns) {
                // Settle the timeout under the lock: a `notify` racing
                // our deadline either already raised `woken` (→ "ok") or
                // will never find us again (we unlink here), so the
                // woken count and our result can't disagree.
                block.lockWaiters();
                const woken_now = w.woken.load(.acquire);
                block.removeWaiter(&w);
                block.unlockWaiters();
                return atomicsString(realm, if (woken_now) "ok" else "timed-out");
            }
        }
        napNs(wait_poll_ns);
    }
}

fn atomicsString(realm: *Realm, s: []const u8) NativeError!Value {
    const str = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(str);
}

/// §25.4.x Atomics.waitAsync(ta, index, value, timeout). Like `wait`
/// but never blocks: returns a result record `{ async, value }`. A
/// value mismatch → `{ async:false, value:"not-equal" }`; a zero
/// timeout with a matching value → `{ async:false, value:"timed-out" }`;
/// otherwise → `{ async:true, value:<Promise> }`. Single agent: nothing
/// can notify, so the async Promise stays pending (it would resolve
/// `"timed-out"` after the timeout; the cross-agent resolution path is
/// deferred — see docs/sab-atomics.md).
fn atomicsWaitAsync(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), true);
    const tv = obj.getTypedView().?;
    if (!tv.viewed.isSharedArrayBuffer())
        return throwTypeError(realm, "Atomics.waitAsync requires a shared Int32Array / BigInt64Array");
    const buf = tv.viewed.getArrayBuffer().?;
    const idx = try validateAtomicAccess(realm, tv, buf, argOr(args, 1, Value.undefined_));
    const kind = tv.kind;
    const size = kind.elementSize();
    const value_bits = try coerceRawBits(realm, kind, argOr(args, 2, Value.undefined_));
    // Timeout: undefined → +∞; NaN → +∞; else max(ToInteger, 0).
    var timeout_ms: f64 = std.math.inf(f64);
    const timeout_v = argOr(args, 3, Value.undefined_);
    if (!timeout_v.isUndefined()) {
        const n = try toNumber(realm, timeout_v);
        const d: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
        if (!std.math.isNan(d) and !std.math.isInf(d)) timeout_ms = @max(@trunc(d), 0);
    }
    const timeout_zero = (timeout_ms == 0);
    const byte_pos = tv.byte_offset + idx * size;
    const cur_bits = readRawBits(buf, size, byte_pos);
    const mask: u64 = if (size == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(size * 8)) - 1;

    // Root the result object across the Promise-capability allocation.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.object_prototype);
    scope.push(heap_mod.taggedObject(result)) catch {};

    if ((cur_bits & mask) != (value_bits & mask)) {
        try result.set(realm.allocator, "async", Value.false_);
        const s = realm.heap.allocateString("not-equal") catch return error.OutOfMemory;
        try result.set(realm.allocator, "value", Value.fromString(s));
    } else if (timeout_zero) {
        try result.set(realm.allocator, "async", Value.false_);
        const s = realm.heap.allocateString("timed-out") catch return error.OutOfMemory;
        try result.set(realm.allocator, "value", Value.fromString(s));
    } else {
        const promise_ctor = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_) orelse
            return throwTypeError(realm, "Atomics.waitAsync: %Promise% missing");
        const cap = try promise_mod.newPromiseCapability(realm, promise_ctor);
        try result.set(realm.allocator, "async", Value.true_);
        try result.set(realm.allocator, "value", cap.promise);
        // §25.4.1.4 AddWaiter — park on the block's process-global wait
        // list so a cross-agent `notify` finds, counts, and wakes us. The
        // waiting agent settles the Promise on its OWN thread — "ok" if a
        // notify raised the node's `woken`, else "timed-out" at the
        // deadline (`+∞` for an untimed wait, settled only by notify).
        // The capability's resolve function is rooted via `markRoots`.
        const block = tv.viewed.getSharedBlock().?;
        const node = try block.addAsyncWaiter(byte_pos);
        const deadline: f64 = if (std.math.isInf(timeout_ms)) timeout_ms else nowMonoMs() + timeout_ms;
        realm.pending_async_waits.append(realm.allocator, .{
            .resolve = heap_mod.taggedFunction(cap.resolve),
            .deadline_ms = deadline,
            .node = node,
            .block = block,
        }) catch {
            _ = block.settleAndFreeAsyncWaiter(node);
            return error.OutOfMemory;
        };
    }
    return heap_mod.taggedObject(result);
}
