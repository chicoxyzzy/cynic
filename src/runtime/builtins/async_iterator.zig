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
const lantern = @import("../lantern/interpreter.zig");
const toBoolean = @import("../lantern/arith.zig").toBoolean;

const SYNC_ITER_SLOT = "__cynic_sync_iter__";

/// §27.6.1 — lazily install `%AsyncFromSyncIteratorPrototype%`
/// on the realm. The proto inherits `%AsyncIteratorPrototype%`
/// (so `@@asyncIterator` returns `this`) and carries `next`,
/// `return`, `throw`.
pub fn ensureAsyncFromSyncIteratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.async_from_sync_iterator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(proto, try lantern.ensureAsyncIteratorPrototype(realm));

    try installMethod(realm, proto, "next", afsiNext, 1);
    try installMethod(realm, proto, "return", afsiReturn, 1);
    try installMethod(realm, proto, "throw", afsiThrow, 1);

    realm.intrinsics.async_from_sync_iterator_prototype = proto;
    @import("harden.zig").freezeLazyIntrinsic(realm, proto) catch return error.OutOfMemory;
    return proto;
}

fn installMethod(realm: *Realm, proto: *JSObject, name: []const u8, native: anytype, params: u8) !void {
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, name);
    fn_obj.has_construct = false;
    fn_obj.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, name, heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
}

/// §27.6.1.1 CreateAsyncFromSyncIterator — wrap `sync_iter` in a
/// fresh object whose proto is `%AsyncFromSyncIteratorPrototype%`.
/// The inner sync iterator lives on the hidden
/// `__cynic_sync_iter__` slot.
pub fn createAsyncFromSyncIterator(realm: *Realm, sync_iter: Value) !Value {
    const proto = try ensureAsyncFromSyncIteratorPrototype(realm);
    const obj = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(obj, proto);
    try obj.set(realm.allocator, SYNC_ITER_SLOT, sync_iter);
    return heap_mod.taggedObject(obj);
}

/// Pull the wrapped sync iter Value out of `this_value`. Returns
/// null if `this_value` isn't a real async-from-sync wrapper
/// (per the brand check in §27.6.1.{2,3,4} step 1).
fn syncIterOf(this_value: Value) ?Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const v = obj.lookupOwn(SYNC_ITER_SLOT) orelse return null;
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
    // §7.4.2 GetIterator step 4 captured [[NextMethod]] once at
    // iterator-record creation; subsequent IteratorNext calls
    // reuse that cached method rather than re-running the
    // `get next` accessor. The cache lives on the sync iterator's
    // typed `iter_record` slot — shared with the `iter_step`
    // destructuring path, off the property bag, so wrapping a
    // user sync iterator leaves no observable own property.
    const rec: *@import("../object.zig").IterRecord = sync_iter_obj.iter_record orelse blk: {
        const r = realm.allocator.create(@import("../object.zig").IterRecord) catch return error.OutOfMemory;
        r.* = .{};
        sync_iter_obj.iter_record = r;
        break :blk r;
    };
    const next_v = if (rec.next_cached) rec.next else nv: {
        const v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "next") catch {
            const ex = lantern.consumePendingException(realm) orelse
                (intrinsics_mod.newTypeError(realm, "sync iterator .next read failed") catch return error.OutOfMemory);
            return rejectedPromise(realm, ex);
        };
        rec.next = v;
        rec.next_cached = true;
        break :nv v;
    };
    const next_fn = heap_mod.valueAsFunction(next_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "sync iterator .next is not callable") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };

    // §27.6.1.2 steps 5–6 — forward `value` only when present.
    const call_result = if (args.len > 0)
        lantern.callJSFunction(realm.allocator, realm, next_fn, sync_iter_v, args) catch return error.OutOfMemory
    else
        lantern.callJSFunction(realm.allocator, realm, next_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;

    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    return processIterResult(realm, result_v, sync_iter_obj, sync_iter_v, true);
}

