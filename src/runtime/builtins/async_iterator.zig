//! §27.6.1 %AsyncFromSyncIteratorPrototype% — the hidden
//! intrinsic that adapts a sync iterator into an async one. The
//! `for await (… of syncIterable)` lowering and async-generator
//! `yield* syncIterable` both go through this wrapper: each call
//! to `next` / `return` / `throw` returns a Promise built via
//! NewPromiseCapability, with §27.6.1.5 Async-from-Sync Iterator
//! Value Unwrap semantics for the inner `value` field.
//!
//! The wrapper is allocated by `createAsyncFromSyncIterator` —
//! the inner sync iterator is stashed as the hidden
//! `__cynic_sync_iter__` property so it gets GC-traced through
//! the normal object property scan.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");
const toBoolean = @import("../interpreter_arith.zig").toBoolean;

const SYNC_ITER_SLOT = "__cynic_sync_iter__";

/// §27.6.1 — lazily install `%AsyncFromSyncIteratorPrototype%`
/// on the realm. The proto inherits `%AsyncIteratorPrototype%`
/// (so `@@asyncIterator` returns `this`) and carries `next`,
/// `return`, `throw`.
pub fn ensureAsyncFromSyncIteratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.async_from_sync_iterator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    proto.prototype = try interpreter.ensureAsyncIteratorPrototype(realm);

    try installMethod(realm, proto, "next", afsiNext, 1);
    try installMethod(realm, proto, "return", afsiReturn, 1);
    try installMethod(realm, proto, "throw", afsiThrow, 1);

    realm.intrinsics.async_from_sync_iterator_prototype = proto;
    return proto;
}

fn installMethod(realm: *Realm, proto: *JSObject, name: []const u8, native: anytype, params: u8) !void {
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, name);
    fn_obj.has_construct = false;
    fn_obj.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, name, heap_mod.taggedFunction(fn_obj), .{
        .writable = true, .enumerable = false, .configurable = true,
    });
}

/// §27.6.1.1 CreateAsyncFromSyncIterator — wrap `sync_iter` in a
/// fresh object whose proto is `%AsyncFromSyncIteratorPrototype%`.
/// The inner sync iterator lives on the hidden
/// `__cynic_sync_iter__` slot.
pub fn createAsyncFromSyncIterator(realm: *Realm, sync_iter: Value) !Value {
    const proto = try ensureAsyncFromSyncIteratorPrototype(realm);
    const obj = try realm.heap.allocateObject();
    obj.prototype = proto;
    try obj.set(realm.allocator, SYNC_ITER_SLOT, sync_iter);
    return heap_mod.taggedObject(obj);
}

/// Pull the wrapped sync iter Value out of `this_value`. Returns
/// null if `this_value` isn't a real async-from-sync wrapper
/// (per the brand check in §27.6.1.{2,3,4} step 1).
fn syncIterOf(this_value: Value) ?Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const v = obj.properties.get(SYNC_ITER_SLOT) orelse return null;
    return v;
}

fn rejectedPromise(realm: *Realm, ex: Value) NativeError!Value {
    return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
}

fn fulfilledPromise(realm: *Realm, v: Value) NativeError!Value {
    return intrinsics_mod.allocatePromiseFor(realm, null, .fulfilled, v) catch return error.OutOfMemory;
}

fn brandReject(realm: *Realm) NativeError!Value {
    const ex = intrinsics_mod.newTypeError(realm, "AsyncFromSyncIterator method called on incompatible receiver") catch return error.OutOfMemory;
    return rejectedPromise(realm, ex);
}

