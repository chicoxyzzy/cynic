//! §27.1.4 Iterator (TC39 stage-4 helpers). Installs the
//! `Iterator` global with `Iterator.from(iterable)` and a
//! prototype carrying `.map` / `.filter` / `.take` / `.drop` /
//! `.toArray` / `.forEach` / `.find` / `.some` / `.every` /
//! `.reduce`.
//!
//! Each helper that returns a new iterator (`.map`, `.filter`,
//! `.take`, `.drop`) builds a wrapper object whose `next` method
//! pulls from the source and applies the transform. Eagerly-
//! evaluated helpers (`.toArray`, `.forEach`, etc.) drain the
//! source.
//!
//! All helpers honour the §7.4.10 IteratorClose protocol via
//! `closeIteratorOnThrow` / `closeIteratorNormal`: callback
//! exceptions, non-object IteratorResult, and argument-validation
//! failures all close the underlying iterator before the throw
//! propagates. When the original completion is a throw, errors
//! from `return()` are swallowed (the original throw wins, per
//! step 4 of IteratorClose).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "Iterator", .ctor = iteratorConstructor, .arity = 0,
        .set_home_object = false,
        .to_string_tag = "Iterator",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeMethod(realm, fn_obj, "from", iteratorFrom, 1);
    try installNativeMethod(realm, fn_obj, "concat", iteratorConcat, 0);
    try installNativeMethod(realm, fn_obj, "zip", iteratorZip, 1);
    try installNativeMethod(realm, fn_obj, "zipKeyed", iteratorZipKeyed, 1);

    try installNativeMethodOnProto(realm, proto, "map", iteratorMap, 1);
    try installNativeMethodOnProto(realm, proto, "filter", iteratorFilter, 1);
    try installNativeMethodOnProto(realm, proto, "take", iteratorTake, 1);
    try installNativeMethodOnProto(realm, proto, "drop", iteratorDrop, 1);
    try installNativeMethodOnProto(realm, proto, "toArray", iteratorToArray, 0);
    try installNativeMethodOnProto(realm, proto, "forEach", iteratorForEach, 1);
    try installNativeMethodOnProto(realm, proto, "find", iteratorFind, 1);
    try installNativeMethodOnProto(realm, proto, "some", iteratorSome, 1);
    try installNativeMethodOnProto(realm, proto, "every", iteratorEvery, 1);
    try installNativeMethodOnProto(realm, proto, "reduce", iteratorReduce, 1);
    // Iterators are themselves iterable.
    try installNativeMethodOnProto(realm, proto, "@@iterator", iteratorSymbolIterator, 0);
}

fn iteratorConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.1.4.1 — abstract constructor. Throws when called as a
    // plain function (NewTarget is undefined) or when newTarget
    // is the Iterator function itself; otherwise (subclass
    // construction) returns the freshly allocated `this`.
    const inst = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "Iterator constructor requires 'new'");
    };
    // Cynic doesn't surface NewTarget to natives — approximate
    // by checking the receiver's [[Prototype]]: a direct
    // `new Iterator()` would have %Iterator.prototype% there,
    // a subclass has the subclass's prototype.
    const ctor_v = realm.globals.get("Iterator") orelse return this_value;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return this_value;
    if (inst.prototype == ctor.prototype) {
        return throwTypeError(realm, "Abstract class Iterator not directly constructable");
    }
    return this_value;
}

/// `Iterator.from(x)` — wrap any iterable in an Iterator instance.
fn iteratorFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const inner = interpreter.openIterator(realm.allocator, realm, arg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Iterator.from argument is not iterable"),
    };
    return wrapIterator(realm, inner);
}

/// Wrap a raw iterator object (the kind `openIterator` returns)
/// in a fresh helper object whose prototype is %Iterator.prototype%.
/// The wrapper's `next` delegates to the source iterator's `next`.
fn wrapIterator(realm: *Realm, source: Value) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return source;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return source;
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_source__", source) catch return error.OutOfMemory;
    const next_fn = realm.heap.allocateFunctionNative(wrappedNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn wrappedNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator next on non-object");
    const src = obj.get("__cynic_iter_source__");
    return invokeIterNext(realm, src);
}

fn invokeIterNext(realm: *Realm, iter: Value) NativeError!Value {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "iterator is not an object");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator has no callable next");
    const out = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

/// Accessor-aware [[Get]] on an iterator-result object: if a
/// getter is defined for `key` (own or on the proto chain), call
/// it with `this = recv` and surface any throw. Otherwise fall
/// back to the plain data lookup. Used so a throwing `done` /
/// `value` getter on a user IteratorResult propagates
/// (§7.4.6 IteratorComplete / §7.4.5 IteratorValue).
fn iterGet(realm: *Realm, recv: Value, key: []const u8) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(recv) orelse return Value.undefined_;
    if (interpreter.lookupAccessor(obj, key)) |acc| {
        if (acc.getter) |getter| {
            const out = interpreter.callJSFunction(realm.allocator, realm, getter, recv, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            return switch (out) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
        }
        return Value.undefined_;
    }
    return obj.get(key);
}

fn iteratorSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

// ── Iterator-close protocol (§7.4.10) ──────────────────────────────────────

