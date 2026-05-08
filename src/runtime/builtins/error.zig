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

    realm.intrinsics.range_error_constructor = try installError(realm, "RangeError", rangeErrorNative, error_proto);
    realm.intrinsics.range_error_prototype = realm.intrinsics.range_error_constructor.?.prototype;

    realm.intrinsics.reference_error_constructor = try installError(realm, "ReferenceError", referenceErrorNative, error_proto);
    realm.intrinsics.reference_error_prototype = realm.intrinsics.reference_error_constructor.?.prototype;

    realm.intrinsics.syntax_error_constructor = try installError(realm, "SyntaxError", syntaxErrorNative, error_proto);
    realm.intrinsics.syntax_error_prototype = realm.intrinsics.syntax_error_constructor.?.prototype;

    realm.intrinsics.uri_error_constructor = try installError(realm, "URIError", uriErrorNative, error_proto);
    realm.intrinsics.uri_error_prototype = realm.intrinsics.uri_error_constructor.?.prototype;
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
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.error_prototype.?, args);
}

fn typeErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.type_error_prototype.?, args);
}

fn rangeErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.range_error_prototype.?, args);
}

fn referenceErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.reference_error_prototype.?, args);
}

fn syntaxErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.syntax_error_prototype.?, args);
}

fn uriErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return constructErrorInstance(realm, realm.intrinsics.uri_error_prototype.?, args);
}

fn constructErrorInstance(realm: *Realm, proto: *JSObject, args: []const Value) NativeError!Value {
    const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
    instance.prototype = proto;
    if (args.len > 0 and !args[0].isUndefined()) {
        const msg_str = stringifyArg(realm, args[0]) catch return error.OutOfMemory;
        instance.set(realm.allocator, "message", Value.fromString(msg_str)) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(instance);
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

