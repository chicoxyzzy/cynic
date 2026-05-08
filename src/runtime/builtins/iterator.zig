//! §27.1.4 Iterator (TC39 stage-4 helpers). Installs the
//! `Iterator` global with `Iterator.from(iterable)` and a
//! prototype carrying `.map` / `.filter` / `.take` / `.drop` /
//! `.toArray` / `.forEach` / `.find` / `.some` / `.every`.
//!
//! Each helper that returns a new iterator (`.map`, `.filter`,
//! `.take`, `.drop`) builds a wrapper object whose `next` method
//! pulls from the source and applies the transform. Eagerly-
//! evaluated helpers (`.toArray`, `.forEach`, etc.) drain the
//! source.

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

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "Iterator", .ctor = iteratorConstructor, .arity = 0,
        .set_home_object = false,
        .to_string_tag = "Iterator",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeMethod(realm, fn_obj, "from", iteratorFrom, 1);

    try installNativeMethodOnProto(realm, proto, "map", iteratorMap, 1);
    try installNativeMethodOnProto(realm, proto, "filter", iteratorFilter, 1);
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
}

fn iteratorConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = this_value;
    return throwTypeError(realm, "Iterator is not directly callable");
}

/// `Iterator.from(x)` — wrap any iterable in an Iterator instance.
fn iteratorFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const inner = interpreter.openIterator(realm.allocator, realm, arg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Iterator.from argument is not iterable"),
    };
    return wrapIterator(realm, inner);
}

/// Wrap a raw iterator object (the kind `openIterator` returns)
/// in a fresh helper object whose prototype is %Iterator.prototype%.
/// The wrapper's `next` delegates to the source iterator's `next`.
fn wrapIterator(realm: *Realm, source: Value) NativeError!Value {
    const ctor_v = realm.globals.get("Iterator") orelse return source;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return source;
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_source__", source) catch return error.OutOfMemory;
    const next_fn = realm.heap.allocateFunctionNative(wrappedNext, 0, "next") catch return error.OutOfMemory;
    next_fn.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(next_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn wrappedNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Iterator next on non-object");
    const src = obj.get("__cynic_iter_source__");
    return invokeIterNext(realm, src);
}

fn invokeIterNext(realm: *Realm, iter: Value) NativeError!Value {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "iterator is not an object");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator has no callable next");
    const out = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| v,
        .thrown => return error.NativeThrew,
    };
}

fn iteratorSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

// ── Lazy helpers — return new iterator wrappers ─────────────────────────────

fn iteratorMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) return throwTypeError(realm, "Iterator.prototype.map callback is not callable");
    return buildLazy(realm, this_value, "map", cb_v, mapNext);
}

fn iteratorFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb_v) == null) return throwTypeError(realm, "Iterator.prototype.filter callback is not callable");
    return buildLazy(realm, this_value, "filter", cb_v, filterNext);
}

fn iteratorTake(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const n_v = argOr(args, 0, Value.undefined_);
    const n: i32 = if (n_v.isInt32()) n_v.asInt32() else if (n_v.isDouble()) blk: {
        const d = n_v.asDouble();
        if (std.math.isNan(d) or d < 0) break :blk 0;
        break :blk @intFromFloat(d);
    } else 0;
    return buildLazy(realm, this_value, "take", Value.fromInt32(n), takeNext);
}

fn iteratorDrop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const n_v = argOr(args, 0, Value.undefined_);
    const n: i32 = if (n_v.isInt32()) n_v.asInt32() else if (n_v.isDouble()) blk: {
        const d = n_v.asDouble();
        if (std.math.isNan(d) or d < 0) break :blk 0;
        break :blk @intFromFloat(d);
    } else 0;
    return buildLazy(realm, this_value, "drop", Value.fromInt32(n), dropNext);
}

fn buildLazy(realm: *Realm, source: Value, kind: []const u8, payload: Value, next_fn: @import("../function.zig").NativeFn) NativeError!Value {
    _ = kind;
    const ctor_v = realm.globals.get("Iterator") orelse return throwTypeError(realm, "Iterator constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "Iterator constructor missing");
    const wrap = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrap.prototype = ctor.prototype;
    wrap.set(realm.allocator, "__cynic_iter_source__", source) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_payload__", payload) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(0)) catch return error.OutOfMemory;
    wrap.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    const fn_obj = realm.heap.allocateFunctionNative(next_fn, 0, "next") catch return error.OutOfMemory;
    fn_obj.has_construct = false;
    wrap.setWithFlags(realm.allocator, "next", heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(wrap);
}

fn doneResult(realm: *Realm) NativeError!Value {
    return iterResult(realm, Value.undefined_, true);
}

fn mapNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "map iter on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    const src = obj.get("__cynic_iter_source__");
    const result = try invokeIterNext(realm, src);
    const result_obj = heap_mod.valueAsPlainObject(result) orelse return doneResult(realm);
    if (intrinsics.toBoolean(result_obj.get("done"))) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    const cb = heap_mod.valueAsFunction(obj.get("__cynic_iter_payload__")) orelse return doneResult(realm);
    const idx_v = obj.get("__cynic_iter_count__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
    obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
    const args_call = [_]Value{ result_obj.get("value"), Value.fromInt32(idx) };
    const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => return error.NativeThrew,
    };
    return iterResult(realm, v, false);
}

fn filterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "filter iter on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    const src = obj.get("__cynic_iter_source__");
    const cb = heap_mod.valueAsFunction(obj.get("__cynic_iter_payload__")) orelse return doneResult(realm);
    while (true) {
        const result = try invokeIterNext(realm, src);
        const result_obj = heap_mod.valueAsPlainObject(result) orelse return doneResult(realm);
        if (intrinsics.toBoolean(result_obj.get("done"))) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
            return doneResult(realm);
        }
        const idx_v = obj.get("__cynic_iter_count__");
        const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
        obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
        const value = result_obj.get("value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => return error.NativeThrew,
        };
        if (pass) return iterResult(realm, value, false);
    }
}

