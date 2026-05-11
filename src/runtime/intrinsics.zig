//! Realm intrinsics — the built-in constructor / prototype objects.
//!
//! ECMA-262 §6.1.7.4 calls these "well-known intrinsics". We
//! install a minimum useful set at realm startup; runtime
//! code (`makeTypeError`, the assert harness, user `throw new
//! TypeError(...)`) reaches into the realm to find the prototype
//! it needs, allocates a fresh `JSObject` with that proto, and
//! returns it. Keeping the intrinsics on a struct (rather than
//! looking them up by name in `realm.globals` every time) lets
//! the interpreter avoid string lookups on the hot exception
//! path.
//!
//! Spec-faithful naming where we can: `error_prototype`,
//! `type_error_prototype`, etc. mirror %Error.prototype% /
//! %TypeError.prototype% in §20.5.
//!
//! later floor:
//! • Error, TypeError, RangeError, ReferenceError, SyntaxError
//! constructors and prototypes wired through the prototype
//! chain (TypeError.prototype.__proto__ === Error.prototype).
//! • Object.prototype, plus Object.{keys, hasOwn, getPrototypeOf}.
//! • Array.prototype with the most-used methods.
//! • Function.prototype with.call /.apply /.bind.
//!
//! Out of scope (deferred to later / later):
//! • Symbol, BigInt, Map / Set / WeakMap / WeakSet, Promise,
//! Proxy, Reflect, Date, RegExp, ArrayBuffer / TypedArray.
//! • Full IteratorPrototype + iterator protocol wiring.

const std = @import("std");

const Value = @import("value.zig").Value;
const JSFunction = @import("function.zig").JSFunction;
const NativeFn = @import("function.zig").NativeFn;
const NativeError = @import("function.zig").NativeError;
const JSObject = @import("object.zig").JSObject;
const JSString = @import("string.zig").JSString;
const ObjMod = @import("object.zig"); // for `MapData` / `SetData` create + `TypedKind` references that survive in TypedArray re-exports
const heap_mod = @import("heap.zig");
const Realm = @import("realm.zig").Realm;

/// Holds heap-pointer references to the Realm's intrinsic
/// constructors and prototype objects. Populated by
/// `Realm.installBuiltins`. Pointers are non-owning — the heap
/// owns the underlying objects.
pub const Intrinsics = struct {
    object_prototype: ?*JSObject = null,
    function_prototype: ?*JSObject = null,
    array_prototype: ?*JSObject = null,
    string_prototype: ?*JSObject = null,

    error_constructor: ?*JSFunction = null,
    error_prototype: ?*JSObject = null,
    type_error_constructor: ?*JSFunction = null,
    type_error_prototype: ?*JSObject = null,
    range_error_constructor: ?*JSFunction = null,
    range_error_prototype: ?*JSObject = null,
    reference_error_constructor: ?*JSFunction = null,
    reference_error_prototype: ?*JSObject = null,
    syntax_error_constructor: ?*JSFunction = null,
    syntax_error_prototype: ?*JSObject = null,
    uri_error_constructor: ?*JSFunction = null,
    uri_error_prototype: ?*JSObject = null,
    eval_error_constructor: ?*JSFunction = null,
    eval_error_prototype: ?*JSObject = null,
    /// §20.5.7 AggregateError — Error subclass with an `errors`
    /// own property. Constructed by `Promise.any` when every
    /// input rejects; user code can also `new AggregateError([…])`.
    aggregate_error_constructor: ?*JSFunction = null,
    aggregate_error_prototype: ?*JSObject = null,

    /// `%GeneratorPrototype%` (§27.5.1). Lazily installed on the
    /// first `function*` call by `interpreter.ensureGeneratorPrototype`;
    /// `null` until then. Carries `next` / `return` / `throw` and
    /// the well-known iterator dispatcher under `"@@iterator"`.
    generator_prototype: ?*JSObject = null,

    /// `%AsyncGeneratorPrototype%` (§27.6.1) — same shape as
    /// `generator_prototype` but `next` / `return` / `throw`
    /// wrap their `{value, done}` (or thrown) result in a fresh
    /// Promise. Lazily installed on first `async function*`
    /// invocation.
    async_generator_prototype: ?*JSObject = null,

    /// `%PromisePrototype%` — installed by `installPromise` so
    /// instances of the realm's `Promise` constructor share one
    /// proto. later still resolves synchronously through the
    /// microtask queue; the prototype carries `.then` / `.catch`
    /// / `.finally`.
    promise_prototype: ?*JSObject = null,
    /// `%GeneratorFunction.prototype%` — JSFunction objects with
    /// `is_generator=true` (and not `is_async`) get this as
    /// their `.proto`. `Object.getPrototypeOf(function*(){}).constructor`
    /// is `GeneratorFunction`.
    generator_function_prototype: ?*JSObject = null,
    /// `%AsyncFunction.prototype%` — `is_async` non-generator
    /// functions get this proto.
    async_function_prototype: ?*JSObject = null,
    /// `%AsyncGeneratorFunction.prototype%` — both `is_generator`
    /// and `is_async`.
    async_generator_function_prototype: ?*JSObject = null,
    /// `%TypedArray%` (§23.2.1) — the abstract intrinsic
    /// constructor that `Int8Array` / `Uint8Array` / … inherit
    /// from. test262 fixtures reach it via
    /// `Object.getPrototypeOf(Int8Array)`.
    typed_array_constructor: ?*JSFunction = null,
    /// `%TypedArray%.prototype` (§23.2.3) — carries the shared
    /// method set (`map`, `filter`, `reduce`, `set`, `subarray`,
    /// `slice`, `every`, `some`, `find`, etc.). Each concrete
    /// `<Kind>Array.prototype` chains here.
    typed_array_prototype: ?*JSObject = null,
    /// `%RegExp.prototype%` — populated by `installRegExp`. The
    /// flag/source getters need to recognise it as a special
    /// receiver: `RegExp.prototype.source === "(?:)"` per
    /// §22.2.6.10 final clause, even though the prototype itself
    /// has no `[[OriginalSource]]` internal slot.
    regexp_prototype: ?*JSObject = null,
    /// `%Set.prototype%` — populated by `installSet`. The ES2025
    /// composition methods (`union`, `intersection`, …) need it
    /// to wire the prototype of fresh result sets they allocate
    /// outside the constructor flow.
    set_prototype: ?*JSObject = null,

    /// `%MapIteratorPrototype%` (§24.1.5.2). Shared prototype of
    /// every Map-iterator instance returned by `Map.prototype.{entries,
    /// keys, values}` and `Map.prototype[@@iterator]`. Carries
    /// `next`, `@@iterator`, and `Symbol.toStringTag = "Map Iterator"`.
    map_iterator_prototype: ?*JSObject = null,
    /// `%SetIteratorPrototype%` (§24.2.5.2). Shared prototype of
    /// every Set-iterator instance returned by `Set.prototype.{values,
    /// keys, entries}` and `Set.prototype[@@iterator]`. Carries
    /// `next`, `@@iterator`, and `Symbol.toStringTag = "Set Iterator"`.
    set_iterator_prototype: ?*JSObject = null,

    /// `%RegExpStringIteratorPrototype%` (§22.2.9.2). Shared
    /// prototype for the iterator returned by
    /// `String.prototype.matchAll` / `RegExp.prototype[@@matchAll]`.
    /// Carries `next`, `@@iterator`, and `@@toStringTag =
    /// "RegExp String Iterator"`.
    regexp_string_iterator_prototype: ?*JSObject = null,

    /// `%ThrowTypeError%` (§10.2.4). The unique anonymous, frozen,
    /// length-0 native that throws TypeError when called. Reused
    /// as the [[Get]] / [[Set]] of the strict-arguments `callee`
    /// accessor (§10.4.4.7 step 5). Stored on the realm so every
    /// strict-mode `arguments` object shares one identity.
    throw_type_error: ?*JSFunction = null,
};