/// Call `iter.return()` and swallow any throw or absence. Used
/// when the surrounding completion is a throw — per §7.4.10
/// step 4, the original throw wins, so any error produced by
/// `return()` is dropped (along with any pending exception it
/// may have set on the realm).
fn closeIteratorSwallow(realm: *Realm, iter: Value) void {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return;
    const ret_v = iter_obj.get("return");
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    // Preserve pending_exception across the return-call: the
    // caller is mid-throw and the `error.NativeThrew` we'll
    // return next must carry that exception.
    const saved = realm.pending_exception;
    const result = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter, &.{}) catch {
        realm.pending_exception = saved;
        return;
    };
    _ = result;
    realm.pending_exception = saved;
}

/// The callback chain returned `.thrown = ex`. Close the source,
/// stash `ex` into pending_exception so the caller's
/// `error.NativeThrew` carries the original throw forward, and
/// return that error. Centralises the swallow-on-throw idiom for
/// every callback-using helper.
fn callbackThrew(realm: *Realm, src: Value, ex: Value) NativeError {
    realm.pending_exception = ex;
    closeIteratorSwallow(realm, src);
    return error.NativeThrew;
}

/// Variant for the catch-side: `callJSFunction` returned a
/// Zig-level error (the native it called set pending_exception).
/// Preserve that pending exception across the close.
fn callbackErrored(realm: *Realm, src: Value) NativeError {
    closeIteratorSwallow(realm, src);
    return error.NativeThrew;
}

/// Call `iter.return()` and propagate any throw it produces (or
/// any throw that fires while reading the `return` property —
/// callers that need the property-read-throw path resolve it
/// before calling here). Used for normal-completion close paths
/// like `take(0)`-on-exhaustion or a direct `iterator.return()`.
fn closeIteratorPropagate(realm: *Realm, iter: Value) NativeError!void {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return;
    const ret_v = iter_obj.get("return");
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse {
        return throwTypeError(realm, "iterator return is not callable");
    };
    const out = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (out) {
        .value, .yielded => {},
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

/// Argument-validation entry point: `closable.map()` /
/// `.take(NaN)` etc. need to close the iterator before throwing
/// the validation TypeError/RangeError. The helper sets
/// `pending_exception` itself, then calls `return()` swallowing
/// errors so the validation throw wins.
fn throwAfterClose(realm: *Realm, this_value: Value, ex: Value) NativeError {
    realm.pending_exception = ex;
    closeIteratorSwallow(realm, this_value);
    return error.NativeThrew;
}

fn typeErrorAfterClose(realm: *Realm, this_value: Value, msg: []const u8) NativeError {
    const ex = intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
    return throwAfterClose(realm, this_value, ex);
}

fn rangeErrorAfterClose(realm: *Realm, this_value: Value, msg: []const u8) NativeError {
    const ex = intrinsics.newRangeError(realm, msg) catch return error.OutOfMemory;
    return throwAfterClose(realm, this_value, ex);
}

// ── Lazy helpers — return new iterator wrappers ─────────────────────────────

fn iteratorMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.map called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.map callback is not callable");
    }
    return buildLazy(realm, this_value, cb_v, mapNext);
}

fn iteratorFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.filter called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.filter predicate is not callable");
    }
    return buildLazy(realm, this_value, cb_v, filterNext);
}

fn iteratorTake(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.take called on non-object");
    // §27.1.4.x — ToNumber(limit) BEFORE GetIteratorDirect, so a
    // throwing valueOf wins over the iterator-direct lookup.
    const arg = argOr(args, 0, Value.undefined_);
    const num_v = intrinsics.toNumber(realm, arg) catch |err| {
        // Whatever ToNumber threw closes the iterator and the
        // original throw propagates.
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, this_value, ex);
        }
        return err;
    };
    const d: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    if (std.math.isNan(d)) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.take limit is NaN");
    }
    // §7.1.5 ToIntegerOrInfinity then "if integerLimit < 0 throw
    // RangeError" — covered by "< 0" check.
    if (d < 0) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.take limit is negative");
    }
    const limit_clamped: f64 = if (std.math.isInf(d)) std.math.maxInt(i32) else @trunc(d);
    const limit_i32: i32 = if (limit_clamped >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(limit_clamped);
    return buildLazy(realm, this_value, Value.fromInt32(limit_i32), takeNext);
}

fn iteratorDrop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.drop called on non-object");
    const arg = argOr(args, 0, Value.undefined_);
    const num_v = intrinsics.toNumber(realm, arg) catch |err| {
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, this_value, ex);
        }
        return err;
    };
    const d: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    if (std.math.isNan(d)) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.drop limit is NaN");
    }
    if (d < 0) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.drop limit is negative");
    }
    const drop_clamped: f64 = if (std.math.isInf(d)) std.math.maxInt(i32) else @trunc(d);
    const drop_i32: i32 = if (drop_clamped >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(drop_clamped);
    return buildLazy(realm, this_value, Value.fromInt32(drop_i32), dropNext);
}

