//! Wasm JS API host-result references must outlive their JS callback scope.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");
const NativeError = @import("function.zig").NativeError;
const lantern = @import("lantern/interpreter.zig");

fn wasmRootsPresent(realm: *Realm, _: Value, _: []const Value) NativeError!Value {
    // Refuse the deliberate collecting callback before it can read a dangling
    // value on an unfixed engine. The observable value check still follows GC.
    for (realm.heap.realms.items) |sharing| {
        if (sharing.wasm_call_depth > 0 and sharing.wasm_extern_roots.count() > 0)
            return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn install(realm: *Realm, jit: bool) !void {
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = jit;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    const probe = try realm.heap.allocateFunctionNative(realm, wasmRootsPresent, 0, "wasmRootsPresent");
    try realm.globals.put(realm.allocator, "wasmRootsPresent", heap_mod.taggedFunction(probe));
}

fn evaluate(realm: *Realm, source: []const u8) !Value {
    return switch (try lantern.evaluateScript(std.testing.allocator, realm, source)) {
        .value => |value| value,
        else => error.UnexpectedWasmCompletion,
    };
}

fn expectTrue(realm: *Realm, source: []const u8) !void {
    const value = try evaluate(realm, source);
    try std.testing.expect(value.isBool() and value.asBool());
}

fn expectNoTransientRoots(realm: *Realm) !void {
    try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_extern_roots.count());
}

// Imports f:()->(externref,i32), g:()->(), c:(externref)->(). The
// defined run function retains f's reference in a local across g's collection,
// then passes it to c. Keeping the value on a Wasm local excludes JS roots.
const consumer_module =
    \\function consumerModule(start) {
    \\  const prefix = [0,97,115,109,1,0,0,0,
    \\    1,13,3,96,0,2,111,127,96,0,0,96,1,111,0,
    \\    2,19,3,1,109,1,102,0,0,1,109,1,103,0,1,1,109,1,99,0,2,
    \\    3,2,1,1,7,7,1,3,114,117,110,0,3];
    \\  if (start) prefix.push(8,1,3);
    \\  return new WebAssembly.Module(new Uint8Array(prefix.concat([
    \\    10,17,1,15,1,1,111,16,0,26,33,0,16,1,32,0,16,2,11])));
    \\}
;

test "WPT multivalue imports: start imports retain fresh externrefs through later GC and release pins" {
    for ([_]bool{ false, true }) |jit| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm, jit);
        try expectTrue(&realm, consumer_module ++
            \\let checked = 0, fail = false;
            \\const sentinel = {};
            \\const imports = {m: {
            \\  f() { return [{answer: 42}, 7]; },
            \\  g() { if (!wasmRootsPresent()) throw 'missing active Wasm roots'; __collectGarbage(); },
            \\  c(value) { if (value.answer !== 42) throw 'lost externref'; checked++; if (fail) throw sentinel; }
            \\}};
            \\const instance = new WebAssembly.Instance(consumerModule(true), imports);
            \\checked === 1
        );
        try expectNoTransientRoots(&realm);
        try expectTrue(&realm,
            \\fail = true;
            \\let same = false;
            \\try { new WebAssembly.Instance(consumerModule(true), imports); }
            \\catch (error) { same = error === sentinel; }
            \\same && checked === 2
        );
        try expectNoTransientRoots(&realm);
    }
}

// Provider imports f:()->(externref,i32), g:()->(); exports wrappers pair
// and collect plus a no-op. The collect callback re-enters the provider's
// exported noop while the consumer still holds an externref in a Wasm local.
const provider_module =
    \\const providerModule = new WebAssembly.Module(new Uint8Array([
    \\  0,97,115,109,1,0,0,0,1,9,2,96,0,2,111,127,96,0,0,
    \\  2,13,2,1,109,1,102,0,0,1,109,1,103,0,1,
    \\  3,4,3,0,1,1,
    \\  7,25,3,4,112,97,105,114,0,2,7,99,111,108,108,101,99,116,0,3,4,110,111,111,112,0,4,
    \\  10,14,3,4,0,16,0,11,4,0,16,1,11,2,0,11]));
    \\const provider = new WebAssembly.Instance(providerModule, {m: {
    \\  f() { return [{answer: 42}, 7]; },
    \\  g() {
    \\    provider.exports.noop();
    \\    if (!wasmRootsPresent()) throw 'missing active cross-realm Wasm roots';
    \\    __collectGarbage();
    \\  }
    \\}});
