//! §27.3 DisposableStack — ES2026 explicit-resource-management.
//!
//! The synchronous resource-stack global. `using` declarations
//! (Phase 4) and `.use()` / `.adopt()` / `.defer()` calls
//! register resources onto a `[[DisposeCapability]]` list;
//! `.dispose()` (or the §9.5.4 DisposeResources walk a `using`
//! binding's scope exit performs) iterates the list in REVERSE
//! and invokes each resource's `[[DisposeMethod]]` with
//! `this = [[ResourceValue]]`. A mid-disposal throw becomes
//! the in-flight throw; a subsequent disposer's throw wraps the
//! pair in `new SuppressedError(<new throw>, <previous throw>)`
//! per §9.5.4 step 2.b.iv-vi.
//!
//! Instance state lives on the `JSObjectExtension`'s
//! `disposable_state` brand + `disposable_resources` LIFO list
//! — never as `__cynic_*` keys on the user-visible instance.
//! See `runtime/object.zig` and AGENTS.md's "no engine state on
//! user-visible objects" rule.
//!
//! The async sibling (§27.4 AsyncDisposableStack) ships in
//! Phase 5 — same data shape, different prototype + dispose
//! discipline. Brand discrimination rides on the
//! `disposable_state` enum's `.sync_*` vs `.async_*` variants
//! (one slot doubles as kind + lifecycle tag) so a
//! `Object.setPrototypeOf` can't flip the brand.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const object_mod = @import("../object.zig");
const DisposableState = object_mod.DisposableState;
const DisposableHint = object_mod.DisposableHint;
const DisposableResource = object_mod.DisposableResource;

const setNonEnumerable = intrinsics.setNonEnumerable;
const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const throwTypeError = intrinsics.throwTypeError;
const throwReferenceError = intrinsics.throwReferenceError;

pub fn install(realm: *Realm) !void {
    // §27.3.1 DisposableStack — constructor + prototype.
    // `length` is 0; the constructor is `new`-only (§27.3.1.1
    // step 1 — IsCallable(NewTarget) === false ⇒ TypeError).
    const r = try installConstructor(realm, .{
        .name = "DisposableStack",
        .ctor = disposableStackConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "DisposableStack",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §27.3.3.{2,3,4,5,7} — prototype methods. `dispose` is
    // installed first so the `Symbol.dispose` alias can reference
    // the same callable.
    try installNativeMethodOnProto(realm, proto, "dispose", disposableStackDispose, 0);
    try installNativeMethodOnProto(realm, proto, "use", disposableStackUse, 1);
    try installNativeMethodOnProto(realm, proto, "adopt", disposableStackAdopt, 2);
    try installNativeMethodOnProto(realm, proto, "defer", disposableStackDefer, 1);
    try installNativeMethodOnProto(realm, proto, "move", disposableStackMove, 0);
    // §27.3.3.1 DisposableStack.prototype.disposed — accessor.
    try installNativeGetter(realm, proto, "disposed", disposableStackDisposedGetter);

    // §27.3.3.6 DisposableStack.prototype[@@dispose] — the spec
    // sets this to the SAME function object as `dispose`. Install
    // one allocation, then alias under the well-known-symbol key
    // (mirrors `Map.prototype[@@iterator] === Map.prototype.entries`).
    const dispose_fn_v = proto.lookupOwn("dispose") orelse Value.undefined_;
    try proto.setWithFlags(realm.allocator, "@@dispose", dispose_fn_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.disposable_stack_constructor = fn_obj;
    realm.intrinsics.disposable_stack_prototype = proto;
}

// §27.3.1.1 DisposableStack ( ) — constructor body. Throws
// TypeError when invoked without `new` (no [[Call]]); on `new`,
// initialises the freshly-allocated `this` with
// `[[DisposableState]] = "pending"` and `[[DisposeCapability]] = «»`.
fn disposableStackConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.3.1.1 step 1 — when called without `new`, `this_value`
    // is the global object (or undefined under strict). The
    // interpreter passes a fresh JSObject (proto =
    // DisposableStack.prototype) only on a real `new` dispatch, so
    // the non-object case is the plain-call signal — throw
    // TypeError per the §27.3.1.1 step 1 NewTarget check.
    const instance = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "DisposableStack constructor requires 'new'");
    };
    // §27.3.1.1 step 4-5 — set [[DisposableState]] = "pending" and
    // [[DisposeCapability]] = a fresh empty DisposeCapability
    // Record. Both live on the JSObjectExtension typed slots; the
    // extension's resource list is already `.empty` from
    // getOrCreateExtension's zero-init.
    try instance.setDisposableState(realm.allocator, .sync_pending);
    return heap_mod.taggedObject(instance);
}

