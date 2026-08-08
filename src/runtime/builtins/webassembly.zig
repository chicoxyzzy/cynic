//! The `WebAssembly` JS namespace — the host API surface over Sarcasm
//! (the engine in `src/runtime/wasm/`).
//!
//! Surface:
//!   - `validate(bytes)` — ungated (only inspects bytes).
//!   - `Module` / `Instance` constructors + `compile` / `instantiate`
//!     Promises. HostEnsureCanCompileWasmBytes gates only dynamic bytes;
//!     predecoded modules remain usable (docs/wasm-engine.md §8-§9).
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
//! Immutable wasm metadata and store headers live in the realm's `wasm_arena`.
//! Movable Memory/Table backings use an immediate-free quota allocator, and
//! Spasm executable mappings are explicitly unmapped before the arena drops.
//! The GC-facing exception is `externref`: a JS value handed to wasm is kept
//! alive as a GC root — *transiently* while it is on the wasm stack during a call
//! (dropped when the outermost call returns), and *persistently* while
//! it sits in a registered externref table / global (walked each GC). So
//! it survives wherever wasm holds it (the non-moving collector
//! preserves identity) and is reclaimed once wasm drops it. See §5.
//!
//! Ordinary imported memories share the provider's `Memory` record, so writes
//! and growth propagate both ways. Wasm shared-memory threads remain out of
//! scope; their eventual backing must use SharedDataBlock for non-moving,
//! in-place growth. A v128 value crossing the JS boundary throws a TypeError — that
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
    /// `shared: true` in the descriptor — `buffer` is exposed as a
    /// SharedArrayBuffer (JS-API §Memory), required to carry a maximum.
    shared: bool = false,
};