/// Install the later intrinsics on `realm`. Wires the constructor
/// / prototype objects, exposes them as globals (`Error`, `TypeError`,
/// …), and stores pointers on `realm.intrinsics` for the runtime
/// to look up.
pub fn install(realm: *Realm) !void {
    // Error and the four typed subclasses share a small builder.
    // Each one creates:
    // - A constructor function (native callback that sets.message
    // on the freshly allocated `this`).
    // - A prototype object whose.constructor points back, and
    // whose.__proto__ inherits from Error.prototype (for
    // subclasses) or Object.prototype (for Error itself).
    // - A.name property on the prototype matching the constructor
    // name (`"TypeError"`, etc.) so `e.name` reads correctly
    // through the prototype chain.

    const obj_proto = try realm.heap.allocateObject();
    realm.intrinsics.object_prototype = obj_proto;

    // §20.5 Error + the four typed subclasses live in `builtins/error.zig`.
    try @import("builtins/error.zig").installAll(realm, obj_proto);

    // Stub-install the most-referenced built-in constructors so
    // unbound references don't raise ReferenceError. These don't
    // do anything yet — `new Array(3)` won't produce a real array
    // — but they exist as objects with prototypes, which is enough
    // for many test262 tests to exercise their actual subject.
    // later fleshes them out.
    realm.intrinsics.array_prototype = try installStubConstructor(
        realm,
        "Array",
        obj_proto,
    );
    realm.intrinsics.string_prototype = try installStubConstructor(
        realm,
        "String",
        obj_proto,
    );
    _ = try installStubConstructor(realm, "Number", obj_proto);
    _ = try installStubConstructor(realm, "Boolean", obj_proto);
    // The Object constructor's `.prototype` slot must alias
    // `obj_proto` itself so `Object.prototype === Object.getPrototypeOf({})`
    // (§20.1.3 — %Object.prototype% is the global object prototype).
    try installCtorReusingProto(realm, "Object", obj_proto);
    realm.intrinsics.function_prototype = try installStubConstructor(
        realm,
        "Function",
        obj_proto,
    );

    // Function.prototype.call /.apply /.bind
    try @import("builtins/function.zig").installPrototypeMethods(realm);

    // §10.2.4 %ThrowTypeError% — the unique anonymous, frozen,
    // length-0 function used as the [[Get]] / [[Set]] of strict
    // `arguments.callee` (§10.4.4.7 step 5). Install once per
    // realm; pin on `realm.intrinsics.throw_type_error` so the
    // `lda_arguments` opcode can wire the same function into
    // every strict-mode arguments object.
    {
        const t = try realm.heap.allocateFunctionNative(throwTypeErrorThrower, 0, "");
        t.proto = realm.intrinsics.function_prototype;
        t.has_construct = false;
        // §10.2.4 — non-extensible. `length` and `name` are
        // already non-writable / non-configurable per §17 (set in
        // `installFunctionLengthAndName`); but the spec requires
        // `configurable: false` for both on %ThrowTypeError%, so
        // override the default `configurable: true`.
        const frozen_flags: @import("object.zig").PropertyFlags = .{
            .writable = false, .enumerable = false, .configurable = false,
        };
        try t.property_flags.put(realm.allocator, "length", frozen_flags);
        try t.property_flags.put(realm.allocator, "name", frozen_flags);
        // `extensible` for JSFunction isn't a heap-side flag yet —
        // `Object.isExtensible(fn)` already returns false because
        // `valueAsPlainObject` rejects functions (§10.2.4 alignment
        // is incidental but matches the spec for now).
        realm.intrinsics.throw_type_error = t;

        // §10.2.4 — Function.prototype.arguments and
        // Function.prototype.caller are accessor properties whose
        // [[Get]] and [[Set]] are both %ThrowTypeError%. test262
        // `built-ins/ThrowTypeError/unique-per-realm-function-proto`
        // verifies the same singleton lands in both descriptors.
        if (realm.intrinsics.function_prototype) |fn_proto| {
            const a_entry = fn_proto.accessors.getOrPut(realm.allocator, "arguments") catch return error.OutOfMemory;
            a_entry.value_ptr.* = .{ .getter = t, .setter = t };
            try fn_proto.property_flags.put(realm.allocator, "arguments", .{
                .writable = false, .enumerable = false, .configurable = true,
            });
            const c_entry = fn_proto.accessors.getOrPut(realm.allocator, "caller") catch return error.OutOfMemory;
            c_entry.value_ptr.* = .{ .getter = t, .setter = t };
            try fn_proto.property_flags.put(realm.allocator, "caller", .{
                .writable = false, .enumerable = false, .configurable = true,
            });
        }
    }

    // Object statics + Object.prototype methods.
    try @import("builtins/object.zig").install(realm);

    // Array.prototype methods + Array statics (all in builtins/array.zig).
    try @import("builtins/array.zig").install(realm);

    // Math object — common static methods only.
    try @import("builtins/math.zig").install(realm);

    // Number / Boolean / String coercion globals (replace the stubs
    // with proper native bodies). The `Array` global stays as a
    // stub for now — `new Array(n)` ergonomics is later.
    try replaceGlobalNative(realm, "String", stringConstructor);
    try replaceGlobalNative(realm, "Number", numberConstructor);
    try replaceGlobalNative(realm, "Boolean", booleanConstructor);

    // §20.3.3 — `%Boolean.prototype%` is itself a Boolean
    // with `[[BooleanData]]: false`. `Boolean.prototype.toString()` /
    // `.valueOf()` calls directly on the prototype unbox it.
    if (heap_mod.valueAsFunction(realm.globals.get("Boolean").?)) |bool_ctor| {
        if (bool_ctor.prototype) |bp| {
            bp.boxed_primitive = Value.false_;
            // §20.3.3.2 / §20.3.3.3 — install `valueOf` and
            // `toString` on `Boolean.prototype`. Without these,
            // `new Boolean(false) - 1` falls through to the
            // inherited `Object.prototype.valueOf` (returns the
            // wrapper, still an object), then to
            // `Object.prototype.toString` ("[object Boolean]"),
            // and finally ToNumber → NaN.
            try installNativeMethodOnProto(realm, bp, "valueOf", booleanProtoValueOf, 0);
            try installNativeMethodOnProto(realm, bp, "toString", booleanProtoToString, 0);
        }
    }

    // String.prototype methods all live in builtins/string.zig.
    try @import("builtins/string.zig").install(realm);
    if (realm.intrinsics.string_prototype) |sp| {
        // §22.1.3 — `%String.prototype%` itself has
        // `[[StringData]]: ""`. Calling a String.prototype
        // method directly on the prototype unboxes to "".
        const empty_str = realm.heap.allocateString("") catch return error.OutOfMemory;
        sp.boxed_primitive = Value.fromString(empty_str);
    }

    // Number prototype + statics + parseInt/parseFloat/isNaN/isFinite globals.
    try @import("builtins/number.zig").install(realm);
    // §19.2 URI handling globals.
    try @import("builtins/uri.zig").install(realm);

    // §19.1 — global value properties. NaN / Infinity / undefined
    // are top-level identifiers in JS that any test262 fixture
    // can mention.
    try realm.globals.put(realm.allocator, "NaN", Value.fromDouble(std.math.nan(f64)));
    try realm.globals.put(realm.allocator, "Infinity", Value.fromDouble(std.math.inf(f64)));
    try realm.globals.put(realm.allocator, "undefined", Value.undefined_);

    // §19.3.3 globalThis — references the global object. We
    // synthesise a plain object exposing the realm's globals so
    // `globalThis.X` reads work the same as `X`. Two-way live
    // binding is later.
    //
    // §17 — built-in globals install with `{ writable: true,
    // enumerable: false, configurable: true }` (the standard
    // built-in objects clause). The few §19.1 read-only globals
    // (`undefined`, `NaN`, `Infinity`) are non-writable /
    // non-configurable; they're patched up after the bulk fill.
    {
        const gt = try realm.heap.allocateObject();
        gt.prototype = realm.intrinsics.object_prototype;
        var it = realm.globals.iterator();
        while (it.next()) |entry| {
            try gt.setWithFlags(realm.allocator, entry.key_ptr.*, entry.value_ptr.*, .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            });
        }
        // §19.1 — `undefined`, `NaN`, `Infinity` are
        // `{ w:false, e:false, c:false }`.
        for ([_][]const u8{ "undefined", "NaN", "Infinity" }) |k| {
            if (gt.properties.contains(k)) {
                try gt.property_flags.put(realm.allocator, k, .{
                    .writable = false,
                    .enumerable = false,
                    .configurable = false,
                });
            }
        }
        try gt.setWithFlags(realm.allocator, "globalThis", heap_mod.taggedObject(gt), .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        });
        try realm.globals.put(realm.allocator, "globalThis", heap_mod.taggedObject(gt));
    }

    // Number static value properties.
    if (heap_mod.valueAsFunction(realm.globals.get("Number").?)) |num_ctor| {
        try num_ctor.set(realm.allocator, "NaN", Value.fromDouble(std.math.nan(f64)));
        try num_ctor.set(realm.allocator, "POSITIVE_INFINITY", Value.fromDouble(std.math.inf(f64)));
        try num_ctor.set(realm.allocator, "NEGATIVE_INFINITY", Value.fromDouble(-std.math.inf(f64)));
        try num_ctor.set(realm.allocator, "MAX_SAFE_INTEGER", Value.fromDouble(9007199254740991.0));
        try num_ctor.set(realm.allocator, "MIN_SAFE_INTEGER", Value.fromDouble(-9007199254740991.0));
        try num_ctor.set(realm.allocator, "MAX_VALUE", Value.fromDouble(std.math.floatMax(f64)));
        try num_ctor.set(realm.allocator, "MIN_VALUE", Value.fromDouble(5e-324));
        try num_ctor.set(realm.allocator, "EPSILON", Value.fromDouble(std.math.floatEps(f64)));
    }

    // Array.prototype + Array statics already installed earlier
    // by `builtins/array.zig`. Removing the duplicate would have
    // shadowed the new bindings — keeping the single delegated
    // `install(realm)` call above is sufficient.

    // §22.1.3 — String iterators. `String.prototype[@@iterator]`
    // returns an iterator that yields each character. Cynic
    // walks by ASCII byte; surrogate-pair fidelity is later.
    if (realm.intrinsics.string_prototype) |sp_iter_install| {
        const collections = @import("builtins/collections.zig");
        try installNativeMethodOnProto(realm, sp_iter_install, "@@iterator", collections.stringIteratorMethod, 0);
    }

    // (split/replace/etc. are wired by builtins/string.zig
    // earlier in this function.)

    // Map / Set / Date — proper constructors with their own
    // prototype objects and method surfaces.
    {
        const collections = @import("builtins/collections.zig");
        try collections.installMap(realm);
        try collections.installSet(realm);
        try collections.installWeakMap(realm);
        try collections.installWeakSet(realm);
    }
    // §26.2 FinalizationRegistry — strong-ref impl (matches
    // WeakMap/WeakSet); cleanup callback never fires today,
    // which the spec explicitly permits.
    try @import("builtins/finalization_registry.zig").install(realm);
    try @import("builtins/date.zig").install(realm);
    try @import("builtins/reflect.zig").install(realm);
    try @import("builtins/symbol.zig").install(realm);
    try @import("builtins/proxy.zig").install(realm);
    // §26.1 WeakRef — strong-ref impl, mirrors collections.zig.
    try @import("builtins/weak_ref.zig").install(realm);
    try @import("builtins/promise.zig").install(realm);
    try @import("builtins/bigint.zig").install(realm);
    try @import("builtins/typed_array.zig").install(realm);
    try @import("builtins/function.zig").installVariantPrototypes(realm);
    try @import("builtins/regexp.zig").install(realm);
    try @import("builtins/json.zig").install(realm);
    try @import("builtins/iterator.zig").install(realm);
    // Iterator.prototype is now live — wire
    // %GeneratorFunction.prototype.prototype% and %AsyncGeneratorFunction.prototype.prototype%
    // so `Object.getPrototypeOf(function*(){}).prototype` lands
    // on the right object (and its proto chain goes through
    // Iterator.prototype per §27.5.1).
    try @import("builtins/function.zig").wireVariantInstancePrototypes(realm);

    // Final pass — wire every heap-allocated function (including
    // the built-ins we just installed) to %Function.prototype%
    // so inherited `.call`/`.apply`/`.bind` resolve from any fn.
    if (realm.intrinsics.function_prototype) |fn_proto| {
        for (realm.heap.functions.items) |fn_obj| {
            if (fn_obj.proto == null) fn_obj.proto = fn_proto;
        }
    }

    // Re-snapshot the globalThis object to pick up every binding
    // installed after its initial creation (Map/Set/Date/Promise/
    // __drainMicrotasks/etc.). Two-way live binding is later;
    // this catch-up pass is enough for `globalThis.X` reads.
    // §17 spec flags `{ w:true, e:false, c:true }` apply.
    if (heap_mod.valueAsPlainObject(realm.globals.get("globalThis") orelse Value.undefined_)) |gt| {
        var it = realm.globals.iterator();
        while (it.next()) |entry| {
            try gt.setWithFlags(realm.allocator, entry.key_ptr.*, entry.value_ptr.*, .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            });
        }
    }
}