;

test "WPT multivalue imports: child caller retains provider results across reentry and releases pins" {
    for ([_]bool{ false, true }) |jit| {
        var parent = Realm.init(std.testing.allocator);
        defer parent.deinit();
        try install(&parent, jit);
        _ = try evaluate(&parent, provider_module);

        var child = Realm.initChild(&parent);
        defer child.deinit();
        try install(&child, jit);
        const scope = try parent.heap.openScope();
        defer scope.close();
        const pair = try evaluate(&parent, "provider.exports.pair");
        try scope.push(pair);
        const collect = try evaluate(&parent, "provider.exports.collect");
        try scope.push(collect);
        try child.globals.put(child.allocator, "providerPair", pair);
        try child.globals.put(child.allocator, "providerCollect", collect);

        try expectTrue(&child, consumer_module ++
            \\let checked = 0, fail = false;
            \\const sentinel = {};
            \\const instance = new WebAssembly.Instance(consumerModule(false), {m: {
            \\  f: providerPair, g: providerCollect,
            \\  c(value) { if (value.answer !== 42) throw 'lost cross-realm externref'; checked++; if (fail) throw sentinel; }
            \\}});
            \\instance.exports.run();
            \\checked === 1
        );
        try expectNoTransientRoots(&parent);
        try expectNoTransientRoots(&child);
        try expectTrue(&child,
            \\fail = true;
            \\let same = false;
            \\try { instance.exports.run(); } catch (error) { same = error === sentinel; }
            \\same && checked === 2
        );
        try expectNoTransientRoots(&parent);
        try expectNoTransientRoots(&child);
    }
}

fn boundedFuelNext(realm: *Realm, _: Value, _: []const Value) NativeError!Value {
    const previous = realm.globals.get("fuelSteps") orelse return error.NativeThrew;
    if (!previous.isInt32()) return error.NativeThrew;
    const steps = previous.asInt32();
    if (steps >= 1000) {
        // A broken poll must fail quickly, without spending the full native
        // iteration allowance or relying on a watchdog to end the test.
        realm.pending_exception = realm.globals.get("backstopSentinel") orelse Value.undefined_;
        return error.NativeThrew;
    }
    try realm.globals.put(realm.allocator, "fuelSteps", Value.fromInt32(steps + 1));
    return realm.globals.get("fuelStep") orelse error.NativeThrew;
}

// Both provider and consumer forward a ()->(i32,i32) imported function.
const fuel_module =
    \\const fuelModule = new WebAssembly.Module(new Uint8Array([
    \\  0,97,115,109,1,0,0,0,1,6,1,96,0,2,127,127,
    \\  2,7,1,1,109,1,102,0,0,3,2,1,0,
    \\  7,7,1,3,114,117,110,0,1,10,6,1,4,0,16,0,11]));
;

