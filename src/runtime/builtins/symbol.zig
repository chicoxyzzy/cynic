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
        .name = "Symbol", .ctor = symbolConstructor, .arity = 1,
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
    // computedKeyToString in interpreter.zig). Identity matches
    // (`Symbol.iterator === Symbol.iterator`) because the
    // constructor stores a fixed JSSymbol pointer per well-known
    // name. Real symbol-keyed property tables are later.
    try installWellKnownSymbol(realm, fn_obj, "iterator", "@@iterator");
    try installWellKnownSymbol(realm, fn_obj, "asyncIterator", "@@asyncIterator");
    try installWellKnownSymbol(realm, fn_obj, "hasInstance", "@@hasInstance");
    try installWellKnownSymbol(realm, fn_obj, "toPrimitive", "@@toPrimitive");
    try installWellKnownSymbol(realm, fn_obj, "toStringTag", "@@toStringTag");
    try installWellKnownSymbol(realm, fn_obj, "isConcatSpreadable", "@@isConcatSpreadable");
    try installWellKnownSymbol(realm, fn_obj, "species", "@@species");
    try installWellKnownSymbol(realm, fn_obj, "match", "@@match");
    try installWellKnownSymbol(realm, fn_obj, "replace", "@@replace");
    try installWellKnownSymbol(realm, fn_obj, "search", "@@search");
    try installWellKnownSymbol(realm, fn_obj, "split", "@@split");
    try installWellKnownSymbol(realm, fn_obj, "unscopables", "@@unscopables");

    try installNativeMethod(realm, fn_obj, "for", symbolFor, 1);
    try installNativeMethod(realm, fn_obj, "keyFor", symbolKeyFor, 1);

    // §20.4.3 Symbol.prototype methods + the `description` accessor.
    try installNativeMethodOnProto(realm, proto, "toString", symbolToString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", symbolValueOf, 0);
    try installNativeGetter(realm, proto, "description", symbolDescriptionGetter);
}

fn symbolToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const sym = heap_mod.valueAsSymbol(this_value) orelse return throwTypeError(realm, "Symbol.prototype.toString requires a Symbol receiver");
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
    const sym = heap_mod.valueAsSymbol(this_value) orelse return throwTypeError(realm, "Symbol.prototype.description requires a Symbol receiver");
    if (sym.description) |d| {
        const s = realm.heap.allocateString(d) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    return Value.undefined_;
}

fn installWellKnownSymbol(realm: *Realm, ctor: *JSFunction, name: []const u8, description: []const u8) !void {
    const desc = try realm.heap.allocateString(description);
    // The `description` doubles as the property-key string —
    // intrinsic installations under e.g. `"@@iterator"` are
    // reached via `obj[Symbol.iterator]` because the symbol's
    // `prop_key` is exactly `"@@iterator"`.
    const sym = try realm.heap.allocateWellKnownSymbol(desc.bytes, description);
    try ctor.set(realm.allocator, name, heap_mod.taggedSymbol(sym));
}

fn symbolConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    var desc: ?[]const u8 = null;
    if (args.len > 0 and !args[0].isUndefined()) {
        const desc_str = stringifyArg(realm, args[0]) catch return error.OutOfMemory;
        desc = desc_str.bytes;
    }
    const sym = realm.heap.allocateSymbol(desc) catch return error.OutOfMemory;
    return heap_mod.taggedSymbol(sym);
}

fn symbolFor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §20.4.2.2 Symbol.for — interns into the realm's global
    // symbol registry. ToString the key first.
    const key_str = if (args.len > 0)
        stringifyArg(realm, args[0]) catch return error.OutOfMemory
    else
        realm.heap.allocateString("undefined") catch return error.OutOfMemory;
    if (realm.heap.symbol_registry.get(key_str.bytes)) |existing| {
        return heap_mod.taggedSymbol(existing);
    }
    const sym = realm.heap.allocateSymbol(key_str.bytes) catch return error.OutOfMemory;
    sym.is_registered = true;
    realm.heap.symbol_registry.put(realm.allocator, key_str.bytes, sym) catch return error.OutOfMemory;
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