fn buildLazy(realm: *Realm, source: Value, payload: Value, next_fn: @import("../function.zig").NativeFn) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_source__", source) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_payload__", payload) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(0)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_running__", Value.fromBool(false)) catch return error.OutOfMemory;
    const fn_obj = realm.heap.allocateFunctionNative(next_fn, 0, "next") catch return error.OutOfMemory;
    fn_obj.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(lazyReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

/// `wrapper.return()` — close the underlying iterator if we
/// haven't already observed exhaustion. After exhaustion or a
/// previous return, this is a no-op (matches the
/// `return-is-not-forwarded-after-exhaustion.js` fixtures).
fn lazyReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) {
        return iterResult(realm, Value.undefined_, true);
    }
    obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
    const src = obj.get("__cynic_iter_source__");
    try closeIteratorPropagate(realm, src);
    return iterResult(realm, Value.undefined_, true);
}

fn doneResult(realm: *Realm) NativeError!Value {
    return iterResult(realm, Value.undefined_, true);
}

/// §27.5.3.2 GeneratorValidate step 6: re-entering an iterator
/// helper while it is mid-step is a TypeError. Cynic models the
/// helper as a native — guard each `next` with a "running" bit.
fn checkNotRunning(realm: *Realm, obj: *JSObject) NativeError!void {
    if (intrinsics.toBoolean(obj.get("__cynic_iter_running__"))) {
        return throwTypeError(realm, "Iterator helper is already running");
    }
}

fn markRunning(obj: *JSObject, allocator: std.mem.Allocator) void {
    obj.set(allocator, "__cynic_iter_running__", Value.fromBool(true)) catch {};
}

fn clearRunning(obj: *JSObject, allocator: std.mem.Allocator) void {
    obj.set(allocator, "__cynic_iter_running__", Value.fromBool(false)) catch {};
}

fn mapNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "map iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);
    const src = obj.get("__cynic_iter_source__");
    const result = invokeIterNext(realm, src) catch |err| {
        // `next` itself threw — wrapper is done, but spec does
        // not call return on this path.
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    const cb = heap_mod.valueAsFunction(obj.get("__cynic_iter_payload__")) orelse return doneResult(realm);
    const idx_v = obj.get("__cynic_iter_count__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
    obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
    const args_call = [_]Value{ value, Value.fromInt32(idx) };
    const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Mapper threw. Mark wrapper done and run §7.4.10
            // IteratorClose with the mapper's throw as the
            // surrounding completion — so any return-throw is
            // swallowed (mapper-throws-then-closing-iterator).
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return callbackErrored(realm, src);
        },
    };
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => |ex| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return callbackThrew(realm, src, ex);
        },
    };
    return iterResult(realm, v, false);
}

fn filterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "filter iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);
    const src = obj.get("__cynic_iter_source__");
    const cb = heap_mod.valueAsFunction(obj.get("__cynic_iter_payload__")) orelse return doneResult(realm);
    while (true) {
        const result = invokeIterNext(realm, src) catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (heap_mod.valueAsPlainObject(result) == null) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return typeErrorAfterClose(realm, src, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, result, "done") catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
            return doneResult(realm);
        }
        const idx_v = obj.get("__cynic_iter_count__");
        const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
        obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
        const value = iterGet(realm, result, "value") catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                return callbackErrored(realm, src);
            },
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| {
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                return callbackThrew(realm, src, ex);
            },
        };
        if (pass) return iterResult(realm, value, false);
    }
}

fn takeNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "take iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);
    const limit_v = obj.get("__cynic_iter_payload__");
    const limit: i32 = if (limit_v.isInt32()) limit_v.asInt32() else 0;
    const idx_v = obj.get("__cynic_iter_count__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
    const src = obj.get("__cynic_iter_source__");
    if (idx >= limit) {
        // Spec: when remaining is 0, IteratorClose(iterated,
        // NormalCompletion(undefined)). Errors from `return`
        // propagate (exhaustion-calls-return.js).
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        try closeIteratorPropagate(realm, src);
        return doneResult(realm);
    }
    obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
    const result = invokeIterNext(realm, src) catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    return iterResult(realm, value, false);
}

fn dropNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "drop iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);
    const drop_v = obj.get("__cynic_iter_payload__");
    var drop_remaining: i32 = if (drop_v.isInt32()) drop_v.asInt32() else 0;
    const src = obj.get("__cynic_iter_source__");
    while (drop_remaining > 0) : (drop_remaining -= 1) {
        const r = invokeIterNext(realm, src) catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (heap_mod.valueAsPlainObject(r) == null) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return typeErrorAfterClose(realm, src, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, r, "done") catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
            obj.set(realm.allocator, "__cynic_iter_payload__", Value.fromInt32(0)) catch return error.OutOfMemory;
            return doneResult(realm);
        }
    }
    obj.set(realm.allocator, "__cynic_iter_payload__", Value.fromInt32(0)) catch return error.OutOfMemory;
    const result = invokeIterNext(realm, src) catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
        return err;
    };
    return iterResult(realm, value, false);
}

// ── Eager helpers — drain the source ────────────────────────────────────────

fn iteratorToArray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.toArray called on non-object");
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var idx: i32 = 0;
    var ibuf: [24]u8 = undefined;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, value) catch return error.OutOfMemory;
        idx += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn iteratorForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.forEach called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.forEach callback is not callable");
    };
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        switch (out) {
            .value, .yielded => {},
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        }
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.find called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.find predicate is not callable");
    };
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (pass) {
            // Found a match — close the iterator and return.
            closeIteratorSwallow(realm, this_value);
            return value;
        }
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorSome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.some called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.some predicate is not callable");
    };
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (pass) {
            closeIteratorSwallow(realm, this_value);
            return Value.fromBool(true);
        }
        idx += 1;
    }
    return Value.fromBool(false);
}

