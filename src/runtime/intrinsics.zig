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
const utf16_mod = @import("utf16.zig");
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

    /// §20.5.x SuppressedError (ES2026 explicit-resource-management)
    /// — Error subclass with `.error` and `.suppressed` own
    /// properties. `DisposeResources` wraps in this when a
    /// disposer throws while another throw is in flight.
    suppressed_error_constructor: ?*JSFunction = null,
    suppressed_error_prototype: ?*JSObject = null,

    /// §27.3 DisposableStack (ES2026 explicit-resource-management)
    /// — the synchronous resource-stack global. `.use(v)` /
    /// `.adopt(v, onDispose)` / `.defer(onDispose)` register
    /// resources; `.dispose()` walks them in LIFO order and
    /// wraps mid-disposal throws via SuppressedError. Sibling
    /// %AsyncDisposableStack% lands later (Phase 5).
    disposable_stack_constructor: ?*JSFunction = null,
    disposable_stack_prototype: ?*JSObject = null,

    /// `%GeneratorPrototype%` (§27.5.1). Lazily installed on the
    /// first `function*` call by `lantern.ensureGeneratorPrototype`;
    /// `null` until then. Carries `next` / `return` / `throw` and
    /// the well-known iterator dispatcher under `"@@iterator"`.
    generator_prototype: ?*JSObject = null,

    /// `%AsyncGeneratorPrototype%` (§27.6.1) — same shape as
    /// `generator_prototype` but `next` / `return` / `throw`
    /// wrap their `{value, done}` (or thrown) result in a fresh
    /// Promise. Lazily installed on first `async function*`
    /// invocation.
    async_generator_prototype: ?*JSObject = null,
    /// §27.1.3 %AsyncIteratorPrototype% — ancestor of every
    /// async iterator. Houses `@@asyncIterator` (returns this).
    async_iterator_prototype: ?*JSObject = null,
    /// §27.6.1 %AsyncFromSyncIteratorPrototype% — hidden
    /// intrinsic adapting a sync iterator to the async-iter
    /// protocol. Lazily installed on first wrap (see
    /// `builtins/async_iterator.zig`).
    async_from_sync_iterator_prototype: ?*JSObject = null,
    /// §27.1.4.1.2 %WrapForValidIteratorPrototype% — the proto
    /// of objects returned by `Iterator.from(o)` when `o` is a
    /// valid iterator that needs to be wrapped. Carries `next`
    /// and `return` that delegate to the wrapped iterator's
    /// methods. Lazily installed on first `Iterator.from` call
    /// (see `builtins/iterator.zig`).
    wrap_for_valid_iterator_prototype: ?*JSObject = null,

    /// §27.1.4.1 %IteratorHelperPrototype% — the `[[Prototype]]`
    /// of every Iterator Helper object: the results of
    /// `Iterator.prototype.{map,filter,take,drop,flatMap}` and of
    /// `Iterator.concat` / `Iterator.zip` / `Iterator.zipKeyed`.
    /// Inherits `%IteratorPrototype%`; carries the generic `next`
    /// / `return` (dispatched on the helper kind) and the
    /// `"Iterator Helper"` `@@toStringTag`. Built by
    /// `builtins/iterator.zig:install`.
    iterator_helper_prototype: ?*JSObject = null,

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
    /// `%ArrayBuffer.prototype%` (§25.1.5). Captured at install
    /// time so the constructor's deferred-OCFC path (§25.1.4.1)
    /// can resolve the intrinsic-default prototype from a native
    /// without re-walking globals.
    array_buffer_prototype: ?*JSObject = null,
    /// `%DataView.prototype%` (§25.3.4). Same role as
    /// `array_buffer_prototype` — supplies the intrinsic default
    /// for §25.3.2.1's deferred OCFC.
    data_view_prototype: ?*JSObject = null,
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

    /// `%ArrayIteratorPrototype%` (§23.1.5.2). Shared prototype of
    /// every Array iterator returned by `Array.prototype.{values,
    /// keys, entries}` and `Array.prototype[@@iterator]`. Chains
    /// to `%IteratorPrototype%` so the Stage 4 `.map` / `.filter`
    /// / `[Symbol.iterator]` helpers resolve through it. Lazily
    /// allocated by `ensureArrayIteratorPrototype` on first use
    /// (collections.zig) — `Iterator` install runs after Array,
    /// so eager wiring would walk into a not-yet-built proto.
    array_iterator_prototype: ?*JSObject = null,

    /// The original `%ArrayIteratorPrototype%.next` native, captured
    /// when the prototype is built. The `for_of_next` opcode's fast
    /// path compares the loop's cached `[[NextMethod]]` against this
    /// to confirm the built-in Array iterator hasn't been replaced
    /// before stepping the backing storage directly.
    array_iterator_next: Value = Value.undefined_,

    /// `%StringIteratorPrototype%` (§22.1.5.2). Same shape — chains
    /// to `%IteratorPrototype%`. Lazily allocated alongside
    /// `array_iterator_prototype`.
    string_iterator_prototype: ?*JSObject = null,

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

    // §19.3 globalThis — allocate the global object up front and
    // promote `realm.globals` to a live view over its properties.
    // Every subsequent `realm.globals.put(...)` lands directly on
    // `gt.properties`, so `globalThis.X` and bare-identifier
    // lookups stay in lockstep without a snapshot rebuild.
    const gt = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(gt, obj_proto);
    try realm.globals.bindToObject(realm.allocator, gt);
    // The `globalThis` binding itself is `{ w:true, e:false, c:true }`
    // per §19.3.3 (a standard built-in).
    try gt.setWithFlags(realm.allocator, "globalThis", heap_mod.taggedObject(gt), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

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
    // Hand the heap the freshly-built %Function.prototype% so
    // `allocateFunctionNative` can wire every later-allocated
    // native function's `[[Prototype]]` at creation time —
    // including the ones installed lazily after this init pass.
    realm.heap.function_prototype = realm.intrinsics.function_prototype;
    // §20.2.3 — %Function.prototype% is itself a built-in
    // function object that, when called, returns undefined.
    // §13.5.3 typeof routes through the `proxy_callable` flag for
    // plain JSObjects with callable exotic semantics, so flip it
    // here to satisfy `typeof Function.prototype === "function"`.
    if (realm.intrinsics.function_prototype) |fp| fp.proxy_callable = true;

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
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };
        try t.property_flags.put(realm.allocator, "length", frozen_flags);
        try t.property_flags.put(realm.allocator, "name", frozen_flags);
        // §10.2.4 — %ThrowTypeError% has [[Extensible]] = false.
        // Test262 `built-ins/ThrowTypeError/extensible.js` reads
        // it via `Object.isExtensible`. The JSFunction `extensible`
        // flag flips it.
        t.extensible = false;
        realm.intrinsics.throw_type_error = t;

        // §10.2.4 — Function.prototype.arguments and
        // Function.prototype.caller are accessor properties whose
        // [[Get]] and [[Set]] are both %ThrowTypeError%. test262
        // `built-ins/ThrowTypeError/unique-per-realm-function-proto`
        // verifies the same singleton lands in both descriptors.
        if (realm.intrinsics.function_prototype) |fn_proto| {
            const a_entry = fn_proto.getOrPutAccessor(realm.allocator, "arguments") catch return error.OutOfMemory;
            a_entry.value_ptr.* = .{ .getter = t, .setter = t };
            try fn_proto.property_flags.put(realm.allocator, "arguments", .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            });
            const c_entry = fn_proto.getOrPutAccessor(realm.allocator, "caller") catch return error.OutOfMemory;
            c_entry.value_ptr.* = .{ .getter = t, .setter = t };
            try fn_proto.property_flags.put(realm.allocator, "caller", .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
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
            realm.heap.setBoxedPrimitive(bp, Value.false_);
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
        // §22.1.3 — `%String.prototype%` itself is a String exotic
        // object whose `[[StringData]]` is the empty String. Cynic
        // records the slot two ways: `boxed_primitive` for the
        // ToString / ToNumber unboxing path, and `boxed_string` for
        // the §10.4.3 String-exotic brand check (which drives the
        // `"String"` builtinTag in §20.1.3.6 Object.prototype.toString
        // — Sputnik `built-ins/String/prototype/S15.5.4_A{1,2,3}.js`
        // delete `String.prototype.toString` and rely on the
        // inherited `Object.prototype.toString.call(String.prototype)`
        // returning `"[object String]"`).
        const empty_str = realm.heap.allocateString("") catch return error.OutOfMemory;
        realm.heap.setBoxedPrimitive(sp, Value.fromString(empty_str));
        try realm.heap.setBoxedString(sp, empty_str);
        // §22.1.4 — `String.prototype` has a `length` data property
        // whose initial value is 0 and whose attributes are
        // `{ [[Writable]]: false, [[Enumerable]]: false,
        //    [[Configurable]]: false }`. Without this `length`
        // would shadow-lookup to `undefined`, breaking Sputnik
        // `language/expressions/property-accessors/S11.2.1_A4_T5.js`.
        try sp.setWithFlags(realm.allocator, "length", Value.fromInt32(0), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
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

    // §19.2.1 — `eval` global. Cynic is strict-only and explicitly
    // does NOT ship runtime code construction (eval / new Function /
    // new GeneratorFunction). The binding still has to EXIST on
    // globalThis though — Sputnik fixtures (S10.2.3_*) and the
    // strict-mode global-property tests do `eval === null` etc.,
    // which fail with ReferenceError if `eval` is not a property.
    // Wire it as a throwing native (length 1, !construct) so
    // `eval !== null` is true, `eval(...)` raises EvalError, and
    // typeof eval === "function".
    const eval_fn = try realm.heap.allocateFunctionNative(globalEvalNotSupported, 1, "eval");
    eval_fn.has_construct = false;
    try realm.globals.put(realm.allocator, "eval", heap_mod.taggedFunction(eval_fn));

    // §19.1 — `undefined`, `NaN`, `Infinity` are frozen data
    // properties: `{ w:false, e:false, c:false }`. They were just
    // installed (a few lines above) through the standard
    // `realm.globals.put` path, which writes default flags. Stamp
    // the frozen descriptors onto the live globalThis object now.
    if (realm.globals.target) |gt_for_flags| {
        for ([_][]const u8{ "undefined", "NaN", "Infinity" }) |k| {
            if (gt_for_flags.ownDataContains(k)) {
                // Re-stamp the descriptor through `setWithFlags`
                // so the attrs land on the right side under
                // Phase 3 of [docs/lazy-property-bag.md] — for
                // shape-mode globals the attrs are stored on the
                // shape transition node, not the bag. The
                // current value flows through; we're flipping
                // flags, not the value.
                const cur_v = gt_for_flags.lookupOwn(k) orelse Value.undefined_;
                try gt_for_flags.setWithFlags(realm.allocator, k, cur_v, .{
                    .writable = false,
                    .enumerable = false,
                    .configurable = false,
                });
            }
        }
    }

    // §21.1.2 Number static value properties. Each is a data
    // property with `{ writable: false, enumerable: false,
    // configurable: false }` per the table in §21.1.2.
    if (heap_mod.valueAsFunction(realm.globals.get("Number").?)) |num_ctor| {
        const num_const_flags: @import("object.zig").PropertyFlags = .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };
        try num_ctor.setWithFlags(realm.allocator, "NaN", Value.fromDouble(std.math.nan(f64)), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "POSITIVE_INFINITY", Value.fromDouble(std.math.inf(f64)), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "NEGATIVE_INFINITY", Value.fromDouble(-std.math.inf(f64)), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "MAX_SAFE_INTEGER", Value.fromDouble(9007199254740991.0), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "MIN_SAFE_INTEGER", Value.fromDouble(-9007199254740991.0), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "MAX_VALUE", Value.fromDouble(std.math.floatMax(f64)), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "MIN_VALUE", Value.fromDouble(5e-324), num_const_flags);
        try num_ctor.setWithFlags(realm.allocator, "EPSILON", Value.fromDouble(std.math.floatEps(f64)), num_const_flags);
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
    // §27.3 DisposableStack (ES2026 explicit-resource-management).
    // Installed AFTER `error.installAll` (so the SuppressedError
    // constructor `.dispose()` wraps with is reachable) and AFTER
    // `symbol.install` (so `Symbol.dispose` is registered and
    // `.use(v)`'s `GetMethod(v, @@dispose)` can find it on a
    // user-supplied resource).
    try @import("builtins/disposable_stack.zig").install(realm);
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
        for (realm.heap.functions_young.items) |fn_obj| {
            if (fn_obj.proto == null) fn_obj.proto = fn_proto;
        }
        for (realm.heap.functions_mature.items) |fn_obj| {
            if (fn_obj.proto == null) fn_obj.proto = fn_proto;
        }
    }

    // `harden(value)` — SES recursive deep-freeze. Part of the
    // SES posture: install only when `realm.hardened` is true,
    // matching the atomic-toggle contract documented in
    // [AGENTS.md](../../AGENTS.md) ("`--unhardened` ⇒ primordials
    // stay mutable, harden() isn't installed, override-mistake
    // fix skipped"). Installed BEFORE `freezePrimordials` so the
    // pass reaches `harden` and stamps it frozen too (otherwise
    // untrusted user code could shadow `globalThis.harden =
    // identity` to defeat the hardening posture).
    if (realm.hardened) try @import("builtins/harden.zig").install(realm);

    // Phase 1 of [docs/ses-alignment.md] — freeze every reachable
    // intrinsic + `globalThis`. Gated on `realm.hardened`
    // (default true; `--unhardened` flips it). Reuses the same
    // walker `harden(value)` does so the freeze shape stays in
    // lockstep with user-invoked hardening.
    if (realm.hardened) try freezePrimordials(realm);

    // No catch-up pass needed — `realm.globals` is a live view
    // over the globalThis object's `properties`. Every binding
    // installed above (Map/Set/Date/Promise/__drainMicrotasks/…)
    // already lives on `gt.properties`, so `globalThis.X` reads
    // hit them directly.
}

