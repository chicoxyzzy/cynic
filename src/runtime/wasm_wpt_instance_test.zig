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

test "WPT compile: promises fulfill and reject under allocation pressure" {
    try expectAsyncTrue(
        \\globalThis.async_ok = false;
        \\let fulfilled = false, rejected = false;
        \\WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0])).then(module => {
        \\  __collectGarbage();
        \\  fulfilled = new WebAssembly.Instance(module) instanceof WebAssembly.Instance;
        \\  globalThis.async_ok = fulfilled && rejected;
        \\});
        \\WebAssembly.compile(new Uint8Array([0])).then(() => {}, reason => {
        \\  __collectGarbage();
        \\  rejected = reason instanceof WebAssembly.CompileError;
        \\  globalThis.async_ok = fulfilled && rejected;
        \\});
    );
}

// Two () -> i32 definitions return 7 and 42. Exports a/b alias index 1;
// `other` names index 0. A second module imports that signature at index 0
// and exports it twice, letting tests distinguish store identity from index.
const identity_modules =
    \\const sourceModule = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,3,2,0,0,7,17,3,1,97,0,1,1,98,0,1,5,111,116,104,101,114,0,0,10,11,2,4,0,65,7,11,4,0,65,42,11]));
    \\const reexportModule = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,7,1,1,109,1,102,0,0,7,9,2,1,120,0,0,1,121,0,0]));
;

test "WPT function identity: duplicate exports share one function per instance" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\const first = new WebAssembly.Instance(sourceModule).exports;
            \\const second = new WebAssembly.Instance(sourceModule).exports;
            \\first.a === first.b && second.a === second.b && first.a !== first.other &&
            \\  first.a !== second.a && first.a.name === '1' && first.a.length === 0 &&
            \\  first.a() === 42 && first.other() === 7
        , hardened, false);
    }
}

test "WPT function identity: tables and funcref globals preserve exported wrappers" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\const f = new WebAssembly.Instance(sourceModule).exports.a;
            \\const table = new WebAssembly.Table({element: 'anyfunc', initial: 2, maximum: 4}, f);
            \\let correct = table.get(0) === f && table.get(1) === f && table.get(0) === table.get(0);
            \\table.set(0, null);
            \\correct = correct && table.get(0) === null;
            \\table.set(0, f);
            \\correct = correct && table.grow(2, f) === 2;
            \\const global = new WebAssembly.Global({value: 'anyfunc', mutable: true}, f);
            \\correct = correct && global.value === f && global.valueOf() === f;
            \\global.value = null;
            \\global.value = f;
            \\for (let i = 0; i < table.length; i++) correct = table.get(i) === f && correct;
            \\correct && global.value === f && table.get(3)() === 42
        , hardened, false);
    }
}

test "WPT function identity: Wasm reexports and import chains preserve the original wrapper" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\const original = new WebAssembly.Instance(sourceModule).exports.a;
            \\const first = new WebAssembly.Instance(reexportModule, {m: {f: original}}).exports;
            \\const second = new WebAssembly.Instance(reexportModule, {m: {f: first.x}}).exports;
            \\const third = new WebAssembly.Instance(reexportModule, {m: {f: second.y}}).exports;
            \\first.x === original && first.y === original && second.x === original &&
            \\  third.y === original && third.y.name === '1' && third.y.length === 0 && third.y() === 42
        , hardened, false);
    }
}

test "WPT function identity: a table alone retains the wrapper and its properties across GC" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\const table = (() => {
            \\  const f = new WebAssembly.Instance(sourceModule).exports.a;
            \\  f.marker = {answer: 19};
            \\  return new WebAssembly.Table({element: 'anyfunc', initial: 1}, f);
            \\})();
            \\__collectGarbage();
            \\for (let i = 0; i < 100; i++) { const temporary = {i}; }
            \\__collectGarbage();
            \\const f = table.get(0);
            \\f.marker !== undefined && f.marker.answer === 19 && f === table.get(0) && f() === 42
        , hardened, true);
    }
}

