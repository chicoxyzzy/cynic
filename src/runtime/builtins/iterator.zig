//! §27.1.4 Iterator (TC39 stage-4 helpers). Installs the
//! `Iterator` global with `Iterator.from(iterable)` and a
//! prototype carrying `.map` / `.filter` / `.take` / `.drop` /
//! `.toArray` / `.forEach` / `.find` / `.some` / `.every` /
//! `.reduce`.
//!
//! Each helper that returns a new iterator (`.map`, `.filter`,
//! `.take`, `.drop`) builds a wrapper object whose `next` method
//! pulls from the source and applies the transform. Eagerly-
//! evaluated helpers (`.toArray`, `.forEach`, etc.) drain the
//! source.
//!
//! All helpers honour the §7.4.10 IteratorClose protocol via
//! `closeIteratorOnThrow` / `closeIteratorNormal`: callback
//! exceptions, non-object IteratorResult, and argument-validation
//! failures all close the underlying iterator before the throw
//! propagates. When the original completion is a throw, errors
//! from `return()` are swallowed (the original throw wins, per
//! step 4 of IteratorClose).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const IteratorHelperState = object_mod.IteratorHelperState;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "Iterator",
        .ctor = iteratorConstructor,
        .arity = 0,
        .set_home_object = false,
        // §27.1.4.5 / §27.1.4.6 — `Iterator.prototype.constructor`
        // and `Iterator.prototype[@@toStringTag]` are **accessor**
        // properties whose setter performs
        // SetterThatIgnoresPrototypeProperties. We install both
        // pairs below; suppress the default data-property setup
        // so the generic `installConstructor` doesn't shadow.
        .to_string_tag = null,
        .install_constructor_property = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §27.1.4.6 — `Iterator.prototype.constructor` accessor.
    try installIteratorPrototypeConstructorAccessor(realm, proto);
    // §27.1.4.5 — `Iterator.prototype[@@toStringTag]` accessor.
    try installIteratorPrototypeToStringTagAccessor(realm, proto);

    try installNativeMethod(realm, fn_obj, "from", iteratorFrom, 1);
    try installNativeMethod(realm, fn_obj, "concat", iteratorConcat, 0);
    // PRE-STAGE-4 PROPOSAL — `joint-iteration` (Stage 3 as of 2026-05).
    // `Iterator.zip(iterables)` and `Iterator.zipKeyed(iterables, options?)`
    // ship ahead of inclusion in a published edition; spec text may
    // still shift before Stage 4 advancement (semantics of the `mode`
    // option, padding behavior). Gated on the per-realm feature flag
    // so embedders / the `cynic` CLI need `--enable=joint-iteration`
    // (or `--enable-experimental`) to see the methods. The test262
    // harness flips every flag on at fixture init. Documented in
    // `docs/ROADMAP.md` under "Pre-Stage-4 proposals shipped".
    if (realm.feature_flags.contains(.joint_iteration)) {
        try installNativeMethod(realm, fn_obj, "zip", iteratorZip, 1);
        try installNativeMethod(realm, fn_obj, "zipKeyed", iteratorZipKeyed, 1);
    }

    try installNativeMethodOnProto(realm, proto, "map", iteratorMap, 1);
    try installNativeMethodOnProto(realm, proto, "filter", iteratorFilter, 1);
    try installNativeMethodOnProto(realm, proto, "flatMap", iteratorFlatMap, 1);
    try installNativeMethodOnProto(realm, proto, "take", iteratorTake, 1);
    try installNativeMethodOnProto(realm, proto, "drop", iteratorDrop, 1);
    try installNativeMethodOnProto(realm, proto, "toArray", iteratorToArray, 0);
    try installNativeMethodOnProto(realm, proto, "forEach", iteratorForEach, 1);
    try installNativeMethodOnProto(realm, proto, "find", iteratorFind, 1);
    try installNativeMethodOnProto(realm, proto, "some", iteratorSome, 1);
    try installNativeMethodOnProto(realm, proto, "every", iteratorEvery, 1);
    try installNativeMethodOnProto(realm, proto, "reduce", iteratorReduce, 1);
    // Iterators are themselves iterable.
    try installNativeMethodOnProto(realm, proto, "@@iterator", iteratorSymbolIterator, 0);

    // §22.2.9 / §27.1.3 — the RegExp-string iterator prototype is
    // built eagerly inside `builtins/string.zig:install` (which runs
    // before this one), so its `[[Prototype]]` was wired to
    // `%Object.prototype%` as a placeholder. Now that
    // `%IteratorPrototype%` exists, re-parent it so
    // `Object.getPrototypeOf(%RegExpStringIteratorPrototype%) ===
    // %IteratorPrototype%` (fixture `RegExpStringIteratorPrototype/
    // ancestry.js`).
    if (realm.intrinsics.regexp_string_iterator_prototype) |risp| {
        risp.prototype = proto;
    }
    // The string-iterator prototype is built lazily by
    // `ensureStringIteratorPrototype` (`builtins/collections.zig`),
    // which already reads `iteratorPrototypeOrObjectPrototypePub` —
    // but if `String.prototype[@@iterator]` was invoked before
    // `Iterator` was installed (e.g. during an early bootstrap
    // step) the lazy build would have cached `%Object.prototype%`.
    // Re-parent defensively for the same shape as above.
    if (realm.intrinsics.string_iterator_prototype) |sip| {
        sip.prototype = proto;
    }
    // §24.1.5.2 %MapIteratorPrototype% / §24.2.5.2 %SetIteratorPrototype%
    // — both are eagerly allocated in `collections.installMap` /
    // `installSet` (which run before this install) with a temporary
    // `%Object.prototype%` parent. Re-parent to `%IteratorPrototype%`
    // so deleting a Map/Set iterator's own `@@toStringTag` falls
    // through to `@@toStringTag === "Iterator"` one level up
    // (`built-ins/Object/prototype/toString/symbol-tag-{map,set}-builtin.js`).
    if (realm.intrinsics.map_iterator_prototype) |mip| {
        mip.prototype = proto;
    }
    if (realm.intrinsics.set_iterator_prototype) |sip| {
        sip.prototype = proto;
    }
}

// ── §27.1.4.5 / §27.1.4.6 — accessor pairs on Iterator.prototype ────────────

/// Install `Iterator.prototype.constructor` as an accessor pair.
/// Getter returns `%Iterator%`; setter performs
/// SetterThatIgnoresPrototypeProperties(%Iterator.prototype%,
/// "constructor", v). Matches `built-ins/Iterator/prototype/
/// constructor/{prop-desc,weird-setter}.js`.
fn installIteratorPrototypeConstructorAccessor(realm: *Realm, proto: *JSObject) !void {
    const getter = try realm.heap.allocateFunctionNative(iteratorPrototypeConstructorGet, 0, "get constructor");
    getter.proto = realm.intrinsics.function_prototype;
    const setter = try realm.heap.allocateFunctionNative(iteratorPrototypeConstructorSet, 1, "set constructor");
    setter.proto = realm.intrinsics.function_prototype;
    // §17 — built-in accessor properties: { enumerable: false,
    // configurable: true }.
    const entry = try proto.accessors.getOrPut(realm.allocator, "constructor");
    entry.value_ptr.* = .{ .getter = getter, .setter = setter };
    try proto.property_flags.put(realm.allocator, "constructor", .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
    // installConstructor left a data slot under "constructor" —
    // strip it so the accessor wins on lookup. (Even though
    // `install_constructor_property = false` now skips it, we
    // keep the cleanup for safety.)
    _ = proto.properties.swapRemove("constructor");
    proto.forgetKey("constructor");
}

/// Install `Iterator.prototype[@@toStringTag]` as an accessor
/// pair. Getter returns `"Iterator"`; setter performs
/// SetterThatIgnoresPrototypeProperties(%Iterator.prototype%,
/// @@toStringTag, v).
fn installIteratorPrototypeToStringTagAccessor(realm: *Realm, proto: *JSObject) !void {
    const getter = try realm.heap.allocateFunctionNative(iteratorPrototypeToStringTagGet, 0, "get [Symbol.toStringTag]");
    getter.proto = realm.intrinsics.function_prototype;
    const setter = try realm.heap.allocateFunctionNative(iteratorPrototypeToStringTagSet, 1, "set [Symbol.toStringTag]");
    setter.proto = realm.intrinsics.function_prototype;
    const entry = try proto.accessors.getOrPut(realm.allocator, "@@toStringTag");
    entry.value_ptr.* = .{ .getter = getter, .setter = setter };
    try proto.property_flags.put(realm.allocator, "@@toStringTag", .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
    _ = proto.properties.swapRemove("@@toStringTag");
    proto.forgetKey("@@toStringTag");
}

fn iteratorPrototypeConstructorGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    // §27.1.4.6 getter — returns %Iterator%.
    return realm.globals.get("Iterator") orelse Value.undefined_;
}

fn iteratorPrototypeConstructorSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const v = argOr(args, 0, Value.undefined_);
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const home = ctor.prototype orelse return throwTypeError(realm, "Iterator.prototype missing");
    try setterThatIgnoresPrototypeProperties(realm, this_value, home, "constructor", v);
    return Value.undefined_;
}

fn iteratorPrototypeToStringTagGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    // §27.1.4.5 getter — returns "Iterator".
    const s = realm.heap.allocateString("Iterator") catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn iteratorPrototypeToStringTagSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const v = argOr(args, 0, Value.undefined_);
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const home = ctor.prototype orelse return throwTypeError(realm, "Iterator.prototype missing");
    try setterThatIgnoresPrototypeProperties(realm, this_value, home, "@@toStringTag", v);
    return Value.undefined_;
}

