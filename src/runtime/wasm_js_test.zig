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

/// Run an async `setup` that stashes a result on `globalThis.__r`, drain
/// the microtask queue (settling the promise reactions), then read it.
fn expectIntWasmAsync(setup: []const u8, want: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm = true;
    realm.hardened = false; // the .then callback writes globalThis.__r
    try realm.installBuiltins();
    _ = try lantern.evaluateScript(testing.allocator, &realm, setup);
    try lantern.drainMicrotasks(testing.allocator, &realm);
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, "globalThis.__r");
    const v = switch (outcome) {
        .value, .yielded => |x| x,
        .thrown => return error.WasmThrewUnexpectedly,
    };
    if (!v.isInt32()) return error.ResultNotInt;
    try testing.expectEqual(want, v.asInt32());
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

test "an i64 export adds two BigInts" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_adder_bytes ++ ")).exports.add;" ++
        "a(40n, 2n) === 42n ? 1 : 0";
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

// ── i64 ↔ BigInt marshalling ────────────────────────────────────────

test "i64 exports marshal through BigInt" {
    const i64adder = "new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_adder_bytes ++ ")).exports.add";
    try expectIntWasm("const a = " ++ i64adder ++ "; a(5n, 7n) === 12n ? 1 : 0", 1);
    try expectIntWasm("const a = " ++ i64adder ++ "; typeof a(1n, 2n) === 'bigint' ? 1 : 0", 1);
}

test "i64 results wrap to a signed 64-bit BigInt" {
    // 2^63 has no positive i64; it wraps to i64::MIN.
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_adder_bytes ++ ")).exports.add;" ++
        "a(9223372036854775808n, 0n) === -9223372036854775808n ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "an i64 argument must be a BigInt, not a Number" {
    const src =
        "const a = new WebAssembly.Instance(new WebAssembly.Module(" ++ i64_adder_bytes ++ ")).exports.add;" ++
        "try { a(5, 7); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

// ── WebAssembly.Global ──────────────────────────────────────────────

// Exports a mutable i32 global "g" (init 42) and a getter "get".
const global_module_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,2,1,0, 6,6,1,127,1,65,42,11, 7,11,2,1,103,3,0,3,103,101,116,0,0, 10,6,1,4,0,35,0,11])";

test "WebAssembly.Global is a constructor" {
    try expectIntWasm("typeof WebAssembly.Global === 'function' ? 1 : 0", 1);
}

test "an immutable Global holds its value" {
    try expectIntWasm("new WebAssembly.Global({ value: 'i32' }, 42).value === 42 ? 1 : 0", 1);
    try expectIntWasm("new WebAssembly.Global({ value: 'i32' }).value === 0 ? 1 : 0", 1); // default 0
}

test "a mutable Global round-trips through value get/set" {
    const src =
        "const g = new WebAssembly.Global({ value: 'i32', mutable: true }, 1);" ++
        "g.value = 99; g.value === 99 ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "writing an immutable Global throws" {
    const src =
        "const g = new WebAssembly.Global({ value: 'i32' }, 1);" ++
        "try { g.value = 2; 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "Global supports every numeric value type" {
    try expectIntWasm("new WebAssembly.Global({ value: 'i64' }, 7n).value === 7n ? 1 : 0", 1);
    try expectIntWasm("new WebAssembly.Global({ value: 'f32' }, 1.5).value === 1.5 ? 1 : 0", 1);
    try expectIntWasm("new WebAssembly.Global({ value: 'f64' }, 3.25).value === 3.25 ? 1 : 0", 1);
}

test "an unknown Global value type throws" {
    try expectIntWasm("try { new WebAssembly.Global({ value: 'i128' }, 0); 0 } catch (e) { 1 }", 1);
}

test "an exported global is a WebAssembly.Global reading the live cell" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ global_module_bytes ++ "));" ++
        "(inst.exports.g instanceof WebAssembly.Global && inst.exports.g.value === 42) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "writing an exported mutable global is visible to wasm" {
    // Set the global through the JS Global object; a wasm function that
    // reads the same global must observe the new value.
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ global_module_bytes ++ "));" ++
        "inst.exports.g.value = 100;" ++
        "inst.exports.get()"; // global.get 0
    try expectIntWasm(src, 100);
}