fn iteratorEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.every called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.every predicate is not callable");
    };
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (!pass) {
            closeIteratorSwallow(realm, this_value);
            return Value.fromBool(false);
        }
        idx += 1;
    }
    return Value.fromBool(true);
}

fn iteratorReduce(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.reduce called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.reduce reducer is not callable");
    };
    var has_acc: bool = args.len >= 2;
    var acc: Value = if (has_acc) args[1] else Value.undefined_;
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        if (!has_acc) {
            acc = value;
            has_acc = true;
            idx += 1;
            continue;
        }
        const args_call = [_]Value{ acc, value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        acc = switch (out) {
            .value, .yielded => |x| x,
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        idx += 1;
    }
    if (!has_acc) return throwTypeError(realm, "Iterator.prototype.reduce on empty iterator with no initial value");
    return acc;
}

fn iterResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}

// ── §27.1.4.2 / 27.1.4.3 / 27.1.4.4 — Iterator.concat / zip / zipKeyed ──────

/// §7.4.4 GetMethod-style read of `@@iterator`. Returns the
/// callable, or null when the property is undefined / null /
/// absent. Throws TypeError if present-and-not-callable.
fn getIteratorMethod(realm: *Realm, v: Value) NativeError!?*JSFunction {
    const obj = heap_mod.valueAsPlainObject(v) orelse return null;
    const m = obj.get("@@iterator");
    if (m.isUndefined() or m.isNull()) return null;
    if (heap_mod.valueAsFunction(m)) |fn_| return fn_;
    return throwTypeError(realm, "@@iterator is not callable");
}

/// `iterable[Symbol.iterator]()` — calls the method, validates the
/// result is an Object, returns the raw iterator.
fn callIteratorMethod(realm: *Realm, iter_fn: *JSFunction, this_v: Value) NativeError!Value {
    const out = interpreter.callJSFunction(realm.allocator, realm, iter_fn, this_v, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    if (heap_mod.valueAsPlainObject(v) == null) {
        return throwTypeError(realm, "iterator method did not return an object");
    }
    return v;
}

/// §7.4.6 GetIteratorFlattenable. `reject_strings` selects the
/// `reject-strings` variant (used by zip / zipKeyed) — a plain
/// String primitive throws. The non-reject variant is used by
/// `Iterator.from` (which already opens via `openIterator`).
/// Returns a raw iterator object (an Object with a `next`
/// method).
fn getIteratorFlattenable(realm: *Realm, v: Value, reject_strings: bool) NativeError!Value {
    if (heap_mod.valueAsPlainObject(v) == null) {
        if (reject_strings) {
            return throwTypeError(realm, "iterable is not an object");
        }
        if (!v.isString()) return throwTypeError(realm, "iterable is not an object");
        // string primitive — fall through with the string-as-value path.
        // (Cynic doesn't yet have a String iterator, so reject anyway for safety.)
        return throwTypeError(realm, "iterable is a primitive");
    }
    const obj = heap_mod.valueAsPlainObject(v).?;
    const m_v = obj.get("@@iterator");
    if (m_v.isUndefined() or m_v.isNull()) {
        // No @@iterator — treat `v` itself as the iterator (must
        // expose a `next`).
        return v;
    }
    const m_fn = heap_mod.valueAsFunction(m_v) orelse {
        return throwTypeError(realm, "@@iterator is not callable");
    };
    return callIteratorMethod(realm, m_fn, v);
}

// Slot-name builders. We store list-shaped state as numbered
// keys on the wrapper object so the existing per-property
// machinery (and the GC) handle visibility for free.
fn slotName(buf: *[40]u8, prefix: []const u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}__", .{ prefix, i }) catch unreachable;
}

/// `Iterator.concat(...iterables)` — §27.1.4.2.
fn iteratorConcat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // Step 1-2: validate every input up-front. Each must be an
    // Object whose `@@iterator` is callable. Capture the method
    // here (accessor-aware) — spec records {[[OpenMethod]],
    // [[Iterable]]} so a `get [Symbol.iterator]()` getter runs
    // exactly once per arg, at construction.
    var captured_methods = std.ArrayListUnmanaged(*JSFunction).empty;
    defer captured_methods.deinit(realm.allocator);
    for (args) |item| {
        if (heap_mod.valueAsPlainObject(item) == null) {
            return throwTypeError(realm, "Iterator.concat argument is not an object");
        }
        const m = try iterGet(realm, item, "@@iterator");
        if (m.isUndefined() or m.isNull()) {
            return throwTypeError(realm, "Iterator.concat argument has no @@iterator");
        }
        const m_fn = heap_mod.valueAsFunction(m) orelse {
            return throwTypeError(realm, "Iterator.concat argument @@iterator is not callable");
        };
        captured_methods.append(realm.allocator, m_fn) catch return error.OutOfMemory;
    }

    // Build the wrapper. State:
    //   __cynic_iter_count__   : i32 number of inputs
    //   __cynic_iter_idx__     : i32 current input index
    //   __cynic_iter_input_<i>__ : input iterable (the user's object)
    //   __cynic_iter_method_<i>__: captured @@iterator method
    //   __cynic_iter_active__  : currently-open inner iterator (or undef)
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(0)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_running__", Value.fromBool(false)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_active__", Value.undefined_) catch return error.OutOfMemory;
    var sbuf: [40]u8 = undefined;
    for (args, 0..) |item, i| {
        const owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_input_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned.bytes, item) catch return error.OutOfMemory;
        const m_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_method_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, m_owned.bytes, heap_mod.taggedFunction(captured_methods.items[i])) catch return error.OutOfMemory;
    }

    const next_fn = realm.heap.allocateFunctionNative(concatNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(concatReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn concatReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) {
        return iterResult(realm, Value.undefined_, true);
    }
    obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
    const active = obj.get("__cynic_iter_active__");
    if (heap_mod.valueAsPlainObject(active) != null) {
        try closeIteratorPropagate(realm, active);
    }
    return iterResult(realm, Value.undefined_, true);
}

