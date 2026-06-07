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
const JSFunction = @import("../function.zig").JSFunction;
const JSString = @import("../string.zig").JSString;
const intrinsics = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");
const arith = @import("../lantern/arith.zig");
const call = @import("../lantern/call.zig");
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

/// A `WebAssembly.Global`'s backing state: a pointer to its live operand
/// cell (an instance's global for an export, or a standalone arena cell),
/// plus its value type and mutability. Arena-owned.
const GlobalState = struct {
    cell: *u128,
    valtype: wasm.ValType,
    mutable: bool,
};

fn valTypeFromString(s: []const u8) ?wasm.ValType {
    if (std.mem.eql(u8, s, "i32")) return .i32;
    if (std.mem.eql(u8, s, "i64")) return .i64;
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    return null;
}

/// A `WebAssembly.Table`'s backing state: the shared engine table plus
/// its element kind. Arena-owned. (Only `funcref` tables are supported
/// today; `externref` tables await GC integration.)
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

    const global_ctor = try intrinsics.installConstructor(realm, .{
        .ctor = globalConstructor,
        .arity = 1,
        .name = "Global",
        .install_global = false,
    });
    try ns.set(realm.allocator, "Global", heap_mod.taggedFunction(global_ctor.ctor));
    realm.wasm_global_prototype = global_ctor.proto;
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

    const imports = try resolveImports(realm, mstate.module, if (args.len > 1) args[1] else Value.undefined_);

    const a = realm.wasmAllocator();
    const ip = a.create(wasm.Instance) catch return error.OutOfMemory;
    wasm.instantiate(ip, a, a, mstate.module, imports) catch
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: instantiation failed (LinkError)");
    wasm.runStart(ip, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HostThrew => return error.NativeThrew, // a host import threw during start
        else => return intrinsics.throwTypeError(realm, "WebAssembly.Instance: start function trapped (RuntimeError)"),
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
    return this_value;
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
    const cell = a.create(u128) catch return error.OutOfMemory;
    // A missing initial value is the type's zero (the 0 bit pattern is
    // i32 0 / i64 0n / f32 +0 / f64 +0).
    cell.* = if (args.len > 1) try marshalArg(realm, vt, args[1]) else 0;

    const st = a.create(GlobalState) catch return error.OutOfMemory;
    st.* = .{ .cell = cell, .valtype = vt, .mutable = mutable };
    self.wasm_global = st;
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
    const raw = obj.wasm_global orelse
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
fn makeGlobal(realm: *Realm, valtype: wasm.ValType, mutable: bool, cell: *u128) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.wasm_global_prototype);
    const a = realm.wasmAllocator();
    const st = a.create(GlobalState) catch return error.OutOfMemory;
    st.* = .{ .cell = cell, .valtype = valtype, .mutable = mutable };
    obj.wasm_global = st;
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
    if (std.mem.eql(u8, elem, "externref"))
        return intrinsics.throwTypeError(realm, "WebAssembly.Table: externref tables are not yet supported");
    if (!std.mem.eql(u8, elem, "anyfunc") and !std.mem.eql(u8, elem, "funcref"))
        return intrinsics.throwTypeError(realm, "WebAssembly.Table: invalid element type");

    const initial = try indexArg(realm, desc.get("initial"));
    const max = try optionalIndexArg(realm, desc.get("maximum"));

    const a = realm.wasmAllocator();
    const elems = a.alloc(u128, initial) catch return error.OutOfMemory;
    const fill = if (args.len > 1) try funcRefFromValue(realm, args[1]) else wasm.REF_NULL;
    @memset(elems, fill);

    const tbl = a.create(wasm.Table) catch return error.OutOfMemory;
    tbl.* = .{ .elems = elems, .max = max, .is_64 = false };
    const st = a.create(TableState) catch return error.OutOfMemory;
    st.* = .{ .table = tbl, .funcref = true };
    self.wasm_table = st;
    return this_value;
}

fn tableStateOf(realm: *Realm, this_value: Value) NativeError!*TableState {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Table");
    const raw = obj.wasm_table orelse
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
    if (cell == wasm.REF_NULL) return Value.null_;
    return makeExportedFunction(realm, wasm.funcRefInstance(cell), wasm.funcRefIndex(cell), "");
}

fn tableSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const st = try tableStateOf(realm, this_value);
    const idx = try tableIndex(realm, st, if (args.len > 0) args[0] else Value.undefined_);
    st.table.elems[idx] = try funcRefFromValue(realm, if (args.len > 1) args[1] else Value.null_);
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
    obj.wasm_table = st;
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
    self.wasm_memory = st;
    return this_value;
}

