//! WPT regressions for import Get ordering and exported-function names.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectScript(source: []const u8, gc_pressure: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    if (gc_pressure) {
        try realm.installTestGlobals();
        realm.heap.setGcThreshold(1);
    }
    const outcome = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    const value = switch (outcome) {
        .value => |value| value,
        else => return error.UnexpectedWasmCompletion,
    };
    try std.testing.expect(value.isInt32());
    try std.testing.expectEqual(@as(i32, 1), value.asInt32());
}

test "WPT imports: ordinary Get runs per declaration in module order" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,2,15,2,1,109,1,97,3,127,0,1,109,1,98,3,127,0,7,9,2,1,97,3,0,1,98,3,1]);
        \\const calls = [];
        \\const imports = new Proxy({}, {
        \\  has() { throw new Error('unexpected HasProperty'); },
        \\  get(target, name) {
        \\    calls.push('module:' + name);
        \\    return new Proxy({}, {
        \\      has() { throw new Error('unexpected HasProperty'); },
        \\      get(namespace, field) { calls.push('field:' + field); return field === 'a' ? 7 : 9; }
        \\    });
        \\  }
        \\});
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
        \\if (calls.join(',') !== 'module:m,field:a,module:m,field:b') throw new Error('wrong getter order');
        \\if (instance.exports.a.value !== 7 || instance.exports.b.value !== 9) throw new Error('wrong imports');
        \\1;
    , false);
}

test "WPT imports: callable objects and inherited getters are accepted" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,2,15,2,1,109,1,97,3,127,0,1,109,1,98,3,127,0,7,9,2,1,97,3,0,1,98,3,1]);
        \\function imports() {}
        \\function namespace() {}
        \\Object.defineProperty(imports, 'm', { get() { return namespace; } });
        \\Object.defineProperty(namespace, 'a', { get() { return 7; } });
        \\Object.defineProperty(namespace, 'b', { get() { return 9; } });
        \\const module = new WebAssembly.Module(bytes);
        \\if (new WebAssembly.Instance(module, imports).exports.b.value !== 9) throw new Error('callable imports');
        \\const inherited = Object.create({ get m() { return Object.create({get a() { return 3; }, get b() { return 4; }}); } });
        \\if (new WebAssembly.Instance(module, inherited).exports.a.value !== 3) throw new Error('inherited imports');
        \\1;
    , false);
}

test "WPT imports: abrupt getters preserve identity and invalid namespaces throw TypeError" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,2,15,2,1,109,1,97,3,127,0,1,109,1,98,3,127,0,7,9,2,1,97,3,0,1,98,3,1]);
        \\const module = new WebAssembly.Module(bytes);
        \\const sentinel = {};
        \\let caught = 0, fields = 0;
        \\try { new WebAssembly.Instance(module, {get m() { throw sentinel; }}); }
        \\catch (error) { if (error === sentinel) caught++; }
        \\try { new WebAssembly.Instance(module, {m: {get a() { fields++; throw sentinel; }, get b() { fields++; return 0; }}}); }
        \\catch (error) { if (error === sentinel) caught++; }
        \\for (const value of [undefined, null, 1, 'namespace']) {
        \\  try { new WebAssembly.Instance(module, {m: value}); }
        \\  catch (error) { if (error instanceof TypeError) caught++; }
        \\}
        \\if (caught !== 6 || fields !== 1) throw new Error('incorrect abrupt import lookup');
        \\1;
    , false);
}

test "WPT imports: fresh externref getter result survives later collecting getter" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,2,15,2,1,109,1,97,3,111,0,1,109,1,98,3,127,0,7,9,2,1,97,3,0,1,98,3,1]);
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        \\  get m() { return {
        \\    get a() { return {answer: 42}; },
        \\    get b() { __collectGarbage(); return 7; }
        \\  }; }
        \\});
        \\__collectGarbage();
        \\if (instance.exports.a.value.answer !== 42 || instance.exports.b.value !== 7) throw new Error('lost import root');
        \\1;
    , true);
}

test "WPT exports: function names use numeric indices including table reads" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,3,2,0,0,7,12,2,5,110,97,109,101,100,0,0,0,0,1,10,7,2,2,0,11,2,0,11]);
        \\const exports = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
        \\if (exports.named.name !== '0' || exports[''].name !== '1') throw new Error('export name used as function name');
        \\const table = new WebAssembly.Table({element: 'anyfunc', initial: 1});
        \\table.set(0, exports['']);
        \\if (table.get(0).name !== '1') throw new Error('table read omitted numeric name');
        \\const descriptor = Object.getOwnPropertyDescriptor(exports.named, 'name');
        \\if (descriptor.writable || descriptor.enumerable || !descriptor.configurable) throw new Error('name descriptor');
        \\1;
    , false);
}
