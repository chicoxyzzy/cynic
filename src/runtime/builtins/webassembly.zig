//! The `WebAssembly` JS namespace — the host API surface over Sarcasm
//! (the engine in `src/runtime/wasm/`).
//!
//! Today's surface: `WebAssembly.validate` (ungated — it only inspects
//! bytes), plus the `WebAssembly.Module` and `WebAssembly.Instance`
//! constructors and an instance's callable function exports, all gated
//! behind `--allow=wasm` (HostEnsureCanCompileWasmBytes; see
//! docs/wasm-engine.md §8-§9). All wasm artifacts live in the realm's
//! `wasm_arena`, freed at realm teardown, so they need no per-object
//! cleanup or GC marking.
//!
//! Not yet built (next slices): imported functions/globals/tables/
//! memories, the `Memory` / `Table` / `Global` objects, the
//! `instantiate` / `compile` Promises, the `CompileError` / `LinkError`
//! / `RuntimeError` types (TypeError stands in for now), and i64↔BigInt
//! / v128 / reference marshalling. `Instance.prototype.exports` is a
//! prototype getter per spec; this slice exposes the exports object as
//! an own data property for simplicity.

const std = @import("std");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const NativeError = @import("../function.zig").NativeError;
const intrinsics = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");
const arith = @import("../lantern/arith.zig");
const wasm = @import("../wasm/wasm.zig");

/// A `WebAssembly.Module`'s decoded record. Arena-owned.
const ModuleState = struct {
    module: *wasm.Module,
};

/// An exported function's backing data, stored on the JS function's
/// `wasm_export` slot. Arena-owned.
const ExportRecord = struct {
    instance: *wasm.Instance,
    func_index: u32,
};

pub fn install(realm: *Realm) !void {
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try intrinsics.installToStringTag(realm, ns, "WebAssembly");
    try intrinsics.installNativeMethodOnProto(realm, ns, "validate", wasmValidate, 1);

    // Constructors live under the namespace, not the global object.
    const module_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = moduleConstructor,
        .arity = 1,
        .name = "Module",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Module", heap_mod.taggedFunction(module_ctor.ctor));

    const instance_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = instanceConstructor,
        .arity = 1,
        .name = "Instance",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Instance", heap_mod.taggedFunction(instance_ctor.ctor));

    try realm.globals.put(realm.allocator, "WebAssembly", heap_mod.taggedObject(ns));
}

/// `WebAssembly.validate(bytes)` — true iff `bytes` decodes and
/// validates. Ungated: no code is generated.
fn wasmValidate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bytes = bufferSourceBytes(args) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.validate expects a BufferSource (ArrayBuffer or typed array)");

    var arena = std.heap.ArenaAllocator.init(realm.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = wasm.decode(a, bytes) catch return Value.fromBool(false);
    _ = wasm.validateModule(a, &module) catch return Value.fromBool(false);
    return Value.fromBool(true);
}

/// `new WebAssembly.Module(bytes)` — decode + validate `bytes` into a
/// realm-resident module. Gated by `--allow=wasm`.
fn moduleConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Module requires 'new'");
    const bytes = bufferSourceBytes(args) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Module expects a BufferSource");

    const a = realm.wasmAllocator();
    // The decoded module borrows slices from the source bytes, so both
    // must outlive it — keep a copy in the wasm arena.
    const owned = a.dupe(u8, bytes) catch return error.OutOfMemory;
    const mp = a.create(wasm.Module) catch return error.OutOfMemory;
    mp.* = wasm.decode(a, owned) catch
        return intrinsics.throwTypeError(realm, "WebAssembly.Module: invalid module (CompileError)");
    _ = wasm.validateModule(a, mp) catch
        return intrinsics.throwTypeError(realm, "WebAssembly.Module: invalid module (CompileError)");

    const state = a.create(ModuleState) catch return error.OutOfMemory;
    state.* = .{ .module = mp };
    self.wasm_module = state;
    return this_value;
}

/// `new WebAssembly.Instance(module, importObject?)` — instantiate a
/// `WebAssembly.Module` and expose its function exports. Gated.
fn instanceConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance requires 'new'");

    const mod_obj = if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null;
    const mstate_raw = (if (mod_obj) |o| o.wasm_module else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance expects a WebAssembly.Module");
    const mstate: *ModuleState = @ptrCast(@alignCast(mstate_raw));

    // Imports are not yet wired (next slice).
    if (mstate.module.imports.len > 0)
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: imports are not yet supported (LinkError)");

    const a = realm.wasmAllocator();
    const ip = a.create(wasm.Instance) catch return error.OutOfMemory;
    wasm.instantiate(ip, a, a, mstate.module, .{}) catch
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: instantiation failed (LinkError)");
    wasm.runStart(ip, a) catch
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: start function trapped (RuntimeError)");

    const exports = try buildExports(realm, ip, mstate.module);
    // Spec models `exports` as an Instance.prototype getter returning the
    // immutable [[Exports]]; this slice exposes it as a read-only own
    // property (also keeps it reachable for GC via the property bag).
    try self.setWithFlags(realm.allocator, "exports", exports, .{
        .writable = false,
        .enumerable = true,
        .configurable = false,
    });
    return this_value;
}