/// Phase 1 + Phase 3 SES freeze. Two passes:
///
///  1. **Freeze walk** (`hardenWalk`) — stamps `[[Extensible]] =
///     false` on every reachable object / function and locks
///     every own descriptor `{writable: false, configurable:
///     false}` (accessors get `{configurable: false}`). Same
///     shape as user-invoked `harden(value)`.
///
///  2. **Override-mistake fix** (Phase 3) — every *prototype*
///     object's own data descriptors are demoted to a synthetic
///     accessor pair. The getter returns the captured value;
///     the setter calls DefineOwnProperty on the receiver, which
///     creates an own data property on the user receiver
///     (shadowing the frozen prototype) instead of throwing.
///     Only prototypes get this treatment — constructors,
///     `globalThis`, namespace objects (`Math`, `JSON`,
///     `Reflect`) stay as plain frozen data slots so that
///     `Array = somethingElse` and `Math.PI = 4` continue to
///     throw.
///
/// Called as the last step of `install(realm)` when
/// `realm.hardened` is true. Skipped wholesale under
/// `--unhardened`, where Cynic behaves like legacy ECMAScript
/// (mutable primordials, extensible globalThis).
///
/// Acknowledged gaps (inherited from `hardenWalk`): module
/// namespaces, proxy receivers, array-exotic indexed slots —
/// none of which appear on the intrinsic graph today. See the
/// `harden.zig` file header for the full list.
fn freezePrimordials(realm: *Realm) !void {
    // ── Pass 1 — deep freeze ─────────────────────────────────
    var visited: std.AutoHashMap(usize, void) = .init(realm.allocator);
    defer visited.deinit();
    const hardenWalk = @import("builtins/harden.zig").hardenWalk;
    // Walk `globalThis` first — its property bag transitively
    // reaches every host-installed binding (`Array`, `Object`,
    // `Math`, `harden`, …) and through each one's `.prototype`
    // chain the full prototype graph. The visited set
    // short-circuits the explicit per-intrinsic walk below so
    // intrinsics reachable through globalThis aren't re-walked.
    if (realm.globals.target) |gt| {
        try hardenWalk(realm, heap_mod.taggedObject(gt), &visited);
    }
    // Belt-and-braces: a handful of intrinsics aren't reachable
    // through globalThis (the unpinned `%ThrowTypeError%`,
    // `%Object.prototype%` if Object's constructor was patched
    // mid-init, …). Iterate the struct via comptime reflection
    // so a future intrinsic addition is covered automatically.
    inline for (@typeInfo(Intrinsics).@"struct".fields) |field| {
        const v = @field(realm.intrinsics, field.name);
        const T = @TypeOf(v);
        if (T == ?*@import("object.zig").JSObject) {
            if (v) |o| try hardenWalk(realm, heap_mod.taggedObject(o), &visited);
        } else if (T == ?*JSFunction) {
            if (v) |fp| try hardenWalk(realm, heap_mod.taggedFunction(fp), &visited);
        }
    }

    // ── Pass 2 — override-mistake fix on prototype objects ───
    //
    // Collect every prototype the user JS can reach as
    // `[[Prototype]]`: every `*_prototype` field on Intrinsics +
    // every constructor's `.prototype`. Skip non-prototype
    // intrinsics (`Math`, `JSON`, `Reflect`, the global object) so
    // direct intrinsic mutation like `Math.PI = 4` keeps
    // throwing per the Phase 1 freeze.
    var proto_set: std.AutoHashMap(*JSObject, void) = .init(realm.allocator);
    defer proto_set.deinit();
    inline for (@typeInfo(Intrinsics).@"struct".fields) |field| {
        const v = @field(realm.intrinsics, field.name);
        const T = @TypeOf(v);
        if (T == ?*JSObject) {
            // Naming convention: every prototype intrinsic field
            // ends in `_prototype` (`object_prototype`,
            // `array_iterator_prototype`, …). Non-prototype
            // JSObject fields (`throw_type_error` is a JSFunction,
            // so it doesn't hit this arm; nothing else lives
            // here today) are skipped.
            if (comptime std.mem.endsWith(u8, field.name, "_prototype")) {
                if (v) |o| try proto_set.put(o, {});
            }
        } else if (T == ?*JSFunction) {
            if (v) |fn_obj| {
                if (fn_obj.prototype) |p| try proto_set.put(p, {});
            }
        }
    }
    var it = proto_set.iterator();
    while (it.next()) |entry| {
        try installOverrideMistakeFix(realm, entry.key_ptr.*);
    }
}

