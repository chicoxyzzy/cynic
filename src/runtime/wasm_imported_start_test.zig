//! A start index names the whole function space, including host imports.
const std = @import("std");
const wasm = @import("wasm/wasm.zig");
const Realm = @import("realm.zig").Realm;
const heap = @import("heap.zig");
const lantern = @import("lantern/interpreter.zig");

// (module (import "m" "f" (func)) (start 0))
const start_bytes = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 2, 7, 1, 1, 109, 1, 102, 0, 0, 8, 1, 0 };
const js_setup =
    \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,7,1,1,109,1,102,0,0,8,1,0]);
    \\const module = new WebAssembly.Module(bytes);
;

const Host = struct {
    calls: usize = 0,
    trap: ?wasm.TrapError = null,

    fn call(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        if (args.len != 0 or results.len != 0) return error.UnsupportedImportCall;
        self.calls += 1;
        if (self.trap) |trap| return trap;
    }

    fn reference(self: *Host) wasm.FuncRef {
        return .{ .host = .{ .fn_ptr = call, .ctx = self, .params = 0, .results = 0 } };
    }
};

const Control = struct {
    result: wasm.ExecutionPoll = .proceed,
    polls: usize = 0,

    fn poll(ctx: *anyopaque) wasm.ExecutionPoll {
        const self: *Control = @ptrCast(@alignCast(ctx));
        self.polls += 1;
        return self.result;
    }

    fn armed(_: *anyopaque) bool {
        return true;
    }

    fn control(self: *Control) wasm.ExecutionControl {
        return .{ .ctx = self, .poll_fn = poll, .armed_fn = armed };
    }
};

test "Wasm imported start: native host entry honors execution control and traps" {
    for ([_]bool{ false, true }) |spasm| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const module = try wasm.decode(arena.allocator(), &start_bytes);
        var host: Host = .{};
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), std.testing.allocator, &module, .{ .funcs = &.{host.reference()} });
        defer instance.deinit();
        instance.spasm_enabled = spasm;
        var control: Control = .{};
        instance.execution_control = control.control();
        try wasm.interpreter.runStart(&instance, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), host.calls);
        try std.testing.expectEqual(@as(usize, 1), control.polls);
        inline for (.{ .step_budget_exhausted, .cooperative_interrupted, .terminated }, .{ error.StepBudgetExhausted, error.ExecutionInterrupted, error.ExecutionTerminated }) |result, err| {
            control.result = result;
            try std.testing.expectError(err, wasm.interpreter.runStart(&instance, std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 1), host.calls);
        }
        control.result = .proceed;
        inline for (.{ error.HostThrew, error.OutOfMemory, error.ExecutionTerminated }) |err| {
            host.trap = err;
            try std.testing.expectError(err, wasm.interpreter.runStart(&instance, std.testing.allocator));
        }
        try std.testing.expectEqual(@as(usize, 4), host.calls);
        try std.testing.expectError(error.UnsupportedImportCall, wasm.invoke(&instance, std.testing.allocator, 0, &.{42}));
        try std.testing.expectEqual(@as(usize, 4), host.calls);
    }
}

test "Wasm imported start: direct host invocation returns owned nonoverlapping results" {
    const ReturningHost = struct {
        fn call(_: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            if (args.len != 1 or results.len != 1 or args.ptr == results.ptr) return error.UnsupportedImportCall;
            results[0] = args[0] + 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // (module (import "m" "f" (func (param i32) (result i32))))
    const bytes = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 2, 7, 1, 1, 109, 1, 102, 0, 0 };
    const module = try wasm.decode(arena.allocator(), &bytes);
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), std.testing.allocator, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = ReturningHost.call, .params = 1, .results = 1 } }} });
    defer instance.deinit();
    const results = try wasm.invoke(&instance, std.testing.allocator, 0, &.{41});
    defer std.testing.allocator.free(results);
    try std.testing.expectEqualSlices(u128, &.{42}, results);
}

fn install(realm: *Realm, hardened: bool) !void {
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
}

fn expectTrue(realm: *Realm, source: []const u8) !void {
    switch (try lantern.evaluateScript(std.testing.allocator, realm, source)) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        else => return error.UnexpectedJavaScriptCompletion,
    }
}