fn detachMemoryHostView(object: *anyopaque) void {
    const buffer: *JSObject = @ptrCast(@alignCast(object));
    if (buffer.arrayBufferSlot()) |slot| slot.* = null;
}

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
        try (try global_ctor.proto.flagsMut(realm.allocator)).put(realm.allocator, "value", .{
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
        try (try table_ctor.proto.flagsMut(realm.allocator)).put(realm.allocator, "length", .{
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
        try (try memory_ctor.proto.flagsMut(realm.allocator)).put(realm.allocator, "buffer", .{
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
/// realm-resident module. This is the HostEnsureCanCompileWasmBytes gate.
fn moduleConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (!realm.allow_wasm_compile) return wasmCompileDisabled(realm);
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
    // Record the decoded module so the playground's WAT inspector can
    // disassemble what a snippet built (non-owning — it lives in the wasm
    // arena). Harmless for ordinary callers: a single pointer store.
    realm.last_wasm_module = @ptrCast(mp);
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

/// `new WebAssembly.Instance(module, importObject?)` — instantiate an
/// already-decoded module. No byte compilation occurs here.
fn instanceConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
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
    var imports = try resolveImports(realm, mstate.module, import_object);
    imports.store_allocator = realm.wasmStoreAllocator();

    const a = realm.wasmAllocator();
    const ip = a.create(wasm.Instance) catch return error.OutOfMemory;
    wasm.instantiate(ip, a, a, mstate.module, imports) catch
        return throwLinkError(realm, "WebAssembly.Instance: instantiation failed");
    ip.spasm_memory_ledger = realm.wasmCodeMemoryLedger();
    realm.registerWasmInstance(ip) catch {
        ip.releaseOwnedStoreBackings();
        return error.OutOfMemory;
    };
    var registered_extern_tables: usize = 0;
    var registered_extern_globals: usize = 0;
    errdefer {
        var tables_remaining = registered_extern_tables;
        for (0..ip.tables.len) |i| {
            if (tables_remaining == 0) break;
            if ((ip.tableElemType(@intCast(i)) orelse continue) != .externref) continue;
            const table = ip.tableRef(@intCast(i)) orelse continue;
            realm.unregisterExternTable(table);
            tables_remaining -= 1;
        }

        var globals_remaining = registered_extern_globals;
        for (0..ip.globals.len) |i| {
            if (globals_remaining == 0) break;
            const gt = ip.globalTypeAt(@intCast(i)) orelse continue;
            if (gt.val != .externref) continue;
            const cell = ip.globalCellPtr(@intCast(i)) orelse continue;
            realm.unregisterExternGlobalCell(cell);
            globals_remaining -= 1;
        }

        realm.unregisterWasmInstance(ip);
    }

    // Let a `try_table` in this instance catch a JS exception thrown by a
    // host import (the JS->wasm direction): the interpreter reifies the
    // realm's pending exception through this bridge.
    ip.host_exn_ctx = realm;
    ip.host_exn_hook = convertHostException;
    ip.execution_control = .{
        .ctx = realm,
        .poll_fn = pollWasmExecution,
        .armed_fn = wasmExecutionMeteringArmed,
        .wake_flag = realm.executionWakeFlag(),
    };
    ip.invocation_allocator = realm.wasmInvocationAllocator();

    // Baseline-compile this instance's functions through Spasm when the
    // JIT is on (docs/jit.md §6) — the production wasm posture every
    // shipping engine takes (V8 Liftoff, SpiderMonkey baseline, JSC BBQ
    // all baseline-compile wasm rather than interpret it). Each emittable
    // function compiles on its first invoke and the cached EntryFn runs
    // thereafter; anything outside the class degrades to the interpreter.
    // `--no-jit` (jit_enabled = false) keeps the pure interpreter for both
    // the JS and wasm tiers.
    ip.spasm_enabled = realm.jit_enabled;

    // Register the instance's externref tables / globals as GC roots, so a
    // JS value a wasm body stores into one survives past the call that put
    // it there (its transient pin is dropped at the outermost return).
    for (0..ip.tables.len) |i| {
        if ((ip.tableElemType(@intCast(i)) orelse continue) == .externref) {
            realm.registerExternTable(ip.tableRef(@intCast(i)).?) catch return error.OutOfMemory;
            registered_extern_tables += 1;
        }
    }
    for (0..ip.globals.len) |i| {
        const gt = ip.globalTypeAt(@intCast(i)) orelse continue;
        if (gt.val == .externref) {
            realm.registerExternGlobalCell(ip.globalCellPtr(@intCast(i)).?) catch return error.OutOfMemory;
            registered_extern_globals += 1;
        }
    }

    wasm.runStart(ip, realm.wasmInvocationAllocator()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HostThrew => return error.NativeThrew, // a host import threw during start
        error.StepBudgetExhausted,
        error.ExecutionInterrupted,
        error.ExecutionTerminated,
        => return throwWasmExecutionError(realm, err),
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
    if (!realm.allow_wasm_compile) return wasmCompileDisabled(realm);
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
    const result = instantiateToResult(realm, args) catch |err| {
        // Host termination is not an ECMAScript abrupt completion and must
        // not be made catchable by converting it into a rejected Promise.
        // Preserve the termination latch and unwind through the native-call
        // boundary exactly like synchronous `new WebAssembly.Instance`.
        if (err == error.NativeThrew and realm.terminationReason() != null) return error.NativeThrew;
        return rejectFromError(realm, cap, err);
    };
    return promise_mod.capabilityResolve(realm, cap, result);
}

fn instantiateToResult(realm: *Realm, args: []const Value) NativeError!Value {
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
    if (!realm.allow_wasm_compile) return wasmCompileDisabled(realm);
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
/// mutable global cell. It constructs store state, not executable code.
fn globalConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
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
/// growable reference table. It is independent of byte compilation policy.
fn tableConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
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

    // JS-API §Table — `initial` is required; `maximum`, when present,
    // must be ≥ `initial`.
    const initial_v = desc.get("initial");
    if (initial_v.isUndefined())
        return intrinsics.throwTypeError(realm, "WebAssembly.Table: missing required 'initial'");
    const initial = try indexArg(realm, initial_v);
    const max = try optionalIndexArg(realm, desc.get("maximum"));
    if (max) |m| {
        if (m < initial) return intrinsics.throwRangeError(realm, "WebAssembly.Table: maximum is less than initial");
    }

    const fill = if (args.len > 1) try tableElemFromValue(realm, is_funcref, args[1]) else wasm.REF_NULL;
    const a = realm.wasmAllocator();
    const store_allocator = realm.wasmStoreAllocator();
    const elems = store_allocator.alloc(u128, initial) catch return error.OutOfMemory;
    @memset(elems, fill);

    const tbl = a.create(wasm.Table) catch {
        store_allocator.free(elems);
        return error.OutOfMemory;
    };
    tbl.* = .{
        .elems = elems,
        .max = max,
        .is_64 = false,
        .backing_allocator = store_allocator,
    };
    var backing_registered = false;
    errdefer if (!backing_registered) tbl.releaseBacking(store_allocator);
    const st = a.create(TableState) catch return error.OutOfMemory;
    st.* = .{ .table = tbl, .funcref = is_funcref };
    try self.setWasmTable(realm.allocator, st);
    var extern_root_registered = false;
    errdefer if (extern_root_registered) realm.unregisterExternTable(tbl);
    if (!is_funcref) {
        realm.registerExternTable(tbl) catch return error.OutOfMemory;
        extern_root_registered = true;
    }
    realm.registerWasmTable(tbl) catch return error.OutOfMemory;
    backing_registered = true;
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
    // The fill value is coerced per the table's element type — an
    // externref table accepts any JS value, not just a funcref.
    const fill = if (args.len > 1) try tableElemFromValue(realm, st.funcref, args[1]) else wasm.REF_NULL;
    const old_len = st.table.elems.len;
    const new_len = std.math.add(usize, old_len, delta) catch
        return intrinsics.throwRangeError(realm, "WebAssembly.Table.grow size is too large");
    if (st.table.max) |m| {
        if (new_len > m) return intrinsics.throwRangeError(realm, "WebAssembly.Table.grow exceeds the maximum");
    }
    const new_elems = st.table.storeAllocator(realm.wasmStoreAllocator()).realloc(st.table.elems, new_len) catch
        return error.OutOfMemory;
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
/// linear memory. The bytes use the Realm's immediate-free metered allocator;
/// `buffer` exposes a non-owning ArrayBuffer view over them.
fn memoryConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const self = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory requires 'new'");
    const desc = (if (args.len > 0) heap_mod.valueAsPlainObject(args[0]) else null) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory expects a descriptor object");

    // JS-API §Memory — `initial` is a required descriptor member; a
    // missing one is a TypeError, not a default-to-zero.
    const initial_v = desc.get("initial");
    if (initial_v.isUndefined())
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory: missing required 'initial'");
    const initial = try indexArg(realm, initial_v);
    const max = try optionalIndexArg(realm, desc.get("maximum"));
    // §Memory — `maximum`, when present, must be ≥ `initial`.
    if (max) |m| {
        if (m < initial) return intrinsics.throwRangeError(realm, "WebAssembly.Memory: maximum is less than initial");
    }
    // A shared memory exposes its buffer as a SharedArrayBuffer and must
    // declare a maximum (the buffer can never move).
    const shared = arith.toBoolean(desc.get("shared"));
    if (shared and max == null)
        return intrinsics.throwTypeError(realm, "WebAssembly.Memory: a shared memory requires a maximum");

    const byte_len = std.math.mul(usize, initial, wasm.PAGE_SIZE) catch
        return intrinsics.throwRangeError(realm, "WebAssembly.Memory size is too large");
    if (byte_len > realm.heap.max_bytes -| realm.heap.bytes_live)
        return intrinsics.throwRangeError(realm, "WebAssembly.Memory exceeds the Realm memory limit");
    const a = realm.wasmAllocator();
    const store_allocator = realm.wasmStoreAllocator();
    // SharedArrayBuffer views are non-detachable and may be observed from
    // another agent. Keep their provisional backing arena-retained until the
    // Wasm shared-memory path uses SharedDataBlock in-place growth.
    const backing_allocator = if (shared) a else store_allocator;
    const bytes = backing_allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
    @memset(bytes, 0);
    const mem = a.create(wasm.Memory) catch {
        backing_allocator.free(bytes);
        return error.OutOfMemory;
    };
    mem.* = .{
        .data = bytes,
        .max_pages = max,
        .is_64 = false,
        .is_shared = shared,
        .backing_allocator = backing_allocator,
    };
    var backing_registered = false;
    errdefer if (!backing_registered) mem.releaseBacking(backing_allocator);
    const st = a.create(MemoryState) catch return error.OutOfMemory;
    st.* = .{ .mem = mem, .buffer = null, .shared = shared };
    try self.setWasmMemory(realm.allocator, st);
    realm.registerWasmMemory(mem) catch return error.OutOfMemory;
    backing_registered = true;
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
    if (st.buffer) |buffer| {
        if (buffer.getArrayBuffer() != null) return heap_mod.taggedObject(buffer);
        st.buffer = null;
    }
    const buf = realm.heap.allocateObject() catch return error.OutOfMemory;
    // A shared memory's buffer is a SharedArrayBuffer (JS-API §Memory):
    // the SAB prototype plus the `array_buffer_shared` flag, over the
    // same non-owning view of the live linear bytes.
    const ab_proto: ?*JSObject = if (st.shared) blk: {
        if (heap_mod.valueAsFunction(realm.globals.get("SharedArrayBuffer") orelse Value.undefined_)) |c| break :blk c.prototype;
        break :blk realm.intrinsics.array_buffer_prototype;
    } else realm.intrinsics.array_buffer_prototype;
    realm.heap.setObjectPrototype(buf, ab_proto);
    buf.setExternalArrayBuffer(realm.allocator, st.mem.data) catch return error.OutOfMemory;
    buf.brand.has_array_buffer_data = true;
    if (st.shared) buf.brand.array_buffer_shared = true;
    st.mem.registerHostView(realm.wasmStoreAllocator(), .{
        .object = buf,
        .detach_fn = detachMemoryHostView,
    }) catch return error.OutOfMemory;
    st.buffer = buf;
    return heap_mod.taggedObject(buf);
}

/// `Memory.prototype.grow(delta)` — grow by `delta` pages, detach the
/// current buffer, return the previous page count.
fn memoryGrow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try memoryStateOf(realm, this_value);
    const delta = try indexArg(realm, if (args.len > 0) args[0] else Value.undefined_);
    const old_pages = st.mem.data.len / wasm.PAGE_SIZE;
    const new_pages = std.math.add(usize, old_pages, delta) catch
        return intrinsics.throwRangeError(realm, "WebAssembly.Memory.grow size is too large");
    if (st.mem.max_pages) |m| {
        if (new_pages > m) return intrinsics.throwRangeError(realm, "WebAssembly.Memory.grow exceeds the maximum");
    }
    const byte_len = std.math.mul(usize, new_pages, wasm.PAGE_SIZE) catch
        return intrinsics.throwRangeError(realm, "WebAssembly.Memory.grow size is too large");
    const growth_bytes = byte_len - st.mem.data.len;
    if (growth_bytes > realm.heap.max_bytes -| realm.heap.bytes_live)
        return intrinsics.throwRangeError(realm, "WebAssembly.Memory.grow exceeds the Realm memory limit");
    const old_len = st.mem.data.len;
    const new_bytes = st.mem.storeAllocator(realm.wasmStoreAllocator()).realloc(st.mem.data, byte_len) catch
        return error.OutOfMemory;
    @memset(new_bytes[old_len..], 0);
    // DetachArrayBuffer (§25.1.3.4) on every materialized non-shared view,
    // including wrappers created for imports/exports of this Memory record.
    st.mem.detachHostViewsAfterGrow();
    st.mem.data = new_bytes;
    return Value.fromInt32(@intCast(old_pages));
}

/// Wrap a shared engine memory as a `WebAssembly.Memory` (for exports).
fn makeMemory(realm: *Realm, mem: *wasm.Memory) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_memory_prototype);
    const st = realm.wasmAllocator().create(MemoryState) catch return error.OutOfMemory;
    st.* = .{ .mem = mem, .buffer = null, .shared = mem.is_shared };
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

fn pollWasmExecution(ctx: *anyopaque) wasm.ExecutionPoll {
    const realm: *Realm = @ptrCast(@alignCast(ctx));
    return switch (realm.pollExecution()) {
        .proceed => .proceed,
        .step_budget_exhausted => .step_budget_exhausted,
        .cooperative_interrupted => .cooperative_interrupted,
        .terminated => .terminated,
    };
}

fn wasmExecutionMeteringArmed(ctx: *anyopaque) bool {
    const realm: *Realm = @ptrCast(@alignCast(ctx));
    return realm.executionMeteringArmed();
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

    const invoke_allocator = realm.wasmInvocationAllocator();
    const results = wasm.invoke(rec.instance, invoke_allocator, rec.func_index, argbuf[0..ft.params.len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A JS-backed host import threw — re-raise its pending exception.
        error.HostThrew => return error.NativeThrew,
        error.StepBudgetExhausted,
        error.ExecutionInterrupted,
        error.ExecutionTerminated,
        => return throwWasmExecutionError(realm, err),
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
    defer invoke_allocator.free(results);

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

/// HostEnsureCanCompileWasmBytes refusal. CSP uses CompileError for this
/// hook; the object model and predecoded modules remain available.
fn wasmCompileDisabled(realm: *Realm) NativeError {
    return throwCompileError(realm, "WebAssembly byte compilation is disabled by host policy");
}

fn throwWasmExecutionError(realm: *Realm, err: anyerror) NativeError {
    return switch (err) {
        error.StepBudgetExhausted => intrinsics.throwRangeError(realm, "interpreter step budget exhausted"),
        error.ExecutionInterrupted => intrinsics.throwRangeError(realm, "execution interrupted"),
        error.ExecutionTerminated => intrinsics.throwRangeError(realm, realm.terminationMessage()),
        else => unreachable,
    };
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
    // Host termination is not a JavaScript exception and must never be
    // captured by a Wasm `catch_all`. Leave the pending synthetic value
    // intact for the JS boundary; Lantern's termination latch then skips
    // every JS catch/finally handler too.
    if (realm.terminationReason() != null) return null;
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
        const buf_scope = realm.heap.openScope() catch return error.OutOfMemory;
        defer buf_scope.close();
        buf_scope.push(heap_mod.taggedObject(buf_obj)) catch return error.OutOfMemory;
        // A fresh, engine-owned copy of the payload (the §ArrayBuffer is
        // mutable and outlives the borrowed wasm-arena slice).
        realm.heap.charge(cs.bytes.len) catch return error.OutOfMemory;
        const copy = realm.allocator.alloc(u8, cs.bytes.len) catch {
            realm.heap.discharge(cs.bytes.len);
            return error.OutOfMemory;
        };
        @memcpy(copy, cs.bytes);
        buf_obj.setArrayBuffer(realm.allocator, copy) catch {
            realm.allocator.free(copy);
            realm.heap.discharge(cs.bytes.len);
            return error.OutOfMemory;
        };
        buf_obj.brand.has_array_buffer_data = true;
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

// ── tests ───────────────────────────────────────────────────────────

const RealmInterruptWorker = struct {
    realm: *Realm,
    function: *JSFunction,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn run(self: *RealmInterruptWorker) void {
        const outcome = call.callJSFunction(
            self.realm.allocator,
            self.realm,
            self.function,
            Value.undefined_,
            &.{},
        ) catch {
            self.status.store(3, .release);
            return;
        };
        self.status.store(switch (outcome) {
            .thrown => 1,
            .value, .yielded => 2,
        }, .release);
    }
};

const RealmInterruptBarrier = struct {
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn invoke(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
        _ = args;
        _ = results;
        const self: *RealmInterruptBarrier = @ptrCast(@alignCast(ctx orelse return));
        if (!self.enabled.load(.acquire)) return;
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "WebAssembly JS API: a jit-enabled realm runs instance exports through Spasm" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");
    const spasm = @import("../wasm/spasm.zig");
    if (comptime !spasm.supported) return error.SkipZigTest;

    // A self-contained `(i32,i32)->i32` adder module — fully within
    // Spasm's emittable class (local.get/local.get/i32.add).
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // preamble
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32,i32)->i32
        0x03, 0x02, 0x01, 0x00, // func 0 : type 0
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" -> 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
    };

    // Embed the module bytes as a Uint8Array literal and drive the real
    // JS API: `new WebAssembly.Instance(new WebAssembly.Module(bytes))`,
    // call the export, then yield the export function so the test can
    // reach the backing wasm Instance through its ExportRecord.
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "const i=new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([");
    for (mod_bytes, 0..) |b, idx| {
        if (idx != 0) try src.append(testing.allocator, ',');
        var tmp: [3]u8 = undefined;
        try src.appendSlice(testing.allocator, std.fmt.bufPrint(&tmp, "{d}", .{b}) catch unreachable);
    }
    try src.appendSlice(testing.allocator, "])));i.exports.add(7,35);i.exports.add;");

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true; // the production default; Spasm should engage
    try realm.installBuiltins();

    const fn_result = try lantern.evaluateScript(testing.allocator, &realm, src.items);
    const fn_val = switch (fn_result) {
        .value => |v| v,
        else => return error.TestUnexpectedResult,
    };
    const fn_obj = heap_mod.valueAsFunction(fn_val) orelse return error.TestUnexpectedResult;
    const rec: *ExportRecord = @ptrCast(@alignCast(fn_obj.wasm_export orelse return error.TestUnexpectedResult));

    // The JIT flag propagated to the instance, and calling the export
    // actually ran Spasm-compiled native code (not the interpreter).
    try testing.expect(rec.instance.spasm_enabled);
    try testing.expect(rec.instance.spasm_runs >= 1);
    try testing.expectEqual(@as(usize, 1), realm.wasm_instances.items.len);

    // Realm teardown uses the same idempotent release operation before its
    // arena invalidates the instance pointer.
    try testing.expect(rec.instance.spasm_cache != null);
    const live_before_release = realm.heap.bytes_live;
    rec.instance.releaseExecutableCode();
    try testing.expect(rec.instance.spasm_cache == null);
    try testing.expectEqual(live_before_release - 64 * 1024, realm.heap.bytes_live);
}

test "WebAssembly JS API: growable store backings charge only their live size" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    try realm.installBuiltins();

    const memory_result = try lantern.evaluateScript(
        testing.allocator,
        &realm,
        "new WebAssembly.Memory({initial:1,maximum:3})",
    );
    const memory_value = switch (memory_result) {
        .value => |v| v,
        else => return error.TestUnexpectedResult,
    };
    const memory_live = realm.heap.bytes_live;
    _ = try memoryGrow(&realm, memory_value, &.{Value.fromInt32(1)});
    try testing.expectEqual(memory_live + wasm.PAGE_SIZE, realm.heap.bytes_live);
    const memory_after_growth = realm.heap.bytes_live;
    _ = try memoryGrow(&realm, memory_value, &.{Value.fromInt32(0)});
    try testing.expectEqual(memory_after_growth, realm.heap.bytes_live);

    const table_result = try lantern.evaluateScript(
        testing.allocator,
        &realm,
        "new WebAssembly.Table({element:'anyfunc',initial:2,maximum:10})",
    );
    const table_value = switch (table_result) {
        .value => |v| v,
        else => return error.TestUnexpectedResult,
    };
    const table_live = realm.heap.bytes_live;
    _ = try tableGrow(&realm, table_value, &.{Value.fromInt32(3)});
    try testing.expectEqual(table_live + 3 * @sizeOf(u128), realm.heap.bytes_live);
    const table_after_growth = realm.heap.bytes_live;
    _ = try tableGrow(&realm, table_value, &.{Value.fromInt32(0)});
    try testing.expectEqual(table_after_growth, realm.heap.bytes_live);
}

test "WebAssembly.Memory keeps its cached buffer alive across GC" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();

    const evaluated = try lantern.evaluateScript(
        testing.allocator,
        &realm,
        "const rootedMemory=new WebAssembly.Memory({initial:1});({memory:rootedMemory,ref:new WeakRef(rootedMemory.buffer)});",
    );
    const container_value = switch (evaluated) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scope = try realm.heap.openScope();
    defer scope.close();
    try scope.push(container_value);
    const container = heap_mod.valueAsPlainObject(container_value) orelse return error.TestUnexpectedResult;
    const memory_value = container.get("memory");
    const weak = heap_mod.valueAsPlainObject(container.get("ref")) orelse return error.TestUnexpectedResult;

    realm.clearKeptObjects();
    realm.collectGarbage();
    const target = weak.getWeakRefTarget();
    try testing.expect(!target.isUndefined());
    const cached = try memoryBufferGet(&realm, memory_value, &.{});
    try testing.expectEqual(target.bits, cached.bits);
}

test "WebAssembly.Memory host views outlive an importing child Realm" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");

    // (module (import "m" "mem" (memory 1)) (export "mem" (memory 0)))
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x02, 0x0a, 0x01, 0x01, 'm',  0x03, 'm',  'e',
        'm',  0x02, 0x00, 0x01, 0x07, 0x07, 0x01, 0x03,
        'm',  'e',  'm',  0x02, 0x00,
    };

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    const child = try parent.allocator.create(Realm);
    child.* = Realm.initChild(&parent);
    var child_live = true;
    defer if (child_live) {
        child.deinit();
        parent.allocator.destroy(child);
    };
    child.allow_wasm_compile = true;
    try child.installBuiltins();

    const scope = try parent.heap.openScope();
    defer scope.close();
    const memory_result = try lantern.evaluateScript(
        testing.allocator,
        &parent,
        "new WebAssembly.Memory({initial:1,maximum:2})",
    );
    const parent_memory = switch (memory_result) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try scope.push(parent_memory);

    const namespace = parent.heap.allocateObject() catch return error.OutOfMemory;
    try scope.push(heap_mod.taggedObject(namespace));
    try namespace.set(parent.allocator, "mem", parent_memory);
    const imports = parent.heap.allocateObject() catch return error.OutOfMemory;
    try scope.push(heap_mod.taggedObject(imports));
    try imports.set(parent.allocator, "m", heap_mod.taggedObject(namespace));

    const module_value = try makeModuleObject(child, &mod_bytes);
    try scope.push(module_value);
    const module_object = heap_mod.valueAsPlainObject(module_value) orelse return error.TestUnexpectedResult;
    const module_state: *ModuleState = @ptrCast(@alignCast(module_object.getWasmModule() orelse return error.TestUnexpectedResult));
    const instance_value = try makeInstanceObject(child, module_state, heap_mod.taggedObject(imports));
    try scope.push(instance_value);
    const instance_object = heap_mod.valueAsPlainObject(instance_value) orelse return error.TestUnexpectedResult;
    const exports = heap_mod.valueAsPlainObject(instance_object.get("exports")) orelse return error.TestUnexpectedResult;
    const child_memory = exports.get("mem");
    const child_buffer = try memoryBufferGet(child, child_memory, &.{});
    try scope.push(child_buffer);
    const buffer_object = heap_mod.valueAsPlainObject(child_buffer) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, wasm.PAGE_SIZE), buffer_object.getArrayBuffer().?.len);

    // The provider Memory keeps only the rooted buffer pointer, never a
    // callback context into the importing Realm's arena. Growing after child
    // teardown therefore detaches safely instead of touching freed metadata.
    child.deinit();
    parent.allocator.destroy(child);
    child_live = false;
    _ = try memoryGrow(&parent, parent_memory, &.{Value.fromInt32(1)});
    try testing.expect(buffer_object.getArrayBuffer() == null);
}