/// §27.1.4.x SetterThatIgnoresPrototypeProperties(O, home, p, v):
///   1. If O is not Object → TypeError.
///   2. If SameValue(O, home) → TypeError (emulates assigning a
///      non-writable data property on `home`).
///   3. Let desc be ? O.[[GetOwnProperty]](p).
///   4. If desc is undefined → CreateDataPropertyOrThrow(O, p, v).
///   5. Else → Set(O, p, v, true).
fn setterThatIgnoresPrototypeProperties(realm: *Realm, this_value: Value, home: *JSObject, key: []const u8, v: Value) NativeError!void {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "SetterThatIgnoresPrototypeProperties: receiver is not an object");
    };
    if (obj == home) {
        return throwTypeError(realm, "Cannot assign to non-writable property on Iterator.prototype");
    }
    if (obj.hasOwn(key)) {
        // OrdinarySet honouring writability — bypass accessor
        // setters: the spec uses ? Set(O, p, v, true).
        const ok = obj.setIfWritable(realm.allocator, key, v) catch return error.OutOfMemory;
        if (!ok) {
            return throwTypeError(realm, "Cannot assign to read-only property");
        }
        return;
    }
    // CreateDataPropertyOrThrow — must throw if not extensible.
    if (!obj.extensible) {
        return throwTypeError(realm, "Cannot define property on non-extensible object");
    }
    obj.setWithFlags(realm.allocator, key, v, .{
        .writable = true,
        .enumerable = true,
        .configurable = true,
    }) catch return error.OutOfMemory;
}

fn iteratorConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.1.4.1 — abstract constructor. Throws when called as a
    // plain function (NewTarget is undefined) or when newTarget
    // is the Iterator function itself; otherwise (subclass
    // construction) returns the freshly allocated `this`.
    const inst = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "Iterator constructor requires 'new'");
    };
    // Cynic doesn't surface NewTarget to natives — approximate
    // by checking the receiver's [[Prototype]]: a direct
    // `new Iterator()` would have %Iterator.prototype% there,
    // a subclass has the subclass's prototype.
    const ctor_v = realm.globals.get("Iterator") orelse return this_value;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return this_value;
    if (inst.prototype == ctor.prototype) {
        return throwTypeError(realm, "Abstract class Iterator not directly constructable");
    }
    return this_value;
}

/// `Iterator.from(x)` — wrap any iterable in an Iterator instance.
/// §27.1.4.1 step 2 calls §7.4.6 GetIteratorFlattenable(`iterate`)
/// which: (a) calls `x[@@iterator]()` if present, otherwise
/// (b) treats `x` itself as an iterator if it carries a callable
/// `next` (the duck-typed-iterator path the
/// `from/get-next-method-only-once.js` family relies on).
fn iteratorFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // Try @@iterator first via the flattenable path. If the arg
    // carries `@@iterator` we call it; otherwise we treat the arg
    // itself as an iterator (returning it directly so wrapIterator
    // snapshots `arg.next` once, not an extra time).
    const inner = getIteratorFlattenable(realm, arg, false) catch |err| {
        if (err == error.NativeThrew) return error.NativeThrew;
        return throwTypeError(realm, "Iterator.from argument is not iterable");
    };
    // §27.1.4.1.1 step 4 — if `iteratorRecord.[[Iterator]]` already
    // has %Iterator.prototype% somewhere in its prototype chain,
    // return it directly. Generator instances (which extend
    // %GeneratorPrototype% → %IteratorPrototype% → %Iterator.prototype%)
    // hit this path: `Object.getPrototypeOf(Iterator.from(g()))` ===
    // %GeneratorPrototype%, not the wrap proto.
    if (heap_mod.valueAsPlainObject(inner)) |inner_obj| {
        const iter_ctor_v = realm.globals.get("Iterator");
        if (iter_ctor_v) |c_v| {
            if (heap_mod.valueAsFunction(c_v)) |c_fn| {
                const iter_proto = c_fn.prototype;
                var cur: ?*JSObject = inner_obj.prototype;
                while (cur) |p| : (cur = p.prototype) {
                    if (p == iter_proto) return inner;
                }
            }
        }
    }
    return wrapIterator(realm, inner);
}

/// §27.1.4.1.2 — lazily install %WrapForValidIteratorPrototype%.
/// Its proto is %Iterator.prototype% and it carries spec-mandated
/// `next` (delegates to wrapped iter's snapshotted next) and
/// `return` (calls wrapped iter's `return` via GetMethod, builds
/// a `{value: undefined, done: true}` if absent).
fn ensureWrapForValidIteratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.wrap_for_valid_iterator_prototype) |p| return p;
    const ctor_v = realm.globals.get("Iterator") orelse return error.OutOfMemory;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return error.OutOfMemory;
    const proto = try realm.heap.allocateObject();
    proto.prototype = ctor.prototype; // %Iterator.prototype%

    const next_fn = try realm.heap.allocateFunctionNative(wrappedNext, 0, "next");
    next_fn.has_construct = false;
    next_fn.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    const return_fn = try realm.heap.allocateFunctionNative(wrappedReturn, 0, "return");
    return_fn.has_construct = false;
    return_fn.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(return_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.wrap_for_valid_iterator_prototype = proto;
    return proto;
}

/// Wrap a raw iterator object (the kind `openIterator` returns)
/// in a fresh helper object whose prototype is
/// %WrapForValidIteratorPrototype%. The wrapper's `next` and
/// `return` delegate to the source iterator's methods.
fn wrapIterator(realm: *Realm, source: Value) NativeError!Value {
    // §7.4.6 step 6 — GetIteratorFlattenable reads `next` once
    // without a callability check (that happens lazily at
    // IteratorNext §7.4.3 step 1). Use `snapshotNextValue` so a
    // missing / non-callable `next` is deferred until the
    // wrapper's `next()` is actually invoked. `{ next: ... }`
    // omitted entirely is the `Iterator.from({})` shape — the
    // wrapper still constructs.
    const cached_next_v = try snapshotNextValue(realm, source);
    const proto = ensureWrapForValidIteratorPrototype(realm) catch return error.OutOfMemory;
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = proto;
    const state = realm.allocator.create(IteratorHelperState) catch return error.OutOfMemory;
    state.* = .{ .source = source, .next_fn = cached_next_v };
    wrap.iter_helper = state;
    return heap_mod.taggedObject(wrap);
}

/// §27.1.4.1.2.2 %WrapForValidIteratorPrototype%.return — calls
/// `GetMethod(iterated, "return")` and either forwards or returns
/// a synthesized done result.
fn wrappedReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // Step 2 — RequireInternalSlot(O, [[Iterated]]).
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WrapForValidIteratorPrototype.return called on non-object");
    const state = obj.iter_helper orelse return throwTypeError(realm, "WrapForValidIteratorPrototype.return called on incompatible receiver");
    const source = state.source;
    const src_obj = heap_mod.valueAsPlainObject(source) orelse return throwTypeError(realm, "wrapped iterator is not an object");
    // Step 5 — GetMethod(iterator, "return").
    const ret_v = try iterGet(realm, source, "return");
    if (ret_v.isUndefined() or ret_v.isNull()) {
        // Step 6 — return CreateIterResultObject(undefined, true).
        const res = realm.heap.allocateObject() catch return error.OutOfMemory;
        res.prototype = realm.intrinsics.object_prototype;
        res.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
        res.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
        return heap_mod.taggedObject(res);
    }
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return throwTypeError(realm, "wrapped iterator .return is not callable");
    _ = src_obj;
    // Step 7 — Return ? Call(returnMethod, iterator).
    const outcome = interpreter.callJSFunction(realm.allocator, realm, ret_fn, source, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

fn wrappedNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator next on non-object");
    const state = obj.iter_helper orelse return throwTypeError(realm, "Iterator next on non-helper object");
    const next_fn = try cachedNextFn(realm, obj, state.source);
    return invokeIterNextFn(realm, state.source, next_fn);
}

fn invokeIterNext(realm: *Realm, iter: Value) NativeError!Value {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "iterator is not an object");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator has no callable next");
    return invokeIterNextFn(realm, iter, next_fn);
}

/// §7.4.10 IteratorClose / GetIteratorDirect — once a helper has
/// snapshotted `iter.next` into its IteratorRecord, every step
/// dispatches through that snapshot rather than re-reading
/// `iter.next` (which would re-run a getter each step). Used by
/// the lazy-helper machinery below: each wrapper stores the
/// source iterator's `next` function once, at construction time,
/// so subsequent steps don't re-trigger the source's `get next`.
fn invokeIterNextFn(realm: *Realm, iter: Value, next_fn: *JSFunction) NativeError!Value {
    const out = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

/// §7.4.2 GetIteratorDirect step 2 — `Get(obj, "next")`. Returns
/// the read value WITHOUT a callability check (spec defers that
/// to §7.4.4 IteratorNext, which throws TypeError when the
/// stored next is not callable at step time). Called at every
/// helper-construction site so the wrapper's stored
/// `__cynic_iter_next_fn__` slot is populated up front. The
/// `get next()` accessor fires here exactly once.
fn snapshotNextValue(realm: *Realm, source: Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(source) == null) return throwTypeError(realm, "iterator is not an object");
    return iterGet(realm, source, "next");
}

/// Strict version that throws on non-callable. Used at terminal-
/// helper entry points (`toArray`, `forEach`, …) where the spec's
/// surrounding loop would have called §7.4.4 immediately anyway,
/// so reporting at snapshot time gives the same observable error.
fn snapshotNext(realm: *Realm, source: Value) NativeError!*JSFunction {
    const v = try snapshotNextValue(realm, source);
    return heap_mod.valueAsFunction(v) orelse return throwTypeError(realm, "iterator has no callable next");
}

/// Pull the cached next *value* out of a wrapper's slot and
/// coerce to a callable function — this is the §7.4.4
/// IteratorNext callability check. If the stored value isn't
/// callable, throw TypeError now (this is the "step time"
/// site the `this-non-callable-next.js` family probes). If the
/// slot is missing entirely (e.g. terminal helper called on a
/// raw user iterator), snapshot now.
fn cachedNextFn(realm: *Realm, wrapper: *JSObject, source: Value) NativeError!*JSFunction {
    if (wrapper.iter_helper) |state| {
        if (!state.next_fn.isUndefined()) {
            return heap_mod.valueAsFunction(state.next_fn) orelse return throwTypeError(realm, "iterator has no callable next");
        }
    }
    return snapshotNext(realm, source);
}

