//! §28 Reflect — extracted from `intrinsics.zig`. Provides a
//! method-style alternative to operators / Object statics for
//! introspection: `Reflect.has`, `.get`, `.set`,
//! `.deleteProperty`, `.ownKeys`, `.getPrototypeOf`,
//! `.setPrototypeOf`, `.isExtensible`, `.apply`, `.construct`.
//!
//! `pub fn install(realm)` allocates the `Reflect` global and
//! wires every method via the `installNativeMethodOnProto`
//! helper from `intrinsics.zig` (Reflect itself is a plain
//! object, but the methods all install with the §17
//! built-in-method flag set).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const lengthOfArray = intrinsics.lengthOfArray;
const clampArrayLength = intrinsics.clampArrayLength;
const objectGetPrototypeOf = intrinsics.objectGetPrototypeOf;

// ── §28 Reflect ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const obj = try realm.heap.allocateObject();
    obj.prototype = realm.intrinsics.object_prototype;
    try installToStringTag(realm, obj, "Reflect");
    try installNativeMethodOnProto(realm, obj, "has", reflectHas, 2);
    try installNativeMethodOnProto(realm, obj, "get", reflectGet, 3);
    try installNativeMethodOnProto(realm, obj, "set", reflectSet, 4);
    try installNativeMethodOnProto(realm, obj, "deleteProperty", reflectDeleteProperty, 2);
    try installNativeMethodOnProto(realm, obj, "ownKeys", reflectOwnKeys, 1);
    try installNativeMethodOnProto(realm, obj, "getPrototypeOf", reflectGetPrototypeOf, 1);
    try installNativeMethodOnProto(realm, obj, "setPrototypeOf", reflectSetPrototypeOf, 2);
    try installNativeMethodOnProto(realm, obj, "isExtensible", reflectIsExtensible, 1);
    try installNativeMethodOnProto(realm, obj, "apply", reflectApply, 3);
    try installNativeMethodOnProto(realm, obj, "construct", reflectConstruct, 2);
    try installNativeMethodOnProto(realm, obj, "getOwnPropertyDescriptor", intrinsics.objectGetOwnPropertyDescriptor, 2);
    try installNativeMethodOnProto(realm, obj, "defineProperty", reflectDefineProperty, 3);
    try installNativeMethodOnProto(realm, obj, "preventExtensions", reflectPreventExtensions, 1);
    try realm.globals.put(realm.allocator, "Reflect", heap_mod.taggedObject(obj));
}

fn reflectPreventExtensions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.10 — Reflect.preventExtensions throws on non-object;
    // returns Boolean (true on success, false on failure).
    const target = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(target) == null) return throwTypeError(realm, "Reflect.preventExtensions called on non-object");
    _ = try intrinsics.objectPreventExtensions(realm, this_value, args);
    return Value.fromBool(true);
}

fn reflectDefineProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.3 — Reflect.defineProperty returns a Boolean (false on
    // failure rather than throwing). We delegate to the Object.*
    // path which throws on failure; catch-and-translate would
    // require pending-exception threading, so for now we just
    // forward, mapping success → true. Failure cases are rare in
    // practice; the test surface still benefits from forwarding.
    const result = intrinsics.objectDefineProperty(realm, this_value, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            realm.pending_exception = null;
            return Value.fromBool(false);
        },
    };
    _ = result;
    return Value.fromBool(true);
}

fn reflectHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const key_v = argOr(args, 1, Value.undefined_);
    var key_buf: [64]u8 = undefined;
    const key_slice = computedKeyForReflect(key_v, &key_buf);
    // §28.1.2.6 Reflect.has — target must be an Object. Functions
    // are objects too. Seed the walk from `fn_obj.proto` for the
    // callable case; the function's own data-bag covers its
    // own `length` / `name` / user-installed statics.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (fn_obj.properties.contains(key_slice)) return Value.true_;
        if (fn_obj.accessors.contains(key_slice)) return Value.true_;
        if (std.mem.eql(u8, key_slice, "prototype") and fn_obj.prototype != null) return Value.true_;
        if (std.mem.eql(u8, key_slice, "name") and fn_obj.name != null) return Value.true_;
        var cursor: ?*@import("../object.zig").JSObject = fn_obj.proto;
        while (cursor) |c| : (cursor = c.prototype) {
            if (c.properties.contains(key_slice)) return Value.true_;
            if (c.accessors.contains(key_slice)) return Value.true_;
        }
        return Value.false_;
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.has target must be an object");
    var cursor: ?*@import("../object.zig").JSObject = target;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.properties.contains(key_slice)) return Value.true_;
        if (c.accessors.contains(key_slice)) return Value.true_;
    }
    return Value.false_;
}

