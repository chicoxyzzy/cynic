//! The `WebAssembly` JS namespace — the host API surface over Sarcasm
//! (the engine in `src/runtime/wasm/`).
//!
//! Surface:
//!   - `validate(bytes)` — ungated (only inspects bytes).
//!   - `Module` / `Instance` constructors + `compile` / `instantiate`
//!     Promises, gated behind `--allow=wasm`
//!     (HostEnsureCanCompileWasmBytes; see docs/wasm-engine.md §8-§9).
//!   - `Memory` (aliasing, detach-on-grow `buffer`), `Table` (anyfunc),
//!     `Global` (typed cell) — as standalone constructors and as
//!     instance exports.
//!   - imports: host functions (JS callables re-entering Lantern),
//!     cross-module functions, and shared globals / memories / tables.
//!   - `CompileError` / `LinkError` / `RuntimeError` (Error subclasses).
//!   - marshalling: i32 / i64↔BigInt / f32 / f64; funcref↔function and
//!     externref↔JS value (incl. externref tables / globals and
//!     reference round-trips through host calls).
//!
//! Most wasm artifacts live in the realm's `wasm_arena`, freed at realm
//! teardown, so they need no per-object cleanup or GC marking. The one
//! exception is `externref`: a JS value handed to wasm is kept alive as
//! a GC root — *transiently* while it is on the wasm stack during a call
//! (dropped when the outermost call returns), and *persistently* while
//! it sits in a registered externref table / global (walked each GC). So
//! it survives wherever wasm holds it (the non-moving collector
//! preserves identity) and is reclaimed once wasm drops it. See §5.
//!
//! Deliberate limitation: an imported memory shares the provider's bytes
//! (writes propagate both ways), but a JS-side `grow` after instantiation
//! isn't observed by the importer — its aliased slice header goes stale.
//! Propagating it would require the instance to hold its memory by
//! pointer (an indirection on every load/store), not worth this rare
//! case. A v128 value crossing the JS boundary throws a TypeError — that
//! is spec-mandated (§ToJSValue / §ToWebAssemblyValue), not a Cynic gap.
//! `Instance.prototype.exports` is a prototype getter per spec; this
//! implementation exposes the exports object as an own data property.

const std = @import("std");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const JSFunction = @import("../function.zig").JSFunction;
const JSString = @import("../string.zig").JSString;
const intrinsics = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");
const arith = @import("../lantern/arith.zig");
const call = @import("../lantern/call.zig");
const promise_mod = @import("promise.zig");
const error_mod = @import("error.zig");
const wasm = @import("../wasm/wasm.zig");
const wasm_types = @import("../wasm/types.zig");

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

/// A `WebAssembly.Global`'s backing state: a pointer to its live operand
/// cell (an instance's global for an export, or a standalone arena cell),
/// plus its value type and mutability. Arena-owned.
const GlobalState = struct {
    /// The engine global behind this object — aliased on import so a
    /// mutable global's writes are mutually visible (§4.5.4).
    g: *wasm.Global,
    cell: *u128, // == &g.value (kept for the value accessor paths)
    valtype: wasm.ValType,
    mutable: bool,
};

fn valTypeFromString(s: []const u8) ?wasm.ValType {
    if (std.mem.eql(u8, s, "i32")) return .i32;
    if (std.mem.eql(u8, s, "i64")) return .i64;
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    if (std.mem.eql(u8, s, "externref")) return .externref;
    if (std.mem.eql(u8, s, "anyfunc") or std.mem.eql(u8, s, "funcref")) return .funcref;
    return null;
}

/// A `WebAssembly.Table`'s backing state: the shared engine table plus
/// its element kind (`funcref` → callable wrappers; `externref` → JS
/// values pinned per §5). Arena-owned.
const TableState = struct {
    table: *wasm.Table,
    funcref: bool,
};

/// A `WebAssembly.Memory`'s backing state: the shared engine memory and
/// the cached `buffer` ArrayBuffer (a non-owning view over the memory's
/// bytes, recreated after a JS-initiated grow). Arena-owned.
const MemoryState = struct {
    mem: *wasm.Memory,
    buffer: ?*JSObject,
};