/// §27.3.3.x `RequireInternalSlot(O, [[DisposableState]])` — the
/// brand check shared by every prototype method. Throws TypeError
/// when the receiver isn't a DisposableStack — either its extension
/// never had `disposable_state` set (plain object) OR the slot
/// carries an AsyncDisposableStack brand (§27.4) instead. Both
/// must reject so a §27.3 method can't observe §27.4 internal
/// state and vice versa.
fn requireDisposableStack(realm: *Realm, this_value: Value) NativeError!*JSObject {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "DisposableStack method called on non-object");
    };
    const state = obj.getDisposableState() orelse {
        return throwTypeError(realm, "DisposableStack method called on incompatible receiver");
    };
    if (state.isAsync()) {
        return throwTypeError(realm, "DisposableStack method called on incompatible receiver");
    }
    return obj;
}

// §27.3.3.7 DisposableStack.prototype.use ( value ).
//   1. Let O be the this value.
//   2. Perform ? RequireInternalSlot(O, [[DisposableState]]).
//   3. If O.[[DisposableState]] is "disposed", throw ReferenceError.
//   4. Perform ? AddDisposableResource(O, value, sync-dispose).
//   5. Return value.
fn disposableStackUse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "DisposableStack.prototype.use: stack is disposed");
    }
    const value = if (args.len > 0) args[0] else Value.undefined_;
    try addDisposableResource(realm, stack, value, .sync_dispose);
    return value;
}

// §27.3.3.2 DisposableStack.prototype.adopt ( value, onDispose ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. If IsCallable(onDispose) is false, throw TypeError.
//   5. Let closure = a new Abstract Closure with no parameters that
//      captures value and onDispose and performs:
//        Return ? Call(onDispose, undefined, « value »).
//   6. Let F = CreateBuiltinFunction(closure, 0, "", « »).
//   7. Perform ? AddDisposableResource(O, undefined, sync-dispose, F).
//   8. Return value.
//
// Cynic implements the closure as a bound function: target is
// `onDispose`, captured `this` is undefined, prefix args are
// `[value]`. Calling the bound function with no args ⇒
// `onDispose.call(undefined, value)`, matching the spec closure.
fn disposableStackAdopt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "DisposableStack.prototype.adopt: stack is disposed");
    }
    const value = if (args.len > 0) args[0] else Value.undefined_;
    const on_dispose_v = if (args.len > 1) args[1] else Value.undefined_;
    const on_dispose = heap_mod.valueAsFunction(on_dispose_v) orelse {
        return throwTypeError(realm, "DisposableStack.prototype.adopt: onDispose is not callable");
    };

    // §27.3.3.2 step 5-6 — build the wrapper closure as a bound
    // function. `bound_this = undefined`, prefix args `[value]`.
    const wrapper = realm.heap.allocateFunctionNative(boundAdoptTrampoline, 0, "") catch return error.OutOfMemory;
    wrapper.proto = realm.intrinsics.function_prototype;
    wrapper.has_construct = false;
    realm.heap.setBoundTarget(wrapper, on_dispose);
    realm.heap.setBoundThis(wrapper, Value.undefined_);
    const args_slice = realm.allocator.alloc(Value, 1) catch return error.OutOfMemory;
    args_slice[0] = value;
    realm.heap.setBoundArgs(wrapper, args_slice);

    // §27.3.3.2 step 7 — AddDisposableResource with V = undefined,
    // hint = sync-dispose, method = the wrapper. The dispose-time
    // walk invokes the wrapper with `this = undefined` (since the
    // resource is undefined) — the bound state already carries
    // both the `this` (undefined) and the captured value.
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = Value.undefined_,
        .hint = .sync_dispose,
        .dispose_method = heap_mod.taggedFunction(wrapper),
    }) catch return error.OutOfMemory;
    return value;
}

// The bound function's native body is never reached — the call
// dispatch checks `bound_target` first and re-enters
// `callJSFunction` with the unwrapped target + prefix args.
// Provide a no-op stub so the allocation succeeds.
fn boundAdoptTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
}