/// §27.6.1.3 %AsyncFromSyncIteratorPrototype%.return ( value )
fn afsiReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const sync_iter_v = syncIterOf(this_value) orelse return brandReject(realm);
    const sync_iter_obj = heap_mod.valueAsPlainObject(sync_iter_v) orelse return brandReject(realm);
    const passed_value = if (args.len > 0) args[0] else Value.undefined_;

    // §27.6.1.3 step 5 — GetMethod(syncIterator, "return").
    const ret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
        const ex = lantern.consumePendingException(realm) orelse
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
        lantern.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, args) catch return error.OutOfMemory
    else
        lantern.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;
    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    // §27.6.1.3 step 11 — result must be Object.
    if (heap_mod.valueAsPlainObject(result_v) == null) {
        const ex = intrinsics_mod.newTypeError(realm, "iterator .return() result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    }
    // `return` itself passes closeOnRejection=false per §27.6.1.3
    // step 12 — the iterator is already being closed; don't
    // double-close.
    return processIterResult(realm, result_v, sync_iter_obj, sync_iter_v, false);
}

/// §27.6.1.4 %AsyncFromSyncIteratorPrototype%.throw ( value )
fn afsiThrow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const sync_iter_v = syncIterOf(this_value) orelse return brandReject(realm);
    const sync_iter_obj = heap_mod.valueAsPlainObject(sync_iter_v) orelse return brandReject(realm);
    const passed_value = if (args.len > 0) args[0] else Value.undefined_;

    // §27.6.1.4 step 5 — GetMethod(syncIterator, "throw").
    const throw_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "throw") catch {
        const ex = lantern.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "sync iterator .throw read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    // §27.6.1.4 step 7 — throw absent → close the iterator (give
    // it a chance to clean up) and reject with a fresh TypeError.
    if (throw_v.isUndefined() or throw_v.isNull()) {
        const cret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
            const ex_inner = lantern.consumePendingException(realm) orelse Value.undefined_;
            return rejectedPromise(realm, ex_inner);
        };
        if (!cret_v.isUndefined() and !cret_v.isNull()) {
            const cret_fn = heap_mod.valueAsFunction(cret_v) orelse {
                const ex = intrinsics_mod.newTypeError(realm, "sync iterator .return is not callable") catch return error.OutOfMemory;
                return rejectedPromise(realm, ex);
            };
            const close_outcome = lantern.callJSFunction(realm.allocator, realm, cret_fn, sync_iter_v, &.{}) catch return error.OutOfMemory;
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
    const call_result = lantern.callJSFunction(realm.allocator, realm, throw_fn, sync_iter_v, &.{passed_value}) catch return error.OutOfMemory;
    const result_v = switch (call_result) {
        .value, .yielded => |v| v,
        .thrown => |ex| return rejectedPromise(realm, ex),
    };
    // §27.6.1.4 step 11 — result must be Object.
    if (heap_mod.valueAsPlainObject(result_v) == null) {
        const ex = intrinsics_mod.newTypeError(realm, "iterator .throw() result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    }
    // §27.6.1.4 step 12 — `throw` passes closeOnRejection=true so
    // a rejected `value` Promise still triggers an iterator close
    // (the underlying iter wants to release resources).
    return processIterResult(realm, result_v, sync_iter_obj, sync_iter_v, true);
}

/// §27.6.1.{2,3,4} steps 7–14 + §27.6.1.6 AsyncFromSyncIteratorContinuation
/// — read `done` then `value` (in that order so a poisoned-`done`
/// getter fires before `value`), build the unwrap Promise, and
/// when `closeOnRejection` is true and `done` is false, close the
/// sync iterator on a rejected inner Promise.
fn processIterResult(
    realm: *Realm,
    result_v: Value,
    sync_iter_obj: *JSObject,
    sync_iter_v: Value,
    close_on_rejection: bool,
) NativeError!Value {
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse {
        const ex = intrinsics_mod.newTypeError(realm, "iterator result is not an object") catch return error.OutOfMemory;
        return rejectedPromise(realm, ex);
    };
    // §7.4.4 IteratorComplete — read `done` first.
    const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch {
        const ex = lantern.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "iterator result .done read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    const done = toBoolean(done_v);
    // §7.4.5 IteratorValue — read `value`.
    const value_v = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch {
        const ex = lantern.consumePendingException(realm) orelse
            (intrinsics_mod.newTypeError(realm, "iterator result .value read failed") catch return error.OutOfMemory);
        return rejectedPromise(realm, ex);
    };
    // §27.6.1.6 step 5 — PromiseResolve(%Promise%, value). In Cynic
    // this is the `value.constructor` read (used by `Promise.resolve`
    // species lookup when value is a thenable). If reading
    // `constructor` throws, step 6 closes the iterator when
    // closeOnRejection && !done, then rejects the outer Promise.
    if (close_on_rejection and !done and heap_mod.valueAsPlainObject(value_v) != null) {
        const v_obj = heap_mod.valueAsPlainObject(value_v).?;
        // Probe for poisoned `constructor` accessor — mirrors
        // §27.6.1.6 step 5 PromiseResolve which reads
        // `value.constructor` to honour species. A throw here
        // surfaces as IteratorClose then reject.
        const ctor_v = intrinsics_mod.getPropertyChain(realm, v_obj, "constructor") catch {
            const ex = lantern.consumePendingException(realm) orelse Value.undefined_;
            return closeAndReject(realm, sync_iter_obj, sync_iter_v, ex);
        };
        _ = ctor_v;
    }
    // §27.6.1.6 step 14 — PerformPromiseThen(valueWrapper,
    // onFulfilled, onRejected, promiseCapability). When `done` is
    // false and `closeOnRejection` is true, `onRejected` closes
    // the iterator before propagating the rejection (step 13.a).
    if (close_on_rejection and !done) {
        const wrapped = try wrapAsyncGenResultWithClose(realm, value_v, done, sync_iter_obj, sync_iter_v);
        return wrapped;
    }
    return lantern.wrapAsyncGenResult(realm, value_v, done);
}

/// §27.6.1.6 step 13.a — close iterator on rejection then reject
/// outer Promise. Builds the rejected outer Promise directly when
/// `value_v` is already a settled rejected Promise.
fn wrapAsyncGenResultWithClose(
    realm: *Realm,
    raw: Value,
    done: bool,
    sync_iter_obj: *JSObject,
    sync_iter_v: Value,
) NativeError!Value {
    // Fast path: settled rejected Promise → IteratorClose then
    // surface the rejection on the outer Promise.
    if (heap_mod.valueAsPlainObject(raw)) |p| {
        if (p.promise_state == .rejected) {
            return closeAndReject(realm, sync_iter_obj, sync_iter_v, p.promise_value);
        }
        if (p.promise_state == .pending) {
            // Register on-fulfilled + on-rejected reactions. The
            // rejection reaction calls IteratorClose before
            // rejecting the outer Promise (§27.6.1.6 step 13).
            const outer = intrinsics_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
            const fulfill_fn = realm.heap.allocateFunctionNative(if (done) iterResultDoneTrue else iterResultDoneFalse, 1, "asyncGenYield") catch return error.OutOfMemory;
            fulfill_fn.has_construct = false;
            const reject_fn = realm.heap.allocateFunctionNative(closeIteratorOnReject, 1, "closeIterator") catch return error.OutOfMemory;
            reject_fn.has_construct = false;
            reject_fn.properties.put(realm.allocator, "__cynic_sync_iter__", sync_iter_v) catch return error.OutOfMemory;
            const p_reactions = p.promiseReactionsPtr(realm.allocator) catch return error.OutOfMemory;
            p_reactions.append(realm.allocator, .{
                .on_fulfilled = heap_mod.taggedFunction(fulfill_fn),
                .on_rejected = heap_mod.taggedFunction(reject_fn),
                .result_promise = outer,
            }) catch return error.OutOfMemory;
            return outer;
        }
    }
    // Non-Promise / fulfilled-Promise / settled-fulfilled: no
    // rejection branch needed — defer to the ordinary wrap.
    return lantern.wrapAsyncGenResult(realm, raw, done);
}

/// §7.4.7 IteratorClose — invoke `iterator.return()` and swallow
/// any abrupt completion from the close itself; the original
/// rejection is what surfaces.
fn closeAndReject(
    realm: *Realm,
    sync_iter_obj: *JSObject,
    sync_iter_v: Value,
    reject_value: Value,
) NativeError!Value {
    const ret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
        _ = lantern.consumePendingException(realm);
        return rejectedPromise(realm, reject_value);
    };
    if (!ret_v.isUndefined() and !ret_v.isNull()) {
        if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
            const close_outcome = lantern.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, &.{}) catch
                return rejectedPromise(realm, reject_value);
            _ = close_outcome; // §7.4.7 step 6 — discard close result.
        }
    }
    return rejectedPromise(realm, reject_value);
}

fn iterResultDoneFalse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = if (args.len > 0) args[0] else Value.undefined_;
    return genResult(realm, v, false);
}

fn iterResultDoneTrue(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = if (args.len > 0) args[0] else Value.undefined_;
    return genResult(realm, v, true);
}

fn closeIteratorOnReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ex = if (args.len > 0) args[0] else Value.undefined_;
    // Recover the sync iter from the function's stash. The
    // closure was tagged with `__cynic_sync_iter__` at creation.
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        if (fn_obj.properties.get("__cynic_sync_iter__")) |sync_iter_v| {
            if (heap_mod.valueAsPlainObject(sync_iter_v)) |sync_iter_obj| {
                // Call iterator.return(); swallow any thrown
                // result — the original rejection is what we
                // re-throw.
                const ret_v = intrinsics_mod.getPropertyChain(realm, sync_iter_obj, "return") catch {
                    _ = lantern.consumePendingException(realm);
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                };
                if (!ret_v.isUndefined() and !ret_v.isNull()) {
                    if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
                        _ = lantern.callJSFunction(realm.allocator, realm, ret_fn, sync_iter_v, &.{}) catch {};
                    }
                }
            }
        }
    }
    realm.pending_exception = ex;
    return error.NativeThrew;
}

fn genResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}