fn testRealmBackedMemoryGrow(jit_enabled: bool) !void {
    const testing = std.testing;

    // (module (memory (export "m") 1 3)
    //         (func (export "gr") (param i32) (result i32)
    //           local.get 0 memory.grow))
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01,
        0x01, 0x03, 0x07, 0x0a, 0x02, 0x01, 'm',  0x02,
        0x00, 0x02, 'g',  'r',  0x00, 0x00, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b,
    };

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = jit_enabled;
    try realm.installBuiltins();

    const scope = try realm.heap.openScope();
    defer scope.close();
    const module_value = try makeModuleObject(&realm, &mod_bytes);
    try scope.push(module_value);
    const module_object = heap_mod.valueAsPlainObject(module_value) orelse return error.TestUnexpectedResult;
    const module_state: *ModuleState = @ptrCast(@alignCast(module_object.getWasmModule() orelse return error.TestUnexpectedResult));
    const instance_value = try makeInstanceObject(&realm, module_state, Value.undefined_);
    try scope.push(instance_value);
    const instance_object = heap_mod.valueAsPlainObject(instance_value) orelse return error.TestUnexpectedResult;
    const exports = heap_mod.valueAsPlainObject(instance_object.get("exports")) orelse return error.TestUnexpectedResult;
    const memory_value = exports.get("m");
    const grow_function = heap_mod.valueAsFunction(exports.get("gr")) orelse return error.TestUnexpectedResult;
    const record: *ExportRecord = @ptrCast(@alignCast(grow_function.wasm_export orelse return error.TestUnexpectedResult));

    // Compile the JIT posture before taking the quota baseline. A zero grow
    // leaves the live backing size unchanged and avoids mixing code-page
    // reservation into the storage assertion below.
    const warm = try call.callJSFunction(realm.allocator, &realm, grow_function, Value.undefined_, &.{Value.fromInt32(0)});
    switch (warm) {
        .value => |value| try testing.expectEqual(@as(i32, 1), value.asInt32()),
        else => return error.TestUnexpectedResult,
    }
    if (jit_enabled and comptime @import("../wasm/spasm.zig").supported)
        try testing.expect(record.instance.spasm_runs >= 1);
    if (!jit_enabled) {
        try testing.expect(!record.instance.spasm_enabled);
        try testing.expectEqual(@as(u32, 0), record.instance.spasm_runs);
    }

    const old_buffer_value = try memoryBufferGet(&realm, memory_value, &.{});
    try scope.push(old_buffer_value);
    const old_buffer = heap_mod.valueAsPlainObject(old_buffer_value) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, wasm.PAGE_SIZE), old_buffer.getArrayBuffer().?.len);

    const live_before_grow = realm.heap.bytes_live;
    const runs_before_grow = record.instance.spasm_runs;
    const outcome = try call.callJSFunction(realm.allocator, &realm, grow_function, Value.undefined_, &.{Value.fromInt32(1)});
    switch (outcome) {
        .value => |value| try testing.expectEqual(@as(i32, 1), value.asInt32()),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(live_before_grow + wasm.PAGE_SIZE, realm.heap.bytes_live);
    if (jit_enabled and comptime @import("../wasm/spasm.zig").supported)
        try testing.expect(record.instance.spasm_runs > runs_before_grow);
    if (!jit_enabled) try testing.expectEqual(@as(u32, 0), record.instance.spasm_runs);
    try testing.expect(old_buffer.getArrayBuffer() == null);
    const new_buffer_value = try memoryBufferGet(&realm, memory_value, &.{});
    try testing.expect(new_buffer_value.bits != old_buffer_value.bits);
    const new_buffer = heap_mod.valueAsPlainObject(new_buffer_value) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2 * wasm.PAGE_SIZE), new_buffer.getArrayBuffer().?.len);
}

