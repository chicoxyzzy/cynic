//! Surface audit — freezes the JS-visible own-property set on the
//! core intrinsic prototypes. Any new own property added to (or
//! removed from) one of these prototypes shows up as a test failure
//! with a diff. The intent is to catch two classes of drift:
//!
//!   1. Internal slots accidentally leaking onto JS-visible
//!      properties (e.g. `__cynic_promise_value__`). These should
//!      live in typed `JSObject` slots, not the `properties` map —
//!      the test fails with an `extra:` entry if one slips in.
//!   2. Spec-required members silently going missing during a
//!      refactor — the `missing:` list catches that.
//!
//! The expected sets list spec-required own properties only, plus
//! the `@@<name>` strings that currently stand in for well-known
//! symbol keys. TODO(symbols): once well-known symbol keys are
//! genuinely keyed by `Symbol`, those `@@<name>` strings come off
//! the expected lists and the symbol-key surface gets its own
//! parallel audit.
//!
//! Source-of-truth: ECMA-262 §22 / §23 / §27. When a spec-required
//! method or accessor is missing here, expand the expected set in
//! the matching `expect*` constant.
//!
//! Helpers walk `JSObject.properties` and `JSObject.accessors`
//! directly rather than calling `Object.getOwnPropertyNames` — JS
//! side enumeration goes through the public surface, while this
//! audit needs to *see* the raw storage so a forgotten internal
//! slot can't hide behind a non-enumerable flag.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const JSObject = @import("object.zig").JSObject;
const Accessor = @import("object.zig").Accessor;

/// Collect every own property name on `obj` (data + accessor),
/// returning a duplicated, sorted slice. Caller frees with
/// `allocator.free`.
fn collectOwnNames(allocator: std.mem.Allocator, obj: *JSObject) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(allocator);

    var p_it = obj.properties.iterator();
    while (p_it.next()) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }
    if (obj.accessorIterator()) |a_it_outer| {
        var a_it = a_it_outer;
        while (a_it.next()) |entry| {
            try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
    }

    const out = try list.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |n| {
        if (std.mem.eql(u8, n, needle)) return true;
    }
    return false;
}

/// Diff `actual` against `expected` and report any drift to stderr.
/// Returns `true` if the sets match exactly.
fn diffAndReport(label: []const u8, actual: []const []const u8, expected: []const []const u8) bool {
    var ok = true;

    for (expected) |name| {
        if (!contains(actual, name)) {
            std.debug.print("[surface-audit] {s}: missing own property \"{s}\"\n", .{ label, name });
            ok = false;
        }
    }
    for (actual) |name| {
        if (!contains(expected, name)) {
            std.debug.print("[surface-audit] {s}: extra own property \"{s}\"\n", .{ label, name });
            ok = false;
        }
    }
    return ok;
}

// =====================================================================
// Expected surfaces. Spec-required names only; `@@<name>` strings are
// the current stand-in for well-known symbol keys (see TODO above).
// =====================================================================

// The Annex-B `__proto__`, `__defineGetter__`, `__defineSetter__`,
// `__lookupGetter__`, `__lookupSetter__` are kept (per AGENTS.md —
// Annex-B normative aliases are in scope); none are wired today
// and need to land when sloppy-mode subset is filled in. Add to
// this set as each lands.
const expect_object_prototype = [_][]const u8{
    "constructor",
    "hasOwnProperty",
    "isPrototypeOf",
    "propertyIsEnumerable",
    "toLocaleString",
    "toString",
    "valueOf",
};

const expect_array_prototype = [_][]const u8{
    "constructor",
    "length",
    "at",
    "concat",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "flat",
    "flatMap",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "pop",
    "push",
    "reduce",
    "reduceRight",
    "reverse",
    "shift",
    "slice",
    "some",
    "sort",
    "splice",
    "toLocaleString",
    "toReversed",
    "toSorted",
    "toSpliced",
    "toString",
    "unshift",
    "values",
    "with",
    "@@iterator",
    "@@unscopables",
};