/// Accessor-aware [[Get]] on an iterator-result object: if a
/// getter is defined for `key` (own or on the proto chain), call
/// it with `this = recv` and surface any throw. Otherwise fall
/// back to the plain data lookup. Used so a throwing `done` /
/// `value` getter on a user IteratorResult propagates
/// (§7.4.6 IteratorComplete / §7.4.5 IteratorValue). Proxy-aware
/// — a `get` trap on the receiver (or anywhere on its target
/// chain) fires, so the proxy-iterator fixtures in
/// `built-ins/Iterator/from/*.js` observe each `Get(iter, …)`
/// the spec mandates.
fn iterGet(realm: *Realm, recv: Value, key: []const u8) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(recv) orelse return Value.undefined_;
    if (obj.proxy_target != null or obj.proxy_revoked) {
        const proxy_mod = @import("proxy.zig");
        var cur = obj;
        while (true) {
            const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, recv);
            switch (outcome) {
                .value => |v| return v,
                .fallthrough => |t| {
                    if (t == cur) return Value.undefined_;
                    if (t.proxy_target != null or t.proxy_revoked) {
                        cur = t;
                        continue;
                    }
                    return iterGetPlain(realm, t, key, recv);
                },
            }
        }
    }
    return iterGetPlain(realm, obj, key, recv);
}

/// Helper for `iterGet`: accessor-aware ordinary [[Get]] on a
/// non-Proxy object. Pulled out so the proxy-fallthrough path
/// can share the lookup. `this_for_getter` is the original
/// receiver — accessor getters fire with `this = recv` per
/// §10.1.8.1 step 5.
fn iterGetPlain(realm: *Realm, obj: *JSObject, key: []const u8, this_for_getter: Value) NativeError!Value {
    if (interpreter.lookupAccessor(obj, key)) |acc| {
        if (acc.getter) |getter| {
            const out = interpreter.callJSFunction(realm.allocator, realm, getter, this_for_getter, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            return switch (out) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
        }
        return Value.undefined_;
    }
    return obj.get(key);
}

fn iteratorSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

// ── Iterator-close protocol (§7.4.10) ──────────────────────────────────────

/// Call `iter.return()` and swallow any throw or absence. Used
/// when the surrounding completion is a throw — per §7.4.10
/// step 4, the original throw wins, so any error produced by
/// `return()` is dropped (along with any pending exception it
/// may have set on the realm).
fn closeIteratorSwallow(realm: *Realm, iter: Value) void {
    if (heap_mod.valueAsPlainObject(iter) == null) return;
    // Preserve pending_exception across the return-call: the
    // caller is mid-throw and the `error.NativeThrew` we'll
    // return next must carry that exception. `iterGet` honours
    // `get return` accessors; if reading itself throws, the
    // surrounding throw still wins, so swallow.
    const saved = realm.pending_exception;
    const ret_v = iterGet(realm, iter, "return") catch {
        realm.pending_exception = saved;
        return;
    };
    if (ret_v.isUndefined() or ret_v.isNull()) {
        realm.pending_exception = saved;
        return;
    }
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse {
        realm.pending_exception = saved;
        return;
    };
    const result = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter, &.{}) catch {
        realm.pending_exception = saved;
        return;
    };
    _ = result;
    realm.pending_exception = saved;
}

/// The callback chain returned `.thrown = ex`. Close the source,
/// stash `ex` into pending_exception so the caller's
/// `error.NativeThrew` carries the original throw forward, and
/// return that error. Centralises the swallow-on-throw idiom for
/// every callback-using helper.
fn callbackThrew(realm: *Realm, src: Value, ex: Value) NativeError {
    realm.pending_exception = ex;
    closeIteratorSwallow(realm, src);
    return error.NativeThrew;
}

/// Variant for the catch-side: `callJSFunction` returned a
/// Zig-level error (the native it called set pending_exception).
/// Preserve that pending exception across the close.
fn callbackErrored(realm: *Realm, src: Value) NativeError {
    closeIteratorSwallow(realm, src);
    return error.NativeThrew;
}

/// Call `iter.return()` and propagate any throw it produces (or
/// any throw that fires while reading the `return` property —
/// callers that need the property-read-throw path resolve it
/// before calling here). Used for normal-completion close paths
/// like `take(0)`-on-exhaustion or a direct `iterator.return()`.
fn closeIteratorPropagate(realm: *Realm, iter: Value) NativeError!void {
    if (heap_mod.valueAsPlainObject(iter) == null) return;
    // §7.4.10 step 5 — `GetMethod(iterator, "return")`. The
    // §10.1.8.1 [[Get]] respects accessors; a throwing
    // `get return` is an abrupt completion that must propagate
    // (`built-ins/Iterator/prototype/<helper>/get-return-method-throws.js`).
    const ret_v = try iterGet(realm, iter, "return");
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse {
        return throwTypeError(realm, "iterator return is not callable");
    };
    const out = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (out) {
        .value, .yielded => {},
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

/// Argument-validation entry point: `closable.map()` /
/// `.take(NaN)` etc. need to close the iterator before throwing
/// the validation TypeError/RangeError. The helper sets
/// `pending_exception` itself, then calls `return()` swallowing
/// errors so the validation throw wins.
fn throwAfterClose(realm: *Realm, this_value: Value, ex: Value) NativeError {
    realm.pending_exception = ex;
    closeIteratorSwallow(realm, this_value);
    return error.NativeThrew;
}

fn typeErrorAfterClose(realm: *Realm, this_value: Value, msg: []const u8) NativeError {
    const ex = intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
    return throwAfterClose(realm, this_value, ex);
}

fn rangeErrorAfterClose(realm: *Realm, this_value: Value, msg: []const u8) NativeError {
    const ex = intrinsics.newRangeError(realm, msg) catch return error.OutOfMemory;
    return throwAfterClose(realm, this_value, ex);
}

// ── Lazy helpers — return new iterator wrappers ─────────────────────────────

fn iteratorMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.map called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.map callback is not callable");
    }
    return buildLazy(realm, this_value, cb_v, mapNext);
}

fn iteratorFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.filter called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.filter predicate is not callable");
    }
    return buildLazy(realm, this_value, cb_v, filterNext);
}

/// §27.1.4.4 Iterator.prototype.flatMap. Same lazy shape as
/// `.map`/`.filter`, but the mapper's result is interpreted as an
/// iterable via §7.4.6 GetIteratorFlattenable(reject-strings) and
/// each of its values is yielded one at a time. State adds an
/// `__cynic_iter_active__` slot for the currently-open inner
/// iterator (undefined when the outer must be advanced next).
fn iteratorFlatMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.flatMap called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.flatMap mapper is not callable");
    }
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    // §27.1.4.1.1.4 step 3 — GetIteratorDirect snapshots `next` once.
    // Callability deferred to step time per §7.4.4.
    const cached_next_v = snapshotNextValue(realm, this_value) catch |err| {
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, this_value, ex);
        }
        return err;
    };
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    const state = realm.allocator.create(IteratorHelperState) catch return error.OutOfMemory;
    state.* = .{
        .source = this_value,
        .next_fn = cached_next_v,
        .payload = cb_v,
    };
    wrap.iter_helper = state;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrap)) catch return error.OutOfMemory;
    const next_fn = realm.heap.allocateFunctionNative(flatMapNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(flatMapReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

/// `wrapper.return()` for flatMap. Closes whichever iterator is
/// currently active: the inner if one is open (we'd otherwise
/// abandon mid-stream), then the outer source. First throw wins;
/// the second close runs in swallow mode so the original throw
/// propagates.
fn flatMapReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    const state = obj.iter_helper orelse return iterResult(realm, Value.undefined_, true);
    if (state.done) {
        return iterResult(realm, Value.undefined_, true);
    }
    state.done = true;
    const active = state.active;
    const src = state.source;
    if (heap_mod.valueAsPlainObject(active) != null) {
        // Close inner first; if it throws, swallow the outer close.
        closeIteratorPropagate(realm, active) catch |err| {
            closeIteratorSwallow(realm, src);
            return err;
        };
    }
    try closeIteratorPropagate(realm, src);
    return iterResult(realm, Value.undefined_, true);
}

fn flatMapNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "flatMap iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;

    const src = state.source;
    const outer_next = try cachedNextFn(realm, obj, src);
    const cb = heap_mod.valueAsFunction(state.payload) orelse return doneResult(realm);

    while (true) {
        // 1. If we have a currently-open inner iterator, pull from it.
        const active = state.active;
        if (heap_mod.valueAsPlainObject(active) != null) {
            const r = invokeIterNext(realm, active) catch |err| {
                state.done = true;
                // Inner threw — outer also needs closing per spec.
                closeIteratorSwallow(realm, src);
                return err;
            };
            if (heap_mod.valueAsPlainObject(r) == null) {
                state.done = true;
                realm.pending_exception = intrinsics.newTypeError(realm, "Iterator result is not an object") catch return error.OutOfMemory;
                closeIteratorSwallow(realm, active);
                closeIteratorSwallow(realm, src);
                return error.NativeThrew;
            }
            const done_v = iterGet(realm, r, "done") catch |err| {
                state.done = true;
                closeIteratorSwallow(realm, src);
                return err;
            };
            if (intrinsics.toBoolean(done_v)) {
                // Inner exhausted — clear active and loop to outer.
                // Per spec, no IteratorClose on a naturally-done inner.
                state.active = Value.undefined_;
                continue;
            }
            const value = iterGet(realm, r, "value") catch |err| {
                state.done = true;
                closeIteratorSwallow(realm, src);
                return err;
            };
            return iterResult(realm, value, false);
        }

        // 2. No active inner — pull next value from outer.
        const result = invokeIterNextFn(realm, src, outer_next) catch |err| {
            state.done = true;
            return err;
        };
        if (heap_mod.valueAsPlainObject(result) == null) {
            state.done = true;
            return typeErrorAfterClose(realm, src, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, result, "done") catch |err| {
            state.done = true;
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            state.done = true;
            return doneResult(realm);
        }
        const value = iterGet(realm, result, "value") catch |err| {
            state.done = true;
            return err;
        };
        const idx: i32 = @intCast(state.count);
        state.count += 1;

        // 3. Apply mapper(value, idx).
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                state.done = true;
                return callbackErrored(realm, src);
            },
        };
        const mapped = switch (out) {
            .value, .yielded => |x| x,
            .thrown => |ex| {
                state.done = true;
                return callbackThrew(realm, src, ex);
            },
        };

        // 4. GetIteratorFlattenable(reject-strings) on the mapped value.
        const inner = getIteratorFlattenable(realm, mapped, true) catch {
            state.done = true;
            // Flattenable's throw is already in pending_exception;
            // close the outer source (swallow) before propagating.
            return callbackErrored(realm, src);
        };
        state.active = inner;
        // Loop back to drain `active`.
    }
}

