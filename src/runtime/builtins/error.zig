//! §20.5 Error and the four typed subclasses (TypeError,
//! RangeError, ReferenceError, SyntaxError) — extracted from
//! `intrinsics.zig`.
//!
//! Each constructor is a native body (`errorNative`,
//! `typeErrorNative`, …) that sets `.message` on the
//! freshly-allocated `this`. The shared `installError` builder
//! creates the constructor + prototype pair, wires the
//! prototype chain so `TypeError.prototype.__proto__ ===
//! Error.prototype`, and exposes the constructor as a global.
//!
//! The runtime's exception path uses `newTypeError` /
//! `newRangeError` / etc. to throw spec-flavored errors
//! (with real `.message` and `.constructor`) so user code
//! that catches them sees the right class.

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

const argOr = intrinsics.argOr;
const setNonEnumerable = intrinsics.setNonEnumerable;
const stringifyArg = intrinsics.stringifyArg;

/// Install Error and the four typed subclasses on the realm.
/// Each one creates a constructor / prototype pair, wires the
/// prototype-chain so subclasses inherit from `Error.prototype`,
/// and pins both pointers on `realm.intrinsics`. Must run
/// before any other built-in install: a few of them throw
/// TypeError / RangeError on bad ctor input via
/// `realm.intrinsics.type_error_prototype`.
pub fn installAll(realm: *Realm, obj_proto: *JSObject) !void {
    const error_ctor = try installError(realm, "Error", errorNative, obj_proto);
    realm.intrinsics.error_constructor = error_ctor;
    const error_proto = error_ctor.prototype.?;
    realm.intrinsics.error_prototype = error_proto;

    realm.intrinsics.type_error_constructor = try installError(realm, "TypeError", typeErrorNative, error_proto);
    realm.intrinsics.type_error_prototype = realm.intrinsics.type_error_constructor.?.prototype;
    // §20.5.6.1 — each NativeError constructor's [[Prototype]]
    // is %Error% (the Error constructor itself). `static_parent`
    // is Cynic's slot for the constructor's own [[Prototype]]
    // when the parent is a JSFunction; `objectGetPrototypeOf`
    // reads it first.
    realm.intrinsics.type_error_constructor.?.static_parent = error_ctor;

    realm.intrinsics.range_error_constructor = try installError(realm, "RangeError", rangeErrorNative, error_proto);
    realm.intrinsics.range_error_prototype = realm.intrinsics.range_error_constructor.?.prototype;
    realm.intrinsics.range_error_constructor.?.static_parent = error_ctor;

    realm.intrinsics.reference_error_constructor = try installError(realm, "ReferenceError", referenceErrorNative, error_proto);
    realm.intrinsics.reference_error_prototype = realm.intrinsics.reference_error_constructor.?.prototype;
    realm.intrinsics.reference_error_constructor.?.static_parent = error_ctor;

    realm.intrinsics.syntax_error_constructor = try installError(realm, "SyntaxError", syntaxErrorNative, error_proto);
    realm.intrinsics.syntax_error_prototype = realm.intrinsics.syntax_error_constructor.?.prototype;
    realm.intrinsics.syntax_error_constructor.?.static_parent = error_ctor;

    realm.intrinsics.uri_error_constructor = try installError(realm, "URIError", uriErrorNative, error_proto);
    realm.intrinsics.uri_error_prototype = realm.intrinsics.uri_error_constructor.?.prototype;
    realm.intrinsics.uri_error_constructor.?.static_parent = error_ctor;

    realm.intrinsics.eval_error_constructor = try installError(realm, "EvalError", evalErrorNative, error_proto);
    realm.intrinsics.eval_error_prototype = realm.intrinsics.eval_error_constructor.?.prototype;
    realm.intrinsics.eval_error_constructor.?.static_parent = error_ctor;

    // §20.5.6.3 NativeError prototype object — each NativeError
    // prototype is an Error instance shape with own
    // `message: ""` (besides the `constructor` and `name` already
    // wired by `installError`).
    try installPrototypeMessage(realm, error_proto);
    try installPrototypeMessage(realm, realm.intrinsics.type_error_prototype.?);
    try installPrototypeMessage(realm, realm.intrinsics.range_error_prototype.?);
    try installPrototypeMessage(realm, realm.intrinsics.reference_error_prototype.?);
    try installPrototypeMessage(realm, realm.intrinsics.syntax_error_prototype.?);
    try installPrototypeMessage(realm, realm.intrinsics.uri_error_prototype.?);
    try installPrototypeMessage(realm, realm.intrinsics.eval_error_prototype.?);

    // §20.5.3.4 Error.prototype.toString — installed only on the
    // Error prototype; NativeError instances inherit it.
    try intrinsics.installNativeMethodOnProto(realm, error_proto, "toString", errorPrototypeToString, 0);
    // §20.5.2.1 Error.isError(arg) — ES2025. Returns true iff
    // arg is an Object with an `[[ErrorData]]` internal slot.
    // Cynic's brand check is structural: any object whose
    // prototype chain reaches `%Error.prototype%` was created
    // by an Error / NativeError / AggregateError ctor that
    // installed the right prototype.
    try intrinsics.installNativeMethod(realm, error_ctor, "isError", errorIsError, 1);

    // §20.5.7 AggregateError(errors, message, options) — the only
    // typed Error whose constructor takes a leading iterable.
    // Built with the same `installError` builder; the constructor
    // body iterates `errors`, materialises an Array, and pins it
    // as an own data property on the instance.
    realm.intrinsics.aggregate_error_constructor = try installAggregateError(realm, error_proto);
    realm.intrinsics.aggregate_error_prototype = realm.intrinsics.aggregate_error_constructor.?.prototype;
    realm.intrinsics.aggregate_error_constructor.?.static_parent = error_ctor;
}

