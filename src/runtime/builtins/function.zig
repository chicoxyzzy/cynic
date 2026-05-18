//! §10.2 Function — extracted from `intrinsics.zig`. Two
//! distinct concerns:
//! • `Function.prototype.{call, apply, bind}` —
//! reflective invocation methods that re-enter the
//! interpreter via `callJSFunction`.
//! • `GeneratorFunction` / `AsyncFunction` /
//! `AsyncGeneratorFunction` — the constructors retrievable
//! via `Object.getPrototypeOf(function*(){}).constructor`
//! etc. Calling them as constructors is a TypeError stub
//! because string-source compilation is later.

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

const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const setNonEnumerable = intrinsics.setNonEnumerable;
const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const lengthOfArray = intrinsics.lengthOfArray;
const clampArrayLength = intrinsics.clampArrayLength;
const callJSFunction = interpreter.callJSFunction;

/// Accessor-aware `Get(target, key)` for a callable receiver.
/// `JSFunction.get` only consults the data-property bag and the
/// reflection slots (`length` / `name` / `prototype`); the spec
/// `Get` (§7.3.2) walks the proto chain and fires getters. Use
/// this for §20.2.3.2 step 5 `? Get(Target, "name")` and step 7
/// `? Get(Target, "length")` so a thrown getter (test262
/// `instance-name-error` / `instance-length-error`) propagates
/// rather than getting silently squashed.
const GetOutcome = union(enum) {
    value: Value,
    thrown: Value,
};

fn getAccessorAwareOnFunction(realm: *Realm, target: *JSFunction, key: []const u8) NativeError!GetOutcome {
    if (interpreter.lookupFunctionAccessor(target, key)) |acc| {
        if (acc.getter) |getter| {
            const outcome = callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(target), &[_]Value{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| return .{ .value = v },
                .thrown => |ex| return .{ .thrown = ex },
            }
        }
        return .{ .value = Value.undefined_ };
    }
    return .{ .value = target.get(key) };
}

/// Wire `Function.prototype.{call, apply, bind, toString}` onto
/// the realm's `%Function.prototype%`.
pub fn installPrototypeMethods(realm: *Realm) !void {
    const fn_proto = realm.intrinsics.function_prototype orelse return;

    // §20.2.3 — Properties of the Function Prototype Object.
    // `Function.prototype` itself has own data properties
    // `length: 0` and `name: ""` with §17 default flags
    // `{w:false, e:false, c:true}`. `installStubConstructor`
    // mistakenly leaves a `name: "Function"` slot; replace it.
    // `length` is installed first so the §17 property-order
    // convention (length before name) holds.
    _ = fn_proto.properties.swapRemove("name");
    _ = fn_proto.property_flags.swapRemove("name");
    const builtin_fn_flags: @import("../object.zig").PropertyFlags = .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    };
    try fn_proto.setWithFlags(realm.allocator, "length", Value.fromInt32(0), builtin_fn_flags);
    const empty_name = try realm.heap.allocateString("");
    try fn_proto.setWithFlags(realm.allocator, "name", Value.fromString(empty_name), builtin_fn_flags);

    try installNativeMethodOnProto(realm, fn_proto, "call", functionCall, 1);
    try installNativeMethodOnProto(realm, fn_proto, "apply", functionApply, 2);
    try installNativeMethodOnProto(realm, fn_proto, "bind", functionBind, 1);
    try installNativeMethodOnProto(realm, fn_proto, "toString", functionToString, 0);

    // §20.2.3.6 — Function.prototype[@@hasInstance].
    // Descriptor: `{w:false, e:false, c:false}` (per §17).
    // Function's own `name` is "[Symbol.hasInstance]", `length` is 1.
    const hi_fn = try realm.heap.allocateFunctionNative(functionHasInstance, 1, "[Symbol.hasInstance]");
    hi_fn.proto = fn_proto;
    hi_fn.has_construct = false;
    try fn_proto.setWithFlags(realm.allocator, "@@hasInstance", heap_mod.taggedFunction(hi_fn), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });

    // Replace the Function constructor stub. Cynic permanently
    // does not implement source-string compilation
    // (`new Function("return 1")` and friends), but the no-args
    // form `new Function()` is benign — it returns an empty
    // function that returns undefined. Real-world fixtures use
    // it as a fresh constructor object for `Reflect.construct(…,
    // NewTarget)` patterns.
    if (heap_mod.valueAsFunction(realm.globals.get("Function").?)) |fn_ctor| {
        fn_ctor.native_callback = functionConstructor;
    }
}