/// Build the exports namespace object: each function export becomes a
/// callable JS function carrying its `(instance, func_index)`.
/// Non-function exports are omitted in this slice.
fn buildExports(realm: *Realm, ip: *wasm.Instance, module: *const wasm.Module) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, null); // §exports object has a null prototype
    const a = realm.wasmAllocator();

    for (module.exports) |ex| {
        switch (ex.desc) {
            .func => |fidx| {
                const ft = ip.funcType(fidx) orelse continue;
                const fn_obj = intrinsics.makeNativeFunction(realm, exportTrampoline, @intCast(ft.params.len), ex.name) catch
                    return error.OutOfMemory;
                const rec = a.create(ExportRecord) catch return error.OutOfMemory;
                rec.* = .{ .instance = ip, .func_index = fidx };
                fn_obj.wasm_export = rec;
                obj.set(realm.allocator, ex.name, heap_mod.taggedFunction(fn_obj)) catch return error.OutOfMemory;
            },
            else => {}, // table / memory / global exports: next slice
        }
    }
    return heap_mod.taggedObject(obj);
}

/// Trampoline shared by every exported function. Recovers its
/// `ExportRecord` from the active native callee, marshals the JS
/// arguments to wasm operand cells, invokes, and marshals results back.
fn exportTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const callee = realm.active_native_fn orelse
        return intrinsics.throwTypeError(realm, "WebAssembly exported function: missing callee");
    const rec: *ExportRecord = @ptrCast(@alignCast(callee.wasm_export orelse
        return intrinsics.throwTypeError(realm, "WebAssembly exported function: missing export record")));
    const ft = rec.instance.funcType(rec.func_index) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly exported function: unknown type");

    var argbuf: [32]u128 = undefined;
    if (ft.params.len > argbuf.len)
        return intrinsics.throwTypeError(realm, "WebAssembly exported function: too many parameters");
    for (ft.params, 0..) |pt, i| {
        const v = if (i < args.len) args[i] else Value.undefined_;
        argbuf[i] = try marshalArg(realm, pt, v);
    }

    const results = wasm.invoke(rec.instance, realm.allocator, rec.func_index, argbuf[0..ft.params.len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return intrinsics.throwTypeError(realm, "WebAssembly exported function trapped (RuntimeError)"),
    };
    defer realm.allocator.free(results);

    if (ft.results.len == 0) return Value.undefined_;
    if (ft.results.len == 1) return try marshalResult(realm, ft.results[0], results[0]);

    // Multi-value: return an array of the marshalled results.
    const arr = intrinsics.allocateArray(realm) catch return error.OutOfMemory;
    for (ft.results, 0..) |rt, i| {
        const rv = try marshalResult(realm, rt, results[i]);
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch unreachable;
        arr.set(realm.allocator, key, rv) catch return error.OutOfMemory;
    }
    arr.setWithFlags(realm.allocator, "length", Value.fromInt32(@intCast(ft.results.len)), .{
        .writable = true,
        .enumerable = false,
        .configurable = false,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

/// JS value -> a wasm operand cell, per the parameter's value type.
fn marshalArg(realm: *Realm, vt: wasm.ValType, v: Value) NativeError!u128 {
    switch (vt) {
        .i32 => return @as(u32, @bitCast(arith.toInt32(v))),
        .f32 => return @as(u32, @bitCast(@as(f32, @floatCast(arith.toNumber(v))))),
        .f64 => return @as(u64, @bitCast(arith.toNumber(v))),
        else => return intrinsics.throwTypeError(realm, "WebAssembly: i64/v128/reference marshalling is not yet supported"),
    }
}

/// A wasm result cell -> a JS value, per the result's value type.
fn marshalResult(realm: *Realm, vt: wasm.ValType, cell: u128) NativeError!Value {
    switch (vt) {
        .i32 => return Value.fromInt32(@bitCast(@as(u32, @truncate(cell)))),
        .f32 => return Value.fromDouble(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(cell)))))),
        .f64 => return Value.fromDouble(@as(f64, @bitCast(@as(u64, @truncate(cell))))),
        else => return intrinsics.throwTypeError(realm, "WebAssembly: i64/v128/reference marshalling is not yet supported"),
    }
}

/// The `--allow=wasm` host refusal (HostEnsureCanCompileWasmBytes).
fn wasmDisabled(realm: *Realm) NativeError {
    return intrinsics.throwEvalError(realm, "WebAssembly is not enabled; pass --allow=wasm to enable");
}

/// Borrow the bytes of a BufferSource argument — an `ArrayBuffer` or any
/// typed-array view over one. Returns null for anything else.
fn bufferSourceBytes(args: []const Value) ?[]const u8 {
    if (args.len == 0) return null;
    const obj = heap_mod.valueAsPlainObject(args[0]) orelse return null;
    if (obj.getTypedView()) |tv| {
        const buf = tv.viewed.getArrayBuffer() orelse return null;
        const end = tv.byte_offset + tv.length * tv.kind.elementSize();
        if (end > buf.len) return null;
        return buf[tv.byte_offset..end];
    }
    if (obj.getArrayBuffer()) |ab| return ab;
    return null;
}