test "WebAssembly-side memory.grow uses the Realm store allocator in the interpreter" {
    try testRealmBackedMemoryGrow(false);
}

test "WebAssembly-side memory.grow uses the Realm store allocator with JIT enabled" {
    try testRealmBackedMemoryGrow(true);
}

fn testRealmBackedTableGrow(jit_enabled: bool) !void {
    const testing = std.testing;

    // (module (table (export "t") 2 10 funcref)
    //         (func (export "gr") (param i32) (result i32)
    //           ref.null func local.get 0 table.grow 0))
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00, 0x04, 0x05, 0x01, 0x70,
        0x01, 0x02, 0x0a, 0x07, 0x0a, 0x02, 0x01, 't',
        0x01, 0x00, 0x02, 'g',  'r',  0x00, 0x00, 0x0a,
        0x0b, 0x01, 0x09, 0x00, 0xd0, 0x70, 0x20, 0x00,
        0xfc, 0x0f, 0x00, 0x0b,
    };

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = jit_enabled;
    try realm.installBuiltins();

    const scope = try realm.heap.openScope();
    defer scope.close();
    const module_value = try makeModuleObject(&realm, &mod_bytes);
    try scope.push(module_value);
    const module_object = heap_mod.valueAsPlainObject(module_value) orelse return error.TestUnexpectedResult;
    const module_state: *ModuleState = @ptrCast(@alignCast(module_object.getWasmModule() orelse return error.TestUnexpectedResult));
    const instance_value = try makeInstanceObject(&realm, module_state, Value.undefined_);
    try scope.push(instance_value);
    const instance_object = heap_mod.valueAsPlainObject(instance_value) orelse return error.TestUnexpectedResult;
    const exports = heap_mod.valueAsPlainObject(instance_object.get("exports")) orelse return error.TestUnexpectedResult;
    try testing.expect(!exports.get("t").isUndefined());
    const grow_function = heap_mod.valueAsFunction(exports.get("gr")) orelse return error.TestUnexpectedResult;
    const record: *ExportRecord = @ptrCast(@alignCast(grow_function.wasm_export orelse return error.TestUnexpectedResult));

    const warm = try call.callJSFunction(realm.allocator, &realm, grow_function, Value.undefined_, &.{Value.fromInt32(0)});
    switch (warm) {
        .value => |value| try testing.expectEqual(@as(i32, 2), value.asInt32()),
        else => return error.TestUnexpectedResult,
    }
    if (jit_enabled and comptime @import("../wasm/spasm.zig").supported)
        try testing.expect(record.instance.spasm_runs >= 1);
    if (!jit_enabled) {
        try testing.expect(!record.instance.spasm_enabled);
        try testing.expectEqual(@as(u32, 0), record.instance.spasm_runs);
    }

    const live_before_grow = realm.heap.bytes_live;
    const runs_before_grow = record.instance.spasm_runs;
    const outcome = try call.callJSFunction(realm.allocator, &realm, grow_function, Value.undefined_, &.{Value.fromInt32(3)});
    switch (outcome) {
        .value => |value| try testing.expectEqual(@as(i32, 2), value.asInt32()),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(live_before_grow + 3 * @sizeOf(u128), realm.heap.bytes_live);
    try testing.expectEqual(@as(usize, 5), record.instance.tables[0].elems.len);
    if (jit_enabled and comptime @import("../wasm/spasm.zig").supported)
        try testing.expect(record.instance.spasm_runs > runs_before_grow);
    if (!jit_enabled) try testing.expectEqual(@as(u32, 0), record.instance.spasm_runs);
}