pub fn install(realm: *Realm) !void {
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try intrinsics.installToStringTag(realm, ns, "WebAssembly");
    try intrinsics.installNativeMethodOnProto(realm, ns, "validate", wasmValidate, 1);
    try intrinsics.installNativeMethodOnProto(realm, ns, "compile", wasmCompile, 1);
    try intrinsics.installNativeMethodOnProto(realm, ns, "instantiate", wasmInstantiate, 1);

    // Constructors live under the namespace, not the global object.
    const module_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = moduleConstructor,
        .arity = 1,
        .name = "Module",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Module", heap_mod.taggedFunction(module_ctor.ctor));
    realm.wasm_module_prototype = module_ctor.proto;
    try intrinsics.installToStringTag(realm, module_ctor.proto, "WebAssembly.Module");
    // §Module statics — introspection, ungated (no code is generated).
    try intrinsics.installNativeMethod(realm, module_ctor.ctor, "exports", wasmModuleExports, 1);
    try intrinsics.installNativeMethod(realm, module_ctor.ctor, "imports", wasmModuleImports, 1);
    try intrinsics.installNativeMethod(realm, module_ctor.ctor, "customSections", wasmModuleCustomSections, 2);

    const instance_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = instanceConstructor,
        .arity = 1,
        .name = "Instance",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Instance", heap_mod.taggedFunction(instance_ctor.ctor));
    realm.wasm_instance_prototype = instance_ctor.proto;
    try intrinsics.installToStringTag(realm, instance_ctor.proto, "WebAssembly.Instance");

    // §Errors — CompileError / LinkError / RuntimeError, Error subclasses
    // on the namespace.
    realm.wasm_compile_error_prototype = try makeWasmErrorClass(realm, ns, "CompileError", compileErrorNative);
    realm.wasm_link_error_prototype = try makeWasmErrorClass(realm, ns, "LinkError", linkErrorNative);
    realm.wasm_runtime_error_prototype = try makeWasmErrorClass(realm, ns, "RuntimeError", runtimeErrorNative);

    const global_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = globalConstructor,
        .arity = 1,
        .name = "Global",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Global", heap_mod.taggedFunction(global_ctor.ctor));
    realm.wasm_global_prototype = global_ctor.proto;
    try intrinsics.installToStringTag(realm, global_ctor.proto, "WebAssembly.Global");
    {
        // `Global.prototype.value` — a getter / setter over the cell.
        const getter = try intrinsics.makeNativeFunction(realm, globalValueGet, 0, "get value");
        const setter = try intrinsics.makeNativeFunction(realm, globalValueSet, 1, "set value");
        const entry = try global_ctor.proto.getOrPutAccessor(realm.allocator, "value");
        entry.value_ptr.* = .{ .getter = getter, .setter = setter };
        try global_ctor.proto.property_flags.put(realm.allocator, "value", .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }

    const table_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = tableConstructor,
        .arity = 1,
        .name = "Table",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Table", heap_mod.taggedFunction(table_ctor.ctor));
    realm.wasm_table_prototype = table_ctor.proto;
    try intrinsics.installToStringTag(realm, table_ctor.proto, "WebAssembly.Table");
    try intrinsics.installNativeMethodOnProto(realm, table_ctor.proto, "get", tableGet, 1);
    try intrinsics.installNativeMethodOnProto(realm, table_ctor.proto, "set", tableSet, 2);
    try intrinsics.installNativeMethodOnProto(realm, table_ctor.proto, "grow", tableGrow, 1);
    {
        const getter = try intrinsics.makeNativeFunction(realm, tableLength, 0, "get length");
        const entry = try table_ctor.proto.getOrPutAccessor(realm.allocator, "length");
        entry.value_ptr.* = .{ .getter = getter, .setter = null };
        try table_ctor.proto.property_flags.put(realm.allocator, "length", .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }

    const memory_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = memoryConstructor,
        .arity = 1,
        .name = "Memory",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Memory", heap_mod.taggedFunction(memory_ctor.ctor));
    realm.wasm_memory_prototype = memory_ctor.proto;
    try intrinsics.installToStringTag(realm, memory_ctor.proto, "WebAssembly.Memory");
    try intrinsics.installNativeMethodOnProto(realm, memory_ctor.proto, "grow", memoryGrow, 1);
    {
        const getter = try intrinsics.makeNativeFunction(realm, memoryBufferGet, 0, "get buffer");
        const entry = try memory_ctor.proto.getOrPutAccessor(realm.allocator, "buffer");
        entry.value_ptr.* = .{ .getter = getter, .setter = null };
        try memory_ctor.proto.property_flags.put(realm.allocator, "buffer", .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }

    const tag_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = tagConstructor,
        .arity = 1,
        .name = "Tag",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Tag", heap_mod.taggedFunction(tag_ctor.ctor));
    realm.wasm_tag_prototype = tag_ctor.proto;
    try intrinsics.installToStringTag(realm, tag_ctor.proto, "WebAssembly.Tag");

    const exception_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = exceptionConstructor,
        .arity = 2,
        .name = "Exception",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Exception", heap_mod.taggedFunction(exception_ctor.ctor));
    realm.wasm_exception_prototype = exception_ctor.proto;
    try intrinsics.installToStringTag(realm, exception_ctor.proto, "WebAssembly.Exception");
    try intrinsics.installNativeMethodOnProto(realm, exception_ctor.proto, "is", exceptionIs, 1);
    try intrinsics.installNativeMethodOnProto(realm, exception_ctor.proto, "getArg", exceptionGetArg, 2);

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
    try decodeModuleInto(realm, self, bytes);
    return this_value;
}

/// Decode + validate `bytes` into a `ModuleState` stored on `self`.
fn decodeModuleInto(realm: *Realm, self: *JSObject, bytes: []const u8) NativeError!void {
    const a = realm.wasmAllocator();
    // The decoded module borrows slices from the source bytes, so both
    // must outlive it — keep a copy in the wasm arena.
    const owned = a.dupe(u8, bytes) catch return error.OutOfMemory;
    const mp = a.create(wasm.Module) catch return error.OutOfMemory;
    mp.* = wasm.decode(a, owned) catch
        return throwCompileError(realm, "WebAssembly.Module: invalid module");
    _ = wasm.validateModule(a, mp) catch
        return throwCompileError(realm, "WebAssembly.Module: invalid module");
    const state = a.create(ModuleState) catch return error.OutOfMemory;
    state.* = .{ .module = mp };
    try self.setWasmModule(realm.allocator, state);
}

/// Build a fresh `WebAssembly.Module` object (no `new`), for the
/// Promise entry points.
fn makeModuleObject(realm: *Realm, bytes: []const u8) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_module_prototype);
    try decodeModuleInto(realm, obj, bytes);
    return heap_mod.taggedObject(obj);
}

/// `new WebAssembly.Instance(module, importObject?)` — instantiate a
/// `WebAssembly.Module` and expose its function exports. Gated.
fn instanceConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance requires 'new'");

    const mod_obj = if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null;
    const mstate_raw = (if (mod_obj) |o| o.getWasmModule() else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance expects a WebAssembly.Module");
    const mstate: *ModuleState = @ptrCast(@alignCast(mstate_raw));
    try populateInstance(realm, self, mstate, if (args.len > 1) args[1] else Value.undefined_);
    return this_value;
}

/// Resolve imports, instantiate, run the start function, and attach the
/// `exports` namespace to `self`.
fn populateInstance(realm: *Realm, self: *JSObject, mstate: *ModuleState, import_object: Value) NativeError!void {
    const imports = try resolveImports(realm, mstate.module, import_object);

    const a = realm.wasmAllocator();
    const ip = a.create(wasm.Instance) catch return error.OutOfMemory;
    wasm.instantiate(ip, a, a, mstate.module, imports) catch
        return throwLinkError(realm, "WebAssembly.Instance: instantiation failed");

    // Let a `try_table` in this instance catch a JS exception thrown by a
    // host import (the JS->wasm direction): the interpreter reifies the
    // realm's pending exception through this bridge.
    ip.host_exn_ctx = realm;
    ip.host_exn_hook = convertHostException;

    // Register the instance's externref tables / globals as GC roots, so a
    // JS value a wasm body stores into one survives past the call that put
    // it there (its transient pin is dropped at the outermost return).
    for (0..ip.tables.len) |i| {
        if ((ip.tableElemType(@intCast(i)) orelse continue) == .externref)
            realm.registerExternTable(ip.tableRef(@intCast(i)).?) catch return error.OutOfMemory;
    }
    for (0..ip.globals.len) |i| {
        const gt = ip.globalTypeAt(@intCast(i)) orelse continue;
        if (gt.val == .externref)
            realm.registerExternGlobalCell(ip.globalCellPtr(@intCast(i)).?) catch return error.OutOfMemory;
    }

    wasm.runStart(ip, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HostThrew => return error.NativeThrew, // a host import threw during start
        else => return throwRuntimeError(realm, "WebAssembly.Instance: start function trapped"),
    };

    const exports = try buildExports(realm, ip, mstate.module);
    // Spec models `exports` as an Instance.prototype getter returning the
    // immutable [[Exports]]; this slice exposes it as a read-only own
    // property (also keeps it reachable for GC via the property bag).
    try self.setWithFlags(realm.allocator, "exports", exports, .{
        .writable = false,
        .enumerable = true,
        .configurable = false,
    });
}

/// Build a fresh `WebAssembly.Instance` object (no `new`), for the
/// Promise entry points.
fn makeInstanceObject(realm: *Realm, mstate: *ModuleState, import_object: Value) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_instance_prototype);
    try populateInstance(realm, obj, mstate, import_object);
    return heap_mod.taggedObject(obj);
}

// ── Promise entry points (compile / instantiate) ────────────────────

fn promiseCtor(realm: *Realm) NativeError!*JSFunction {
    return heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly: %Promise% is missing");
}

/// Turn a synchronous abrupt completion into a promise rejection (so
/// `compile` / `instantiate` always return a settled promise).
fn rejectFromError(realm: *Realm, cap: promise_mod.PromiseCapability, err: NativeError) NativeError!Value {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            const reason = realm.pending_exception orelse Value.undefined_;
            realm.pending_exception = null;
            return promise_mod.capabilityReject(realm, cap, reason);
        },
    }
}

/// `WebAssembly.compile(bytes)` → Promise<Module>.
fn wasmCompile(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const cap = try promise_mod.newPromiseCapability(realm, try promiseCtor(realm));
    const result = compileToModule(realm, args) catch |err| return rejectFromError(realm, cap, err);
    return promise_mod.capabilityResolve(realm, cap, result);
}

fn compileToModule(realm: *Realm, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const bytes = bufferSourceBytes(args) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.compile expects a BufferSource");
    return makeModuleObject(realm, bytes);
}

/// `WebAssembly.instantiate(bytes, importObject?)` → Promise<{module,
/// instance}>; `WebAssembly.instantiate(module, importObject?)` →
/// Promise<Instance>.
fn wasmInstantiate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const cap = try promise_mod.newPromiseCapability(realm, try promiseCtor(realm));
    const result = instantiateToResult(realm, args) catch |err| return rejectFromError(realm, cap, err);
    return promise_mod.capabilityResolve(realm, cap, result);
}