// §27.3.3.3 DisposableStack.prototype.defer ( onDispose ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. If IsCallable(onDispose) is false, throw TypeError.
//   5. Perform ? AddDisposableResource(O, undefined, sync-dispose, onDispose).
//   6. Return undefined.
fn disposableStackDefer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "DisposableStack.prototype.defer: stack is disposed");
    }
    const on_dispose_v = if (args.len > 0) args[0] else Value.undefined_;
    if (heap_mod.valueAsFunction(on_dispose_v) == null) {
        return throwTypeError(realm, "DisposableStack.prototype.defer: onDispose is not callable");
    }
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = Value.undefined_,
        .hint = .sync_dispose,
        .dispose_method = on_dispose_v,
    }) catch return error.OutOfMemory;
    return Value.undefined_;
}

// §27.3.3.4 DisposableStack.prototype.dispose ( ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", return undefined.
//   4. Set state to "disposed".
//   5. Return ? DisposeResources(O.[[DisposeCapability]], NormalCompletion(undefined)).
fn disposableStackDispose(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = try requireDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) return Value.undefined_;
    try stack.setDisposableState(realm.allocator, .sync_disposed);
    return disposeResources(realm, stack);
}

// §27.3.3.1 get DisposableStack.prototype.disposed.
//   1-2. RequireInternalSlot.
//   3. Return true iff state is "disposed".
fn disposableStackDisposedGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = try requireDisposableStack(realm, this_value);
    return Value.fromBool(stack.getDisposableState().?.isDisposed());
}

// §27.3.3.5 DisposableStack.prototype.move ( ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. Let newDisposableStack = ? OrdinaryCreateFromConstructor(
//        %DisposableStack%, "%DisposableStack.prototype%",
//        « [[DisposableState]], [[DisposeCapability]] »).
//   5. Set newDisposableStack.[[DisposableState]] to "pending".
//   6. Set newDisposableStack.[[DisposeCapability]] to O.[[DisposeCapability]].
//   7. Set O.[[DisposeCapability]] to a new empty DisposeCapability.
//   8. Set O.[[DisposableState]] to "disposed".
//   9. Return newDisposableStack.
fn disposableStackMove(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = try requireDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "DisposableStack.prototype.move: stack is disposed");
    }
    // §27.3.3.5 step 4 — allocate a fresh instance with our
    // prototype. OrdinaryCreateFromConstructor isn't reachable
    // from here without the user-facing NewTarget; reach the
    // realm-pinned prototype directly (matches the pattern used
    // by `Promise.prototype.then`-allocated chained promises).
    const new_stack = realm.heap.allocateObject() catch return error.OutOfMemory;
    const proto = realm.intrinsics.disposable_stack_prototype.?;
    realm.heap.setObjectPrototype(new_stack, proto);
    try new_stack.setDisposableState(realm.allocator, .sync_pending);

    // Move (don't copy) the resource list. Walk the source list
    // and append into the destination; then clear the source.
    if (stack.disposableResourcesConst()) |src_list| {
        const dst_list = try new_stack.disposableResourcesPtr(realm.allocator);
        dst_list.ensureUnusedCapacity(realm.allocator, src_list.items.len) catch return error.OutOfMemory;
        for (src_list.items) |rec| dst_list.appendAssumeCapacity(rec);
    }
    // Clear the source list and flip the source to "disposed".
    if (stack.extension) |ext| ext.disposable_resources.clearRetainingCapacity();
    try stack.setDisposableState(realm.allocator, .sync_disposed);
    return heap_mod.taggedObject(new_stack);
}

// §9.5.4 DisposeResources(disposeCapability, completion).
//
// Walk `disposeCapability.[[DisposableResourceStack]]` in REVERSE
// (the spec's "for each resource of ... in reverse list order").
// For each record:
//   - If method is undefined (resource was null/undefined at use()
//     time), skip — there's no callable to invoke.
//   - Otherwise: Call(method, resource, «»).
//     If that throws:
//       - If completion is already a throw, replace completion
//         with `new SuppressedError(thisThrow, completion)` —
//         the new throw becomes [[Error]], the old completion
//         becomes [[Suppressed]].
//       - Otherwise set completion to a throw of thisThrow.
// After the loop, clear the list. If completion is a throw,
// re-throw; else return undefined.
/// Public entry into §9.5.4 DisposeResources — used both by
/// `DisposableStack.prototype.dispose` and by the `dispose_stack`
/// opcode the compiler emits at every exit edge of a `using`-
/// bearing block (Phase 4b).
pub fn disposeResources(realm: *Realm, stack: *JSObject) NativeError!Value {
    return disposeResourcesWithCompletion(realm, stack, null);
}

