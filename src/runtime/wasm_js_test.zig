//! JS-API coverage for `WebAssembly.*` (docs/wasm-engine.md §8) — the
//! host surface over the Sarcasm engine: `validate`, the `Module` /
//! `Instance` constructors gated behind `--allow=wasm`, and an
//! instance's callable function exports with numeric marshalling.
//!
//! Modules are written as raw byte arrays in the JS source (a
//! `Uint8Array`), the same shape `WebAssembly.validate` / `new Module`
//! accept from real callers.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

/// Evaluate `source` against a realm with the wasm gate open.
fn evalWasm(source: []const u8) !Value {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm = true;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => error.WasmThrewUnexpectedly,
    };
}

/// Evaluate `source` with the gate CLOSED and assert it throws.
fn evalWasmExpectThrow(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    // allow_wasm stays false (the default).
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    switch (outcome) {
        .thrown => {},
        else => return error.ExpectedThrow,
    }
}

fn expectIntWasm(source: []const u8, want: i32) !void {
    const v = try evalWasm(source);
    if (!v.isInt32()) return error.ResultNotInt;
    try testing.expectEqual(want, v.asInt32());
}

fn expectDoubleWasm(source: []const u8, want: f64) !void {
    const v = try evalWasm(source);
    const got: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else if (v.isDouble()) v.asDouble() else return error.ResultNotNumber;
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

// An `(i32,i32)->i32` adder exported as "add".
const adder_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,127,127,1,127, 3,2,1,0, 7,7,1,3,97,100,100,0,0, 10,9,1,7,0,32,0,32,1,106,11])";

// An `(f64,f64)->f64` adder exported as "add".
const f64_adder_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,124,124,1,124, 3,2,1,0, 7,7,1,3,97,100,100,0,0, 10,9,1,7,0,32,0,32,1,160,11])";

test "WebAssembly.validate accepts a well-formed module" {
    try expectIntWasm("WebAssembly.validate(" ++ adder_bytes ++ ") ? 1 : 0", 1);
}

test "WebAssembly.validate rejects garbage" {
    try expectIntWasm("WebAssembly.validate(new Uint8Array([0,1,2,3,4,5,6,7])) ? 1 : 0", 0);
}

test "new WebAssembly.Module + Instance exposes callable i32 exports" {
    const src =
        "const m = new WebAssembly.Module(" ++ adder_bytes ++ ");" ++
        "const inst = new WebAssembly.Instance(m);" ++
        "inst.exports.add(2, 3)";
    try expectIntWasm(src, 5);
}

test "exported i32 function handles negative results" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        "inst.exports.add(2, -3)";
    try expectIntWasm(src, -1);
}

test "exported i32 function coerces its arguments (ToInt32)" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        "inst.exports.add(2.9, '3')"; // 2.9 -> 2 (ToInt32), '3' -> 3
    try expectIntWasm(src, 5);
}

test "exported f64 function marshals doubles" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ f64_adder_bytes ++ "));" ++
        "inst.exports.add(1.5, 2.25)";
    try expectDoubleWasm(src, 3.75);
}

test "a void export returns undefined" {
    // (func (export \"f\")) — empty body, no params, no results.
    const src =
        "const bytes = new Uint8Array([0,97,115,109,1,0,0,0, 1,4,1,96,0,0, 3,2,1,0, 7,5,1,1,102,0,0, 10,4,1,2,0,11]);" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes));" ++
        "inst.exports.f() === undefined ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "a multi-value export returns an array" {
    // (func (export \"f\") (result i32 i32) i32.const 7 i32.const 9)
    const src =
        "const bytes = new Uint8Array([0,97,115,109,1,0,0,0, 1,6,1,96,0,2,127,127, 3,2,1,0, 7,5,1,1,102,0,0, 10,8,1,6,0,65,7,65,9,11]);" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes));" ++
        "const r = inst.exports.f(); r[0] * 100 + r[1]";
    try expectIntWasm(src, 709);
}

test "the exports object has a null prototype" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        "Object.getPrototypeOf(inst.exports) === null ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "Module / Instance are gated behind --allow=wasm" {
    try evalWasmExpectThrow("new WebAssembly.Module(" ++ adder_bytes ++ ")");
}

test "validate stays ungated (no allow=wasm needed)" {
    // With the gate closed, validate must still work (it builds nothing).
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, "WebAssembly.validate(" ++ adder_bytes ++ ") ? 1 : 0");
    switch (outcome) {
        .value => |v| try testing.expectEqual(@as(i32, 1), v.asInt32()),
        else => return error.Unexpected,
    }
}

test "instantiating a module with imports is rejected for now" {
    // (import \"e\" \"f\" (func)) — imports aren't wired yet.
    const src =
        "const bytes = new Uint8Array([0,97,115,109,1,0,0,0, 1,4,1,96,0,0, 2,5,1,1,101,1,102,0,0]);" ++
        "try { new WebAssembly.Instance(new WebAssembly.Module(bytes)); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}