/// Demote each of `proto`'s own data properties to a Phase 3
/// synthetic accessor pair so user writes through the prototype
/// chain shadow on the receiver instead of failing the §10.1.9.2
/// "non-writable inherited slot" rejection.
fn installOverrideMistakeFix(realm: *Realm, proto: *JSObject) !void {
    // Snapshot the data entries before we mutate the bag —
    // iterating while removing would invalidate the iterator.
    const Entry = struct {
        key: []const u8,
        value: Value,
        enumerable: bool,
    };
    var snapshot: std.ArrayListUnmanaged(Entry) = .empty;
    defer snapshot.deinit(realm.allocator);
    var pit = proto.iterOwnNamedKeys();
    while (pit.next()) |e| {
        const flags = proto.flagsFor(e.key_ptr.*);
        try snapshot.append(realm.allocator, .{
            .key = e.key_ptr.*,
            .value = e.value_ptr.*,
            .enumerable = flags.enumerable,
        });
    }
    for (snapshot.items) |s| {
        // §15.7.14 / §17 — `constructor` is the back-edge that
        // makes `instance.constructor === MyClass` work. Demoting
        // it to a synth accessor would route every
        // `someInst.constructor` read through the getter. Cheap
        // to read in cycle terms but it shows up in IC misses;
        // leave it as a frozen data slot (and accept the
        // override mistake for the rare `Foo.prototype.constructor
        // = …` reassignment — that's not a hot path).
        if (std.mem.eql(u8, s.key, "constructor")) continue;
        try installSyntheticAccessorPair(realm, proto, s.key, s.value, s.enumerable);
    }
}

/// Replace `proto`'s own data property `key = value` with an
/// accessor pair `(synthGet, synthSet)`. The pair's descriptor
/// is `{enumerable, configurable: false}` — the configurability
/// bit stays locked so `Object.defineProperty(proto, key,
/// {value: …})` can't put the data slot back.
fn installSyntheticAccessorPair(
    realm: *Realm,
    proto: *JSObject,
    key: []const u8,
    value: Value,
    enumerable: bool,
) !void {
    const SyntheticAccessor = @import("function.zig").SyntheticAccessor;
    // Two cells — one per role. They share the key + value
    // contents but each carries its own `is_setter` flag because
    // call dispatch reads that to pick the branch.
    const get_cell = try realm.allocator.create(SyntheticAccessor);
    get_cell.* = .{ .value = value, .key = key, .is_setter = false };
    try realm.synth_accessor_cells.append(realm.allocator, get_cell);
    const set_cell = try realm.allocator.create(SyntheticAccessor);
    set_cell.* = .{ .value = value, .key = key, .is_setter = true };
    try realm.synth_accessor_cells.append(realm.allocator, set_cell);

    // Allocate the getter / setter JSFunctions. The native body
    // is a placeholder — call dispatch short-circuits on
    // `synth_accessor != null` before invoking it.
    const get_fn = try realm.heap.allocateFunctionNative(synthAccessorPlaceholder, 0, "");
    get_fn.synth_accessor = get_cell;
    get_fn.has_construct = false;
    get_fn.extensible = false;
    const set_fn = try realm.heap.allocateFunctionNative(synthAccessorPlaceholder, 1, "");
    set_fn.synth_accessor = set_cell;
    set_fn.has_construct = false;
    set_fn.extensible = false;

    // The shape system only models data properties; an accessor
    // install MUST demote first or the IC's shape lookup would
    // still serve the removed slot's stale value.
    try proto.demoteFromShape(realm.allocator);
    _ = proto.properties.swapRemove(key);
    const entry = try proto.getOrPutAccessor(realm.allocator, key);
    entry.value_ptr.* = .{ .getter = get_fn, .setter = set_fn };
    // Accessor descriptor — `writable` is ignored, `configurable`
    // stays false (the Phase 1 freeze applied to the underlying
    // slot; preserving non-configurable matches the spec's
    // observable shape and prevents the SES posture from being
    // unwound by `Object.defineProperty`).
    try proto.property_flags.put(realm.allocator, key, .{
        .writable = false,
        .enumerable = enumerable,
        .configurable = false,
    });
}

