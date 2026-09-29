//! Focused regressions for WPT's WebAssembly Global and value conversions.
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

test "WPT Global: valueOf is a branded enumerable operation" {
    try expectScript(
        \\const descriptor = Object.getOwnPropertyDescriptor(WebAssembly.Global.prototype, 'valueOf');
        \\if (!descriptor || !descriptor.enumerable || !descriptor.writable || !descriptor.configurable) throw 1;
        \\if (descriptor.value.name !== 'valueOf' || descriptor.value.length !== 0) throw 2;
        \\for (const type of ['i32', 'f32', 'f64', 'i64']) {
        \\  const expected = type === 'i64' ? 9n : 9;
        \\  const global = new WebAssembly.Global({value: type}, expected);
        \\  if (global.valueOf() !== expected) throw 3;
        \\}
        \\for (const receiver of [undefined, null, true, 1, '', {}, WebAssembly.Global.prototype]) {
        \\  let threw = false;
        \\  try { descriptor.value.call(receiver); } catch (error) { threw = error instanceof TypeError; }
        \\  if (!threw) throw 4;
        \\}
        \\1;
    , false);
}

test "WPT Global: descriptor gets and conversions follow WebIDL order" {
    try expectScript(
        \\const order = [];
        \\const descriptor = new Proxy({
        \\  mutable: true,
        \\  value: {toString() { order.push('type'); return 'f64'; }}
        \\}, {get(target, key) { order.push(key); return target[key]; }});
        \\const global = new WebAssembly.Global(descriptor, {valueOf() { order.push('initial'); return 7; }});
        \\if (order.join(',') !== 'mutable,value,type,initial' || global.value !== 7) throw 1;
        \\function callableDescriptor() {}
        \\callableDescriptor.value = 'i32';
        \\if (new WebAssembly.Global(callableDescriptor, 3).value !== 3) throw 2;
        \\const inherited = Object.create({mutable: true, value: 'i32'});
        \\const inheritedGlobal = new WebAssembly.Global(inherited, 2);
        \\inheritedGlobal.value = 4;
        \\if (inheritedGlobal.value !== 4) throw 3;
        \\const sentinel = {};
        \\let same = false;
        \\try { new WebAssembly.Global({get mutable() { throw sentinel; }, get value() { throw 4; }}); }
        \\catch (error) { same = error === sentinel; }
        \\if (!same) throw 5;
        \\1;
    , false);
}

test "WPT Global: missing and undefined initial values use the correct defaults" {
    try expectScript(
        \\for (const type of ['i32', 'f32', 'f64', 'i64', 'externref', 'anyfunc']) {
        \\  const expected = type === 'i64' ? 0n : type === 'externref' ? undefined : type === 'anyfunc' ? null : 0;
        \\  if (!Object.is(new WebAssembly.Global({value: type}).value, expected)) throw 1;
        \\  if (!Object.is(new WebAssembly.Global({value: type}, undefined).value, expected)) throw 2;
        \\}
        \\let calls = 0, threw = false;
        \\try { new WebAssembly.Global({value: 'v128'}, {valueOf() { ++calls; return 1; }}); }
        \\catch (error) { threw = error instanceof TypeError; }
        \\if (!threw || calls !== 0) throw 3;
        \\1;
    , false);
}

test "WPT Global: numeric initialization and writes perform full coercion" {
    try expectScript(
        \\for (const type of ['i32', 'f32', 'f64']) {
        \\  const global = new WebAssembly.Global({value: type, mutable: true}, {valueOf() { return '7'; }});
        \\  if (global.value !== 7) throw 1;
        \\  global.value = {[Symbol.toPrimitive](hint) { if (hint !== 'number') throw 2; return 9; }};
        \\  if (global.value !== 9) throw 3;
        \\  for (const invalid of [1n, Symbol()]) {
        \\    let threw = false;
        \\    try { global.value = invalid; } catch (error) { threw = error instanceof TypeError; }
        \\    if (!threw || global.value !== 9) throw 4;
        \\  }
        \\}
        \\const global = new WebAssembly.Global({value: 'i64', mutable: true}, {valueOf() { return '18446744073709551621'; }});
        \\if (global.value !== 5n) throw 5;
        \\global.value = true;
        \\if (global.value !== 1n) throw 6;
        \\global.value = {toString() { return '-7'; }};
        \\if (global.value !== -7n) throw 7;
        \\let syntaxError = false;
        \\try { global.value = 'not-an-integer'; } catch (error) { syntaxError = error instanceof SyntaxError; }
        \\if (!syntaxError || global.value !== -7n) throw 8;
        \\let numberError = false;
        \\try { global.value = 7; } catch (error) { numberError = error instanceof TypeError; }
        \\if (!numberError) throw 9;
        \\1;
    , false);
}