/// Allocate a no-op constructor whose `.prototype` chains to
/// `parent_proto`. Returns the prototype object pointer (so the
/// caller can stash it on `Intrinsics`). Spec correctness is
/// deferred — these are placeholders that move the floor for
/// runtime test262 tests that just reference the global.
fn installStubConstructor(
    realm: *Realm,
    name: []const u8,
    parent_proto: *JSObject,
) !*JSObject {
    // §17 — every spec'd stub built-in (Array, String, Number,
    // Boolean, Function) has `length === 1`.
    const fn_obj = try realm.heap.allocateFunctionNative(stubConstructorNative, 1, name);
    const proto = try realm.heap.allocateObject();
    proto.prototype = parent_proto;
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    const name_str = try realm.heap.allocateString(name);
    try setNonEnumerable(proto, realm.allocator, "name", Value.fromString(name_str));
    fn_obj.prototype = proto;
    try realm.globals.put(realm.allocator, name, heap_mod.taggedFunction(fn_obj));
    return proto;
}

/// Like `installStubConstructor` but reuses an existing proto
/// instead of allocating a fresh one. Used to align
/// `Object.prototype` with the realm-wide object prototype that
/// every plain object chains to.
fn installCtorReusingProto(realm: *Realm, name: []const u8, proto: *JSObject) !void {
    // §20.1.1 — `Object` constructor's `length` is 1.
    const fn_obj = try realm.heap.allocateFunctionNative(stubConstructorNative, 1, name);
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    fn_obj.prototype = proto;
    try realm.globals.put(realm.allocator, name, heap_mod.taggedFunction(fn_obj));
}