test "WebAssembly-side table.grow uses the Realm store allocator in the interpreter" {
    try testRealmBackedTableGrow(false);
}

test "WebAssembly-side table.grow uses the Realm store allocator with JIT enabled" {
    try testRealmBackedTableGrow(true);
}

test "WebAssembly.Instance rolls back a trapping start transaction" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");
    const spasm = @import("../wasm/spasm.zig");

    // Outer: import host.spawn, call it from start, then trap on i32.div_s.
    // The large memory makes retained store backing unambiguous; its
    // externref table/global exercise transactional root rollback.
    const outer_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x0e,
        0x01, 0x04, 'h',  'o',  's',  't',  0x05, 's',
        'p',  'a',  'w',  'n',  0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x04, 0x04, 0x01, 0x6f, 0x00, 0x02,
        0x05, 0x03, 0x01, 0x00, 0x10, 0x06, 0x06, 0x01,
        0x6f, 0x00, 0xd0, 0x6f, 0x0b, 0x08, 0x01, 0x01,
        0x0a, 0x0c, 0x01, 0x0a, 0x00, 0x10, 0x00, 0x41,
        0x01, 0x41, 0x00, 0x6d, 0x1a, 0x0b,
    };
    // Nested: one unique externref table and global, no functions. The host
    // callback instantiates this synchronously while the outer start runs.
    const nested_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x04, 0x01, 0x6f, 0x00, 0x01, 0x06, 0x06,
        0x01, 0x6f, 0x00, 0xd0, 0x6f, 0x0b,
    };

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    try realm.installBuiltins();

    const scope = try realm.heap.openScope();
    defer scope.close();
    const nested_module = try makeModuleObject(&realm, &nested_bytes);
    try scope.push(nested_module);
    try realm.globals.put(realm.allocator, "nestedModuleForStart", nested_module);
    const imports_result = try lantern.evaluateScript(
        testing.allocator,
        &realm,
        "({host:{spawn:function(){new WebAssembly.Instance(nestedModuleForStart);}}})",
    );
    const imports_value = switch (imports_result) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try scope.push(imports_value);

    const outer_module = try makeModuleObject(&realm, &outer_bytes);
    try scope.push(outer_module);
    const outer_object = heap_mod.valueAsPlainObject(outer_module) orelse return error.TestUnexpectedResult;
    const outer_state: *ModuleState = @ptrCast(@alignCast(outer_object.getWasmModule() orelse return error.TestUnexpectedResult));

    var expected_instances = realm.wasm_instances.items.len;
    var expected_table_roots = realm.wasm_extern_tables.items.len;
    var expected_global_roots = realm.wasm_extern_global_cells.items.len;
    const code_live_baseline = realm.wasm_code_bytes_live;
    var expected_reservations = realm.wasm_code_reservations_total;
    var live_before_attempt = realm.heap.bytes_live;
    for (0..3) |_| {
        try testing.expectError(
            error.NativeThrew,
            makeInstanceObject(&realm, outer_state, imports_value),
        );
        realm.pending_exception = null;
        realm.collectGarbage();

        expected_instances += 1;
        expected_table_roots += 1;
        expected_global_roots += 1;
        try testing.expectEqual(expected_instances, realm.wasm_instances.items.len);
        try testing.expectEqual(expected_table_roots, realm.wasm_extern_tables.items.len);
        try testing.expectEqual(expected_global_roots, realm.wasm_extern_global_cells.items.len);
        // The nested instance remains registered; the exact outer code
        // reservation and every outer root/backing return to baseline.
        try testing.expectEqual(code_live_baseline, realm.wasm_code_bytes_live);
        if (comptime spasm.supported) {
            expected_reservations += 1;
            try testing.expectEqual(expected_reservations, realm.wasm_code_reservations_total);
        }
        const retained = realm.heap.bytes_live -| live_before_attempt;
        try testing.expect(retained < 16 * wasm.PAGE_SIZE);
        live_before_attempt = realm.heap.bytes_live;
    }
}