fn instantiateToResult(realm: *Realm, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const import_object = if (args.len > 1) args[1] else Value.undefined_;

    // A Module argument instantiates directly, resolving to the Instance.
    if (args.len > 0) {
        if (heap_mod.valueAsPlainObject(args[0])) |o| {
            if (o.getWasmModule()) |raw| {
                const mstate: *ModuleState = @ptrCast(@alignCast(raw));
                return makeInstanceObject(realm, mstate, import_object);
            }
        }
    }

    // Otherwise a BufferSource: compile then instantiate, resolving to
    // `{ module, instance }`.
    const bytes = bufferSourceBytes(args) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.instantiate expects a BufferSource or Module");
    const module_v = try makeModuleObject(realm, bytes);
    const mobj = heap_mod.valueAsPlainObject(module_v) orelse unreachable;
    const mstate: *ModuleState = @ptrCast(@alignCast(mobj.getWasmModule() orelse unreachable));
    const instance_v = try makeInstanceObject(realm, mstate, import_object);

    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.object_prototype);
    try result.set(realm.allocator, "module", module_v);
    try result.set(realm.allocator, "instance", instance_v);
    return heap_mod.taggedObject(result);
}

// ── WebAssembly.Global ──────────────────────────────────────────────

/// `new WebAssembly.Global(descriptor, value?)` — a typed, optionally
/// mutable global cell. Gated.
fn globalConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Global requires 'new'");
    const desc = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Global expects a descriptor object");

    const vt = readValType(desc.get("value")) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Global: invalid value type");
    const mutable = arith.toBoolean(desc.get("mutable"));

    const a = realm.wasmAllocator();
    const g = a.create(wasm.Global) catch return error.OutOfMemory;
    // A missing initial value is the type's default: the null ref for
    // reference types, else the zero bit pattern (i32 0 / i64 0n /
    // f32 +0 / f64 +0).
    const default_cell: u128 = if (vt == .externref or vt == .funcref) wasm.REF_NULL else 0;
    g.* = .{
        .value = if (args.len > 1) try marshalArg(realm, vt, args[1]) else default_cell,
        .mutable = mutable,
    };
    const cell = &g.value;

    const st = a.create(GlobalState) catch return error.OutOfMemory;
    st.* = .{ .g = g, .cell = cell, .valtype = vt, .mutable = mutable };
    try self.setWasmGlobal(realm.allocator, st);
    if (vt == .externref) realm.registerExternGlobalCell(cell) catch return error.OutOfMemory;
    return this_value;
}

/// Read a value-type string Value ("i32"/"i64"/"f32"/"f64").
fn readValType(v: Value) ?wasm.ValType {
    if (!v.isString()) return null;
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    return valTypeFromString(s.flatBytes());
}

fn globalStateOf(realm: *Realm, this_value: Value) NativeError!*GlobalState {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Global");
    const raw = obj.getWasmGlobal() orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Global");
    return @ptrCast(@alignCast(raw));
}

fn globalValueGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const st = try globalStateOf(realm, this_value);
    return marshalResult(realm, st.valtype, st.cell.*);
}

fn globalValueSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try globalStateOf(realm, this_value);
    if (!st.mutable) return intrinsics.throwTypeError(realm, "WebAssembly.Global is immutable");
    st.cell.* = try marshalArg(realm, st.valtype, if (args.len > 0) args[0] else Value.undefined_);
    return Value.undefined_;
}

/// Wrap an instance's live global cell as a `WebAssembly.Global` object
/// (for global exports). Reads / writes go straight to the cell.
fn makeGlobal(realm: *Realm, valtype: wasm.ValType, mutable: bool, g: *wasm.Global) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_global_prototype);
    const a = realm.wasmAllocator();
    const st = a.create(GlobalState) catch return error.OutOfMemory;
    st.* = .{ .g = g, .cell = &g.value, .valtype = valtype, .mutable = mutable };
    try obj.setWasmGlobal(realm.allocator, st);
    return heap_mod.taggedObject(obj);
}

// ── WebAssembly.Table ───────────────────────────────────────────────

/// `new WebAssembly.Table({element, initial, maximum?}, value?)` — a
/// growable funcref table. Gated.
fn tableConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Table requires 'new'");
    const desc = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Table expects a descriptor object");

    const elem_v = desc.get("element");
    if (!elem_v.isString()) return intrinsics.throwTypeError(realm, "WebAssembly.Table: invalid element type");
    const elem_s: *JSString = @ptrCast(@alignCast(elem_v.asString()));
    const elem = elem_s.flatBytes();
    const is_funcref = std.mem.eql(u8, elem, "anyfunc") or std.mem.eql(u8, elem, "funcref");
    if (!is_funcref and !std.mem.eql(u8, elem, "externref"))
        return intrinsics.throwTypeError(realm, "WebAssembly.Table: invalid element type");

    const initial = try indexArg(realm, desc.get("initial"));
    const max = try optionalIndexArg(realm, desc.get("maximum"));

    const a = realm.wasmAllocator();
    const elems = a.alloc(u128, initial) catch return error.OutOfMemory;
    const fill = if (args.len > 1) try tableElemFromValue(realm, is_funcref, args[1]) else wasm.REF_NULL;
    @memset(elems, fill);

    const tbl = a.create(wasm.Table) catch return error.OutOfMemory;
    tbl.* = .{ .elems = elems, .max = max, .is_64 = false };
    const st = a.create(TableState) catch return error.OutOfMemory;
    st.* = .{ .table = tbl, .funcref = is_funcref };
    try self.setWasmTable(realm.allocator, st);
    if (!is_funcref) realm.registerExternTable(tbl) catch return error.OutOfMemory;
    return this_value;
}

/// A JS value -> a table element cell, per the table's element type.
fn tableElemFromValue(realm: *Realm, is_funcref: bool, v: Value) NativeError!u128 {
    return if (is_funcref) funcRefFromValue(realm, v) else marshalArg(realm, .externref, v);
}

fn tableStateOf(realm: *Realm, this_value: Value) NativeError!*TableState {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Table");
    const raw = obj.getWasmTable() orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Table");
    return @ptrCast(@alignCast(raw));
}

fn tableLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const st = try tableStateOf(realm, this_value);
    return Value.fromInt32(@intCast(st.table.elems.len));
}

fn tableGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try tableStateOf(realm, this_value);
    const idx = try tableIndex(realm, st, if (args.len > 0) args[0] else Value.undefined_);
    const cell = st.table.elems[idx];
    return marshalResult(realm, if (st.funcref) .funcref else .externref, cell);
}

fn tableSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try tableStateOf(realm, this_value);
    const idx = try tableIndex(realm, st, if (args.len > 0) args[0] else Value.undefined_);
    st.table.elems[idx] = try tableElemFromValue(realm, st.funcref, if (args.len > 1) args[1] else Value.null_);
    return Value.undefined_;
}

fn tableGrow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try tableStateOf(realm, this_value);
    const delta = try indexArg(realm, if (args.len > 0) args[0] else Value.undefined_);
    const fill = if (args.len > 1) try funcRefFromValue(realm, args[1]) else wasm.REF_NULL;
    const old_len = st.table.elems.len;
    const new_len = old_len + delta;
    if (st.table.max) |m| {
        if (new_len > m) return intrinsics.throwRangeError(realm, "WebAssembly.Table.grow exceeds the maximum");
    }
    const new_elems = realm.wasmAllocator().realloc(st.table.elems, new_len) catch return error.OutOfMemory;
    @memset(new_elems[old_len..], fill);
    st.table.elems = new_elems;
    return Value.fromInt32(@intCast(old_len));
}

