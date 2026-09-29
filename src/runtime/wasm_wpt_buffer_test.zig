//! Wasm JS API §5.3: conversion of memory buffers and HostResizeArrayBuffer.
//! https://webassembly.github.io/spec/js-api/#memories
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectResult(realm: *Realm, source: []const u8) !void {
    const outcome = try lantern.evaluateScript(std.testing.allocator, realm, source);
    switch (outcome) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        .yielded => return error.UnexpectedYield,
        .thrown => return error.UnexpectedJavaScriptException,
    }
}

fn expectTrue(source: []const u8, hardened: bool, pressure: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.setMemoryLimit(realm.heap.bytes_live + 16 * 1024 * 1024);
    if (pressure) realm.heap.setGcThreshold(1);
    try expectResult(&realm, source);
}

const throws_helper =
    \\function throwsType(f, type) { try { f(); } catch (e) { return e instanceof type; } return false; }
;

// (module (import "s" "m" (memory 1 3))
//   (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))
const grow_module =
    \\const growModule = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,2,9,1,1,115,1,109,2,1,1,3,3,2,1,0,7,8,1,4,103,114,111,119,0,0,10,8,1,6,0,32,0,64,0,11]));
;

test "WPT Memory buffers: methods have Web IDL descriptors and strict receiver brands" {
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({initial: 0, maximum: 1});
        \\let ok = true;
        \\for (const name of ['toFixedLengthBuffer', 'toResizableBuffer']) {
        \\  const d = Object.getOwnPropertyDescriptor(WebAssembly.Memory.prototype, name);
        \\  ok = !!d && typeof d.value === 'function' && d.writable && d.enumerable && d.configurable &&
        \\    d.value.name === name && d.value.length === 0 && !Object.hasOwn(memory, name) && ok;
        \\  for (const receiver of [undefined, null, true, '', Symbol(), 1, {}, WebAssembly.Memory,
        \\      WebAssembly.Memory.prototype, Object.create(memory), new Proxy(memory, {})]) {
        \\    ok = throwsType(() => d.value.call(receiver), TypeError) && ok;
        \\  }
        \\}
        \\ok;
    , false, false);
}

test "WPT Memory buffers: resizable conversion needs a declared maximum" {
    try expectTrue(throws_helper ++
        \\const unbounded = new WebAssembly.Memory({initial: 1});
        \\const fixed = unbounded.buffer;
        \\const rejected = throwsType(() => unbounded.toResizableBuffer(), TypeError);
        \\const zero = new WebAssembly.Memory({initial: 0, maximum: 0}).toResizableBuffer();
        \\const largest = new WebAssembly.Memory({initial: 0, maximum: 65536}).toResizableBuffer();
        \\rejected && fixed === unbounded.buffer && !fixed.detached && fixed.byteLength === 65536 &&
        \\  fixed === unbounded.toFixedLengthBuffer() && zero.resizable && zero.maxByteLength === 0 &&
        \\  zero.resize(0) === undefined && largest.maxByteLength === 4294967296;
    , false, false);
}

test "WPT Memory buffers: conversion caches identity detaches old views and preserves bytes" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(throws_helper ++
            \\const memory = new WebAssembly.Memory({initial: 1, maximum: 3});
            \\const fixed = memory.buffer;
            \\const oldBytes = new Uint8Array(fixed);
            \\const oldView = new DataView(fixed);
            \\oldBytes[0] = 73;
            \\let ok = memory.toFixedLengthBuffer() === fixed;
            \\const resizable = memory.toResizableBuffer();
            \\__collectGarbage();
            \\ok = resizable !== fixed && fixed.detached && oldBytes.length === 0 &&
            \\  throwsType(() => oldView.getUint8(0), TypeError) && resizable === memory.buffer &&
            \\  resizable === memory.toResizableBuffer() && resizable.resizable &&
            \\  resizable.maxByteLength === 196608 && new Uint8Array(resizable)[0] === 73 && ok;
            \\const currentBytes = new Uint8Array(resizable);
            \\currentBytes[1] = 91;
            \\const converted = memory.toFixedLengthBuffer();
            \\__collectGarbage();
            \\ok && converted !== resizable && resizable.detached && currentBytes.length === 0 &&
            \\  !converted.resizable && converted.maxByteLength === 65536 &&
            \\  converted === memory.buffer && converted === memory.toFixedLengthBuffer() &&
            \\  new Uint8Array(converted)[0] === 73 && new Uint8Array(converted)[1] === 91;
        , hardened, true);
    }
}