/// §20.5.7.1.1 AggregateError(errors, message[, options]) — built
/// out-of-line because its arity is 2 (vs. 1 for the rest) and
/// the body has to walk the iterable to populate `errors`.
fn installAggregateError(realm: *Realm, parent_proto: *JSObject) !*JSFunction {
    const fn_obj = try realm.heap.allocateFunctionNative(aggregateErrorNative, 2, "AggregateError");
    const proto = try realm.heap.allocateObject();
    proto.prototype = parent_proto;
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    const name_str = try realm.heap.allocateString("AggregateError");
    try setNonEnumerable(proto, realm.allocator, "name", Value.fromString(name_str));
    // §20.5.7.3.2 — the prototype's `message` defaults to "".
    const empty = try realm.heap.allocateString("");
    try setNonEnumerable(proto, realm.allocator, "message", Value.fromString(empty));
    fn_obj.prototype = proto;
    // §20.5.7.2.1 — AggregateError.prototype is `{ writable:
    // false, enumerable: false, configurable: false }` (same
    // shape as other NativeError prototypes). Override the
    // default `{w:true, e:false, c:false}` from
    // `JSFunction.flagsForOwn`.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    try realm.globals.put(realm.allocator, "AggregateError", heap_mod.taggedFunction(fn_obj));
    return fn_obj;
}