/// §20.2.1 The Function Constructor.
///
/// Cynic-only behaviour: the 0-arg form returns a fresh empty
/// function (no source text, returns undefined). The 1+-arg
/// form throws TypeError because Cynic doesn't ship runtime
/// source compilation — aligns with SES / Hardened JavaScript.
fn functionConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (args.len > 0) {
        return throwTypeError(realm, "Function constructor with source string is not supported (Cynic ships no eval / runtime code construction)");
    }
    // Allocate an empty anonymous function. The native body
    // returns undefined regardless of arguments — matches the
    // spec semantics of `Function()` (a function whose body is
    // the empty string).
    const empty = realm.heap.allocateFunctionNative(emptyFunctionBody, 0, "anonymous") catch return error.OutOfMemory;
    empty.proto = realm.intrinsics.function_prototype;
    // Wire up a normal `.prototype` object so users can
    // `Reflect.construct(C)` with our function as NewTarget.
    const proto = realm.heap.allocateObject() catch return error.OutOfMemory;
    proto.prototype = realm.intrinsics.object_prototype;
    proto.setWithFlags(realm.allocator, "constructor", heap_mod.taggedFunction(empty), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    empty.prototype = proto;
    // If called via `new`, the interpreter pre-allocated `this`;
    // ConstructResult prefers our return value (the empty fn) per
    // §13.3.5.1.1 when it's an Object. Plain-call returns it too.
    _ = this_value;
    return heap_mod.taggedFunction(empty);
}

fn emptyFunctionBody(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
}