test "WPT Memory buffers: JS and Wasm growth keep resizable identity and refresh typed views" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(grow_module ++
            \\let ok = true;
            \\for (const viaWasm of [false, true]) {
            \\  const memory = new WebAssembly.Memory({initial: 1, maximum: 3});
            \\  const grow = new WebAssembly.Instance(growModule, {s: {m: memory}}).exports.grow;
            \\  const buffer = memory.toResizableBuffer();
            \\  const bytes = new Uint8Array(buffer);
            \\  const fixedBytes = new Uint8Array(buffer, 0, 2);
            \\  const view = new DataView(buffer);
            \\  const fixedView = new DataView(buffer, 0, 2);
            \\  bytes[0] = 27;
            \\  const previous = viaWasm ? grow(1) : memory.grow(1);
            \\  __collectGarbage();
            \\  ok = previous === 1 && memory.buffer === buffer && !buffer.detached && buffer.byteLength === 131072 &&
            \\    bytes.length === 131072 && fixedBytes.length === 2 && view.byteLength === 131072 &&
            \\    fixedView.byteLength === 2 && bytes[0] === 27 && bytes[65536] === 0 && ok;
            \\  view.setUint8(65536, 81);
            \\  fixedBytes[1] = 99;
            \\  ok = bytes[65536] === 81 && new Uint8Array(memory.buffer)[1] === 99 && ok;
            \\  const sameSize = viaWasm ? grow(0) : memory.grow(0);
            \\  ok = sameSize === 2 && memory.buffer === buffer && !buffer.detached &&
            \\    bytes[0] === 27 && view.getUint8(65536) === 81 && ok;
            \\}
            \\ok;
        , hardened, true);
    }
}

test "WPT Memory buffers: resize grows whole pages and rejects shrink or excessive size atomically" {
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({initial: 0, maximum: 3});
        \\const buffer = memory.toResizableBuffer();
        \\const bytes = new Uint8Array(buffer);
        \\let ok = buffer.resize(131072) === undefined && buffer === memory.buffer && bytes.length === 131072;
        \\bytes[0] = 63;
        \\for (const size of [1, 65536, 196607, 262144, Infinity, 1e30]) {
        \\  ok = throwsType(() => buffer.resize(size), RangeError) && buffer.byteLength === 131072 &&
        \\    bytes.length === 131072 && bytes[0] === 63 && ok;
        \\}
        \\ok = buffer.resize(131072) === undefined && !buffer.detached && ok;
        \\buffer.resize(196608);
        \\ok && memory.grow(0) === 3 && memory.buffer === buffer && buffer.maxByteLength === 196608 &&
        \\  bytes.length === 196608 && bytes[0] === 63 && bytes[131072] === 0;
    , false, true);
}

test "WPT Memory buffers: resizable buffers refuse both transfer operations without losing memory" {
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2});
        \\const buffer = memory.toResizableBuffer();
        \\const bytes = new Uint8Array(buffer);
        \\bytes[0] = 42;
        \\let ok = true;
        \\for (const name of ['transfer', 'transferToFixedLength']) {
        \\  ok = throwsType(() => buffer[name](), TypeError) &&
        \\    throwsType(() => buffer[name](0), TypeError) && !buffer.detached &&
        \\    memory.buffer === buffer && bytes[0] === 42 && ok;
        \\}
        \\memory.grow(1);
        \\ok && bytes.length === 131072 && bytes[0] === 42 && buffer === memory.buffer;
    , false, true);
}

test "WPT Memory buffers: collecting resize coercion observes reentrant growth and detachment" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(throws_helper ++
            \\const memory = new WebAssembly.Memory({initial: 1, maximum: 3});
            \\const buffer = memory.toResizableBuffer();
            \\const bytes = new Uint8Array(buffer);
            \\bytes[0] = 58;
            \\let calls = 0;
            \\buffer.resize({valueOf() { calls++; memory.grow(1); __collectGarbage(); return 196608; }});
            \\let ok = calls === 1 && buffer === memory.buffer && bytes.length === 196608 && bytes[0] === 58;
            \\const rejected = throwsType(() => buffer.resize({valueOf() {
            \\  calls++; memory.toFixedLengthBuffer(); __collectGarbage(); return 196608;
            \\}}), TypeError);
            \\ok && rejected && calls === 2 && buffer.detached && bytes.length === 0 &&
            \\  !memory.buffer.resizable && memory.buffer.byteLength === 196608 &&
            \\  new Uint8Array(memory.buffer)[0] === 58;
        , hardened, true);
    }
}