/// Placeholder native body for synthetic accessor closures. Call
/// dispatch (`callJSFunction`) short-circuits on
/// `JSFunction.synth_accessor` BEFORE reaching the native
/// callback, so this body is never invoked in normal operation.
/// Returning `undefined` is the safe fallback if dispatch ever
/// misses the short-circuit (e.g. a future call path forgets
/// the check).
fn synthAccessorPlaceholder(
    realm: *Realm,
    this_value: Value,
    args: []const Value,
) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
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
    realm.heap.setObjectPrototype(proto, parent_proto);
    try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    realm.heap.setFunctionPrototype(fn_obj, proto);
    // §17 — built-in constructors have a non-writable, non-
    // enumerable, non-configurable `prototype` data property.
    // The `flagsForOwn` synthesizer would otherwise hand back the
    // ordinary-function default (writable: true) since
    // `is_class_constructor` is reserved for `class C {}` literals
    // (it gates the "Class constructor cannot be invoked without
    // 'new'" check). Stash the override directly in
    // `property_flags` so it wins the lookup.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
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
    realm.heap.setFunctionPrototype(fn_obj, proto);
    // §17 — same non-writable-prototype default as the stub path above.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
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
    /// When `false`, skip the default `prototype.constructor`
    /// data-property wiring. The caller is expected to install
    /// its own descriptor (e.g. `Iterator.prototype.constructor`
    /// is an accessor pair per §27.1.4.6).
    install_constructor_property: bool = true,
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
    realm.heap.setObjectPrototype(proto, realm.intrinsics.object_prototype);
    if (spec.install_constructor_property) {
        try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj));
    }
    if (spec.to_string_tag) |t| try installToStringTag(realm, proto, t);
    realm.heap.setFunctionPrototype(fn_obj, proto);
    if (spec.set_home_object) realm.heap.setHomeObject(fn_obj, proto);
    // §17 — every built-in constructor's `prototype` slot is
    // { w:false, e:false, c:false } regardless of whether the
    // function itself is a class-style constructor (`new`-only,
    // e.g. Map) or callable-without-new (BigInt, Symbol). The
    // synthesized §10.2.4 default in `JSFunction.flagsForOwn`
    // gives the callable-without-new branch `writable: true`,
    // which is correct for ordinary user functions but not for
    // built-in ctors — pin the §17 attributes explicitly here.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
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
    // §17 — built-in getter functions carry `name` = `"get <propname>"`
    // (with the space). Test262 verifies via
    // `Object.getOwnPropertyDescriptor(proto, key).get.name`.
    // Allocate via the realm's class-arena so the slice lives
    // for the realm's lifetime without leaking through GC.
    // §17 — when the property key is a well-known Symbol the
    // function's `.name` is `"get [Symbol.<descr>]"`, not the
    // raw `@@<descr>` slot key. Cynic stores well-known symbols
    // under `"@@<descr>"`; rewrite when formatting the name so
    // test262 (`get foo.name === "get [Symbol.toStringTag]"`)
    // sees the spec-faithful form.
    const getter_name = if (std.mem.startsWith(u8, name, "@@"))
        std.fmt.allocPrint(realm.classAllocator(), "get [Symbol.{s}]", .{name[2..]}) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(realm.classAllocator(), "get {s}", .{name}) catch return error.OutOfMemory;
    const getter = try realm.heap.allocateFunctionNative(getter_fn, 0, getter_name);
    getter.proto = realm.intrinsics.function_prototype;
    const entry = try proto.getOrPutAccessor(realm.allocator, name);
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
    // §17 — when the property key is a well-known Symbol the
    // function's `.name` is `"[Symbol.<descr>]"`, not the raw
    // `@@<descr>` slot key. Cynic stores well-known symbols under
    // `"@@<descr>"`; rewrite when allocating the function so
    // test262 (e.g. `String.prototype[Symbol.iterator].name ===
    // "[Symbol.iterator]"`) sees the spec-faithful form.
    const fn_name = if (std.mem.startsWith(u8, name, "@@"))
        std.fmt.allocPrint(realm.classAllocator(), "[Symbol.{s}]", .{name[2..]}) catch return error.OutOfMemory
    else
        name;
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, fn_name);
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
    realm.heap.setObjectPrototype(obj, realm.intrinsics.array_prototype);
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
        realm.heap.setObjectPrototype(w, realm.intrinsics.string_prototype);
        realm.heap.setBoxedString(w, s) catch return error.OutOfMemory;
        // §22.1.4 String exotic — `length` and integer-indexed
        // entries are own *non-writable*, *non-configurable*
        // properties. Install them with that descriptor so the
        // strict-mode `Set(O, idx, V, true)` paths in
        // Array.prototype.{push, unshift, splice, ...} throw
        // TypeError instead of silently mutating the wrapper.
        // `enumerable: true` matches §22.1.5.5 step 6.
        const ro_flags = ObjMod.PropertyFlags{
            .writable = false,
            .enumerable = false, // length is non-enumerable
            .configurable = false,
        };
        const idx_flags = ObjMod.PropertyFlags{
            .writable = false,
            .enumerable = true,
            .configurable = false,
        };
        // §22.1.4.4 [[GetOwnProperty]] — `length` and the indexed
        // own properties report UTF-16 code-unit positions, not
        // WTF-8 byte offsets. Walk the code-unit view of `s.flatBytes()`.
        const cu_len = utf16_mod.lengthInCodeUnits(s.flatBytes());
        w.setWithFlags(realm.allocator, "length", Value.fromInt32(@intCast(cu_len)), ro_flags) catch return error.OutOfMemory;
        var idx: usize = 0;
        while (idx < cu_len) : (idx += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            // Decode the code unit at `idx` and re-encode as a
            // single-unit WTF-8 string for the wrapper slot. This
            // splits a supplementary code point into two distinct
            // entries (lead at i, trail at i+1).
            const cu = utf16_mod.codeUnitAt(s.flatBytes(), idx) orelse 0xFFFD;
            var cu_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer cu_buf.deinit(realm.allocator);
            utf16_mod.appendCodeUnitAsWtf8(realm.allocator, &cu_buf, cu) catch return error.OutOfMemory;
            const ch = realm.heap.allocateString(cu_buf.items) catch return error.OutOfMemory;
            const own_key = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            w.setWithFlags(realm.allocator, own_key.flatBytes(), Value.fromString(ch), idx_flags) catch return error.OutOfMemory;
            // The index key is a heap-allocated JSString; anchor it
            // on the wrapper so GC can't free the key slice.
            w.key_anchors.append(realm.allocator, own_key) catch return error.OutOfMemory;
        }
        return w;
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        // §7.1.18 ToObject — Functions are already Objects;
        // ideally we'd return the function itself. Cynic's
        // JSFunction and JSObject are distinct heap structs, so
        // Array.prototype.* helpers (typed `*JSObject`) can't
        // address the function directly. Mirror the function's
        // own data properties (including the synthesized
        // `length` / `name` that §10.2.4 installs into
        // `properties` at function-creation time) into a
        // wrapper so read-only Array.prototype.X.call(fn, …)
        // observes `length` and `fn[i]` per spec.
        const w = realm.heap.allocateObject() catch return error.OutOfMemory;
        // Inherit the function's proto chain so `obj instanceof
        // Function` succeeds inside Array.prototype.X callbacks
        // (Sputnik 15.4.4.x-1-9 family). The function's `proto`
        // slot points at `%Function.prototype%` (or a user-
        // subclassed proto), exactly what the wrapper needs.
        realm.heap.setObjectPrototype(w, fn_obj.proto);
        var it = fn_obj.properties.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // §10.2.4 — `length` / `name` on functions are
            // `{writable:false, enumerable:false, configurable:true}`.
            // Mirror the function's per-key flags so callers like
            // `Array.prototype.shift.call(fn)` (§23.1.3.25 step 5
            // Set(O, "length", 0, true)) hit the writable=false
            // gate and throw TypeError as the spec requires.
            const flags = fn_obj.property_flags.get(key) orelse ObjMod.PropertyFlags.default;
            w.setWithFlags(realm.allocator, key, entry.value_ptr.*, flags) catch return error.OutOfMemory;
        }
        return w;
    }
    // Number / boolean / symbol / bigint — wrap with no own
    // properties; the wrapper's prototype chain (Number /
    // Boolean / Symbol / BigInt prototype) supplies inherited
    // methods. The wrapper has no `length`, so iterating
    // Array.prototype.* over a wrapped number reads length 0
    // and the loop exits — matching real engines.
    const w = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(w, lookupPrimitivePrototype(realm, this_value) orelse realm.intrinsics.object_prototype);
    // §6.1.6.1 Number wrapper / §6.1.5 BigInt / §6.1.3 Boolean —
    // stash the primitive in `boxed_primitive` so
    // `Number.prototype.toString` / `.valueOf` (and the matching
    // Boolean / BigInt methods) can recover the underlying value
    // for `new Object(42).toString()` style coercion.
    if (this_value.isInt32() or this_value.isDouble() or this_value.isBool() or
        heap_mod.isSymbol(this_value) or heap_mod.isBigInt(this_value))
    {
        realm.heap.setBoxedPrimitive(w, this_value);
    }
    return w;
}