test "Wasm imported start: sync and async entry preserve call shape GC and reentry" {
    for ([_]bool{ false, true }) |hardened| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm, hardened);
        try expectTrue(&realm, js_setup ++
            \\let calls = 0, gets = 0, done = 0, failed = false;
            \\const imports = {get m() {
            \\  gets++;
            \\  const captured = {answer: 42};
            \\  return {f: function(...args) {
            \\    if (this !== undefined || args.length !== 0) failed = true;
            \\    __collectGarbage();
            \\    new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0])));
            \\    if (captured.answer !== 42) failed = true;
            \\    calls++;
            \\    return {get then() { throw new Error('start return value was inspected'); }};
            \\  }};
            \\}};
            \\const instance = new WebAssembly.Instance(module, imports);
            \\WebAssembly.instantiate(module, imports).then(value => {
            \\  if (!(value instanceof WebAssembly.Instance)) failed = true;
            \\  done++;
            \\}, () => { failed = true; });
            \\WebAssembly.instantiate(bytes, imports).then(value => {
            \\  if (!(value.instance instanceof WebAssembly.Instance)) failed = true;
            \\  done++;
            \\}, () => { failed = true; });
            \\instance instanceof WebAssembly.Instance && calls === 1 && gets === 2 && done === 0 && !failed;
        );
        realm.collectGarbage();
        try lantern.drainMicrotasks(std.testing.allocator, &realm);
        try expectTrue(&realm, "calls === 3 && gets === 3 && done === 2 && !failed;");
        try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
        try std.testing.expect(realm.heap.wasm_root_owner == null);
    }
}

test "Wasm imported start: original JS and Wasm exception identity reaches every API" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm, true);
    try expectTrue(&realm, js_setup ++
        \\let caught = 0, failed = false;
        \\const exceptions = [{marker: 42}, undefined, new WebAssembly.Exception(new WebAssembly.Tag({parameters: []}), [])];
        \\for (const reason of exceptions) {
        \\  const imports = {m: {f() { __collectGarbage(); throw reason; }}};
        \\  try { new WebAssembly.Instance(module, imports); failed = true; }
        \\  catch (error) { if (error === reason) caught++; else failed = true; }
        \\  for (const input of [module, bytes]) {
        \\    WebAssembly.instantiate(input, imports).then(() => { failed = true; }, error => {
        \\      __collectGarbage();
        \\      if (error === reason) caught++; else failed = true;
        \\    });
        \\  }
        \\}
        \\caught === 3 && !failed;
    );
    realm.collectGarbage();
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    try expectTrue(&realm, "caught === 9 && !failed;");
}

test "Wasm imported start: terminating host callback stops async drain without settlement" {
    inline for ([_]bool{ false, true }) |module_overload| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm, false);
        try expectTrue(&realm, js_setup ++
            \\globalThis.settled = 0; globalThis.later = 0; globalThis.entered = 0;
            \\globalThis.pending = WebAssembly.instantiate(
        ++ (if (module_overload) "module" else "bytes") ++
            \\, {m: {f() { entered++; while (true) {} }}});
            \\pending.then(() => { settled++; }, () => { settled++; });
            \\WebAssembly.instantiate(
        ++ (if (module_overload) "module" else "bytes") ++
            \\, {m: {f() { later++; }}});
            \\true;
        );
        realm.setFuel(32);
        try lantern.drainMicrotasks(std.testing.allocator, &realm);
        try std.testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), realm.terminationReason());
        const pending = heap.valueAsPlainObject(realm.globals.get("pending").?).?;
        try std.testing.expectEqual(.pending, pending.brand.promise_state);
        try std.testing.expectEqual(@as(u32, 0), realm.wasm_call_depth);
        try std.testing.expect(realm.heap.wasm_root_owner == null);
        realm.clearTermination();
        realm.setFuel(std.math.maxInt(u64));
        try expectTrue(&realm, "settled === 0 && later === 0 && entered === 1;");
        try lantern.drainMicrotasks(std.testing.allocator, &realm);
        try expectTrue(&realm, "settled === 0 && later === 1 && entered === 1;");
    }
}