/// §9.5.4 DisposeResources(disposeCapability, completion) — variant
/// that lets the caller seed an in-flight throw. Used by the
/// `dispose_stack_with_throw` opcode at the throw-handler arm of a
/// `using`-bearing block: a disposer that itself throws while we're
/// already unwinding wraps via SuppressedError per §9.5.4 step
/// 2.b.iv-vi. On normal-completion arms, `existing_throw` is null
/// and the behaviour matches the public `disposeResources`.
///
/// On a non-null `existing_throw`, this function ALWAYS returns
/// `error.NativeThrew` with `realm.pending_exception` set — either
/// the original throw (if no disposer threw), the disposer's throw
/// (if one threw without a prior pending), or a fresh
/// SuppressedError chain (if multiple threw or a disposer threw
/// while an external throw was already in flight).
pub fn disposeResourcesWithCompletion(realm: *Realm, stack: *JSObject, existing_throw: ?Value) NativeError!Value {
    const lantern = @import("../lantern/interpreter.zig");
    // Root the running completion across the disposal walk. `pending`
    // chases error3 → SuppressedError(error2, error3) → SuppressedError(
    // error1, …) in the multi-throw case; each intermediate
    // SuppressedError is freshly allocated and bound to no JS variable,
    // so the *next* iteration's disposer re-entry (arbitrary user JS →
    // GC) would sweep it and the wrapped chain would dangle. The async
    // walk roots its pending throw via a typed slot (see heap.zig
    // markValue / async_dispose_walk); the sync walk keeps it in this
    // native local, so it needs a HandleScope.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    var pending: ?Value = existing_throw;
    if (existing_throw) |et| scope.push(et) catch return error.OutOfMemory;
    if (stack.disposableResourcesConst()) |list| {
        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            const rec = list.items[i];
            const method_v = rec.dispose_method;
            if (method_v.isUndefined()) continue;
            const method_fn = heap_mod.valueAsFunction(method_v) orelse continue;
            const outcome = lantern.callJSFunction(realm.allocator, realm, method_fn, rec.resource, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => {},
                .thrown => |ex| {
                    if (pending) |prev| {
                        // §9.5.4 step 2.b.iv-vi — wrap the existing
                        // pending throw with a fresh SuppressedError.
                        // The new throw becomes [[Error]] (the
                        // disposer that just failed), the existing
                        // pending becomes [[Suppressed]].
                        pending = makeSuppressedError(realm, ex, prev) catch |werr| switch (werr) {
                            error.OutOfMemory => return error.OutOfMemory,
                        };
                    } else {
                        pending = ex;
                    }
                    // Anchor the new running completion before the next
                    // disposer re-entry can GC.
                    if (pending) |p| scope.push(p) catch return error.OutOfMemory;
                },
            }
        }
    }
    // Clear the list — once dispose has run, the records are
    // permanently consumed (a second dispose() no-ops because the
    // state flipped to "disposed", but a re-entrant grow during
    // disposal — e.g. a user disposer calling .move() — must
    // observe an empty source).
    if (stack.extension) |ext| ext.disposable_resources.clearRetainingCapacity();
    if (pending) |ex| {
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    return Value.undefined_;
}