fn concatNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "concat iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);

    const count_v = obj.get("__cynic_iter_count__");
    const count: i32 = if (count_v.isInt32()) count_v.asInt32() else 0;
    var idx_v = obj.get("__cynic_iter_idx__");
    var idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
    var sbuf: [40]u8 = undefined;

    while (idx < count) {
        var active = obj.get("__cynic_iter_active__");
        if (heap_mod.valueAsPlainObject(active) == null) {
            // Open input[idx]. Per spec, errors here propagate
            // (no in-flight inner iterator to close).
            const slot = slotName(&sbuf, "__cynic_iter_input_", @intCast(idx));
            const input_v = obj.get(slot);
            var sbuf2: [40]u8 = undefined;
            const m_slot = slotName(&sbuf2, "__cynic_iter_method_", @intCast(idx));
            const m_v = obj.get(m_slot);
            const m_fn = heap_mod.valueAsFunction(m_v) orelse {
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                return throwTypeError(realm, "Iterator.concat captured method missing");
            };
            const inner = callIteratorMethod(realm, m_fn, input_v) catch |err| {
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                return err;
            };
            obj.set(realm.allocator, "__cynic_iter_active__", inner) catch return error.OutOfMemory;
            active = inner;
        }

        const result = invokeIterNext(realm, active) catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (heap_mod.valueAsPlainObject(result) == null) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return typeErrorAfterClose(realm, active, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, result, "done") catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            // Inner exhausted — clear active, advance to next input.
            obj.set(realm.allocator, "__cynic_iter_active__", Value.undefined_) catch return error.OutOfMemory;
            idx += 1;
            obj.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(idx)) catch return error.OutOfMemory;
            idx_v = Value.fromInt32(idx);
            continue;
        }
        const value = iterGet(realm, result, "value") catch |err| {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
            return err;
        };
        return iterResult(realm, value, false);
    }

    obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
    return doneResult(realm);
}

// ── Iterator.zip / Iterator.zipKeyed shared machinery ───────────────────────

const ZipMode = enum(i32) { shortest = 0, longest = 1, strict = 2 };

/// Read + validate `options.mode`. Returns the parsed mode.
fn readZipMode(realm: *Realm, options_v: Value) NativeError!ZipMode {
    if (options_v.isUndefined()) return .shortest;
    const opts = heap_mod.valueAsPlainObject(options_v) orelse {
        return throwTypeError(realm, "Iterator.zip options must be an object");
    };
    const mode_v = try iterGet(realm, heap_mod.taggedObject(opts), "mode");
    if (mode_v.isUndefined()) return .shortest;
    if (!mode_v.isString()) return throwTypeError(realm, "Iterator.zip 'mode' must be a string");
    const s: *JSString = @ptrCast(@alignCast(mode_v.asString()));
    if (std.mem.eql(u8, s.bytes, "shortest")) return .shortest;
    if (std.mem.eql(u8, s.bytes, "longest")) return .longest;
    if (std.mem.eql(u8, s.bytes, "strict")) return .strict;
    return throwTypeError(realm, "Iterator.zip 'mode' must be 'shortest', 'longest', or 'strict'");
}

/// Read + validate `options.padding`. Returns null when absent;
/// returns the padding object otherwise. Only consulted in
/// "longest" mode.
fn readZipPadding(realm: *Realm, options_v: Value) NativeError!?*JSObject {
    if (options_v.isUndefined()) return null;
    const opts = heap_mod.valueAsPlainObject(options_v) orelse return null;
    const pad_v = try iterGet(realm, heap_mod.taggedObject(opts), "padding");
    if (pad_v.isUndefined()) return null;
    const pad_obj = heap_mod.valueAsPlainObject(pad_v) orelse {
        return throwTypeError(realm, "Iterator.zip 'padding' must be an object");
    };
    return pad_obj;
}

/// Close every iter in `iters[start..]` (forward index order),
/// swallowing errors so the caller's pending throw wins.
fn closeAllSwallow(realm: *Realm, iters: []const Value, start: usize) void {
    var i: usize = start;
    while (i < iters.len) : (i += 1) {
        closeIteratorSwallow(realm, iters[i]);
    }
}