fn aggregateErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const proto = realm.intrinsics.aggregate_error_prototype.?;
    // §20.5.7.1.1 — Error subclass-aware: if `this_value` is an
    // already-allocated object (via `new` or `super(...)`),
    // initialise it in-place; otherwise allocate fresh.
    const instance = if (heap_mod.valueAsPlainObject(this_value)) |o| o else blk: {
        const fresh = realm.heap.allocateObject() catch return error.OutOfMemory;
        fresh.prototype = proto;
        break :blk fresh;
    };
    instance.has_error_data = true;

    // §20.5.7.1.1 step 3 — if message ≠ undefined, ToString(message)
    // BEFORE step 4's IterableToList(errors). The fixture
    // `order-of-args-evaluation.js` encodes this: `message.toString`
    // must fire before `errors[@@iterator]`.
    if (args.len > 1 and !args[1].isUndefined()) {
        const msg_str = try stringifyArg(realm, args[1]);
        instance.setWithFlags(realm.allocator, "message", Value.fromString(msg_str), .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        }) catch return error.OutOfMemory;
    }

    // §20.5.7.1.1 step 4 — IteratorToList(GetIterator(errors)).
    // A non-iterable here MUST throw — `new AggregateError({})` is
    // a TypeError, not a silent zero-element instance. Likewise a
    // non-callable `[Symbol.iterator]` returned by an accessor is a
    // TypeError per GetMethod.
    const errors_v = if (args.len > 0) args[0] else Value.undefined_;
    const errors_arr = aggregateErrorMaterialiseErrors(realm, errors_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    // `errors` is an own data property with {w:true, e:false, c:true}
    // per §20.5.7.1.1 step 6 (CreateNonEnumerableDataPropertyOrThrow).
    instance.setWithFlags(realm.allocator, "errors", errors_arr, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    // §20.5.8.1 InstallErrorCause — third arg is an options object;
    // mirrors the Error constructor: HasProperty (proxy-trap aware) +
    // Get (accessor-aware).
    if (args.len > 2) {
        if (heap_mod.valueAsPlainObject(args[2])) |opts| {
            const has_cause = errorOptionsHasCause(realm, opts) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            if (has_cause) {
                const cause_v = try intrinsics.getPropertyChain(realm, opts, "cause");
                instance.setWithFlags(realm.allocator, "cause", cause_v, .{
                    .writable = true,
                    .enumerable = false,
                    .configurable = true,
                }) catch return error.OutOfMemory;
            }
        }
    }
    return heap_mod.taggedObject(instance);
}

/// Walk `errors_v` per §20.5.7.1.1 step 4 (IteratorToList) and
/// build a fresh Array. Accepts iterables (objects with a callable
/// `@@iterator`) and array-likes (`length` + indexed get). Throws
/// `TypeError` on non-object input.
fn aggregateErrorMaterialiseErrors(realm: *Realm, errors_v: Value) NativeError!Value {
    const lantern = @import("../lantern.zig");
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;

    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const src = heap_mod.valueAsPlainObject(errors_v) orelse {
        return intrinsics.throwTypeError(realm, "AggregateError: errors argument is not iterable");
    };

    // §7.4.6 GetMethod(errors, @@iterator). Accessor-aware
    // (`getPropertyChain` fires the getter, so a `get [Symbol.iterator]`
    // throw propagates). If the read returns something non-callable
    // AND non-nullish, §7.3.10 step 3 throws TypeError.
    const iter_method_v = try intrinsics.getPropertyChain(realm, src, "@@iterator");
    if (!iter_method_v.isUndefined() and !iter_method_v.isNull() and
        heap_mod.valueAsFunction(iter_method_v) == null)
    {
        return intrinsics.throwTypeError(realm, "AggregateError: @@iterator is not callable");
    }
    if (heap_mod.valueAsFunction(iter_method_v)) |iter_method| {
        const iter_outcome = lantern.callJSFunction(realm.allocator, realm, iter_method, errors_v, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const iter = switch (iter_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return intrinsics.throwTypeError(realm, "AggregateError: @@iterator did not return an object");
        const next_v = try intrinsics.getPropertyChain(realm, iter_obj, "next");
        const next_fn = heap_mod.valueAsFunction(next_v) orelse return intrinsics.throwTypeError(realm, "AggregateError: iterator missing callable 'next'");
        var k: i64 = 0;
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            const result_outcome = lantern.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            const result = switch (result_outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
            const result_obj = heap_mod.valueAsPlainObject(result) orelse return intrinsics.throwTypeError(realm, "AggregateError: iterator next() did not return an object");
            // §7.4.7 — IteratorComplete / IteratorValue invoke
            // accessor descriptors on `done` / `value`.
            if (intrinsics.toBoolean(try intrinsics.getPropertyChain(realm, result_obj, "done"))) break;
            const elem = try intrinsics.getPropertyChain(realm, result_obj, "value");
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), elem) catch return error.OutOfMemory;
            k += 1;
        }
        @import("array.zig").setLength(realm, out, k) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // Array-like fallback.
    const len = try intrinsics.clampArrayLength(try intrinsics.toLengthOf(realm, src));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try intrinsics.getPropertyChain(realm, src, islice);
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.flatBytes(), elem) catch return error.OutOfMemory;
    }
    @import("array.zig").setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

pub fn installError(
    realm: *Realm,
    name: []const u8,
    native: NativeFn,
    parent_proto: *JSObject,
) !*JSFunction {
    const fn_obj = try realm.heap.allocateFunctionNative(native, 1, name);
    // The auto-allocated prototype was given.constructor by
    // allocateFunctionNative-equivalent paths in non-native
    // allocateFunction; native fns don't get a prototype unless
    // we set one explicitly here.
    const proto = try realm.heap.allocateObject();
    proto.prototype = parent_proto;
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    const name_str = try realm.heap.allocateString(name);
    try setNonEnumerable(proto, realm.allocator, "name", Value.fromString(name_str));
    fn_obj.prototype = proto;
    // §20.5.5.1 / §20.5.6.2.1 — Error.prototype and
    // NativeError.prototype are `{ writable: false, enumerable:
    // false, configurable: false }`. `JSFunction.flagsForOwn`
    // defaults to `{w:true, e:false, c:false}` for non-class
    // constructors; install an override so test262 sees the
    // spec-mandated frozen shape.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    try realm.globals.put(realm.allocator, name, heap_mod.taggedFunction(fn_obj));
    return fn_obj;
}

// ── Native constructor bodies ───────────────────────────────────────────────
//
// Each `<Type>ErrorNative` is the function body invoked by `new <Type>(msg)`.
// On a plain (non-`new`) call, no `this` is bound — for that case we
// allocate the instance ourselves. Spec-correct semantics distinguish
// `new` from plain call, but for the harness's purposes both shapes need
// to produce an Error-shaped object. Without a way to detect which
// invocation form we're in (would need NewTarget plumbing), we always
// allocate a fresh instance and return it. §13.3.5.1.1 ConstructResult
// will let an explicit object return win when used with `new`.

fn errorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.error_prototype.?, args);
}