/// Build `new SuppressedError(error, suppressed)` per §20.5.x.
/// Used by DisposeResources when a disposer throws while another
/// throw is in flight (§9.5.4 step 2.b.iv-vi).
fn makeSuppressedError(realm: *Realm, err_v: Value, suppressed_v: Value) !Value {
    const proto = realm.intrinsics.suppressed_error_prototype.?;
    // Root the two payloads (and the half-built instance) across the
    // allocations below: they are raw Values held only in native
    // locals, and allocateObject / setWithFlags can each trigger a GC
    // that would otherwise sweep them before they're linked onto the
    // instance — leaving a SuppressedError with a dangling .error /
    // .suppressed.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(err_v) catch return error.OutOfMemory;
    scope.push(suppressed_v) catch return error.OutOfMemory;
    const instance = try realm.heap.allocateObject();
    scope.push(heap_mod.taggedObject(instance)) catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(instance, proto);
    instance.has_error_data = true;
    try instance.setWithFlags(realm.allocator, "error", err_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    try instance.setWithFlags(realm.allocator, "suppressed", suppressed_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    return heap_mod.taggedObject(instance);
}

// §9.5.3 AddDisposableResource(disposable, V, hint).
//   Conceptual signature with an optional `method` for the
//   §27.3.3.2 .adopt() flow — used by `disposableStackAdopt`
//   inline since the wrapper construction is mostly bound-fn
//   bookkeeping. The bare form below is the §27.3.3.7 .use()
//   path (and the `register_using` opcode emitted by the compiler
//   for a `using` declarator): derive `method` from
//   `GetDisposeMethod(V, hint)`.
//
// Public so the `register_using` opcode (§13.2.4 `using`-decl
// initialisation) shares the GetDisposeMethod walk.
pub fn addDisposableResource(realm: *Realm, stack: *JSObject, value: Value, hint: DisposableHint) NativeError!void {
    // §9.5.3 step 1 — sync-dispose with null / undefined value
    // appends NO record (a no-op `.use(null)` / `using x = null;`
    // is a literal pass-through). Async-dispose, by contrast,
    // appends a "ghost" record with `dispose_method = undefined`:
    // §9.5.4 DisposeResources step 3.f then sets `needsAwait = true`
    // so the disposeAsync Promise crosses at least one microtask
    // boundary, matching the spec's semantics of `await null` /
    // `await undefined`. test262
    // `built-ins/AsyncDisposableStack/prototype/disposeAsync/
    // explicit-await-for-{null,undefined}.js` are the witnesses.
    if (value.isUndefined() or value.isNull()) {
        if (hint == .async_dispose) {
            const ext_list = try stack.disposableResourcesPtr(realm.allocator);
            ext_list.append(realm.allocator, .{
                .resource = Value.undefined_,
                .hint = .async_dispose,
                .dispose_method = Value.undefined_,
            }) catch return error.OutOfMemory;
        }
        return;
    }

    // §9.5.3 step 2 — GetDisposeMethod(V, hint). For sync, look up
    // `Symbol.dispose` on V. The method must be callable, or the
    // spec throws TypeError at the binding site (.use() / `using`-
    // decl initialisation), NOT at dispose time.
    //
    // V is "any value" per spec; under Cynic's heap model the
    // property-lookup helper accepts either a JSObject OR a
    // JSFunction (functions carry their own property bag for
    // user assignments like `Function.prototype[Symbol.dispose] =
    // …`). Primitives (string / number / bigint / symbol /
    // boolean) ToObject-coerce up the wrapper prototype chain
    // when read — but `using "x" = …` is uncommon and the spec
    // treats them via the same coercion. Reject only when we
    // truly can't extract a Symbol.dispose method.
    // §9.5.2 GetDisposeMethod(V, hint) — for async-dispose, look
    // up @@asyncDispose first; if missing, fall back to @@dispose.
    // For sync-dispose, only @@dispose. The async fallback path
    // means a `await using x = { [Symbol.dispose]() {…} }` binding
    // is legal — the sync method is invoked and the engine awaits
    // its (possibly undefined) result during the async walk.
    const lookup = struct {
        fn read(r: *Realm, v: Value, k: []const u8) NativeError!Value {
            if (heap_mod.valueAsPlainObject(v)) |obj| {
                return try intrinsics.getPropertyChain(r, obj, k);
            }
            if (heap_mod.valueAsFunction(v)) |fn_obj| {
                return fn_obj.get(k);
            }
            return Value.undefined_;
        }
    };
    if (heap_mod.valueAsPlainObject(value) == null and heap_mod.valueAsFunction(value) == null) {
        return throwTypeError(realm, "Disposable resource is not an object");
    }
    var method_v = try lookup.read(realm, value, switch (hint) {
        .sync_dispose => "@@dispose",
        .async_dispose => "@@asyncDispose",
    });
    if ((method_v.isUndefined() or method_v.isNull()) and hint == .async_dispose) {
        method_v = try lookup.read(realm, value, "@@dispose");
    }
    if (method_v.isUndefined() or method_v.isNull()) {
        return throwTypeError(realm, "Disposable resource has no Symbol.dispose method");
    }
    if (heap_mod.valueAsFunction(method_v) == null) {
        return throwTypeError(realm, "Disposable resource Symbol.dispose is not callable");
    }
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = value,
        .hint = hint,
        .dispose_method = method_v,
    }) catch return error.OutOfMemory;
}