fn iteratorTake(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.take called on non-object");
    // §27.1.4.x — ToNumber(limit) BEFORE GetIteratorDirect, so a
    // throwing valueOf wins over the iterator-direct lookup.
    const arg = argOr(args, 0, Value.undefined_);
    const num_v = intrinsics.toNumber(realm, arg) catch |err| {
        // Whatever ToNumber threw closes the iterator and the
        // original throw propagates.
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, this_value, ex);
        }
        return err;
    };
    const d: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    // §27.1.4.x step 4: "If numLimit is NaN, throw RangeError."
    if (std.math.isNan(d)) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.take limit is NaN");
    }
    // §7.1.5 ToIntegerOrInfinity first (truncates toward zero;
    // `-0.5` -> `0`), THEN the "< 0" check. Doing the `< 0`
    // test on the raw double would wrongly reject `-0.5`
    // (fixture `take/limit-rangeerror.js`).
    const integer_limit: f64 = if (std.math.isInf(d)) d else @trunc(d);
    if (integer_limit < 0) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.take limit is negative");
    }
    const limit_clamped: f64 = if (std.math.isInf(integer_limit)) @as(f64, std.math.maxInt(i32)) else integer_limit;
    const limit_i32: i32 = if (limit_clamped >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(limit_clamped);
    return buildLazy(realm, this_value, Value.fromInt32(limit_i32), takeNext);
}

fn iteratorDrop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) return throwTypeError(realm, "Iterator.prototype.drop called on non-object");
    const arg = argOr(args, 0, Value.undefined_);
    const num_v = intrinsics.toNumber(realm, arg) catch |err| {
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, this_value, ex);
        }
        return err;
    };
    const d: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    // §27.1.4.x step 3: "If numLimit is NaN, throw RangeError."
    if (std.math.isNan(d)) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.drop limit is NaN");
    }
    // §7.1.5 ToIntegerOrInfinity first, THEN the "< 0" check.
    // `-0.5` truncs to `0`, which is not `< 0` (fixture
    // `drop/limit-rangeerror.js`).
    const integer_limit: f64 = if (std.math.isInf(d)) d else @trunc(d);
    if (integer_limit < 0) {
        return rangeErrorAfterClose(realm, this_value, "Iterator.prototype.drop limit is negative");
    }
    const drop_clamped: f64 = if (std.math.isInf(integer_limit)) @as(f64, std.math.maxInt(i32)) else integer_limit;
    const drop_i32: i32 = if (drop_clamped >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(drop_clamped);
    return buildLazy(realm, this_value, Value.fromInt32(drop_i32), dropNext);
}

fn buildLazy(realm: *Realm, source: Value, payload: Value, next_fn: @import("../function.zig").NativeFn) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    // §27.1.4.x — every lazy helper does GetIteratorDirect on
    // `this`, which snapshots `this.next` once (§7.4.2; the
    // callability check is deferred to step time per §7.4.4).
    // Cache the raw value on the wrapper so subsequent steps
    // don't re-trigger a `get next` accessor on the source
    // (the `get-next-method-only-once.js` family) and a
    // non-callable `next` defers its TypeError to `.next()`
    // time (the `this-non-callable-next.js` family).
    const cached_next_v = snapshotNextValue(realm, source) catch |err| {
        if (err == error.NativeThrew) {
            const ex = realm.pending_exception orelse Value.undefined_;
            return throwAfterClose(realm, source, ex);
        }
        return err;
    };
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    const state = realm.allocator.create(IteratorHelperState) catch return error.OutOfMemory;
    state.* = .{
        .source = source,
        .next_fn = cached_next_v,
        .payload = payload,
    };
    wrap.iter_helper = state;
    // Pin `wrap` for the rest of construction — every subsequent
    // `allocate*` call below can trigger GC, and `wrap` is only
    // alive through this local variable. `source` rides along
    // through `state.source` once the GC walker reaches `wrap`.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrap)) catch return error.OutOfMemory;
    const fn_obj = realm.heap.allocateFunctionNative(next_fn, 0, "next") catch return error.OutOfMemory;
    fn_obj.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(lazyReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

/// `wrapper.return()` — close the underlying iterator if we
/// haven't already observed exhaustion. After exhaustion or a
/// previous return, this is a no-op (matches the
/// `return-is-not-forwarded-after-exhaustion.js` fixtures).
fn lazyReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    const state = obj.iter_helper orelse return iterResult(realm, Value.undefined_, true);
    if (state.done) {
        return iterResult(realm, Value.undefined_, true);
    }
    state.done = true;
    try closeIteratorPropagate(realm, state.source);
    return iterResult(realm, Value.undefined_, true);
}

fn doneResult(realm: *Realm) NativeError!Value {
    return iterResult(realm, Value.undefined_, true);
}

/// §27.5.3.2 GeneratorValidate step 6: re-entering an iterator
/// helper while it is mid-step is a TypeError. Cynic models the
/// helper as a native — guard each `next` with a "running" bit
/// on the typed state.
fn checkNotRunning(realm: *Realm, state: *IteratorHelperState) NativeError!void {
    if (state.running) {
        return throwTypeError(realm, "Iterator helper is already running");
    }
}

fn mapNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "map iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;
    const src = state.source;
    const next_fn = try cachedNextFn(realm, obj, src);
    const result = invokeIterNextFn(realm, src, next_fn) catch |err| {
        // `next` itself threw — wrapper is done, but spec does
        // not call return on this path.
        state.done = true;
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        state.done = true;
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        state.done = true;
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        state.done = true;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        state.done = true;
        return err;
    };
    const cb = heap_mod.valueAsFunction(state.payload) orelse return doneResult(realm);
    const idx: i32 = @intCast(state.count);
    state.count += 1;
    const args_call = [_]Value{ value, Value.fromInt32(idx) };
    const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Mapper threw. Mark wrapper done and run §7.4.10
            // IteratorClose with the mapper's throw as the
            // surrounding completion — so any return-throw is
            // swallowed (mapper-throws-then-closing-iterator).
            state.done = true;
            return callbackErrored(realm, src);
        },
    };
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => |ex| {
            state.done = true;
            return callbackThrew(realm, src, ex);
        },
    };
    return iterResult(realm, v, false);
}

fn filterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "filter iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;
    const src = state.source;
    const next_fn = try cachedNextFn(realm, obj, src);
    const cb = heap_mod.valueAsFunction(state.payload) orelse return doneResult(realm);
    while (true) {
        const result = invokeIterNextFn(realm, src, next_fn) catch |err| {
            state.done = true;
            return err;
        };
        if (heap_mod.valueAsPlainObject(result) == null) {
            state.done = true;
            return typeErrorAfterClose(realm, src, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, result, "done") catch |err| {
            state.done = true;
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            state.done = true;
            return doneResult(realm);
        }
        const idx: i32 = @intCast(state.count);
        state.count += 1;
        const value = iterGet(realm, result, "value") catch |err| {
            state.done = true;
            return err;
        };
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                state.done = true;
                return callbackErrored(realm, src);
            },
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| {
                state.done = true;
                return callbackThrew(realm, src, ex);
            },
        };
        if (pass) return iterResult(realm, value, false);
    }
}

fn takeNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "take iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;
    // `payload` here is the i32 take-limit stored as a Value.
    const limit_v = state.payload;
    const limit: u32 = if (limit_v.isInt32()) @intCast(@max(limit_v.asInt32(), 0)) else 0;
    const idx: u32 = state.count;
    const src = state.source;
    if (idx >= limit) {
        // Spec: when remaining is 0, IteratorClose(iterated,
        // NormalCompletion(undefined)). Errors from `return`
        // propagate (exhaustion-calls-return.js).
        state.done = true;
        try closeIteratorPropagate(realm, src);
        return doneResult(realm);
    }
    state.count = idx + 1;
    const next_fn = try cachedNextFn(realm, obj, src);
    const result = invokeIterNextFn(realm, src, next_fn) catch |err| {
        state.done = true;
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        state.done = true;
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        state.done = true;
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        state.done = true;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        state.done = true;
        return err;
    };
    return iterResult(realm, value, false);
}

fn dropNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "drop iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;
    // `payload` is the drop-count remaining; clears to 0 once primed.
    const drop_v = state.payload;
    var drop_remaining: i32 = if (drop_v.isInt32()) drop_v.asInt32() else 0;
    const src = state.source;
    const next_fn = try cachedNextFn(realm, obj, src);
    while (drop_remaining > 0) : (drop_remaining -= 1) {
        const r = invokeIterNextFn(realm, src, next_fn) catch |err| {
            state.done = true;
            return err;
        };
        if (heap_mod.valueAsPlainObject(r) == null) {
            state.done = true;
            return typeErrorAfterClose(realm, src, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, r, "done") catch |err| {
            state.done = true;
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            state.done = true;
            state.payload = Value.fromInt32(0);
            return doneResult(realm);
        }
    }
    state.payload = Value.fromInt32(0);
    const result = invokeIterNextFn(realm, src, next_fn) catch |err| {
        state.done = true;
        return err;
    };
    if (heap_mod.valueAsPlainObject(result) == null) {
        state.done = true;
        return typeErrorAfterClose(realm, src, "Iterator result is not an object");
    }
    const done_v = iterGet(realm, result, "done") catch |err| {
        state.done = true;
        return err;
    };
    if (intrinsics.toBoolean(done_v)) {
        state.done = true;
        return doneResult(realm);
    }
    const value = iterGet(realm, result, "value") catch |err| {
        state.done = true;
        return err;
    };
    return iterResult(realm, value, false);
}

