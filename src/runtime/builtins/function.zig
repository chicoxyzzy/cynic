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

/// Wire `Function.prototype.{call, apply, bind}` onto the
/// realm's `%Function.prototype%`.
pub fn installPrototypeMethods(realm: *Realm) !void {
    const fn_proto = realm.intrinsics.function_prototype orelse return;
    try installNativeMethodOnProto(realm, fn_proto, "call", functionCall, 1);
    try installNativeMethodOnProto(realm, fn_proto, "apply", functionApply, 2);
    try installNativeMethodOnProto(realm, fn_proto, "bind", functionBind, 1);
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
    const fn_obj = heap_mod.valueAsFunction(this_value) orelse return error.NativeThrew;
    const this_arg = argOr(args, 0, Value.undefined_);
    const rest: []const Value = if (args.len > 1) args[1..] else &.{};

    const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, this_arg, rest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| return v,
        .thrown => {
            // The reentrant session threw — surface that to the
            // outer interpreter as a native throw. later: a
            // dedicated `realm.pending_throw` slot would let us
            // forward the actual exception value verbatim.
            return error.NativeThrew;
        },
    }
}

fn functionApply(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const fn_obj = heap_mod.valueAsFunction(this_value) orelse return error.NativeThrew;
    const this_arg = argOr(args, 0, Value.undefined_);
    var apply_args: std.ArrayListUnmanaged(Value) = .empty;
    defer apply_args.deinit(realm.allocator);
    if (args.len > 1) {
        const arg_array = args[1];
        if (arg_array.isUndefined() or arg_array.isNull()) {
            // No extra args.
        } else if (heap_mod.valueAsPlainObject(arg_array)) |arr| {
            const len = try clampArrayLength(lengthOfArray(arr));
            var i: i64 = 0;
            while (i < len) : (i += 1) {
                var ibuf: [24]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                apply_args.append(realm.allocator, arr.get(islice)) catch return error.OutOfMemory;
            }
        } else {
            // §20.2.3.1 step 6 — non-object, non-null/undefined
            // is a TypeError.
            return error.NativeThrew;
        }
    }


    const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, this_arg, apply_args.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| return v,
        .thrown => return error.NativeThrew,
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

    // The bound function carries no chunk; call sites detect
    // `bound_target` and route through that.
    const bound = realm.heap.allocateFunctionNative(boundFunctionTrampoline, 0, "bound") catch return error.OutOfMemory;
    bound.proto = realm.intrinsics.function_prototype;
    bound.bound_target = target;
    bound.bound_this = bound_this;
    bound.bound_args = owned_args;
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

fn installVariantCtor(realm: *Realm, name: []const u8) !*JSObject {
    const fn_obj = try realm.heap.allocateFunctionNative(variantCtorThrows, 1, name);
    fn_obj.proto = realm.intrinsics.function_prototype;
    const proto = try realm.heap.allocateObject();
    // §27.3 — these prototypes inherit from %Function.prototype%
    // (NOT %Object.prototype%) so e.g. `bind` / `call` resolve.
    proto.prototype = realm.intrinsics.function_prototype;
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
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