test "WebAssembly JS API: a fuel-metered loop remains in Spasm" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");
    const spasm = @import("../wasm/spasm.zig");
    if (comptime !spasm.supported) return error.SkipZigTest;

    // `(func (export "spin") (loop br 0))` -- the backedge must enter
    // Spasm's execution poll and propagate Realm fuel termination.
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x73, 0x70,
        0x69, 0x6e, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07,
        0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b,
    };

    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "const meteredInstance=new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([");
    for (mod_bytes, 0..) |b, idx| {
        if (idx != 0) try src.append(testing.allocator, ',');
        var tmp: [3]u8 = undefined;
        try src.appendSlice(testing.allocator, std.fmt.bufPrint(&tmp, "{d}", .{b}) catch unreachable);
    }
    try src.appendSlice(testing.allocator, "])));meteredInstance.exports.spin;");

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    try realm.installBuiltins();

    const fn_result = try lantern.evaluateScript(testing.allocator, &realm, src.items);
    const fn_val = switch (fn_result) {
        .value => |v| v,
        else => return error.TestUnexpectedResult,
    };
    const fn_obj = heap_mod.valueAsFunction(fn_val) orelse return error.TestUnexpectedResult;
    const rec: *ExportRecord = @ptrCast(@alignCast(fn_obj.wasm_export orelse return error.TestUnexpectedResult));
    const runs_before = rec.instance.spasm_runs;

    realm.setFuel(4);
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, "meteredInstance.exports.spin()");
    switch (outcome) {
        .thrown => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), realm.terminationReason());
    try testing.expect(rec.instance.spasm_runs > runs_before);
}