test "WPT Global: immutable writes reject before coercion and mutable throws preserve identity" {
    try expectScript(
        \\let calls = 0, rejected = false;
        \\const immutable = new WebAssembly.Global({value: 'i32'}, 7);
        \\try { immutable.value = {valueOf() { ++calls; return 9; }}; }
        \\catch (error) { rejected = error instanceof TypeError; }
        \\if (!rejected || calls !== 0 || immutable.value !== 7) throw 1;
        \\const global = new WebAssembly.Global({value: 'f64', mutable: true}, 5);
        \\const sentinel = {};
        \\let same = false;
        \\try { global.value = {valueOf() { throw sentinel; }}; } catch (error) { same = error === sentinel; }
        \\if (!same || global.value !== 5) throw 2;
        \\1;
    , false);
}

test "WPT Global: descriptor and value conversions survive GC reentry" {
    try expectScript(
        \\const global = new WebAssembly.Global({
        \\  get mutable() { __collectGarbage(); return true; },
        \\  get value() { return {toString() { __collectGarbage(); return 'i64'; }}; }
        \\}, {valueOf() { __collectGarbage(); return '8'; }});
        \\global.value = {valueOf() { __collectGarbage(); return 13n; }};
        \\if (global.value !== 13n) throw 1;
        \\const external = new WebAssembly.Global({value: 'externref', mutable: true}, {answer: 42});
        \\__collectGarbage();
        \\if (external.value.answer !== 42) throw 2;
        \\1;
    , true);
}

const i32_adder = "new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11])";
const i64_identity = "new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,1,126,1,126,3,2,1,0,7,5,1,1,102,0,0,10,6,1,4,0,32,0,11])";

test "WPT marshalling: exported numeric parameters coerce once and preserve throws" {
    try expectScript(
        "const add = new WebAssembly.Instance(new WebAssembly.Module(" ++ i32_adder ++ ")).exports.add;" ++
            "let calls = 0;" ++
            "const result = add({valueOf() { ++calls; __collectGarbage(); return 7; }}, {valueOf() { ++calls; return '8'; }});" ++
            "if (result !== 15 || calls !== 2) throw 1;" ++
            "for (const invalid of [1n, Symbol()]) { let threw = false; try { add(invalid, 2); } catch(error) { threw = error instanceof TypeError; } if (!threw) throw 2; }" ++
            "const f = new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_identity ++ ")).exports.f;" ++
            "if (f({valueOf() { __collectGarbage(); return '9'; }}) !== 9n || f(true) !== 1n) throw 3;" ++
            "const sentinel = {}; let same = false; try { f({valueOf() { throw sentinel; }}); } catch(error) { same = error === sentinel; }" ++
            "if (!same) throw 4; 1;",
        true,
    );
}

test "WPT marshalling: host result numeric coercion survives GC reentry" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,7,1,1,109,1,102,0,0,3,2,1,0,7,5,1,1,102,0,1,10,6,1,4,0,16,0,11]);
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {f() { return {valueOf() { __collectGarbage(); return 41; }}; }}});
        \\if (instance.exports.f() !== 41) throw 1;
        \\1;
    , true);
}

test "WPT marshalling: primitive Global imports reject coercion and mutability mismatches" {
    try expectScript(
        \\function moduleFor(type, mutable) {
        \\  return new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,2,8,1,1,109,1,103,3,type,mutable,7,5,1,1,103,3,0]));
        \\}
        \\const numeric = moduleFor(127, 0), bigint = moduleFor(126, 0);
        \\let calls = 0;
        \\const object = {valueOf() { ++calls; return 1; }};
        \\for (const invalid of [object, true, '1', 1n, undefined, null]) {
        \\  let threw = false;
        \\  try { new WebAssembly.Instance(numeric, {m: {g: invalid}}); }
        \\  catch (error) { threw = error instanceof WebAssembly.LinkError; }
        \\  if (!threw) throw 1;
        \\}
        \\for (const invalid of [object, true, '1', 1]) {
        \\  let threw = false;
        \\  try { new WebAssembly.Instance(bigint, {m: {g: invalid}}); }
        \\  catch (error) { threw = error instanceof WebAssembly.LinkError; }
        \\  if (!threw) throw 2;
        \\}
        \\let mutableThrew = false;
        \\try { new WebAssembly.Instance(moduleFor(127, 1), {m: {g: 1}}); }
        \\catch (error) { mutableThrew = error instanceof WebAssembly.LinkError; }
        \\if (!mutableThrew || calls !== 0) throw 3;
        \\if (new WebAssembly.Instance(numeric, {m: {g: 8}}).exports.g.value !== 8) throw 4;
        \\if (new WebAssembly.Instance(bigint, {m: {g: 9n}}).exports.g.value !== 9n) throw 5;
        \\1;
    , false);
}