/// §27.6.1.2 %AsyncFromSyncIteratorPrototype%.next ( value )
fn afsiNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const sync_iter_v = syncIterOf(this_value) orelse return brandReject(realm);
    const sync_iter_obj = heap_mod.valueAsPlainObject(sync_iter_v) orelse return brandReject(realm);

    // §27.6.1.2 step 5 — IteratorNext(syncIteratorRecord[, value]).
    const next_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "next") catch {
        const ex = interpreter.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "sync iterator .next read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    const next_fn = heap_mod.valueAsFunction(next_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "sync iterator .next is not callable") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };

    // §27.6.1.2 steps 5–6 — forward `value` only when present.
    const call_result = if (args.len > 0)
        interpreter.callJSFunction(realm.allocator, realm, next_fn, sync_iter_v, args) catch return error.OutOfMemory
    else
        interpreter.callJSFunction(realm.allocator, realm, next_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;

    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    return processIterResult(realm, result_v);
}

/// §27.6.1.3 %AsyncFromSyncIteratorPrototype%.return ( value )
fn afsiReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const sync_iter_v = syncIterOf(this_value) orelse return brandReject(realm);
    const sync_iter_obj = heap_mod.valueAsPlainObject(sync_iter_v) orelse return brandReject(realm);
    const passed_value = if (args.len > 0) args[0] else Value.undefined_;

    // §27.6.1.3 step 5 — GetMethod(syncIterator, "return").
    const ret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
        const ex = interpreter.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "sync iterator .return read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    // §27.6.1.3 step 7 — return method undefined → fulfill with
    // `{value, done: true}`.
    if (ret_v.isUndefined() or ret_v.isNull()) {
        const result = try genResult(realm, passed_value, true);
        return fulfilledPromise(realm, result);
    }
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "sync iterator .return is not callable") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };

    // §27.6.1.3 step 9 — Call(return, syncIterator, « value »).
    const call_result = if (args.len > 0)
        interpreter.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, args) catch return error.OutOfMemory
    else
        interpreter.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;
    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    // §27.6.1.3 step 11 — result must be Object.
    if (heap_mod.valueAsPlainObject(result_v) == null) {
        const ex = intrinsics_mod.newTypeError(realm, "iterator .return() result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    }
    return processIterResult(realm, result_v);
}

/// §27.6.1.4 %AsyncFromSyncIteratorPrototype%.throw ( value )
fn afsiThrow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const sync_iter_v = syncIterOf(this_value) orelse return brandReject(realm);
    const sync_iter_obj = heap_mod.valueAsPlainObject(sync_iter_v) orelse return brandReject(realm);
    const passed_value = if (args.len > 0) args[0] else Value.undefined_;

    // §27.6.1.4 step 5 — GetMethod(syncIterator, "throw").
    const throw_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "throw") catch {
        const ex = interpreter.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "sync iterator .throw read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    // §27.6.1.4 step 7 — throw absent → close the iterator (give
    // it a chance to clean up) and reject with a fresh TypeError.
    if (throw_v.isUndefined() or throw_v.isNull()) {
        const cret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
            const ex_inner = interpreter.consumePendingException(realm) orelse Value.undefined_;
            return rejectedPromise(realm, ex_inner);
        };
        if (!cret_v.isUndefined() and !cret_v.isNull()) {
            const cret_fn = heap_mod.valueAsFunction(cret_v) orelse {
                const ex = intrinsics_mod.newTypeError(realm, "sync iterator .return is not callable") catch return error.OutOfMemory;
                return rejectedPromise(realm, ex);
            };
            const close_outcome = interpreter.callJSFunction(realm.allocator, realm, cret_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;
            switch (close_outcome) {
                .thrown => |ex| return rejectedPromise(realm, ex),
                .value, .yielded => {},
            }
        }
        const ex = intrinsics_mod.newTypeError(realm, "sync iterator has no 'throw' method") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    }
    const throw_fn = heap_mod.valueAsFunction(throw_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "sync iterator .throw is not callable") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };

    // §27.6.1.4 step 9 — Call(throw, syncIterator, « value »).
    const call_result = interpreter.callJSFunction(realm.allocator, realm, throw_fn, sync_iter_v, &.{passed_value}) catch return error.OutOfMemory;
    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    // §27.6.1.4 step 11 — result must be Object.
    if (heap_mod.valueAsPlainObject(result_v) == null) {
        const ex = intrinsics_mod.newTypeError(realm, "iterator .throw() result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    }
    return processIterResult(realm, result_v);
}

/// §27.6.1.{2,3,4} steps 7–14 — read `done` then `value` (in
/// that order so a poisoned-`done` getter fires before
/// `value`), build the unwrap Promise.
fn processIterResult(realm: *Realm, result_v: Value) NativeError!Value {
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "iterator result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };
    // §7.4.4 IteratorComplete — read `done` first.
    const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch {
        const ex = interpreter.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "iterator result .done read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    const done = toBoolean(done_v);
    // §7.4.5 IteratorValue — read `value`.
    const value_v = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch {
        const ex = interpreter.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "iterator result .value read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    // §27.6.1.5 Async-from-Sync Iterator Value Unwrap —
    // PromiseResolve(value) then re-wrap as `{value, done}`.
    // `wrapAsyncGenResult` already implements exactly this:
    // fulfilled → fresh `{value, done}` Promise; rejected →
    // propagate rejection; pending → register reaction.
    return interpreter.wrapAsyncGenResult(realm, value_v, done);
}

fn genResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}