test "WPT function identity: a function alone survives GC and later reexport" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\const f = (() => {
            \\  const source = new WebAssembly.Instance(sourceModule).exports.a;
            \\  source.marker = {answer: 23};
            \\  return new WebAssembly.Instance(reexportModule, {m: {f: source}}).exports.x;
            \\})();
            \\__collectGarbage();
            \\for (let i = 0; i < 100; i++) { const temporary = {i}; }
            \\__collectGarbage();
            \\const again = new WebAssembly.Instance(reexportModule, {m: {f}}).exports.y;
            \\again === f && again.marker !== undefined && again.marker.answer === 23 && again() === 42
        , hardened, true);
    }
}

test "WPT function identity: JS import wrappers use Wasm function identity" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(identity_modules ++
            \\function callback() { return 43; }
            \\const first = new WebAssembly.Instance(reexportModule, {m: {f: callback}}).exports;
            \\const second = new WebAssembly.Instance(reexportModule, {m: {f: callback}}).exports;
            \\const chain = new WebAssembly.Instance(reexportModule, {m: {f: first.x}}).exports;
            \\const table = new WebAssembly.Table({element: 'anyfunc', initial: 1}, first.x);
            \\first.x === first.y && first.x !== second.x && second.x === second.y &&
            \\  chain.x === first.x && chain.y === first.x && table.get(0) === first.x
        , hardened, false);
    }
}

test "WPT function identity: start exposure and later export share the first wrapper" {
    // Start publishes ref.func 1 to a JS import before buildExports runs.
    const source =
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,12,3,96,1,112,0,96,0,1,127,96,0,0,2,10,1,1,109,4,115,97,118,101,0,0,3,3,2,1,2,7,5,1,1,102,0,1,8,1,2,9,5,1,3,0,1,1,10,13,2,4,0,65,42,11,6,0,210,1,16,0,11]);
        \\let captured;
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {
        \\  save(f) { captured = f; f.marker = {answer: 29}; __collectGarbage(); }
        \\}});
        \\__collectGarbage();
        \\captured === instance.exports.f && instance.exports.f.marker !== undefined &&
        \\  instance.exports.f.marker.answer === 29 && captured() === 42
    ;
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(source, hardened, true);
    }
}

test "WPT function identity: child realm tables and reexports preserve a parent wrapper" {
    // The function is already materialized in the parent. This asserts its
    // identity survives use through another realm's intrinsics, without
    // prescribing the allocation realm of a never-before-exposed function.
    for ([_]bool{ false, true }) |hardened| {
        var parent = Realm.init(std.testing.allocator);
        defer parent.deinit();
        parent.hardened = hardened;
        parent.allow_wasm_compile = true;
        parent.jit_enabled = true;
        try parent.installBuiltins();
        const scope = try parent.heap.openScope();
        defer scope.close();
        const created = try lantern.evaluateScript(std.testing.allocator, &parent, identity_modules ++ "new WebAssembly.Instance(sourceModule).exports.a");
        const original = switch (created) {
            .value, .yielded => |value| value,
            .thrown => return error.UnexpectedJavaScriptException,
        };
        try scope.push(original);

        var child = Realm.initChild(&parent);
        defer child.deinit();
        try child.installBuiltins();
        try child.installTestGlobals();
        child.heap.setGcThreshold(1);
        try child.globals.put(child.allocator, "parentFunction", original);
        const observed = try lantern.evaluateScript(std.testing.allocator, &child, identity_modules ++
            \\const table = new WebAssembly.Table({element: 'anyfunc', initial: 1, maximum: 2}, parentFunction);
            \\const imported = new WebAssembly.Instance(reexportModule, {m: {f: parentFunction}}).exports;
            \\__collectGarbage();
            \\table.grow(1, imported.x);
            \\__collectGarbage();
            \\table.get(0) === parentFunction && table.get(1) === parentFunction &&
            \\  imported.x === parentFunction && imported.y === parentFunction && imported.x() === 42
        );
        switch (observed) {
            .value, .yielded => |value| try std.testing.expect(value.isBool() and value.asBool()),
            .thrown => return error.UnexpectedJavaScriptException,
        }
    }
}