fn stubConstructorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    // Plain-call returns undefined; constructor calls (`new`) get
    // the freshly allocated `this` from the interpreter via the
    // ConstructResult rule (§13.3.5.1.1). Fleshing the constructor
    // out — `Array(n)` returning a length-n array, `String(v)`
    // coercing to string — is later.
    return Value.undefined_;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

pub fn installNativeMethod(realm: *Realm, target: *JSFunction, name: []const u8, native: NativeFn, params: u8) !void {
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, name);
    // §17 — these are built-in static methods (e.g. `Object.keys`,
    // `Promise.all`); spec says they don't have `[[Construct]]`
    // unless explicitly identified as constructors.
    fn_obj.has_construct = false;
    // §17 — built-in own data property descriptors are non-
    // enumerable by default. Enumerable methods cause the
    // test262 `prop-desc.js` and `not-a-constructor.js` checks
    // to misclassify the method.
    try target.setWithFlags(realm.allocator, name, heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
}

/// Wire `key` on `proto` to `value` with non-enumerable flags
/// — the spec convention for every property on a built-in
/// prototype (§17 — built-in objects). Used for `constructor`,
/// `name`, prototype-installed accessors, etc.
pub fn setNonEnumerable(proto: *JSObject, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
    try proto.setWithFlags(allocator, key, v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
}

/// §22.1.3.5 Object.prototype.toString consults `@@toStringTag`
/// on the receiver / its prototype chain. Built-in prototypes
/// install their tag with `{w:false, e:false, c:true}` per the
/// well-known-symbol convention. Stored under the synthetic
/// `@@toStringTag` key (later well-known-symbol property
/// identity); user code that does `obj[Symbol.toStringTag]`
/// resolves to the same slot via the same key.
pub fn installToStringTag(realm: *Realm, proto: *JSObject, tag: []const u8) !void {
    const s = try realm.heap.allocateString(tag);
    try proto.setWithFlags(realm.allocator, "@@toStringTag", Value.fromString(s), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
}

/// Per-built-in constructor installation spec. Captures the
/// dimensions that vary across the 11 `install<Builtin>`
/// functions: the constructor body, its arity, whether it's
/// callable-only (BigInt, Symbol) vs. class-constructor (Map,
/// Promise, …), whether the prototype chain gets a `@@toStringTag`
/// override, and whether the constructor is exposed as a global
/// (the abstract `%TypedArray%` is not).
pub const ConstructorSpec = struct {
    name: []const u8,
    ctor: NativeFn,
    arity: u8 = 0,
    /// §15.7.14 [[ConstructorKind]] = "derived" treatment —
    /// `false` for plain functions callable both with and
    /// without `new` (BigInt, Symbol).
    is_class: bool = true,
    /// `[[HomeObject]]` (§10.2.5). Set for class-style
    /// constructors so methods inside the body resolve `super`
    /// against the prototype.
    set_home_object: bool = true,
    /// When set, installs `Symbol.toStringTag = tag` on the
    /// prototype with §17 spec flags.
    to_string_tag: ?[]const u8 = null,
    /// When `false`, the constructor is reachable only via
    /// `realm.intrinsics.*` and not exposed as a global —
    /// matches `%TypedArray%` semantics.
    install_global: bool = true,
};

/// Generic constructor installer. Returns the
/// `JSFunction` + prototype JSObject pair so the caller can
/// install methods, accessors, and statics. Replaces ~10
/// near-identical hand-rolled blocks across `install<Builtin>`.
pub fn installConstructor(realm: *Realm, spec: ConstructorSpec) !struct { ctor: *JSFunction, proto: *JSObject } {
    const fn_obj = try realm.heap.allocateFunctionNative(spec.ctor, spec.arity, spec.name);
    fn_obj.is_class_constructor = spec.is_class;
    fn_obj.proto = realm.intrinsics.function_prototype;
    const proto = try realm.heap.allocateObject();
    proto.prototype = realm.intrinsics.object_prototype;
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    if (spec.to_string_tag) |t| try installToStringTag(realm, proto, t);
    fn_obj.prototype = proto;
    if (spec.set_home_object) fn_obj.home_object = proto;
    if (spec.install_global) try realm.globals.put(realm.allocator, spec.name, heap_mod.taggedFunction(fn_obj));
    return .{ .ctor = fn_obj, .proto = proto };
}

/// Install a §6.2.5.4 accessor descriptor (getter only) on
/// `proto[name]`. The getter inherits `%Function.prototype%`
/// for `.call` / `.apply` / `.bind`. Replaces the
/// allocateFunctionNative + accessors.getOrPut pattern that
/// repeats at every `length` / `byteLength` / `size` /
/// `description` site.
pub fn installNativeGetter(realm: *Realm, proto: *JSObject, name: []const u8, getter_fn: NativeFn) !void {
    const getter = try realm.heap.allocateFunctionNative(getter_fn, 0, name);
    getter.proto = realm.intrinsics.function_prototype;
    const entry = try proto.accessors.getOrPut(realm.allocator, name);
    entry.value_ptr.* = .{ .getter = getter };
    // §17 — built-in accessor properties are { enumerable: false,
    // configurable: true }. `writable` is N/A on accessor descriptors.
    try proto.property_flags.put(realm.allocator, name, .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
}

/// Decimal-format a non-negative integer index into the
/// caller-supplied scratch buffer. Used 40+ times in array-
/// like methods that iterate `obj["0"]`, `obj["1"]`, …
/// Returns the slice of `buf` that's now the digits.
pub fn formatIndex(buf: *[24]u8, i: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable;
}

pub fn installNativeMethodOnProto(realm: *Realm, proto: *JSObject, name: []const u8, native: NativeFn, params: u8) !void {
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, name);
    // §17 — built-in prototype methods are not constructors.
    fn_obj.has_construct = false;
    // §17 — built-in methods install with `enumerable: false`
    // so they don't surface in `for-in` over user objects that
    // inherit from these prototypes. `writable` and
    // `configurable` stay true (default), matching the spec.
    try proto.setWithFlags(realm.allocator, name, heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
}

pub fn argOr(args: []const Value, i: usize, default: Value) Value {
    return if (i < args.len) args[i] else default;
}

/// §23.1.1 ArrayCreate — allocate a fresh Array instance with
/// `[[Prototype]]` = `%Array.prototype%`, `is_array_exotic =
/// true`, and `length = 0` (writable, non-enumerable, non-
/// configurable per §23.1.4). Centralised so every Array-shaped
/// JSObject (literal, builtin result, slice/concat/Array.from
/// output, etc.) goes through one place — one missed flag and
/// `arr[3]` reads come from `properties` instead of `elements`.
pub fn allocateArray(realm: *Realm) !*JSObject {
    const obj = try realm.heap.allocateObject();
    obj.prototype = realm.intrinsics.array_prototype;
    obj.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    obj.is_array_exotic = true;
    try obj.setWithFlags(realm.allocator, "length", Value.fromInt32(0), .{
        .writable = true,
        .enumerable = false,
        .configurable = false,
    });
    return obj;
}

pub fn objectFromThis(this_value: Value) ?*JSObject {
    return heap_mod.valueAsPlainObject(this_value);
}

/// §7.1.18 ToObject — used by every Array / String / Number /
/// Boolean prototype method that accepts a primitive `this`.
/// Boxes primitives into a fresh wrapper object whose prototype
/// is the matching built-in (`%String.prototype%`, etc.) so
/// inherited methods + indexed-access patterns work as if the
/// primitive were a real object. Throws `TypeError` for
/// `null` / `undefined`.
///
/// The wrapper carries the primitive value:
/// • String → `wrapper.properties["length"] = bytes.len`,
/// wrapper.properties["0"], …, ["len-1"] = single-char
/// JSStrings. Lazy materialisation isn't worth it; the
/// iteration paths read every index anyway.
/// • Number / Boolean → no observable own properties; the
/// wrapper's prototype chain handles `toString`, etc.
pub fn toObjectThis(realm: *Realm, this_value: Value) NativeError!*JSObject {
    if (heap_mod.valueAsPlainObject(this_value)) |o| return o;
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeError(realm, "Cannot convert null or undefined to object");
    }
    if (this_value.isString()) {
        const s: *JSString = @ptrCast(@alignCast(this_value.asString()));
        const w = realm.heap.allocateObject() catch return error.OutOfMemory;
        w.prototype = realm.intrinsics.string_prototype;
        w.boxed_string = s;
        // §22.1.4 String exotic — `length` and indexed
        // `[i]` are own non-writable, non-configurable, but
        // we install them as plain entries; tests that
        // inspect descriptors via `Object.getOwnPropertyDescriptor`
        // on a primitive's wrapper are later.
        w.set(realm.allocator, "length", Value.fromInt32(@intCast(s.bytes.len))) catch return error.OutOfMemory;
        var idx: usize = 0;
        while (idx < s.bytes.len) : (idx += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const ch = realm.heap.allocateString(s.bytes[idx .. idx + 1]) catch return error.OutOfMemory;
            const own_key = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            w.set(realm.allocator, own_key.bytes, Value.fromString(ch)) catch return error.OutOfMemory;
        }
        return w;
    }
    if (heap_mod.valueAsFunction(this_value)) |_| {
        // Functions are already objects; the cast back via
        // `valueAsPlainObject` failed because the kind tag is
        // `function`. For Array.prototype.* purposes treat the
        // function as if it were a plain object: allocate a
        // wrapper that proxies length + indexed reads via the
        // function's property bag. Rare path; keep simple.
        const w = realm.heap.allocateObject() catch return error.OutOfMemory;
        w.prototype = realm.intrinsics.object_prototype;
        return w;
    }
    // Number / boolean / symbol / bigint — wrap with no own
    // properties; the wrapper's prototype chain (Number /
    // Boolean / Symbol / BigInt prototype) supplies inherited
    // methods. The wrapper has no `length`, so iterating
    // Array.prototype.* over a wrapped number reads length 0
    // and the loop exits — matching real engines.
    const w = realm.heap.allocateObject() catch return error.OutOfMemory;
    w.prototype = lookupPrimitivePrototype(realm, this_value) orelse realm.intrinsics.object_prototype;
    return w;
}

/// Find the matching `<Kind>.prototype` for a primitive
/// receiver. Returns `null` on miss; caller falls back to
/// `%Object.prototype%`. Walks `realm.globals` because the
/// Number / Boolean / etc. prototypes aren't pinned on
/// `Intrinsics` (only the ones the runtime fast-paths reach).
fn lookupPrimitivePrototype(realm: *Realm, v: Value) ?*JSObject {
    const ctor_name: []const u8 = blk: {
        if (v.isNumber()) break :blk "Number";
        if (v.isBool()) break :blk "Boolean";
        if (heap_mod.isSymbol(v)) break :blk "Symbol";
        if (heap_mod.isBigInt(v)) break :blk "BigInt";
        return null;
    };
    const ctor_v = realm.globals.get(ctor_name) orelse return null;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return null;
    return ctor.prototype;
}

/// §7.3.2 Get(O, P) for native intrinsic methods. Walks the
/// receiver's prototype chain; accessor own properties invoke
/// the getter via `callJSFunction` (the spec's [[Get]] internal
/// method). Falls back to `Value.undefined_` on miss.
///
/// Used by every Array / Object / TypedArray prototype method
/// that reads `length`, indexed elements, or other arbitrary
/// keys — fixtures often define those as accessors with side
/// effects, so the method must invoke them rather than reach
/// directly into the property bag.
///
/// Returns `error.NativeThrew` if a getter throws; the
/// pending exception is recorded on the realm.
pub fn getPropertyChain(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!Value {
    var cur: ?*JSObject = obj;
    while (cur) |o| {
        if (o.accessors.get(key)) |acc| {
            if (acc.getter) |getter| {
                const interpreter = @import("interpreter.zig");
                const outcome = interpreter.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedObject(obj), &[_]Value{}) catch |err| switch (err) {
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
            // Setter-only accessor — read returns undefined.
            return Value.undefined_;
        }
        // §10.4.2 Array exotic — integer-indexed read goes
        // through the packed `elements` vector, not the
        // named-property bag. Holes fall through to the
        // prototype chain (matches §10.4.2.1 step 2).
        if (o.is_array_exotic) {
            if (JSObject.canonicalIntegerIndex(key)) |idx| {
                if (o.tryGetIndexedOwn(idx)) |v| return v;
            }
        }
        if (o.properties.get(key)) |v| return v;
        cur = o.prototype;
    }
    return Value.undefined_;
}

/// Spec §7.1.20 ToLength on the receiver's `length` property.
/// Uses `getPropertyChain` so accessor `length` getters fire,
/// and `Object.defineProperty(obj, "length", {get: …})` style
/// fixtures behave per spec.
pub fn toLengthOf(realm: *Realm, obj: *JSObject) NativeError!i64 {
    const v = try getPropertyChain(realm, obj, "length");
    return toLengthValuePropagating(realm, v);
}

/// §7.1.20 ToLength = F(ToIntegerOrInfinity(ToNumber(arg))).
/// `ToNumber` on an Object triggers ToPrimitive — `valueOf` /
/// `toString` — which can throw. Propagate that throw via
/// `realm.pending_exception` instead of silently coercing to 0.
fn toLengthValuePropagating(realm: *Realm, v: Value) NativeError!i64 {
    if (v.isInt32()) {
        const i = v.asInt32();
        return if (i < 0) 0 else i;
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or d <= 0) return 0;
        return doubleToI64Saturating(d);
    }
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        const d = std.fmt.parseFloat(f64, s.bytes) catch return 0;
        if (std.math.isNan(d) or d <= 0) return 0;
        return doubleToI64Saturating(d);
    }
    if (heap_mod.valueAsSymbol(v) != null) return throwTypeError(realm, "Cannot convert a Symbol value to a number");
    // §7.1.4 ToNumber step 6 — Object: ToPrimitive(arg, hint
    // "number") which invokes `@@toPrimitive` / `valueOf` /
    // `toString` in that order. Any throw propagates.
    if (heap_mod.valueAsPlainObject(v)) |o| {
        // Try valueOf first.
        const value_of = try getPropertyChain(realm, o, "valueOf");
        if (heap_mod.valueAsFunction(value_of)) |vfn| {
            const interp = @import("interpreter.zig");
            const outcome = interp.callJSFunction(realm.allocator, realm, vfn, v, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |rv| {
                    if (!rv.isUndefined() and heap_mod.valueAsPlainObject(rv) == null) {
                        return toLengthValuePropagating(realm, rv);
                    }
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        const to_string = try getPropertyChain(realm, o, "toString");
        if (heap_mod.valueAsFunction(to_string)) |tfn| {
            const interp = @import("interpreter.zig");
            const outcome = interp.callJSFunction(realm.allocator, realm, tfn, v, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |rv| {
                    if (!rv.isUndefined() and heap_mod.valueAsPlainObject(rv) == null) {
                        return toLengthValuePropagating(realm, rv);
                    }
                    return throwTypeError(realm, "Cannot convert object to primitive value");
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        return throwTypeError(realm, "Cannot convert object to primitive value");
    }
    return 0;
}

/// Legacy slow-path `length` getter that doesn't invoke
/// accessors. Kept for callers that hold an obj-only handle and
/// don't need accessor behavior; new callers should prefer
/// `toLengthOf`. The intrinsic-side `length` checks (e.g.
/// `Array.isArray`) lean on this.
pub fn lengthOfArray(obj: *JSObject) i64 {
    const v = obj.get("length");
    if (v.isInt32()) return v.asInt32();
    if (v.isDouble()) return doubleToI64Saturating(v.asDouble());
    return 0;
}

/// §22.1.3.23 / §7.1.20 ToLength — clamps to [0, 2^53 - 1].
/// We additionally cap iteration to a reasonable bound so a
/// pathological `length: 4294967296` in test262 doesn't pin a CPU
/// for hours. Real engines throw RangeError on excessive lengths;
/// we mirror that by signalling NativeThrew so the surrounding
/// dispatcher coerces the failure to a real `RangeError`.
pub const max_iter_length: i64 = 1 << 24; // 16M elements is plenty for any realistic array op

pub fn clampArrayLength(len: i64) NativeError!i64 {
    if (len < 0) return 0;
    if (len > max_iter_length) return error.NativeThrew; // generic — caller sets the message via realm.pending_exception
    return len;
}

/// Range-checked variant: caller has access to `realm` and wants
/// the thrown value to carry a real `.message`.
fn clampArrayLengthOr(realm: *Realm, len: i64) NativeError!i64 {
    if (len < 0) return 0;
    if (len > max_iter_length) return throwRangeError(realm, "Array length exceeds maximum supported");
    return len;
}

/// Throw a native exception with a specific JS value.
/// Sets `realm.pending_exception` so the dispatcher reads it
/// when the caller returns `error.NativeThrew`.
fn throwNative(realm: *Realm, ex: Value) NativeError {
    realm.pending_exception = ex;
    return error.NativeThrew;
}

/// §10.2.4 %ThrowTypeError% body — "throwerSteps". Always throws
/// a fresh TypeError, regardless of receiver / args. Cynic uses
/// it for the strict-`arguments` `callee` accessor traps.
fn throwTypeErrorThrower(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
}

/// Convenience: throw a real `TypeError(msg)` from a native.
pub fn throwTypeError(realm: *Realm, msg: []const u8) NativeError {
    const ex = newTypeError(realm, msg) catch return error.OutOfMemory;
    return throwNative(realm, ex);
}

pub fn throwRangeError(realm: *Realm, msg: []const u8) NativeError {
    const ex = newRangeError(realm, msg) catch return error.OutOfMemory;
    return throwNative(realm, ex);
}

// ── Globals: replacing the stub constructors with real natives ─────────────

fn replaceGlobalNative(realm: *Realm, name: []const u8, native: NativeFn) !void {
    // Build a fresh function with the right native body and the
    // existing prototype object — the stub-installed `.prototype`
    // already has the right `.constructor` and is referenced by
    // `realm.intrinsics.<x>_prototype`. Rebind the global to point
    // at the new function; the prototype keeps its identity.
    const old_v = realm.globals.get(name) orelse return;
    const old_fn = heap_mod.valueAsFunction(old_v) orelse return;
    const fresh = try realm.heap.allocateFunctionNative(native, 1, name);
    fresh.prototype = old_fn.prototype;
    if (fresh.prototype) |p| {
        try p.set(realm.allocator, "constructor", heap_mod.taggedFunction(fresh));
    }
    try realm.globals.put(realm.allocator, name, heap_mod.taggedFunction(fresh));
}

fn stringConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const primitive: Value = if (args.len == 0) blk: {
        const s = realm.heap.allocateString("") catch return error.OutOfMemory;
        break :blk Value.fromString(s);
    } else blk: {
        const s = stringifyArg(realm, args[0]) catch return error.OutOfMemory;
        break :blk Value.fromString(s);
    };
    // §22.1.1.1 — when invoked as a constructor (NewTarget set),
    // box the primitive into the freshly allocated `this`. We
    // detect "called via new" by checking whether `this_value`
    // is a non-null plain object (the `new_call` op pre-allocates
    // the instance with the proto chain). When called as a plain
    // function, `this` is undefined and we just return the
    // primitive.
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        inst.boxed_primitive = primitive;
        // Also pin in the typed slot so
        // `String.prototype.toString` / `.valueOf` can unbox in
        // O(1) without an isString discriminator dance.
        if (primitive.isString()) {
            inst.boxed_string = @ptrCast(@alignCast(primitive.asString()));
        }
        return this_value; // ConstructResult will keep it
    }
    return primitive;
}

fn numberConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const primitive: Value = if (args.len == 0) Value.fromInt32(0) else coerceToNumber(args[0]);
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        inst.boxed_primitive = primitive;
        return this_value;
    }
    return primitive;
}

fn booleanConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const primitive: Value = if (args.len == 0) Value.false_ else Value.fromBool(toBoolean(args[0]));
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        inst.boxed_primitive = primitive;
        return this_value;
    }
    return primitive;
}

/// §20.3.3.3 thisBooleanValue / Boolean.prototype.valueOf — return
/// the underlying primitive bool. Receivers that aren't bool /
/// Boolean wrapper get a TypeError per the abstract op.
fn booleanProtoValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (this_value.isBool()) return this_value;
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        if (inst.boxed_primitive) |bp| {
            if (bp.isBool()) return bp;
        }
    }
    return throwTypeError(realm, "Boolean.prototype.valueOf called on non-Boolean");
}

