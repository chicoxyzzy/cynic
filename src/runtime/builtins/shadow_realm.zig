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
//! `host_data` slot (same trick `$262.createRealm()` uses), and
//! the instance's owner realm rides `shadow_realm_owner` in the
//! cold-field extension.
//!
//! `.evaluate` is fully wired (callable boundary + owner-realm
//! error tagging). `.importValue` still throws "not yet
//! implemented" — it needs the child realm's module loader, which
//! isn't wired here yet.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const PropertyFlags = @import("../object.zig").PropertyFlags;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../lantern/interpreter.zig");
const call_mod = @import("../lantern/call.zig");
const lantern_helpers = @import("../lantern/helpers.zig");
const promise_mod = @import("promise.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const throwTypeError = intrinsics.throwTypeError;
const argOr = intrinsics.argOr;

/// §7.3.2 Get on a JSFunction receiver, honoring accessor
/// descriptors so a throwing `length` or `name` getter
/// propagates. Mirrors `getAccessorAwareOnFunction` in
/// `builtins/function.zig`. Returns `undefined` when the
/// property is missing entirely (caller layers the spec's
/// "non-Number/Number → 0" / "non-String → empty" coercions on
/// top).
fn getAccessorAware(realm: *Realm, target: *JSFunction, key: []const u8) NativeError!Value {
    if (lantern_helpers.lookupFunctionAccessor(target, key)) |acc| {
        if (acc.getter) |getter| {
            const outcome = call_mod.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(target), &[_]Value{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| return v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        return Value.undefined_;
    }
    return target.get(key);
}

// ── §3.8 ShadowRealm ──────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "ShadowRealm",
        .ctor = shadowRealmConstructor,
        .arity = 0,
        .to_string_tag = "ShadowRealm",
    });
    // §3.8 — the constructor uses the `defers_proto_lookup`
    // pattern (ArrayBuffer / Promise style) so the body can read
    // `realm.pending_native_new_target` and derive the owner
    // realm via GetFunctionRealm(new_target). Without this, a
    // cross-realm construct (`Reflect.construct(OtherShadowRealm,
    // [])`) would lose track of which realm to associate the
    // instance with for boundary errors.
    r.ctor.defers_proto_lookup = true;
    const proto = r.proto;
    // Stash the prototype so `getPrototypeFromConstructorValue`
    // can use it as the intrinsic-default fallback inside the
    // constructor body.
    realm.intrinsics.shadow_realm_prototype = proto;

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
    _ = this_value; // OCFC deferred — see `defers_proto_lookup`
    // in `install`. The new_target sits on
    // `realm.pending_native_new_target`; absence means we were
    // called without `new`.
    _ = args;
    const new_target_v = realm.pending_native_new_target;
    if (new_target_v.isUndefined()) {
        return throwTypeError(realm, "ShadowRealm constructor requires 'new'");
    }
    // §3.8 — the instance's owner realm is GetFunctionRealm(new_target).
    // For `new ShadowRealm()` this is the running realm; for
    // `Reflect.construct(OtherShadowRealm, [])` it's OtherRealm.
    // Boundary errors and WrappedFunction `[[Realm]]` reads from
    // this slot.
    const owner_realm: *Realm = blk: {
        if (heap_mod.valueAsFunction(new_target_v)) |nt| {
            if (nt.getFunctionRealm()) |r_| break :blk r_;
        }
        break :blk realm;
    };

    // §3.8.1.1 step 2 — OrdinaryCreateFromConstructor. Read the
    // prototype off newTarget (may throw from a user getter).
    const interp = @import("../lantern/interpreter.zig");
    const proto_lookup = interp.getPrototypeFromConstructorValue(realm.allocator, realm, new_target_v, realm.intrinsics.shadow_realm_prototype) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const proto: ?*@import("../object.zig").JSObject = switch (proto_lookup) {
        .proto => |p| p,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, proto);

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
    // §6.1.5.1 — well-known symbols are agent-wide.
    child_ptr.shareWellKnownSymbolsWith(realm) catch return error.OutOfMemory;
    // Register the child on the parent's list so it lives as long
    // as the parent and gets torn down with it.
    realm.child_realms.append(realm.allocator, child_ptr) catch return error.OutOfMemory;

    // Brand + stash slots: child realm (host_data) + owner realm
    // (both ride the cold-field extension; ShadowRealm instances
    // are rare so neither sits inline on every JSObject).
    inst.is_shadow_realm = true;
    inst.setHostData(realm.allocator, @ptrCast(child_ptr)) catch return error.OutOfMemory;
    inst.setShadowRealmOwner(realm.allocator, owner_realm) catch return error.OutOfMemory;

    return heap_mod.taggedObject(inst);
}