fn memoryStateOf(realm: *Realm, this_value: Value) NativeError!*MemoryState {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return intrinsics.throwTypeError(realm, "receiver is not a WebAssembly.Memory");
    const raw = obj.wasm_memory orelse
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
    obj.wasm_memory = st;
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
    for (module.imports) |imp| switch (imp.desc) {
        .func => nfunc += 1,
        .global => nglob += 1,
        .table => ntab += 1,
        .mem => {},
    };
    if (module.imports.len == 0) return .{};

    const import_obj = heap_mod.valueAsPlainObject(import_obj_v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: an importObject is required (LinkError)");

    const a = realm.wasmAllocator();
    const funcs = a.alloc(wasm.FuncRef, nfunc) catch return error.OutOfMemory;
    const globals = a.alloc(u128, nglob) catch return error.OutOfMemory;
    const tables = a.alloc(*wasm.Table, ntab) catch return error.OutOfMemory;
    var memory: ?*const wasm.Memory = null;
    var fi: usize = 0;
    var gi: usize = 0;
    var ti: usize = 0;

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
            .mem => memory = try resolveMemImport(realm, v),
        }
    }
    return .{ .funcs = funcs, .globals = globals, .tables = tables, .memory = memory };
}

/// `importObject[module][name]`.
fn lookupImport(realm: *Realm, import_obj: *JSObject, module_name: []const u8, name: []const u8) NativeError!Value {
    const mod_v = import_obj.get(module_name);
    const mod_obj = heap_mod.valueAsPlainObject(mod_v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: import module namespace is not an object (LinkError)");
    return mod_obj.get(name);
}

fn resolveFuncImport(realm: *Realm, v: Value, module: *const wasm.Module, type_idx: u32) NativeError!wasm.FuncRef {
    const fn_obj = heap_mod.valueAsFunction(v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: function import is not callable (LinkError)");
    // A WebAssembly exported function links directly to its wasm body.
    if (fn_obj.wasm_export) |raw| {
        const rec: *ExportRecord = @ptrCast(@alignCast(raw));
        return rec.instance.funcRefAt(rec.func_index) orelse
            return intrinsics.throwTypeError(realm, "WebAssembly.Instance: bad exported-function import (LinkError)");
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

fn resolveGlobalImport(realm: *Realm, v: Value, gt: anytype) NativeError!u128 {
    // A WebAssembly.Global shares its current cell value; a primitive is
    // marshalled to the global's declared type.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.wasm_global) |raw| {
            const st: *GlobalState = @ptrCast(@alignCast(raw));
            return st.cell.*;
        }
    }
    return marshalArg(realm, gt.val, v);
}

fn resolveTableImport(realm: *Realm, v: Value) NativeError!*wasm.Table {
    const obj = heap_mod.valueAsPlainObject(v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: table import is not a WebAssembly.Table (LinkError)");
    const raw = obj.wasm_table orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: table import is not a WebAssembly.Table (LinkError)");
    const st: *TableState = @ptrCast(@alignCast(raw));
    return st.table;
}

fn resolveMemImport(realm: *Realm, v: Value) NativeError!*const wasm.Memory {
    const obj = heap_mod.valueAsPlainObject(v) orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: memory import is not a WebAssembly.Memory (LinkError)");
    const raw = obj.wasm_memory orelse
        return intrinsics.throwTypeError(realm, "WebAssembly.Instance: memory import is not a WebAssembly.Memory (LinkError)");
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
                const cell = ip.globalCellPtr(gidx) orelse continue;
                const gt = ip.globalTypeAt(gidx) orelse continue;
                const gobj = try makeGlobal(realm, gt.val, gt.mut == .mutable, cell);
                obj.set(realm.allocator, ex.name, gobj) catch return error.OutOfMemory;
            },
            .table => |tidx| {
                const tbl = ip.tableRef(tidx) orelse continue;
                if ((ip.tableElemType(tidx) orelse continue) != .funcref) continue; // externref: deferred
                const tobj = try makeTable(realm, tbl, true);
                obj.set(realm.allocator, ex.name, tobj) catch return error.OutOfMemory;
            },
            .mem => {
                const mem = ip.memoryPtr() orelse continue;
                const mobj = try makeMemory(realm, mem);
                obj.set(realm.allocator, ex.name, mobj) catch return error.OutOfMemory;
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
    for (ft.params, 0..) |pt, i| {
        const v = if (i < args.len) args[i] else Value.undefined_;
        argbuf[i] = try marshalArg(realm, pt, v);
    }

    const results = wasm.invoke(rec.instance, realm.allocator, rec.func_index, argbuf[0..ft.params.len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A JS-backed host import threw — re-raise its pending exception.
        error.HostThrew => return error.NativeThrew,
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
        else => return intrinsics.throwTypeError(realm, "WebAssembly: v128 / reference marshalling is not yet supported"),
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
        else => return intrinsics.throwTypeError(realm, "WebAssembly: v128 / reference marshalling is not yet supported"),
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
