//! ToWebAssemblyValue: concrete function references retain module type context.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(comptime source: []const u8) !void {
    for ([_]bool{ false, true }) |native| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        realm.allow_wasm_compile = true;
        realm.jit_enabled = native;
        realm.ohaimark_enabled = false;
        try realm.installBuiltins();
        try realm.installTestGlobals();
        realm.heap.setGcThreshold(1);
        const outcome = try lantern.evaluateScript(std.testing.allocator, &realm, helpers ++ source);
        switch (outcome) {
            .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
            else => return error.UnexpectedJavaScriptCompletion,
        }
    }
}

// Small binary fixtures, with every count/section length below 128.
const helpers =
    \\function instance(sections, imports = {}) {
    \\  const bytes = [0,97,115,109,1,0,0,0];
    \\  for (const [id, data] of sections) bytes.push(id, data.length, ...data);
    \\  return new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(bytes)), imports).exports;
    \\}
    \\function fn(types, index, body) {
    \\  return instance([[1, types], [3, [1,index]], [7,[1,1,102,0,0]],
    \\    [10,[1,body.length,...body]]]).f;
    \\}
    \\function throwsType(action) {
    \\  try { action(); } catch (e) { return e instanceof TypeError; } return false;
    \\}
    \\function throwsLink(action) {
    \\  try { action(); } catch (e) { return e instanceof WebAssembly.LinkError; } return false;
    \\}
    \\const good = fn([1,96,1,127,1,127], 0, [0,32,0,11]);
    \\const bad = fn([1,96,0,1,127], 0, [0,65,42,11]);
;

test "typed reference boundary: arguments reject mismatches before entering Wasm" {
    try expectTrue(
        \\const accept = fn([2,96,1,127,1,127,96,1,99,0,1,127], 1, [0,65,7,11]);
        \\throwsType(() => accept(bad)) && throwsType(() => accept(undefined)) &&
        \\throwsType(() => accept(() => 1)) && accept(good) === 7 && accept(null) === 7;
    );
}

test "typed reference boundary: non-null arguments reject null and undefined" {
    try expectTrue(
        \\const accept = fn([2,96,1,127,1,127,96,1,100,0,1,127], 1, [0,65,7,11]);
        \\throwsType(() => accept(null)) && throwsType(() => accept(undefined)) && accept(good) === 7;
    );
}

test "typed reference boundary: compare nested signatures across module indices" {
    try expectTrue(
        \\const accept = fn([3,96,1,127,1,127,96,1,99,0,1,99,0,
        \\  96,1,99,1,1,127], 2, [0,65,7,11]);
        \\const shifted = fn([3,96,0,0,96,1,127,1,127,96,1,99,1,1,99,1], 2, [0,32,0,11]);
        \\const wrong = fn([2,96,1,124,1,124,96,1,99,0,1,99,0], 1, [0,32,0,11]);
        \\const wrongNullability = fn([2,96,1,127,1,127,96,1,100,0,1,100,0], 1, [0,32,0,11]);
        \\accept(shifted) === 7 && throwsType(() => accept(wrong)) && throwsType(() => accept(wrongNullability));
    );
}

test "typed reference boundary: host single and multiple returns validate before resuming" {
    try expectTrue(
        \\function returning(multi, host) {
        \\  const results = multi ? [2,99,0,127] : [1,99,0];
        \\  return instance([[1,[2,96,1,127,1,127,96,0,...results]],
        \\    [2,[1,1,104,1,102,0,1]], [3,[1,1]], [7,[1,1,102,0,1]],
        \\    [10,[1,4,0,16,0,11]]], {h:{f:host}}).f;
        \\}
        \\let converted = 0;
        \\const single = returning(false, () => { __collectGarbage(); return good; });
        \\const multiple = returning(true, () => [bad, {valueOf() { converted++; return 1; }}]);
        \\single() === good && throwsType(returning(false, () => bad)) &&
        \\throwsType(returning(false, () => undefined)) && throwsType(multiple) && converted === 0 &&
        \\returning(true, () => [good, 3])()[0] === good;
    );
}

test "typed reference boundary: typed tables and globals preserve values after rejection" {
    try expectTrue(
        \\const store = instance([[1,[1,96,1,127,1,127]],
        \\  [4,[1,99,0,1,1,3]], [6,[1,99,0,1,208,0,11]],
        \\  [7,[2,1,116,1,0,1,103,3,0]]]);
        \\store.t.set(0,good); store.g.value = good;
        \\const rejected = throwsType(() => store.t.set(0,bad)) &&
        \\  throwsType(() => store.t.grow(1,bad)) &&
        \\  throwsType(() => { store.g.value = bad; }) && throwsType(() => { store.g.value = undefined; });
        \\rejected && store.t.length === 1 && store.t.get(0) === good && store.g.value === good &&
        \\store.t.grow(1,null) === 1 && store.t.get(1) === null;
    );
}