test "WebAssembly JS API: Realm.requestInterrupt wakes Spasm after native entry" {
    const testing = std.testing;
    const lantern = @import("../lantern/interpreter.zig");
    const spasm = @import("../wasm/spasm.zig");
    if (comptime !spasm.supported) return error.SkipZigTest;

    // import host.barrier : () -> (); export run : () -> i32. The imported
    // host function parks after Spasm's entry poll; the two-trip loop then
    // guarantees a taken native backedge.
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7f, 0x02, 0x10, 0x01, 0x04, 'h',  'o',
        's',  't',  0x07, 'b',  'a',  'r',  'r',  'i',
        'e',  'r',  0x00, 0x00, 0x03, 0x02, 0x01, 0x01,
        0x07, 0x07, 0x01, 0x03, 'r',  'u',  'n',  0x00,
        0x01, 0x0a, 0x1a, 0x01, 0x18, 0x01, 0x01, 0x7f,
        0x10, 0x00, 0x41, 0x02, 0x21, 0x00, 0x03, 0x40,
        0x20, 0x00, 0x41, 0x01, 0x6b, 0x22, 0x00, 0x0d,
        0x00, 0x0b, 0x20, 0x00, 0x0b,
    };

    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator,
        \\const interruptImports={host:{barrier:function(){}}};
        \\const interruptInstance=new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
    );
    for (mod_bytes, 0..) |byte, index| {
        if (index != 0) try src.append(testing.allocator, ',');
        var tmp: [3]u8 = undefined;
        try src.appendSlice(testing.allocator, std.fmt.bufPrint(&tmp, "{d}", .{byte}) catch unreachable);
    }
    try src.appendSlice(testing.allocator,
        \\])),interruptImports);
        \\interruptInstance.exports.run;
    );

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    try realm.installBuiltins();

    const evaluated = try lantern.evaluateScript(testing.allocator, &realm, src.items);
    const function_value = switch (evaluated) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scope = try realm.heap.openScope();
    defer scope.close();
    try scope.push(function_value);
    const function = heap_mod.valueAsFunction(function_value) orelse return error.TestUnexpectedResult;
    const record: *ExportRecord = @ptrCast(@alignCast(function.wasm_export orelse return error.TestUnexpectedResult));

    // Import resolution and populateInstance ran through the public JS API.
    // Replace its placeholder JS callback with a direct host barrier only for
    // deterministic cross-thread synchronization: no Lantern safe point can
    // consume the request between barrier release and the Spasm backedge.
    var barrier: RealmInterruptBarrier = .{};
    const imported_funcs: []wasm.FuncRef = @constCast(record.instance.imported_funcs);
    imported_funcs[0] = .{ .host = .{
        .fn_ptr = RealmInterruptBarrier.invoke,
        .ctx = &barrier,
        .params = 0,
        .results = 0,
    } };

    // Warm the exact JS-created instance while the barrier is disabled, so
    // the worker enters already-published Spasm code with an unarmed Realm.
    const warm = try call.callJSFunction(realm.allocator, &realm, function, Value.undefined_, &.{});
    switch (warm) {
        .value => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(record.instance.spasm_runs >= 1);
    const runs_before_worker = record.instance.spasm_runs;

    barrier.enabled.store(true, .release);
    var worker: RealmInterruptWorker = .{ .realm = &realm, .function = function };
    const thread = try std.Thread.spawn(.{}, RealmInterruptWorker.run, .{&worker});
    while (!barrier.entered.load(.acquire) and worker.status.load(.acquire) == 0) std.atomic.spinLoopHint();
    if (!barrier.entered.load(.acquire)) {
        thread.join();
        return error.TestUnexpectedResult;
    }
    realm.requestInterrupt();
    barrier.released.store(true, .release);
    thread.join();

    try testing.expectEqual(@as(u8, 1), worker.status.load(.acquire));
    try testing.expect(record.instance.spasm_runs > runs_before_worker);
    try testing.expect(!realm.executionWakeFlag().load(.acquire));
    try testing.expectEqual(@as(?Realm.TerminationReason, null), realm.terminationReason());
}

