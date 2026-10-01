//! Queued BufferSource instantiation owns its inputs/capability and preserves
//! the host's termination and allocation-failure contracts while draining.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const lantern = @import("lantern/interpreter.zig");

fn install(realm: *Realm) !void {
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
}

fn evaluate(realm: *Realm, source: []const u8) !Value {
    return switch (try lantern.evaluateScript(std.testing.allocator, realm, source)) {
        .value => |value| value,
        else => error.UnexpectedJavaScriptCompletion,
    };
}

fn expectTrue(realm: *Realm, source: []const u8) !void {
    const value = try evaluate(realm, source);
    try std.testing.expect(value.isBool() and value.asBool());
}

fn expectPending(realm: *Realm, name: []const u8) !void {
    const value = realm.globals.get(name) orelse return error.MissingPromise;
    const promise = heap.valueAsPlainObject(value) orelse return error.ExpectedPromise;
    try std.testing.expectEqual(.pending, promise.brand.promise_state);
}

const collecting_start_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,7,1,1,109,1,102,0,0,3,2,1,0,7,5,1,1,102,0,1,8,1,1,10,6,1,4,0,16,0,11])";

fn collectingSetup(comptime module_overload: bool) []const u8 {
    const input = if (module_overload)
        "new WebAssembly.Module(" ++ collecting_start_bytes ++ ")"
    else
        collecting_start_bytes;
    return
    \\globalThis.events = 0;
    \\globalThis.Promise = function(executor) {
    \\  executor(value => {
    \\    __collectGarbage();
    \\    globalThis.outcome = value;
    \\    globalThis.events++;
    \\  }, reason => { __collectGarbage(); throw reason; });
    \\  return {marker: 42};
    \\};
    \\WebAssembly.instantiate(
    ++ input ++
        \\, (() => {
        \\  const payload = {answer: 42};
        \\  return {get m() {
        \\    __collectGarbage();
        \\    return {f() { __collectGarbage(); globalThis.events += payload.answer; }};
        \\  }};
        \\})());
    ;
}

test "WPT async instantiate: pending job retains inputs and independent capability through GC" {
    inline for ([_]bool{ false, true }) |module_overload| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm);
        realm.heap.setGcThreshold(1);
        // The returned capability object is deliberately not put in a HandleScope.
        // The queued job must retain it, the imported closure, and both settlement
        // functions after all setup frames have gone away. For the Module overload,
        // its getter has already returned a fresh namespace before this collection.
        const capability_value = try evaluate(&realm, collectingSetup(module_overload));
        try expectTrue(&realm, "globalThis.events === 0;");
        realm.collectGarbage();
        const capability = heap.valueAsPlainObject(capability_value) orelse return error.ExpectedCapabilityObject;
        try std.testing.expectEqual(@as(i32, 42), capability.get("marker").asInt32());
        try lantern.drainMicrotasks(std.testing.allocator, &realm);
        try std.testing.expectEqual(@as(i32, 42), capability.get("marker").asInt32());
        try expectTrue(&realm, if (module_overload)
            "globalThis.events === 43 && outcome instanceof WebAssembly.Instance;"
        else
            \\globalThis.events === 43 && outcome.module instanceof WebAssembly.Module &&
            \\  outcome.instance instanceof WebAssembly.Instance;
        );
    }
}

test "WPT async instantiate: teardown releases an undrained job without executing callbacks" {
    inline for ([_]bool{ false, true }) |module_overload| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm);
        _ = try evaluate(&realm, collectingSetup(module_overload));
        try expectTrue(&realm, "globalThis.events === 0;");
        realm.collectGarbage();
        // std.testing.allocator checks queue storage and every retained allocation
        // after teardown; no drain is needed to release the queued payload.
    }
}