test "WPT Memory buffers: buffer alone retains the store across collection and resize" {
    try expectTrue(
        \\const buffer = (() => new WebAssembly.Memory({initial: 1, maximum: 2}).toResizableBuffer())();
        \\const bytes = new Uint8Array(buffer);
        \\bytes[0] = 112;
        \\__collectGarbage();
        \\buffer.resize({valueOf() { __collectGarbage(); return 131072; }});
        \\__collectGarbage();
        \\buffer.byteLength === 131072 && bytes.length === 131072 && bytes[0] === 112 && bytes[65536] === 0;
    , false, true);
}

test "WPT Memory buffers: resize respects Realm quota without changing buffer or views" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    try expectResult(&realm,
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 32});
        \\const buffer = memory.toResizableBuffer();
        \\const bytes = new Uint8Array(buffer);
        \\bytes[0] = 17;
        \\true;
    );
    realm.setMemoryLimit(realm.heap.bytes_live + 512 * 1024);
    try expectResult(&realm, throws_helper ++
        \\throwsType(() => buffer.resize(16 * 65536), RangeError) && memory.buffer === buffer &&
        \\  buffer.byteLength === 65536 && bytes.length === 65536 && bytes[0] === 17 && !buffer.detached;
    );
}

test "WPT Memory buffers: resize validates ToIndex before reporting detachment" {
    // ECMA-262 §25.1.6.6 steps 4–5: a negative or excessive ToIndex
    // throws before the detached-buffer check, including after conversion.
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2});
        \\const detached = memory.toResizableBuffer();
        \\memory.toFixedLengthBuffer();
        \\let ok = detached.detached;
        \\for (const size of [-1, -Infinity, Infinity, 1e30]) {
        \\  ok = throwsType(() => detached.resize(size), RangeError) && ok;
        \\}
        \\ok = throwsType(() => detached.resize(0), TypeError) && ok;
        \\const sentinel = {};
        \\let preserved = false;
        \\try { detached.resize({valueOf() { __collectGarbage(); throw sentinel; }}); }
        \\catch (error) { preserved = error === sentinel; }
        \\ok && preserved && memory.buffer.byteLength === 65536;
    , false, true);
}

// The same grow function, importing a shared memory (limits flag 3).
const shared_grow_module =
    \\const growModule = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,2,9,1,1,115,1,109,2,3,1,3,3,2,1,0,7,8,1,4,103,114,111,119,0,0,10,8,1,6,0,32,0,64,0,11]));
;

test "WPT Memory buffers: shared conversion caches frozen buffers without detaching previous views" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(
            \\const memory = new WebAssembly.Memory({initial: 1, maximum: 3, shared: true});
            \\const fixed = memory.buffer;
            \\const fixedBytes = new Uint8Array(fixed);
            \\fixedBytes[0] = 79;
            \\let ok = fixed instanceof SharedArrayBuffer && !fixed.growable &&
            \\  fixed === memory.toFixedLengthBuffer() && Object.isFrozen(fixed);
            \\const growable = memory.toResizableBuffer();
            \\const growingBytes = new Uint8Array(growable);
            \\__collectGarbage();
            \\ok = growable instanceof SharedArrayBuffer && growable.growable && Object.isFrozen(growable) &&
            \\  growable !== fixed && growable === memory.toResizableBuffer() && growable === memory.buffer &&
            \\  growable.maxByteLength === 196608 && fixed.byteLength === 65536 && fixedBytes[0] === 79 && ok;
            \\const nextFixed = memory.toFixedLengthBuffer();
            \\__collectGarbage();
            \\growingBytes[1] = 93;
            \\ok && nextFixed !== fixed && nextFixed !== growable && !nextFixed.growable && Object.isFrozen(nextFixed) &&
            \\  nextFixed === memory.toFixedLengthBuffer() && nextFixed === memory.buffer &&
            \\  fixedBytes.length === 65536 && growingBytes.length === 65536 &&
            \\  fixedBytes[1] === 93 && new Uint8Array(nextFixed)[0] === 79 && new Uint8Array(nextFixed)[1] === 93;
        , hardened, true);
    }
}