/// A JS value -> a funcref cell: null/undefined -> the null ref; a
/// WebAssembly exported function -> its funcref; anything else throws.
fn funcRefFromValue(realm: *Realm, v: Value) NativeError!u128 {
    if (v.isUndefined() or v.isNull()) return wasm.REF_NULL;
    const fn_obj = heap_mod.valueAsFunction(v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Table value must be null or an exported function");
    const raw = fn_obj.wasm_export orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Table value must be a WebAssembly exported function");
    const rec: *ExportRecord = @ptrCast(@alignCast(raw));
    return wasm.makeFuncRef(rec.instance, rec.func_index);
}

/// Validate a table index argument against the table's bounds.
fn tableIndex(realm: *Realm, st: *TableState, v: Value) NativeError!usize {
    const i = arith.toInt32(v);
    if (i < 0 or @as(usize, @intCast(i)) >= st.table.elems.len)
        return intrinsics.throwRangeError(realm, "WebAssembly.Table index is out of bounds");
    return @intCast(i);
}

/// Read a non-negative length-like argument as a usize.
fn indexArg(realm: *Realm, v: Value) NativeError!usize {
    const i = arith.toInt32(v);
    if (i < 0) return intrinsics.throwRangeError(realm, "WebAssembly: length must be non-negative");
    return @intCast(i);
}

/// Read an optional maximum (undefined -> null).
fn optionalIndexArg(realm: *Realm, v: Value) NativeError!?u64 {
    if (v.isUndefined()) return null;
    return @as(u64, try indexArg(realm, v));
}

/// Wrap a shared engine table as a `WebAssembly.Table` (for exports).
fn makeTable(realm: *Realm, table: *wasm.Table, funcref: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_table_prototype);
    const st = realm.wasmAllocator().create(TableState) catch return error.OutOfMemory;
    st.* = .{ .table = table, .funcref = funcref };
    try obj.setWasmTable(realm.allocator, st);
    return heap_mod.taggedObject(obj);
}

// ── WebAssembly.Memory ──────────────────────────────────────────────

/// `new WebAssembly.Memory({initial, maximum?})` — a page-granular
/// linear memory. Gated. The bytes live in the realm's wasm arena;
/// `buffer` exposes a non-owning ArrayBuffer view over them.
fn memoryConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory requires 'new'");
    const desc = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory expects a descriptor object");

    const initial = try indexArg(realm, desc.get("initial"));
    const max = try optionalIndexArg(realm, desc.get("maximum"));

    const a = realm.wasmAllocator();
    const bytes = a.alloc(u8, initial * wasm.PAGE_SIZE) catch return error.OutOfMemory;
    @memset(bytes, 0);
    const mem = a.create(wasm.Memory) catch return error.OutOfMemory;
    mem.* = .{ .data = bytes, .max_pages = max, .is_64 = false };
    const st = a.create(MemoryState) catch return error.OutOfMemory;
    st.* = .{ .mem = mem, .buffer = null };
    try self.setWasmMemory(realm.allocator, st);
    return this_value;
}

fn memoryStateOf(realm: *Realm, this_value: Value) NativeError!*MemoryState {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Memory");
    const raw = obj.getWasmMemory() orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Memory");
    return @ptrCast(@alignCast(raw));
}

/// `Memory.prototype.buffer` — a cached non-owning ArrayBuffer aliasing
/// the live linear bytes.
fn memoryBufferGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const st = try memoryStateOf(realm, this_value);
    if (st.buffer) |b| return heap_mod.taggedObject(b);
    const buf = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(buf, realm.intrinsics.array_buffer_prototype);
    buf.setExternalArrayBuffer(realm.allocator, st.mem.data) catch return error.OutOfMemory;
    buf.has_array_buffer_data = true;
    st.buffer = buf;
    return heap_mod.taggedObject(buf);
}

/// `Memory.prototype.grow(delta)` — grow by `delta` pages, detach the
/// current buffer, return the previous page count.
fn memoryGrow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try memoryStateOf(realm, this_value);
    const delta = try indexArg(realm, if (args.len > 0) args[0] else Value.undefined_);
    const old_pages = st.mem.data.len / wasm.PAGE_SIZE;
    const new_pages = old_pages + delta;
    if (st.mem.max_pages) |m| {
        if (new_pages > m) return intrinsics.throwRangeError(realm, "WebAssembly.Memory.grow exceeds the maximum");
    }
    const a = realm.wasmAllocator();
    const new_bytes = a.alloc(u8, new_pages * wasm.PAGE_SIZE) catch return error.OutOfMemory;
    @memset(new_bytes, 0);
    @memcpy(new_bytes[0..st.mem.data.len], st.mem.data);
    // DetachArrayBuffer (§25.1.3.4) on the prior buffer, if materialized.
    if (st.buffer) |b| {
        b.setArrayBuffer(realm.allocator, null) catch {};
        st.buffer = null;
    }
    st.mem.data = new_bytes;
    return Value.fromInt32(@intCast(old_pages));
}

/// Wrap a shared engine memory as a `WebAssembly.Memory` (for exports).
fn makeMemory(realm: *Realm, mem: *wasm.Memory) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_memory_prototype);
    const st = realm.wasmAllocator().create(MemoryState) catch return error.OutOfMemory;
    st.* = .{ .mem = mem, .buffer = null };
    try obj.setWasmMemory(realm.allocator, st);
    return heap_mod.taggedObject(obj);
}

// ── imports (importObject -> engine Imports) ────────────────────────

/// A JS-backed host function's context, reached through the engine's
/// `FuncRef.host.ctx`. Arena-owned.
const HostImportCtx = struct {
    realm: *Realm,
    js_fn: *JSFunction,
    params: []const wasm.ValType,
    results: []const wasm.ValType,
};

/// The engine's host-function callback for a JS import: marshal the wasm
/// operands to JS values, call the JS function (re-entering Lantern),
/// and marshal its result back. A JS throw becomes `HostThrew`, re-raised
/// at the wasm->JS boundary.
fn jsHostTrampoline(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
    const c: *HostImportCtx = @ptrCast(@alignCast(ctx orelse return error.HostThrew));
    const realm = c.realm;
    if (c.params.len > 16 or c.results.len > 1) return error.HostThrew; // arity bounds / multi-value host returns: unsupported

    var jsargs: [16]Value = undefined;
    const scope = realm.heap.openScope() catch return error.HostThrew;
    defer scope.close();
    for (c.params, 0..) |pt, i| {
        jsargs[i] = marshalResult(realm, pt, args[i]) catch return error.HostThrew;
        scope.push(jsargs[i]) catch return error.HostThrew;
    }

    const outcome = call.callJSFunction(realm.allocator, realm, c.js_fn, Value.undefined_, jsargs[0..c.params.len]) catch return error.HostThrew;
    const ret = switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.HostThrew;
        },
    };
    if (c.results.len == 1) results[0] = marshalArg(realm, c.results[0], ret) catch return error.HostThrew;
}