// ── WebAssembly.Table ───────────────────────────────────────────────

// Exports a funcref table "tbl" (size 1), a function "f" (→ 42), and a
// "callIndirect" that does call_indirect through table index 0.
const table_module_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,3,2,0,0, 4,4,1,112,0,1, 7,26,3,1,102,0,0,3,116,98,108,1,0,12,99,97,108,108,73,110,100,105,114,101,99,116,0,1, 10,14,2,4,0,65,42,11,7,0,65,0,17,0,0,11])";

// An exported "f" that returns 7, for filling tables from JS.
const f7_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,2,1,0, 7,5,1,1,102,0,0, 10,6,1,4,0,65,7,11])";

test "WebAssembly.Table is a constructor" {
    try expectIntWasm("typeof WebAssembly.Table === 'function' ? 1 : 0", 1);
}

test "a fresh anyfunc table has the requested length and null entries" {
    const src =
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 3 });" ++
        "(t.length === 3 && t.get(0) === null && t.get(2) === null) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "table.get out of bounds throws" {
    const src =
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 1 });" ++
        "try { t.get(5); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "table.set stores an exported function that is callable via get" {
    const src =
        "const f = new WebAssembly.Instance(new WebAssembly.Module(" ++ f7_bytes ++ ")).exports.f;" ++
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 2 });" ++
        "t.set(1, f); t.get(1)()"; // → 7
    try expectIntWasm(src, 7);
}

test "table.set rejects a non-function value" {
    const src =
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 1 });" ++
        "try { t.set(0, 123); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "table.grow extends the table and returns the old length" {
    const src =
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 2 });" ++
        "const old = t.grow(3);" ++
        "(old === 2 && t.length === 5 && t.get(4) === null) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "table.grow past the maximum throws" {
    const src =
        "const t = new WebAssembly.Table({ element: 'anyfunc', initial: 1, maximum: 2 });" ++
        "try { t.grow(5); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "an externref table holds and returns JS values" {
    const src =
        "const t = new WebAssembly.Table({ element: 'externref', initial: 2 });" ++
        "const o = { tag: 42 };" ++
        "t.set(1, o);" ++
        "(t.length === 2 && t.get(0) === null && t.get(1) === o && t.get(1).tag === 42) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "an externref held in a table survives GC with identity intact" {
    // The marquee GC test: a JS object stored as an externref must be
    // kept alive (pinned as a root) across collection, and — the GC being
    // non-moving — return with identity preserved.
    const src =
        "const t = new WebAssembly.Table({ element: 'externref', initial: 1 });" ++
        "const o = { tag: 99 };" ++
        "t.set(0, o);" ++
        "for (let i = 0; i < 400000; i++) { const x = { y: i }; void x; }" ++ // force GC cycles
        "(t.get(0) === o && t.get(0).tag === 99) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "an externref Global holds a JS value" {
    const src =
        "const o = { v: 5 };" ++
        "const g = new WebAssembly.Global({ value: 'externref' }, o);" ++
        "(g.value === o && new WebAssembly.Global({ value: 'externref' }).value === null) ? 1 : 0";
    try expectIntWasm(src, 1);
}

// imports env.id (externref)->externref; exports run(externref)->externref = id(x).
const extern_id_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,6,1,96,1,111,1,111, 2,10,1,3,101,110,118,2,105,100,0,0, 3,2,1,0, 7,7,1,3,114,117,110,0,1, 10,8,1,6,0,32,0,16,0,11])";

test "an externref round-trips JS -> wasm -> host -> wasm -> JS" {
    const src =
        "const o = { id: 7 };" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ extern_id_bytes ++ "), { env: { id: (x) => x } });" ++
        "inst.exports.run(o) === o ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "an exported table is a WebAssembly.Table over the live table" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ table_module_bytes ++ "));" ++
        "(inst.exports.tbl instanceof WebAssembly.Table && inst.exports.tbl.length === 1) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "a function set into a table from JS is callable by wasm call_indirect" {
    // The marquee test: JS writes an exported function into the shared
    // table; a wasm `call_indirect` through that table then runs it.
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ table_module_bytes ++ "));" ++
        "inst.exports.tbl.set(0, inst.exports.f);" ++
        "inst.exports.callIndirect()"; // call_indirect 0 -> f -> 42
    try expectIntWasm(src, 42);
}