/// §20.3.3.2 Boolean.prototype.toString — `"true"` / `"false"`.
/// Throws TypeError when the receiver isn't a bool / Boolean
/// wrapper.
fn booleanProtoToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const b = blk: {
        if (this_value.isBool()) break :blk this_value.asBool();
        if (heap_mod.valueAsPlainObject(this_value)) |inst| {
            if (inst.boxed_primitive) |bp| {
                if (bp.isBool()) break :blk bp.asBool();
            }
        }
        return throwTypeError(realm, "Boolean.prototype.toString called on non-Boolean");
    };
    const s = realm.heap.allocateString(if (b) "true" else "false") catch return error.OutOfMemory;
    return Value.fromString(s);
}

pub fn coerceToNumber(v: Value) Value {
    if (v.isInt32() or v.isDouble()) return v;
    if (v.isBool()) return Value.fromInt32(if (v.asBool()) 1 else 0);
    if (v.isNull()) return Value.fromInt32(0);
    if (v.isUndefined()) return Value.fromDouble(std.math.nan(f64));
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return stringToNumber(s.bytes);
    }
    return Value.fromDouble(std.math.nan(f64));
}

/// §7.1.4.1.1 StringToNumber — full StringNumericLiteral grammar
/// (StrWhiteSpace, NumericLiteralBase, decimal exponent). Rejects
/// the NumericLiteralSeparator (`1_000`) which the syntactic
/// numeric literal accepts but the runtime ToNumber does not.
pub fn stringToNumber(bytes: []const u8) Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n\u{0009}\u{000B}\u{000C}\u{00A0}\u{FEFF}");
    if (trimmed.len == 0) return Value.fromInt32(0);
    // Reject any underscore — §12.9.3.1 NumericLiteralSeparator
    // is a syntactic-only feature and not part of StringToNumber.
    for (trimmed) |c| {
        if (c == '_') return Value.fromDouble(std.math.nan(f64));
    }
    // Optional sign for decimal forms only — `0x` / `0b` / `0o`
    // prefixes are unsigned per the grammar.
    if (trimmed.len >= 2 and trimmed[0] == '0') {
        const radix: ?u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'b', 'B' => 2,
            'o', 'O' => 8,
            else => null,
        };
        if (radix) |r| {
            const digits = trimmed[2..];
            if (digits.len == 0) return Value.fromDouble(std.math.nan(f64));
            const parsed = std.fmt.parseInt(u64, digits, r) catch return Value.fromDouble(std.math.nan(f64));
            return Value.fromDouble(@floatFromInt(parsed));
        }
    }
    if ((trimmed[0] == '+' or trimmed[0] == '-') and trimmed.len > 1) {
        // Reject sign followed by non-decimal-prefix bases — the
        // grammar's signed form admits only StrDecimalLiteral.
        if (trimmed.len >= 3 and trimmed[1] == '0') {
            switch (trimmed[2]) {
                'x', 'X', 'b', 'B', 'o', 'O' => return Value.fromDouble(std.math.nan(f64)),
                else => {},
            }
        }
    }
    // Empty Infinity short-circuit — parseFloat handles `Infinity`
    // / `-Infinity` correctly already, so fall through.
    const d = std.fmt.parseFloat(f64, trimmed) catch return Value.fromDouble(std.math.nan(f64));
    return Value.fromDouble(d);
}

