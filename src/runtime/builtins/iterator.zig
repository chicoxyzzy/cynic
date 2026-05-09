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