fn typeErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.type_error_prototype.?, args);
}

fn rangeErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.range_error_prototype.?, args);
}

fn referenceErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.reference_error_prototype.?, args);
}

fn syntaxErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.syntax_error_prototype.?, args);
}

fn uriErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.uri_error_prototype.?, args);
}

fn evalErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return constructErrorInstance(realm, this_value, realm.intrinsics.eval_error_prototype.?, args);
}

/// §20.5.6.3.2 — initial value of `<NativeError>.prototype.message`
/// is the empty string with `{w:true, e:false, c:true}`. Same shape
/// for `Error.prototype.message`.
fn installPrototypeMessage(realm: *Realm, proto: *JSObject) !void {
    const empty = try realm.heap.allocateString("");
    try setNonEnumerable(proto, realm.allocator, "message", Value.fromString(empty));
}

/// §20.5.3.4 Error.prototype.toString:
/// 1. Let O be the this value.
/// 2. If Type(O) is not Object, throw TypeError.
/// 3. Let name be ? Get(O, "name"); default to "Error" if undefined.
/// 4. Let msg be ? Get(O, "message"); default to "" if undefined.
/// 5. If name === "" return msg.
/// §20.5.2.1 Error.isError(arg) — ES2025. Returns true iff arg
/// is an Object with an `[[ErrorData]]` internal slot. The
/// brand check is on the slot, not the prototype chain — a
/// user-built `{ __proto__: Error.prototype }` impostor with no
/// `[[ErrorData]]` returns `false` (test262
/// `built-ins/Error/isError/fake-errors.js`).
fn errorIsError(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.false_;
    return Value.fromBool(obj.has_error_data);
}

/// 6. If msg === "" return name.
/// 7. Return name + ": " + msg.
fn errorPrototypeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        return intrinsics.throwTypeError(realm, "Error.prototype.toString called on non-object");
    };

    const name_v = try intrinsics.getPropertyChain(realm, obj, "name");
    const name_str: *JSString = blk: {
        if (name_v.isUndefined()) {
            break :blk realm.heap.allocateString("Error") catch return error.OutOfMemory;
        }
        break :blk try stringifyArg(realm, name_v);
    };

    const msg_v = try intrinsics.getPropertyChain(realm, obj, "message");
    const msg_str: *JSString = blk: {
        if (msg_v.isUndefined()) {
            break :blk realm.heap.allocateString("") catch return error.OutOfMemory;
        }
        break :blk try stringifyArg(realm, msg_v);
    };

    if (name_str.byte_len == 0) return Value.fromString(msg_str);
    if (msg_str.byte_len == 0) return Value.fromString(name_str);

    const joined = std.fmt.allocPrint(realm.allocator, "{s}: {s}", .{ name_str.flatBytes(), msg_str.flatBytes() }) catch return error.OutOfMemory;
    defer realm.allocator.free(joined);
    const out = realm.heap.allocateString(joined) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn constructErrorInstance(realm: *Realm, this_value: Value, proto: *JSObject, args: []const Value) NativeError!Value {
    // §20.5.1.1 Error / NativeError — when called via `new`
    // (including via `super(...)` from a derived class), the
    // engine has already allocated `this_value` as an object
    // whose `[[Prototype]]` is the right `<X>Error.prototype`.
    // Initialise that instance in-place so user subclassing
    // (e.g. `class CustomError extends Error {}`) sees the
    // message land on the right object. When `this_value`
    // isn't an object — `Error()` called as a function — fall
    // back to allocating fresh with the default prototype.
    const instance = if (heap_mod.valueAsPlainObject(this_value)) |o| o else blk: {
        const fresh = realm.heap.allocateObject() catch return error.OutOfMemory;
        fresh.prototype = proto;
        break :blk fresh;
    };
    // §20.5.1.1 step 3 — install [[ErrorData]] slot so
    // Object.prototype.toString picks the "Error" tag (and so
    // user-facing IsError-style introspection can distinguish a
    // real instance from `Error.prototype`).
    instance.has_error_data = true;
    // §20.5.1.1 step 4 — DefinePropertyOrThrow with descriptor
    // `{[[Value]]: msg, [[Writable]]: true, [[Enumerable]]: false,
    //  [[Configurable]]: true}`.
    if (args.len > 0 and !args[0].isUndefined()) {
        // `stringifyArg` can throw TypeError for Symbol arguments
        // (§7.1.17 ToString step 2); that throw must propagate as
        // a real JS exception, not be swallowed as OutOfMemory.
        const msg_str = try stringifyArg(realm, args[0]);
        instance.setWithFlags(realm.allocator, "message", Value.fromString(msg_str), .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        }) catch return error.OutOfMemory;
    }
    // §20.5.8.1 InstallErrorCause — ES2022 `error-cause`.
    //   1. If options is Object AND ? HasProperty(options, "cause") then
    //   2.   cause = ? Get(options, "cause")
    //   3.   CreateNonEnumerableDataPropertyOrThrow(O, "cause", cause)
    // HasProperty walks the prototype chain AND fires Proxy `has`
    // traps; Get fires accessor getters. A bare `opts.hasOwn` would
    // miss both (`cause_abrupt.js` exercises a Proxy with a `has`
    // trap that throws; `constructor.js` checks ordering — `cause`
    // is accessed after ToString(message)).
    if (args.len > 1) {
        if (heap_mod.valueAsPlainObject(args[1])) |opts| {
            const has_cause = errorOptionsHasCause(realm, opts) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            if (has_cause) {
                const cause_v = try intrinsics.getPropertyChain(realm, opts, "cause");
                instance.setWithFlags(realm.allocator, "cause", cause_v, .{
                    .writable = true,
                    .enumerable = false,
                    .configurable = true,
                }) catch return error.OutOfMemory;
            }
        }
    }
    return heap_mod.taggedObject(instance);
}