pub const ToPrimitiveHint = enum { default, number, string };

/// §7.1.1 ToPrimitive — coerce a value to a primitive, consulting
/// `Symbol.toPrimitive` (well-known key `@@toPrimitive`) if the
/// receiver is an object. Falls through to OrdinaryToPrimitive
/// (`valueOf` then `toString`, hint-ordered) per §7.1.1.1.
/// Primitive inputs return as-is.
pub fn toPrimitive(realm: *Realm, value: Value, hint: ToPrimitiveHint) NativeError!Value {
    if (!value.isObject()) return value;
    const interp = @import("interpreter.zig");

    // §7.1.1.1 OrdinaryToPrimitive maps "default"→"number" for
    // non-Date objects, but the @@toPrimitive trap receives the
    // raw hint string verbatim — "default", "number", or "string".
    const hint_str: []const u8 = switch (hint) {
        .default => "default",
        .number => "number",
        .string => "string",
    };
    if (heap_mod.valueAsPlainObject(value)) |obj| {
        // Symbol.toPrimitive override.
        const exotic = obj.get("@@toPrimitive");
        if (heap_mod.valueAsFunction(exotic)) |fn_obj| {
            const hint_v = realm.heap.allocateString(hint_str) catch return error.OutOfMemory;
            const args = [_]Value{Value.fromString(hint_v)};
            const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, value, &args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| {
                    // §7.1.1 step 6 — `If Type(result) is not Object,
                    // return result`. Symbols and BigInts are JS
                    // primitives (§6.1.5 / §6.1.6.2), so they pass
                    // through even though they share the object-tag
                    // encoding internally.
                    if (heap_mod.isJSObject(v)) return throwTypeError(realm, "Symbol.toPrimitive must return a primitive value");
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        // OrdinaryToPrimitive: `valueOf` then `toString` for
        // number/default hint; reverse for string.
        const first_name: []const u8 = if (hint == .string) "toString" else "valueOf";
        const second_name: []const u8 = if (hint == .string) "valueOf" else "toString";
        for ([_][]const u8{ first_name, second_name }) |name| {
            const method = obj.get(name);
            if (heap_mod.valueAsFunction(method)) |fn_obj| {
                const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, value, &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        // §7.1.1.1 step 5.iii — accept any JS
                        // primitive (including Symbol / BigInt). Only
                        // a true Object result keeps the loop going to
                        // try the second method.
                        if (!heap_mod.isJSObject(v)) return v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
        }
        return throwTypeError(realm, "Cannot convert object to primitive value");
    }
    // Functions, symbols, bigints — for now fall back to `value`
    // (treat as primitive). Symbols can't reach here via the
    // hint=number path without throwing per §7.1.4 ToNumber, but
    // we keep this conservative.
    return value;
}

/// §7.1.4 ToNumber — like `coerceToNumber` but consults
/// `Symbol.toPrimitive` / `valueOf` / `toString` for object
/// receivers. Returns either an int32 or double Value.
pub fn toNumber(realm: *Realm, v: Value) NativeError!Value {
    const prim = try toPrimitive(realm, v, .number);
    return coerceToNumber(prim);
}

// ── Equality helpers ────────────────────────────────────────────────────────

pub fn strictEqualsLite(a: Value, b: Value) bool {
    if (a.bits == b.bits) return true;
    // NaN never equals itself even by bit pattern (canonicalised
    // here, so matches), but other strict-equality cross-type
    // rules — int vs double — need a check.
    if (a.isInt32() and b.isDouble()) return @as(f64, @floatFromInt(a.asInt32())) == b.asDouble();
    if (a.isDouble() and b.isInt32()) return a.asDouble() == @as(f64, @floatFromInt(b.asInt32()));
    if (a.isString() and b.isString()) {
        const sa: *JSString = @ptrCast(@alignCast(a.asString()));
        const sb: *JSString = @ptrCast(@alignCast(b.asString()));
        return std.mem.eql(u8, sa.bytes, sb.bytes);
    }
    return false;
}

pub fn sameValueZero(a: Value, b: Value) bool {
    return strictEqualsLite(a, b);
}

/// §7.2.10 SameValue — like SameValueZero but distinguishes
/// `+0` from `-0`. The basis for `Object.is`.
pub fn sameValue(a: Value, b: Value) bool {
    // Number numerics need the SameValueNumber rule:
    // `NaN === NaN`, `+0 !== -0`, otherwise IEEE-754 equality.
    const a_d: ?f64 = if (a.isInt32()) @floatFromInt(a.asInt32()) else if (a.isDouble()) a.asDouble() else null;
    const b_d: ?f64 = if (b.isInt32()) @floatFromInt(b.asInt32()) else if (b.isDouble()) b.asDouble() else null;
    if (a_d != null and b_d != null) {
        const da = a_d.?;
        const db = b_d.?;
        if (std.math.isNan(da) and std.math.isNan(db)) return true;
        if (da == 0 and db == 0) {
            return std.math.signbit(da) == std.math.signbit(db);
        }
        return da == db;
    }
    return strictEqualsLite(a, b);
}

pub fn toInt(v: Value) i64 {
    if (v.isInt32()) return v.asInt32();
    if (v.isDouble()) return doubleToI64Saturating(v.asDouble());
    return 0;
}

/// Saturating cast from `f64` to `i64`. `@intFromFloat` panics on
/// values outside the destination type (test262 explicitly throws
/// `length: 4294967296` etc.); clamp to the i64 range first.
pub fn doubleToI64Saturating(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
    if (std.math.isInf(d)) return if (d > 0) std.math.maxInt(i64) else 0;
    const truncated = @trunc(d);
    const i64_max_safe: f64 = 9223372036854775000.0;
    if (truncated > i64_max_safe) return std.math.maxInt(i64);
    if (truncated < -i64_max_safe) return std.math.minInt(i64);
    return @intFromFloat(truncated);
}

/// Allocate an Error-shaped constructor (`name`) plus its prototype
/// chained to `parent_proto`. Registers the constructor as a global
/// under `name`. Returns the constructor. The prototype's
/// `.constructor` is wired back to the function and `.name` is
/// `name`.
/// to keep the runtime well-defined.
pub fn stringifyArg(realm: *Realm, v: Value) NativeError!*JSString {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s;
    }
    // §7.1.17 ToString — for object receivers run §7.1.1
    // ToPrimitive with hint "string" first, which consults
    // `Symbol.toPrimitive` / `toString` / `valueOf` in spec
    // order. Symbol primitives throw TypeError per §7.1.17 step 6.
    if (v.isObject()) {
        if (heap_mod.valueAsSymbol(v) != null) {
            return throwTypeError(realm, "Cannot convert a Symbol value to a string");
        }
        if (heap_mod.valueAsBigInt(v)) |bi| {
            const buf = std.fmt.allocPrint(realm.allocator, "{d}", .{bi.value}) catch return error.OutOfMemory;
            defer realm.allocator.free(buf);
            return realm.heap.allocateString(buf) catch return error.OutOfMemory;
        }
        if (heap_mod.valueAsFunction(v)) |fn_obj| {
            // §20.2.3.5 — match Function.prototype.toString. Real
            // source for user functions, native-function format
            // (with name when present) otherwise.
            if (fn_obj.source) |src| {
                return realm.heap.allocateString(src) catch return error.OutOfMemory;
            }
            const display_name: []const u8 = if (fn_obj.name) |n| n else "";
            const formatted = if (display_name.len == 0)
                std.fmt.allocPrint(realm.allocator, "function () {{ [native code] }}", .{}) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(realm.allocator, "function {s}() {{ [native code] }}", .{display_name}) catch return error.OutOfMemory;
            defer realm.allocator.free(formatted);
            return realm.heap.allocateString(formatted) catch return error.OutOfMemory;
        }
        const prim = try toPrimitive(realm, v, .string);
        // Don't recurse into another `isObject()` case — at this
        // point `prim` must be a primitive (toPrimitive throws
        // TypeError otherwise).
        return stringifyArg(realm, prim);
    }
    var buf: [64]u8 = undefined;
    const slice: []const u8 = blk: {
        if (v.isInt32()) {
            break :blk std.fmt.bufPrint(&buf, "{d}", .{v.asInt32()}) catch unreachable;
        } else if (v.isDouble()) {
            const d = v.asDouble();
            if (std.math.isNan(d)) break :blk "NaN";
            if (std.math.isInf(d)) break :blk if (d > 0) "Infinity" else "-Infinity";
            // §6.1.6.1.13 Number::toString step 2 — both +0 and
            // -0 stringify as `"0"`. The internal sign survives
            // for SameValue, but ToString collapses them.
            if (d == 0) break :blk "0";
            // §6.1.6.1.20 — switch to exponential notation for
            // very large / very small magnitudes so the formatted
            // result fits in our scratch buffer.
            const a = @abs(d);
            if (a != 0 and (a < 1e-6 or a >= 1e21)) {
                break :blk std.fmt.bufPrint(&buf, "{e}", .{d}) catch unreachable;
            }
            break :blk std.fmt.bufPrint(&buf, "{d}", .{d}) catch unreachable;
        } else if (v.isBool()) {
            break :blk if (v.asBool()) "true" else "false";
        } else if (v.isNull()) {
            break :blk "null";
        } else if (v.isUndefined()) {
            break :blk "undefined";
        } else {
            break :blk "[object]";
        }
    };
    return realm.heap.allocateString(slice) catch return error.OutOfMemory;
}

// ── ArrayBuffer / DataView / TypedArray live in `builtins/typed_array.zig` ───
//
// Re-exported here so existing callers (notably the
// interpreter's index-access path) keep their
// `intrinsics_mod.readTypedElement` / `.writeTypedElement`
// references working unchanged.

pub const readTypedElement = @import("builtins/typed_array.zig").readTypedElement;
pub const writeTypedElement = @import("builtins/typed_array.zig").writeTypedElement;

// Iterator factory methods live in `builtins/collections.zig` —
// re-export so `builtins/typed_array.zig` and other call sites
// can keep their `intrinsics.arrayLike*Method` imports.
pub const arrayLikeValuesMethod = @import("builtins/collections.zig").arrayLikeValuesMethod;
pub const arrayLikeKeysMethod = @import("builtins/collections.zig").arrayLikeKeysMethod;
pub const arrayLikeEntriesMethod = @import("builtins/collections.zig").arrayLikeEntriesMethod;

// Object methods live in `builtins/object.zig` — re-export those
// referenced by other builtins so the `intrinsics.objectXxx`
// imports keep working.
pub const objectGetOwnPropertyDescriptor = @import("builtins/object.zig").objectGetOwnPropertyDescriptor;
pub const objectDefineProperty = @import("builtins/object.zig").objectDefineProperty;
pub const objectPreventExtensions = @import("builtins/object.zig").objectPreventExtensions;
pub const objectGetPrototypeOf = @import("builtins/object.zig").objectGetPrototypeOf;
pub const ownPropertyKeysOrdered = @import("builtins/object.zig").ownPropertyKeysOrdered;

// Array helpers used by intrinsics' own ctor wiring + sibling
// builtins (TypedArray reaches for `numberFromI64`, etc.).
pub const numberFromI64 = @import("builtins/array.zig").numberFromI64;
pub const setLength = @import("builtins/array.zig").setLength;
pub const toBoolean = @import("builtins/array.zig").toBoolean;
pub const isArrayLike = @import("builtins/array.zig").isArrayLike;
pub const invokeCallback = @import("builtins/array.zig").invokeCallback;

// Error class factories live in `builtins/error.zig`; the
// runtime exception path (`makeTypeError`, `throwTypeError`,
// the URI / parser glue) reaches them via these re-exports.
pub const newTypeError = @import("builtins/error.zig").newTypeError;
pub const newRangeError = @import("builtins/error.zig").newRangeError;
pub const newReferenceError = @import("builtins/error.zig").newReferenceError;
pub const newSyntaxError = @import("builtins/error.zig").newSyntaxError;
pub const newURIError = @import("builtins/error.zig").newURIError;

pub const PromiseState = @import("builtins/promise.zig").PromiseState;
pub const allocatePromiseFor = @import("builtins/promise.zig").allocatePromiseFor;