/// Build the engine `Imports` from a module's import list and a JS
/// `importObject`. Functions resolve to a cross-module funcref (a
/// WebAssembly exported function) or a host trampoline (any JS
/// function); globals read a `Global` cell or marshal a primitive;
/// memories / tables share the imported object's engine state.
fn resolveImports(realm: *Realm, module: *const wasm.Module, import_obj_v: Value) NativeError!wasm.Imports {
    var nfunc: usize = 0;
    var nglob: usize = 0;
    var ntab: usize = 0;
    var ntag: usize = 0;
    var nmem: usize = 0;
    for (module.imports) |imp| switch (imp.desc) {
        .func => nfunc += 1,
        .global => nglob += 1,
        .table => ntab += 1,
        .mem => nmem += 1,
        .tag => ntag += 1,
    };
    if (module.imports.len == 0) return .{};

    const import_obj = heap_mod.valueAsPlainObject(import_obj_v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: an importObject is required");

    const a = realm.wasmAllocator();
    const funcs = a.alloc(wasm.FuncRef, nfunc) catch return error.OutOfMemory;
    const globals = a.alloc(*wasm.Global, nglob) catch return error.OutOfMemory;
    const tables = a.alloc(*wasm.Table, ntab) catch return error.OutOfMemory;
    const tags = a.alloc(*const wasm.TagType, ntag) catch return error.OutOfMemory;
    const memories = a.alloc(*wasm.Memory, nmem) catch return error.OutOfMemory;
    var fi: usize = 0;
    var gi: usize = 0;
    var ti: usize = 0;
    var tgi: usize = 0;
    var mi: usize = 0;

    for (module.imports) |imp| {
        const v = try lookupImport(realm, import_obj, imp.module, imp.name);
        switch (imp.desc) {
            .func => |type_idx| {
                funcs[fi] = try resolveFuncImport(realm, v, module, type_idx);
                fi += 1;
            },
            .global => |gt| {
                globals[gi] = try resolveGlobalImport(realm, v, gt);
                gi += 1;
            },
            .table => {
                tables[ti] = try resolveTableImport(realm, v);
                ti += 1;
            },
            .mem => {
                memories[mi] = try resolveMemImport(realm, v);
                mi += 1;
            },
            .tag => {
                tags[tgi] = tagTypeOf(v) orelse
                    return throwLinkError(realm, "WebAssembly.Instance: tag import is not a WebAssembly.Tag");
                tgi += 1;
            },
        }
    }
    // JS-API imports share the provider's linear memories (writes are
    // mutually visible), unlike the spectest harness's snapshot.
    return .{ .funcs = funcs, .globals = globals, .tables = tables, .memories = memories, .share_memory = true, .tags = tags };
}

/// `importObject[module][name]`.
fn lookupImport(realm: *Realm, import_obj: *JSObject, module_name: []const u8, name: []const u8) NativeError!Value {
    const mod_v = import_obj.get(module_name);
    const mod_obj = heap_mod.valueAsPlainObject(mod_v) orelse
        return throwLinkError(realm, "WebAssembly.Instance: import module namespace is not an object");
    return mod_obj.get(name);
}

fn resolveFuncImport(realm: *Realm, v: Value, module: *const wasm.Module, type_idx: u32) NativeError!wasm.FuncRef {
    const fn_obj = heap_mod.valueAsFunction(v) orelse
        return throwLinkError(realm, "WebAssembly.Instance: function import is not callable");
    // A WebAssembly exported function links directly to its wasm body.
    if (fn_obj.wasm_export) |raw| {
        const rec: *ExportRecord = @ptrCast(@alignCast(raw));
        return rec.instance.funcRefAt(rec.func_index) orelse
            return throwLinkError(realm, "WebAssembly.Instance: bad exported-function import");
    }
    // Any other JS function becomes a host import.
    const ft = module.types[type_idx];
    if (ft.params.len > 16 or ft.results.len > 1)
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: host import arity is not supported");
    const ctx = realm.wasmAllocator().create(HostImportCtx) catch return error.OutOfMemory;
    ctx.* = .{ .realm = realm, .js_fn = fn_obj, .params = ft.params, .results = ft.results };
    return .{ .host = .{
        .fn_ptr = jsHostTrampoline,
        .ctx = ctx,
        .params = @intCast(ft.params.len),
        .results = @intCast(ft.results.len),
    } };
}

fn resolveGlobalImport(realm: *Realm, v: Value, gt: anytype) NativeError!*wasm.Global {
    // A WebAssembly.Global is aliased — a mutable global's writes are
    // visible both ways (§4.5.4); a primitive is marshalled into a
    // fresh engine global of the declared type.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.getWasmGlobal()) |raw| {
            const st: *GlobalState = @ptrCast(@alignCast(raw));
            return st.g;
        }
    }
    const g = realm.wasmAllocator().create(wasm.Global) catch return error.OutOfMemory;
    g.* = .{ .value = try marshalArg(realm, gt.val, v), .mutable = gt.mut == .mutable };
    return g;
}

fn resolveTableImport(realm: *Realm, v: Value) NativeError!*wasm.Table {
    const obj = heap_mod.valueAsPlainObject(v) orelse
        return throwLinkError(realm, "WebAssembly.Instance: table import is not a WebAssembly.Table");
    const raw = obj.getWasmTable() orelse
        return throwLinkError(realm, "WebAssembly.Instance: table import is not a WebAssembly.Table");
    const st: *TableState = @ptrCast(@alignCast(raw));
    return st.table;
}

fn resolveMemImport(realm: *Realm, v: Value) NativeError!*wasm.Memory {
    const obj = heap_mod.valueAsPlainObject(v) orelse
        return throwLinkError(realm, "WebAssembly.Instance: memory import is not a WebAssembly.Memory");
    const raw = obj.getWasmMemory() orelse
        return throwLinkError(realm, "WebAssembly.Instance: memory import is not a WebAssembly.Memory");
    const st: *MemoryState = @ptrCast(@alignCast(raw));
    return st.mem;
}

/// Build the exports namespace object: each function export becomes a
/// callable JS function carrying its `(instance, func_index)`; each
/// global export becomes a `WebAssembly.Global`; each funcref table
/// export becomes a `WebAssembly.Table`; the memory export becomes a
/// `WebAssembly.Memory`.
fn buildExports(realm: *Realm, ip: *wasm.Instance, module: *const wasm.Module) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, null); // §exports object has a null prototype
    for (module.exports) |ex| {
        switch (ex.desc) {
            .func => |fidx| {
                const fv = try makeExportedFunction(realm, ip, fidx, ex.name);
                obj.set(realm.allocator, ex.name, fv) catch return error.OutOfMemory;
            },
            .global => |gidx| {
                const g = ip.globalRef(gidx) orelse continue;
                const gt = ip.globalTypeAt(gidx) orelse continue;
                const gobj = try makeGlobal(realm, gt.val, gt.mut == .mutable, g);
                obj.set(realm.allocator, ex.name, gobj) catch return error.OutOfMemory;
            },
            .table => |tidx| {
                const tbl = ip.tableRef(tidx) orelse continue;
                const et = ip.tableElemType(tidx) orelse continue;
                const tobj = try makeTable(realm, tbl, et == .funcref);
                obj.set(realm.allocator, ex.name, tobj) catch return error.OutOfMemory;
            },
            .mem => |midx| {
                const mem = ip.memoryPtr(midx) orelse continue;
                const mobj = try makeMemory(realm, mem);
                obj.set(realm.allocator, ex.name, mobj) catch return error.OutOfMemory;
            },
            .tag => |tidx| {
                const tobj = try makeTagForInstance(realm, ip, tidx);
                obj.set(realm.allocator, ex.name, tobj) catch return error.OutOfMemory;
            },
        }
    }
    return heap_mod.taggedObject(obj);
}