/// §7.3.11 HasProperty on the error-cause options object. Walks
/// proxy `has` traps then falls through to OrdinaryHasProperty.
fn errorOptionsHasCause(realm: *Realm, opts: *JSObject) NativeError!bool {
    const proxy_mod = @import("proxy.zig");
    var cur = opts;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyHas(realm, cur, "cause");
        switch (r) {
            .boolean => |b| return b,
            .fallthrough => |t| {
                if (t == cur) return cur.hasProperty("cause");
                cur = t;
            },
        }
    }
    return cur.hasProperty("cause");
}

/// `ToString` for the message argument of an Error constructor.
/// Matches §20.5.1.1 step 3 — when `message` is not undefined,
/// coerce it to a string. We accept primitives directly; objects
/// would normally `[Symbol.toPrimitive]` / `.toString` chain, but
/// we don't have that yet, so they stringify as `[object Object]`
/// Build a fresh `TypeError` instance with `message`. Used by the
/// interpreter's exception path so user code that catches a
/// runtime-emitted error sees a real `TypeError` (with `.message`
/// and `.constructor`) rather than a bare string.
pub fn newTypeError(realm: *Realm, message: []const u8) !Value {
    const proto = realm.intrinsics.type_error_prototype orelse return makeStringFallback(realm, message);
    return makeError(realm, proto, message);
}

pub fn newRangeError(realm: *Realm, message: []const u8) !Value {
    const proto = realm.intrinsics.range_error_prototype orelse return makeStringFallback(realm, message);
    return makeError(realm, proto, message);
}

pub fn newReferenceError(realm: *Realm, message: []const u8) !Value {
    const proto = realm.intrinsics.reference_error_prototype orelse return makeStringFallback(realm, message);
    return makeError(realm, proto, message);
}

pub fn newSyntaxError(realm: *Realm, message: []const u8) !Value {
    const proto = realm.intrinsics.syntax_error_prototype orelse return makeStringFallback(realm, message);
    return makeError(realm, proto, message);
}

pub fn newURIError(realm: *Realm, message: []const u8) !Value {
    const proto = realm.intrinsics.uri_error_prototype orelse return makeStringFallback(realm, message);
    return makeError(realm, proto, message);
}

fn makeError(realm: *Realm, proto: *JSObject, message: []const u8) !Value {
    const instance = try realm.heap.allocateObject();
    instance.prototype = proto;
    instance.has_error_data = true;
    const msg_str = try realm.heap.allocateString(message);
    try instance.set(realm.allocator, "message", Value.fromString(msg_str));
    return heap_mod.taggedObject(instance);
}

/// Last-resort fallback when intrinsics aren't installed (test
/// harness paths that build a Realm directly without
/// `installBuiltins`). Emits a JSString carrying the message —
/// matches the later–later behaviour.
fn makeStringFallback(realm: *Realm, message: []const u8) !Value {
    const s = try realm.heap.allocateString(message);
    return Value.fromString(s);
}