// ── Eager helpers — drain the source ────────────────────────────────────────

fn iteratorToArray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.toArray called on non-object");
    // §27.1.4.1.1.5 step 1 — GetIteratorDirect snapshots `next` once.
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // The loop body calls into user JS (`next`, accessor getters)
    // and allocates an index JSString per step. `out` is only
    // alive through this local variable — pin it so the GC can't
    // reclaim it mid-step.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    var idx: i32 = 0;
    var ibuf: [24]u8 = undefined;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, value) catch return error.OutOfMemory;
        idx += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn iteratorForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.forEach called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.forEach callback is not callable");
    };
    // §27.1.4.1.1.6 step 2 — GetIteratorDirect snapshots `next`.
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        switch (out) {
            .value, .yielded => {},
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        }
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.find called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.find predicate is not callable");
    };
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (pass) {
            // §27.1.4.x step "return ? IteratorClose(iterated,
            // NormalCompletion(value))" — `?` propagates any
            // throw from `.return()` (or `get return`).
            try closeIteratorPropagate(realm, this_value);
            return value;
        }
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorSome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.some called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.some predicate is not callable");
    };
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (pass) {
            // §27.1.4.x — return ? IteratorClose(iterated,
            // NormalCompletion(true)). `?` propagates throws
            // from `.return()` / `get return`.
            try closeIteratorPropagate(realm, this_value);
            return Value.fromBool(true);
        }
        idx += 1;
    }
    return Value.fromBool(false);
}

fn iteratorEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.every called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.every predicate is not callable");
    };
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        if (!pass) {
            // §27.1.4.x — return ? IteratorClose(iterated,
            // NormalCompletion(false)). `?` propagates throws
            // from `.return()` / `get return`.
            try closeIteratorPropagate(realm, this_value);
            return Value.fromBool(false);
        }
        idx += 1;
    }
    return Value.fromBool(true);
}

fn iteratorReduce(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator.prototype.reduce called on non-object");
    const cb_v = argOr(args, 0, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse {
        return typeErrorAfterClose(realm, this_value, "Iterator.prototype.reduce reducer is not callable");
    };
    _ = this_obj;
    const next_fn = try snapshotNext(realm, this_value);
    var has_acc: bool = args.len >= 2;
    var acc: Value = if (has_acc) args[1] else Value.undefined_;
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNextFn(realm, this_value, next_fn);
        if (heap_mod.valueAsPlainObject(r) == null) {
            return typeErrorAfterClose(realm, this_value, "Iterator result is not an object");
        }
        const done_v = try iterGet(realm, r, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try iterGet(realm, r, "value");
        if (!has_acc) {
            acc = value;
            has_acc = true;
            idx += 1;
            continue;
        }
        const args_call = [_]Value{ acc, value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return callbackErrored(realm, this_value),
        };
        acc = switch (out) {
            .value, .yielded => |x| x,
            .thrown => |ex| return callbackThrew(realm, this_value, ex),
        };
        idx += 1;
    }
    if (!has_acc) return throwTypeError(realm, "Iterator.prototype.reduce on empty iterator with no initial value");
    return acc;
}

fn iterResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}

// ── §27.1.4.2 / 27.1.4.3 / 27.1.4.4 — Iterator.concat / zip / zipKeyed ──────

/// §7.4.4 GetMethod-style read of `@@iterator`. Returns the
/// callable, or null when the property is undefined / null /
/// absent. Throws TypeError if present-and-not-callable.
fn getIteratorMethod(realm: *Realm, v: Value) NativeError!?*JSFunction {
    const obj = heap_mod.valueAsPlainObject(v) orelse return null;
    const m = obj.get("@@iterator");
    if (m.isUndefined() or m.isNull()) return null;
    if (heap_mod.valueAsFunction(m)) |fn_| return fn_;
    return throwTypeError(realm, "@@iterator is not callable");
}

/// `iterable[Symbol.iterator]()` — calls the method, validates the
/// result is an Object, returns the raw iterator.
fn callIteratorMethod(realm: *Realm, iter_fn: *JSFunction, this_v: Value) NativeError!Value {
    const out = interpreter.callJSFunction(realm.allocator, realm, iter_fn, this_v, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    if (heap_mod.valueAsPlainObject(v) == null) {
        return throwTypeError(realm, "iterator method did not return an object");
    }
    return v;
}

/// §7.4.6 GetIteratorFlattenable. `reject_strings` selects the
/// `reject-strings` variant (used by zip / zipKeyed) — a plain
/// String primitive throws. The non-reject variant is used by
/// `Iterator.from` (which already opens via `openIterator`).
/// Returns a raw iterator object (an Object with a `next`
/// method).
fn getIteratorFlattenable(realm: *Realm, v: Value, reject_strings: bool) NativeError!Value {
    // §7.4.6 step 1 — if O is not Object and stringHandling rejects
    // strings (or O isn't a String), TypeError. Strings flow through
    // when stringHandling=iterate-string-primitives (Iterator.from).
    if (heap_mod.valueAsPlainObject(v) == null) {
        if (!(v.isString() and !reject_strings)) {
            return throwTypeError(realm, "iterable is not an object");
        }
        // Spec § 7.4.6 step 2 — `GetMethod(v, @@iterator)` — runs
        // against the primitive String. The getter sees `this` as
        // the primitive in strict mode (typeof === 'string'), so
        // walk `String.prototype` directly rather than boxing first.
        const sp = realm.intrinsics.string_prototype orelse return throwTypeError(realm, "String.prototype not installed");
        if (sp.accessors.get("@@iterator")) |acc| {
            if (acc.getter) |getter| {
                const out = interpreter.callJSFunction(realm.allocator, realm, getter, v, &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                const m_v = switch (out) {
                    .value, .yielded => |x| x,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                };
                if (m_v.isUndefined() or m_v.isNull()) {
                    // Fall through to default string iteration.
                    return interpreter.openIteratorAllowArrayLike(realm.allocator, realm, v) catch return throwTypeError(realm, "could not open string iterator");
                }
                const m_fn = heap_mod.valueAsFunction(m_v) orelse return throwTypeError(realm, "@@iterator is not callable");
                return callIteratorMethod(realm, m_fn, v);
            }
        }
        // No accessor on String.prototype — fall through to data
        // slot lookup. If a normal data property is installed
        // there, invoke it with `this = v`.
        if (sp.properties.get("@@iterator")) |m_v| {
            if (heap_mod.valueAsFunction(m_v)) |m_fn| {
                return callIteratorMethod(realm, m_fn, v);
            }
        }
        // Default String iteration — array-like over code units.
        return interpreter.openIteratorAllowArrayLike(realm.allocator, realm, v) catch return throwTypeError(realm, "could not open string iterator");
    }
    // §7.4.6 step 2 — accessor-aware `@@iterator` read so the
    // `iterables-iteration*.js` family observes the spec's exact
    // ordering (one `get @@iterator` per input, at this site).
    const m_v = try iterGet(realm, v, "@@iterator");
    if (m_v.isUndefined() or m_v.isNull()) {
        // No @@iterator — treat `v` itself as the iterator (must
        // expose a `next`).
        return v;
    }
    const m_fn = heap_mod.valueAsFunction(m_v) orelse {
        return throwTypeError(realm, "@@iterator is not callable");
    };
    return callIteratorMethod(realm, m_fn, v);
}

// Slot-name builders. We store list-shaped state as numbered
// keys on the wrapper object so the existing per-property
// machinery (and the GC) handle visibility for free.
fn slotName(buf: *[40]u8, prefix: []const u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}__", .{ prefix, i }) catch unreachable;
}

/// `Iterator.concat(...iterables)` — §27.1.4.2.
fn iteratorConcat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // Step 1-2: validate every input up-front. Each must be an
    // Object whose `@@iterator` is callable. Capture the method
    // here (accessor-aware) — spec records {[[OpenMethod]],
    // [[Iterable]]} so a `get [Symbol.iterator]()` getter runs
    // exactly once per arg, at construction.
    var captured_methods = std.ArrayListUnmanaged(*JSFunction).empty;
    defer captured_methods.deinit(realm.allocator);
    for (args) |item| {
        if (heap_mod.valueAsPlainObject(item) == null) {
            return throwTypeError(realm, "Iterator.concat argument is not an object");
        }
        const m = try iterGet(realm, item, "@@iterator");
        if (m.isUndefined() or m.isNull()) {
            return throwTypeError(realm, "Iterator.concat argument has no @@iterator");
        }
        const m_fn = heap_mod.valueAsFunction(m) orelse {
            return throwTypeError(realm, "Iterator.concat argument @@iterator is not callable");
        };
        captured_methods.append(realm.allocator, m_fn) catch return error.OutOfMemory;
    }

    // Build the wrapper. Primary state (count/idx/done/running/active)
    // lives on the typed `iter_helper` slot; per-input
    // [[Iterable]] + [[OpenMethod]] still ride along as indexed
    // properties (`__cynic_iter_input_<i>__` / `__cynic_iter_method_<i>__`)
    // pending a dynamic-array typed slot for them. TODO: move
    // indexed inputs off the property bag too.
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    const state = realm.allocator.create(IteratorHelperState) catch return error.OutOfMemory;
    state.* = .{ .count = @intCast(args.len) };
    wrap.iter_helper = state;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrap)) catch return error.OutOfMemory;
    var sbuf: [40]u8 = undefined;
    for (args, 0..) |item, i| {
        const owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_input_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned.bytes, item) catch return error.OutOfMemory;
        const m_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_method_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, m_owned.bytes, heap_mod.taggedFunction(captured_methods.items[i])) catch return error.OutOfMemory;
    }

    const next_fn = realm.heap.allocateFunctionNative(concatNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(concatReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn concatReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    const state = obj.iter_helper orelse return iterResult(realm, Value.undefined_, true);
    if (state.done) {
        return iterResult(realm, Value.undefined_, true);
    }
    state.done = true;
    const active = state.active;
    if (heap_mod.valueAsPlainObject(active) != null) {
        try closeIteratorPropagate(realm, active);
    }
    return iterResult(realm, Value.undefined_, true);
}

fn concatNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "concat iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    state.running = true;
    defer state.running = false;

    const count: u32 = state.count;
    var idx: u32 = state.idx;
    var sbuf: [40]u8 = undefined;

    while (idx < count) {
        var active = state.active;
        if (heap_mod.valueAsPlainObject(active) == null) {
            // Open input[idx]. Per spec, errors here propagate
            // (no in-flight inner iterator to close).
            const slot = slotName(&sbuf, "__cynic_iter_input_", idx);
            const input_v = obj.get(slot);
            var sbuf2: [40]u8 = undefined;
            const m_slot = slotName(&sbuf2, "__cynic_iter_method_", idx);
            const m_v = obj.get(m_slot);
            const m_fn = heap_mod.valueAsFunction(m_v) orelse {
                state.done = true;
                return throwTypeError(realm, "Iterator.concat captured method missing");
            };
            const inner = callIteratorMethod(realm, m_fn, input_v) catch |err| {
                state.done = true;
                return err;
            };
            state.active = inner;
            active = inner;
        }

        const result = invokeIterNext(realm, active) catch |err| {
            state.done = true;
            return err;
        };
        if (heap_mod.valueAsPlainObject(result) == null) {
            state.done = true;
            return typeErrorAfterClose(realm, active, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, result, "done") catch |err| {
            state.done = true;
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            // Inner exhausted — clear active, advance to next input.
            state.active = Value.undefined_;
            idx += 1;
            state.idx = idx;
            continue;
        }
        const value = iterGet(realm, result, "value") catch |err| {
            state.done = true;
            return err;
        };
        return iterResult(realm, value, false);
    }

    state.done = true;
    return doneResult(realm);
}

// ── Iterator.zip / Iterator.zipKeyed shared machinery ───────────────────────

const ZipMode = enum(i32) { shortest = 0, longest = 1, strict = 2 };

/// Read + validate `options.mode`. Returns the parsed mode.
fn readZipMode(realm: *Realm, options_v: Value) NativeError!ZipMode {
    if (options_v.isUndefined()) return .shortest;
    const opts = heap_mod.valueAsPlainObject(options_v) orelse {
        return throwTypeError(realm, "Iterator.zip options must be an object");
    };
    const mode_v = try iterGet(realm, heap_mod.taggedObject(opts), "mode");
    if (mode_v.isUndefined()) return .shortest;
    if (!mode_v.isString()) return throwTypeError(realm, "Iterator.zip 'mode' must be a string");
    const s: *JSString = @ptrCast(@alignCast(mode_v.asString()));
    if (std.mem.eql(u8, s.bytes, "shortest")) return .shortest;
    if (std.mem.eql(u8, s.bytes, "longest")) return .longest;
    if (std.mem.eql(u8, s.bytes, "strict")) return .strict;
    return throwTypeError(realm, "Iterator.zip 'mode' must be 'shortest', 'longest', or 'strict'");
}

/// Read + validate `options.padding`. Returns null when absent;
/// returns the padding object otherwise. Only consulted in
/// "longest" mode.
fn readZipPadding(realm: *Realm, options_v: Value) NativeError!?*JSObject {
    if (options_v.isUndefined()) return null;
    const opts = heap_mod.valueAsPlainObject(options_v) orelse return null;
    const pad_v = try iterGet(realm, heap_mod.taggedObject(opts), "padding");
    if (pad_v.isUndefined()) return null;
    const pad_obj = heap_mod.valueAsPlainObject(pad_v) orelse {
        return throwTypeError(realm, "Iterator.zip 'padding' must be an object");
    };
    return pad_obj;
}

/// A sub-iterator opened from the zip iterables list, with its
/// `next` method snapshotted at construction (§7.4.2 GetIteratorDirect
/// step 1). zipNext dispatches through the cached `next` for every
/// step so a `get next()` accessor on the underlying iterator
/// fires exactly once.
const ZipIterSlot = struct {
    iter: Value,
    /// Result of `Get(iter, "next")`. Stored as a Value (not a
    /// `*JSFunction`) so the §7.4.4 IteratorNext callability check
    /// is deferred to step time — matches the spec's
    /// `[[NextMethod]]` semantics.
    next: Value,
};

/// §7.4.2 GetIteratorDirect — given a raw iterator `iter`,
/// snapshot its `next` via accessor-aware [[Get]]. The
/// callability check is deferred (per §7.4.4 IteratorNext) so a
/// non-callable `next` only TypeErrors at step time.
fn snapshotIterNextValue(realm: *Realm, iter: Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(iter) == null) {
        return throwTypeError(realm, "iterator is not an object");
    }
    return iterGet(realm, iter, "next");
}

