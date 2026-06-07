//! The `WebAssembly` JS namespace — the host API surface over Sarcasm
//! (the engine in `src/runtime/wasm/`).
//!
//! This first slice installs the namespace and `WebAssembly.validate`.
//! `validate` performs no code generation (it only decodes + checks),
//! so per the JS-API spec it is *not* gated by
//! HostEnsureCanCompileWasmBytes; the `compile` / `Module` /
//! `instantiate` surface that builds runnable instances lands next,
//! behind `--allow=wasm` (see docs/wasm-engine.md, AGENTS.md).

const std = @import("std");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const NativeError = @import("../function.zig").NativeError;
const intrinsics = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");
const wasm = @import("../wasm/wasm.zig");

pub fn install(realm: *Realm) !void {
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try intrinsics.installToStringTag(realm, ns, "WebAssembly");
    try intrinsics.installNativeMethodOnProto(realm, ns, "validate", wasmValidate, 1);
    try realm.globals.put(realm.allocator, "WebAssembly", heap_mod.taggedObject(ns));
}

/// `WebAssembly.validate(bytes)` (§ JS-API) — true iff `bytes` decodes
/// and validates as a well-formed module.
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

/// Borrow the bytes of a BufferSource argument — an `ArrayBuffer` or
/// any typed-array view over one. Returns null for anything else.
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