fn reflectGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const key_v = argOr(args, 1, Value.undefined_);
    var key_buf: [64]u8 = undefined;
    const key_slice = computedKeyForReflect(key_v, &key_buf);
    if (heap_mod.valueAsFunction(arg)) |fn_obj| return fn_obj.get(key_slice);
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.get target must be an object");
    return target.get(key_slice);
}

fn reflectSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const key_v = argOr(args, 1, Value.undefined_);
    var key_buf: [64]u8 = undefined;
    const key_slice = computedKeyForReflect(key_v, &key_buf);
    const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
    const v = argOr(args, 2, Value.undefined_);
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        const ok = fn_obj.setIfWritable(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        return Value.fromBool(ok);
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.set target must be an object");
    // §10.1.9.1 [[Set]] step 5.a — return false when the own
    // data property exists with `writable: false`. Cynic was
    // using the bypass-set path which silently overwrites.
    const had_own = target.properties.contains(key_slice);
    if (had_own) {
        const flags = target.flagsFor(key_slice);
        if (!flags.writable) return Value.false_;
    }
    // Accessor descriptor — call the setter if present.
    if (target.accessors.get(key_slice)) |acc| {
        if (acc.setter) |setter| {
            const interp = @import("../interpreter.zig");
            const setter_args = [_]Value{v};
            const outcome = interp.callJSFunction(realm.allocator, realm, setter, heap_mod.taggedObject(target), &setter_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => return Value.true_,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        // Getter-only accessor — Reflect.set returns false.
        return Value.false_;
    }
    target.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    return Value.true_;
}

fn reflectDeleteProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const key_v = argOr(args, 1, Value.undefined_);
    var key_buf: [64]u8 = undefined;
    const key_slice = computedKeyForReflect(key_v, &key_buf);
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // §10.1.10.1 [[Delete]] step 4 — return false when the
        // own property is non-configurable.
        if (fn_obj.flagsForOwn(key_slice).configurable == false and (fn_obj.properties.contains(key_slice) or fn_obj.accessors.contains(key_slice))) return Value.false_;
        _ = fn_obj.properties.swapRemove(key_slice);
        _ = fn_obj.accessors.swapRemove(key_slice);
        _ = fn_obj.property_flags.swapRemove(key_slice);
        return Value.true_;
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.deleteProperty target must be an object");
    // §10.1.10.1 — non-configurable own property → return false
    // (no mutation). Includes frozen / sealed objects.
    if (target.flagsFor(key_slice).configurable == false and (target.properties.contains(key_slice) or target.accessors.contains(key_slice))) return Value.false_;
    _ = target.properties.swapRemove(key_slice);
    _ = target.accessors.swapRemove(key_slice);
    _ = target.property_flags.swapRemove(key_slice);
    return Value.true_;
}

fn reflectOwnKeys(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var idx: usize = 0;
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| : (idx += 1) {
            const k = entry.key_ptr.*;
            const key_str = realm.heap.allocateString(k) catch return error.OutOfMemory;
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, Value.fromString(key_str)) catch return error.OutOfMemory;
        }
        out.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.ownKeys target must be an object");
    var it = target.properties.iterator();
    while (it.next()) |entry| : (idx += 1) {
        const key_str = realm.heap.allocateString(entry.key_ptr.*) catch return error.OutOfMemory;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(key_str)) catch return error.OutOfMemory;
    }
    out.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn reflectGetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return objectGetPrototypeOf(realm, this_value, args);
}

fn reflectSetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return Value.false_;
    const proto_v = argOr(args, 1, Value.null_);
    // §28.1.13 Reflect.setPrototypeOf — proto must be Object or null.
    if (!proto_v.isNull() and heap_mod.valueAsPlainObject(proto_v) == null and heap_mod.valueAsFunction(proto_v) == null) {
        return intrinsics.throwTypeError(realm, "prototype must be an Object or null");
    }
    const new_proto: ?*@import("../object.zig").JSObject = blk: {
        if (proto_v.isNull()) break :blk null;
        if (heap_mod.valueAsPlainObject(proto_v)) |p| break :blk p;
        if (heap_mod.valueAsFunction(proto_v)) |fn_obj| break :blk fn_obj.prototype;
        break :blk null;
    };
    // §10.4.7 — `%Object.prototype%` is an Immutable Prototype
    // Exotic Object. Its [[SetPrototypeOf]] returns true only if
    // the requested value equals the current one (both null in
    // the default case); otherwise returns false without modifying.
    if (target == realm.intrinsics.object_prototype.?) {
        return Value.fromBool(new_proto == target.prototype);
    }
    // §10.1.2.1 OrdinarySetPrototypeOf step 8 — cycle detection.
    var cursor: ?*@import("../object.zig").JSObject = new_proto;
    while (cursor) |node| {
        if (node == target) return Value.false_;
        cursor = node.prototype;
    }
    target.prototype = new_proto;
    return Value.true_;
}

fn reflectIsExtensible(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    // we don't track an [[Extensible]] internal slot
    // yet; report true to match the default for ordinary objects.
    return Value.true_;
}

