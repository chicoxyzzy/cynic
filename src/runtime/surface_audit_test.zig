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
    var a_it = obj.accessors.iterator();
    while (a_it.next()) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
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

// TODO(spec): Object.prototype.toLocaleString (§20.1.3.4) is not
// installed yet. The Annex-B `__proto__`, `__defineGetter__`,
// `__defineSetter__`, `__lookupGetter__`, `__lookupSetter__` are
// kept (per AGENTS.md — Annex-B normative aliases are in scope);
// none are wired today and need to land when sloppy-mode subset
// is filled in. Add to this set as each lands.
const expect_object_prototype = [_][]const u8{
    "constructor",
    "hasOwnProperty",
    "isPrototypeOf",
    "propertyIsEnumerable",
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

// TODO(spec): String.prototype.length is the receiver's length on
// a wrapped String. The §22 build-out otherwise tracks ECMA-262
// 2024 — isWellFormed / toWellFormed are wired below.
const expect_string_prototype = [_][]const u8{
    "constructor",
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