/// Create a callable JS function wrapping `(instance, func_index)` —
/// shared by `Instance.exports` and `Table.prototype.get` of a funcref.
fn makeExportedFunction(realm: *Realm, instance: *wasm.Instance, func_index: u32, name: []const u8) NativeError!Value {
    const ft = instance.funcType(func_index) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly: unknown exported function type");
    const fn_obj = intrinsics.makeNativeFunction(realm, exportTrampoline, @intCast(ft.params.len), name) catch
        return error.OutOfMemory;
    const rec = realm.wasmAllocator().create(ExportRecord) catch return error.OutOfMemory;
    rec.* = .{ .instance = instance, .func_index = func_index };
    fn_obj.wasm_export = rec;
    return heap_mod.taggedFunction(fn_obj);
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

    // Inside the call, externref values live on the wasm stack: pin them
    // transiently (params, host-import results), and drop the pins when
    // the outermost call returns. The defer runs after the result Value
    // is built; a returned externref is then rooted by the JS caller.
    realm.enterWasmCall();
    defer realm.leaveWasmCall();

    for (ft.params, 0..) |pt, i| {
        const v = if (i < args.len) args[i] else Value.undefined_;
        argbuf[i] = try marshalArg(realm, pt, v);
    }

    const results = wasm.invoke(rec.instance, realm.allocator, rec.func_index, argbuf[0..ft.params.len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A JS-backed host import threw — re-raise its pending exception.
        error.HostThrew => return error.NativeThrew,
        // An uncaught exception surfaces to JS. One that entered wasm as a
        // JS throw is re-raised as its original value (identity preserved);
        // a pure wasm throw is reified as a WebAssembly.Exception.
        error.UncaughtException => {
            if (rec.instance.pending_exn) |exn_rec| {
                if (exn_rec.js_value != wasm.REF_NULL) {
                    realm.pending_exception = Value{ .bits = @truncate(exn_rec.js_value) };
                } else {
                    realm.pending_exception = try makeExceptionFromRecord(realm, exn_rec);
                }
                return error.NativeThrew;
            }
            return throwRuntimeError(realm, "WebAssembly: uncaught exception");
        },
        error.NullExnRef => return throwRuntimeError(realm, "WebAssembly: throw_ref of a null exnref"),
        else => return throwRuntimeError(realm, "WebAssembly exported function trapped"),
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
/// (§ToWebAssemblyValue.)
fn marshalArg(realm: *Realm, vt: wasm.ValType, v: Value) NativeError!u128 {
    switch (vt) {
        .i32 => return @as(u32, @bitCast(arith.toInt32(v))),
        .i64 => {
            const bi = heap_mod.valueAsBigInt(v) orelse
                return intrinsics.throwTypeError(realm, "WebAssembly: an i64 value must be a BigInt");
            return @as(u64, @bitCast(bi.toI64Truncating()));
        },
        .f32 => return @as(u32, @bitCast(@as(f32, @floatCast(arith.toNumber(v))))),
        .f64 => return @as(u64, @bitCast(arith.toNumber(v))),
        // §ToWebAssemblyValue for reference types. An externref cell holds
        // the JS value's NaN-boxed bits (pinned as a GC root); JS null maps
        // to the wasm null ref. A funcref accepts null or an exported fn.
        .externref => {
            if (v.isNull()) return wasm.REF_NULL;
            // Pin only while inside a wasm call, where the value lives on
            // the operand stack / in a local. At depth 0 it instead lands
            // in a registered container (table / global) or is returned to
            // JS — both root it precisely without a transient pin.
            if (realm.wasm_call_depth > 0) realm.pinExternRefTransient(v) catch return error.OutOfMemory;
            return @as(u128, v.bits);
        },
        .funcref => return funcRefFromValue(realm, v),
        // §ToWebAssemblyValue / §ToJSValue — a v128 value cannot cross the JS
        // boundary; the spec mandates a TypeError.
        .v128 => return intrinsics.throwTypeError(realm, "WebAssembly: a v128 value cannot cross the JS boundary"),
        // exnref interop is the WebAssembly.Exception surface (not yet built).
        .exnref => return intrinsics.throwTypeError(realm, "WebAssembly: an exnref cannot yet cross the JS boundary"),
        // Constructed reference types (function-references proposal):
        // route by heap — a func-typed ref marshals like funcref, an
        // extern one like externref — refusing null for non-nullable.
        _ => {
            const heap = vt.heapOf() orelse
                return intrinsics.throwTypeError(realm, "WebAssembly: unsupported parameter type");
            if (v.isNull() and !vt.isNullable())
                return intrinsics.throwTypeError(realm, "WebAssembly: null is not valid for a non-nullable reference");
            if (heap == wasm_types.heap_abs_extern) {
                if (v.isNull()) return wasm.REF_NULL;
                if (realm.wasm_call_depth > 0) realm.pinExternRefTransient(v) catch return error.OutOfMemory;
                return @as(u128, v.bits);
            }
            if (heap == wasm_types.heap_abs_exn)
                return intrinsics.throwTypeError(realm, "WebAssembly: an exnref cannot yet cross the JS boundary");
            return funcRefFromValue(realm, v);
        },
    }
}

/// A wasm result cell -> a JS value, per the result's value type.
/// (§ToJSValue.)
fn marshalResult(realm: *Realm, vt: wasm.ValType, cell: u128) NativeError!Value {
    switch (vt) {
        .i32 => return Value.fromInt32(@bitCast(@as(u32, @truncate(cell)))),
        .i64 => {
            const v: i64 = @bitCast(@as(u64, @truncate(cell)));
            const bi = realm.heap.allocateBigInt(@as(i128, v)) catch return error.OutOfMemory;
            return heap_mod.taggedBigInt(bi);
        },
        .f32 => return Value.fromDouble(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(cell)))))),
        .f64 => return Value.fromDouble(@as(f64, @bitCast(@as(u64, @truncate(cell))))),
        // §ToJSValue for reference types. The wasm null ref becomes JS
        // null; an externref reconstructs the JS value from its bits; a
        // funcref becomes a callable exported-function wrapper.
        .externref => {
            if (cell == wasm.REF_NULL) return Value.null_;
            return Value{ .bits = @truncate(cell) };
        },
        .funcref => {
            if (cell == wasm.REF_NULL) return Value.null_;
            return makeExportedFunction(realm, wasm.funcRefInstance(cell), wasm.funcRefIndex(cell), "");
        },
        // §ToWebAssemblyValue / §ToJSValue — a v128 value cannot cross the JS
        // boundary; the spec mandates a TypeError.
        .v128 => return intrinsics.throwTypeError(realm, "WebAssembly: a v128 value cannot cross the JS boundary"),
        // exnref interop is the WebAssembly.Exception surface (not yet built).
        .exnref => return intrinsics.throwTypeError(realm, "WebAssembly: an exnref cannot yet cross the JS boundary"),
        // Constructed reference types route by heap, as in marshalArg.
        _ => {
            const heap = vt.heapOf() orelse
                return intrinsics.throwTypeError(realm, "WebAssembly: unsupported result type");
            if (heap == wasm_types.heap_abs_exn)
                return intrinsics.throwTypeError(realm, "WebAssembly: an exnref cannot yet cross the JS boundary");
            if (cell == wasm.REF_NULL) return Value.null_;
            if (heap == wasm_types.heap_abs_extern) return Value{ .bits = @truncate(cell) };
            return makeExportedFunction(realm, wasm.funcRefInstance(cell), wasm.funcRefIndex(cell), "");
        },
    }
}

/// The `--allow=wasm` host refusal (HostEnsureCanCompileWasmBytes).
fn wasmDisabled(realm: *Realm) NativeError {
    return intrinsics.throwEvalError(realm, "WebAssembly is not enabled; pass --allow=wasm to enable");
}

// ── WebAssembly.Tag / WebAssembly.Exception ────────────────────────

const TagState = struct { tag_type: *const wasm.TagType };
const ExceptionState = struct { tag: *const wasm.TagType, payload: []u128 };

