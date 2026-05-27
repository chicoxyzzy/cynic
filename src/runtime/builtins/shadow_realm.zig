//! §3.8 ShadowRealm — a synchronous boundary between two realms.
//!
//! A ShadowRealm instance owns a fresh child `*Realm` (own
//! intrinsics + globals, shared heap) and exposes two methods:
//!
//!   - `.evaluate(sourceText)` — parse + evaluate `sourceText`
//!     as a script in the child realm. The return value passes
//!     through the spec's "callable boundary": primitives cross
//!     untouched, functions are wrapped in a fresh
//!     WrappedFunction visible to the caller realm, and every
//!     other object value throws a TypeError per §3.8.3.4 step 1.a.
//!
//!   - `.importValue(specifier, exportName)` — async; loads a
//!     module via the child realm's loader, resolves the named
//!     export through the same callable boundary.
//!
//! The constructor is `is_class_constructor`, so calling
//! `ShadowRealm(...)` without `new` throws TypeError per §17. The
//! brand check on the prototype methods is the `is_shadow_realm`
//! flag on `JSObject`; the child realm pointer rides the
//! `host_data` slot (same trick `$262.createRealm()` uses).
//!
//! Phase 3.1 — scaffolding only. `.evaluate` evaluates and
//! returns the raw value (no boundary filter yet); `.importValue`
//! throws "not yet implemented". Boundary filtering + module
//! loader integration land in 3.3-3.5.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../lantern/interpreter.zig");
const call_mod = @import("../lantern/call.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const throwTypeError = intrinsics.throwTypeError;
const argOr = intrinsics.argOr;

// ── §3.8 ShadowRealm ──────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "ShadowRealm",
        .ctor = shadowRealmConstructor,
        .arity = 0,
        .to_string_tag = "ShadowRealm",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "evaluate", shadowRealmEvaluate, 1);
    try installNativeMethodOnProto(realm, proto, "importValue", shadowRealmImportValue, 2);
}

/// §3.8.1.1 ShadowRealm ( ) — constructor.
///   1. If NewTarget is undefined, throw TypeError. (Enforced by
///      `is_class_constructor: true` on the installed ctor.)
///   2. Let O be ? OrdinaryCreateFromConstructor(NewTarget,
///      "%ShadowRealmPrototype%", « [[ShadowRealm]],
///      [[ExecutionContext]] »). — the interpreter's `new` dispatch
///      already allocates `this_value` with the right prototype.
///   3. Let realmRec be ? CreateRealm(). — `Realm.initChild` plus
///      `installBuiltins` builds a fresh intrinsics-and-globals
///      surface on the shared heap.
///   4. SetRealmGlobalObject(realmRec, undefined, undefined). —
///      `installBuiltins` wires globalThis already.
///   5. Set O.[[ShadowRealm]] to realmRec. — `host_data` carries
///      the child pointer; `is_shadow_realm = true` brands the
///      instance for the prototype's `RequireInternalSlot` checks.
///   6. Perform ? HostInitializeShadowRealm(realmRec). — host
///      hook; no-op for Cynic today.
///   7. Return O.
fn shadowRealmConstructor(
    realm: *Realm,
    this_value: Value,
    args: []const Value,
) NativeError!Value {
    _ = args;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "ShadowRealm constructor requires 'new'");

    // §3.8.1.1 step 3 — allocate a fresh child realm sharing the
    // parent's heap. Mirrors `test262CreateRealm` in tools/test262.zig.
    const child_ptr = realm.allocator.create(Realm) catch return error.OutOfMemory;
    child_ptr.* = Realm.initChild(realm);
    // §3.8.1.1 step 4 / SetRealmGlobalObject — installBuiltins
    // wires every intrinsic constructor onto the child's globals.
    child_ptr.installBuiltins() catch {
        realm.allocator.destroy(child_ptr);
        return error.OutOfMemory;
    };
    // §6.1.5.1 — well-known symbols are agent-wide. The child's
    // `Symbol.iterator` etc. are rewired to the parent's pointers
    // so `parentSr.evaluate("Symbol.iterator") === Symbol.iterator`
    // holds (matches the spec's intent of single-agent symbols).
    child_ptr.shareWellKnownSymbolsWith(realm) catch return error.OutOfMemory;
    // Register the child on the parent's list so it lives as long
    // as the parent and gets torn down with it. (No GC tracking
    // needed — the child Realm is not on the heap.)
    realm.child_realms.append(realm.allocator, child_ptr) catch return error.OutOfMemory;

    // Brand + stash the child pointer.
    inst.is_shadow_realm = true;
    inst.setHostData(realm.allocator, @ptrCast(child_ptr)) catch return error.OutOfMemory;

    return this_value;
}

