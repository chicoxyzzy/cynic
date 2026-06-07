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

// ── namespace + constructor shape ───────────────────────────────────

// An `(f32,f32)->f32` adder exported as "add".
const f32_adder_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,125,125,1,125, 3,2,1,0, 7,7,1,3,97,100,100,0,0, 10,9,1,7,0,32,0,32,1,146,11])";

// An `(i32,i32)->i32` signed divide exported as "div".
const div_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,127,127,1,127, 3,2,1,0, 7,7,1,3,100,105,118,0,0, 10,9,1,7,0,32,0,32,1,109,11])";

// `(func (export "f") unreachable)`.
const trap_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,4,1,96,0,0, 3,2,1,0, 7,5,1,1,102,0,0, 10,5,1,3,0,0,11])";

// Recursive `fib(i32)->i32` exported as "fib".
const fib_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,6,1,96,1,127,1,127, 3,2,1,0, 7,7,1,3,102,105,98,0,0, 10,30,1,28,0,32,0,65,2,72,4,127,32,0,5,32,0,65,1,107,16,0,32,0,65,2,107,16,0,106,11,11])";

// `(i64,i64)->i64` adder exported as "add".
const i64_adder_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,126,126,1,126, 3,2,1,0, 7,7,1,3,97,100,100,0,0, 10,9,1,7,0,32,0,32,1,124,11])";

// Two `(i32,i32)->i32` functions: "add" (func 0) and "sub" (func 1).
const multi_export_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,127,127,1,127, 3,3,2,0,0, 7,13,2,3,97,100,100,0,0,3,115,117,98,0,1, 10,17,2,7,0,32,0,32,1,106,11,7,0,32,0,32,1,107,11])";

test "the WebAssembly namespace has the expected shape" {
    try expectIntWasm("typeof WebAssembly === 'object' ? 1 : 0", 1);
    try expectIntWasm("typeof WebAssembly.validate === 'function' ? 1 : 0", 1);
    try expectIntWasm("typeof WebAssembly.Module === 'function' && typeof WebAssembly.Instance === 'function' ? 1 : 0", 1);
    try expectIntWasm("Object.prototype.toString.call(WebAssembly) === '[object WebAssembly]' ? 1 : 0", 1);
}

test "an exported function is a real function with name and arity" {
    const src =
        "const i = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        "(typeof i.exports.add === 'function' && i.exports.add.length === 2 && i.exports.add.name === 'add') ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "the exports object is stable across accesses" {
    const src =
        "const i = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        "i.exports === i.exports ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "one module exports several functions" {
    const src =
        "const i = new WebAssembly.Instance(new WebAssembly.Module(" ++ multi_export_bytes ++ "));" ++
        "i.exports.add(10, 3) * 100 + i.exports.sub(10, 3)";
    try expectIntWasm(src, 1307); // add=13, sub=7
}

// ── marshalling edge cases ──────────────────────────────────────────

test "i32 arguments wrap modulo 2^32 (ToInt32)" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ ")).exports.add;" ++
        "a(4294967296 + 1, 0)"; // 2^32 + 1 -> ToInt32 -> 1
    try expectIntWasm(src, 1);
}

test "missing arguments default to zero; extra arguments are ignored" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ ")).exports.add;" ++
        "a() * 1000 + a(2, 3, 99, 100)"; // a()=0, a(2,3,..)=5
    try expectIntWasm(src, 5);
}

test "f32 export narrows precision to single" {
    // 0.1 is not representable in f32, so the result differs from 0.1.
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ f32_adder_bytes ++ ")).exports.add;" ++
        "(a(0.5, 0.25) === 0.75 && Math.abs(a(0.1, 0) - 0.1) > 1e-9) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "f64 export passes Infinity and NaN through" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ f64_adder_bytes ++ ")).exports.add;" ++
        "(a(Infinity, 1) === Infinity && Number.isNaN(a(NaN, 1))) ? 1 : 0";
    try expectIntWasm(src, 1);
}

// ── traps + errors propagate as JS exceptions ───────────────────────

test "a trap (divide by zero) throws into JS" {
    const src =
        "const d = new WebAssembly.Instance(new WebAssembly.Module(" ++ div_bytes ++ ")).exports.div;" ++
        "(d(6, 2) === 3) && (() => { try { d(1, 0); return 0 } catch (e) { return 1 } })() ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "an unreachable trap throws into JS" {
    const src =
        "const f = new WebAssembly.Instance(new WebAssembly.Module(" ++ trap_bytes ++ ")).exports.f;" ++
        "try { f(); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "recursion runs across the JS boundary" {
    const src =
        "const fib = new WebAssembly.Instance(new WebAssembly.Module(" ++ fib_bytes ++ ")).exports.fib;" ++
        "fib(10) * 1000 + fib(13)"; // 55, 233
    try expectIntWasm(src, 55233);
}

test "calling an i64 export throws (BigInt marshalling not yet supported)" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_adder_bytes ++ ")).exports.add;" ++
        "try { a(1n, 2n); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

// ── constructor error paths ─────────────────────────────────────────

test "new Module rejects a non-BufferSource argument" {
    try expectIntWasm("try { new WebAssembly.Module('not bytes'); 0 } catch (e) { 1 }", 1);
}

test "new Module rejects bytes that do not validate" {
    try expectIntWasm("try { new WebAssembly.Module(new Uint8Array([0,1,2,3])); 0 } catch (e) { 1 }", 1);
}

test "new Instance rejects a non-Module argument" {
    try expectIntWasm("try { new WebAssembly.Instance({}); 0 } catch (e) { 1 }", 1);
}

test "two instances of one module are independent objects" {
    const src =
        "const m = new WebAssembly.Module(" ++ adder_bytes ++ ");" ++
        "const a = new WebAssembly.Instance(m), b = new WebAssembly.Instance(m);" ++
        "(a !== b && a.exports !== b.exports && a.exports.add(1, 1) === 2 && b.exports.add(2, 2) === 4) ? 1 : 0";
    try expectIntWasm(src, 1);
}

// ── validate BufferSource variants ──────────────────────────────────

test "validate accepts a plain ArrayBuffer" {
    const src =
        "const u = " ++ adder_bytes ++ "; WebAssembly.validate(u.buffer) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "validate honours a typed-array view offset" {
    // Prepend two junk bytes, then view the module through a subarray.
    const src =
        "const u = " ++ adder_bytes ++ ";" ++
        "const padded = new Uint8Array(u.length + 2);" ++
        "padded.set(u, 2);" ++
        "WebAssembly.validate(padded.subarray(2)) ? 1 : 0";
    try expectIntWasm(src, 1);
}