/// Pulls the (child realm, owner realm) pair out of a ShadowRealm
/// receiver, throwing the §3.8 brand-check TypeError when
/// `this_value` isn't a ShadowRealm instance.
///
/// `child` is where evaluate runs source / importValue loads
/// modules. `owner` is the instance's `[[Realm]]`-equivalent —
/// the realm where boundary errors land and WrappedFunctions
/// get their `[[Realm]]` stamp.
const ShadowRealmRefs = struct { child: *Realm, owner: *Realm };

fn shadowRealmOf(realm: *Realm, this_value: Value, method_name: []const u8) NativeError!ShadowRealmRefs {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwBrandError(realm, method_name);
    };
    if (!inst.is_shadow_realm) return throwBrandError(realm, method_name);
    const raw = inst.getHostData() orelse return throwBrandError(realm, method_name);
    const child: *Realm = @ptrCast(@alignCast(raw));
    // §10.2.5 / §3.8 — the "caller realm" is the realm of the
    // method FUNCTION currently executing (the dispatcher recorded
    // it in `active_native_fn_realm` just before invoking us). This
    // is what makes `YetAnotherShadowRealm.prototype.evaluate.call(
    // otherInstance, …)` tag its boundary errors / WrappedFunctions
    // with YetAnotherRealm rather than the instance's owner. Falls
    // back to the instance's construct-time owner, then the running
    // realm. Read it FIRST — any later native dispatch inside the
    // method overwrites the slot.
    const owner = realm.active_native_fn_realm orelse inst.shadowRealmOwner() orelse realm;
    return .{ .child = child, .owner = owner };
}