// ── WebAssembly.Memory ──────────────────────────────────────────────

// Exports a memory "mem", a "store"(addr,val) and a "load"(addr).
const memory_module_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,11,2,96,2,127,127,0,96,1,127,1,127, 3,3,2,0,1, 5,3,1,0,1, 7,22,3,3,109,101,109,2,0,5,115,116,111,114,101,0,0,4,108,111,97,100,0,1, 10,19,2,9,0,32,0,32,1,54,2,0,11,7,0,32,0,40,2,0,11])";

test "WebAssembly.Memory is a constructor" {
    try expectIntWasm("typeof WebAssembly.Memory === 'function' ? 1 : 0", 1);
}

test "a fresh Memory exposes a zeroed ArrayBuffer of the right size" {
    const src =
        "const m = new WebAssembly.Memory({ initial: 1 });" ++
        "(m.buffer instanceof ArrayBuffer && m.buffer.byteLength === 65536 && new Uint8Array(m.buffer)[0] === 0) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "Memory.buffer is cached (same object across accesses)" {
    try expectIntWasm("const m = new WebAssembly.Memory({ initial: 1 }); m.buffer === m.buffer ? 1 : 0", 1);
}

test "a JS write to Memory.buffer is visible to a wasm load" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ memory_module_bytes ++ "));" ++
        "new Uint8Array(inst.exports.mem.buffer)[0] = 42;" ++
        "inst.exports.load(0)"; // i32.load at 0 -> 42
    try expectIntWasm(src, 42);
}

test "a wasm store is visible through Memory.buffer" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ memory_module_bytes ++ "));" ++
        "inst.exports.store(4, 7);" ++ // i32.store 7 at address 4
        "new Uint8Array(inst.exports.mem.buffer)[4]"; // low byte = 7
    try expectIntWasm(src, 7);
}

test "an exported memory is a WebAssembly.Memory" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ memory_module_bytes ++ "));" ++
        "inst.exports.mem instanceof WebAssembly.Memory ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "Memory.grow returns the old page count and resizes the buffer" {
    const src =
        "const m = new WebAssembly.Memory({ initial: 1, maximum: 3 });" ++
        "const old = m.grow(1);" ++
        "(old === 1 && m.buffer.byteLength === 131072) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "Memory.grow detaches the previous buffer" {
    const src =
        "const m = new WebAssembly.Memory({ initial: 1 });" ++
        "const b = m.buffer; m.grow(1);" ++
        "(b.byteLength === 0 && m.buffer.byteLength === 131072) ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "Memory.grow past the maximum throws" {
    const src =
        "const m = new WebAssembly.Memory({ initial: 1, maximum: 1 });" ++
        "try { m.grow(1); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

test "growing an exported memory keeps wasm and JS in sync" {
    // Grow from JS, then store from wasm into the new region and read it
    // back through the fresh buffer.
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ memory_module_bytes ++ "));" ++
        "inst.exports.mem.grow(1);" ++ // now 2 pages
        "inst.exports.store(70000, 9);" ++ // address in the new page
        "new Uint8Array(inst.exports.mem.buffer)[70000]";
    try expectIntWasm(src, 9);
}

// ── imports ─────────────────────────────────────────────────────────

// imports env.add (i32,i32)->i32; exports run(i32,i32)->i32 = add(a,b).
const host_add_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,7,1,96,2,127,127,1,127, 2,11,1,3,101,110,118,3,105,109,112,0,0, 3,2,1,0, 7,7,1,3,114,117,110,0,1, 10,10,1,8,0,32,0,32,1,16,0,11])";

// imports env.f ()->i32; exports run()->i32 = f().
const consumer_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 2,9,1,3,101,110,118,1,102,0,0, 3,2,1,0, 7,7,1,3,114,117,110,0,1, 10,6,1,4,0,16,0,11])";

// imports env.g (global i32); exports get()->i32 = global.get 0.
const global_import_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 2,10,1,3,101,110,118,1,103,3,127,0, 3,2,1,0, 7,7,1,3,103,101,116,0,0, 10,6,1,4,0,35,0,11])";