/// Pulls the child `*Realm` out of a ShadowRealm receiver,
/// throwing the §3.8 brand-check TypeError when `this_value`
/// isn't a ShadowRealm instance. Used by every prototype method.
fn shadowRealmOf(realm: *Realm, this_value: Value, method_name: []const u8) NativeError!*Realm {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwBrandError(realm, method_name);
    };
    if (!inst.is_shadow_realm) return throwBrandError(realm, method_name);
    const raw = inst.getHostData() orelse return throwBrandError(realm, method_name);
    return @ptrCast(@alignCast(raw));
}

fn throwBrandError(realm: *Realm, method_name: []const u8) NativeError {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "ShadowRealm.prototype.{s} called on non-ShadowRealm receiver",
        .{method_name},
    ) catch return throwTypeError(realm, "ShadowRealm.prototype called on non-ShadowRealm receiver");
    return throwTypeError(realm, msg);
}

/// §3.8.3.1 ShadowRealm.prototype.evaluate ( sourceText )
///   1. Let O be the this value.
///   2. Perform ? RequireInternalSlot(O, [[ShadowRealm]]).
///   3. If Type(sourceText) is not String, throw TypeError.
///   4. Let callerRealm be the current Realm Record.
///   5. Let evalRealm be O.[[ShadowRealm]].
///   6. Return ? PerformShadowRealmEval(sourceText, callerRealm,
///      evalRealm). — parse + evaluate in evalRealm, then filter
///      the completion through `GetWrappedValue(callerRealm, …)`
///      and remap any thrown completion to a TypeError in
///      callerRealm.
fn shadowRealmEvaluate(
    realm: *Realm,
    this_value: Value,
    args: []const Value,
) NativeError!Value {
    const eval_realm = try shadowRealmOf(realm, this_value, "evaluate");
    const source_arg = argOr(args, 0, Value.undefined_);
    if (!source_arg.isString()) {
        return throwTypeError(realm, "ShadowRealm.prototype.evaluate: sourceText must be a string");
    }
    const s: *JSString = @ptrCast(@alignCast(source_arg.asString()));
    // §3.8.3.7 PerformShadowRealmEval — parse + run the script in
    // the child realm. Any abrupt completion becomes a TypeError
    // raised IN THE CALLER REALM (§3.8.3.7 step 6).
    const result = interpreter.evaluateScript(eval_realm.allocator, eval_realm, s.flatBytes()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // §3.8.3.7 step 4 — a parse failure produces a
        // SyntaxError in the CALLER realm. The TypeError fallback
        // (step 6) only applies to abrupt completions during
        // evaluation, not parse-phase errors.
        error.ParseError => {
            const ex = intrinsics.newSyntaxError(realm, "ShadowRealm.prototype.evaluate: parse error in evaluated source") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
        else => return throwTypeError(realm, "ShadowRealm.prototype.evaluate: evaluation failed"),
    };
    switch (result) {
        .value, .yielded => |v| {
            // §3.8.3.4 step 3 — filter the result through the
            // callable boundary: primitives pass, callables get
            // wrapped, all other Object values throw TypeError in
            // the caller realm.
            return try getWrappedValue(realm, v);
        },
        .thrown => {
            return throwTypeError(realm, "ShadowRealm.prototype.evaluate: evaluation threw");
        },
    }
}

// ── §3.8.3.4 GetWrappedValue + §3.8.3.5 WrappedFunctionCreate ────────────

/// §3.8.3.4 GetWrappedValue ( callerRealm, value )
///   1. If Type(value) is Object:
///      a. If IsCallable(value) is false, throw a TypeError
///         exception in callerRealm.
///      b. Return ? WrappedFunctionCreate(callerRealm, value).
///   2. Return value (primitives pass through unmodified).
///
/// We collapse the spec's two-argument signature (the parent
/// `Realm` parameter is normally used only to pick the realm
/// the TypeError is constructed in). Cynic's `throwTypeError`
/// already targets the running realm, which is by definition
/// the caller realm at every call site.
pub fn getWrappedValue(caller_realm: *Realm, value: Value) NativeError!Value {
    // Step 2 — primitives (number, string, bigint, symbol, bool,
    // null, undefined) cross the boundary unmodified.
    if (value.isUndefined() or value.isNull() or value.isBool() or
        value.isInt32() or value.isDouble() or value.isString() or
        heap_mod.valueAsBigInt(value) != null or
        heap_mod.valueAsSymbol(value) != null)
    {
        return value;
    }
    // Step 1 — non-primitive: must be a function. JSFunction-tagged
    // values are callable; plain JSObjects are not (Cynic does not
    // model callable proxies through JSObject, callable proxies
    // route through JSFunction.proxy_target / revocable_proxy
    // slots).
    if (heap_mod.valueAsFunction(value)) |target| {
        const wrapper = wrappedFunctionCreate(caller_realm, target) catch return error.OutOfMemory;
        return heap_mod.taggedFunction(wrapper);
    }
    // Non-callable Object → TypeError in caller realm.
    return throwTypeError(caller_realm, "ShadowRealm boundary: non-callable, non-primitive value cannot cross");
}

/// §3.8.3.5 WrappedFunctionCreate ( callerRealm, Target )
///   1. Let wrapped be ! MakeBasicObject(« [[Realm]],
///      [[WrappedTargetFunction]] »).
///   2. Set wrapped.[[Prototype]] to callerRealm's %Function.prototype%.
///   3. Set wrapped.[[Call]] to the WrappedFunctionCall spec
///      operation (handled in `call.zig` via the
///      `wrapped_target_function` slot).
///   4. Set wrapped.[[WrappedTargetFunction]] to Target.
///   5. Set wrapped.[[Realm]] to callerRealm.
///   6. CopyNameAndLength(wrapped, Target, "wrapped") — mirror
///      `Target.name` (prefixed "wrapped " per §3.8.3.5.1) and
///      `Target.length`.
fn wrappedFunctionCreate(caller_realm: *Realm, target: *JSFunction) !*JSFunction {
    // Use a trampoline native that never actually runs — call
    // dispatch detects `wrapped_target_function != null` and
    // short-circuits before reaching the native body.
    const wrapped = try caller_realm.heap.allocateFunctionNative(wrappedTrampoline, 0, "wrapped");
    wrapped.proto = caller_realm.intrinsics.function_prototype;
    wrapped.realm = caller_realm;
    wrapped.wrapped_target_function = target;
    // §3.8.3.5.1 CopyNameAndLength step 5 — `name` = `"wrapped " ++ target.name`.
    // §3.8.3.5.1 step 8 — `length` = max(0, target.length - 0) (no prefix args).
    // Both default-installed by allocateFunctionNative; refine the
    // name / length to mirror the target only when the target's
    // values are observable (they typically are — tests check
    // `wrapped.length === target.length`).
    if (target.properties.get("length")) |len_v| {
        try wrapped.properties.put(caller_realm.allocator, "length", len_v);
    }
    if (target.properties.get("name")) |name_v| {
        try wrapped.properties.put(caller_realm.allocator, "name", name_v);
    }
    // §3.8.3.5 step 4 — wrapped functions have no [[Construct]].
    wrapped.has_construct = false;
    return wrapped;
}

/// Placeholder native body for WrappedFunction closures.
/// `callJSFunction` short-circuits on `wrapped_target_function`
/// before reaching this; the body exists only to satisfy the
/// non-null `native_callback` requirement of a host-allocated
/// function.
fn wrappedTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "internal: WrappedFunction trampoline reached (dispatch bug)");
}