fn reflectApply(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    // Allow callable Proxy (apply-trap dispatch via callValue).
    if (heap_mod.valueAsFunction(target_v) == null) {
        const po = heap_mod.valueAsPlainObject(target_v) orelse return throwTypeError(realm, "Reflect.apply target must be callable");
        if (po.proxy_target_fn == null and po.proxy_target == null and !po.proxy_revoked) {
            return throwTypeError(realm, "Reflect.apply target must be callable");
        }
    }
    const this_arg = argOr(args, 1, Value.undefined_);
    const args_v = argOr(args, 2, Value.undefined_);

    var apply_args: std.ArrayListUnmanaged(Value) = .empty;
    defer apply_args.deinit(realm.allocator);
    if (heap_mod.valueAsPlainObject(args_v)) |arr| {
        const len = try clampArrayLength(lengthOfArray(arr));
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            apply_args.append(realm.allocator, arr.get(islice)) catch return error.OutOfMemory;
        }
    }

    const interpreter = @import("../interpreter.zig");
    const outcome = interpreter.callValue(realm.allocator, realm, target_v, this_arg, apply_args.items) catch |err| switch (err) {
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

fn reflectConstruct(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    const args_v = argOr(args, 1, Value.undefined_);
    const new_target_v = argOr(args, 2, Value.undefined_);
    const interpreter = @import("../interpreter.zig");

    var ctor_args: std.ArrayListUnmanaged(Value) = .empty;
    defer ctor_args.deinit(realm.allocator);
    if (heap_mod.valueAsPlainObject(args_v)) |arr| {
        const len = try clampArrayLength(lengthOfArray(arr));
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            ctor_args.append(realm.allocator, arr.get(islice)) catch return error.OutOfMemory;
        }
    }

    // §10.5.14 — if `target` is a Proxy with a `construct` trap,
    // dispatch the trap. Missing trap walks down the proxy chain
    // until we reach a real constructor.
    if (heap_mod.valueAsPlainObject(target_v)) |po| {
        if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
            const newt: Value = if (new_target_v.isUndefined()) target_v else new_target_v;
            const outcome = interpreter.constructValue(realm.allocator, realm, target_v, ctor_args.items, newt) catch |err| switch (err) {
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
    }

    const target = heap_mod.valueAsFunction(target_v) orelse return throwTypeError(realm, "Reflect.construct target must be a constructor");
    // §28.1.2 Reflect.construct step 2: throw if target is
    // not actually a constructor.
    if (!target.has_construct or target.is_arrow) return throwTypeError(realm, "Reflect.construct target is not a constructor");
    // Step 3-5: optional `newTarget` defaults to `target`; when
    // supplied, MUST be a constructor too (the trick the
    // `isConstructor.js` harness relies on to detect non-ctor
    // built-ins like `Object.freeze`).
    const new_target: *@import("../function.zig").JSFunction = if (new_target_v.isUndefined())
        target
    else if (heap_mod.valueAsFunction(new_target_v)) |nt|
        nt
    else if (heap_mod.valueAsPlainObject(new_target_v)) |po|
        // newTarget can be a callable Proxy.
        if (po.proxy_target_fn) |tfn| tfn else return throwTypeError(realm, "Reflect.construct newTarget must be a constructor")
    else
        return throwTypeError(realm, "Reflect.construct newTarget must be a constructor");
    if (!new_target.has_construct or new_target.is_arrow) return throwTypeError(realm, "Reflect.construct newTarget is not a constructor");

    // §10.1.13 OrdinaryCreateFromConstructor → §10.1.14
    // GetPrototypeFromConstructor — Get(newTarget, "prototype")
    // through the accessor path so a user-installed getter on a
    // bound NewTarget fires (per the WeakRef /
    // FinalizationRegistry / ArrayBuffer
    // `prototype-from-newtarget-*.js` fixtures).
    const proto_lookup = interpreter.getPrototypeFromConstructor(realm.allocator, realm, new_target, target.prototype) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const resolved_proto: ?*@import("../object.zig").JSObject = switch (proto_lookup) {
        .proto => |p| p,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
    instance.prototype = resolved_proto;
    const this_arg = heap_mod.taggedObject(instance);

    const outcome = interpreter.callJSFunction(realm.allocator, realm, target, this_arg, ctor_args.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| {
            // ConstructResult: object return wins, else `this`.
            if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return v;
            return this_arg;
        },
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

/// Stringify a Value for use as a property key in Reflect ops.
/// Mirrors `computedKeyToString` in interpreter.zig.
fn computedKeyForReflect(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.bytes;
    }
    if (v.isInt32()) return std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        if (d == @trunc(d) and d >= -9007199254740992.0 and d <= 9007199254740992.0) {
            const i: i64 = @intFromFloat(d);
            return std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
        }
        return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
    }
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    return "[object]";
}