// §22.1.4 — String.prototype itself has a `length` data property
// whose initial value is 0, attributes { w:false, e:false, c:false }.
// (The §22.1.5 accessor-style `.length` on a String *instance* —
// receiver-based code-unit count — is a separate path.) The §22
// build-out otherwise tracks ECMA-262 2024 — isWellFormed /
// toWellFormed are wired below.
const expect_string_prototype = [_][]const u8{
    "constructor",
    "length",
    "at",
    "charAt",
    "charCodeAt",
    "codePointAt",
    "concat",
    "endsWith",
    "includes",
    "indexOf",
    "isWellFormed",
    "lastIndexOf",
    "localeCompare",
    "match",
    "matchAll",
    "normalize",
    "padEnd",
    "padStart",
    "repeat",
    "replace",
    "replaceAll",
    "search",
    "slice",
    "split",
    "startsWith",
    "substring",
    "toLocaleLowerCase",
    "toLocaleUpperCase",
    "toLowerCase",
    "toString",
    "toUpperCase",
    "toWellFormed",
    "trim",
    "trimEnd",
    "trimStart",
    "valueOf",
    "@@iterator",
};

const expect_promise_prototype = [_][]const u8{
    "constructor",
    "then",
    "catch",
    "finally",
    "@@toStringTag",
};

const expect_regexp_prototype = [_][]const u8{
    "constructor",
    "exec",
    "test",
    "toString",
    "flags",
    "source",
    "global",
    "ignoreCase",
    "multiline",
    "sticky",
    "unicode",
    "unicodeSets",
    "dotAll",
    "hasIndices",
    "@@match",
    "@@matchAll",
    "@@replace",
    "@@search",
    "@@split",
};

const expect_typed_array_prototype = [_][]const u8{
    "constructor",
    "buffer",
    "byteLength",
    "byteOffset",
    "length",
    "at",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "reduce",
    "reduceRight",
    "reverse",
    "set",
    "slice",
    "some",
    "sort",
    "subarray",
    "toLocaleString",
    "toReversed",
    "toSorted",
    "toString",
    "values",
    "with",
    "@@iterator",
    // §23.2.3.32 — `get %TypedArray%.prototype [ @@toStringTag ]`
    // accessor; returns the [[TypedArrayName]] string for TA
    // instances and `undefined` otherwise.
    "@@toStringTag",
};

const Case = struct {
    label: []const u8,
    proto: *JSObject,
    expected: []const []const u8,
};

test "surface audit: intrinsic prototypes expose only spec-defined names" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();

    const cases = [_]Case{
        .{
            .label = "Object.prototype",
            .proto = realm.intrinsics.object_prototype.?,
            .expected = &expect_object_prototype,
        },
        .{
            .label = "Array.prototype",
            .proto = realm.intrinsics.array_prototype.?,
            .expected = &expect_array_prototype,
        },
        .{
            .label = "String.prototype",
            .proto = realm.intrinsics.string_prototype.?,
            .expected = &expect_string_prototype,
        },
        .{
            .label = "Promise.prototype",
            .proto = realm.intrinsics.promise_prototype.?,
            .expected = &expect_promise_prototype,
        },
        .{
            .label = "RegExp.prototype",
            .proto = realm.intrinsics.regexp_prototype.?,
            .expected = &expect_regexp_prototype,
        },
        .{
            .label = "%TypedArray%.prototype",
            .proto = realm.intrinsics.typed_array_prototype.?,
            .expected = &expect_typed_array_prototype,
        },
    };

    var all_ok = true;
    for (cases) |case| {
        const actual = try collectOwnNames(testing.allocator, case.proto);
        defer freeNames(testing.allocator, actual);
        if (!diffAndReport(case.label, actual, case.expected)) all_ok = false;
    }

    try testing.expect(all_ok);
}

const heap_mod = @import("heap.zig");