/// Open every entry of an iterables-iterable (zip's `iterables`
/// argument — itself iterable — yielding objects to pass through
/// `GetIteratorFlattenable(reject-strings)`). Returns the
/// collected raw-iterator list. On any throw, closes already-
/// opened inner iters and the input iterator before propagating.
fn collectZipIters(realm: *Realm, iterables_v: Value) NativeError![]Value {
    if (heap_mod.valueAsPlainObject(iterables_v) == null) {
        return throwTypeError(realm, "Iterator.zip iterables must be an object");
    }
    const input_iter = interpreter.openIterator(realm.allocator, realm, iterables_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Iterator.zip iterables is not iterable"),
    };
    var iters: std.ArrayListUnmanaged(Value) = .empty;
    errdefer iters.deinit(realm.allocator);
    while (true) {
        const r = invokeIterNext(realm, input_iter) catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            iters.deinit(realm.allocator);
            return err;
        };
        if (heap_mod.valueAsPlainObject(r) == null) {
            closeAllSwallow(realm, iters.items, 0);
            iters.deinit(realm.allocator);
            return typeErrorAfterClose(realm, input_iter, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, r, "done") catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            iters.deinit(realm.allocator);
            return err;
        };
        if (intrinsics.toBoolean(done_v)) break;
        const value = iterGet(realm, r, "value") catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            iters.deinit(realm.allocator);
            return err;
        };
        const sub_iter = getIteratorFlattenable(realm, value, true) catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            closeIteratorSwallow(realm, input_iter);
            iters.deinit(realm.allocator);
            return err;
        };
        iters.append(realm.allocator, sub_iter) catch {
            closeAllSwallow(realm, iters.items, 0);
            iters.deinit(realm.allocator);
            return error.OutOfMemory;
        };
    }
    return iters.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

/// Allocate the zip wrapper and stash the iterator list, mode,
/// padding list, and (optional) keys list as numbered slots.
/// `keys == null` builds zip; non-null builds zipKeyed.
fn buildZipWrapper(
    realm: *Realm,
    iters: []const Value,
    mode: ZipMode,
    padding: ?*JSObject,
    keys: ?[]const []const u8,
) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(@intCast(iters.len))) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_mode__", Value.fromInt32(@intFromEnum(mode))) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_running__", Value.fromBool(false)) catch return error.OutOfMemory;

    var sbuf: [40]u8 = undefined;
    for (iters, 0..) |it, i| {
        const owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_zip_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned.bytes, it) catch return error.OutOfMemory;
        const owned_a = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_active_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned_a.bytes, Value.fromBool(true)) catch return error.OutOfMemory;
    }

    if (keys) |ks| {
        for (ks, 0..) |k, i| {
            const k_owned = realm.heap.allocateString(k) catch return error.OutOfMemory;
            const slot_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_key_", i)) catch return error.OutOfMemory;
            // Store the (heap-owned) key string as a Value so the
            // GC keeps it alive.
            const k_value = Value.fromString(k_owned);
            wrap.set(realm.allocator, slot_owned.bytes, k_value) catch return error.OutOfMemory;
        }
        wrap.set(realm.allocator, "__cynic_iter_keyed__", Value.fromBool(true)) catch return error.OutOfMemory;
    } else {
        wrap.set(realm.allocator, "__cynic_iter_keyed__", Value.fromBool(false)) catch return error.OutOfMemory;
    }

    // Padding storage. §27.1.4.3 step 14b: open the padding via
    // GetIterator(sync), pull `iterCount` values, fill the rest
    // with undefined. We do this eagerly at construction time so
    // a non-iterable padding throws here (matching the spec's
    // up-front order: padding-iter is opened *before* any input
    // iterator step). If we run out of padding values, the slot
    // is left empty (reads return undefined).
    if (mode == .longest and padding != null and iters.len > 0) {
        const pad_obj = padding.?;
        const pad_iter = interpreter.openIterator(realm.allocator, realm, heap_mod.taggedObject(pad_obj)) catch |err| switch (err) {
            error.OutOfMemory => {
                // Already-collected iters need closing.
                closeAllSwallow(realm, iters, 0);
                return error.OutOfMemory;
            },
            else => {
                closeAllSwallow(realm, iters, 0);
                return throwTypeError(realm, "Iterator.zip 'padding' is not iterable");
            },
        };
        var still_active = true;
        for (iters, 0..) |_, i| {
            const slot_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_pad_", i)) catch return error.OutOfMemory;
            if (still_active) {
                const r = invokeIterNext(realm, pad_iter) catch |err| {
                    closeAllSwallow(realm, iters, 0);
                    return err;
                };
                if (heap_mod.valueAsPlainObject(r) == null) {
                    closeAllSwallow(realm, iters, 0);
                    return typeErrorAfterClose(realm, pad_iter, "padding iterator result is not an object");
                }
                const done_v = iterGet(realm, r, "done") catch |err| {
                    closeAllSwallow(realm, iters, 0);
                    return err;
                };
                if (intrinsics.toBoolean(done_v)) {
                    still_active = false;
                    wrap.set(realm.allocator, slot_owned.bytes, Value.undefined_) catch return error.OutOfMemory;
                    continue;
                }
                const value = iterGet(realm, r, "value") catch |err| {
                    closeAllSwallow(realm, iters, 0);
                    return err;
                };
                wrap.set(realm.allocator, slot_owned.bytes, value) catch return error.OutOfMemory;
            } else {
                wrap.set(realm.allocator, slot_owned.bytes, Value.undefined_) catch return error.OutOfMemory;
            }
        }
        // If we read every slot but the iterator wasn't exhausted,
        // close it (NormalCompletion).
        if (still_active) {
            closeIteratorPropagate(realm, pad_iter) catch |err| {
                closeAllSwallow(realm, iters, 0);
                return err;
            };
        }
    }

    const next_fn = realm.heap.allocateFunctionNative(zipNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(zipReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn zipReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) {
        return iterResult(realm, Value.undefined_, true);
    }
    obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
    const count_v = obj.get("__cynic_iter_count__");
    const count: i32 = if (count_v.isInt32()) count_v.asInt32() else 0;
    var sbuf: [40]u8 = undefined;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        if (!intrinsics.toBoolean(obj.get(a_slot))) continue;
        var sbuf2: [40]u8 = undefined;
        const z_slot = slotName(&sbuf2, "__cynic_iter_zip_", @intCast(i));
        const it_v = obj.get(z_slot);
        closeIteratorSwallow(realm, it_v);
    }
    return iterResult(realm, Value.undefined_, true);
}