// ── §20.2.3.6 / §7.3.20 Function.prototype[@@hasInstance] ──────────────
//
// `f[@@hasInstance](v)` returns OrdinaryHasInstance(f, v).
fn functionHasInstance(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const v = if (args.len > 0) args[0] else Value.undefined_;

    // §7.3.20 OrdinaryHasInstance step 1 — `If IsCallable(C) is
    // false, return false`. Cynic stores most callables as
    // `JSFunction`; the lone exception is `%Function.prototype%`
    // itself, which is allocated as a plain `JSObject` (the proto
    // produced by `installStubConstructor`) but is callable per
    // §10.2.3 (a no-op returning undefined). Honour the spec
    // contract by routing JSObject `this` through the accessor-
    // aware property-lookup helper so a user-installed getter on
    // `Function.prototype.prototype` fires (test262
    // language/expressions/instanceof/prototype-getter-with-object,
    // prototype-getter-with-object-throws,
    // primitive-prototype-with-object).
    if (heap_mod.valueAsFunction(this_value) == null) {
        const obj = heap_mod.valueAsPlainObject(this_value) orelse return Value.false_;
        if (realm.intrinsics.function_prototype) |fn_proto| {
            if (obj == fn_proto) {
                // §7.3.20 step 3 — if `v` is not an Object,
                // short-circuit to `false` BEFORE step 4 fires
                // `Get(C, "prototype")` (test262
                // prototype-getter-with-primitive,
                // primitive-prototype-with-primitive: the getter
                // must NOT be observed for primitive LHS).
                const v_is_obj = heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null;
                if (!v_is_obj) return Value.false_;
                const intrinsics_mod = @import("../intrinsics.zig");
                const proto_v = intrinsics_mod.getPropertyChain(realm, obj, "prototype") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                const proto_obj: *JSObject = heap_mod.valueAsPlainObject(proto_v) orelse {
                    return throwTypeError(realm, "Function has non-object prototype in instanceof check");
                };
                // §7.3.20 step 7 — walk the LHS prototype chain.
                if (heap_mod.valueAsPlainObject(v)) |lhs_obj| {
                    var cursor: ?*JSObject = lhs_obj.prototype;
                    while (cursor) |p| : (cursor = p.prototype) {
                        if (p == proto_obj) return Value.true_;
                    }
                    return Value.false_;
                } else if (heap_mod.valueAsFunction(v)) |lhs_fn| {
                    var cursor: ?*JSObject = lhs_fn.proto;
                    while (cursor) |p| : (cursor = p.prototype) {
                        if (p == proto_obj) return Value.true_;
                    }
                    return Value.false_;
                }
                return Value.false_;
            }
        }
        return Value.false_;
    }
    var target_fn = heap_mod.valueAsFunction(this_value).?;
    while (target_fn.bound_target) |inner| target_fn = inner;

    // §7.3.20 OrdinaryHasInstance step 4 — `Let P be ? Get(C,
    // "prototype")`. Must walk accessors so a poisoned
    // `Object.defineProperty(f, "prototype", {get(){throw}})`
    // surfaces the thrown completion (test262
    // `this-val-poisoned-prototype.js`). User-set data properties
    // ride the same path and shadow the auto-allocated slot.
    const target_proto_v = blk: {
        if (target_fn.accessors.get("prototype")) |acc| {
            if (acc.getter) |getter| {
                const out = interpreter.callJSFunction(realm.allocator, realm, getter, this_value, &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                break :blk switch (out) {
                    .value, .yielded => |v_| v_,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                };
            }
            break :blk Value.undefined_;
        }
        break :blk target_fn.get("prototype");
    };
    const target_proto: *JSObject = heap_mod.valueAsPlainObject(target_proto_v) orelse {
        return throwTypeError(realm, "Function has non-object prototype in instanceof check");
    };

    // §7.3.20 step 7 — walk the prototype chain by repeatedly
    // calling `O.[[GetPrototypeOf]]`. For Proxy receivers this
    // fires the `getPrototypeOf` handler trap at each step; an
    // abrupt completion from any step short-circuits the walk
    // (test262 `value-get-prototype-of-err.js`). Route through
    // `objectGetPrototypeOf` so the trap dispatch + invariants
    // are honoured.
    if (heap_mod.valueAsPlainObject(v) == null and heap_mod.valueAsFunction(v) == null) {
        return Value.false_;
    }
    const get_proto = @import("object.zig").objectGetPrototypeOf;
    var cursor_v: Value = v;
    while (true) {
        const args_one = [_]Value{cursor_v};
        const next_v = try get_proto(realm, Value.undefined_, &args_one);
        if (next_v.isNull()) return Value.false_;
        if (heap_mod.valueAsPlainObject(next_v)) |po| {
            if (po == target_proto) return Value.true_;
        }
        cursor_v = next_v;
    }
}

// ── Function.prototype.{call, apply, bind} ──────────────────────────────────
//
// `Function.prototype.call(thisArg,...args)` re-invokes the
// receiver function with the supplied `this` and arguments.
// Implemented as a native that loops back into the interpreter
// via `callJSFunction` — natives can call arbitrary JS without
// nesting Zig stack frames per opcode (the inner session uses
// its own frame stack).

fn functionCall(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §20.2.3.1 — if `this` is a callable Proxy, the apply trap
    // fires (callValue handles that); otherwise dispatch to the
    // ordinary function.
    if (heap_mod.valueAsFunction(this_value) == null and heap_mod.valueAsPlainObject(this_value) == null) {
        return throwTypeError(realm, "Function.prototype.call requires a callable receiver");
    }
    const this_arg = argOr(args, 0, Value.undefined_);
    const rest: []const Value = if (args.len > 1) args[1..] else &.{};

    const outcome = interpreter.callValue(realm.allocator, realm, this_value, this_arg, rest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| return v,
        .thrown => |ex| {
            // Surface the inner exception verbatim through the
            // `pending_exception` slot so the outer interpreter
            // re-raises with the right value (Test262Error etc.).
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn functionApply(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsFunction(this_value) == null and heap_mod.valueAsPlainObject(this_value) == null) {
        return throwTypeError(realm, "Function.prototype.apply requires a callable receiver");
    }
    const this_arg = argOr(args, 0, Value.undefined_);
    var apply_args: std.ArrayListUnmanaged(Value) = .empty;
    defer apply_args.deinit(realm.allocator);
    if (args.len > 1) {
        const arg_array = args[1];
        if (arg_array.isUndefined() or arg_array.isNull()) {
            // No extra args.
        } else if (heap_mod.valueAsPlainObject(arg_array)) |arr| {
            // §20.2.3.1 step 4 → §7.3.18 CreateListFromArrayLike:
            // both `Get(O, "length")` and `Get(O, ! ToString(i))`
            // are `?`-prefixed (abrupt). Use accessor-aware reads
            // so a getter that throws propagates instead of being
            // silently squashed to `undefined`.
            const len = try clampArrayLength(try intrinsics.toLengthOf(realm, arr));
            var i: i64 = 0;
            while (i < len) : (i += 1) {
                var ibuf: [24]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                const v = try intrinsics.getPropertyChain(realm, arr, islice);
                apply_args.append(realm.allocator, v) catch return error.OutOfMemory;
            }
        } else if (heap_mod.valueAsFunction(arg_array)) |fn_arr| {
            // §20.2.3.1 / §7.3.18 CreateListFromArrayLike — any
            // object with a `length` and indexed properties is a
            // valid argArray. Functions count: e.g.
            // `fn.apply(x, Array)` reads `Array.length` (== 1).
            // No accessors on JSFunction's own length/indices, so
            // plain `.get` is fine here.
            const len_v = fn_arr.get("length");
            const raw_len: i64 = if (len_v.isInt32()) len_v.asInt32() else if (len_v.isDouble()) blk: {
                const d = len_v.asDouble();
                if (std.math.isNan(d)) break :blk 0;
                break :blk @intFromFloat(@max(0.0, @min(d, @as(f64, @floatFromInt(@as(i64, std.math.maxInt(i64)))))));
            } else 0;
            const len = try clampArrayLength(raw_len);
            var i: i64 = 0;
            while (i < len) : (i += 1) {
                var ibuf: [24]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                apply_args.append(realm.allocator, fn_arr.get(islice)) catch return error.OutOfMemory;
            }
        } else {
            // §20.2.3.1 step 6 — non-object, non-null/undefined
            // is a TypeError.
            return error.NativeThrew;
        }
    }

    const outcome = interpreter.callValue(realm.allocator, realm, this_value, this_arg, apply_args.items) catch |err| switch (err) {
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

fn functionBind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §20.2.3.2 Function.prototype.bind. Returns a new BoundFunction
    // that, when called, dispatches to the target with `this`
    // pinned to the first arg and the remaining args prepended to
    // the call-site arg list. later uses a dedicated `bound_*`
    // slot trio on JSFunction; the call/call_method/new_call
    // opcodes detect a bound function and unwrap before dispatch.
    const target = heap_mod.valueAsFunction(this_value) orelse return throwTypeError(realm, "Function.prototype.bind requires a callable receiver");
    const bound_this = if (args.len > 0) args[0] else Value.undefined_;
    const prefix_args = if (args.len > 1) args[1..] else &[_]Value{};

    // Owning copy of the prefix args — the caller's slice is borrowed
    // from a register file that won't outlive this call.
    var owned_args: ?[]const Value = null;
    if (prefix_args.len > 0) {
        const buf = realm.allocator.alloc(Value, prefix_args.len) catch return error.OutOfMemory;
        @memcpy(buf, prefix_args);
        owned_args = buf;
    }

    // §20.2.3.2 step 5-7 — `targetHasLength = ? HasOwnProperty(Target,
    // "length")`. Only read `length` when it is an own property
    // of the target; non-own lengths (e.g. inherited via
    // setPrototypeOf) yield L = 0. If `length` is an own data /
    // accessor whose Type is not Number, L = 0. Otherwise
    // L = max(0, ToInteger(targetLen) - args.length).
    var bound_length: f64 = 0;
    const has_own_length = target.accessors.contains("length") or target.properties.contains("length");
    if (has_own_length) {
        const len_v = switch (try getAccessorAwareOnFunction(realm, target, "length")) {
            .value => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        // §20.2.3.2 step 7.b — `If Type(targetLen) is not Number,
        // let L be 0`. Type() distinguishes primitive Number from
        // Object (a boxed Number wrapper is Type Object), so any
        // non-primitive-Number value stays at the 0 default.
        if (len_v.isInt32()) {
            const li: i64 = @as(i64, len_v.asInt32()) - @as(i64, @intCast(prefix_args.len));
            bound_length = @floatFromInt(@max(@as(i64, 0), li));
        } else if (len_v.isDouble()) {
            const d = len_v.asDouble();
            if (std.math.isNan(d)) {
                bound_length = 0;
            } else if (std.math.isInf(d)) {
                bound_length = if (d > 0) d else 0;
            } else {
                const ti: f64 = @trunc(d);
                bound_length = @max(0.0, ti - @as(f64, @floatFromInt(prefix_args.len)));
            }
        }
    }

    // §20.2.3.2 step 4-6 — name = "bound " + (target.name if String else "").
    // Per spec: `? Get(Target, "name")` — accessor-aware, abrupt
    // propagates. The previous data-bag-only fallback swallowed
    // a thrown getter (test262 `instance-name-error`).
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer name_buf.deinit(realm.allocator);
    name_buf.appendSlice(realm.allocator, "bound ") catch return error.OutOfMemory;
    const target_name_v = switch (try getAccessorAwareOnFunction(realm, target, "name")) {
        .value => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    if (target_name_v.isString()) {
        const ts: *JSString = @ptrCast(@alignCast(target_name_v.asString()));
        name_buf.appendSlice(realm.allocator, ts.bytes) catch return error.OutOfMemory;
    }

    // The bound function carries no chunk; call sites detect
    // `bound_target` and route through that.
    const bound = realm.heap.allocateFunctionNative(boundFunctionTrampoline, 0, "bound") catch return error.OutOfMemory;
    bound.proto = realm.intrinsics.function_prototype;
    bound.bound_target = target;
    bound.bound_this = bound_this;
    bound.bound_args = owned_args;
    // §10.4.1.2 BoundFunctionCreate — the bound has [[Construct]] iff
    // the target has [[Construct]]. Built-in static methods (Math.cos,
    // String.fromCharCode, …) are installed with `has_construct=false`,
    // so `Math.cos.bind(…)` must NOT be IsConstructor; otherwise
    // `Array.of.call(Math.cos.bind(Math))` would take the constructor
    // path and observe a non-Array receiver (return-a-new-array-object.js).
    bound.has_construct = target.has_construct;

    // Override the §17 default `length` / `name` slots stamped
    // by `installFunctionLengthAndName` with the spec-computed
    // values. Flags stay `{w:false, e:false, c:true}`.
    const fn_flags: @import("../object.zig").PropertyFlags = .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    };
    const len_v: Value = if (bound_length >= -2147483648.0 and bound_length <= 2147483647.0 and @trunc(bound_length) == bound_length)
        Value.fromInt32(@intFromFloat(bound_length))
    else
        Value.fromDouble(bound_length);
    try bound.setWithFlags(realm.allocator, "length", len_v, fn_flags);
    const name_str = realm.heap.allocateString(name_buf.items) catch return error.OutOfMemory;
    try bound.setWithFlags(realm.allocator, "name", Value.fromString(name_str), fn_flags);

    return heap_mod.taggedFunction(bound);
}

/// Trampoline for bound functions. The interpreter's call ops
/// short-circuit before reaching this — the trampoline is here
/// only for code paths that go through `callJSFunction` with a
/// bound function as the callee. It rebuilds the args slice and
/// re-enters via `callJSFunction(target, bound_this, args)`.
fn boundFunctionTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // The native dispatch contract doesn't pass the callee
    // pointer, so the trampoline can't read its own bound state.
    // The interpreter call ops handle bound functions before
    // reaching here; a direct native invocation of a bound
    // function (which doesn't happen through any normal path)
    // is therefore an error.
    _ = realm;
    _ = args;
    return error.NativeThrew;
}

// ── §27.3-27.5 Function-flavour constructors ─────────────────────────

/// Set up `GeneratorFunction`, `AsyncFunction`, and
/// `AsyncGeneratorFunction` — the constructors retrievable via
/// `Object.getPrototypeOf(function*(){}).constructor` etc.
/// We don't support calling them as constructors yet (which
/// would compile a string source — that's later); the
/// intrinsics exist so introspection tests pass.
pub fn installVariantPrototypes(realm: *Realm) !void {
    realm.intrinsics.generator_function_prototype = try installVariantCtor(realm, "GeneratorFunction");
    realm.intrinsics.async_function_prototype = try installVariantCtor(realm, "AsyncFunction");
    realm.intrinsics.async_generator_function_prototype = try installVariantCtor(realm, "AsyncGeneratorFunction");
}

/// §27.3.4.3 GeneratorFunction.prototype.prototype = %GeneratorPrototype%
/// §27.4.3.4 AsyncGeneratorFunction.prototype.prototype = %AsyncGeneratorPrototype%
///
/// Tests routinely walk `Object.getPrototypeOf(function*(){}).prototype`
/// to reach the prototype with `next` / `return` / `throw`;
/// without these wirings that lookup yields `undefined`. Runs
/// AFTER `iterator.install` so the generator prototype's
/// `[[Prototype]]` resolves to `%Iterator.prototype%` per
/// §27.5.1 step 1.b of OrdinaryGeneratorObjectPrototype.
pub fn wireVariantInstancePrototypes(realm: *Realm) !void {
    const interp = @import("../interpreter.zig");
    if (realm.intrinsics.generator_function_prototype) |gfp| {
        const gp = try interp.ensureGeneratorPrototype(realm);
        try gfp.setWithFlags(realm.allocator, "prototype", heap_mod.taggedObject(gp), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
        // §27.5.1.1 — `%GeneratorPrototype%.constructor` is
        // `%GeneratorFunction.prototype%` (== `%Generator%`) with
        // attributes { w:false, e:false, c:true }.
        try gp.setWithFlags(realm.allocator, "constructor", heap_mod.taggedObject(gfp), .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }
    if (realm.intrinsics.async_generator_function_prototype) |agfp| {
        const agp = try interp.ensureAsyncGeneratorPrototype(realm);
        try agfp.setWithFlags(realm.allocator, "prototype", heap_mod.taggedObject(agp), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
        // §27.6.1.1 — `%AsyncGeneratorPrototype%.constructor` is
        // `%AsyncGeneratorFunction.prototype%` (== `%AsyncGenerator%`)
        // with attributes { w:false, e:false, c:true }.
        try agp.setWithFlags(realm.allocator, "constructor", heap_mod.taggedObject(agfp), .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }
}

fn installVariantCtor(realm: *Realm, name: []const u8) !*JSObject {
    const fn_obj = try realm.heap.allocateFunctionNative(variantCtorThrows, 1, name);
    fn_obj.proto = realm.intrinsics.function_prototype;
    const proto = try realm.heap.allocateObject();
    // §27.3 — these prototypes inherit from %Function.prototype%
    // (NOT %Object.prototype%) so e.g. `bind` / `call` resolve.
    proto.prototype = realm.intrinsics.function_prototype;
    // §27.3.4.1 / §27.4.3.1 — `constructor` is
    // { w:false, e:false, c:true } on the variant prototypes.
    // `setNonEnumerable` defaults to writable=true; use
    // `setWithFlags` directly with the spec-mandated flags.
    try proto.setWithFlags(realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
    // §27.3.3 — GeneratorFunction.prototype[@@toStringTag] etc.
    try installToStringTag(realm, proto, name);
    fn_obj.prototype = proto;
    // Not exposed as a global per spec (§27.3-27.5 — these
    // intrinsics are only reachable through introspection of
    // an instance). Test262 fixtures get there via
    // `Object.getPrototypeOf(function*(){}).constructor`.
    return proto;
}

fn variantCtorThrows(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    // Calling `GeneratorFunction("…")` etc. would compile a
    // string source. For now throw so tests that
    // intentionally trigger the error see a TypeError.
    return throwTypeError(realm, "Function constructor from string not supported");
}

// ── Function.prototype.toString ─────────────────────────────────────────────
//
// §20.2.3.5 — the spec wants the function's original source text
// for declarations / expressions / arrows / methods, and the
// "[native code]" placeholder for native functions and bound
// functions. We don't yet retain source slices on
// `FunctionTemplate`, so every callable falls into the native-
// function format. The format is the one test262's
// `nativeFunctionMatcher.js` validates: `function NAME(...) {
// [native code] }` — `validateNativeFunctionSource` walks it
// loosely (accepts any whitespace, strings inside the params).

fn functionToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §20.2.3.5 — `this` may be a Proxy whose target is callable.
    // Walk the proxy chain to the underlying JSFunction (or, if the
    // chain bottoms out at a non-function callable proxy, fall
    // through to the native-function placeholder). A revoked proxy
    // (proxy_revoked, no target_fn / target) throws TypeError.
    const fn_obj_opt = heap_mod.valueAsFunction(this_value);
    // §20.2.3.5 — Proxies whose target is callable are themselves
    // callable. The spec says the produced string must conform to
    // NativeFunction syntax — it must NOT echo the target's source
    // text, since the proxy may interpose `apply`. So we always
    // emit `function () { [native code] }` for a proxy receiver.
    var receiver_is_proxy: bool = false;
    if (fn_obj_opt == null) {
        if (heap_mod.valueAsPlainObject(this_value)) |obj| {
            if (obj.proxy_revoked) {
                return throwTypeError(realm, "Function.prototype.toString called on revoked proxy");
            }
            // §10.5 — a proxy is callable only when its target was
            // callable at construction time (`proxy_callable`).
            // `proxy_target_fn` implies the same; a plain object
            // target with no callability does NOT make the proxy
            // callable and `Function.prototype.toString` must throw.
            if (obj.proxy_target_fn != null or obj.proxy_callable) {
                receiver_is_proxy = true;
            }
        }
    }
    if (fn_obj_opt == null and !receiver_is_proxy) {
        // §20.2.3.5 step 3 — `this` must be a callable Object;
        // otherwise throw TypeError.
        return throwTypeError(realm, "Function.prototype.toString requires that 'this' be a Function");
    }
    if (receiver_is_proxy) {
        const formatted = std.fmt.allocPrint(realm.allocator, "function () {{ [native code] }}", .{}) catch return error.OutOfMemory;
        defer realm.allocator.free(formatted);
        const s = realm.heap.allocateString(formatted) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const fn_obj = fn_obj_opt.?;
    // §20.2.3.5 step 6 — if the function carries source text,
    // hand it back verbatim. Engine-synthesised functions
    // (default constructors, native bridges, bound functions)
    // fall through to the native-function placeholder.
    if (fn_obj.source) |src| {
        const s = realm.heap.allocateString(src) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const display_name: []const u8 = if (fn_obj.name) |n| n else "";
    const formatted = if (display_name.len == 0)
        std.fmt.allocPrint(realm.allocator, "function () {{ [native code] }}", .{}) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(realm.allocator, "function {s}() {{ [native code] }}", .{display_name}) catch return error.OutOfMemory;
    defer realm.allocator.free(formatted);
    const s = realm.heap.allocateString(formatted) catch return error.OutOfMemory;
    return Value.fromString(s);
}