fn takeNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "take iter on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    const limit_v = obj.get("__cynic_iter_payload__");
    const limit: i32 = if (limit_v.isInt32()) limit_v.asInt32() else 0;
    const idx_v = obj.get("__cynic_iter_count__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;
    if (idx >= limit) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    obj.set(realm.allocator, "__cynic_iter_count__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
    const src = obj.get("__cynic_iter_source__");
    const result = try invokeIterNext(realm, src);
    const result_obj = heap_mod.valueAsPlainObject(result) orelse return doneResult(realm);
    if (intrinsics.toBoolean(result_obj.get("done"))) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    return iterResult(realm, result_obj.get("value"), false);
}

fn dropNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "drop iter on non-object");
    if (intrinsics.toBoolean(obj.get("__cynic_iter_done__"))) return doneResult(realm);
    const drop_v = obj.get("__cynic_iter_payload__");
    var drop_remaining: i32 = if (drop_v.isInt32()) drop_v.asInt32() else 0;
    const src = obj.get("__cynic_iter_source__");
    while (drop_remaining > 0) : (drop_remaining -= 1) {
        const r = try invokeIterNext(realm, src);
        const ro = heap_mod.valueAsPlainObject(r) orelse return doneResult(realm);
        if (intrinsics.toBoolean(ro.get("done"))) {
            obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
            obj.set(realm.allocator, "__cynic_iter_payload__", Value.fromInt32(0)) catch return error.OutOfMemory;
            return doneResult(realm);
        }
    }
    obj.set(realm.allocator, "__cynic_iter_payload__", Value.fromInt32(0)) catch return error.OutOfMemory;
    const result = try invokeIterNext(realm, src);
    const result_obj = heap_mod.valueAsPlainObject(result) orelse return doneResult(realm);
    if (intrinsics.toBoolean(result_obj.get("done"))) {
        obj.set(realm.allocator, "__cynic_iter_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return doneResult(realm);
    }
    return iterResult(realm, result_obj.get("value"), false);
}

// ── Eager helpers — drain the source ────────────────────────────────────────

fn iteratorToArray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var idx: i32 = 0;
    var ibuf: [24]u8 = undefined;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, ro.get("value")) catch return error.OutOfMemory;
        idx += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn iteratorForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Iterator.prototype.forEach callback is not callable");
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const args_call = [_]Value{ ro.get("value"), Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (out) {
            .value, .yielded => {},
            .thrown => return error.NativeThrew,
        }
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Iterator.prototype.find callback is not callable");
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const value = ro.get("value");
        const args_call = [_]Value{ value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => return error.NativeThrew,
        };
        if (pass) return value;
        idx += 1;
    }
    return Value.undefined_;
}

fn iteratorSome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Iterator.prototype.some callback is not callable");
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const args_call = [_]Value{ ro.get("value"), Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => return error.NativeThrew,
        };
        if (pass) return Value.fromBool(true);
        idx += 1;
    }
    return Value.fromBool(false);
}

fn iteratorEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Iterator.prototype.every callback is not callable");
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const args_call = [_]Value{ ro.get("value"), Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const pass = switch (out) {
            .value, .yielded => |x| intrinsics.toBoolean(x),
            .thrown => return error.NativeThrew,
        };
        if (!pass) return Value.fromBool(false);
        idx += 1;
    }
    return Value.fromBool(true);
}

fn iteratorReduce(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Iterator.prototype.reduce callback is not callable");
    var has_acc: bool = args.len >= 2;
    var acc: Value = if (has_acc) args[1] else Value.undefined_;
    var idx: i32 = 0;
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const r = try invokeIterNext(realm, this_value);
        const ro = heap_mod.valueAsPlainObject(r) orelse break;
        if (intrinsics.toBoolean(ro.get("done"))) break;
        const value = ro.get("value");
        if (!has_acc) {
            acc = value;
            has_acc = true;
            idx += 1;
            continue;
        }
        const args_call = [_]Value{ acc, value, Value.fromInt32(idx) };
        const out = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        acc = switch (out) {
            .value, .yielded => |x| x,
            .thrown => return error.NativeThrew,
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