/// Close every slot in `slots[start..]` (forward index order),
/// swallowing errors so the caller's pending throw wins.
fn closeAllSwallowSlots(realm: *Realm, slots: []const ZipIterSlot, start: usize) void {
    var i: usize = start;
    while (i < slots.len) : (i += 1) {
        closeIteratorSwallow(realm, slots[i].iter);
    }
}

/// Open every entry of an iterables-iterable (zip's `iterables`
/// argument — itself iterable — yielding objects to pass through
/// §7.4.6 GetIteratorFlattenable(reject-strings)). Returns the
/// collected sub-iterators with their snapshotted `next` slots.
/// On any throw, closes already-opened inner iters and the input
/// iterator before propagating.
///
/// §27.5.4 step 10 (Iterator.zip): `Let inputIter be ? GetIterator(iterables, sync)` —
/// reads `@@iterator` once, calls it, then §7.4.2 GetIteratorDirect
/// snapshots the returned iterator's `next`. Both reads are
/// accessor-aware so the `iterables-iteration.js` log ordering
/// matches.
fn collectZipIters(realm: *Realm, iterables_v: Value) NativeError![]ZipIterSlot {
    if (heap_mod.valueAsPlainObject(iterables_v) == null) {
        return throwTypeError(realm, "Iterator.zip iterables must be an object");
    }
    // §7.4.2 GetIterator(iterables, sync) — accessor-aware
    // `@@iterator` read, then call the method.
    const m_v = try iterGet(realm, iterables_v, "@@iterator");
    if (m_v.isUndefined() or m_v.isNull()) {
        return throwTypeError(realm, "Iterator.zip iterables is not iterable");
    }
    const m_fn = heap_mod.valueAsFunction(m_v) orelse {
        return throwTypeError(realm, "Iterator.zip iterables @@iterator is not callable");
    };
    const input_iter = try callIteratorMethod(realm, m_fn, iterables_v);
    // §7.4.2 step 1 — snapshot input_iter.next.
    const input_next_v = try snapshotIterNextValue(realm, input_iter);

    var iters: std.ArrayListUnmanaged(ZipIterSlot) = .empty;
    // The errdefer below frees the list backing on every error
    // path; the per-branch close walks below close the user-
    // observable iterators but must NOT call `iters.deinit` —
    // doing so would let the errdefer run a second time over the
    // freed pointer and segfault on the next allocator pass.
    errdefer iters.deinit(realm.allocator);
    while (true) {
        // §7.4.4 IteratorNext callability check fires here.
        const input_next_fn = heap_mod.valueAsFunction(input_next_v) orelse {
            closeAllSwallowSlots(realm, iters.items, 0);
            return throwTypeError(realm, "iterator has no callable next");
        };
        const r = invokeIterNextFn(realm, input_iter, input_next_fn) catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        if (heap_mod.valueAsPlainObject(r) == null) {
            closeAllSwallowSlots(realm, iters.items, 0);
            return typeErrorAfterClose(realm, input_iter, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, r, "done") catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        if (intrinsics.toBoolean(done_v)) break;
        const value = iterGet(realm, r, "value") catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        const sub_iter = getIteratorFlattenable(realm, value, true) catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, input_iter);
            return err;
        };
        // §7.4.2 step 1 — snapshot the sub-iter's `next` once.
        const sub_next_v = snapshotIterNextValue(realm, sub_iter) catch |err| {
            closeIteratorSwallow(realm, sub_iter);
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, input_iter);
            return err;
        };
        iters.append(realm.allocator, .{ .iter = sub_iter, .next = sub_next_v }) catch {
            closeIteratorSwallow(realm, sub_iter);
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, input_iter);
            return error.OutOfMemory;
        };
    }
    return iters.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