test "WPT Memory buffers: shared JS and Wasm growth refresh growable views and replace cached fixed buffer" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(shared_grow_module ++
            \\let ok = true;
            \\for (const viaWasm of [false, true]) {
            \\  const memory = new WebAssembly.Memory({initial: 1, maximum: 3, shared: true});
            \\  const grow = new WebAssembly.Instance(growModule, {s: {m: memory}}).exports.grow;
            \\  const firstFixed = memory.buffer;
            \\  const fixedBytes = new Uint8Array(firstFixed);
            \\  const fixedView = new DataView(firstFixed);
            \\  const growable = memory.toResizableBuffer();
            \\  const growingBytes = new Uint8Array(growable);
            \\  const growingView = new DataView(growable);
            \\  const beforeGrow = memory.toFixedLengthBuffer();
            \\  fixedBytes[0] = 24;
            \\  const previous = viaWasm ? grow(1) : memory.grow(1);
            \\  __collectGarbage();
            \\  const current = memory.buffer;
            \\  ok = previous === 1 && current !== beforeGrow && !current.growable && Object.isFrozen(current) &&
            \\    current === memory.buffer && current.byteLength === 131072 &&
            \\    firstFixed.byteLength === 65536 && beforeGrow.byteLength === 65536 &&
            \\    fixedBytes.length === 65536 && fixedView.byteLength === 65536 &&
            \\    growable.byteLength === 131072 && growingBytes.length === 131072 &&
            \\    growingView.byteLength === 131072 && growingBytes[0] === 24 && growingBytes[65536] === 0 && ok;
            \\  new Uint8Array(current)[1] = 86;
            \\  growingView.setUint8(65536, 109);
            \\  ok = fixedBytes[1] === 86 && fixedView.getUint8(1) === 86 &&
            \\    new Uint8Array(current)[65536] === 109 && ok;
            \\}
            \\ok;
        , hardened, true);
    }
}

test "WPT Memory buffers: a previous growable shared buffer can still grow the memory" {
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 3, shared: true});
        \\const growable = memory.toResizableBuffer();
        \\const bytes = new Uint8Array(growable);
        \\const fixed = memory.toFixedLengthBuffer();
        \\const fixedBytes = new Uint8Array(fixed);
        \\fixedBytes[0] = 51;
        \\__collectGarbage();
        \\let calls = 0;
        \\const result = growable.grow({valueOf() { calls++; __collectGarbage(); return 131072; }});
        \\const current = memory.buffer;
        \\let ok = result === undefined && calls === 1 && current !== fixed && !current.growable &&
        \\  Object.isFrozen(current) && current.byteLength === 131072 && fixed.byteLength === 65536 &&
        \\  growable.byteLength === 131072 && bytes.length === 131072 && bytes[0] === 51;
        \\for (const size of [65536, 196607, 262144]) {
        \\  ok = throwsType(() => growable.grow(size), RangeError) && growable.byteLength === 131072 &&
        \\    memory.buffer === current && bytes[0] === 51 && ok;
        \\}
        \\growable.grow(196608);
        \\bytes[1] = 114;
        \\ok && memory.buffer !== current && !memory.buffer.growable && memory.buffer.byteLength === 196608 &&
        \\  growable.byteLength === 196608 && bytes.length === 196608 && bytes[131072] === 0 && fixedBytes[1] === 114;
    , false, true);
}

test "WPT Memory buffers: shared wrappers retain intrinsic prototype after global replacement" {
    try expectTrue(
        \\const OriginalSharedArrayBuffer = SharedArrayBuffer;
        \\const expected = OriginalSharedArrayBuffer.prototype;
        \\const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
        \\const before = memory.buffer;
        \\SharedArrayBuffer = function Replacement() {};
        \\function NewTarget() {}
        \\NewTarget.prototype = 42;
        \\__collectGarbage();
        \\const constructed = Reflect.construct(OriginalSharedArrayBuffer, [0], NewTarget);
        \\const growable = memory.toResizableBuffer();
        \\const fixed = memory.toFixedLengthBuffer();
        \\memory.grow(1);
        \\const grown = memory.buffer;
        \\Object.getPrototypeOf(constructed) === expected && Object.getPrototypeOf(before) === expected &&
        \\  Object.getPrototypeOf(growable) === expected && Object.getPrototypeOf(fixed) === expected &&
        \\  Object.getPrototypeOf(grown) === expected && growable.growable && grown.byteLength === 131072;
    , false, true);
}