/// Find the matching `<Kind>.prototype` for a primitive
/// receiver. Returns `null` on miss; caller falls back to
/// `%Object.prototype%`. Walks `realm.globals` because the
/// Number / Boolean / etc. prototypes aren't pinned on
/// `Intrinsics` (only the ones the runtime fast-paths reach).
pub fn lookupPrimitivePrototype(realm: *Realm, v: Value) ?*JSObject {
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
    // §10.5.5 Proxy [[Get]] — when `obj` is a Proxy (or a Proxy
    // whose target is itself a Proxy), the handler's `get` trap
    // must fire BEFORE walking the prototype chain. Without this,
    // an iterator built off a Proxy (`for-of new Proxy([1,2,3], {})`)
    // saw `length === undefined` because the proxy has no own
    // `length` and the trapless fall-through never reached the
    // wrapped array.
    if (obj.proxy_target != null or obj.proxy_revoked) {
        const proxy_mod = @import("builtins/proxy.zig");
        var cur_proxy = obj;
        while (cur_proxy.proxy_target != null or cur_proxy.proxy_revoked) {
            const r = try proxy_mod.nativeProxyGet(realm, cur_proxy, key, heap_mod.taggedObject(obj));
            switch (r) {
                .value => |v| return v,
                .fallthrough => |t| {
                    if (t == cur_proxy) break;
                    cur_proxy = t;
                },
            }
        }
        // The walk fell out of all proxy layers onto a plain target;
        // do an ordinary chain lookup on that target so accessors /
        // indexed-storage / prototype walks all fire.
        return getPropertyChain(realm, cur_proxy, key);
    }
    var cur: ?*JSObject = obj;
    while (cur) |o| {
        if (o.getAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const lantern = @import("lantern/interpreter.zig");
                const outcome = lantern.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedObject(obj), &[_]Value{}) catch |err| switch (err) {
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
        // §10.4.5 Integer-Indexed Exotic [[Get]] — for a typed-array
        // numeric index, read from the backing buffer directly
        // (live length on length-tracking views over a resizable
        // buffer). Lookup terminates at the TA — no proto-chain
        // fallthrough for the numeric form. Out-of-bounds reads
        // return undefined per ES2024 IntegerIndexedElementGet.
        if (o.getTypedView()) |tv| {
            if (std.fmt.parseInt(usize, key, 10)) |idx_u| {
                if (tv.viewed.getArrayBuffer()) |buf| {
                    const elem_size = tv.kind.elementSize();
                    const live_len: usize = if (tv.length_tracking) blk: {
                        if (tv.byte_offset > buf.len) break :blk 0;
                        break :blk (buf.len - tv.byte_offset) / elem_size;
                    } else blk: {
                        if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
                        break :blk tv.length;
                    };
                    if (idx_u < live_len) {
                        const byte_pos = tv.byte_offset + idx_u * elem_size;
                        if (byte_pos + elem_size <= buf.len) {
                            return readTypedElement(realm, buf, tv.kind, byte_pos);
                        }
                    }
                }
                return Value.undefined_;
            } else |_| {}
        }
        if (o.ownDataLookup(key)) |v| return v;
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
pub fn toLengthValue(realm: *Realm, v: Value) NativeError!i64 {
    return toLengthValuePropagating(realm, v);
}

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
        const d = std.fmt.parseFloat(f64, s.flatBytes()) catch return 0;
        if (std.math.isNan(d) or d <= 0) return 0;
        return doubleToI64Saturating(d);
    }
    if (heap_mod.valueAsSymbol(v) != null) return throwTypeError(realm, "Cannot convert a Symbol value to a number");
    // §7.1.4 ToNumber step 5 — BigInt → TypeError. Array.fromAsync /
    // Array.from on `{ length: 1n }` must reject with TypeError per
    // §23.1.2.1 step 6 (LengthOfArrayLike → ToLength → ToNumber).
    if (heap_mod.isBigInt(v)) return throwTypeError(realm, "Cannot convert a BigInt value to a number");
    // §7.1.4 ToNumber step 6 — Object: ToPrimitive(arg, hint
    // "number") which invokes `@@toPrimitive` / `valueOf` /
    // `toString` in that order. Any throw propagates. Routing
    // through the shared `toPrimitive` helper ensures
    // `@@toPrimitive` (with its hint-string argument) fires per
    // spec rather than being skipped for the direct valueOf /
    // toString fallback (the `array-like-objects-poisoned-length`
    // family pins a `Symbol.toPrimitive` thrower).
    if (heap_mod.valueAsPlainObject(v) != null) {
        const prim = try toPrimitive(realm, v, .number);
        return toLengthValuePropagating(realm, prim);
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

/// Range-checked clamp that sets `realm.pending_exception` to a
/// real `RangeError` before unwinding. Prefer this over the bare
/// `clampArrayLength` so spec fixtures see the right error class.
pub fn clampArrayLengthR(realm: *Realm, len: i64) NativeError!i64 {
    if (len < 0) return 0;
    if (len > max_iter_length) {
        const ex = newRangeError(realm, "Invalid array length") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
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

pub fn throwSyntaxError(realm: *Realm, msg: []const u8) NativeError {
    const ex = newSyntaxError(realm, msg) catch return error.OutOfMemory;
    return throwNative(realm, ex);
}

/// Convenience: throw a real `ReferenceError(msg)` from a native.
/// Used by §9.4.6.7 Module Namespace [[Get]] when the source-module
/// binding is still uninitialised — `GetBindingValue(N, true)`
/// throws ReferenceError under the strict flag the namespace
/// [[Get]] hard-codes.
pub fn throwReferenceError(realm: *Realm, msg: []const u8) NativeError {
    const ex = newReferenceError(realm, msg) catch return error.OutOfMemory;
    return throwNative(realm, ex);
}

/// Native-side cooperative interrupt + budget poll. Long-running
/// builtin loops (`Array.prototype.{map, filter, reduce}`,
/// `String.prototype.{repeat, replace}`, regex matchers, large
/// JSON parse / stringify) call this every ~1024 iterations so
/// a host-side watchdog or step-budget host interrupts even
/// when no JS opcodes are dispatching. V8 / JSC / SpiderMonkey
/// do the same in their builtin implementations.
///
/// Returns `error.NativeThrew` (with `realm.pending_exception`
/// set) when the interrupt fires or the step budget runs out,
/// or `error.OutOfMemory` if synthesising the error itself
/// fails. Cheap on the no-op path — one atomic load + one
/// integer compare.
pub fn checkInterruptInNative(realm: *Realm) NativeError!void {
    if (realm.interrupt.load(.acquire)) {
        realm.clearInterrupt();
        const ex = newRangeError(realm, "execution interrupted") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    if (realm.step_budget == 0) {
        const ex = newRangeError(realm, "interpreter step budget exhausted") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
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
    realm.heap.setFunctionPrototype(fresh, old_fn.prototype);
    if (fresh.prototype) |p| {
        try p.set(realm.allocator, "constructor", heap_mod.taggedFunction(fresh));
    }
    // Re-apply the §17 non-writable-prototype default that
    // `installStubConstructor` set on the original function; the
    // fresh JSFunction has a clean `property_flags` map otherwise.
    try fresh.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    try realm.globals.put(realm.allocator, name, heap_mod.taggedFunction(fresh));
}

fn stringConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §22.1.1.1 step 2.a — `String(symbol)` called as a function
    // (no NewTarget) yields SymbolDescriptiveString, *not*
    // TypeError. The `new String(symbol)` form still ToString's
    // through.
    const called_as_new = heap_mod.valueAsPlainObject(this_value) != null;
    const primitive: Value = if (args.len == 0) blk: {
        const s = realm.heap.allocateString("") catch return error.OutOfMemory;
        break :blk Value.fromString(s);
    } else if (!called_as_new and heap_mod.valueAsSymbol(args[0]) != null) blk: {
        const sym = heap_mod.valueAsSymbol(args[0]).?;
        const desc: []const u8 = sym.description orelse "";
        const formatted = std.fmt.allocPrint(realm.allocator, "Symbol({s})", .{desc}) catch return error.OutOfMemory;
        defer realm.allocator.free(formatted);
        const s = realm.heap.allocateString(formatted) catch return error.OutOfMemory;
        break :blk Value.fromString(s);
    } else blk: {
        const s = try stringifyArg(realm, args[0]);
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
        realm.heap.setBoxedPrimitive(inst, primitive);
        // Also pin in the typed slot so
        // `String.prototype.toString` / `.valueOf` can unbox in
        // O(1) without an isString discriminator dance.
        if (primitive.isString()) {
            const ps: *JSString = @ptrCast(@alignCast(primitive.asString()));
            realm.heap.setBoxedString(inst, ps) catch return error.OutOfMemory;
            // §22.1.4 String exotic — instances have own `length`
            // and indexed slots `[0]..[length-1]`, all
            // non-writable / non-configurable per §10.4.3.4. Without
            // these `new String("abc").length` was undefined and
            // any iteration / index-access against the wrapper
            // failed.
            // §22.1.4.4 — `length` and indexed entries are counted
            // and indexed in UTF-16 code units, not WTF-8 bytes.
            const cu_len = utf16_mod.lengthInCodeUnits(ps.flatBytes());
            inst.setWithFlags(realm.allocator, "length", Value.fromInt32(@intCast(cu_len)), .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            }) catch return error.OutOfMemory;
            var ibuf: [24]u8 = undefined;
            var ci: usize = 0;
            while (ci < cu_len) : (ci += 1) {
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{ci}) catch unreachable;
                const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                const cu = utf16_mod.codeUnitAt(ps.flatBytes(), ci) orelse 0xFFFD;
                var cu_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer cu_buf.deinit(realm.allocator);
                utf16_mod.appendCodeUnitAsWtf8(realm.allocator, &cu_buf, cu) catch return error.OutOfMemory;
                const ch = realm.heap.allocateString(cu_buf.items) catch return error.OutOfMemory;
                inst.setWithFlags(realm.allocator, owned.flatBytes(), Value.fromString(ch), .{
                    .writable = false,
                    .enumerable = true,
                    .configurable = false,
                }) catch return error.OutOfMemory;
                // Anchor the heap-allocated index key on the wrapper
                // so a GC sweep can't free the key slice out from
                // under `wrapper[i]` lookups.
                inst.key_anchors.append(realm.allocator, owned) catch return error.OutOfMemory;
            }
        }
        return this_value; // ConstructResult will keep it
    }
    return primitive;
}

fn numberConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §21.1.1.1 step 1 — `Number(value)`. ToNumeric, then if the
    // result is a BigInt convert to Number via the spec's
    // 𝔽(ℝ(prim)) (the BigInt's mathematical value as a double).
    // Bare `coerceToNumber` would have rejected BigInt (NaN), which
    // breaks the common `Number(10n)` idiom.
    const primitive: Value = blk: {
        if (args.len == 0) break :blk Value.fromInt32(0);
        const arg = args[0];
        if (heap_mod.valueAsBigInt(arg)) |bi| {
            break :blk Value.fromDouble(bi.toF64());
        }
        const prim = try toPrimitive(realm, arg, .number);
        if (heap_mod.valueAsBigInt(prim)) |bi| {
            break :blk Value.fromDouble(bi.toF64());
        }
        break :blk try toNumber(realm, prim);
    };
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        realm.heap.setBoxedPrimitive(inst, primitive);
        return this_value;
    }
    return primitive;
}

fn booleanConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const primitive: Value = if (args.len == 0) Value.false_ else Value.fromBool(toBoolean(args[0]));
    if (heap_mod.valueAsPlainObject(this_value)) |inst| {
        realm.heap.setBoxedPrimitive(inst, primitive);
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
        return stringToNumber(s.flatBytes());
    }
    return Value.fromDouble(std.math.nan(f64));
}

/// §7.1.4.1.1 StringToNumber — full StringNumericLiteral grammar
/// (StrWhiteSpace, NumericLiteralBase, decimal exponent). Rejects
/// the NumericLiteralSeparator (`1_000`) which the syntactic
/// numeric literal accepts but the runtime ToNumber does not.
pub fn stringToNumber(bytes: []const u8) Value {
    // §12.6 StrWhiteSpace covers the full Unicode whitespace set:
    // ZWNBSP (FEFF), every USP category Zs (space separator)
    // codepoint, plus LF / CR / LS (2028) / PS (2029). Trim them
    // by codepoint, not byte, so multibyte ws (NBSP, OGHAM space
    // mark, EN QUAD…) is handled.
    const trimmed = trimStrWhiteSpace(bytes);
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
    // §7.1.4.1.1 step 2 — `Infinity` is the only case-sensitive
    // literal accepted. Zig's `parseFloat` lower-cases `inf` /
    // `infinity` / `iNf`; reject those manually so
    // `Number("INFINITY")` is NaN, not Infinity.
    const inf_body = if (trimmed[0] == '+' or trimmed[0] == '-') trimmed[1..] else trimmed;
    if (inf_body.len > 0 and (inf_body[0] == 'I' or inf_body[0] == 'i')) {
        // The literal must be exactly "Infinity" — anything else
        // (case-shifted variants, `inf`, `INF`, `Inf`) is NaN.
        if (!std.mem.eql(u8, inf_body, "Infinity")) {
            return Value.fromDouble(std.math.nan(f64));
        }
        return Value.fromDouble(if (trimmed[0] == '-') -std.math.inf(f64) else std.math.inf(f64));
    }
    const d = std.fmt.parseFloat(f64, trimmed) catch return Value.fromDouble(std.math.nan(f64));
    return Value.fromDouble(d);
}

/// §12.6 StrWhiteSpace. Trim leading + trailing characters from
/// `bytes` whose code points are in the Unicode whitespace /
/// line-terminator set per §12.6 / §12.5 (LineTerminators).
fn trimStrWhiteSpace(bytes: []const u8) []const u8 {
    var lo: usize = 0;
    while (lo < bytes.len) {
        const cp_len = utf8DecodeLen(bytes[lo..]) catch break;
        const cp = utf8DecodeCp(bytes[lo .. lo + cp_len]) catch break;
        if (!isStrWhiteSpace(cp)) break;
        lo += cp_len;
    }
    var hi: usize = bytes.len;
    while (hi > lo) {
        // Walk backwards by one UTF-8 codepoint.
        var start = hi - 1;
        while (start > lo and (bytes[start] & 0xC0) == 0x80) start -= 1;
        const cp = utf8DecodeCp(bytes[start..hi]) catch break;
        if (!isStrWhiteSpace(cp)) break;
        hi = start;
    }
    return bytes[lo..hi];
}

fn utf8DecodeLen(bytes: []const u8) !usize {
    const n = try std.unicode.utf8ByteSequenceLength(bytes[0]);
    return @as(usize, n);
}

fn utf8DecodeCp(bytes: []const u8) !u21 {
    return std.unicode.utf8Decode(bytes);
}

fn isStrWhiteSpace(cp: u21) bool {
    return switch (cp) {
        // ASCII whitespace + LF / CR / VT / FF.
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        // NBSP / OGHAM SPACE MARK / EN QUAD .. HAIR SPACE /
        // LINE SEPARATOR / PARAGRAPH SEPARATOR /
        // NARROW NO-BREAK SPACE / MEDIUM MATH SPACE /
        // IDEOGRAPHIC SPACE / ZWNBSP.
        0xA0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

pub const ToPrimitiveHint = enum { default, number, string };

/// §7.1.1 ToPrimitive — coerce a value to a primitive, consulting
/// `Symbol.toPrimitive` (well-known key `@@toPrimitive`) if the
/// receiver is an object. Falls through to OrdinaryToPrimitive
/// (`valueOf` then `toString`, hint-ordered) per §7.1.1.1.
/// Primitive inputs return as-is.
pub fn toPrimitive(realm: *Realm, value: Value, hint: ToPrimitiveHint) NativeError!Value {
    if (!value.isObject()) return value;
    const interp = @import("lantern/interpreter.zig");

    // §7.1.1.1 OrdinaryToPrimitive maps "default"→"number" for
    // non-Date objects, but the @@toPrimitive trap receives the
    // raw hint string verbatim — "default", "number", or "string".
    const hint_str: []const u8 = switch (hint) {
        .default => "default",
        .number => "number",
        .string => "string",
    };
    if (heap_mod.valueAsPlainObject(value)) |obj| {
        // Symbol.toPrimitive override. Use `getPropertyChain` so
        // an accessor `get [Symbol.toPrimitive]() {…}` fires
        // (fixtures install poisoned getters and assert the
        // throw propagates). A plain data-slot lookup would miss
        // those.
        const exotic = getPropertyChain(realm, obj, "@@toPrimitive") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        // §7.1.1 step 2.b-c — GetMethod(O, @@toPrimitive). Per
        // §7.3.10, if `exotic` is neither undefined nor null and
        // is not Callable, throw a TypeError. Silently falling
        // through to OrdinaryToPrimitive would swallow the abrupt
        // (e.g. a class field key `[obj]` where `obj.Symbol.
        // toPrimitive = 42` must throw, not coerce via toString).
        const exotic_present = !exotic.isUndefined() and !exotic.isNull();
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
        } else if (exotic_present) {
            // §7.3.10 GetMethod — non-undefined / non-null but
            // not Callable is a TypeError. Don't silently fall
            // through to OrdinaryToPrimitive.
            return throwTypeError(realm, "Symbol.toPrimitive must be callable");
        }
        // OrdinaryToPrimitive: `valueOf` then `toString` for
        // number/default hint; reverse for string. `getPropertyChain`
        // fires inherited or accessor-installed getters — fixtures
        // like `trimStart/this-value-object-tostring-call-err.js`
        // install `get toString() { throw ... }` and expect the
        // getter throw to propagate.
        const first_name: []const u8 = if (hint == .string) "toString" else "valueOf";
        const second_name: []const u8 = if (hint == .string) "valueOf" else "toString";
        for ([_][]const u8{ first_name, second_name }) |name| {
            const method = getPropertyChain(realm, obj, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
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
    // §7.1.1 OrdinaryToPrimitive for a callable Function — same
    // shape as the plain-object path, but Cynic stores functions in
    // a separate value family. Symbols / BigInts are primitives and
    // exit at the top check; they never reach this branch.
    if (heap_mod.valueAsFunction(value)) |fn_obj| {
        // GetMethod(@@toPrimitive) — Function objects don't usually
        // expose it but a user can `defineProperty(fn, @@toPrimitive,
        // …)` to install one. Read via the function's data + chain.
        const exotic = fn_obj.get("@@toPrimitive");
        const exotic_present = !exotic.isUndefined() and !exotic.isNull();
        if (heap_mod.valueAsFunction(exotic)) |trap| {
            const hint_v = realm.heap.allocateString(hint_str) catch return error.OutOfMemory;
            const args = [_]Value{Value.fromString(hint_v)};
            const outcome = interp.callJSFunction(realm.allocator, realm, trap, value, &args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| {
                    if (heap_mod.isJSObject(v)) return throwTypeError(realm, "Symbol.toPrimitive must return a primitive value");
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        } else if (exotic_present) {
            return throwTypeError(realm, "Symbol.toPrimitive must be callable");
        }
        // OrdinaryToPrimitive — `valueOf` then `toString` (number/default)
        // or vice versa (string). For an ordinary Function, only
        // `toString` is meaningful (inherited from
        // `%Function.prototype.toString%`), but a user-installed
        // `valueOf` (own or via the proto chain) should still fire
        // first per spec.
        const first_name: []const u8 = if (hint == .string) "toString" else "valueOf";
        const second_name: []const u8 = if (hint == .string) "valueOf" else "toString";
        for ([_][]const u8{ first_name, second_name }) |name| {
            const method = fn_obj.get(name);
            if (heap_mod.valueAsFunction(method)) |m_fn| {
                const outcome = interp.callJSFunction(realm.allocator, realm, m_fn, value, &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (!heap_mod.isJSObject(v)) return v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
        }
        return throwTypeError(realm, "Cannot convert function to primitive value");
    }
    // Symbols / BigInts already exit at the top `!isObject()` check.
    return value;
}

/// §7.1.4 ToNumber — like `coerceToNumber` but consults
/// `Symbol.toPrimitive` / `valueOf` / `toString` for object
/// receivers. Returns either an int32 or double Value.
pub fn toNumber(realm: *Realm, v: Value) NativeError!Value {
    const prim = try toPrimitive(realm, v, .number);
    // §7.1.4 ToNumber step 4 — Symbol / BigInt operands throw
    // TypeError (the silent coerceToNumber path returns NaN
    // for Symbol, which masks the spec-mandated throw).
    if (heap_mod.valueAsSymbol(prim) != null) {
        return throwTypeError(realm, "Cannot convert a Symbol value to a number");
    }
    if (heap_mod.valueAsBigInt(prim) != null) {
        return throwTypeError(realm, "Cannot convert a BigInt value to a number");
    }
    return coerceToNumber(prim);
}

// ── Equality helpers ────────────────────────────────────────────────────────

pub fn strictEqualsLite(a: Value, b: Value) bool {
    // §7.2.16 IsStrictlyEqual / §6.1.6.1.13 Number::equal —
    // for two Numbers, defer to IEEE-754 `==`, which:
    //   • returns false when either operand is NaN (even if both
    //     are the same NaN bit pattern);
    //   • returns true for `+0.0 == -0.0` despite differing sign
    //     bits — this is the case the prior `a.bits == b.bits`
    //     fast path got wrong on Float32Array / Float64Array
    //     fixtures (indexOf/lastIndexOf strict-comparison.js).
    if (a.isDouble() and b.isDouble()) return a.asDouble() == b.asDouble();
    // Cross-type int vs double comparison (Number::equal operates
    // on the mathematical value). IEEE `==` also handles the NaN
    // case (the Double side may be NaN; comparison yields false).
    if (a.isInt32() and b.isDouble()) return @as(f64, @floatFromInt(a.asInt32())) == b.asDouble();
    if (a.isDouble() and b.isInt32()) return a.asDouble() == @as(f64, @floatFromInt(b.asInt32()));
    if (a.bits == b.bits) return true;
    if (a.isString() and b.isString()) {
        const sa: *JSString = @ptrCast(@alignCast(a.asString()));
        const sb: *JSString = @ptrCast(@alignCast(b.asString()));
        return std.mem.eql(u8, sa.flatBytes(), sb.flatBytes());
    }
    // §6.1.6.2.13 BigInt::equal — compare mathematical values.
    // Two distinct JSBigInt allocations with the same value pass
    // strict equality.
    if (heap_mod.valueAsBigInt(a)) |ba| {
        if (heap_mod.valueAsBigInt(b)) |bb| {
            return @import("bigint.zig").equals(
                .{ .sign = ba.sign, .limbs = ba.limbs },
                .{ .sign = bb.sign, .limbs = bb.limbs },
            );
        }
    }
    return false;
}

/// §7.2.11 SameValueZero — like StrictEquality except both NaNs
/// are equal and +0 / -0 are equal (the distinguishing pair
/// vs §7.2.10 SameValue).  Used by Array / TypedArray `includes`,
/// Set / Map key lookup, and a handful of other spots.
pub fn sameValueZero(a: Value, b: Value) bool {
    // Number-vs-Number rule: collapse +0 and -0; equate NaN
    // with NaN. Mixed int / double routes through the float
    // comparison so the IEEE rule applies uniformly. Non-numeric
    // cases fall through to strictEqualsLite, which already handles
    // strings / BigInts / by-identity equality (and was hardened in
    // commit 6517db4 so NaN never equals itself there).
    const a_d: ?f64 = if (a.isInt32()) @floatFromInt(a.asInt32()) else if (a.isDouble()) a.asDouble() else null;
    const b_d: ?f64 = if (b.isInt32()) @floatFromInt(b.asInt32()) else if (b.isDouble()) b.asDouble() else null;
    if (a_d != null and b_d != null) {
        const da = a_d.?;
        const db = b_d.?;
        if (std.math.isNan(da) and std.math.isNan(db)) return true;
        return da == db;
    }
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
/// §6.1.6.1.13 Number::toString — exponent formatting. The
/// Zig `{e}` format yields `1e22` / `1e-6`; the JS spec wants
/// `1e+22` / `1e-6` (positive exponents get an explicit `+`).
/// Some Zig versions also pad zero-byte exponents (`1e0`) and
/// emit the sign differently. Normalise to spec form using
/// `buf` as scratch.
pub fn normalizeExponentPub(buf: []u8, raw: []const u8) []const u8 {
    return normalizeExponent(buf, raw);
}

fn normalizeExponent(buf: []u8, raw: []const u8) []const u8 {
    const e_idx = std.mem.indexOfScalar(u8, raw, 'e') orelse return raw;
    const exp_start = e_idx + 1;
    if (exp_start >= raw.len) return raw;
    // If the next char is `+` or `-`, signed; otherwise add `+`.
    if (raw[exp_start] == '+' or raw[exp_start] == '-') return raw;
    // Insert `+` after `e`. Slide tail right by one byte using
    // the caller-supplied buffer (raw points into `buf`).
    if (raw.len + 1 > buf.len) return raw;
    var i: usize = raw.len;
    while (i > exp_start) : (i -= 1) buf[i] = buf[i - 1];
    buf[exp_start] = '+';
    return buf[0 .. raw.len + 1];
}

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
            // §6.1.6.2.21 BigInt::toString(10).
            const buf = @import("bigint.zig").toStringAlloc(realm.allocator, bi, 10) catch return error.OutOfMemory;
            defer realm.allocator.free(buf);
            return realm.heap.allocateString(buf) catch return error.OutOfMemory;
        }
        // §7.1.17 ToString step 5 — `Let primValue be ?
        // ToPrimitive(argument, string)`. Run this BEFORE any
        // function-specific short-circuit, so a user-installed
        // `valueOf` / `toString` on the function object (or a
        // monkey-patched `Function.prototype.toString`) fires
        // per spec. The Function.prototype.toString fallback
        // formatting lives in `builtins/function.zig` and is
        // reached via the normal ToPrimitive → toString lookup
        // path. Test262 S15.5.2.1_A1_T8 / _T11 cover the case
        // where the function's `valueOf` / `toString` override
        // is observable through `new String(fn)`.
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
                const raw = std.fmt.bufPrint(&buf, "{e}", .{d}) catch unreachable;
                break :blk normalizeExponent(&buf, raw);
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
/// Name-aware write: dispatches to ToUint8Clamp for
/// Uint8ClampedArray, regular ToInt*/ToUint*/IEEE writes otherwise.
/// Use this from any [[Set]] / IntegerIndexedElementSet path —
/// `writeTypedElement` on its own treats kind=.uint8 as Uint8Array
/// (modular ToUint8) and would silently corrupt clamped arrays.
pub const writeTypedElementForView = @import("builtins/typed_array.zig").writeTypedElementForView;

// Iterator factory methods live in `builtins/collections.zig` —
// re-export so `builtins/typed_array.zig` and other call sites
// can keep their `intrinsics.arrayLike*Method` imports.
pub const arrayLikeValuesMethod = @import("builtins/collections.zig").arrayLikeValuesMethod;
pub const arrayLikeKeysMethod = @import("builtins/collections.zig").arrayLikeKeysMethod;
pub const arrayLikeEntriesMethod = @import("builtins/collections.zig").arrayLikeEntriesMethod;
pub const typedArrayValuesMethod = @import("builtins/collections.zig").typedArrayValuesMethod;
pub const typedArrayKeysMethod = @import("builtins/collections.zig").typedArrayKeysMethod;
pub const typedArrayEntriesMethod = @import("builtins/collections.zig").typedArrayEntriesMethod;

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

/// §19.2.1 eval(x). Cynic is strict-only and explicitly does NOT
/// ship runtime code construction (per AGENTS.md — `eval()`,
/// `new Function(string)`, etc. are out permanently). The binding
/// must exist on globalThis though so `typeof eval === "function"`
/// and `eval === null` (Sputnik S10.2.3_* uses both shapes) don't
/// fall through to ReferenceError. Returns the argument unchanged
/// for non-string operands per §19.2.1 step 1; throws SyntaxError
/// on String operands so callers see a spec-flavored failure
/// rather than silent success.
fn globalEvalNotSupported(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = if (args.len > 0) args[0] else Value.undefined_;
    if (!arg.isString()) return arg;
    return throwSyntaxError(realm, "Cynic does not support eval() of source strings");
}