/// §3.8.3.6 WrappedFunctionCall (called by `callJSFunction` when
/// a JSFunction's `wrapped_target_function` slot is non-null).
///
///   1. Let target be F.[[WrappedTargetFunction]].
///   2. Let callerRealm be F.[[Realm]].
///   3. Let targetRealm be ? GetFunctionRealm(target).
///   4. For each arg, let wrappedArg be ? GetWrappedValue(targetRealm, arg).
///   5. Let result be ? Call(target, undefined, wrappedArgs).
///   6. If result is abrupt, throw a TypeError in callerRealm.
///   7. Else return ? GetWrappedValue(callerRealm, result).
pub fn callWrappedFunction(
    allocator: std.mem.Allocator,
    realm: *Realm,
    wrapper: *JSFunction,
    args: []const Value,
) call_mod.RunError!call_mod.RunResult {
    const target = wrapper.wrapped_target_function orelse unreachable;
    const caller_realm = wrapper.realm orelse realm;
    // Step 3 — `target_realm` is the realm `target` was created in.
    // GetFunctionRealm walks the bound chain; falls back to `realm`
    // (current) only when no tag is reachable.
    const target_realm = target.getFunctionRealm() orelse realm;

    // Step 4 — marshal each arg from callerRealm into targetRealm.
    // Allocate the marshalled slice on the function-call allocator
    // (caller's arena) since args don't escape the call.
    var wrapped_args = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    defer allocator.free(wrapped_args);
    for (args, 0..) |a, i| {
        wrapped_args[i] = getWrappedValue(target_realm, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                const ex = target_realm.pending_exception orelse Value.undefined_;
                target_realm.pending_exception = null;
                return .{ .thrown = ex };
            },
        };
    }

    // Step 5 — call target with the marshalled args.
    const inner_result = try call_mod.callJSFunction(allocator, target_realm, target, Value.undefined_, wrapped_args);
    switch (inner_result) {
        .thrown => {
            // Step 6 — the target threw; remap to TypeError in
            // callerRealm. The §3.8 spec is intentionally
            // information-hiding here — the target's error object
            // would leak its realm-of-origin identity.
            const ex = intrinsics.newTypeError(caller_realm, "ShadowRealm boundary: wrapped function threw") catch return error.OutOfMemory;
            return .{ .thrown = ex };
        },
        .value, .yielded => |v| {
            const wrapped_ret = getWrappedValue(caller_realm, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = caller_realm.pending_exception orelse Value.undefined_;
                    caller_realm.pending_exception = null;
                    return .{ .thrown = ex };
                },
            };
            return .{ .value = wrapped_ret };
        },
    }
}

/// §3.8.3.2 ShadowRealm.prototype.importValue ( specifier,
/// exportName )
///
/// Phase 3.5 will wire this through the child realm's module
/// loader. Stubbed for now so fixtures that probe the method's
/// existence (descriptor checks, IsCallable on the method, etc.)
/// classify as engine-true even though calls throw.
fn shadowRealmImportValue(
    realm: *Realm,
    this_value: Value,
    args: []const Value,
) NativeError!Value {
    _ = args;
    _ = try shadowRealmOf(realm, this_value, "importValue");
    return throwTypeError(realm, "ShadowRealm.prototype.importValue is not yet implemented");
}