fn zipNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "zip iter on non-object");
    try checkNotRunning(realm, obj);
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    markRunning(obj, realm.allocator);
    defer clearRunning(obj, realm.allocator);

    const count_v = obj.get("__cynic_iter_count__");
    const count: i32 = if (count_v.isInt32()) count_v.asInt32() else 0;
    if (count == 0) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    const mode_v = obj.get("__cynic_iter_mode__");
    const mode_int: i32 = if (mode_v.isInt32()) mode_v.asInt32() else 0;
    const mode: ZipMode = @enumFromInt(mode_int);
    const keyed = intrinsics.toBoolean(obj.get("__cynic_iter_keyed__"));

    // Build the result holder. zip yields Array exotics, zipKeyed
    // yields a *null-prototype* OrdinaryObject (§27.1.4.4 step 16).
    const result_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (keyed) {
        result_obj.prototype = null;
    } else {
        result_obj.prototype = realm.intrinsics.array_prototype;
    }

    var sbuf: [40]u8 = undefined;
    var any_active: bool = false;
    var any_inactive: bool = false;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        const active = intrinsics.toBoolean(obj.get(a_slot));
        if (active) {
            var sbuf2: [40]u8 = undefined;
            const z_slot = slotName(&sbuf2, "__cynic_iter_zip_", @intCast(i));
            const it_v = obj.get(z_slot);
            const r = invokeIterNext(realm, it_v) catch |err| {
                // §7.4.10 IfAbruptCloseIterators: close every
                // iter (including i — it threw before being
                // removed from openIters).
                obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                closeAllExcept(realm, obj, count, -1);
                return err;
            };
            if (heap_mod.valueAsPlainObject(r) == null) {
                obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                closeAllExcept(realm, obj, count, -1);
                return throwTypeError(realm, "Iterator result is not an object");
            }
            const done_v = iterGet(realm, r, "done") catch |err| {
                obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                closeAllExcept(realm, obj, count, -1);
                return err;
            };
            if (intrinsics.toBoolean(done_v)) {
                obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch return error.OutOfMemory;
                any_inactive = true;
                switch (mode) {
                    .shortest => {
                        // Stop and close the rest (i is removed
                        // from openIters per spec).
                        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
                        closeAllExcept(realm, obj, count, i);
                        return doneResult(realm);
                    },
                    .strict => {
                        if (i == 0) {
                            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
                            closeAllExcept(realm, obj, count, i);
                            return doneResult(realm);
                        }
                        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
                        closeAllExcept(realm, obj, count, i);
                        return throwTypeError(realm, "Iterator.zip strict: iterator exhausted before others");
                    },
                    .longest => {
                        const p_slot = slotName(&sbuf2, "__cynic_iter_pad_", @intCast(i));
                        const pv = obj.get(p_slot);
                        try storeZipResult(realm, obj, result_obj, @intCast(i), pv, keyed);
                        continue;
                    },
                }
            }
            const value = iterGet(realm, r, "value") catch |err| {
                obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
                obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch {};
                closeAllExcept(realm, obj, count, -1);
                return err;
            };
            try storeZipResult(realm, obj, result_obj, @intCast(i), value, keyed);
            any_active = true;
        } else {
            any_inactive = true;
            // strict mode shouldn't reach here normally — once any
            // becomes inactive, we either errored or finished. For
            // longest, pad.
            switch (mode) {
                .longest => {
                    var sbuf2: [40]u8 = undefined;
                    const p_slot = slotName(&sbuf2, "__cynic_iter_pad_", @intCast(i));
                    const pv = obj.get(p_slot);
                    try storeZipResult(realm, obj, result_obj, @intCast(i), pv, keyed);
                },
                else => {
                    // Shouldn't happen — _done_ would have been true.
                    obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
                    return doneResult(realm);
                },
            }
        }
    }

    if (mode == .longest and !any_active and any_inactive) {
        // Every iter exhausted — done.
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }

    if (!keyed) {
        result_obj.setWithFlags(realm.allocator, "length", Value.fromInt32(count), .{
            .writable = true,
            .enumerable = false,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    return iterResult(realm, heap_mod.taggedObject(result_obj), false);
}

/// Store result[idx] for zip / zipKeyed. For zip, key is the
/// numeric index as a string. For zipKeyed, the key was captured
/// at construction time in `__cynic_iter_key_<i>__`.
fn storeZipResult(
    realm: *Realm,
    wrap: *JSObject,
    result_obj: *JSObject,
    i: usize,
    value: Value,
    keyed: bool,
) NativeError!void {
    if (keyed) {
        var sbuf: [40]u8 = undefined;
        const k_slot = slotName(&sbuf, "__cynic_iter_key_", i);
        const k_v = wrap.get(k_slot);
        if (k_v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(k_v.asString()));
            result_obj.set(realm.allocator, s.bytes, value) catch return error.OutOfMemory;
        }
    } else {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result_obj.set(realm.allocator, owned.bytes, value) catch return error.OutOfMemory;
    }
}

/// §7.4.13 IteratorCloseAll over every still-active iter in
/// `obj`. Pass `skip_idx = -1` to close every iter; pass the
/// index of an iter the caller just observed done (already
/// removed from openIters by the spec) to skip it. Iters close
/// in reverse order; throws from `return()` are swallowed (the
/// caller is mid-throw or mid-return, and we don't propagate new
/// errors out of close-all).
fn closeAllExcept(realm: *Realm, obj: *JSObject, count: i32, skip_idx: i32) void {
    var sbuf: [40]u8 = undefined;
    var i: i32 = count - 1;
    while (i >= 0) : (i -= 1) {
        if (i == skip_idx) continue;
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        if (!intrinsics.toBoolean(obj.get(a_slot))) continue;
        var sbuf2: [40]u8 = undefined;
        const z_slot = slotName(&sbuf2, "__cynic_iter_zip_", @intCast(i));
        const it_v = obj.get(z_slot);
        closeIteratorSwallow(realm, it_v);
        obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
    }
}

/// `Iterator.zip(iterables, options?)` — §27.1.4.3.
fn iteratorZip(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const iterables_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(iterables_v) == null) {
        return throwTypeError(realm, "Iterator.zip iterables must be an object");
    }
    const options_v = argOr(args, 1, Value.undefined_);
    if (!options_v.isUndefined() and heap_mod.valueAsPlainObject(options_v) == null) {
        return throwTypeError(realm, "Iterator.zip options must be an object");
    }
    const mode = try readZipMode(realm, options_v);
    const padding = if (mode == .longest) try readZipPadding(realm, options_v) else null;

    const iters = try collectZipIters(realm, iterables_v);
    defer realm.allocator.free(iters);
    return buildZipWrapper(realm, iters, mode, padding, null);
}