// imports env.mem (memory 1); exports load(addr)->i32.
const mem_import_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,6,1,96,1,127,1,127, 2,12,1,3,101,110,118,3,109,101,109,2,0,1, 3,2,1,0, 7,8,1,4,108,111,97,100,0,0, 10,9,1,7,0,32,0,40,2,0,11])";

// imports env.tbl (funcref table 1); exports callIndirect()->i32.
const table_import_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 2,13,1,3,101,110,118,3,116,98,108,1,112,0,1, 3,2,1,0, 7,16,1,12,99,97,108,108,73,110,100,105,114,101,99,116,0,0, 10,9,1,7,0,65,0,17,0,0,11])";

test "a JS function import is called by wasm with marshalled args" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ host_add_bytes ++ ")," ++
        "  { env: { imp: (a, b) => a * 10 + b } });" ++
        "inst.exports.run(3, 4)"; // run calls imp(3,4) -> 34
    try expectIntWasm(src, 34);
}

test "a GC during a host-import call does not corrupt the wasm caller" {
    // The host import allocates heavily (forcing GC cycles) before
    // returning. Mid-wasm-call GC is safe today because only numeric
    // values sit on the wasm value stack — there is no live externref to
    // lose. This locks that property in (see docs/wasm-engine.md §5/§6).
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ host_add_bytes ++ ")," ++
        "  { env: { imp: (a, b) => { for (let i = 0; i < 300000; i++) { const o = { x: i }; void o; } return a * 10 + b; } } });" ++
        "inst.exports.run(3, 4)"; // -> 34, despite GC churn inside imp
    try expectIntWasm(src, 34);
}

test "a host import that throws propagates the exception into the wasm caller" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ consumer_bytes ++ ")," ++
        "  { env: { f: () => { throw new RangeError('boom') } } });" ++
        "try { inst.exports.run(); 0 } catch (e) { (e instanceof RangeError && e.message === 'boom') ? 1 : 0 }";
    try expectIntWasm(src, 1);
}

test "an exported function from one instance imports into another (cross-module)" {
    const src =
        "const provider = new WebAssembly.Instance(new WebAssembly.Module(" ++ f7_bytes ++ "));" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ consumer_bytes ++ ")," ++
        "  { env: { f: provider.exports.f } });" ++
        "inst.exports.run()"; // run -> provider.f -> 7
    try expectIntWasm(src, 7);
}

test "a WebAssembly.Global import is read by wasm" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ global_import_bytes ++ ")," ++
        "  { env: { g: new WebAssembly.Global({ value: 'i32' }, 77) } });" ++
        "inst.exports.get()"; // global.get 0 -> 77
    try expectIntWasm(src, 77);
}

test "a Number import fills an i32 global" {
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ global_import_bytes ++ ")," ++
        "  { env: { g: 55 } });" ++
        "inst.exports.get()";
    try expectIntWasm(src, 55);
}

test "a WebAssembly.Memory import is used by wasm" {
    // Write before instantiation; wasm reads the imported bytes.
    const src =
        "const mem = new WebAssembly.Memory({ initial: 1 });" ++
        "new Uint8Array(mem.buffer)[0] = 99;" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ mem_import_bytes ++ "), { env: { mem } });" ++
        "inst.exports.load(0)"; // -> 99
    try expectIntWasm(src, 99);
}

test "an imported memory is shared: a post-instantiation JS write reaches wasm" {
    // The snapshot model would miss this — the write lands after the
    // instance is built, so it only reaches wasm if the bytes are shared.
    const src =
        "const mem = new WebAssembly.Memory({ initial: 1 });" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ mem_import_bytes ++ "), { env: { mem } });" ++
        "new Uint8Array(mem.buffer)[8] = 123;" ++ // write AFTER instantiation
        "inst.exports.load(8)"; // -> 123 only if shared
    try expectIntWasm(src, 123);
}

test "a WebAssembly.Table import drives wasm call_indirect" {
    const src =
        "const f7 = new WebAssembly.Instance(new WebAssembly.Module(" ++ f7_bytes ++ ")).exports.f;" ++
        "const tbl = new WebAssembly.Table({ element: 'anyfunc', initial: 1 });" ++
        "tbl.set(0, f7);" ++
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ table_import_bytes ++ "), { env: { tbl } });" ++
        "inst.exports.callIndirect()"; // call_indirect 0 -> f7 -> 7
    try expectIntWasm(src, 7);
}