/// Allocate the zip wrapper and stash the iterator list, mode,
/// padding list, and (optional) keys list as numbered slots.
/// `keys == null` builds zip; non-null builds zipKeyed.
fn buildZipWrapper(
    realm: *Realm,
    iters: []const ZipIterSlot,
    mode: ZipMode,
    padding: ?*JSObject,
    keys: ?[]const []const u8,
) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    const state = realm.allocator.create(IteratorHelperState) catch return error.OutOfMemory;
    state.* = .{
        .count = @intCast(iters.len),
        .mode = @intCast(@intFromEnum(mode)),
        .keyed = keys != null,
    };
    wrap.iter_helper = state;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrap)) catch return error.OutOfMemory;

    // Per-input indexed slots (iter, snapshotted next, active-flag)
    // still ride on the property bag pending a dynamic-array typed
    // slot. TODO: move zip_<i> / zipnext_<i> / active_<i> / key_<i>
    // / pad_<i> off the property bag too.
    var sbuf: [40]u8 = undefined;
    for (iters, 0..) |slot, i| {
        const owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_zip_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned.bytes, slot.iter) catch return error.OutOfMemory;
        // §7.4.2 GetIteratorDirect — snapshot of iter.next, stashed
        // per-input so step time doesn't re-trigger a `get next`
        // accessor (the `iterator-zip-iteration.js` log expects
        // exactly one `get name.next` per input, at construction).
        const owned_n = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_zipnext_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned_n.bytes, slot.next) catch return error.OutOfMemory;
        const owned_a = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_active_", i)) catch return error.OutOfMemory;
        wrap.set(realm.allocator, owned_a.bytes, Value.fromBool(true)) catch return error.OutOfMemory;
    }

    if (keys) |ks| {
        for (ks, 0..) |k, i| {
            const k_owned = realm.heap.allocateString(k) catch return error.OutOfMemory;
            const slot_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_key_", i)) catch return error.OutOfMemory;
            // Store the (heap-owned) key string as a Value so the
            // GC keeps it alive.
            const k_value = Value.fromString(k_owned);
            wrap.set(realm.allocator, slot_owned.bytes, k_value) catch return error.OutOfMemory;
        }
    }

    // Padding storage. §27.1.4.3 step 14b: open the padding via
    // GetIterator(sync), pull `iterCount` values, fill the rest
    // with undefined. We do this eagerly at construction time so
    // a non-iterable padding throws here (matching the spec's
    // up-front order: padding-iter is opened *before* any input
    // iterator step). If we run out of padding values, the slot
    // is left empty (reads return undefined).
    if (mode == .longest and padding != null and iters.len > 0) {
        const pad_obj = padding.?;
        // §27.5.4 step 14b — `Let paddingIter be ? GetIterator(padding, sync)`.
        // Accessor-aware `@@iterator` read; then §7.4.2 snapshots next.
        const pad_v = heap_mod.taggedObject(pad_obj);
        const pad_m_v = iterGet(realm, pad_v, "@@iterator") catch |err| {
            closeAllSwallowSlots(realm, iters, 0);
            return err;
        };
        if (pad_m_v.isUndefined() or pad_m_v.isNull()) {
            closeAllSwallowSlots(realm, iters, 0);
            return throwTypeError(realm, "Iterator.zip 'padding' is not iterable");
        }
        const pad_m_fn = heap_mod.valueAsFunction(pad_m_v) orelse {
            closeAllSwallowSlots(realm, iters, 0);
            return throwTypeError(realm, "Iterator.zip 'padding' @@iterator is not callable");
        };
        const pad_iter = callIteratorMethod(realm, pad_m_fn, pad_v) catch |err| {
            closeAllSwallowSlots(realm, iters, 0);
            return err;
        };
        // §7.4.2 step 1 — snapshot pad_iter.next once.
        const pad_next_v = snapshotIterNextValue(realm, pad_iter) catch |err| {
            closeAllSwallowSlots(realm, iters, 0);
            return err;
        };
        var still_active = true;
        for (iters, 0..) |_, i| {
            const slot_owned = realm.heap.allocateString(slotName(&sbuf, "__cynic_iter_pad_", i)) catch return error.OutOfMemory;
            if (still_active) {
                const pad_next_fn = heap_mod.valueAsFunction(pad_next_v) orelse {
                    closeAllSwallowSlots(realm, iters, 0);
                    return throwTypeError(realm, "padding iterator has no callable next");
                };
                const r = invokeIterNextFn(realm, pad_iter, pad_next_fn) catch |err| {
                    closeAllSwallowSlots(realm, iters, 0);
                    return err;
                };
                if (heap_mod.valueAsPlainObject(r) == null) {
                    closeAllSwallowSlots(realm, iters, 0);
                    return typeErrorAfterClose(realm, pad_iter, "padding iterator result is not an object");
                }
                const done_v = iterGet(realm, r, "done") catch |err| {
                    closeAllSwallowSlots(realm, iters, 0);
                    return err;
                };
                if (intrinsics.toBoolean(done_v)) {
                    still_active = false;
                    wrap.set(realm.allocator, slot_owned.bytes, Value.undefined_) catch return error.OutOfMemory;
                    continue;
                }
                const value = iterGet(realm, r, "value") catch |err| {
                    closeAllSwallowSlots(realm, iters, 0);
                    return err;
                };
                wrap.set(realm.allocator, slot_owned.bytes, value) catch return error.OutOfMemory;
            } else {
                wrap.set(realm.allocator, slot_owned.bytes, Value.undefined_) catch return error.OutOfMemory;
            }
        }
        // If we read every slot but the iterator wasn't exhausted,
        // close it (NormalCompletion).
        if (still_active) {
            closeIteratorPropagate(realm, pad_iter) catch |err| {
                closeAllSwallowSlots(realm, iters, 0);
                return err;
            };
        }
    }

    const next_fn = realm.heap.allocateFunctionNative(zipNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const ret_fn = realm.heap.allocateFunctionNative(zipReturn, 0, "return") catch return error.OutOfMemory;
    ret_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "return", heap_mod.taggedFunction(ret_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn zipReturn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator return on non-object");
    // §27.5.1 — split per spec:
    //   suspended-start (never stepped) → set state to "completed"
    //                  and run IteratorCloseAll without entering
    //                  "executing"; nested return() observes
    //                  completed state and returns iterResult
    //                  (the `suspended-start-iterator-close-calls-return.js`
    //                  family probes this).
    //   suspended-yield (stepped at least once) → state transitions
    //                  to "executing" during IteratorCloseAll;
    //                  nested return() observes executing state
    //                  and throws TypeError per §27.5.1.4
    //                  GeneratorValidate step 6.
    const state = obj.iter_helper orelse return iterResult(realm, Value.undefined_, true);
    const started = state.started;
    if (started) try checkNotRunning(realm, state);
    if (state.done) {
        return iterResult(realm, Value.undefined_, true);
    }
    state.done = true;
    if (started) state.running = true;
    defer if (started) {
        state.running = false;
    };
    const count: i32 = @intCast(state.count);
    // §7.4.13 IteratorCloseAll(openIters, NormalCompletion(undefined)):
    // walk in REVERSE order; carry the running completion forward —
    // a throw from one iter's return() turns the completion into a
    // throw; subsequent IteratorClose calls (per §7.4.10 step 5)
    // swallow further throws and preserve the existing one.
    var sbuf: [40]u8 = undefined;
    var pending: ?Value = null;
    var i: i32 = count - 1;
    while (i >= 0) : (i -= 1) {
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        if (!intrinsics.toBoolean(obj.get(a_slot))) continue;
        var sbuf2: [40]u8 = undefined;
        const z_slot = slotName(&sbuf2, "__cynic_iter_zip_", @intCast(i));
        const it_v = obj.get(z_slot);
        obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
        if (pending == null) {
            // No pending throw — call return() and capture any throw.
            closeIteratorPropagate(realm, it_v) catch {
                pending = realm.pending_exception orelse Value.undefined_;
            };
        } else {
            // Already have a throw — IteratorClose with throw
            // completion swallows new errors (§7.4.10 step 5).
            closeIteratorSwallow(realm, it_v);
        }
    }
    if (pending) |ex| {
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    return iterResult(realm, Value.undefined_, true);
}

/// Step the i-th sub-iterator using its cached `next` (from the
/// `__cynic_iter_zipnext_<i>__` slot, populated at construction
/// per §7.4.2 GetIteratorDirect). The §7.4.4 IteratorNext
/// callability check fires here — a non-callable cached value
/// throws TypeError now, not at construction time.
fn stepZipIter(realm: *Realm, obj: *JSObject, i: i32) NativeError!Value {
    var sbuf: [40]u8 = undefined;
    const z_slot = slotName(&sbuf, "__cynic_iter_zip_", @intCast(i));
    const it_v = obj.get(z_slot);
    var sbuf2: [40]u8 = undefined;
    const n_slot = slotName(&sbuf2, "__cynic_iter_zipnext_", @intCast(i));
    const next_v = obj.get(n_slot);
    const next_fn = heap_mod.valueAsFunction(next_v) orelse {
        return throwTypeError(realm, "iterator has no callable next");
    };
    return invokeIterNextFn(realm, it_v, next_fn);
}

fn zipNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "zip iter on non-object");
    const state = obj.iter_helper orelse return doneResult(realm);
    try checkNotRunning(realm, state);
    if (state.done) return doneResult(realm);
    // §27.5.1 — once next() has been entered, the helper transitions
    // out of "suspended-start"; subsequent return() must run as
    // suspended-yield (executing) per GeneratorResumeAbrupt.
    state.started = true;
    state.running = true;
    defer state.running = false;

    const count: i32 = @intCast(state.count);
    if (count == 0) {
        state.done = true;
        return doneResult(realm);
    }
    const mode: ZipMode = @enumFromInt(@as(i32, state.mode));
    const keyed = state.keyed;

    // Build the result holder. zip yields Array exotics, zipKeyed
    // yields a *null-prototype* OrdinaryObject (§27.5.4 step 16 /
    // §27.5.5 step 16).
    const result_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (keyed) {
        result_obj.prototype = null;
    } else {
        result_obj.prototype = realm.intrinsics.array_prototype;
        result_obj.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    }

    var sbuf: [40]u8 = undefined;
    var any_active: bool = false;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        const active = intrinsics.toBoolean(obj.get(a_slot));
        if (!active) {
            // Already exhausted in a previous round (longest only —
            // shortest/strict would have terminated the wrapper at
            // first exhaustion). §27.5.4 step 14d.iv — pad slot.
            if (mode == .longest) {
                var sbuf2: [40]u8 = undefined;
                const p_slot = slotName(&sbuf2, "__cynic_iter_pad_", @intCast(i));
                const pv = obj.get(p_slot);
                try storeZipResult(realm, obj, result_obj, @intCast(i), pv, keyed);
            } else {
                state.done = true;
                return doneResult(realm);
            }
            continue;
        }

        // §27.5.4 step 14d — `Let result be Completion(IteratorStepValue(iter))`.
        // Cynic splits this into stepZipIter (cached `next`) plus
        // explicit `done` / `value` reads so the §7.4.10
        // IfAbruptCloseIterators close-all path is observable on
        // every spec-defined throw site.
        const r = stepZipIter(realm, obj, i) catch |err| {
            obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
            state.done = true;
            closeAllExcept(realm, obj, count, -1);
            return err;
        };
        if (heap_mod.valueAsPlainObject(r) == null) {
            obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
            state.done = true;
            closeAllExcept(realm, obj, count, -1);
            return throwTypeError(realm, "Iterator result is not an object");
        }
        const done_v = iterGet(realm, r, "done") catch |err| {
            obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
            state.done = true;
            closeAllExcept(realm, obj, count, -1);
            return err;
        };
        if (intrinsics.toBoolean(done_v)) {
            // §27.5.4 step 14d.iii — iter[i] returned done. Remove
            // from openIters (active=false). Mode dictates the rest.
            obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch return error.OutOfMemory;
            switch (mode) {
                .shortest => {
                    state.done = true;
                    closeAllExcept(realm, obj, count, i);
                    return doneResult(realm);
                },
                .strict => {
                    // §27.5.4 step 14d.iii (strict): if i ≠ 0,
                    // immediately throw closing all still-open in
                    // reverse. If i = 0, walk k = 1..count-1
                    // stepping each — they must all be done too,
                    // otherwise throw.
                    if (i != 0) {
                        state.done = true;
                        closeAllExcept(realm, obj, count, i);
                        return throwTypeError(realm, "Iterator.zip strict: iterator exhausted before others");
                    }
                    var k: i32 = 1;
                    while (k < count) : (k += 1) {
                        const r2 = stepZipIter(realm, obj, k) catch |err| {
                            state.done = true;
                            const k_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(k));
                            obj.set(realm.allocator, k_slot, Value.fromBool(false)) catch {};
                            closeAllExcept(realm, obj, count, -1);
                            return err;
                        };
                        if (heap_mod.valueAsPlainObject(r2) == null) {
                            state.done = true;
                            const k_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(k));
                            obj.set(realm.allocator, k_slot, Value.fromBool(false)) catch {};
                            closeAllExcept(realm, obj, count, -1);
                            return throwTypeError(realm, "Iterator result is not an object");
                        }
                        const k_done = iterGet(realm, r2, "done") catch |err| {
                            state.done = true;
                            const k_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(k));
                            obj.set(realm.allocator, k_slot, Value.fromBool(false)) catch {};
                            closeAllExcept(realm, obj, count, -1);
                            return err;
                        };
                        if (intrinsics.toBoolean(k_done)) {
                            const k_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(k));
                            obj.set(realm.allocator, k_slot, Value.fromBool(false)) catch return error.OutOfMemory;
                            continue;
                        }
                        // k yielded a value — strict violation.
                        // §7.4.13 IteratorCloseAll(openIters, throw)
                        // closes everything still active (k still
                        // is — the spec hasn't removed it) in
                        // reverse, then throws.
                        state.done = true;
                        closeAllExcept(realm, obj, count, -1);
                        return throwTypeError(realm, "Iterator.zip strict: iterator exhausted before others");
                    }
                    // Every iterator exhausted in the same round.
                    state.done = true;
                    return doneResult(realm);
                },
                .longest => {
                    // §27.5.4 step 14d.iv — substitute padding[i].
                    var sbuf2: [40]u8 = undefined;
                    const p_slot = slotName(&sbuf2, "__cynic_iter_pad_", @intCast(i));
                    const pv = obj.get(p_slot);
                    try storeZipResult(realm, obj, result_obj, @intCast(i), pv, keyed);
                    continue;
                },
            }
        }
        const value = iterGet(realm, r, "value") catch |err| {
            obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
            state.done = true;
            closeAllExcept(realm, obj, count, -1);
            return err;
        };
        try storeZipResult(realm, obj, result_obj, @intCast(i), value, keyed);
        any_active = true;
    }

    if (mode == .longest and !any_active) {
        // Every iter exhausted — done.
        state.done = true;
        return doneResult(realm);
    }

    if (!keyed) {
        // §27.5.4 step 14e — `Set status to Completion(Set(result, "length", iterCount, true))`.
        // `assertIsPackedArray` checks length is writable, non-
        // enumerable, non-configurable.
        result_obj.setWithFlags(realm.allocator, "length", Value.fromInt32(count), .{
            .writable = true,
            .enumerable = false,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    return iterResult(realm, heap_mod.taggedObject(result_obj), false);
}

/// Store result[idx] for zip / zipKeyed. For zip, key is the
/// numeric index as a string. For zipKeyed, the key was captured
/// at construction time in `__cynic_iter_key_<i>__`.
fn storeZipResult(
    realm: *Realm,
    wrap: *JSObject,
    result_obj: *JSObject,
    i: usize,
    value: Value,
    keyed: bool,
) NativeError!void {
    if (keyed) {
        var sbuf: [40]u8 = undefined;
        const k_slot = slotName(&sbuf, "__cynic_iter_key_", i);
        const k_v = wrap.get(k_slot);
        if (k_v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(k_v.asString()));
            result_obj.set(realm.allocator, s.bytes, value) catch return error.OutOfMemory;
        }
    } else {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result_obj.set(realm.allocator, owned.bytes, value) catch return error.OutOfMemory;
    }
}

/// §7.4.13 IteratorCloseAll over every still-active iter in
/// `obj`. Pass `skip_idx = -1` to close every iter; pass the
/// index of an iter the caller just observed done (already
/// removed from openIters by the spec) to skip it. Iters close
/// in reverse order; throws from `return()` are swallowed (the
/// caller is mid-throw or mid-return, and we don't propagate new
/// errors out of close-all).
fn closeAllExcept(realm: *Realm, obj: *JSObject, count: i32, skip_idx: i32) void {
    var sbuf: [40]u8 = undefined;
    var i: i32 = count - 1;
    while (i >= 0) : (i -= 1) {
        if (i == skip_idx) continue;
        const a_slot = slotName(&sbuf, "__cynic_iter_active_", @intCast(i));
        if (!intrinsics.toBoolean(obj.get(a_slot))) continue;
        var sbuf2: [40]u8 = undefined;
        const z_slot = slotName(&sbuf2, "__cynic_iter_zip_", @intCast(i));
        const it_v = obj.get(z_slot);
        closeIteratorSwallow(realm, it_v);
        obj.set(realm.allocator, a_slot, Value.fromBool(false)) catch {};
    }
}

/// `Iterator.zip(iterables, options?)` — §27.1.4.3.
fn iteratorZip(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const iterables_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(iterables_v) == null) {
        return throwTypeError(realm, "Iterator.zip iterables must be an object");
    }
    const options_v = argOr(args, 1, Value.undefined_);
    if (!options_v.isUndefined() and heap_mod.valueAsPlainObject(options_v) == null) {
        return throwTypeError(realm, "Iterator.zip options must be an object");
    }
    const mode = try readZipMode(realm, options_v);
    const padding = if (mode == .longest) try readZipPadding(realm, options_v) else null;

    const iters = try collectZipIters(realm, iterables_v);
    defer realm.allocator.free(iters);
    return buildZipWrapper(realm, iters, mode, padding, null);
}

