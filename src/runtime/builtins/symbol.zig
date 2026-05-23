//! §20.4 Symbol — extracted from `intrinsics.zig`. Cynic
//! encodes Symbols as a separate pointer-tagged variant of the
//! NaN-boxed Value (see `runtime/heap.zig`); this module owns
//! the Symbol *constructor* surface (the global `Symbol(...)` /
//! `Symbol.for` / `Symbol.iterator` etc.).
//!
//! Heap-side symbol primitives live in `runtime/symbol.zig`;
//! this file is purely the JS-visible installer.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const JSSymbol = @import("../symbol.zig").JSSymbol;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const stringifyArg = intrinsics.stringifyArg;
const throwTypeError = intrinsics.throwTypeError;

// ── Symbol (placeholder primitive — still a tagged wrapper for now) ─────────

pub fn install(realm: *Realm) !void {
    // §20.4 Symbol — Cynic encodes Symbols as a separate
    // pointer-tagged variant of the NaN-boxed Value (see
    // heap.zig). Each `JSSymbol` is identity-unique. Symbols
    // have no `.prototype` chain in the spec, but `Symbol`
    // itself does carry a prototype object for `Object(sym)`
    // boxing.
    const r = try installConstructor(realm, .{
        .name = "Symbol",
        .ctor = symbolConstructor,
        // §20.4.1 — `Symbol`'s `length` is 0; the description
        // parameter is optional and §17 length-counts only the
        // arguments before the first optional / rest / destructure.
        .arity = 0,
        .is_class = false,
        .set_home_object = false,
        .to_string_tag = "Symbol",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §20.4.2 Well-known Symbols. Each is a real Symbol primitive
    // with a description that doubles as the property-key string
    // when used as a computed key (so `obj[Symbol.iterator]` and
    // `obj["@@iterator"]` resolve to the same slot — see
    // computedKeyToString in lantern.zig). Identity matches
    // (`Symbol.iterator === Symbol.iterator`) because the
    // constructor stores a fixed JSSymbol pointer per well-known
    // name. Real symbol-keyed property tables are later.
    // §20.4.2.* — well-known symbols' description-strings are
    // their `"Symbol.<name>"` form per §20.4.3.4 (so
    // `String(Symbol.iterator) === "Symbol(Symbol.iterator)"`).
    // The third argument is the internal property-key Cynic uses
    // to install methods like `obj["@@iterator"]`; user JS still
    // reaches them via `obj[Symbol.iterator]` because the symbol
    // value's `prop_key` is exactly that string.
    try installWellKnownSymbol(realm, fn_obj, "iterator", "Symbol.iterator", "@@iterator");
    try installWellKnownSymbol(realm, fn_obj, "asyncIterator", "Symbol.asyncIterator", "@@asyncIterator");
    try installWellKnownSymbol(realm, fn_obj, "hasInstance", "Symbol.hasInstance", "@@hasInstance");
    try installWellKnownSymbol(realm, fn_obj, "toPrimitive", "Symbol.toPrimitive", "@@toPrimitive");
    try installWellKnownSymbol(realm, fn_obj, "toStringTag", "Symbol.toStringTag", "@@toStringTag");
    try installWellKnownSymbol(realm, fn_obj, "isConcatSpreadable", "Symbol.isConcatSpreadable", "@@isConcatSpreadable");
    try installWellKnownSymbol(realm, fn_obj, "species", "Symbol.species", "@@species");
    try installWellKnownSymbol(realm, fn_obj, "match", "Symbol.match", "@@match");
    try installWellKnownSymbol(realm, fn_obj, "replace", "Symbol.replace", "@@replace");
    try installWellKnownSymbol(realm, fn_obj, "search", "Symbol.search", "@@search");
    try installWellKnownSymbol(realm, fn_obj, "split", "Symbol.split", "@@split");
    try installWellKnownSymbol(realm, fn_obj, "matchAll", "Symbol.matchAll", "@@matchAll");
    try installWellKnownSymbol(realm, fn_obj, "unscopables", "Symbol.unscopables", "@@unscopables");

    try installNativeMethod(realm, fn_obj, "for", symbolFor, 1);
    try installNativeMethod(realm, fn_obj, "keyFor", symbolKeyFor, 1);

    // §20.4.3 Symbol.prototype methods + the `description` accessor.
    try installNativeMethodOnProto(realm, proto, "toString", symbolToString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", symbolValueOf, 0);
    try installNativeGetter(realm, proto, "description", symbolDescriptionGetter);

    // §20.4.3.4 Symbol.prototype [ @@toPrimitive ] (hint) —
    // returns the underlying Symbol primitive regardless of
    // hint. Descriptor `{ w:false, e:false, c:true }` per the
    // spec; `.length === 1` because it accepts the hint arg.
    const to_prim = try realm.heap.allocateFunctionNative(symbolToPrimitive, 1, "[Symbol.toPrimitive]");
    to_prim.proto = realm.intrinsics.function_prototype;
    to_prim.has_construct = false;
    try proto.setWithFlags(realm.allocator, "@@toPrimitive", heap_mod.taggedFunction(to_prim), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
}

/// §20.4.3.4 Symbol.prototype [ @@toPrimitive ]. The hint is
/// ignored — symbols never coerce to a number, and ToString /
/// String conversion is handled by stringConstructor's special
/// case. Always returns the underlying Symbol primitive, or
/// throws TypeError if the receiver isn't a Symbol / boxed
/// Symbol wrapper.
fn symbolToPrimitive(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return symbolValueOf(realm, this_value, &.{});
}

/// §20.4.3.3.1 ThisSymbolValue(value) — accepts either a Symbol
/// primitive or a Symbol wrapper object (whose [[SymbolData]]
/// internal slot lives in `boxed_primitive`). Used by every
/// Symbol.prototype method per spec.
fn thisSymbolValue(this_value: Value) ?*@import("../symbol.zig").JSSymbol {
    if (heap_mod.valueAsSymbol(this_value)) |s| return s;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_primitive) |bp| {
            if (heap_mod.valueAsSymbol(bp)) |s| return s;
        }
    }
    return null;
}

fn symbolToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const sym = thisSymbolValue(this_value) orelse return throwTypeError(realm, "Symbol.prototype.toString requires a Symbol receiver");
    var buf: [128]u8 = undefined;
    const desc: []const u8 = sym.description orelse "";
    const slice = std.fmt.bufPrint(&buf, "Symbol({s})", .{desc}) catch return error.OutOfMemory;
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn symbolValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    if (heap_mod.valueAsSymbol(this_value) != null) return this_value;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_primitive) |bp| {
            if (heap_mod.valueAsSymbol(bp) != null) return bp;
        }
    }
    return error.NativeThrew;
}