/// Root any externref slots in an exception's payload so the JS values
/// they hold survive GC for the exception's lifetime (the payload lives
/// in the realm's wasm arena, so the cell pointers stay stable).
fn rootExceptionPayload(realm: *Realm, tt: *const wasm.TagType, payload: []u128) NativeError!void {
    for (tt.params, 0..) |pt, i| {
        if (pt == .externref) realm.registerExternGlobalCell(&payload[i]) catch return error.OutOfMemory;
    }
}

fn tagTypeOf(v: Value) ?*const wasm.TagType {
    const obj = heap_mod.valueAsPlainObject(v) orelse return null;
    const slot = obj.getWasmTag() orelse return null;
    const st: *TagState = @ptrCast(@alignCast(slot));
    return st.tag_type;
}

fn exceptionStateOf(v: Value) ?*ExceptionState {
    const obj = heap_mod.valueAsPlainObject(v) orelse return null;
    const slot = obj.getWasmException() orelse return null;
    return @ptrCast(@alignCast(slot));
}

/// Wrap a canonical tag identity as a `WebAssembly.Tag` object.
fn makeTagFromType(realm: *Realm, tt: *const wasm.TagType) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_tag_prototype);
    const a = realm.wasmAllocator();
    const st = a.create(TagState) catch return error.OutOfMemory;
    st.* = .{ .tag_type = tt };
    try obj.setWasmTag(realm.allocator, st);
    return heap_mod.taggedObject(obj);
}

/// A wasm instance's exported tag, exposed as a `WebAssembly.Tag`.
fn makeTagForInstance(realm: *Realm, ip: *wasm.Instance, tag_idx: u32) NativeError!Value {
    if (tag_idx >= ip.tag_identities.len) return error.OutOfMemory;
    return makeTagFromType(realm, ip.tag_identities[tag_idx]);
}

fn tagConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Tag requires 'new'");
    const desc = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Tag expects a descriptor object");
    const params_obj = heap_mod.valueAsPlainObject(desc.get("parameters")) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Tag: 'parameters' must be an array");
    const n = params_obj.arrayLength();
    const a = realm.wasmAllocator();
    const params = a.alloc(wasm.ValType, n) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        params[i] = readValType(params_obj.tryGetIndexedOwn(i) orelse Value.undefined_) orelse
            return intrinsics.throwTypeError(realm, "WebAssembly.Tag: invalid parameter type");
    }
    const tt = a.create(wasm.TagType) catch return error.OutOfMemory;
    tt.* = .{ .params = params };
    const st = a.create(TagState) catch return error.OutOfMemory;
    st.* = .{ .tag_type = tt };
    try self.setWasmTag(realm.allocator, st);
    return this_value;
}

/// Reify a thrown exception record as a `WebAssembly.Exception` — the JS
/// view of an exception that escaped a wasm call uncaught.
fn makeExceptionFromRecord(realm: *Realm, rec: *const wasm.ExnRecord) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_exception_prototype);
    const a = realm.wasmAllocator();
    const payload = a.alloc(u128, rec.payload.len) catch return error.OutOfMemory;
    @memcpy(payload, rec.payload);
    const st = a.create(ExceptionState) catch return error.OutOfMemory;
    st.* = .{ .tag = rec.tag, .payload = payload };
    try obj.setWasmException(realm.allocator, st);
    try rootExceptionPayload(realm, rec.tag, payload);
    return heap_mod.taggedObject(obj);
}

/// Bridge the interpreter calls on a host import's `HostThrew`: reify the
/// realm's pending JS exception as an `ExnRecord` a wasm `try_table` can
/// match, clearing the pending slot. A `WebAssembly.Exception` keeps its
/// tag identity (so `catch $tag` binds it); any other JS value gets the
/// realm's foreign sentinel tag (only `catch_all` matches). The thrown
/// value is rooted so a bound exnref or a re-raise keeps it alive.
fn convertHostException(ctx: *anyopaque, owner: *wasm.Instance) ?*wasm.ExnRecord {
    const realm: *Realm = @ptrCast(@alignCast(ctx));
    const ex = realm.pending_exception orelse return null;
    realm.pending_exception = null;
    const js_bits: u128 = ex.bits;
    const rec = if (exceptionStateOf(ex)) |st|
        owner.internExnRecord(st.tag, st.payload, js_bits)
    else
        owner.internExnRecord(&realm.wasm_foreign_exn_tag, &.{}, js_bits);
    if (rec) |r| realm.registerExternGlobalCell(&r.js_value) catch {};
    return rec;
}

fn exceptionConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm) return wasmDisabled(realm);
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception requires 'new'");
    const tt = tagTypeOf(if (args.len > 0) args[0] else Value.undefined_) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception expects a WebAssembly.Tag");
    const payload_obj = heap_mod.valueAsPlainObject(if (args.len > 1) args[1] else Value.undefined_) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception expects a payload array");
    const n: u32 = @intCast(tt.params.len);
    const a = realm.wasmAllocator();
    const payload = a.alloc(u128, n) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        payload[i] = try marshalArg(realm, tt.params[i], payload_obj.tryGetIndexedOwn(i) orelse Value.undefined_);
    }
    const st = a.create(ExceptionState) catch return error.OutOfMemory;
    st.* = .{ .tag = tt, .payload = payload };
    try self.setWasmException(realm.allocator, st);
    try rootExceptionPayload(realm, tt, payload);
    return this_value;
}

fn exceptionIs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = exceptionStateOf(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception.prototype.is called on a non-Exception");
    const tt = tagTypeOf(if (args.len > 0) args[0] else Value.undefined_);
    return Value.fromBool(tt != null and st.tag == tt.?);
}

fn exceptionGetArg(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = exceptionStateOf(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception.prototype.getArg called on a non-Exception");
    const tt = tagTypeOf(if (args.len > 0) args[0] else Value.undefined_) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception.prototype.getArg expects a WebAssembly.Tag");
    if (st.tag != tt)
        return intrinsics.throwTypeError(realm, "WebAssembly.Exception.prototype.getArg: tag does not match this exception");
    const idx_f = arith.toNumber(if (args.len > 1) args[1] else Value.undefined_);
    if (!(idx_f >= 0) or idx_f >= @as(f64, @floatFromInt(st.payload.len)))
        return intrinsics.throwRangeError(realm, "WebAssembly.Exception.prototype.getArg: index out of range");
    const idx: usize = @intFromFloat(idx_f);
    return marshalResult(realm, st.tag.params[idx], st.payload[idx]);
}

// ── WebAssembly.CompileError / LinkError / RuntimeError ─────────────

/// Build a `WebAssembly.<name>` Error subclass on the namespace and
/// return its prototype (chained to %Error.prototype%).
fn makeWasmErrorClass(realm: *Realm, ns: *JSObject, name: []const u8, native: NativeFn) !*JSObject {
    const fn_obj = try realm.heap.allocateFunctionNative(realm, native, 1, name);
    const proto = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(proto, realm.intrinsics.error_prototype);
    try proto.setWithFlags(realm.allocator, "constructor", heap_mod.taggedFunction(fn_obj), .{ .writable = true, .enumerable = false, .configurable = true });
    const name_str = try realm.heap.allocateString(name);
    try proto.setWithFlags(realm.allocator, "name", Value.fromString(name_str), .{ .writable = true, .enumerable = false, .configurable = true });
    const empty = try realm.heap.allocateString("");
    try proto.setWithFlags(realm.allocator, "message", Value.fromString(empty), .{ .writable = true, .enumerable = false, .configurable = true });
    realm.heap.setFunctionPrototype(fn_obj, proto);
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try ns.set(realm.allocator, name, heap_mod.taggedFunction(fn_obj));
    return proto;
}

fn compileErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return error_mod.constructErrorInstance(realm, this_value, realm.wasm_compile_error_prototype.?, args);
}
fn linkErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return error_mod.constructErrorInstance(realm, this_value, realm.wasm_link_error_prototype.?, args);
}
fn runtimeErrorNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return error_mod.constructErrorInstance(realm, this_value, realm.wasm_runtime_error_prototype.?, args);
}