/// `Iterator.zipKeyed(iterables, options?)` — §27.1.4.4.
fn iteratorZipKeyed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const iterables_v = argOr(args, 0, Value.undefined_);
    const iterables_obj = heap_mod.valueAsPlainObject(iterables_v) orelse {
        return throwTypeError(realm, "Iterator.zipKeyed iterables must be an object");
    };
    const options_v = argOr(args, 1, Value.undefined_);
    if (!options_v.isUndefined() and heap_mod.valueAsPlainObject(options_v) == null) {
        return throwTypeError(realm, "Iterator.zipKeyed options must be an object");
    }
    const mode = try readZipMode(realm, options_v);
    const padding = if (mode == .longest) try readZipPadding(realm, options_v) else null;

    // §27.1.4.4 step 10-12 — walk own property keys (in spec
    // order), filter to enumerable own data/accessor descriptors,
    // skip undefined values, and open each via
    // GetIteratorFlattenable.
    const all_keys = try @import("object.zig").ownPropertyKeysOrdered(realm, iterables_obj);
    defer realm.allocator.free(all_keys);

    var iters: std.ArrayListUnmanaged(ZipIterSlot) = .empty;
    defer iters.deinit(realm.allocator);
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (keys.items) |k| realm.allocator.free(k);
        keys.deinit(realm.allocator);
    }

    for (all_keys) |key| {
        // §10.1.5 [[GetOwnProperty]] — only enumerable own
        // descriptors qualify.
        const flags = iterables_obj.flagsFor(key);
        const has_data = iterables_obj.properties.contains(key);
        const has_acc = iterables_obj.accessors.contains(key);
        if (!has_data and !has_acc) continue;
        if (!flags.enumerable) continue;
        const v = iterGet(realm, iterables_v, key) catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        if (v.isUndefined()) continue;
        const sub_iter = getIteratorFlattenable(realm, v, true) catch |err| {
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        // §7.4.2 step 1 — snapshot sub_iter.next once, accessor-
        // aware via iterGet. (Same `next`-snapshot rule as zip.)
        const sub_next_v = snapshotIterNextValue(realm, sub_iter) catch |err| {
            closeIteratorSwallow(realm, sub_iter);
            closeAllSwallowSlots(realm, iters.items, 0);
            return err;
        };
        // Copy the key into our owned storage so we keep the
        // identity stable even if the underlying property string
        // gets recycled.
        const owned_key = realm.allocator.dupe(u8, key) catch {
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, sub_iter);
            return error.OutOfMemory;
        };
        keys.append(realm.allocator, owned_key) catch {
            realm.allocator.free(owned_key);
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, sub_iter);
            return error.OutOfMemory;
        };
        iters.append(realm.allocator, .{ .iter = sub_iter, .next = sub_next_v }) catch {
            closeAllSwallowSlots(realm, iters.items, 0);
            closeIteratorSwallow(realm, sub_iter);
            return error.OutOfMemory;
        };
    }

    return buildZipWrapper(realm, iters.items, mode, padding, keys.items);
}