fn symbolDescriptionGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const sym = thisSymbolValue(this_value) orelse return throwTypeError(realm, "Symbol.prototype.description requires a Symbol receiver");
    if (sym.description) |d| {
        const s = realm.heap.allocateString(d) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    return Value.undefined_;
}

fn installWellKnownSymbol(
    realm: *Realm,
    ctor: *JSFunction,
    name: []const u8,
    description: []const u8,
    prop_key: []const u8,
) !void {
    const desc = try realm.heap.allocateString(description);
    const sym = try realm.heap.allocateWellKnownSymbol(desc.flatBytes(), prop_key);
    // §20.4.2 — well-known symbols on the Symbol constructor are
    // frozen data properties: `{ w:false, e:false, c:false }`.
    try ctor.setWithFlags(realm.allocator, name, heap_mod.taggedSymbol(sym), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
}

fn symbolConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §20.4.1.1 step 1 — Symbol called as a constructor (`new
    // Symbol(...)`) throws TypeError. The fresh `this_value`
    // allocated for `new` is a JSObject; the plain-call form
    // gets `undefined` (or globalThis). Functions called as
    // constructors carry a non-undefined this; reject those.
    if (heap_mod.valueAsPlainObject(this_value) != null) {
        return throwTypeError(realm, "Symbol is not a constructor");
    }
    var desc: ?[]const u8 = null;
    if (args.len > 0 and !args[0].isUndefined()) {
        const desc_str = try stringifyArg(realm, args[0]);
        desc = desc_str.flatBytes();
    }
    const sym = realm.heap.allocateSymbol(desc) catch return error.OutOfMemory;
    return heap_mod.taggedSymbol(sym);
}

fn symbolFor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §20.4.2.2 Symbol.for — interns into the realm's global
    // symbol registry. ToString the key first.
    const key_str = if (args.len > 0)
        try stringifyArg(realm, args[0])
    else
        realm.heap.allocateString("undefined") catch return error.OutOfMemory;
    if (realm.heap.symbol_registry.get(key_str.flatBytes())) |existing| {
        return heap_mod.taggedSymbol(existing);
    }
    const sym = realm.heap.allocateSymbol(key_str.flatBytes()) catch return error.OutOfMemory;
    sym.is_registered = true;
    // §20.4.2.2 GlobalSymbolRegistry has no spec'd eviction —
    // pin so the GC keeps the entry alive for the realm's
    // lifetime. Replaces the per-cycle re-mark loop the heap
    // used to do over `symbol_registry`.
    sym.pinned = true;
    realm.heap.symbol_registry.put(realm.allocator, key_str.flatBytes(), sym) catch return error.OutOfMemory;
    return heap_mod.taggedSymbol(sym);
}
fn symbolKeyFor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §20.4.2.6 Symbol.keyFor — return the registry key if `sym`
    // was created by `Symbol.for`, else `undefined`.
    if (args.len == 0) return throwTypeError(realm, "Symbol.keyFor requires a Symbol argument");
    const sym = heap_mod.valueAsSymbol(args[0]) orelse return throwTypeError(realm, "Symbol.keyFor argument is not a Symbol");
    if (!sym.is_registered) return Value.undefined_;
    if (sym.description) |d| {
        const s = realm.heap.allocateString(d) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    return Value.undefined_;
}