test "WPT multivalue imports: native iteration spends cross-realm caller fuel and preserves termination" {
    for ([_]bool{ false, true }) |jit| {
        var parent = Realm.init(std.testing.allocator);
        defer parent.deinit();
        try install(&parent, jit);
        const next = try parent.heap.allocateFunctionNative(&parent, boundedFuelNext, 0, "boundedFuelNext");
        try parent.globals.put(parent.allocator, "fuelNext", heap_mod.taggedFunction(next));
        try parent.globals.put(parent.allocator, "fuelSteps", Value.fromInt32(0));
        _ = try evaluate(&parent, fuel_module ++
            \\globalThis.fuelStep = {done: false, value: 1};
            \\globalThis.backstopSentinel = {};
            \\const fuelProvider = new WebAssembly.Instance(fuelModule, {m: {
            \\  f() { return {[Symbol.iterator]() { return {next: fuelNext}; }}; }
            \\}}).exports.run;
        );

        var child = Realm.initChild(&parent);
        defer child.deinit();
        try install(&child, jit);
        const scope = try parent.heap.openScope();
        defer scope.close();
        const provider = try evaluate(&parent, "fuelProvider");
        try scope.push(provider);
        try child.globals.put(child.allocator, "fuelProvider", provider);
        try expectTrue(&child, fuel_module ++
            \\const fuelRun = new WebAssembly.Instance(fuelModule, {m: {f: fuelProvider}}).exports.run;
            \\let caught = false;
            \\true;
        );
        // Setup and compilation are complete. Only the consumer is metered;
        // the JS callback and native next method execute through the provider.
        child.setFuel(64);
        const outcome = try lantern.evaluateScript(std.testing.allocator, &child,
            \\try { fuelRun(); } catch (error) { caught = true; }
        );
        switch (outcome) {
            .thrown => {},
            else => return error.ExpectedCrossRealmFuelTermination,
        }
        try std.testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), child.terminationReason());
        try std.testing.expectEqual(@as(?Realm.TerminationReason, null), parent.terminationReason());
        try std.testing.expectEqual(std.math.maxInt(u64), parent.step_budget);
        const steps = parent.globals.get("fuelSteps") orelse return error.MissingFuelSteps;
        try std.testing.expect(steps.isInt32());
        try std.testing.expect(steps.asInt32() > 0 and steps.asInt32() < 1000);
        try expectNoTransientRoots(&parent);
        try expectNoTransientRoots(&child);
        try std.testing.expect(parent.heap.wasm_root_owner == null);
        child.clearTermination();
        child.setFuel(std.math.maxInt(u64));
        try expectTrue(&child, "caught === false;");

        // The cooperative posture must surface the consumer's RangeError,
        // not the provider's sentinel or a stale pending-exception value.
        // Invoke the export directly so checking its result needs no JS
        // safe point while the cooperative budget is still exhausted.
        const run_value = try evaluate(&child, "fuelRun");
        try scope.push(run_value);
        const run_function = heap_mod.valueAsFunction(run_value) orelse return error.ExpectedWasmExport;
        try parent.globals.put(parent.allocator, "fuelSteps", Value.fromInt32(0));
        child.fuel_exhaustion = .throw_range_error;
        child.step_budget = 64;
        const cooperative = try lantern.callJSFunction(std.testing.allocator, &child, run_function, Value.undefined_, &.{});
        const exception = switch (cooperative) {
            .thrown => |value| value,
            else => return error.ExpectedCrossRealmBudgetException,
        };
        try scope.push(exception);
        try std.testing.expectEqual(@as(?Realm.TerminationReason, null), child.terminationReason());
        try std.testing.expectEqual(@as(?Realm.TerminationReason, null), parent.terminationReason());
        try std.testing.expectEqual(@as(u64, 0), child.step_budget);
        try std.testing.expectEqual(std.math.maxInt(u64), parent.step_budget);
        const cooperative_steps = parent.globals.get("fuelSteps") orelse return error.MissingFuelSteps;
        try std.testing.expect(cooperative_steps.isInt32());
        try std.testing.expect(cooperative_steps.asInt32() > 0 and cooperative_steps.asInt32() < 1000);
        try expectNoTransientRoots(&parent);
        try expectNoTransientRoots(&child);
        try std.testing.expect(parent.heap.wasm_root_owner == null);
        child.step_budget = std.math.maxInt(u64);
        try child.globals.put(child.allocator, "cooperativeError", exception);
        try expectTrue(&child, "cooperativeError instanceof RangeError && cooperativeError.message === 'interpreter step budget exhausted';");
    }
}
