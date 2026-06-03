//! §25.4 Atomics — single-agent.
//!
//! Cynic is single-agent-per-isolate, so the read-modify-write / load
//! / store / compareExchange / isLockFree operations are ordinary
//! sequential operations on the integer typed array's backing store
//! (shared OR non-shared — Atomics is not restricted to shared
//! buffers, except `wait`). `notify` always returns 0 (no other agent
//! waits) and `wait` returns only `"not-equal"` / `"timed-out"`.
//! Cross-agent `wait`/`notify` and the memory model are deferred —
//! see `docs/sab-atomics.md`.

const std = @import("std");

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
    ta_mod.writeTypedElement(buf, kind, byte_pos, coerced);
    return coerced;
}

/// §25.4.9 Atomics.isLockFree(size). Lock-free for the platform's
/// 1/2/4/8-byte atomic widths (matching V8 on 64-bit).
fn atomicsIsLockFree(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const n = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const raw: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
    const lock_free = raw == 1 or raw == 2 or raw == 4 or raw == 8;
    return Value.fromBool(lock_free);
}

/// §25.4.12 Atomics.notify(ta, index, count). Single agent → 0 waiters.
fn atomicsNotify(realm: *Realm, _: Value, args: []const Value) NativeError!Value {
    const obj = try validateIntegerTypedArray(realm, argOr(args, 0, Value.undefined_), true);
    const tv = obj.getTypedView().?;
    _ = try validateAtomicAccess(realm, tv, tv.viewed.getArrayBuffer().?, argOr(args, 1, Value.undefined_));
    // §25.4.12 step — `count` defaults to +Infinity, else max(ToInteger, 0).
    // The value is unused on a single agent but its coercion is observable.
    const count_v = argOr(args, 2, Value.undefined_);
    if (!count_v.isUndefined()) _ = try toNumber(realm, count_v);
    // No other agent waits on this location → 0 awoken.
    return Value.fromInt32(0);
}

/// §25.4.11 Atomics.wait(ta, index, value, timeout). Requires a shared
/// Int32Array / BigInt64Array. Single agent: returns `"not-equal"` when
/// the current value differs, else `"timed-out"` (no agent can notify).
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
    // §25.4.11 step 6 — coerce `value` to the element type's bits.
    const value_bits = try coerceRawBits(realm, kind, argOr(args, 2, Value.undefined_));
    // §25.4.11 step 7 — coerce `timeout` (observable; the value is
    // unused single-agent since a matching wait can never be notified).
    const timeout_v = argOr(args, 3, Value.undefined_);
    if (!timeout_v.isUndefined()) _ = try toNumber(realm, timeout_v);
    const byte_pos = tv.byte_offset + idx * size;
    const cur_bits = readRawBits(buf, size, byte_pos);
    const mask: u64 = if (size == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(size * 8)) - 1;
    // §25.4.11 — value mismatch returns "not-equal" immediately;
    // otherwise, with no agent able to notify, the wait times out.
    const result: []const u8 = if ((cur_bits & mask) != (value_bits & mask)) "not-equal" else "timed-out";
    const s = realm.heap.allocateString(result) catch return error.OutOfMemory;
    return Value.fromString(s);
}