test "instantiating an importing module without an importObject throws" {
    try expectIntWasm("try { new WebAssembly.Instance(new WebAssembly.Module(" ++ consumer_bytes ++ ")); 0 } catch (e) { 1 }", 1);
}

test "a non-callable function import throws" {
    const src =
        "try { new WebAssembly.Instance(new WebAssembly.Module(" ++ consumer_bytes ++ "), { env: { f: 123 } }); 0 } catch (e) { 1 }";
    try expectIntWasm(src, 1);
}

// ── WebAssembly.compile / instantiate (Promises) ────────────────────

test "compile and instantiate return Promises" {
    try expectIntWasm("WebAssembly.compile(" ++ adder_bytes ++ ") instanceof Promise ? 1 : 0", 1);
    try expectIntWasm("WebAssembly.instantiate(" ++ adder_bytes ++ ") instanceof Promise ? 1 : 0", 1);
}

test "compile resolves to a Module" {
    const setup =
        "WebAssembly.compile(" ++ adder_bytes ++ ").then(m => {" ++
        "  globalThis.__r = (m instanceof WebAssembly.Module) ? 1 : 0; });";
    try expectIntWasmAsync(setup, 1);
}

test "instantiate(bytes) resolves to a module/instance pair" {
    const setup =
        "WebAssembly.instantiate(" ++ adder_bytes ++ ").then(res => {" ++
        "  globalThis.__r = (res.module instanceof WebAssembly.Module && res.instance instanceof WebAssembly.Instance)" ++
        "    ? res.instance.exports.add(2, 3) : -1; });";
    try expectIntWasmAsync(setup, 5);
}

test "instantiate(module) resolves to an Instance" {
    const setup =
        "const m = new WebAssembly.Module(" ++ adder_bytes ++ ");" ++
        "WebAssembly.instantiate(m).then(inst => {" ++
        "  globalThis.__r = (inst instanceof WebAssembly.Instance) ? inst.exports.add(4, 5) : -1; });";
    try expectIntWasmAsync(setup, 9);
}

test "instantiate threads an importObject" {
    const setup =
        "WebAssembly.instantiate(" ++ consumer_bytes ++ ", { env: { f: () => 7 } }).then(res => {" ++
        "  globalThis.__r = res.instance.exports.run(); });";
    try expectIntWasmAsync(setup, 7);
}

test "compile rejects invalid bytes" {
    const setup =
        "WebAssembly.compile(new Uint8Array([0,1,2,3])).then(" ++
        "  () => { globalThis.__r = 0; }," ++
        "  (e) => { globalThis.__r = 1; });";
    try expectIntWasmAsync(setup, 1);
}

// ── CompileError / LinkError / RuntimeError ─────────────────────────

test "the wasm error types are Error subclasses on the namespace" {
    try expectIntWasm("typeof WebAssembly.CompileError === 'function' && typeof WebAssembly.LinkError === 'function' && typeof WebAssembly.RuntimeError === 'function' ? 1 : 0", 1);
    const src =
        "const e = new WebAssembly.CompileError('boom');" ++
        "(e instanceof WebAssembly.CompileError && e instanceof Error && e.message === 'boom' && e.name === 'CompileError') ? 1 : 0";
    try expectIntWasm(src, 1);
}

test "invalid module bytes throw a CompileError" {
    const src =
        "try { new WebAssembly.Module(new Uint8Array([0,1,2,3])); 0 }" ++
        "catch (e) { (e instanceof WebAssembly.CompileError) ? 1 : 0 }";
    try expectIntWasm(src, 1);
}

test "a bad import throws a LinkError" {
    const src =
        "try { new WebAssembly.Instance(new WebAssembly.Module(" ++ consumer_bytes ++ "), { env: { f: 123 } }); 0 }" ++
        "catch (e) { (e instanceof WebAssembly.LinkError) ? 1 : 0 }";
    try expectIntWasm(src, 1);
}