/// `Iterator.zipKeyed(iterables, options?)` — §27.1.4.4.
fn iteratorZipKeyed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const iterables_v = argOr(args, 0, Value.undefined_);
    const iterables_obj = heap_mod.valueAsPlainObject(iterables_v) orelse {
        return throwTypeError(realm, "Iterator.zipKeyed iterables must be an object");
    };
    const options_v = argOr(args, 1, Value.undefined_);
    if (!options_v.isUndefined() and heap_mod.valueAsPlainObject(options_v) == null) {
        return throwTypeError(realm, "Iterator.zipKeyed options must be an object");
    }
    const mode = try readZipMode(realm, options_v);
    const padding = if (mode == .longest) try readZipPadding(realm, options_v) else null;

    // §27.1.4.4 step 10-12 — walk own property keys (in spec
    // order), filter to enumerable own data/accessor descriptors,
    // skip undefined values, and open each via
    // GetIteratorFlattenable.
    const all_keys = try @import("object.zig").ownPropertyKeysOrdered(realm, iterables_obj);
    defer realm.allocator.free(all_keys);

    var iters: std.ArrayListUnmanaged(Value) = .empty;
    defer iters.deinit(realm.allocator);
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (keys.items) |k| realm.allocator.free(k);
        keys.deinit(realm.allocator);
    }

    for (all_keys) |key| {
        // §10.1.5 [[GetOwnProperty]] — only enumerable own
        // descriptors qualify.
        const flags = iterables_obj.flagsFor(key);
        const has_data = iterables_obj.properties.contains(key);
        const has_acc = iterables_obj.accessors.contains(key);
        if (!has_data and !has_acc) continue;
        if (!flags.enumerable) continue;
        const v = iterGet(realm, iterables_v, key) catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            return err;
        };
        if (v.isUndefined()) continue;
        const sub_iter = getIteratorFlattenable(realm, v, true) catch |err| {
            closeAllSwallow(realm, iters.items, 0);
            return err;
        };
        // Copy the key into our owned storage so we keep the
        // identity stable even if the underlying property string
        // gets recycled.
        const owned_key = realm.allocator.dupe(u8, key) catch {
            closeAllSwallow(realm, iters.items, 0);
            closeIteratorSwallow(realm, sub_iter);
            return error.OutOfMemory;
        };
        keys.append(realm.allocator, owned_key) catch {
            realm.allocator.free(owned_key);
            closeAllSwallow(realm, iters.items, 0);
            closeIteratorSwallow(realm, sub_iter);
            return error.OutOfMemory;
        };
        iters.append(realm.allocator, sub_iter) catch {
            closeAllSwallow(realm, iters.items, 0);
            return error.OutOfMemory;
        };
    }

    return buildZipWrapper(realm, iters.items, mode, padding, keys.items);
}
