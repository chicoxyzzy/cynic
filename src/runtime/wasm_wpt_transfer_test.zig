//! Wasm JS API §5.3 and ECMA-262 ArrayBufferCopyAndDetach: borrowed
//! linear memory cannot be detached by ordinary JavaScript transfer.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(source: []const u8, hardened: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
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

const throws =
    \\function throwsType(f, type) { try { f(); } catch (e) { return e instanceof type; } return false; }
;

test "WPT buffer transfer: Wasm-owned storage rejects transfer in both postures" {
    for ([_]bool{ false, true }) |hardened| try expectTrue(throws ++
        \\let ok = true;
        \\for (const method of ["transfer", "transferToFixedLength"]) {
        \\  const memory = new WebAssembly.Memory({initial: 0, maximum: 2});
        \\  const buffer = memory.buffer;
        \\  ok = throwsType(() => buffer[method](), TypeError) && ok;
        \\  ok = !buffer.detached && memory.buffer === buffer && ok;
        \\}
        \\ok;
    , hardened);
}

test "WPT buffer transfer: Wasm detach protection follows length coercion" {
    try expectTrue(throws ++
        \\let ok = true;
        \\for (const method of ["transfer", "transferToFixedLength"]) {
        \\  const memory = new WebAssembly.Memory({initial: 0, maximum: 1});
        \\  const buffer = memory.buffer;
        \\  let calls = 0;
        \\  ok = throwsType(() => buffer[method]({valueOf() { calls++; __collectGarbage(); return 0; }}), TypeError) && ok;
        \\  ok = throwsType(() => buffer[method](-1), RangeError) && ok;
        \\  ok = throwsType(() => buffer[method]({valueOf() { throw new SyntaxError(); }}), SyntaxError) && ok;
        \\  ok = calls === 1 && !buffer.detached && ok;
        \\}
        \\ok;
    , false);
}

test "WPT buffer transfer: coercion detachment is checked again before copying" {
    try expectTrue(throws ++
        \\let ok = true;
        \\for (const method of ["transfer", "transferToFixedLength"]) {
        \\  const buffer = new ArrayBuffer(0);
        \\  ok = throwsType(() => buffer[method]({valueOf() { buffer.transfer(); __collectGarbage(); return 0; }}), TypeError) && ok;
        \\  ok = buffer.detached && ok;
        \\  let calls = 0;
        \\  ok = throwsType(() => buffer[method]({valueOf() { calls++; return -1; }}), RangeError) && ok;
        \\  ok = calls === 1 && ok;
        \\}
        \\ok;
    , false);
}

test "WPT buffer transfer: resized source is reloaded after coercion" {
    for ([_]bool{ false, true }) |hardened| try expectTrue(
        \\let ok = true;
        \\for (const method of ["transfer", "transferToFixedLength"]) {
        \\  const buffer = new ArrayBuffer(0, {maxByteLength: 16});
        \\  const output = buffer[method]({valueOf() {
        \\    buffer.resize(8); new Uint8Array(buffer)[0] = 73; __collectGarbage(); return 8;
        \\  }});
        \\  ok = buffer.detached && output.byteLength === 8 && new Uint8Array(output)[0] === 73 && ok;
        \\}
        \\ok;
    , hardened);
}

test "WPT buffer transfer: detached sources retain resizable metadata" {
    for ([_]bool{ false, true }) |hardened| try expectTrue(
        \\let ok = true;
        \\for (const method of ["transfer", "transferToFixedLength"]) {
        \\  const buffer = new ArrayBuffer(4, {maxByteLength: 8});
        \\  const output = buffer[method]();
        \\  ok = buffer.detached && buffer.resizable && buffer.byteLength === 0 && buffer.maxByteLength === 0 && ok;
        \\  ok = output.resizable === (method === "transfer") && ok;
        \\}
        \\ok;
    , hardened);
}
