//! Wasm JS API §5.2 Instance.exports and its GC-traced [[Exports]] slot.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(source: []const u8, hardened: bool, pressure: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    if (pressure) realm.heap.setGcThreshold(1);
    const result = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    switch (result) {
        .value, .yielded => |value| try std.testing.expect(value.isBool() and value.asBool()),
        .thrown => return error.UnexpectedJavaScriptException,
    }
}

const empty_instance =
    "const instance = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0])));";

test "WPT Instance: exports is a branded prototype getter" {
    try expectTrue(empty_instance ++
        \\const d = Object.getOwnPropertyDescriptor(WebAssembly.Instance.prototype, 'exports');
        \\!!d && typeof d.get === 'function' && d.get.name === 'get exports' &&
        \\d.get.length === 0 && d.set === undefined && d.enumerable && d.configurable &&
        \\!Object.hasOwn(instance, 'exports') && d.get.call(instance) === instance.exports &&
        \\instance.exports === instance.exports
    , false, false);
}

test "WPT Instance: exports rejects prototypes descendants and proxies" {
    try expectTrue(empty_instance ++
        \\const d = Object.getOwnPropertyDescriptor(WebAssembly.Instance.prototype, 'exports');
        \\let ok = !!d;
        \\if (ok) {
        \\  for (const value of [undefined, null, 1, {}, WebAssembly.Instance.prototype,
        \\      Object.create(instance), new Proxy(instance, {})]) {
        \\    try { d.get.call(value); ok = false; } catch (e) { ok = ok && e instanceof TypeError; }
        \\  }
        \\}
        \\ok
    , false, false);
}

test "WPT Instance: exports survives collection through its internal slot" {
    try expectTrue(empty_instance ++
        \\__collectGarbage();
        \\for (let i = 0; i < 20; i++) { const temporary = {i}; }
        \\const exports = instance.exports;
        \\__collectGarbage();
        \\exports === instance.exports && Object.getPrototypeOf(exports) === null &&
        \\!Object.hasOwn(instance, 'exports')
    , false, true);
}

test "WPT Instance: exports attached after a collecting start callback remains rooted" {
    try expectTrue(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,
        \\  1,4,1,96,0,0, 2,7,1,1,109,1,102,0,0, 3,2,1,0, 7,5,1,1,102,0,1, 8,1,1, 10,6,1,4,0,16,0,11]);
        \\let calls = 0;
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        \\  m: {f() { __collectGarbage(); calls++; }}
        \\});
        \\for (let i = 0; i < 20; i++) { const temporary = {i}; }
        \\__collectGarbage();
        \\instance.exports.f();
        \\calls === 2 && !Object.hasOwn(instance, 'exports')
    , false, true);
}

test "WPT Instance: hardened realms preserve the exports getter" {
    try expectTrue(empty_instance ++
        \\const d = Object.getOwnPropertyDescriptor(WebAssembly.Instance.prototype, 'exports');
        \\!!d && typeof d.get === 'function' && !d.configurable &&
        \\Object.isFrozen(WebAssembly.Instance.prototype) &&
        \\!Object.hasOwn(instance, 'exports') && d.get.call(instance) === instance.exports
    , true, false);
}

fn expectAsyncTrue(source: []const u8) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
    const setup = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    switch (setup) {
        .value, .yielded => {},
        .thrown => return error.UnexpectedJavaScriptException,
    }
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    const result = try lantern.evaluateScript(std.testing.allocator, &realm, "globalThis.async_ok");
    switch (result) {
        .value, .yielded => |value| try std.testing.expect(value.isBool() and value.asBool()),
        .thrown => return error.UnexpectedJavaScriptException,
    }
}

const collecting_start_module =
    \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,
    \\  1,4,1,96,0,0, 2,7,1,1,109,1,102,0,0, 3,2,1,0,
    \\  7,5,1,1,102,0,1, 8,1,1, 10,6,1,4,0,16,0,11]);
    \\globalThis.async_ok = false;
;

test "WPT Instance: async Module resolution survives a collecting start callback" {
    try expectAsyncTrue(collecting_start_module ++
        \\let calls = 0;
        \\WebAssembly.instantiate(new WebAssembly.Module(bytes), {
        \\  m: {f() { __collectGarbage(); calls++; }}
        \\}).then(instance => {
        \\  __collectGarbage();
        \\  instance.exports.f();
        \\  globalThis.async_ok = instance instanceof WebAssembly.Instance && calls === 2;
        \\});
    );
}

test "WPT Instance: async rejection survives a collecting throwing start callback" {
    try expectAsyncTrue(collecting_start_module ++
        \\const sentinel = {failure: 'start'};
        \\WebAssembly.instantiate(new WebAssembly.Module(bytes), {
        \\  m: {f() { __collectGarbage(); throw sentinel; }}
        \\}).then(() => {}, reason => {
        \\  __collectGarbage();
        \\  globalThis.async_ok = reason === sentinel;
        \\});
    );
}

test "WPT Instance: async BufferSource result retains its module across collecting start" {
    try expectAsyncTrue(collecting_start_module ++
        \\let calls = 0;
        \\const imports = {m: {f() { __collectGarbage(); calls++; }}};
        \\WebAssembly.instantiate(bytes, imports).then(result => {
        \\  __collectGarbage();
        \\  const again = new WebAssembly.Instance(result.module, imports);
        \\  result.instance.exports.f();
        \\  again.exports.f();
        \\  globalThis.async_ok = result.module instanceof WebAssembly.Module &&
        \\    result.instance instanceof WebAssembly.Instance && calls === 4;
        \\});
    );
}