test "typed reference boundary: primitive global imports and wrapped store imports are checked" {
    try expectTrue(
        \\function globalImport(v) {
        \\  return instance([[1,[1,96,1,127,1,127]], [2,[1,1,104,1,103,3,99,0,0]],
        \\    [7,[1,1,103,3,0]]], {h:{g:v}}).g;
        \\}
        \\const broad = new WebAssembly.Global({value:'anyfunc'},good);
        \\globalImport(good).value === good && throwsLink(() => globalImport(bad)) &&
        \\throwsLink(() => globalImport(broad));
    );
}

test "typed reference boundary: imported functions retain their defining signature" {
    try expectTrue(
        \\function imported(value) {
        \\  return instance([[1,[1,96,1,127,1,127]], [2,[1,1,104,1,102,0,0]],
        \\    [7,[1,1,102,0,0]]], {h:{f:value}}).f;
        \\}
        \\imported(good) === good && typeof imported(x => x) === 'function' && throwsLink(() => imported(bad));
    );
}

test "typed reference boundary: exception payloads validate concrete function references" {
    try expectTrue(
        \\const tag = instance([[1,[2,96,1,127,1,127,96,1,99,0,0]],
        \\  [13,[1,0,1]], [7,[1,1,116,4,0]]]).t;
        \\throwsType(() => new WebAssembly.Exception(tag,[bad])) &&
        \\new WebAssembly.Exception(tag,[good]).getArg(tag,0) === good;
    );
}

test "typed reference boundary: store reexports retain their original type context" {
    try expectTrue(
        \\const store = instance([[1,[3,96,0,0,96,1,127,1,127,96,1,99,1,0]],
        \\  [4,[1,99,1,1,1,3]], [13,[1,0,2]], [6,[1,99,1,1,208,1,11]],
        \\  [7,[3,1,116,1,0,1,103,3,0,1,101,4,0]]]);
        \\function alias(values) {
        \\  return instance([[1,[2,96,1,127,1,127,96,1,99,0,0]],
        \\    [2,[3,1,104,1,116,1,99,0,1,1,3,1,104,1,103,3,99,0,1,1,104,1,101,4,0,1]],
        \\    [7,[3,1,116,1,0,1,103,3,0,1,101,4,0]]], {h:values});
        \\}
        \\const view = alias(store);
        \\view.g.value = good; view.t.set(0,good);
        \\const broad = new WebAssembly.Table({element:'anyfunc',initial:1,maximum:3});
        \\view.t === store.t && view.g === store.g && view.g.value === good && view.t.get(0) === good &&
        \\throwsType(() => view.t.set(0,bad)) && throwsType(() => {view.g.value=bad;}) &&
        \\throwsType(() => new WebAssembly.Exception(view.e,[bad])) &&
        \\new WebAssembly.Exception(view.e,[good]).is(store.e) &&
        \\throwsLink(() => alias({t:broad,g:store.g,e:store.e}));
    );
}

test "typed reference boundary: link checks follow import getters and do not reread them" {
    try expectTrue(
        \\let reads = 0; const sentinel = {};
        \\const sections = [[1,[1,96,1,127,1,127]], [2,[2,1,104,1,102,0,0,1,104,1,103,3,127,0]]];
        \\let preserved = false;
        \\try { instance(sections,{h:{get f(){reads++;return bad;},get g(){reads++;throw sentinel;}}}); }
        \\catch (e) { preserved = e === sentinel; }
        \\const rejected = throwsLink(() => instance(sections,{h:{get f(){reads++;return bad;},get g(){reads++;return 0;}}}));
        \\preserved && rejected && reads === 4;
    );
}

test "typed reference boundary: abstract funcref rejects undefined except optional defaults" {
    try expectTrue(
        \\const accept = fn([1,96,1,112,1,112],0,[0,32,0,11]);
        \\const g = new WebAssembly.Global({value:'anyfunc',mutable:true});
        \\const t = new WebAssembly.Table({element:'anyfunc',initial:1});
        \\t.set(0,good); t.set(0,undefined);
        \\throwsType(() => accept(undefined)) && throwsType(() => {g.value=undefined;}) &&
        \\accept(null) === null && accept(good) === good && g.value === null && t.get(0) === null;
    );
}
