//! Preserve allocation failures across JS-backed Wasm imports. A host throw
//! carries a pending JS value; allocation failure must keep its distinct error
//! so the caller retains the standard out-of-memory path.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const NativeError = @import("function.zig").NativeError;
const heap = @import("heap.zig");
const lantern = @import("lantern/interpreter.zig");
const call = @import("lantern/call.zig");
const spasm = @import("wasm/spasm.zig");

fn failAllocation(realm: *Realm, _: Value, _: []const Value) NativeError!Value {
    // Fail a small, real allocation at its charge check. Restore the ceiling
    // before unwinding so the bridge itself can still allocate an exception.
    const previous_limit = realm.heap.max_bytes;
    realm.setMemoryLimit(realm.heap.bytes_live);
    defer realm.heap.max_bytes = previous_limit;
    return Value.fromString(try realm.heap.allocateString("host import allocation"));
}

fn expectImportOutOfMemory(source: []const u8) !void {
    for ([_]bool{ false, true }) |jit_enabled| {
        if (jit_enabled and !spasm.supported) continue;
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        realm.hardened = false;
        realm.allow_wasm_compile = true;
        realm.jit_enabled = jit_enabled;
        realm.ohaimark_enabled = false;
        try realm.installBuiltins();
        const created = try lantern.evaluateScript(std.testing.allocator, &realm, source);
        const export_value = switch (created) {
            .value => |value| value,
            else => return error.UnexpectedWasmCompletion,
        };
        const scope = try realm.heap.openScope();
        defer scope.close();
        try scope.push(export_value);
        const function = heap.valueAsFunction(export_value) orelse return error.MissingWasmExport;
        const callback_value = realm.globals.get("failAllocation") orelse return error.MissingHostCallback;
        const callback = heap.valueAsFunction(callback_value) orelse return error.MissingHostCallback;
        callback.native_callback = failAllocation;

        // Both absent and stale pending exceptions used to lose the OOM:
        // HostThrew synthesized an unrelated TypeError or replayed the stale
        // value. The native caller must instead receive OutOfMemory exactly.
        for ([_]?Value{ null, Value.fromInt32(73) }) |pending| {
            realm.pending_exception = pending;
            try std.testing.expectError(error.OutOfMemory, call.callJSFunction(
                std.testing.allocator,
                &realm,
                function,
                Value.undefined_,
                &.{},
            ));
            try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
            try std.testing.expect(realm.heap.wasm_root_owner == null);
            try std.testing.expectEqual(@as(usize, 0), realm.wasm_extern_roots.count());
        }
        if (jit_enabled) {
            try std.testing.expectEqual(@as(usize, 1), realm.wasm_instances.items.len);
            try std.testing.expect(realm.wasm_instances.items[0].spasm_runs > 0);
        }
    }
}

test "WPT multivalue imports: callback allocation failure keeps OutOfMemory across interpreter and Spasm" {
    try expectImportOutOfMemory(
        \\function failAllocation() {}
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,7,1,1,109,1,102,0,0,3,2,1,0,7,5,1,1,103,0,1,10,6,1,4,0,16,0,11]);
        \\new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {f: failAllocation}}).exports.g;
    );
}

test "WPT multivalue imports: result conversion allocation failure keeps OutOfMemory across interpreter and Spasm" {
    try expectImportOutOfMemory(
        \\function failAllocation() {}
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,0,2,127,127,2,7,1,1,109,1,102,0,0,3,2,1,0,7,5,1,1,103,0,1,10,6,1,4,0,16,0,11]);
        \\new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {f() { return [{valueOf: failAllocation}, 2]; }}}).exports.g;
    );
}