/// Assert that `target[key]` is a built-in *method* with the
/// canonical §17 / §10.2.5 shape that the shared
/// `intrinsics.installNativeMethod*` helpers produce:
///
///   - the value is a callable function object;
///   - `[[Construct]]` is absent (`has_construct == false`) — §17
///     built-in methods are not constructors;
///   - `[[Prototype]]` is `%Function.prototype%` (§20.2.3);
///   - `[[Realm]]` is the installing realm (§10.2.5) — the raw
///     `allocateFunctionNative` + manual-flag sites this audit
///     guards historically *forgot* to set this, leaving cross-
///     realm species/brand checks to read `null`;
///   - the own data descriptor is `{ w:true, e:false, c:true }`.
///
/// `expected_name` pins the function's `name` slot (for symbol-keyed
/// methods the spec form is `"[Symbol.<descr>]"`, not the `@@<descr>`
/// storage key).
fn expectCanonicalMethod(
    realm: *Realm,
    target: *JSObject,
    key: []const u8,
    expected_name: []const u8,
) !void {
    const v = target.lookupOwn(key) orelse {
        std.debug.print("[method-shape] missing own method \"{s}\"\n", .{key});
        return error.MissingMethod;
    };
    const fn_obj = heap_mod.valueAsFunction(v) orelse {
        std.debug.print("[method-shape] \"{s}\" is not a function\n", .{key});
        return error.NotAFunction;
    };

    try testing.expect(!fn_obj.has_construct);
    // Pointer identity via `==` (not `expectEqual`) so a mismatch
    // doesn't dump the entire Realm / JSObject struct to stderr.
    try testing.expect(fn_obj.proto == realm.intrinsics.function_prototype);
    try testing.expect(fn_obj.realm == realm);

    const flags = target.flagsFor(key);
    try testing.expect(flags.writable);
    try testing.expect(!flags.enumerable);
    try testing.expect(flags.configurable);

    try testing.expect(fn_obj.name != null);
    try testing.expectEqualStrings(expected_name, fn_obj.name.?);
}

test "method-registration shape: built-in object methods carry the canonical §17/§10.2.5 descriptor" {
    // Unhardened so the SES freeze pass doesn't rewrite the
    // descriptors out from under the audit — this pins the shape
    // the install helpers *produce*, before any hardening.
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    const json_v = realm.globals.get("JSON") orelse return error.NoJSON;
    const json_obj = heap_mod.valueAsPlainObject(json_v) orelse return error.JSONNotObject;

    try expectCanonicalMethod(&realm, json_obj, "stringify", "stringify");
    try expectCanonicalMethod(&realm, json_obj, "parse", "parse");
    try expectCanonicalMethod(&realm, json_obj, "rawJSON", "rawJSON");
    try expectCanonicalMethod(&realm, json_obj, "isRawJSON", "isRawJSON");
}

test "method-registration shape: global built-in functions carry [[Realm]] and aren't constructors" {
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    // §19.2 — `parseInt` / `parseFloat` / `isNaN` / `isFinite` are
    // ordinary built-in functions installed straight onto the global
    // object, allocated via `makeNativeFunction`.
    const target: *JSObject = realm.globals.target.?;
    try expectCanonicalMethod(&realm, target, "parseInt", "parseInt");
    try expectCanonicalMethod(&realm, target, "parseFloat", "parseFloat");
    try expectCanonicalMethod(&realm, target, "isNaN", "isNaN");
    try expectCanonicalMethod(&realm, target, "isFinite", "isFinite");
}

test "method-registration shape: Set.prototype values/keys/@@iterator are the same function object" {
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    const set_v = realm.globals.get("Set") orelse return error.NoSet;
    const set_ctor = heap_mod.valueAsFunction(set_v) orelse return error.SetNotFn;
    const set_proto = set_ctor.prototype orelse return error.NoSetProto;

    // §24.2.3 — `Set.prototype.values`, `.keys`, and `@@iterator` are
    // required to be the *same* function object. The migration to
    // `makeNativeFunction` must preserve that identity.
    try expectCanonicalMethod(&realm, set_proto, "values", "values");
    const values = set_proto.lookupOwn("values").?;
    const keys = set_proto.lookupOwn("keys").?;
    const iter = set_proto.lookupOwn("@@iterator").?;
    try testing.expect(heap_mod.valueAsFunction(values).? == heap_mod.valueAsFunction(keys).?);
    try testing.expect(heap_mod.valueAsFunction(values).? == heap_mod.valueAsFunction(iter).?);
}