test "WebAssembly.instantiate does not turn start-function termination into a rejection" {
    const testing = std.testing;

    // (module (func (loop br 0)) (start 0))
    const mod_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x09, 0x01,
        0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b,
    };

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    try realm.installBuiltins();

    const module = try makeModuleObject(&realm, &mod_bytes);
    realm.setFuel(1);
    try testing.expectError(
        error.NativeThrew,
        wasmInstantiate(&realm, Value.undefined_, &.{module}),
    );
    try testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), realm.terminationReason());
}

test "WebAssembly.Module.customSections charges ArrayBuffer payloads to the Realm ceiling" {
    const testing = std.testing;
    const payload_len = 64 * 1024;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &.{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x82, 0x80, 0x04, // custom section, 65,538-byte body
        0x01, 'x', // one-byte name; the rest is payload
    });
    const payload_start = bytes.items.len;
    try bytes.resize(testing.allocator, payload_start + payload_len);
    @memset(bytes.items[payload_start..], 0x5a);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    try realm.installBuiltins();

    const module = try makeModuleObject(&realm, bytes.items);
    const name = Value.fromString(try realm.heap.allocateString("x"));
    const scope = try realm.heap.openScope();
    defer scope.close();
    try scope.push(module);
    try scope.push(name);

    realm.setMemoryLimit(realm.heap.bytes_live + payload_len / 2);
    try testing.expectError(
        error.OutOfMemory,
        wasmModuleCustomSections(&realm, Value.undefined_, &.{ module, name }),
    );
}