test "WPT async instantiate: deferred start termination stops drain without rejection" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    // The finite setup budget also bounds the old synchronous implementation:
    // its infinite start function must fail the RED test instead of hanging.
    realm.setFuel(1000);
    try expectTrue(&realm,
        \\globalThis.settlements = 0;
        \\globalThis.laterCalls = 0;
        \\const looping = new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,8,1,0,10,9,1,7,0,3,64,12,0,11,11]);
        \\globalThis.pendingStart = WebAssembly.instantiate(looping);
        \\pendingStart.then(() => { settlements++; }, () => { settlements++; });
        \\WebAssembly.instantiate(
    ++ collecting_start_bytes ++
        \\, {m: {f() { laterCalls++; }}});
        \\true;
    );
    try expectPending(&realm, "pendingStart");
    realm.setFuel(32);
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    try std.testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), realm.terminationReason());
    try expectPending(&realm, "pendingStart");
    try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
    try std.testing.expect(realm.heap.wasm_root_owner == null);
    realm.clearTermination();
    realm.setFuel(std.math.maxInt(u64));
    try expectTrue(&realm, "settlements === 0 && laterCalls === 0;");
    // The interrupted job is not replayed; the host may resume remaining jobs.
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    try expectTrue(&realm, "settlements === 0 && laterCalls === 1;");
    try expectPending(&realm, "pendingStart");
}

test "WPT async instantiate: allocation failure in a queued job preserves OutOfMemory" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    try expectTrue(&realm,
        \\globalThis.pendingAllocation = WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]));
        \\true;
    );
    try expectPending(&realm, "pendingAllocation");
    // Fail a deferred allocation, after queue setup has succeeded.
    // This tests OOM transport with a small real allocation, not memory growth.
    const previous_limit = realm.heap.max_bytes;
    realm.setMemoryLimit(realm.heap.bytes_live);
    defer realm.heap.max_bytes = previous_limit;
    try std.testing.expectError(error.OutOfMemory, lantern.drainMicrotasks(std.testing.allocator, &realm));
    try expectPending(&realm, "pendingAllocation");
    try std.testing.expectEqual(@as(?Realm.TerminationReason, null), realm.terminationReason());
    try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
    try std.testing.expect(realm.heap.wasm_root_owner == null);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_extern_roots.count());
}

test "WPT async instantiate: core allocation failure preserves OutOfMemory and rolls back registrations" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    try expectTrue(&realm,
        \\const memoryModule = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,5,3,1,0,1]));
        \\globalThis.pendingCoreAllocation = WebAssembly.instantiate(memoryModule);
        \\true;
    );
    try expectPending(&realm, "pendingCoreAllocation");
    const instances_before = realm.wasm_instances.items.len;
    const globals_before = realm.wasm_extern_global_cells.items.len;
    const tables_before = realm.wasm_extern_tables.items.len;
    const wrappers_before = realm.wasm_function_wrappers.count();
    // Leave arena capacity for Instance/validation bookkeeping so the failure
    // occurs inside core instantiation, at its separately charged 64KiB memory.
    const arena = realm.wasmAllocator();
    const reserve = try arena.alloc(u8, 32 * 1024);
    arena.free(reserve);
    const previous_limit = realm.heap.max_bytes;
    realm.setMemoryLimit(realm.heap.bytes_live + 8 * 1024);
    defer realm.heap.max_bytes = previous_limit;
    try std.testing.expectError(error.OutOfMemory, lantern.drainMicrotasks(std.testing.allocator, &realm));
    try expectPending(&realm, "pendingCoreAllocation");
    try std.testing.expectEqual(instances_before, realm.wasm_instances.items.len);
    try std.testing.expectEqual(globals_before, realm.wasm_extern_global_cells.items.len);
    try std.testing.expectEqual(tables_before, realm.wasm_extern_tables.items.len);
    try std.testing.expectEqual(wrappers_before, realm.wasm_function_wrappers.count());
    try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
    try std.testing.expect(realm.heap.wasm_root_owner == null);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_extern_roots.count());
}