fn throwBrandError(realm: *Realm, method_name: []const u8) NativeError {
    // §3.8.3 RequireInternalSlot — the TypeError is created in the
    // realm of the METHOD function (active_native_fn_realm), not
    // the running realm, so `OtherShadowRealm.prototype.evaluate
    // .call(bogus, …)` throws `OtherTypeError`. Pin it on the
    // running realm's pending_exception for the dispatcher.
    const err_realm = realm.active_native_fn_realm orelse realm;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "ShadowRealm.prototype.{s} called on non-ShadowRealm receiver",
        .{method_name},
    ) catch "ShadowRealm.prototype called on non-ShadowRealm receiver";
    const ex = intrinsics.newTypeError(err_realm, msg) catch return error.OutOfMemory;
    realm.pending_exception = ex;
    return error.NativeThrew;
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
    const refs = try shadowRealmOf(realm, this_value, "evaluate");
    const owner = refs.owner;
    const eval_realm = refs.child;
    const source_arg = argOr(args, 0, Value.undefined_);
    if (!source_arg.isString()) {
        const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.evaluate: sourceText must be a string") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const s: *JSString = @ptrCast(@alignCast(source_arg.asString()));
    // §3.8.3.7 PerformShadowRealmEval — parse + run the script in
    // the child realm. Any abrupt completion becomes a TypeError
    // raised IN THE OWNER REALM (the ShadowRealm instance's
    // [[Realm]] — `Reflect.construct(OtherShadowRealm, [])` makes
    // this different from the running realm).
    const result = interpreter.evaluateScript(eval_realm.allocator, eval_realm, s.flatBytes()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // §3.8.3.7 step 4 — parse failures produce a SyntaxError
        // IN THE OWNER REALM.
        error.ParseError => {
            const ex = intrinsics.newSyntaxError(owner, "ShadowRealm.prototype.evaluate: parse error in evaluated source") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
        else => {
            const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.evaluate: evaluation failed") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    switch (result) {
        .value, .yielded => |v| {
            // §3.8.3.4 step 3 — filter the result through the
            // callable boundary in the owner realm: primitives
            // pass, callables get wrapped, non-callable Objects
            // throw TypeError in OWNER realm.
            const wrapped = getWrappedValue(owner, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    // owner.pending_exception already carries the
                    // boundary TypeError; surface it on the
                    // running realm so the dispatcher unwinds.
                    if (owner != realm) {
                        realm.pending_exception = owner.pending_exception;
                        owner.pending_exception = null;
                    }
                    return error.NativeThrew;
                },
            };
            return wrapped;
        },
        .thrown => {
            // §3.8.3.7 step 6 — remap abrupt completion to a
            // TypeError IN THE OWNER REALM. `throwTypeError`
            // pins the exception on the supplied realm; copy it
            // to the running realm so the dispatcher's unwinder
            // picks it up.
            const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.evaluate: evaluation threw") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
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
    // Step 1 — non-primitive: IsCallable must be true. JSFunction
    // is callable; a JSObject is callable iff it's a Proxy whose
    // target chain bottoms out on a callable (`proxy_callable`
    // flag), or it's an engine-internal `proxy_callable` slot like
    // %Function.prototype%. Wrapping either kind produces a fresh
    // WrappedFunction in the caller realm.
    if (heap_mod.valueAsFunction(value) != null) {
        const wrapper = try wrappedFunctionCreate(caller_realm, value);
        return heap_mod.taggedFunction(wrapper);
    }
    if (heap_mod.valueAsPlainObject(value)) |obj| {
        if (obj.proxy_callable) {
            const wrapper = try wrappedFunctionCreate(caller_realm, value);
            return heap_mod.taggedFunction(wrapper);
        }
    }
    // Non-callable Object → TypeError in caller realm.
    return throwTypeError(caller_realm, "ShadowRealm boundary: non-callable, non-primitive value cannot cross");
}

/// §3.8.3.5 WrappedFunctionCreate ( callerRealm, Target )
///   1. Let wrapped be ! MakeBasicObject(« [[Realm]],
///      [[WrappedTargetFunction]] »).
///   2. Set wrapped.[[Prototype]] to callerRealm's
///      %Function.prototype%.
///   3. Set wrapped.[[Call]] to WrappedFunctionCall (handled
///      via the `wrapped_target` slot).
///   4. Set wrapped.[[WrappedTargetFunction]] to Target.
///   5. Set wrapped.[[Realm]] to callerRealm.
///   6. Let result be CopyNameAndLength(wrapped, Target). If
///      result is an abrupt completion, throw a TypeError
///      exception in callerRealm.
///
/// `target` is Value-typed: a JSFunction or a callable
/// JSObject (Proxy on a callable target). CopyNameAndLength
/// fires accessors on the target — a throwing `length` or
/// `name` getter must surface as an abrupt completion
/// (`WrappedFunction/{length,name}-throws-typeerror.js`).
fn wrappedFunctionCreate(caller_realm: *Realm, target: Value) NativeError!*JSFunction {
    // Use a trampoline native that never actually runs — call
    // dispatch detects `!wrapped_target.isUndefined()` and short-
    // circuits before reaching the native body.
    const wrapped = caller_realm.heap.allocateFunctionNative(wrappedTrampoline, 0, "") catch return error.OutOfMemory;
    wrapped.proto = caller_realm.intrinsics.function_prototype;
    wrapped.realm = caller_realm;
    wrapped.wrapped_target = target;
    // §3.8.3.5 step 4 — wrapped functions have no [[Construct]].
    wrapped.has_construct = false;

    // §3.8.3.5 step 6 + §3.8.3.5.1 CopyNameAndLength. The spec
    // catches abrupt completions and rethrows them AS a fresh
    // TypeError in callerRealm.
    copyNameAndLength(caller_realm, wrapped, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            caller_realm.pending_exception = null;
            return throwTypeError(caller_realm, "ShadowRealm: WrappedFunctionCreate could not copy target's length/name");
        },
    };

    return wrapped;
}

/// §3.8.3.5.1 CopyNameAndLength(F, Target, prefix, argCount):
///   1. If argCount is undefined, set argCount to 0.
///   2. Let L be 0.
///   3. Let targetHasLength be ? HasOwnProperty(Target, "length").
///   4. If targetHasLength is true:
///      a. Let targetLen be ? Get(Target, "length").
///      b. If Type(targetLen) is Number:
///         i.   If targetLen is +∞, set L to +∞.
///         ii.  Else if targetLen is -∞, set L to 0.
///         iii. Else: L = max(ToIntegerOrInfinity(targetLen) -
///              argCount, 0).
///   5. SetFunctionLength(F, L).
///   6. Let targetName be ? Get(Target, "name").
///   7. If Type(targetName) is not String, set targetName to "".
///   8. SetFunctionName(F, targetName, prefix).
///
/// WrappedFunctionCreate calls this without a prefix and with
/// argCount = 0, so `wrapped.name === target.name` (no "wrapped "
/// prefix) and `wrapped.length === target.length` (mod the
/// special cases above).
fn copyNameAndLength(realm: *Realm, wrapped: *JSFunction, target_v: Value) NativeError!void {
    // §17 — function `length` and `name` descriptors are
    // `{w:false, e:false, c:true}`.
    const fn_flags: PropertyFlags = .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    };

    // Step 3-4 / 6 — read the raw `length` and `name` off the
    // target. Two target shapes cross the boundary:
    //   - JSFunction: typed accessor / data-bag path (mirrors
    //     `Function.prototype.bind`).
    //   - callable JSObject (a Proxy on a callable): the spec's
    //     `Get(Target, …)` fires the proxy's `get` / underlying
    //     `[[GetOwnProperty]]` traps. A REVOKED proxy or a
    //     throwing trap makes that `Get` abrupt — which is the
    //     §3.8.3.5 step 8 abrupt completion the
    //     `WrappedFunction/throws-typeerror-{wrap-throwing,
    //     on-revoked-proxy}` fixtures pin. `getPropertyChain` is
    //     the generic proxy- and accessor-aware Get; abrupt
    //     completions propagate as `error.NativeThrew` and
    //     `wrappedFunctionCreate` remaps them to a fresh owner-
    //     realm TypeError.
    var raw_len: Value = Value.undefined_;
    var raw_name: Value = Value.undefined_;
    if (heap_mod.valueAsFunction(target_v)) |target| {
        // §10.2.4 ordinary functions always have a `length` slot;
        // only Get it when present (an arrow with a redefined
        // accessor counts via the accessor map).
        if (target.accessors.contains("length") or target.properties.contains("length")) {
            raw_len = try getAccessorAware(realm, target, "length");
        }
        raw_name = try getAccessorAware(realm, target, "name");
    } else if (heap_mod.valueAsPlainObject(target_v)) |obj| {
        raw_len = try intrinsics.getPropertyChain(realm, obj, "length");
        raw_name = try intrinsics.getPropertyChain(realm, obj, "name");
    }

    // Step 4.b — `length`: Number filter, then +∞ → +∞, -∞/NaN/
    // non-Number → 0, else max(trunc(n), 0).
    var length_value: Value = Value.fromInt32(0);
    if (raw_len.isInt32()) {
        const li: i64 = raw_len.asInt32();
        length_value = Value.fromInt32(@intCast(if (li > 0) li else 0));
    } else if (raw_len.isDouble()) {
        const d = raw_len.asDouble();
        if (std.math.isNan(d)) {
            length_value = Value.fromInt32(0);
        } else if (std.math.isInf(d)) {
            length_value = if (d > 0) Value.fromDouble(std.math.inf(f64)) else Value.fromInt32(0);
        } else {
            const ti: f64 = @trunc(d);
            const clamped: f64 = if (ti > 0) ti else 0;
            if (clamped == @as(f64, @floatFromInt(@as(i64, @intFromFloat(clamped)))) and clamped < 2147483647.0) {
                length_value = Value.fromInt32(@intFromFloat(clamped));
            } else {
                length_value = Value.fromDouble(clamped);
            }
        }
    }

    // Step 6-7 — `name`: non-String → "". No prefix (WrappedFunction
    // installs the target's name verbatim).
    var name_value: Value = raw_name;
    if (!raw_name.isString()) {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        name_value = Value.fromString(empty);
    }

    try wrapped.setWithFlags(realm.allocator, "length", length_value, fn_flags);
    try wrapped.setWithFlags(realm.allocator, "name", name_value, fn_flags);
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
/// a JSFunction's `wrapped_target` slot is non-undefined).
///
///   1. Let target be F.[[WrappedTargetFunction]].
///   2. Let callerRealm be F.[[Realm]].
///   3. Let targetRealm be ? GetFunctionRealm(target).
///      — for a revoked Proxy target, GetFunctionRealm throws
///      TypeError per §10.2.5 step 3.a.
///   4. For each arg, let wrappedArg be ? GetWrappedValue(targetRealm, arg).
///   5. Let result be ? Call(target, undefined, wrappedArgs).
///   6. If result is abrupt, throw a TypeError in callerRealm.
///   7. Else return ? GetWrappedValue(callerRealm, result).
/// §10.2.5 GetFunctionRealm for a Value: a JSFunction reports its
/// own realm (walking the bound chain); a callable Proxy reports
/// its target's realm (step 3.b, recursing through nested
/// proxies). `null` when no realm is reachable (caller falls back
/// to the running realm).
fn targetRealmOf(target_v: Value) ?*Realm {
    if (heap_mod.valueAsFunction(target_v)) |f| return f.getFunctionRealm();
    if (heap_mod.valueAsPlainObject(target_v)) |obj| {
        if (obj.proxy_target_fn) |tfn| return tfn.getFunctionRealm();
        if (obj.proxy_target) |t| return targetRealmOf(heap_mod.taggedObject(t));
    }
    return null;
}

pub fn callWrappedFunction(
    allocator: std.mem.Allocator,
    realm: *Realm,
    wrapper: *JSFunction,
    args: []const Value,
) call_mod.RunError!call_mod.RunResult {
    const target_v = wrapper.wrapped_target;
    const caller_realm = wrapper.realm orelse realm;

    // Step 3 — `target_realm` walks GetFunctionRealm on the
    // target. A revoked proxy hits step 3.a and throws TypeError
    // *in callerRealm*. For now we approximate: if the target is
    // a revoked-proxy JSObject, throw immediately.
    if (heap_mod.valueAsPlainObject(target_v)) |obj| {
        if (obj.proxy_revoked) {
            const ex = intrinsics.newTypeError(caller_realm, "ShadowRealm boundary: target proxy is revoked") catch return error.OutOfMemory;
            return .{ .thrown = ex };
        }
    }
    // Step 3 — §10.2.5 GetFunctionRealm. For a JSFunction, ask the
    // function. For a callable Proxy, recurse to its target
    // (§10.2.5 step 3.b) — the proxy's realm is its target's realm.
    // Critical: a proxy's `apply` trap is a closure of the realm
    // the proxy was created in, so it must run with THAT realm as
    // the interpreter's `realm` (else a global the trap references
    // resolves against the wrong globals and throws).
    const target_realm: *Realm = targetRealmOf(target_v) orelse realm;

    // Step 4 — marshal each arg from callerRealm into targetRealm.
    // §3.8.3.6 step 5 NOTE: "Any exception objects produced
    // after this point are associated with callerRealm." So a
    // non-wrappable arg's TypeError (raised inside GetWrappedValue
    // with the targetRealm parameter) gets retagged here as a
    // fresh callerRealm TypeError before propagation — otherwise
    // the test262 `wrappedFunction(non-callable-obj)` fixtures see
    // `targetRealm.TypeError` and fail the `instanceof
    // callerRealm.TypeError` check.
    var wrapped_args = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    defer allocator.free(wrapped_args);
    for (args, 0..) |a, i| {
        wrapped_args[i] = getWrappedValue(target_realm, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                // Drop the target-realm exception; re-throw a
                // fresh callerRealm TypeError so the instanceof
                // check in the calling JS sees the right
                // constructor identity.
                target_realm.pending_exception = null;
                const ex = intrinsics.newTypeError(caller_realm, "ShadowRealm boundary: argument cannot cross") catch return error.OutOfMemory;
                return .{ .thrown = ex };
            },
        };
    }

    // Step 5 — call target with the marshalled args. `callValue`
    // dispatches through Proxy traps for callable JSObject
    // targets and direct call for JSFunctions.
    const inner_result = try call_mod.callValue(allocator, target_realm, target_v, Value.undefined_, wrapped_args);
    switch (inner_result) {
        .thrown => {
            // Step 6 — the target threw; remap to TypeError in
            // callerRealm. §3.8's information-hiding posture
            // requires not leaking the target's exception object.
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

/// §3.8.3.2 ShadowRealm.prototype.importValue ( specifier, exportName )
///   1. RequireInternalSlot(O, [[ShadowRealm]]).
///   2. specifierString = ? ToString(specifier).  (synchronous throw)
///   3. If exportName is not a String, throw TypeError. (synchronous)
///   4-5. Return ? ShadowRealmImportValue(specifierString,
///        exportName, callerRealm, evalRealm).
///
/// §3.8.3.6 ShadowRealmImportValue builds a callerRealm Promise
/// capability, loads the module in evalRealm, and on completion
/// reads the named export, filters it through GetWrappedValue,
/// and resolves the Promise; any failure (load error, missing
/// export, non-wrappable value) rejects with a TypeError in
/// callerRealm.
///
/// Cynic's loader is synchronous, so the load runs inline and the
/// capability settles before this returns — `.then` on the
/// returned (callerRealm) Promise still defers via the caller
/// realm's microtask queue, so the async observation is correct
/// and we avoid draining the child realm's queue from here.
fn shadowRealmImportValue(
    realm: *Realm,
    this_value: Value,
    args: []const Value,
) NativeError!Value {
    const refs = try shadowRealmOf(realm, this_value, "importValue");
    const owner = refs.owner;
    const eval_realm = refs.child;

    // Step 2 — ToString(specifier). Abrupt → synchronous throw
    // (NOT a rejected Promise), per the `?`.
    const spec_arg = argOr(args, 0, Value.undefined_);
    const spec_str = intrinsics.stringifyArg(realm, spec_arg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return error.NativeThrew, // pending_exception already set
    };

    // Step 3 — exportName must be a String; else synchronous TypeError.
    const export_arg = argOr(args, 1, Value.undefined_);
    if (!export_arg.isString()) {
        const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.importValue: exportName must be a string") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const export_str: *JSString = @ptrCast(@alignCast(export_arg.asString()));

    // §3.8.3.6 — build the callerRealm (owner) Promise capability.
    const owner_promise_v = owner.globals.get("Promise") orelse {
        const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.importValue: Promise is missing in caller realm") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    };
    const owner_promise_ctor = heap_mod.valueAsFunction(owner_promise_v) orelse {
        const ex = intrinsics.newTypeError(owner, "ShadowRealm.prototype.importValue: caller realm Promise is not callable") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    };
    const cap = try promise_mod.newPromiseCapability(realm, owner_promise_ctor);

    // Pin the capability across the synchronous module load (the
    // module body re-enters JS and can allocate / GC).
    const scope = eval_realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(cap.promise) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;

    // Settle the capability and return its Promise. `settle`
    // rejects with a fresh owner-realm TypeError on any failure
    // (§3.8 information-hiding — the child's error object never
    // crosses the boundary).
    settleImportValue(realm, owner, eval_realm, spec_str.flatBytes(), export_str.flatBytes(), cap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A boundary failure surfaced as NativeThrew while we were
        // settling — the capability was already rejected by
        // `settle`, so swallow and return the (rejected) Promise.
        error.NativeThrew => {},
    };
    return cap.promise;
}

/// Loads `specifier` in `eval_realm`, reads `export_name` off the
/// resulting namespace, wraps it through the §3.8.3.4 boundary,
/// and resolves `cap`; on any abrupt step rejects `cap` with a
/// fresh owner-realm TypeError.
fn settleImportValue(
    realm: *Realm,
    owner: *Realm,
    eval_realm: *Realm,
    specifier: []const u8,
    export_name: []const u8,
    cap: promise_mod.PromiseCapability,
) NativeError!void {
    const outcome = interpreter.loadModule(eval_realm.allocator, eval_realm, specifier, null, null) catch {
        return rejectImport(realm, owner, cap, "ShadowRealm.prototype.importValue: module load failed");
    };
    if (outcome.threw) {
        // §3.8 information-hiding — don't leak the child realm's
        // error object; reject with a fresh owner-realm TypeError.
        return rejectImport(realm, owner, cap, "ShadowRealm.prototype.importValue: module evaluation threw");
    }
    const ns_obj = heap_mod.valueAsPlainObject(outcome.value) orelse {
        return rejectImport(realm, owner, cap, "ShadowRealm.prototype.importValue: module has no namespace");
    };
    // §3.8.3.6 — the export must exist as an own binding of the
    // namespace; a missing name rejects with TypeError.
    if (!ns_obj.hasOwn(export_name)) {
        return rejectImport(realm, owner, cap, "ShadowRealm.prototype.importValue: export not found");
    }
    const export_val = try intrinsics.getPropertyChain(eval_realm, ns_obj, export_name);
    // §3.8.3.4 GetWrappedValue — primitives cross, callables wrap,
    // other objects reject (in the owner realm).
    const wrapped = getWrappedValue(owner, export_val) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            owner.pending_exception = null;
            return rejectImport(realm, owner, cap, "ShadowRealm.prototype.importValue: exported value is not wrappable");
        },
    };
    // Resolve the caller-realm Promise with the wrapped value.
    const outcome_r = call_mod.callJSFunction(realm.allocator, realm, cap.resolve, Value.undefined_, &[_]Value{wrapped}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    _ = outcome_r;
}

/// Reject `cap` with a fresh owner-realm TypeError carrying `msg`.
fn rejectImport(realm: *Realm, owner: *Realm, cap: promise_mod.PromiseCapability, msg: []const u8) NativeError!void {
    const ex = intrinsics.newTypeError(owner, msg) catch return error.OutOfMemory;
    const outcome = call_mod.callJSFunction(realm.allocator, realm, cap.reject, Value.undefined_, &[_]Value{ex}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    _ = outcome;
}