test "a wasm trap throws a RuntimeError" {
    const src =
        "const d = new WebAssembly.Instance(new WebAssembly.Module(" ++ div_bytes ++ ")).exports.div;" ++
        "try { d(1, 0); 0 } catch (e) { (e instanceof WebAssembly.RuntimeError) ? 1 : 0 }";
    try expectIntWasm(src, 1);
}

test "compile rejects with a CompileError" {
    const setup =
        "WebAssembly.compile(new Uint8Array([0,1,2,3])).then(" ++
        "  () => { globalThis.__r = 0; }," ++
        "  (e) => { globalThis.__r = (e instanceof WebAssembly.CompileError) ? 1 : 0; });";
    try expectIntWasmAsync(setup, 1);
}

// ── v128 across the JS boundary (spec-mandated TypeError) ───────────

// (func (export "f") (result v128) v128.const 0).
const v128_result_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,123, 3,2,1,0, 7,5,1,1,102,0,0, 10,22,1,20,0,253,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11])";

test "a v128 result cannot cross the JS boundary" {
    // §ToJSValue throws a TypeError for v128 — calling a v128-returning
    // export from JS is spec-mandated to fail (v128 works inside wasm).
    const src =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ v128_result_bytes ++ "));" ++
        "try { inst.exports.f(); 0 } catch (e) { (e instanceof TypeError) ? 1 : 0 }";
    try expectIntWasm(src, 1);
}

test "a v128 Global cannot be constructed from JS" {
    try expectIntWasm("try { new WebAssembly.Global({ value: 'v128' }); 0 } catch (e) { (e instanceof TypeError) ? 1 : 0 }", 1);
}

// ── externref precise reclaim (no retain-until-teardown leak) ───────

/// Like `expectIntWasmAsync` but installs the test globals
/// (`__collectGarbage` / `__clearKeptObjects`) so a `WeakRef` can observe
/// collection deterministically.
fn expectIntWasmGc(setup: []const u8, want: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm = true;
    realm.hardened = false; // the script writes globalThis.__r
    try realm.installBuiltins();
    try realm.installTestGlobals();
    _ = try lantern.evaluateScript(testing.allocator, &realm, setup);
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, "globalThis.__r");
    const v = switch (outcome) {
        .value, .yielded => |x| x,
        .thrown => return error.WasmThrewUnexpectedly,
    };
    if (!v.isInt32()) return error.ResultNotInt;
    try testing.expectEqual(want, v.asInt32());
}

// (func (export "f") (param externref)) — takes an externref and drops it.
const extern_drop_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0, 1,5,1,96,1,111,0, 3,2,1,0, 7,5,1,1,102,0,0, 10,4,1,2,0,11])";

test "an externref dropped by a wasm call is reclaimed" {
    // The marquee reclaim test: a JS object passed to wasm (pinned only
    // transiently) is collected once the call returns and JS drops it —
    // no retain-until-teardown leak.
    const setup =
        "const inst = new WebAssembly.Instance(new WebAssembly.Module(" ++ extern_drop_bytes ++ "));" ++
        "let wr;" ++
        "(function () { const o = { tag: 1 }; wr = new WeakRef(o); inst.exports.f(o); })();" ++
        "__clearKeptObjects(); __collectGarbage();" ++
        "globalThis.__r = (wr.deref() === undefined) ? 1 : 0;";
    try expectIntWasmGc(setup, 1);
}

test "overwriting an externref table slot reclaims the old value" {
    const setup =
        "const t = new WebAssembly.Table({ element: 'externref', initial: 1 });" ++
        "let wr;" ++
        "(function () { const o = {}; wr = new WeakRef(o); t.set(0, o); })();" ++
        "t.set(0, null);" ++ // drop the only reference held by wasm
        "__clearKeptObjects(); __collectGarbage();" ++
        "globalThis.__r = (wr.deref() === undefined) ? 1 : 0;";
    try expectIntWasmGc(setup, 1);
}

test "an externref still in a table survives an explicit GC" {
    const setup =
        "const t = new WebAssembly.Table({ element: 'externref', initial: 1 });" ++
        "const o = { tag: 5 };" ++
        "t.set(0, o);" ++
        "__clearKeptObjects(); __collectGarbage();" ++
        "globalThis.__r = (t.get(0) === o && t.get(0).tag === 5) ? 1 : 0;";
    try expectIntWasmGc(setup, 1);
}