/// Assert a built-in accessor function carries the §17 / §10.2.5
/// shape: it is NOT a constructor (`[[Construct]]` absent —
/// accessor functions never construct), its `[[Prototype]]` is
/// `%Function.prototype%`, its `[[Realm]]` is the installing
/// realm, and its `.name` is the `"get "` / `"set "`-prefixed
/// form per §10.2.9 SetFunctionName.
fn expectCanonicalAccessorFn(
    realm: *Realm,
    fn_obj_opt: ?*@import("function.zig").JSFunction,
    expected_name: []const u8,
) !void {
    const fn_obj = fn_obj_opt orelse {
        std.debug.print("[accessor-shape] missing accessor fn \"{s}\"\n", .{expected_name});
        return error.MissingAccessorFn;
    };
    try testing.expect(!fn_obj.has_construct);
    try testing.expect(fn_obj.proto == realm.intrinsics.function_prototype);
    try testing.expect(fn_obj.realm == realm);
    try testing.expect(fn_obj.name != null);
    try testing.expectEqualStrings(expected_name, fn_obj.name.?);
}

test "accessor-registration shape: @@species getters aren't constructors and carry [[Realm]]" {
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    // §22.1.2.5 / §24.1.2.2 / §27.2.4.10 etc. — `get C[@@species]`
    // is an accessor; its getter is a non-constructor built-in.
    const cases = [_][]const u8{ "Array", "Map", "Set", "Promise", "RegExp" };
    for (cases) |name| {
        const ctor_v = realm.globals.get(name) orelse {
            std.debug.print("[accessor-shape] no global {s}\n", .{name});
            return error.NoCtor;
        };
        const ctor = heap_mod.valueAsFunction(ctor_v) orelse return error.CtorNotFn;
        const acc: Accessor = ctor.accessors.get("@@species") orelse {
            std.debug.print("[accessor-shape] {s} missing @@species accessor\n", .{name});
            return error.NoSpeciesAccessor;
        };
        try expectCanonicalAccessorFn(&realm, acc.getter, "get [Symbol.species]");
    }
}

test "accessor-registration shape: Iterator.prototype accessor pairs aren't constructors" {
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    const iter_v = realm.globals.get("Iterator") orelse return error.NoIterator;
    const iter_ctor = heap_mod.valueAsFunction(iter_v) orelse return error.IteratorNotFn;
    const proto = iter_ctor.prototype orelse return error.NoIteratorProto;
    const proto_ext = proto.extension orelse return error.NoIteratorProtoExt;

    // §27.1.4.5 / §27.1.4.6 — `constructor` and `@@toStringTag` are
    // accessor pairs; neither the getter nor the setter constructs.
    const ctor_acc: Accessor = proto_ext.accessors.get("constructor") orelse return error.NoCtorAccessor;
    try expectCanonicalAccessorFn(&realm, ctor_acc.getter, "get constructor");
    try expectCanonicalAccessorFn(&realm, ctor_acc.setter, "set constructor");

    const tag_acc: Accessor = proto_ext.accessors.get("@@toStringTag") orelse return error.NoTagAccessor;
    try expectCanonicalAccessorFn(&realm, tag_acc.getter, "get [Symbol.toStringTag]");
    try expectCanonicalAccessorFn(&realm, tag_acc.setter, "set [Symbol.toStringTag]");
}

test "accessor-registration shape: simple installNativeGetter getters aren't constructors" {
    var realm = Realm.init(testing.allocator);
    realm.hardened = false;
    defer realm.deinit();
    try realm.installBuiltins();

    // §25.1.6 get ArrayBuffer.prototype.byteLength — a plain
    // `installNativeGetter` accessor; the getter is a non-constructor.
    const ab_v = realm.globals.get("ArrayBuffer") orelse return error.NoArrayBuffer;
    const ab_ctor = heap_mod.valueAsFunction(ab_v) orelse return error.ABNotFn;
    const ab_proto = ab_ctor.prototype orelse return error.NoABProto;
    const ab_ext = ab_proto.extension orelse return error.NoABProtoExt;
    const acc: Accessor = ab_ext.accessors.get("byteLength") orelse return error.NoByteLengthAccessor;
    try expectCanonicalAccessorFn(&realm, acc.getter, "get byteLength");
}