test "WPT marshalling: later exception coercion retains earlier externref payload" {
    try expectScript(
        \\const tag = new WebAssembly.Tag({parameters: ['externref', 'i32']});
        \\const payload = [{answer: 42}, {valueOf() { payload[0] = null; __collectGarbage(); return 7; }}];
        \\const exception = new WebAssembly.Exception(tag, payload);
        \\if (exception.getArg(tag, 0).answer !== 42 || exception.getArg(tag, 1) !== 7) throw 1;
        \\1;
    , true);
}

test "WPT marshalling: imported callbacks remain live after argument and explicit GC" {
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,7,1,1,109,1,102,0,0,3,2,1,0,7,5,1,1,102,0,1,10,6,1,4,0,16,0,11]);
        \\const f = new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {f: (() => { const state = {value: 37}; return () => state.value; })()}}).exports.f;
        \\__collectGarbage();
        \\if (f() !== 37) throw 1;
        \\__collectGarbage();
        \\if (f() !== 37) throw 2;
        \\1;
    , true);
}

test "WPT marshalling: failed imports clean roots but started instances retain them" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    const roots_before = realm.wasm_extern_global_cells.items.len;
    const instances_before = realm.wasm_instances.items.len;
    const failed_import = try lantern.evaluateScript(std.testing.allocator, &realm,
        \\const badImport = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,14,2,1,109,1,102,0,0,1,109,1,103,3,127,0]));
        \\for (let i = 0; i < 3; ++i) {
        \\  let threw = false;
        \\  try { new WebAssembly.Instance(badImport, {m: {f() {}, g: 'invalid'}}); }
        \\  catch (error) { threw = error instanceof WebAssembly.LinkError; }
        \\  if (!threw) throw 1;
        \\}
        \\1;
    );
    const import_value = switch (failed_import) {
        .value => |value| value,
        else => return error.UnexpectedWasmCompletion,
    };
    try std.testing.expect(import_value.isInt32());
    try std.testing.expectEqual(@as(i32, 1), import_value.asInt32());
    try std.testing.expectEqual(roots_before, realm.wasm_extern_global_cells.items.len);
    try std.testing.expectEqual(instances_before, realm.wasm_instances.items.len);

    const failed_start = try lantern.evaluateScript(std.testing.allocator, &realm,
        \\const badStart = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,7,1,1,109,1,102,0,0,3,2,1,0,8,1,1,10,6,1,4,0,16,0,11]));
        \\const sentinel = {};
        \\for (let i = 0; i < 3; ++i) {
        \\  let threw = false;
        \\  try { new WebAssembly.Instance(badStart, {m: {f() { throw sentinel; }}}); }
        \\  catch (error) { threw = error === sentinel; }
        \\  if (!threw) throw 1;
        \\}
        \\1;
    );
    const start_value = switch (failed_start) {
        .value => |value| value,
        else => return error.UnexpectedWasmCompletion,
    };
    try std.testing.expect(start_value.isInt32());
    try std.testing.expectEqual(@as(i32, 1), start_value.asInt32());
    // A start function may publish ref.func before it traps. Retain its
    // realm-owned store and callbacks conservatively until realm teardown.
    try std.testing.expect(realm.wasm_extern_global_cells.items.len >= roots_before + 3);
    try std.testing.expectEqual(instances_before + 3, realm.wasm_instances.items.len);
}

test "WPT marshalling: function escaping a trapping start retains memory and callbacks" {
    // Imports save(funcref) and get()->i32. Start writes 5 to owned memory,
    // publishes a local function that loads it and adds get(), then traps.
    // Node/V8 validates these bytes and returns 42 through the escaped ref.
    try expectScript(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,12,3,96,1,112,0,96,0,1,127,96,0,0,2,18,2,1,109,4,115,97,118,101,0,0,1,109,3,103,101,116,0,1,3,3,2,1,2,5,3,1,0,1,8,1,3,9,5,1,3,0,1,2,10,27,2,10,0,65,0,40,2,0,16,1,106,11,14,0,65,0,65,5,54,2,0,210,2,16,0,0,11]);
        \\let escaped, trapped = false;
        \\try { new WebAssembly.Instance(new WebAssembly.Module(bytes), {m: {
        \\  save(f) { escaped = f; },
        \\  get: (() => { const state = {value: 37}; return () => state.value; })()
        \\}}); }
        \\catch(error) { trapped = error instanceof WebAssembly.RuntimeError; }
        \\if (!trapped || typeof escaped !== 'function') throw 1;
        \\__collectGarbage();
        \\if (escaped() !== 42) throw 2;
        \\__collectGarbage();
        \\if (escaped() !== 42) throw 3;
        \\1;
    , true);
}
