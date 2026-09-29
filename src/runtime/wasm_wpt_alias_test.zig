//! Distinct Wasm shared-buffer wrappers still identify the same data block.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(source: []const u8, hardened: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = hardened;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
    const result = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    switch (result) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        else => return error.UnexpectedJavaScriptException,
    }
}

test "WPT Memory aliases: shared slice rejects a species result over the same store even when empty" {
    try expectTrue(
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\const fixed = memory.buffer;
        \\const growable = memory.toResizableBuffer();
        \\Object.defineProperty(SharedArrayBuffer, Symbol.species, {value: function() {
        \\  __collectGarbage(); return growable;
        \\}});
        \\let rejected = false;
        \\try { fixed.slice(0, 0); } catch (error) { rejected = error instanceof TypeError; }
        \\rejected && fixed !== growable && fixed.byteLength === 65536 && growable.byteLength === 65536;
    , false);
}

test "WPT Memory aliases: shared slice reloads storage after coercion and species growth" {
    try expectTrue(
        \\let ok = true;
        \\for (const speciesGrowth of [false, true]) {
        \\  const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\  const source = memory.buffer;
        \\  const bytes = new Uint8Array(source);
        \\  bytes[0] = 21;
        \\  function growAndWrite() { memory.grow(1); bytes[0] = 87; __collectGarbage(); }
        \\  Object.defineProperty(SharedArrayBuffer, Symbol.species, {configurable: true, value: function(size) {
        \\    if (speciesGrowth) growAndWrite();
        \\    return new SharedArrayBuffer(size);
        \\  }});
        \\  const copy = source.slice({valueOf() { if (!speciesGrowth) growAndWrite(); return 0; }}, 1);
        \\  ok = copy.byteLength === 1 && new Uint8Array(copy)[0] === 87 &&
        \\    source.byteLength === 65536 && bytes[0] === 87 && ok;
        \\}
        \\ok;
    , false);
}

test "WPT Memory aliases: typed set snapshots different element kinds across shared wrappers" {
    for ([_]bool{ false, true }) |hardened| try expectTrue(
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\const fixed = memory.buffer;
        \\const growable = memory.toResizableBuffer();
        \\const source = new Uint8Array(fixed, 0, 3);
        \\source[0] = 1; source[1] = 2; source[2] = 3;
        \\const target = new Uint16Array(growable, 0, 3);
        \\__collectGarbage();
        \\target.set(source);
        \\target[0] === 1 && target[1] === 2 && target[2] === 3;
    , hardened);
}

test "WPT Memory aliases: typed set snapshots overlapping same-kind shared wrappers" {
    for ([_]bool{ false, true }) |hardened| try expectTrue(
        \\let ok = true;
        \\for (const reverse of [false, true]) {
        \\  const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\  const fixed = memory.buffer;
        \\  const growable = memory.toResizableBuffer();
        \\  const source = new Uint8Array(reverse ? growable : fixed, 0, 3);
        \\  const target = new Uint8Array(reverse ? fixed : growable, 0, 4);
        \\  source[0] = 1; source[1] = 2; source[2] = 3; target[3] = 4;
        \\  __collectGarbage();
        \\  target.set(source, 1);
        \\  ok = target[0] === 1 && target[1] === 1 && target[2] === 2 && target[3] === 3 && ok;
        \\}
        \\ok;
    , hardened);
}

test "WPT Memory aliases: typed slice copies forward through an overlapping species view" {
    try expectTrue(
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\const source = new Uint8Array(memory.buffer, 0, 4);
        \\source[0] = 1; source[1] = 2; source[2] = 3; source[3] = 4;
        \\const other = memory.toResizableBuffer();
        \\source.constructor = { [Symbol.species]: function(length) {
        \\  __collectGarbage(); return new Uint8Array(other, 1, length);
        \\}};
        \\const output = source.slice(0, 3);
        \\output.buffer === other && output.length === 3 && output[0] === 1 && output[1] === 1 &&
        \\  output[2] === 1 && source[0] === 1 && source[1] === 1 && source[2] === 1 && source[3] === 1;
    , false);
}