/// Throw an instance of a host-defined wasm error class (falling back to
/// a TypeError if the class somehow isn't installed).
fn throwWasmError(realm: *Realm, proto_opt: ?*JSObject, msg: []const u8) NativeError {
    const proto = proto_opt orelse return intrinsics.throwTypeError(realm, msg);
    const ex = error_mod.newErrorWithProto(realm, proto, msg) catch return error.OutOfMemory;
    realm.pending_exception = ex;
    return error.NativeThrew;
}

fn throwCompileError(realm: *Realm, msg: []const u8) NativeError {
    return throwWasmError(realm, realm.wasm_compile_error_prototype, msg);
}
fn throwLinkError(realm: *Realm, msg: []const u8) NativeError {
    return throwWasmError(realm, realm.wasm_link_error_prototype, msg);
}
fn throwRuntimeError(realm: *Realm, msg: []const u8) NativeError {
    return throwWasmError(realm, realm.wasm_runtime_error_prototype, msg);
}

// ── WebAssembly.Module statics (introspection) ─────────────────────

/// Resolve arg[0] to its decoded `ModuleState`, or throw a TypeError.
/// Shared by `Module.exports` / `Module.imports` / `Module.customSections`.
fn moduleStateArg(realm: *Realm, args: []const Value, who: []const u8) NativeError!*ModuleState {
    const obj = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return moduleArgTypeError(realm, who);
    const raw = obj.getWasmModule() orelse return moduleArgTypeError(realm, who);
    return @ptrCast(@alignCast(raw));
}

fn moduleArgTypeError(realm: *Realm, who: []const u8) NativeError {
    var buf: [80]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "WebAssembly.Module.{s} expects a WebAssembly.Module", .{who}) catch
        "WebAssembly.Module: expected a WebAssembly.Module";
    return intrinsics.throwTypeError(realm, msg);
}

/// §ExternKind → the JS-API external-kind string ("function" / "table" /
/// "memory" / "global" / "tag").
fn externKindString(kind: wasm.module.ExternKind) []const u8 {
    return switch (kind) {
        .func => "function",
        .table => "table",
        .mem => "memory",
        .global => "global",
        .tag => "tag",
    };
}

/// Set an array-exotic element `arr[i] = v` and (re)set `length`.
fn arraySetElem(realm: *Realm, arr: *JSObject, i: usize, v: Value) NativeError!void {
    var buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    arr.set(realm.allocator, key, v) catch return error.OutOfMemory;
}

/// `WebAssembly.Module.exports(module)` — an Array of `{ name, kind }`,
/// one per export, in declaration order (JS-API ModuleExports). Ungated.
fn wasmModuleExports(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const mstate = try moduleStateArg(realm, args, "exports");
    const exports = mstate.module.exports;

    const arr = intrinsics.allocateArray(realm) catch return error.OutOfMemory;
    // Root the result array across the per-export object/string allocs.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(arr)) catch return error.OutOfMemory;

    for (exports, 0..) |ex, i| {
        const entry = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(entry, realm.intrinsics.object_prototype);
        // Root the in-flight entry while its two string values allocate.
        const escope = realm.heap.openScope() catch return error.OutOfMemory;
        defer escope.close();
        escope.push(heap_mod.taggedObject(entry)) catch return error.OutOfMemory;
        // Property order is `name` then `kind`.
        const name_str = realm.heap.allocateString(ex.name) catch return error.OutOfMemory;
        entry.set(realm.allocator, "name", Value.fromString(name_str)) catch return error.OutOfMemory;
        const kind_str = realm.heap.allocateString(externKindString(ex.desc)) catch return error.OutOfMemory;
        entry.set(realm.allocator, "kind", Value.fromString(kind_str)) catch return error.OutOfMemory;
        try arraySetElem(realm, arr, i, heap_mod.taggedObject(entry));
    }
    arr.set(realm.allocator, "length", Value.fromInt32(@intCast(exports.len))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

/// `WebAssembly.Module.imports(module)` — an Array of `{ module, name,
/// kind }`, one per import, in declaration order. Ungated.
fn wasmModuleImports(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const mstate = try moduleStateArg(realm, args, "imports");
    const imports = mstate.module.imports;

    const arr = intrinsics.allocateArray(realm) catch return error.OutOfMemory;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(arr)) catch return error.OutOfMemory;

    for (imports, 0..) |imp, i| {
        const entry = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(entry, realm.intrinsics.object_prototype);
        const escope = realm.heap.openScope() catch return error.OutOfMemory;
        defer escope.close();
        escope.push(heap_mod.taggedObject(entry)) catch return error.OutOfMemory;
        // Property order is `module`, `name`, `kind`.
        const mod_str = realm.heap.allocateString(imp.module) catch return error.OutOfMemory;
        entry.set(realm.allocator, "module", Value.fromString(mod_str)) catch return error.OutOfMemory;
        const name_str = realm.heap.allocateString(imp.name) catch return error.OutOfMemory;
        entry.set(realm.allocator, "name", Value.fromString(name_str)) catch return error.OutOfMemory;
        const kind_str = realm.heap.allocateString(externKindString(imp.desc)) catch return error.OutOfMemory;
        entry.set(realm.allocator, "kind", Value.fromString(kind_str)) catch return error.OutOfMemory;
        try arraySetElem(realm, arr, i, heap_mod.taggedObject(entry));
    }
    arr.set(realm.allocator, "length", Value.fromInt32(@intCast(imports.len))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

/// `WebAssembly.Module.customSections(module, sectionName)` — an Array of
/// fresh `ArrayBuffer` copies of every custom section whose name equals
/// `String(sectionName)`, in declaration order. Ungated.
fn wasmModuleCustomSections(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const mstate = try moduleStateArg(realm, args, "customSections");

    // §7.1.17 ToString(sectionName) — the full abstract operation, so a
    // user-defined `toString` / `@@toPrimitive` on an object argument is
    // observed per spec (not the primitive-only coercion). Copy the key
    // into a stable buffer: it must survive the GC the array / ArrayBuffer
    // allocations below may trigger (the JSString is not rooted past here).
    const name_js = try intrinsics.stringifyArg(realm, if (args.len > 1) args[1] else Value.undefined_);
    const want = realm.classAllocator().dupe(u8, name_js.flatBytes()) catch return error.OutOfMemory;
    defer realm.classAllocator().free(want);

    const arr = intrinsics.allocateArray(realm) catch return error.OutOfMemory;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(arr)) catch return error.OutOfMemory;

    var n: usize = 0;
    for (mstate.module.custom_sections) |cs| {
        if (!std.mem.eql(u8, cs.name, want)) continue;
        const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(buf_obj, realm.intrinsics.array_buffer_prototype);
        // A fresh, engine-owned copy of the payload (the §ArrayBuffer is
        // mutable and outlives the borrowed wasm-arena slice).
        const copy = realm.allocator.alloc(u8, cs.bytes.len) catch return error.OutOfMemory;
        @memcpy(copy, cs.bytes);
        buf_obj.setArrayBuffer(realm.allocator, copy) catch return error.OutOfMemory;
        buf_obj.has_array_buffer_data = true;
        try arraySetElem(realm, arr, n, heap_mod.taggedObject(buf_obj));
        n += 1;
    }
    arr.set(realm.allocator, "length", Value.fromInt32(@intCast(n))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
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
