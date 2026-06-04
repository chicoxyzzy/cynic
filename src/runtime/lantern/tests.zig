//! Tests for the bytecode interpreter — extracted from
//! `interpreter.zig` to keep the dispatch loop module focused
//! on production code (the host file dropped from ~5,960 to
//! ~3,730 lines after this split). All tests run end-to-end:
//! parse → compile → run → assert on the resulting `Value`.

const std = @import("std");
const testing = std.testing;

const lantern = @import("interpreter.zig");
const RunResult = lantern.RunResult;
const run = lantern.run;
const evaluateScript = lantern.evaluateScript;
const op_mod = @import("../../bytecode/op.zig");
const chunk_mod = @import("../../bytecode/chunk.zig");
const disasm = @import("../../bytecode/disasm.zig");
const Span = @import("../../source.zig").Span;

/// Compile `source` and disassemble the resulting chunk. Caller
/// owns the returned slice. Used by the fused counter-loop tests
/// to assert whether the `LoopIncLt` opcode shows up in the
/// emitted bytecode.
fn compileAndDisassemble(realm: *Realm, source: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    var chunk = try compileScriptAsChunk(testing.allocator, realm, &program, source, null);
    defer chunk.deinit(testing.allocator);
    return disasm.dump(testing.allocator, &chunk);
}

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const Realm = @import("../realm.zig").Realm;
const features = @import("../features.zig");
const parser_mod = @import("../../parser/parser.zig");
const compiler_mod = @import("../../bytecode/compiler.zig");
const compileExpressionAsChunk = compiler_mod.compileExpressionAsChunk;
const compileScriptAsChunk = compiler_mod.compileScriptAsChunk;
const cynic_diag = @import("../../diagnostic.zig");

/// Unit tests run against the full engine surface — every gated
/// pre-Stage-4 proposal is enabled. Embedders / the `cynic` CLI
/// default to all-off; the test262 harness independently flips
/// everything on. This helper centralises the "install builtins
/// with every feature" pattern shared by every `*WithBuiltins`
/// helper below.
fn installBuiltinsAllFeatures(realm: *Realm) !void {
    realm.feature_flags = features.FeatureSet.initFull();
    try realm.installBuiltins();
    // Inline unit tests deliberately use `__collectGarbage` /
    // `__clearKeptObjects` / `__drainMicrotasks` for deterministic
    // GC + microtask triggering. These are debug-only host hooks
    // that production realms (`cynic eval`, `cynic run` without
    // `--debug-globals`) deliberately don't install.
    try realm.installTestGlobals();
}

fn evaluate(realm: *Realm, source: []const u8) !Value {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    try testing.expect(program.body.len == 1);
    const stmt = program.body[0];
    try testing.expect(stmt == .expression);
    const expr = stmt.expression.expression;

    var chunk = try compileExpressionAsChunk(testing.allocator, realm, &expr, source);
    defer chunk.deinit(testing.allocator);
    const result = try run(testing.allocator, realm, &chunk);
    return switch (result) {
        .value, .yielded => |v| v,
        .thrown => error.UncaughtException,
    };
}

/// Run a full script (any number of statements) and return the
/// `RunResult`. Caller decides whether the `.thrown` branch is
/// the test's expected outcome.
fn evaluateScriptResult(realm: *Realm, source: []const u8) !RunResult {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    var chunk = try compileScriptAsChunk(testing.allocator, realm, &program, source, null);
    defer chunk.deinit(testing.allocator);
    return run(testing.allocator, realm, &chunk);
}

fn expectScriptIntWithBuiltins(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    if (v.isInt32()) try testing.expectEqual(expected, v.asInt32()) else if (v.isDouble()) try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble()) else return error.NotANumber;
}

fn expectScriptStringWithBuiltins(source: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

/// Unhardened-realm variant of `expectScriptIntWithBuiltins`. Use
/// when the test monkey-patches a primordial (e.g. installs an
/// indexed accessor on `Object.prototype`) or probes a descriptor
/// whose §17 spec attributes (`configurable: true`) the SES freeze
/// pass locks down. Skipping the freeze pass via
/// `installBuiltinsUnhardened` lets the test exercise the spec
/// shape directly.
fn expectScriptIntUnhardened(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsUnhardened(&realm);
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    if (v.isInt32()) try testing.expectEqual(expected, v.asInt32()) else if (v.isDouble()) try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble()) else return error.NotANumber;
}

/// Unhardened-realm variant of `expectScriptStringWithBuiltins`.
/// See `expectScriptIntUnhardened` for when to use this.
fn expectScriptStringUnhardened(source: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsUnhardened(&realm);
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

/// Test helper: run a script, returning the final accumulator
/// value. Throws surface as `error.UncaughtException`. The
/// public `evaluateScript` (top of file) is used directly by
/// callers that want the full `RunResult`.
fn evaluateScriptValue(realm: *Realm, source: []const u8) !Value {
    return switch (try evaluateScriptResult(realm, source)) {
        .value, .yielded => |v| v,
        .thrown => error.UncaughtException,
    };
}

fn expectScriptInt(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluateScriptValue(&realm, source);
    if (v.isInt32()) try testing.expectEqual(expected, v.asInt32()) else if (v.isDouble()) try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble()) else return error.NotANumber;
}

fn expectScriptString(source: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluateScriptValue(&realm, source);
    try testing.expect(v.isString());
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

fn expectScriptThrows(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const result = try evaluateScriptResult(&realm, source);
    switch (result) {
        .value, .yielded => return error.ExpectedThrow,
        .thrown => {}, // ok
    }
}

fn expectInt(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluate(&realm, source);
    if (v.isInt32()) {
        try testing.expectEqual(expected, v.asInt32());
    } else if (v.isDouble()) {
        try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble());
    } else {
        return error.NotANumber;
    }
}

fn expectDouble(source: []const u8, expected: f64) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluate(&realm, source);
    const d = if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
    try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(d)));
}

fn expectBool(source: []const u8, expected: bool) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluate(&realm, source);
    try testing.expect(v.isBool());
    try testing.expectEqual(expected, v.asBool());
}

fn expectString(source: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluate(&realm, source);
    try testing.expect(v.isString());
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

test "interpreter: 1 + 2 = 3 (int32 fast path)" {
    try expectInt("1 + 2;", 3);
}

test "interpreter: 1 + 2 * 3 = 7 (precedence preserved)" {
    try expectInt("1 + 2 * 3;", 7);
}

test "interpreter: double-path arithmetic" {
    // The point: when at least one operand isn't an exact i32, the
    // operation goes through the f64 path. Use an exactly-
    // representable result so the bit-equal compare doesn't trip
    // on platform-specific intermediate rounding.
    try expectDouble("1.5 + 2.5;", 4.0);
    try expectDouble("0.5 * 0.5;", 0.25);
}

test "interpreter: integer overflow falls back to double" {
    try expectDouble("2147483647 + 1;", 2147483648.0);
}

test "interpreter: subtraction" {
    try expectInt("5 - 2;", 3);
    try expectInt("1 - 2;", -1);
}

test "interpreter: division produces a double" {
    try expectDouble("1.0 / 2.0;", 0.5);
    try expectDouble("1 / 0;", std.math.inf(f64));
}

test "interpreter: modulo" {
    try expectInt("5 % 3;", 2);
}

test "interpreter: unary negate (int32)" {
    try expectInt("-1;", -1);
}

test "interpreter: bit-not" {
    try expectInt("~5;", -6);
}

test "interpreter: bitwise and / or / xor" {
    try expectInt("5 & 3;", 1);
    try expectInt("5 | 3;", 7);
    try expectInt("5 ^ 3;", 6);
}

test "interpreter: shifts" {
    try expectInt("1 << 4;", 16);
    try expectInt("16 >> 2;", 4);
    // §6.1.6.1.10 Number::unsignedRightShift returns a Number;
    // `-1 >>> 0 === 4294967295`, not -1. The high-bit-set u32
    // doesn't fit in the signed-int32 Smi representation, so the
    // result escapes to Double.
    try expectDouble("-1 >>> 0;", 4294967295.0);
}

test "interpreter: strict equality across types" {
    try expectBool("1 === 1;", true);
    try expectBool("1 === 2;", false);
    try expectBool("'a' === 'a';", true);
    try expectBool("'a' === 'b';", false);
    try expectBool("null === null;", true);
    // `undefined` is a global identifier — not addressable until later
    // adds variable lookup. `void 0` is the spec-canonical way to
    // materialise `undefined` in expression position pre-variables.
    try expectBool("null === void 0;", false);
    try expectBool("(void 0) === (void 0);", true);
}

test "interpreter: loose equality" {
    try expectBool("null == void 0;", true);
    try expectBool("1 == '1';", true);
    try expectBool("0 == false;", true);
    try expectBool("'1' == 1;", true);
}

test "interpreter: relational operators" {
    try expectBool("1 < 2;", true);
    try expectBool("2 < 1;", false);
    try expectBool("1 <= 1;", true);
    try expectBool("'a' < 'b';", true);
}

test "interpreter: NaN comparisons are false" {
    try expectBool("(0/0) < 1;", false);
    try expectBool("(0/0) > 1;", false);
    try expectBool("(0/0) === (0/0);", false);
}

test "interpreter: logical not" {
    try expectBool("!true;", false);
    try expectBool("!0;", true);
    try expectBool("!'';", true);
    try expectBool("!'x';", false);
}

test "interpreter: conditional ?:" {
    try expectInt("1 < 2 ? 10 : 20;", 10);
    try expectInt("1 > 2 ? 10 : 20;", 20);
}

test "interpreter: && returns rhs when lhs truthy" {
    try expectInt("1 && 2;", 2);
}

test "interpreter: && returns lhs when lhs falsey" {
    // §13.13: `&&` returns the LHS value (not a coerced bool) when
    // it's falsy. `0 && 2` is `0`, not `false`.
    try expectInt("0 && 2;", 0);
}

test "interpreter: || returns lhs when truthy" {
    try expectInt("1 || 2;", 1);
}

test "interpreter: || returns rhs when lhs falsey" {
    try expectInt("0 || 2;", 2);
}

test "interpreter: toBoolean covers every spec ToBoolean case" {
    // §7.1.2 ToBoolean — pins the full type-switch so the
    // arith_loop fast-path on Bool doesn't regress any case.
    // String empty-vs-nonempty, BigInt 0n-vs-nonzero, object
    // always truthy (incl. `new Boolean(false)`), numeric 0/NaN
    // falsy and anything else truthy, undefined/null falsy. Each
    // pair is read through a ternary so the result feeds the
    // jmp_if_* opcode that calls toBoolean.
    try expectScriptStringWithBuiltins(
        \\(true ? "T" : "F") + "," + (false ? "T" : "F") + "," +
        \\(undefined ? "T" : "F") + "," + (null ? "T" : "F") + "," +
        \\(0 ? "T" : "F") + "," + (-0 ? "T" : "F") + "," +
        \\(NaN ? "T" : "F") + "," + (42 ? "T" : "F") + "," +
        \\("" ? "T" : "F") + "," + ("x" ? "T" : "F") + "," +
        \\(0n ? "T" : "F") + "," + (1n ? "T" : "F") + "," +
        \\({} ? "T" : "F") + "," + (new Boolean(false) ? "T" : "F");
    , "T,F,F,F,F,F,F,T,F,T,F,T,T,T");
}

test "interpreter: string + string = concatenation" {
    try expectString("'a' + 'b';", "ab");
    try expectString("'foo' + 'bar';", "foobar");
}

test "interpreter: number + string = string" {
    try expectString("1 + 'a';", "1a");
    try expectString("'a' + 1;", "a1");
}

test "interpreter: typeof returns spec strings" {
    try expectString("typeof 1;", "number");
    try expectString("typeof 1.5;", "number");
    try expectString("typeof 'a';", "string");
    try expectString("typeof true;", "boolean");
    try expectString("typeof null;", "object"); // §13.5.3 historical quirk
    try expectString("typeof (void 0);", "undefined");
}

// ── later — statements, scope, control flow, exceptions ──────────────────

test "later: let declaration with initializer" {
    try expectScriptInt("let x = 42; x;", 42);
}

test "later: let declaration without initializer is undefined" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluateScriptValue(&realm, "let x; x;");
    try testing.expect(v.isUndefined());
}

test "later: const declaration" {
    try expectScriptInt("const x = 7; x + 3;", 10);
}

test "later: var declaration" {
    try expectScriptInt("var x = 5; x * 2;", 10);
}

test "later: simple assignment to let" {
    try expectScriptInt("let x = 1; x = 2; x;", 2);
}

test "later: compound assignment +=" {
    try expectScriptInt("let x = 5; x += 3; x;", 8);
}

test "later: compound assignment *=" {
    try expectScriptInt("let x = 4; x *= 5; x;", 20);
}

test "later: const reassignment in a local scope is rejected at compile time" {
    // Local `const` is a static binding whose immutability is
    // statically knowable — Cynic upgrades the spec's runtime
    // TypeError into a compile-time SyntaxError for the local
    // case. Global `const`, by contrast, defers to runtime per
    // §9.1.1.4 SetMutableBinding so fixtures can wrap the throw
    // in `assert.throws(TypeError, () => { c = 1; })`.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = "{ const x = 1; x = 2; }";
    const program = try parser_mod.parseScript(arena.allocator(), src, null);

    var diags: cynic_diag.Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    const result = compileScriptAsChunk(testing.allocator, &realm, &program, src, &diags);
    try testing.expectError(error.AssignmentToConst, result);
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(cynic_diag.Code.assignment_to_const, diags.items[0].code);
}

test "later: top-level const reassignment throws TypeError at runtime" {
    // §9.1.1.4 SetMutableBinding — global `const` reassignment
    // is a runtime TypeError so `assert.throws(TypeError, () =>
    // { c = 1; })` works at script top level. The compiler emits
    // `sta_global` and the runtime checks the lex-record's
    // const flag.
    try expectScriptThrows("const x = 1; x = 2;");
}

test "later: cross-function const write defers to runtime TypeError" {
    // §9.1.1.1.4 SetMutableBinding step 9.b — writing to an
    // outer-scope `const` from inside a nested function is a
    // *runtime* TypeError, not an early SyntaxError. The
    // assignment site is only reachable when the inner function
    // runs, so the fixture pattern `assert.throws(TypeError, ()
    // => { c = 1; })` from test262 needs the throw deferred. Same
    // reasoning as the named-fn-expr self-binding and import-
    // binding paths — Cynic's compile-time const-reject only
    // fires when the assignment is statically in the same
    // function-like scope as the binding.
    try expectScriptThrows("const x = 1; (function() { x = 2; })();");
}

test "later: TDZ — reading let before declaration throws ReferenceError" {
    // The Hole sentinel sits in the let's slot from block entry
    // until the declaration runs. Reading it via `Ldar` +
    // `ThrowIfHole` raises a ReferenceError.
    try expectScriptThrows("x; let x = 1;");
}

test "later: TDZ does not fire after the declaration runs" {
    try expectScriptInt("let x = 1; x;", 1);
}

test "later: var hoisting — read before declaration is undefined" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    // later simplification: `var` is declare-on-encounter rather
    // than fully hoisted. The full §13.3.2 hoisting semantics
    // are correctness-equivalent for this assertion since we
    // don't run reads through the global scope yet.
    const v = try evaluateScriptValue(&realm, "var x = 1; x;");
    try testing.expect(v.isInt32());
}

test "later: block scope — outer let isn't shadowed when inner doesn't redeclare" {
    try expectScriptInt("let x = 1; { x = 2; } x;", 2);
}

test "later: block scope — inner let shadows outer let" {
    try expectScriptInt("let x = 1; { let x = 2; } x;", 1);
}

// ── Control flow ────────────────────────────────────────────────────────

test "later: if-else true branch" {
    try expectScriptInt("let r = 0; if (true) r = 1; else r = 2; r;", 1);
}

test "later: if-else false branch" {
    try expectScriptInt("let r = 0; if (false) r = 1; else r = 2; r;", 2);
}

test "later: while loop accumulates" {
    try expectScriptInt(
        "let i = 0; let s = 0; while (i < 5) { s = s + i; i = i + 1; } s;",
        10, // 0+1+2+3+4
    );
}

test "later: do-while runs body once even if test is false" {
    try expectScriptInt(
        "let r = 0; do { r = 42; } while (false); r;",
        42,
    );
}

test "later: for loop" {
    try expectScriptInt(
        "let s = 0; for (let i = 1; i <= 10; i = i + 1) s = s + i; s;",
        55, // 1+2+...+10
    );
}

test "later: break exits the loop" {
    try expectScriptInt(
        "let i = 0; while (true) { if (i === 3) break; i = i + 1; } i;",
        3,
    );
}

test "later: continue skips iteration body remainder" {
    try expectScriptInt(
        "let s = 0; for (let i = 1; i <= 5; i = i + 1) { if (i === 3) continue; s = s + i; } s;",
        12, // 1+2+4+5
    );
}

test "later: nested loops — break leaves only the inner" {
    try expectScriptInt(
        "let count = 0; for (let i = 0; i < 3; i = i + 1) { for (let j = 0; j < 3; j = j + 1) { if (j === 1) break; count = count + 1; } } count;",
        3, // each outer iter does the inner once before break
    );
}

// §14.13 LabelledStatement + §14.16/14.17 Break/ContinueStatement —
// labelled `break` and `continue` resolve to the loop whose
// `labelSet` contains the target Identifier, walking outwards.
test "later: labelled break exits the named outer loop" {
    try expectScriptInt(
        "let count = 0; outer: for (let i = 0; i < 3; i = i + 1) { for (let j = 0; j < 3; j = j + 1) { if (j === 1) break outer; count = count + 1; } } count;",
        1, // outer breaks after the first inner iter
    );
}

test "later: labelled continue skips to the named outer loop's update" {
    try expectScriptInt(
        "let count = 0; outer: for (let i = 0; i < 3; i = i + 1) { for (let j = 0; j < 3; j = j + 1) { count = count + 1; if (j === 1) continue outer; } } count;",
        6, // each outer iter runs the inner twice (j=0, j=1→continue)
    );
}

test "later: labelled break on a labelled while loop" {
    try expectScriptInt(
        "let i = 0; label: while (true) { i = i + 1; if (i === 3) break label; } i;",
        3,
    );
}

test "later: labelled continue on a single labelled for loop" {
    try expectScriptInt(
        "var count = 0; label: for (let x = 0; x < 10;) { x++; count++; continue label; } count;",
        10,
    );
}

test "later: labelled break from inside try inside named loop" {
    try expectScriptInt(
        "let i = 0; outer: while (true) { try { i = i + 1; break outer; } catch (e) {} } i;",
        1,
    );
}

// ── Exceptions ──────────────────────────────────────────────────────────

test "later: throw + catch round-trip with binding" {
    try expectScriptString(
        "let captured = 'no'; try { throw 'boom'; } catch (e) { captured = e; } captured;",
        "boom",
    );
}

test "later: throw + catch round-trip without binding" {
    try expectScriptInt(
        "let r = 0; try { throw 1; } catch { r = 2; } r;",
        2,
    );
}

test "later: catch reaches non-thrown values via assignment" {
    try expectScriptInt(
        "let r = 0; try { r = 1; } catch (e) { r = 99; } r;",
        1,
    );
}

test "later: TDZ — destructuring assignment leaf to let-in-TDZ throws (object pattern)" {
    // §13.15.5 DestructuringAssignmentEvaluation routes each
    // leaf through PutValue, which under §6.2.5.5 + §9.1.1.1.4
    // SetMutableBinding step 9 throws ReferenceError when the
    // bound value is still the §13.3.1 TDZ Hole. The leaf is
    // ASSIGNMENT, not InitializeBinding — even if the slot
    // currently holds the Hole sentinel.
    try expectScriptThrows("({ y } = { y: 1 }); let y;");
}

test "later: TDZ — destructuring assignment leaf to let-in-TDZ throws (array pattern)" {
    // §13.15.5 ArrayAssignmentPattern element — same
    // ReferenceError as the object-pattern case.
    try expectScriptThrows("[z] = [1]; let z;");
}

test "later: TDZ — declarator destructuring still initializes (object pattern)" {
    // §14.3.3 destructuring binding for a `let` declarator is
    // an InitializeBinding (§9.1.1.4), not an assignment — it
    // legitimately writes through the Hole. Regression guard
    // for the assignment-vs-declarator split.
    try expectScriptInt("let { a } = { a: 7 }; a;", 7);
}

test "later: TDZ exception is catchable" {
    try expectScriptInt(
        "let caught = 0; try { x; let x = 1; } catch { caught = 1; } caught;",
        1,
    );
}

test "later: throw with no catch propagates" {
    try expectScriptThrows("throw 42;");
}

test "later: finally runs on normal completion" {
    try expectScriptInt(
        "let r = 0; try { r = 1; } finally { r = r + 10; } r;",
        11,
    );
}

// ── Integration: fizzbuzz-shaped program ─────────────────────────────────

// ── later — functions, calls, returns ──────────────────────────────────
//
// Closures over outer-scope bindings are later; for now functions
// can reference their own params, locals, and (via the named-function
// self-binding at register 0) themselves. That's enough for
// non-recursive functions, lambdas, and *named-form* recursion.

test "later: function declaration + call" {
    try expectScriptInt("function add(a, b) { return a + b; } add(2, 3);", 5);
}

test "later: function expression assigned to a let" {
    try expectScriptInt("let f = function(x) { return x * 2; }; f(7);", 14);
}

test "later: arrow function — concise body" {
    try expectScriptInt("let f = (x) => x + 10; f(5);", 15);
}

test "later: arrow function — block body" {
    try expectScriptInt("let f = (x) => { return x - 1; }; f(10);", 9);
}

test "later: function with no return falls through to undefined" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const v = try evaluateScriptValue(&realm, "function f() {} f();");
    try testing.expect(v.isUndefined());
}

test "later: missing arguments arrive as undefined" {
    // §10.2.3 IteratorBindingInitialization: when the caller
    // passes fewer args than the callee declares, the missing
    // params are `undefined`. Our convention copies args at
    // r1.. and pads with the register file's initial value.
    try expectScriptString(
        "function f(a, b) { return typeof b; } f(1);",
        "undefined",
    );
}

test "later: named function expression — recursion via self-binding" {
    // §15.6.5 InstantiateOrdinaryFunctionExpression — for a named
    // function expression the BindingIdentifier is wired into a
    // synthetic 1-binding declarative env wrapping the body so the
    // function can call itself by its given name even when no outer
    // binding exists (and even when shadowed by the outer let).
    try expectScriptInt(
        "let f = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }; f(5);",
        120,
    );
}

test "later: function declaration — self-recursion via self-binding" {
    // later extends the named-function-expression trick to
    // declarations: the function's own name is bound to r0
    // inside its body. Real outer-scope closures arrive later.
    try expectScriptInt(
        "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } fact(6);",
        720,
    );
}

test "later: deep recursion throws RangeError" {
    // The interpreter caps simultaneously-active call frames at
    // `max_call_frames` and raises a RangeError on overflow.
    // `rec(n + 1) + 1` is a non-tail call (the `+ 1` consumes
    // the result), so PTC (§15.10, default-on since f3fdc8b)
    // doesn't fire and the stack grows per recursion. The
    // throw unwinds all the way back to the host since nothing
    // catches it.
    try expectScriptThrows(
        "function rec(n) { return rec(n + 1) + 1; } rec(0);",
    );
}

test "later: deep recursion is catchable" {
    // RangeError unwinds frame-by-frame; an outer try/catch can
    // catch it the moment unwinding hits a handler.
    //
    // `rec(n + 1) + 1` is a *non-tail* call — the `+ 1` after
    // the call means PTC (§15.10) doesn't fire and the stack
    // grows per recursion as required to exercise the overflow.
    // The original `return rec(n + 1)` pattern is now a tail
    // call and runs in one frame forever (PTC ships on by
    // default since f3fdc8b).
    try expectScriptString(
        \\let caught = '';
        \\function rec(n) { return rec(n + 1) + 1; }
        \\try { rec(0); } catch (e) { caught = 'caught'; }
        \\caught;
    , "caught");
}

test "later: calling a non-function throws TypeError" {
    try expectScriptThrows("let x = 1; x();");
}

test "later: TypeError from a non-callable is catchable" {
    try expectScriptString(
        \\let saw = '';
        \\try { let x = 1; x(); } catch (e) { saw = e; }
        \\saw;
    , "value is not callable");
}

test "later: arrow as a higher-order function arg surrogate" {
    // No higher-order built-ins yet, but we can still
    // test the call-return mechanism on a hand-rolled callback.
    try expectScriptInt(
        \\function apply(f, x) { return f(x); }
        \\apply((y) => y * 3, 7);
    , 21);
}

test "later: nested non-recursive calls preserve return values" {
    try expectScriptInt(
        \\function double(x) { return x * 2; }
        \\function triple(x) { return x * 3; }
        \\double(triple(4));
    , 24);
}

// ── later — closures over arbitrary scopes ─────────────────────────────

test "later: closure over an outer let" {
    // The arrow `() => n` captures `n` from `counter`'s scope.
    // Each invocation of the returned arrow sees and mutates
    // the same `n` because the arrow holds a reference to
    // counter's environment (via `captured_env`).
    try expectScriptInt(
        \\function counter() {
        \\  let n = 0;
        \\  return () => { n = n + 1; return n; };
        \\}
        \\let c = counter();
        \\c(); c(); c();
    , 3);
}

test "later: two counters maintain independent state" {
    try expectScriptInt(
        \\function makeCounter() {
        \\  let n = 0;
        \\  return () => { n = n + 1; return n; };
        \\}
        \\let a = makeCounter();
        \\let b = makeCounter();
        \\a(); a(); a();
        \\b(); b();
        \\a();
    , 4);
}

test "later: closure captures multiple bindings" {
    try expectScriptInt(
        \\function adder(x) {
        \\  return (y) => x + y;
        \\}
        \\let add5 = adder(5);
        \\add5(10);
    , 15);
}

test "later: nested closures (closure-of-closure)" {
    try expectScriptInt(
        \\function outer(a) {
        \\  return function (b) {
        \\    return function (c) {
        \\      return a + b + c;
        \\    };
        \\  };
        \\}
        \\outer(1)(2)(3);
    , 6);
}

test "later: function declaration recursion via captured outer env" {
    // No more self-binding hack — `fact` is in script env,
    // captured by the function's closure. The body resolves
    // `fact` via LdaEnv at depth=1.
    try expectScriptInt(
        "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } fact(7);",
        5040,
    );
}

// ── later — object literals + property access ───────────────────────────

test "later: empty object literal" {
    try expectScriptString("typeof ({});", "object");
}

test "later: object literal with single property" {
    try expectScriptInt("({a: 42}).a;", 42);
}

test "later: object literal with multiple properties" {
    try expectScriptInt("let o = {x: 10, y: 20}; o.x + o.y;", 30);
}

test "later: missing property returns undefined" {
    try expectScriptString("typeof ({a: 1}).b;", "undefined");
}

test "later: assignment to property" {
    try expectScriptInt("let o = {x: 1}; o.x = 5; o.x;", 5);
}

test "later: chained property reads" {
    try expectScriptInt("let o = {inner: {value: 7}}; o.inner.value;", 7);
}

test "later: assigning new property" {
    try expectScriptInt("let o = {}; o.x = 99; o.x;", 99);
}

test "later: typeof null is object (historical)" {
    try expectScriptString("typeof null;", "object");
}

test "later: object stored in let, methods of access" {
    try expectScriptInt(
        \\let person = {age: 30, height: 180};
        \\person.age = person.age + 1;
        \\person.age + person.height;
    , 211);
}

test "later: reading number-prototype methods auto-boxes" {
    // Pre-later we threw TypeError on `(5).x`; later the
    // primitive auto-boxes through %Number.prototype% so
    // `(5).toFixed(0)` works. Bare property access of a
    // non-method name returns undefined.
    try expectScriptStringWithBuiltins("let n = 5; typeof n.x;", "undefined");
}

test "later: reading property of null/undefined still throws" {
    try expectScriptThrows("let n = null; n.x;");
}

test "later: BigInt literal + typeof" {
    try expectScriptStringWithBuiltins("typeof 42n;", "bigint");
}

test "later: BigInt arithmetic" {
    try expectScriptStringWithBuiltins(
        \\(2n ** 64n).toString();
    , "18446744073709551616");
}

test "later: BigInt() coerces from Number, String, Boolean" {
    try expectScriptStringWithBuiltins(
        \\BigInt(42).toString() + ":" + BigInt("100").toString() + ":" + BigInt(true).toString();
    , "42:100:1");
}

test "later: BigInt comparison + equality" {
    try expectScriptStringWithBuiltins(
        \\(5n === 5n) + ":" + (5n < 10n) + ":" + (5n === 5);
    , "true:true:false");
}

// §6.1.6.2.{17..23} BigInt::bitwise{AND,OR,XOR,NOT,leftShift,signedRightShift}
test "later: BigInt bitwise AND / OR / XOR" {
    try expectScriptStringWithBuiltins(
        \\((0b1100n & 0b1010n).toString()) + ":" +
        \\((0b1100n | 0b1010n).toString()) + ":" +
        \\((0b1100n ^ 0b1010n).toString());
    , "8:14:6");
}

test "later: BigInt bitwise NOT (~x === -x - 1n)" {
    try expectScriptStringWithBuiltins(
        \\(~0n).toString() + ":" + (~5n).toString() + ":" + (~-1n).toString();
    , "-1:-6:0");
}

test "later: BigInt left-shift / signed right-shift" {
    try expectScriptStringWithBuiltins(
        \\(1n << 4n).toString() + ":" + (16n >> 2n).toString() + ":" + ((-8n) >> 1n).toString();
    , "16:4:-4");
}

test "later: BigInt unsigned right-shift throws TypeError" {
    try expectScriptThrows("1n >>> 1n;");
}

// §7.2.14 IsLooselyEqual: BigInt vs String / Number / Boolean.
test "later: BigInt loose-equals String" {
    try expectScriptStringWithBuiltins(
        \\(0n == "") + ":" + (0n == "0") + ":" + (1n == "1") +
        \\":" + (-1n == "-1") + ":" + (1n == "foo") + ":" + (1n == "1.5");
    , "true:true:true:true:false:false");
}

test "later: BigInt loose-equals Number / Boolean" {
    try expectScriptStringWithBuiltins(
        \\(1n == 1) + ":" + (1n == 1.0) + ":" + (1n == 1.5) +
        \\":" + (1n == true) + ":" + (0n == false) + ":" + (1n == NaN);
    , "true:true:false:true:true:false");
}

// §20.1.1.1 Object(value) — Symbol/BigInt are primitives (§6.1.5 /
// §6.1.6.2), not Type(Object), so Object() must wrap them rather
// than passing them through.
test "later: Object(BigInt) / Object(Symbol) box the primitive" {
    try expectScriptStringWithBuiltins(
        \\typeof Object(0n) + ":" + typeof Object(Symbol("s"));
    , "object:object");
}

test "later: BigInt bitwise on negative + AND with -1n is identity" {
    try expectScriptStringWithBuiltins(
        \\(-2n & -3n).toString() + ":" + (-1n & 5n).toString() + ":" + (5n | -1n).toString();
    , "-4:5:-1");
}

test "later: ArrayBuffer + Uint8Array indexed access" {
    try expectScriptStringWithBuiltins(
        \\const u8 = new Uint8Array(4);
        \\u8[0] = 1; u8[1] = 2; u8[2] = 3; u8[3] = 4;
        \\u8[0] + ":" + u8[1] + ":" + u8[2] + ":" + u8[3] + ":" + u8.length;
    , "1:2:3:4:4");
}

test "later: Int32Array view onto an ArrayBuffer" {
    try expectScriptIntWithBuiltins(
        \\const buf = new ArrayBuffer(16);
        \\const i32 = new Int32Array(buf);
        \\i32[0] = 100; i32[1] = 200;
        \\i32.length + i32[0] + i32[1];
    , 304);
}

test "later: TypedArray fill" {
    try expectScriptIntWithBuiltins(
        \\const a = new Uint8Array(5);
        \\a.fill(7);
        \\a[0] + a[1] + a[2] + a[3] + a[4];
    , 35);
}

test "later: encodeURI / encodeURIComponent" {
    try expectScriptStringWithBuiltins(
        \\encodeURI("a b") + ":" + encodeURIComponent("a=b&c");
    , "a%20b:a%3Db%26c");
}

test "later: Number.prototype.toString(radix)" {
    try expectScriptStringWithBuiltins(
        \\(255).toString(16) + ":" + (10).toString(2);
    , "ff:1010");
}

test "later: Number.prototype.toString integer fast-path matches spec" {
    // §6.1.6.1.20 Number::toString. The radix-10 path takes an
    // integer shortcut (i64-format) when the value is integral
    // and in the safe range; the rest must keep falling through
    // to the f64 formatter. -0 must serialize as "0" (step 2:
    // NumericValue of -0𝔽 is 0). Non-integral doubles stay on
    // the float path. Infinity / NaN keep their dedicated names.
    try expectScriptStringWithBuiltins(
        \\(0).toString() + "," + (-0).toString() + "," +
        \\(42).toString() + "," + (-42).toString() + "," +
        \\(1.5).toString() + "," + (-1.5).toString() + "," +
        \\(NaN).toString() + "," + (Infinity).toString() + "," +
        \\(-Infinity).toString();
    , "0,0,42,-42,1.5,-1.5,NaN,Infinity,-Infinity");
}

test "later: BigInt.prototype.toString(radix)" {
    try expectScriptStringWithBuiltins(
        \\(255n).toString(16) + ":" + (-100n).toString(16);
    , "ff:-64");
}

test "later: BigInt(non-integer) throws RangeError" {
    try expectScriptThrows("BigInt(1.5);");
}

test "later: parseInt ToString-coerces non-strings" {
    try expectScriptStringWithBuiltins(
        \\String(parseInt(true)) + ":" + String(parseInt(false));
    , "NaN:NaN");
}

test "later: TypedArray.prototype.buffer throws on prototype object" {
    try expectScriptThrows(
        \\Uint8Array.prototype.buffer;
    );
}

test "later: harden recursively freezes own data + nested + prototype" {
    // Phase 2 of docs/ses-alignment.md — `harden(v)` deep-freezes
    // the reachable graph from `v`. Strict mode + frozen property
    // ⇒ assignment throws TypeError. Three layers exercise:
    //  · top-level data property assignment (root frozen)
    //  · nested data property assignment (recursive walk caught it)
    //  · new property addition (non-extensible)
    try expectScriptIntWithBuiltins(
        \\const o = { tag: 1, nested: { count: 2 } };
        \\harden(o);
        \\let r = 0;
        \\try { o.tag = 9; } catch { r += 1; }
        \\try { o.nested.count = 9; } catch { r += 10; }
        \\try { o.added = 9; } catch { r += 100; }
        \\r;
    , 111);
}

test "later: harden is cycle-safe + returns its argument" {
    // The reference algorithm uses a visited WeakSet for cycle
    // termination — Cynic's native equivalent uses an internal
    // AutoHashMap keyed by heap pointer. Spec demands the call
    // returns `value` unchanged (identity-equal).
    try expectScriptIntWithBuiltins(
        \\const cyc = { name: "cyc" };
        \\cyc.self = cyc;
        \\const ret = harden(cyc);
        \\(ret === cyc && cyc.self === cyc) ? 1 : 0;
    , 1);
}

test "later: harden of a primitive is a no-op" {
    // §primitive — number / string / bool / null / undefined have
    // no heap identity; `harden` returns them unchanged.
    try expectScriptIntWithBuiltins(
        \\(harden(42) === 42 && harden("x") === "x" &&
        \\ harden(true) === true && harden(null) === null &&
        \\ harden(undefined) === undefined) ? 1 : 0;
    , 1);
}

test "later: harden on Array reaches nested values but not indexed slots (known gap)" {
    // Pins current MVP harden behaviour on §10.4.2 Array exotics:
    //
    //   `a[0].x = 9`    throws (the walk recurses through the
    //                   element's value and freezes the nested
    //                   object). ✓
    //   `a.push(3)`     throws (root is non-extensible). ✓
    //   `a[0] = 9`      **does NOT throw** — the indexed slot
    //                   itself lives in `obj.elements`, not
    //                   `obj.properties`, so harden's bag-only
    //                   walk doesn't reach it. Object.freeze
    //                   handles this via `lowerArrayIndexedFlags`
    //                   which demotes each indexed slot into the
    //                   bag with `{w:false, c:false}`. Wiring
    //                   that into harden is a follow-up — see
    //                   src/runtime/builtins/harden.zig for the
    //                   acknowledged-gaps list.
    //
    // Expected = 10 (nested freeze) + 100 (non-extensible) = 110.
    // When the array gap closes, the indexed-write also throws
    // and this test flips to 111.
    try expectScriptIntWithBuiltins(
        \\const a = [{x: 1}, {x: 2}];
        \\harden(a);
        \\let r = 0;
        \\try { a[0] = 9; } catch { r += 1; }
        \\try { a[0].x = 9; } catch { r += 10; }
        \\try { a.push(3); } catch { r += 100; }
        \\r;
    , 110);
}

/// Inline-test variant of `installBuiltinsAllFeatures` that
/// drops the SES posture before installing builtins — the
/// Phase 1 freeze pass is skipped, so primordials stay mutable.
/// Used by the `--unhardened` parity tests below.
fn installBuiltinsUnhardened(realm: *Realm) !void {
    realm.feature_flags = features.FeatureSet.initFull();
    realm.hardened = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
}

test "ses phase 1: hardened-default — Array.prototype assignment throws" {
    // Phase 1 of docs/ses-alignment.md — at the tail of
    // `installBuiltins` the engine walks the intrinsic graph and
    // stamps every reachable object / function frozen. Writing
    // to `Array.prototype.X` in strict mode then throws
    // TypeError per §10.1.9 (own property is non-writable on a
    // frozen prototype).
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const res = try evaluateScriptResult(&realm,
        \\let threw = 0;
        \\try { Array.prototype.flat = () => null; } catch { threw += 1; }
        \\try { Object.prototype.foo = 'bar'; } catch { threw += 10; }
        \\try { Date.now = () => 0; } catch { threw += 100; }
        \\try { String.prototype.includes = null; } catch { threw += 1000; }
        \\threw;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 1111), v.asInt32());
}

test "ses phase 1: hardened-default — globalThis is non-extensible" {
    // Adding a brand-new property to globalThis throws because
    // the freeze pass set `globalThis.extensible = false`. This
    // is the property that locks the host surface against an
    // untrusted script smuggling capabilities through bare-
    // identifier assignment.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const res = try evaluateScriptResult(&realm,
        \\let threw = 0;
        \\try { globalThis.brandNewBinding = 1; } catch { threw += 1; }
        \\try { Array = null; } catch { threw += 10; }
        \\threw;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 11), v.asInt32());
}

test "ses phase 1: hardened-default — Object.isFrozen(Array.prototype) is true" {
    // The whole hardened graph reports as frozen through the
    // §20.1.2.12 spec path. A user using SES-conventional checks
    // (`Object.isFrozen(intrinsic)`) gets the right answer
    // without having to call `harden()` themselves.
    try expectScriptIntWithBuiltins(
        \\(Object.isFrozen(Array.prototype) &&
        \\ Object.isFrozen(Object.prototype) &&
        \\ Object.isFrozen(Array) &&
        \\ Object.isFrozen(globalThis)) ? 1 : 0;
    , 1);
}

test "ses phase 1: hardened-default — user-allocated objects stay mutable" {
    // The freeze targets ONLY the intrinsic graph — every `{}`,
    // `class`, `new`, array literal etc. allocated by user JS
    // stays writable. Otherwise basic JS programs can't run.
    try expectScriptIntWithBuiltins(
        \\const obj = { a: 1 };
        \\obj.a = 2;
        \\obj.b = 3;
        \\class Foo { constructor() { this.x = 0; } }
        \\Foo.prototype.method = () => 7;
        \\const f = new Foo();
        \\f.x = 42;
        \\const arr = [1, 2, 3];
        \\arr.push(4);
        \\(obj.a === 2 && obj.b === 3 && f.x === 42 &&
        \\ f.method() === 7 && arr.length === 4) ? 1 : 0;
    , 1);
}

test "ses phase 1: --unhardened — Array.prototype assignment succeeds" {
    // Setting `realm.hardened = false` before installBuiltins
    // skips the freeze pass. Primordials stay mutable and the
    // same script that threw four times above succeeds silently.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsUnhardened(&realm);
    const res = try evaluateScriptResult(&realm,
        \\Array.prototype.flat = () => 'patched';
        \\Object.prototype.foo = 'bar';
        \\Date.now = () => 0;
        \\globalThis.brandNewBinding = 99;
        \\([1].flat === Array.prototype.flat &&
        \\ ({}).foo === 'bar' &&
        \\ Date.now() === 0 &&
        \\ globalThis.brandNewBinding === 99) ? 1 : 0;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 1), v.asInt32());
}

test "ses phase 1: --unhardened — Object.isFrozen(Array.prototype) is false" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsUnhardened(&realm);
    const res = try evaluateScriptResult(&realm,
        \\Object.isFrozen(Array.prototype) ? 1 : 0;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 0), v.asInt32());
}

test "ses phase 1: --unhardened — user-allocated objects still mutable" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsUnhardened(&realm);
    const res = try evaluateScriptResult(&realm,
        \\const obj = { a: 1 };
        \\obj.a = 2;
        \\obj.b = 3;
        \\(obj.a === 2 && obj.b === 3) ? 1 : 0;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 1), v.asInt32());
}

test "ses phase 3: override-mistake fix — user class can shadow Object.prototype methods" {
    // The canonical override mistake: `Foo.prototype.toString = fn`.
    // Under spec-literal §10.1.9.2 step 3.b this throws because
    // Object.prototype.toString is non-writable on the chain.
    // Phase 3's synthetic accessor pair routes the assignment
    // through a setter that creates an own data property on the
    // receiver, so the shadow lands on Foo.prototype.
    try expectScriptStringWithBuiltins(
        \\class Foo { constructor() { this.x = 1; } }
        \\Foo.prototype.toString = function() { return "foo"; };
        \\(new Foo()).toString();
    , "foo");
}

test "ses phase 3: override-mistake fix — sta.js Test262Error pattern" {
    // The actual shape from `vendor/test262/harness/sta.js`. If
    // this assignment throws, the entire test262 harness preamble
    // fails to load → every fixture using assert.* false-rejects.
    try expectScriptStringWithBuiltins(
        \\function Test262Error(message) { this.message = message || ""; }
        \\Test262Error.prototype.toString = function() {
        \\  return "Test262Error: " + this.message;
        \\};
        \\(new Test262Error("oops")).toString();
    , "Test262Error: oops");
}

test "ses phase 3: override-mistake fix — instance shadowing of inherited toString" {
    // The shadow lands on the receiver, not on Object.prototype
    // itself. Other objects keep seeing the original inherited
    // toString.
    try expectScriptIntWithBuiltins(
        \\const a = {};
        \\const b = {};
        \\a.toString = function() { return "from-a"; };
        \\(a.toString() === "from-a" &&
        \\ b.toString() === "[object Object]") ? 1 : 0;
    , 1);
}

test "ses phase 3: direct intrinsic-prototype mutation still throws" {
    // Phase 3 only allows shadowing on downstream receivers. A
    // user attempting to overwrite the intrinsic prototype slot
    // itself (`Array.prototype.flat = badImpl` where the receiver
    // IS Array.prototype) still trips the non-configurable
    // accessor redefine and throws.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const res = try evaluateScriptResult(&realm,
        \\let threw = 0;
        \\try { Array.prototype.push = () => "evil"; } catch { threw += 1; }
        \\try { Object.prototype.toString = () => "evil"; } catch { threw += 10; }
        \\try { String.prototype.includes = () => true; } catch { threw += 100; }
        \\threw;
    );
    const v = switch (res) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 111), v.asInt32());
}

test "ses phase 3: shadowing via Reflect.set works on user receiver" {
    // The override-mistake fix has to fire on every code path that
    // routes through OrdinarySet — not just bare assignment. The
    // Phase 3 dispatch lives in `callJSFunction`, so any caller of
    // the synthetic setter sees the shadow happen.
    try expectScriptIntWithBuiltins(
        \\const obj = {};
        \\const ok = Reflect.set(obj, "toString", function() { return "yes"; });
        \\(ok && obj.toString() === "yes") ? 1 : 0;
    , 1);
}

test "ses phase 1: harden global is itself frozen under hardened-default" {
    // If `harden` weren't reached by the freeze pass, untrusted
    // code could shadow `globalThis.harden = (x) => x` to defeat
    // user-level deep-freezes. The Phase 1 walk starts from
    // globalThis and reaches `harden` transitively.
    try expectScriptIntWithBuiltins(
        \\let threw = 0;
        \\try { globalThis.harden = (x) => x; } catch { threw += 1; }
        \\threw;
    , 1);
}

test "later: harden of a function freezes its .prototype and own props" {
    // Functions carry an own `.prototype` object that downstream
    // `new`-construction wires up the receiver's [[Prototype]]
    // to. Hardening the function must also reach .prototype +
    // every accessor pair so that `MyClass.prototype.bar = …`
    // doesn't slip through.
    try expectScriptIntWithBuiltins(
        \\function MakePoint(x, y) { this.x = x; this.y = y; }
        \\MakePoint.prototype.greet = function() { return "hi"; };
        \\harden(MakePoint);
        \\let r = 0;
        \\try { MakePoint.tag = 1; } catch { r += 1; }
        \\try { MakePoint.prototype.greet = null; } catch { r += 10; }
        \\try { MakePoint.prototype.added = 1; } catch { r += 100; }
        \\r;
    , 111);
}

test "later: AsyncGeneratorFunction constructor is reachable via instance proto" {
    try expectScriptStringWithBuiltins(
        \\const f = async function* () {};
        \\typeof Object.getPrototypeOf(f).constructor;
    , "function");
}

test "later: RegExp.escape escapes syntax characters" {
    try expectScriptStringWithBuiltins(
        \\RegExp.escape("^.*$");
    , "\\^\\.\\*\\$");
}

// ── §22.2.1.1 duplicate named capture groups (ES2025) ───────────────
// A GroupName may repeat across mutually exclusive alternatives of a
// Disjunction; repeating it within a single Alternative
// (concatenation) is an early SyntaxError.

test "RegExp: duplicate group name across alternatives parses" {
    try expectScriptStringWithBuiltins(
        \\new RegExp("(?<x>a)|(?<x>b)").source;
    , "(?<x>a)|(?<x>b)");
}

test "RegExp: duplicate group name in same alternative is a SyntaxError" {
    try expectScriptStringWithBuiltins(
        \\(() => { try { new RegExp("(?<x>a)(?<x>b)"); return "no-throw"; }
        \\  catch (e) { return e.constructor.name; } })();
    , "SyntaxError");
}

test "RegExp: nested duplicate group name in same alternative is a SyntaxError" {
    try expectScriptStringWithBuiltins(
        \\(() => { try { new RegExp("(?<x>(?<x>a))"); return "no-throw"; }
        \\  catch (e) { return e.constructor.name; } })();
    , "SyntaxError");
}

test "RegExp: exec result array keeps a slot per duplicated group" {
    // §22.2.7.2 — captures stay positional; only the matched
    // alternative's slot is populated.
    try expectScriptStringWithBuiltins(
        \\String(/(?<x>a)|(?<x>b)/.exec("bab"));
    , "b,,b");
}

test "RegExp: exec result array slot order follows source order" {
    try expectScriptStringWithBuiltins(
        \\String(/(?<x>b)|(?<x>a)/.exec("bab"));
    , "b,b,");
}

test "RegExp: groups.x reflects the participating alternative" {
    try expectScriptStringWithBuiltins(
        \\/(?<x>a)|(?<x>b)/.exec("bab").groups.x;
    , "b");
}

test "RegExp: backreference resolves the participating duplicated name" {
    try expectScriptStringWithBuiltins(
        \\String(/(?:(?<x>a)|(?<x>b))\k<x>/.exec("aa"));
    , "aa,a,");
}

test "RegExp: backreference resolves the second duplicated name" {
    try expectScriptStringWithBuiltins(
        \\String(/(?:(?<x>a)|(?<x>b))\k<x>/.exec("bb"));
    , "bb,,b");
}

test "RegExp: backreference to unset duplicated name matches empty" {
    // /(?<a>x)|(?:zy\k<a>)/ on "zy": second alternative matches, a is
    // unset, \k<a> matches the empty string.
    try expectScriptStringWithBuiltins(
        \\String(/(?<a>x)|(?:zy\k<a>)/.exec("zy"));
    , "zy,");
}

test "RegExp: backreference to duplicated name fails when neither matches" {
    try expectScriptStringWithBuiltins(
        \\String(/(?:(?<x>a)|(?<x>b))\k<x>/.exec("abab"));
    , "null");
}

test "RegExp: duplicated name across three alternatives" {
    try expectScriptStringWithBuiltins(
        \\String(/^(?:(?<a>x)|(?<a>y)|z)\k<a>$/.exec("xx"));
    , "xx,x,");
}

test "RegExp: groups object emits one property per distinct name in source order" {
    try expectScriptStringWithBuiltins(
        \\Object.keys(/(?:(?<x>a)|(?<y>a)(?<x>b))(?:(?<z>c)|(?<z>d))/.exec("abc").groups).join(",");
    , "x,y,z");
}

test "RegExp: groups object dedups to participating capture across names" {
    try expectScriptStringWithBuiltins(
        \\const m = /(?:(?<x>a)|(?<y>a)(?<x>b))(?:(?<z>c)|(?<z>d))/.exec("abc");
        \\[m.groups.x, m.groups.y, m.groups.z].join(",");
    , "b,a,c");
}

test "RegExp: groups object preserves names with no participating capture" {
    try expectScriptStringWithBuiltins(
        \\const m = /(?:(?<x>a)|(?<y>a)(?<x>b))(?:(?<z>c)|(?<z>d))/.exec("ad");
        \\[m.groups.x, String(m.groups.y), m.groups.z].join(",");
    , "a,undefined,d");
}

test "RegExp: iterated duplicated group resets across iterations" {
    // /(?:(?:(?<x>a)|(?<x>b)|c)\k<x>){2}/ on "aac": last iteration
    // takes the `c` branch, so groups.x is undefined.
    try expectScriptStringWithBuiltins(
        \\typeof /(?:(?:(?<x>a)|(?<x>b)|c)\k<x>){2}/.exec("aac").groups.x;
    , "undefined");
}

test "later: WeakMap.prototype.delete on a Map throws TypeError" {
    try expectScriptThrows(
        \\WeakMap.prototype.delete.call(new Map(), {});
    );
}

test "later: WeakMap.prototype.getOrInsert" {
    try expectScriptIntWithBuiltins(
        \\const wm = new WeakMap();
        \\const k = {};
        \\wm.getOrInsert(k, 5);
        \\wm.getOrInsert(k, 99);
    , 5);
}

test "later: decodeURI preserves reserved characters" {
    try expectScriptStringWithBuiltins(
        \\decodeURI("a%20b%23c");
    , "a b%23c");
}

test "later: closure can write back through captured env" {
    try expectScriptString(
        \\let log = '';
        \\function record(s) { log = log + s; }
        \\record('a'); record('b'); record('c');
        \\log;
    , "abc");
}

test "later: function carries arbitrary properties" {
    // Functions are objects (§10.2). Reads of unknown properties
    // return undefined; writes are visible on subsequent reads.
    // Mandatory for harness/sta.js loading
    // (`Test262Error.prototype.toString = …`).
    try expectScriptInt(
        \\function f() {}
        \\f.tag = 7;
        \\f.tag;
    , 7);
}

test "later: function .prototype is an auto-allocated object" {
    // Non-arrow functions get a fresh `.prototype` object at
    // allocation time (§10.2.4). The object's `.constructor`
    // points back to the function (§20.2.4.1).
    try expectScriptString(
        \\function F() {}
        \\typeof F.prototype;
    , "object");
}

test "later: F.prototype.constructor === F" {
    try expectScriptString(
        \\function F() {}
        \\F.prototype.constructor === F ? "yes" : "no";
    , "yes");
}

test "native method on a lazily-built prototype inherits Function.prototype" {
    // Regression: %ArrayIteratorPrototype% is built on the first
    // array iteration — after realm init's one-time function-proto
    // wiring pass. Its `next` (and every other lazily-installed
    // native) must still chain to %Function.prototype% so the
    // inherited `.call` / `.apply` / `.bind` resolve.
    try expectScriptStringWithBuiltins(
        \\const next = Object.getPrototypeOf([1, 2, 3][Symbol.iterator]()).next;
        \\const ok = Object.getPrototypeOf(next) === Function.prototype
        \\    && typeof next.call === "function"
        \\    && typeof next.apply === "function"
        \\    && typeof next.bind === "function";
        \\ok ? "ok" : "broken";
    , "ok");
}

test "lazily-installed native method is callable via Function.prototype.call" {
    try expectScriptIntWithBuiltins(
        \\const it = [10, 20, 30][Symbol.iterator]();
        \\Object.getPrototypeOf(it).next.call(it).value;
    , 10);
}

test "later: function .prototype is mutable" {
    // Test262 sets `Test262Error.prototype.toString = …` so the
    //.prototype object must be a real ordinary object that
    // accepts property writes.
    try expectScriptInt(
        \\function F() {}
        \\F.prototype.x = 42;
        \\F.prototype.x;
    , 42);
}

test "later: assigning to f.prototype rebinds the slot" {
    try expectScriptInt(
        \\function F() {}
        \\F.prototype = {marker: 99};
        \\F.prototype.marker;
    , 99);
}

test "later: new F() returns a new instance" {
    try expectScriptString(
        \\function F() {}
        \\typeof new F();
    , "object");
}

test "later: constructor binds this to the new instance" {
    try expectScriptInt(
        \\function Point(x, y) { this.x = x; this.y = y; }
        \\const p = new Point(3, 4);
        \\p.x + p.y;
    , 7);
}

test "later: instance.__proto__ === F.prototype (transitively)" {
    // No `__proto__`/`Object.getPrototypeOf` yet — but methods
    // installed on F.prototype must be reachable via instance.
    try expectScriptInt(
        \\function F() {}
        \\F.prototype.shared = 42;
        \\const f = new F();
        \\f.shared;
    , 42);
}

test "later: new returns this if constructor doesn't return an object" {
    // §13.3.5.1.1: primitive return values are discarded; the
    // freshly allocated `this` survives.
    try expectScriptInt(
        \\function F() { this.tag = 99; return 17; }
        \\new F().tag;
    , 99);
}

test "later: new uses the explicit object return when given one" {
    try expectScriptInt(
        \\function F() { this.a = 1; return {b: 2}; }
        \\const f = new F();
        \\(f.a === undefined ? 1 : 0) + f.b;
    , 3);
}

test "later: constructor.constructor === F" {
    // §20.2.4.1 — `(new F).constructor` resolves through the
    // prototype chain to `F`.
    try expectScriptString(
        \\function F() {}
        \\new F().constructor === F ? "yes" : "no";
    , "yes");
}

test "later: instanceof returns true for direct constructor" {
    try expectScriptString(
        \\function F() {}
        \\const f = new F();
        \\f instanceof F ? "yes" : "no";
    , "yes");
}

test "later: instanceof returns false for unrelated constructor" {
    try expectScriptString(
        \\function F() {}
        \\function G() {}
        \\const f = new F();
        \\f instanceof G ? "yes" : "no";
    , "no");
}

test "later: instanceof on non-object returns false" {
    try expectScriptString(
        \\function F() {}
        \\(5 instanceof F) ? "yes" : "no";
    , "no");
}

test "later: instanceof on non-callable RHS throws TypeError" {
    try expectScriptThrows("({}) instanceof {};");
}

test "later: arrow this is lexically captured" {
    // `this` inside an arrow points to whatever `this` was at the
    // arrow's definition site. Top-level strict `this` is undefined.
    try expectScriptString(
        \\const f = () => typeof this;
        \\f();
    , "undefined");
}

test "later: top-level this is undefined in strict mode" {
    try expectScriptString("typeof this;", "undefined");
}

test "later: method-style call binds this to the receiver" {
    // no method-shorthand-call sugar yet.
    // Test through plain assignment + property access.
    try expectScriptInt(
        \\function F() { this.value = 7; }
        \\F.prototype.getValue = function() { return this.value; };
        \\new F().getValue();
    , 7);
}

test "later: typed Error constructors install correctly" {
    try expectScriptStringWithBuiltins(
        \\const t = new TypeError("oops");
        \\t.message + ":" + t.name;
    , "oops:TypeError");
}

test "later: typed Error subclassing — TypeError instanceof Error" {
    try expectScriptStringWithBuiltins(
        \\const t = new TypeError("x");
        \\(t instanceof TypeError) && (t instanceof Error) ? "yes" : "no";
    , "yes");
}

test "later: TypeError.prototype.constructor === TypeError" {
    try expectScriptStringWithBuiltins(
        \\TypeError.prototype.constructor === TypeError ? "yes" : "no";
    , "yes");
}

test "later: runtime-thrown TypeError is catchable as a real object" {
    // The interpreter now allocates a real `new TypeError(msg)`
    // when an opcode raises a TypeError, so user code can match
    // against the constructor (the assert.throws shape).
    try expectScriptStringWithBuiltins(
        \\let kind = "none";
        \\try {
        \\  ({}).a.b;  // reading property of undefined → TypeError
        \\} catch (e) {
        \\  if (e instanceof TypeError) kind = "type";
        \\  else kind = typeof e;
        \\}
        \\kind;
    , "type");
}

test "later: ReferenceError on unresolved global is a real object" {
    try expectScriptStringWithBuiltins(
        \\let kind = "none";
        \\try { unboundIdentifier; } catch (e) {
        \\  if (e instanceof ReferenceError) kind = "ref";
        \\}
        \\kind;
    , "ref");
}

// §13.15.2 step 1.a — Evaluation of the LHS Reference happens
// *before* the RHS, so a side-effecting RHS that creates a
// matching global must not mask the unresolvable LHS Reference.
// Cynic is strict-only; §6.2.5.5 step 6 then throws. Runs
// unhardened because `this.undeclaredA = 5` would otherwise
// trip the SES freeze of `globalThis` and throw TypeError from
// the RHS before the snapshot replay fires.
test "strict: assignment LHS resolvability snapshot precedes RHS" {
    try expectScriptStringUnhardened(
        \\let kind = "none";
        \\try {
        \\  undeclaredA = (this.undeclaredA = 5);
        \\} catch (e) {
        \\  if (e instanceof ReferenceError) kind = "ref";
        \\}
        \\kind;
    , "ref");
}

// Sanity guard for the same path: forward writes against
// already-declared globals continue to succeed.
test "strict: bare assignment to a pre-declared global stores" {
    try expectScriptIntWithBuiltins(
        \\var declared;
        \\declared = 17;
        \\declared;
    , 17);
}

test "later: empty class declaration creates a constructor" {
    try expectScriptStringWithBuiltins(
        \\class Empty {}
        \\typeof Empty;
    , "function");
}

test "later: new C() returns an instance with C.prototype as proto" {
    try expectScriptStringWithBuiltins(
        \\class C {}
        \\const x = new C();
        \\(x instanceof C) ? "yes" : "no";
    , "yes");
}

test "later: instance method lives on the prototype" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  m() { return 7; }
        \\}
        \\new C().m();
    , 7);
}

test "later: constructor receives args and binds this" {
    try expectScriptIntWithBuiltins(
        \\class Point {
        \\  constructor(x, y) {
        \\    this.x = x;
        \\    this.y = y;
        \\  }
        \\}
        \\const p = new Point(3, 4);
        \\p.x + p.y;
    , 7);
}

test "later: static method on the constructor itself" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  static fn() { return 9; }
        \\}
        \\C.fn();
    , 9);
}

test "later: extends links B.prototype to A.prototype" {
    try expectScriptIntWithBuiltins(
        \\class A {
        \\  greet() { return 1; }
        \\}
        \\class B extends A {}
        \\new B().greet();
    , 1);
}

test "later: super(...) calls parent constructor with this" {
    try expectScriptIntWithBuiltins(
        \\class A {
        \\  constructor(x) { this.a = x; }
        \\}
        \\class B extends A {
        \\  constructor(x) {
        \\    super(x);
        \\    this.b = x + 1;
        \\  }
        \\}
        \\const b = new B(5);
        \\b.a + b.b;
    , 11);
}

test "later: super.method() looks up through home-object proto" {
    try expectScriptIntWithBuiltins(
        \\class A {
        \\  base() { return 10; }
        \\}
        \\class B extends A {
        \\  derived() { return super.base() + 1; }
        \\}
        \\new B().derived();
    , 11);
}

test "later: super(...) rebinds `this` to the object returned by the parent ctor (§13.3.7.1)" {
    // §10.2.1.3 step 10.a — `Construct(parent, args, NT)` returns the
    // parent's returned object if it's an Object. §13.3.7.1 step 8 then
    // BindThisValue(result) on the derived ctor's environment, so a
    // subsequent `this` read inside the derived ctor body sees the
    // parent-supplied object.
    try expectScriptIntWithBuiltins(
        \\var supplied = { tag: 17 };
        \\function Parent() { return supplied; }
        \\class Child extends Parent {
        \\  constructor() {
        \\    super();
        \\    this.tag;
        \\  }
        \\}
        \\new Child().tag;
    , 17);
}

test "later: derived ctor returns the BindThisValue result, not the pre-allocated instance" {
    // §10.2.2 step 12 — derived ctor's [[Construct]] returns
    // `GetThisBinding()`, which after super() is whatever the parent
    // bound. So `new Sub3()` should yield `obj`, not the pre-allocated
    // derived instance.
    try expectScriptIntWithBuiltins(
        \\var obj = { tag: 99 };
        \\class Base3 { constructor() { return obj; } }
        \\class Sub3 extends Base3 {}
        \\new Sub3().tag;
    , 99);
}

test "later: calling super() twice in a derived ctor throws ReferenceError (§9.1.1.3.1)" {
    // §10.2.1.4 BindThisValue step 3 — if the function env-record's
    // [[ThisBindingStatus]] is "initialized", BindThisValue throws
    // ReferenceError. So a second `super(...)` in the same derived
    // ctor body must throw.
    try expectScriptStringWithBuiltins(
        \\var caught = "none";
        \\class A {}
        \\class B extends A {
        \\  constructor() {
        \\    super();
        \\    try { super(); caught = "no-throw"; }
        \\    catch (e) { caught = e.constructor.name; }
        \\  }
        \\}
        \\new B();
        \\caught;
    , "ReferenceError");
}

test "later: instance is also instanceof both subclass and parent" {
    try expectScriptStringWithBuiltins(
        \\class A {}
        \\class B extends A {}
        \\const b = new B();
        \\(b instanceof B && b instanceof A) ? "yes" : "no";
    , "yes");
}

test "later: default-constructor synthesis without extends" {
    try expectScriptStringWithBuiltins(
        \\class C {}
        \\typeof new C();
    , "object");
}

test "later: default-constructor with extends forwards args" {
    try expectScriptIntWithBuiltins(
        \\class A {
        \\  constructor(v) { this.v = v; }
        \\}
        \\class B extends A {}
        \\new B(42).v;
    , 42);
}

test "later: class expression assigned to const" {
    try expectScriptIntWithBuiltins(
        \\const C = class {
        \\  m() { return 13; }
        \\};
        \\new C().m();
    , 13);
}

test "later: class is callable only via new" {
    try expectScriptStringWithBuiltins(
        \\class C {}
        \\let kind = "ok";
        \\try { C(); kind = "no-throw"; } catch (e) {
        \\  if (e instanceof TypeError) kind = "type";
        \\}
        \\kind;
    , "type");
}

test "later: extends static methods inherited" {
    try expectScriptIntWithBuiltins(
        \\class A {
        \\  static get42() { return 42; }
        \\}
        \\class B extends A {}
        \\B.get42();
    , 42);
}

test "later: public instance field initializer" {
    try expectScriptIntWithBuiltins(
        \\class C { x = 1; y = 2; }
        \\const c = new C();
        \\c.x + c.y;
    , 3);
}

test "later: field initializer reads `this` of in-progress instance" {
    try expectScriptIntWithBuiltins(
        \\class C { x = 1; y = this.x + 1; }
        \\const c = new C();
        \\c.x + c.y;
    , 3);
}

test "later: field initializers run AFTER super(...)" {
    try expectScriptIntWithBuiltins(
        \\class A { constructor() { this.parent = 7; } }
        \\class B extends A { x = this.parent; }
        \\new B().x;
    , 7);
}

test "later: static field on the constructor" {
    try expectScriptIntWithBuiltins(
        \\class C { static x = 42; }
        \\C.x;
    , 42);
}

test "later: static block runs at class definition with this=class" {
    // Use `this` (bound to the class inside a static block per
    // §15.7.13) — `C` itself is initialised after class
    // definition completes, so wouldn't be visible from inside.
    try expectScriptIntWithBuiltins(
        \\class C { static x = 0; static { this.x = 5; } }
        \\C.x;
    , 5);
}

test "later: private field round-trip" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #x = 0;
        \\  set(v) { this.#x = v; }
        \\  get() { return this.#x; }
        \\}
        \\const c = new C();
        \\c.set(99);
        \\c.get();
    , 99);
}

test "later: private field brand check throws on foreign object" {
    try expectScriptStringWithBuiltins(
        \\class C {
        \\  #x = 1;
        \\  static check(o) { return o.#x; }
        \\}
        \\let kind = "ok";
        \\try { C.check({}); kind = "no-throw"; } catch (e) {
        \\  if (e instanceof TypeError) kind = "type";
        \\}
        \\kind;
    , "type");
}

test "later: private field postfix increment returns old value" {
    // Regression: `this.#x++` used to fail with
    // `error.UnsupportedExpression` from `compileUpdateMember` —
    // the private-key branch was an explicit "not supported".
    // The playground's "Class + private field" sample surfaced
    // this as a generic "SyntaxError: failed to compile".
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 0;
        \\  inc() { return this.#n++; }
        \\  value() { return this.#n; }
        \\}
        \\const c = new C();
        \\c.inc();
        \\c.inc();
        \\c.inc();
        \\c.value();
    , 3);
}

test "later: private field prefix increment returns new value" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 0;
        \\  inc() { return ++this.#n; }
        \\}
        \\const c = new C();
        \\c.inc();
        \\c.inc();
        \\c.inc();
    , 3);
}

test "later: private field postfix decrement" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 5;
        \\  dec() { this.#n--; }
        \\  value() { return this.#n; }
        \\}
        \\const c = new C();
        \\c.dec();
        \\c.dec();
        \\c.value();
    , 3);
}

test "later: postfix-increment expression value equals the pre-update read" {
    // Same shape as the previous test but asserts the
    // postfix-result semantics (`x++` returns the OLD value, not
    // the bumped one). Catches a bug where the .private branch
    // emits the bumped value instead.
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 41;
        \\  bump() { return this.#n++; }
        \\}
        \\new C().bump();
    , 41);
}

test "later: private field prefix decrement returns new value" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 10;
        \\  dec() { return --this.#n; }
        \\}
        \\new C().dec();
    , 9);
}

test "later: multiple private fields, independent ++" {
    // Distinct private slots mangle to distinct constants; check
    // the bumps don't collide on the same mangled key.
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #a = 0;
        \\  #b = 100;
        \\  bump() { this.#a++; this.#b++; }
        \\  sum()  { return this.#a + this.#b; }
        \\}
        \\const c = new C();
        \\c.bump();
        \\c.bump();
        \\c.bump();
        \\c.sum();
    , 106);
}

test "later: private BigInt field ++ uses BigInt::unit" {
    // §13.4 bump dispatches on Type(oldValue). For a private
    // BigInt slot, ++ must NOT mix in Number's 1 and TypeError —
    // it should bump by 1n. The `inc` opcode handles the
    // dispatch; this test catches any regression where the
    // private path bypasses the type-aware bump.
    try expectScriptStringWithBuiltins(
        \\class C {
        \\  #n = 0n;
        \\  bump() { this.#n++; }
        \\  value() { return this.#n.toString(); }
        \\}
        \\const c = new C();
        \\c.bump();
        \\c.bump();
        \\c.bump();
        \\c.value();
    , "3");
}

test "later: private static field ++ via class lvalue" {
    // `C.#n++` from a static method — `this` is the constructor
    // itself, brand-checked against the static private slot.
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  static #n = 0;
        \\  static bump() { return C.#n++; }
        \\  static value() { return C.#n; }
        \\}
        \\C.bump();
        \\C.bump();
        \\C.bump();
        \\C.value();
    , 3);
}

test "later: private field compound `+=` still works" {
    // Different code path (`compileAssignmentMember`, not
    // `compileUpdateMember`) — sanity-check that the assignment
    // path's private-field handling didn't regress alongside the
    // update fix.
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #n = 10;
        \\  add(d) { this.#n += d; }
        \\  value() { return this.#n; }
        \\}
        \\const c = new C();
        \\c.add(5);
        \\c.add(7);
        \\c.value();
    , 22);
}

test "later: private method callable via this" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #priv() { return 7; }
        \\  use() { return this.#priv(); }
        \\}
        \\new C().use();
    , 7);
}

test "later: instance getter / setter pair" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  constructor() { this._x = 0; }
        \\  get x() { return this._x; }
        \\  set x(v) { this._x = v + 1; }
        \\}
        \\const c = new C();
        \\c.x = 5;
        \\c.x;
    , 6);
}

test "later: postfix obj.x++ returns old, mutates property" {
    try expectScriptIntWithBuiltins(
        \\const o = {x: 5};
        \\const a = o.x++;
        \\a + o.x;
    , 11);
}

test "later: prefix ++obj.x returns new" {
    try expectScriptIntWithBuiltins(
        \\const o = {x: 5};
        \\const a = ++o.x;
        \\a + o.x;
    , 12);
}

test "later: arr[i]-- works on computed member" {
    try expectScriptIntWithBuiltins(
        \\const a = [10, 20, 30];
        \\const x = a[1]--;
        \\x + a[1];
    , 39);
}

test "later: arguments.length and indexed access" {
    try expectScriptIntWithBuiltins(
        \\function f() { return arguments.length; }
        \\f(1, 2, 3, 4);
    , 4);
}

test "later: arguments[i] reads positional args" {
    try expectScriptIntWithBuiltins(
        \\function f() { return arguments[0] + arguments[2]; }
        \\f(7, 100, 3);
    , 10);
}

test "later: arguments not visible inside arrow functions" {
    // Arrows inherit `arguments` from the enclosing function;
    // when there is none (top-level), reading it is a
    // ReferenceError. (Reading via `typeof` would NOT throw —
    // §13.5.3 step 3 turns unresolvable refs into "undefined".
    // Use direct read instead.)
    try expectScriptStringWithBuiltins(
        \\const f = () => arguments;
        \\let kind = "ok";
        \\try { f(); } catch (e) {
        \\  if (e instanceof ReferenceError) kind = "ref";
        \\}
        \\kind;
    , "ref");
}

test "later: for-of over array iterates values" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (const x of [1, 2, 3, 4]) s = s + x;
        \\s;
    , 10);
}

test "later: for-of over string iterates chars" {
    try expectScriptStringWithBuiltins(
        \\let s = "";
        \\for (const c of "abc") s = s + c + ",";
        \\s;
    , "a,b,c,");
}

test "later: for-of with break stops early" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (const x of [1, 2, 3, 4]) {
        \\  if (x > 2) break;
        \\  s = s + x;
        \\}
        \\s;
    , 3);
}

test "for-of: hoisted-env loop with break / continue" {
    // §14.7.5.6 — body captures nothing, so the per-iteration env
    // is hoisted to a single env. break / continue must still
    // unwind it correctly.
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (const v of [1, 2, 3, 4, 5]) { if (v % 2 === 0) continue; s += v; }
        \\let t = 0;
        \\for (const v of [1, 2, 3, 4, 5]) { if (v === 4) break; t += v; }
        \\s * 100 + t;
    , 906);
}

test "for-of: closure over loop var keeps per-iteration values" {
    // A closure captures the loop variable — the per-iteration env
    // must NOT be hoisted; each closure sees its own iteration.
    try expectScriptStringWithBuiltins(
        \\const fns = [];
        \\for (const v of [10, 20, 30]) fns.push(() => v);
        \\fns.map(f => f()).join(",");
    , "10,20,30");
}

test "for-of: closure over a body lexical keeps per-iteration values" {
    // Cynic flattens body-block lexicals into the loop env, so a
    // closure capturing a body `const` (not the loop variable)
    // must also keep the per-iteration env.
    try expectScriptStringWithBuiltins(
        \\const fns = [];
        \\for (const v of [1, 2, 3]) { const w = v * 100; fns.push(() => w); }
        \\fns.map(f => f()).join(",");
    , "100,200,300");
}

test "for: closure over a body lexical keeps per-iteration values" {
    // §14.7.4.4 — the C-style for loop flattens body-block lexicals
    // into its per-iteration env, so a closure capturing a body
    // `let` (not the loop counter `i`) must also keep that env
    // per-iteration. Regression for the per-iter-env elision gate
    // missing body-lexical captures.
    try expectScriptStringWithBuiltins(
        \\const fns = [];
        \\for (let i = 0; i < 3; i++) { let w = i * 10; fns.push(() => w); }
        \\fns.map(f => f()).join(",");
    , "0,10,20");
}

test "later: new Number(5) wraps a primitive that ToNumber unwraps" {
    try expectScriptIntWithBuiltins(
        \\const n = new Number(5);
        \\n * 2;
    , 10);
}

test "later: new String('abc') wraps and ToString unwraps" {
    try expectScriptStringWithBuiltins(
        \\const s = new String("abc");
        \\"<" + s + ">";
    , "<abc>");
}

test "later: Map basic round-trip" {
    try expectScriptIntWithBuiltins(
        \\const m = new Map();
        \\m.set("a", 1);
        \\m.set("b", 2);
        \\m.get("a") + m.get("b") + m.size;
    , 5);
}

test "later: Map constructor accepts iterable of pairs" {
    try expectScriptIntWithBuiltins(
        \\const m = new Map([["a", 1], ["b", 2], ["c", 3]]);
        \\m.get("b") + m.size;
    , 5);
}

test "later: Map.has + delete" {
    try expectScriptStringWithBuiltins(
        \\const m = new Map();
        \\m.set("k", 1);
        \\const a = m.has("k");
        \\m.delete("k");
        \\const b = m.has("k");
        \\(a ? "yes" : "no") + ":" + (b ? "yes" : "no");
    , "yes:no");
}

test "later: Map.forEach iterates in insertion order" {
    try expectScriptStringWithBuiltins(
        \\const m = new Map();
        \\m.set("c", 3);
        \\m.set("a", 1);
        \\m.set("b", 2);
        \\let s = "";
        \\m.forEach((v, k) => { s = s + k + "=" + v + ","; });
        \\s;
    , "c=3,a=1,b=2,");
}

test "later: Set basic" {
    try expectScriptIntWithBuiltins(
        \\const s = new Set();
        \\s.add(1); s.add(2); s.add(2); s.add(3);
        \\s.size;
    , 3);
}

test "later: Set constructor + has + delete" {
    try expectScriptStringWithBuiltins(
        \\const s = new Set([1, 2, 3]);
        \\const a = s.has(2);
        \\s.delete(2);
        \\const b = s.has(2);
        \\(a ? "yes" : "no") + ":" + (b ? "yes" : "no");
    , "yes:no");
}

test "later: Date.now returns a positive number" {
    try expectScriptStringWithBuiltins(
        \\typeof Date.now() === "number" ? "ok" : "no";
    , "ok");
}

test "later: generator yields values in order" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\const it = g();
        \\const a = it.next();
        \\const b = it.next();
        \\const c = it.next();
        \\const d = it.next();
        \\a.value + ":" + a.done + "," + b.value + ":" + b.done + "," + c.value + ":" + c.done + "," + d.done;
    , "1:false,2:false,3:false,true");
}

test "later: generator next(arg) sends value back to yield" {
    try expectScriptIntWithBuiltins(
        \\function* g() {
        \\  const x = yield 1;
        \\  const y = yield x + 1;
        \\  return y * 2;
        \\}
        \\const it = g();
        \\it.next();      // -> {value: 1}
        \\it.next(10);    // -> {value: 11}, x = 10
        \\it.next(20).value; // y = 20, return 40
    , 40);
}

test "later: generator manual-driven loop" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield "a"; yield "b"; yield "c"; }
        \\const it = g();
        \\let s = "";
        \\let r = it.next();
        \\while (!r.done) { s = s + r.value; r = it.next(); }
        \\s;
    , "abc");
}

test "later: for-of dispatches via @@iterator over generators" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield "a"; yield "b"; yield "c"; }
        \\let s = "";
        \\for (const v of g()) s = s + v;
        \\s;
    , "abc");
}

test "later: for-of over plain array still walks length+index (fallback)" {
    try expectScriptStringWithBuiltins(
        \\let s = "";
        \\for (const v of [10, 20, 30]) s = s + v + ",";
        \\s;
    , "10,20,30,");
}

test "later: for-of over Map walks insertion order" {
    try expectScriptStringWithBuiltins(
        \\const m = new Map();
        \\m.set("a", 1); m.set("b", 2); m.set("c", 3);
        \\let s = "";
        \\for (const e of m) s = s + e[0] + "=" + e[1] + ",";
        \\s;
    , "a=1,b=2,c=3,");
}

test "later: for-of over Set walks insertion order" {
    try expectScriptStringWithBuiltins(
        \\const xs = new Set();
        \\xs.add("p"); xs.add("q"); xs.add("r");
        \\let s = "";
        \\for (const v of xs) s = s + v;
        \\s;
    , "pqr");
}

test "later: for-of over a string yields per-character" {
    try expectScriptStringWithBuiltins(
        \\let out = "";
        \\for (const ch of "abc") out = out + "[" + ch + "]";
        \\out;
    , "[a][b][c]");
}

test "later: array spread uses iterator protocol over a generator" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\const arr = [0, ...g(), 4];
        \\arr.join(",");
    , "0,1,2,3,4");
}

test "later: array spread of a Set" {
    try expectScriptStringWithBuiltins(
        \\const s = new Set();
        \\s.add("a"); s.add("b"); s.add("c");
        \\[...s].join(",");
    , "a,b,c");
}

test "later: array spread of an array still works (fallback)" {
    try expectScriptIntWithBuiltins(
        \\const xs = [1, 2, 3];
        \\const ys = [...xs, ...xs];
        \\ys.length;
    , 6);
}

test "later: typeof Symbol() === 'symbol'" {
    try expectScriptStringWithBuiltins(
        \\typeof Symbol("desc");
    , "symbol");
}

test "later: Symbol(d) is identity-unique even with same description" {
    try expectScriptStringWithBuiltins(
        \\const a = Symbol("x");
        \\const b = Symbol("x");
        \\(a === b) + ":" + (a === a);
    , "false:true");
}

test "later: Symbol.for interns by key" {
    try expectScriptStringWithBuiltins(
        \\const a = Symbol.for("k");
        \\const b = Symbol.for("k");
        \\const c = Symbol.for("other");
        \\(a === b) + ":" + (a === c);
    , "true:false");
}

test "later: Symbol.keyFor on registered + non-registered" {
    try expectScriptStringWithBuiltins(
        \\const a = Symbol.for("hello");
        \\const b = Symbol("hello");
        \\Symbol.keyFor(a) + ":" + Symbol.keyFor(b);
    , "hello:undefined");
}

test "later: arr[Symbol.iterator]() yields values" {
    try expectScriptStringWithBuiltins(
        \\const it = [10, 20, 30][Symbol.iterator]();
        \\let s = "";
        \\let r = it.next();
        \\while (!r.done) { s = s + r.value + ","; r = it.next(); }
        \\s;
    , "10,20,30,");
}

test "later: Symbol.iterator identity" {
    try expectScriptStringWithBuiltins(
        \\(Symbol.iterator === Symbol.iterator) + "";
    , "true");
}

test "later: typeof of well-known symbols" {
    try expectScriptStringWithBuiltins(
        \\typeof Symbol.iterator;
    , "symbol");
}

// §20.4.2 — ES2026 explicit-resource-management well-known symbols.

test "later: Symbol.dispose / Symbol.asyncDispose typeof + description" {
    try expectScriptStringWithBuiltins(
        \\typeof Symbol.dispose + ":" + String(Symbol.dispose) + "|" +
        \\typeof Symbol.asyncDispose + ":" + String(Symbol.asyncDispose);
    , "symbol:Symbol(Symbol.dispose)|symbol:Symbol(Symbol.asyncDispose)");
}

test "later: Symbol.dispose identity stable across reads" {
    try expectScriptStringWithBuiltins(
        \\(Symbol.dispose === Symbol.dispose) + ":" +
        \\(Symbol.asyncDispose === Symbol.asyncDispose);
    , "true:true");
}

// §27.1.4.13 — %IteratorPrototype%[@@dispose] calls `return()` and
// returns undefined. The reference fixture lives at
// `built-ins/Iterator/prototype/Symbol.dispose/return-val.js`.

test "later: %IteratorPrototype%[@@dispose] returns undefined" {
    try expectScriptStringWithBuiltins(
        \\const ip = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
        \\typeof ip[Symbol.dispose]();
    , "undefined");
}

test "later: %IteratorPrototype%[@@dispose] invokes own return()" {
    try expectScriptStringWithBuiltins(
        \\const ip = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
        \\let called = 0;
        \\const o = { return() { called++; return { done: true }; } };
        \\Object.setPrototypeOf(o, ip);
        \\ip[Symbol.dispose].call(o);
        \\String(called);
    , "1");
}

// §27.1.4.14 — %AsyncIteratorPrototype%[@@asyncDispose] returns a
// Promise that fulfils with undefined after `return()` settles.

test "later: %AsyncIteratorPrototype%[@@asyncDispose] returns a Promise" {
    try expectScriptStringWithBuiltins(
        \\async function* g() {}
        \\const aip = Object.getPrototypeOf(Object.getPrototypeOf(g.prototype));
        \\(aip[Symbol.asyncDispose]() instanceof Promise) + "";
    , "true");
}

// §20.5.x SuppressedError — ES2026 explicit-resource-management.
// DisposeResources wraps an in-flight throw + a disposer throw with
// this Error subclass; the `error` slot is the new throw,
// `suppressed` is the previous.

test "later: SuppressedError(error, suppressed, message) populates slots" {
    try expectScriptStringWithBuiltins(
        \\const e = new SuppressedError("E", "S", "M");
        \\e.error + ":" + e.suppressed + ":" + e.message;
    , "E:S:M");
}

test "later: SuppressedError extends Error" {
    try expectScriptStringWithBuiltins(
        \\const e = new SuppressedError();
        \\(e instanceof Error) + ":" + (e instanceof SuppressedError) + ":" +
        \\(Object.getPrototypeOf(SuppressedError.prototype) === Error.prototype);
    , "true:true:true");
}

test "later: SuppressedError omitted message stays on prototype" {
    try expectScriptStringWithBuiltins(
        \\const e = new SuppressedError(1, 2);
        \\Object.prototype.hasOwnProperty.call(e, "message") + ":" +
        \\e.message + ":" + SuppressedError.prototype.message;
    , "false::");
}

test "later: SuppressedError default ctor arity" {
    try expectScriptIntWithBuiltins(
        \\SuppressedError.length;
    , 3);
}

// §27.3 DisposableStack — ES2026 explicit-resource-management.
// Synchronous resource stack. `.use(v)` / `.adopt(v, fn)` /
// `.defer(fn)` register resources; `.dispose()` walks them in
// LIFO order and wraps mid-disposal throws with SuppressedError.

test "later: DisposableStack is a function with length 0" {
    try expectScriptStringWithBuiltins(
        \\typeof DisposableStack + ":" + DisposableStack.length;
    , "function:0");
}

test "later: new DisposableStack() shape — .disposed is false" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\s.disposed + ":" + (s instanceof DisposableStack) + ":" +
        \\(Object.getPrototypeOf(s) === DisposableStack.prototype);
    , "false:true:true");
}

test "later: DisposableStack.prototype[Symbol.toStringTag]" {
    try expectScriptStringWithBuiltins(
        \\Object.prototype.toString.call(new DisposableStack());
    , "[object DisposableStack]");
}

test "later: DisposableStack.prototype[Symbol.dispose] === .dispose" {
    try expectScriptStringWithBuiltins(
        \\(DisposableStack.prototype[Symbol.dispose] ===
        \\  DisposableStack.prototype.dispose) + "";
    , "true");
}

test "later: DisposableStack.prototype.use(value) returns value" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\const r = { [Symbol.dispose]() {} };
        \\(s.use(r) === r) + "";
    , "true");
}

test "later: DisposableStack.prototype.use null/undefined no-op" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\(s.use(null) === null) + ":" + (s.use(undefined) === undefined);
    , "true:true");
}

test "later: DisposableStack.prototype.use({}) throws TypeError" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\let kind = "";
        \\try { s.use({}); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: DisposableStack.prototype.use after dispose throws ReferenceError" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\s.dispose();
        \\let kind = "";
        \\try { s.use({ [Symbol.dispose]() {} }); }
        \\catch (e) { kind = e.constructor.name; }
        \\kind;
    , "ReferenceError");
}

test "later: DisposableStack.prototype.adopt calls fn(value) at dispose" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\let seen = "";
        \\const ret = s.adopt(42, (v) => { seen = "v=" + v; });
        \\seen + "|" + ret;
        \\s.dispose();
        \\seen + "|" + ret;
    , "v=42|42");
}

test "later: DisposableStack.prototype.adopt non-callable throws TypeError" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\let kind = "";
        \\try { s.adopt(1, "not a fn"); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: DisposableStack.prototype.defer fires at dispose with no args" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\let log = "";
        \\const ret = s.defer(() => { log = "fired"; });
        \\(ret === undefined) + ":" + log + ":";
        \\s.dispose();
        \\(ret === undefined) + ":" + log;
    , "true:fired");
}

test "later: DisposableStack disposal order is LIFO" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\const log = [];
        \\s.defer(() => log.push("A"));
        \\s.defer(() => log.push("B"));
        \\s.defer(() => log.push("C"));
        \\s.dispose();
        \\log.join(",");
    , "C,B,A");
}

test "later: DisposableStack.prototype.dispose is idempotent" {
    try expectScriptIntWithBuiltins(
        \\const s = new DisposableStack();
        \\let calls = 0;
        \\s.defer(() => { calls += 1; });
        \\s.dispose();
        \\s.dispose();
        \\s.dispose();
        \\calls;
    , 1);
}

test "later: DisposableStack .disposed flips after dispose" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\const before = s.disposed;
        \\s.dispose();
        \\before + ":" + s.disposed;
    , "false:true");
}

test "later: DisposableStack single throwing disposer propagates" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\s.defer(() => { throw new Error("boom"); });
        \\let msg = "";
        \\try { s.dispose(); } catch (e) { msg = e.message; }
        \\msg;
    , "boom");
}

test "later: DisposableStack two throwing disposers wrap in SuppressedError" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\const e1 = new Error("one");
        \\const e2 = new Error("two");
        \\s.defer(() => { throw e1; });
        \\s.defer(() => { throw e2; });
        \\let kind = "", err = null, sup = null;
        \\try { s.dispose(); } catch (e) { kind = e.constructor.name; err = e.error; sup = e.suppressed; }
        \\// Disposal is LIFO: e2 throws first (most-recent disposer),
        \\// e1 throws next and becomes the new "error" with e2 as
        \\// suppressed (§9.5.4 step 2.b.iv-vi).
        \\kind + ":" + err.message + ":" + sup.message;
    , "SuppressedError:one:two");
}

test "later: DisposableStack.prototype.move transfers resources" {
    try expectScriptStringWithBuiltins(
        \\const s1 = new DisposableStack();
        \\const log = [];
        \\s1.defer(() => log.push("A"));
        \\s1.defer(() => log.push("B"));
        \\const s2 = s1.move();
        \\(s2 instanceof DisposableStack) + ":" +
        \\s1.disposed + ":" + s2.disposed;
    , "true:true:false");
}

test "later: DisposableStack.prototype.move source can't add resources" {
    try expectScriptStringWithBuiltins(
        \\const s1 = new DisposableStack();
        \\s1.defer(() => {});
        \\const s2 = s1.move();
        \\let kind = "";
        \\try { s1.defer(() => {}); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "ReferenceError");
}

test "later: DisposableStack.prototype.move target disposes moved resources" {
    try expectScriptStringWithBuiltins(
        \\const s1 = new DisposableStack();
        \\const log = [];
        \\s1.defer(() => log.push("A"));
        \\s1.defer(() => log.push("B"));
        \\const s2 = s1.move();
        \\s1.dispose();
        \\log.join(",") + "|";
        \\s2.dispose();
        \\log.join(",");
    , "B,A");
}

test "later: DisposableStack.prototype.move after dispose throws" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\s.dispose();
        \\let kind = "";
        \\try { s.move(); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "ReferenceError");
}

test "later: DisposableStack called without new throws TypeError" {
    try expectScriptStringWithBuiltins(
        \\let kind = "";
        \\try { DisposableStack(); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: DisposableStack brand check on prototype methods" {
    try expectScriptStringWithBuiltins(
        \\let kinds = [];
        \\const m = DisposableStack.prototype.use;
        \\try { m.call({}, null); } catch (e) { kinds.push(e.constructor.name); }
        \\try { DisposableStack.prototype.dispose.call({}); } catch (e) { kinds.push(e.constructor.name); }
        \\kinds.join(",");
    , "TypeError,TypeError");
}

test "later: DisposableStack.prototype.use fires Symbol.dispose" {
    try expectScriptStringWithBuiltins(
        \\const s = new DisposableStack();
        \\let log = "";
        \\s.use({ [Symbol.dispose]() { log = "disposed"; } });
        \\s.dispose();
        \\log;
    , "disposed");
}

// ── ES2026 explicit-resource-management — `using` declarations.
// Block-scoped resource binding (§14.3.x / §13.2.4.6).

test "later: using disposes binding at normal block exit" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\{
        \\  using x = { [Symbol.dispose]() { log = "disposed"; } };
        \\}
        \\log;
    , "disposed");
}

test "later: using disposes multiple bindings in LIFO order" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\{
        \\  using a = { [Symbol.dispose]() { log.push("A"); } };
        \\  using b = { [Symbol.dispose]() { log.push("B"); } };
        \\  using c = { [Symbol.dispose]() { log.push("C"); } };
        \\}
        \\log.join(",");
    , "C,B,A");
}

test "later: using fires disposers on throw" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\let msg = "";
        \\try {
        \\  using x = { [Symbol.dispose]() { log = "disposed"; } };
        \\  throw new Error("boom");
        \\} catch (e) { msg = e.message; }
        \\log + ":" + msg;
    , "disposed:boom");
}

test "later: using mid-disposal throw wraps with SuppressedError" {
    try expectScriptStringWithBuiltins(
        \\const e1 = new Error("one");
        \\const e2 = new Error("two");
        \\let kind = "", err = null, sup = null;
        \\try {
        \\  using a = { [Symbol.dispose]() { throw e1; } };
        \\  using b = { [Symbol.dispose]() { throw e2; } };
        \\} catch (e) { kind = e.constructor.name; err = e.error; sup = e.suppressed; }
        \\// LIFO: e2 throws first (most-recent), e1 throws next and
        \\// becomes the new error with e2 as suppressed (§9.5.4 step 2.b.iv-vi).
        \\kind + ":" + err.message + ":" + sup.message;
    , "SuppressedError:one:two");
}

test "later: using disposes before return propagates" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\function f() {
        \\  using x = { [Symbol.dispose]() { log = "disposed"; } };
        \\  return "ret";
        \\}
        \\const r = f();
        \\log + ":" + r;
    , "disposed:ret");
}

test "later: using disposes on break out of block-labelled" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\outer: {
        \\  using x = { [Symbol.dispose]() { log = "disposed"; } };
        \\  break outer;
        \\}
        \\log;
    , "disposed");
}

test "later: using disposes on continue through loop" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\for (let i = 0; i < 3; i++) {
        \\  using x = { [Symbol.dispose]() { log.push("d" + i); } };
        \\  if (i === 1) continue;
        \\  log.push("body" + i);
        \\}
        \\log.join(",");
    , "body0,d0,d1,body2,d2");
}

test "later: using null is a legal no-op" {
    try expectScriptStringWithBuiltins(
        \\let log = "ok";
        \\{
        \\  using x = null;
        \\}
        \\log;
    , "ok");
}

test "later: using undefined is a legal no-op" {
    try expectScriptStringWithBuiltins(
        \\let log = "ok";
        \\{
        \\  using x = undefined;
        \\}
        \\log;
    , "ok");
}

test "later: using non-disposable object throws TypeError at decl" {
    try expectScriptStringWithBuiltins(
        \\let kind = "", reached_after = false;
        \\try {
        \\  using x = {};
        \\  reached_after = true;
        \\} catch (e) { kind = e.constructor.name; }
        \\kind + ":" + reached_after;
    , "TypeError:false");
}

test "later: nested using scopes dispose inner before outer" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\{
        \\  using outer = { [Symbol.dispose]() { log.push("outer"); } };
        \\  {
        \\    using inner = { [Symbol.dispose]() { log.push("inner"); } };
        \\  }
        \\  log.push("between");
        \\}
        \\log.join(",");
    , "inner,between,outer");
}

test "later: using value bound to const is visible inside block" {
    try expectScriptStringWithBuiltins(
        \\let observed = 0;
        \\{
        \\  using r = { value: 42, [Symbol.dispose]() {} };
        \\  observed = r.value;
        \\}
        \\observed + "";
    , "42");
}

test "later: using rebind from inner function throws TypeError" {
    // §14.3.x — `using` bindings are immutable (const-like). A
    // direct in-scope `x = …` is rejected at compile time
    // (matching how Cynic treats `const x = 1; x = 2;` in the
    // same scope). A cross-function rebind escapes the static
    // check and surfaces as the spec-shaped runtime TypeError
    // from SetMutableBinding step 9.b.
    try expectScriptStringWithBuiltins(
        \\let kind = "";
        \\try {
        \\  {
        \\    using x = { [Symbol.dispose]() {} };
        \\    (function () { x = null; })();
        \\  }
        \\} catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: for-of with using disposes per iteration" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const items = [
        \\  { id: "a", [Symbol.dispose]() { log.push("d-a"); } },
        \\  { id: "b", [Symbol.dispose]() { log.push("d-b"); } },
        \\  { id: "c", [Symbol.dispose]() { log.push("d-c"); } },
        \\];
        \\for (using r of items) {
        \\  log.push("body-" + r.id);
        \\}
        \\log.join(",");
    , "body-a,d-a,body-b,d-b,body-c,d-c");
}

test "later: for-of using disposes on early break" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const items = [
        \\  { id: "a", [Symbol.dispose]() { log.push("d-a"); } },
        \\  { id: "b", [Symbol.dispose]() { log.push("d-b"); } },
        \\  { id: "c", [Symbol.dispose]() { log.push("d-c"); } },
        \\];
        \\for (using r of items) {
        \\  log.push("body-" + r.id);
        \\  if (r.id === "b") break;
        \\}
        \\log.join(",");
    , "body-a,d-a,body-b,d-b");
}

test "later: for-of using disposes on throw inside body" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const items = [
        \\  { id: "a", [Symbol.dispose]() { log.push("d-a"); } },
        \\  { id: "b", [Symbol.dispose]() { log.push("d-b"); } },
        \\];
        \\try {
        \\  for (using r of items) {
        \\    log.push("body-" + r.id);
        \\    if (r.id === "a") throw new Error("stop");
        \\  }
        \\} catch (e) { log.push("caught:" + e.message); }
        \\log.join(",");
    , "body-a,d-a,caught:stop");
}

test "later: C-style for-using disposes at end of whole loop" {
    // §14.3.x — `for (using x = init; cond; step) body` allocates a
    // single dispose stack at for-entry; the binding registers
    // once, the disposer fires ONCE at for-exit (NOT per
    // iteration). Two iterations should observe the resource
    // still-alive in both, and disposed only after the loop ends.
    // Step variable lives outside the using-decl (the spec lets
    // you mix but a sibling let-binding inside a using-decl
    // would be const-protected and `i++` would throw).
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const r = { [Symbol.dispose]() { log.push("disposed"); } };
        \\let i = 0;
        \\for (using _ = r; i < 2; i++) { log.push("iter" + i); }
        \\log.join(",");
    , "iter0,iter1,disposed");
}

test "later: C-style for-using fires on subsequent-init throw" {
    // §9.5.4 step 2.b — when a SECOND init throws, the FIRST
    // init's disposer must still fire (the throw becomes the
    // in-flight completion that the dispose walk wraps via
    // SuppressedError if a disposer also throws).
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const r1 = { [Symbol.dispose]() { log.push("d1"); } };
        \\function init2() { throw new Error("init2-fail"); }
        \\try {
        \\  for (using _1 = r1, _2 = init2(); false;) {}
        \\} catch (e) { log.push("caught:" + e.message); }
        \\log.join(",");
    , "d1,caught:init2-fail");
}

// §14.3.x AwaitUsingDeclaration — ES2026 explicit-resource-management.
// `await using x = expr;` registers with hint = async-dispose; the
// scope-exit walk awaits each disposer (whether the disposer is sync
// or returns a thenable). Only valid in async function bodies, async
// generator bodies, and module top-level.

test "later: await using awaits sync Symbol.asyncDispose at block exit" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\async function f() {
        \\  {
        \\    await using a = { [Symbol.asyncDispose]() { log.push("a-async"); } };
        \\    log.push("body");
        \\  }
        \\  log.push("after");
        \\  return log.join(",");
        \\}
        \\let result = "?";
        \\f().then(v => { result = v; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "body,a-async,after");
}

test "later: await using disposes in LIFO across sync + async hints" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\async function f() {
        \\  {
        \\    using c = { [Symbol.dispose]() { log.push("c-sync"); } };
        \\    await using b = { async [Symbol.asyncDispose]() { log.push("b-async"); } };
        \\    await using a = { [Symbol.asyncDispose]() { log.push("a-async"); } };
        \\    log.push("body");
        \\  }
        \\  log.push("after");
        \\  return log.join(",");
        \\}
        \\let result = "?";
        \\f().then(v => { result = v; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "body,a-async,b-async,c-sync,after");
}

test "later: await using disposes before return propagates" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\async function f() {
        \\  await using r = { [Symbol.asyncDispose]() { log.push("disposed"); } };
        \\  return "ret";
        \\}
        \\let result = "?";
        \\f().then(v => { log.push("got:" + v); result = log.join(","); });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "disposed,got:ret");
}

test "later: await using disposer throw rejects the function's Promise" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\async function f() {
        \\  await using r = { [Symbol.asyncDispose]() { throw new Error("disposer"); } };
        \\  log.push("body");
        \\}
        \\let result = "?";
        \\f().then(
        \\  v => { result = "ok:" + v; },
        \\  e => { result = "err:" + e.message + ":" + log.join(","); },
        \\);
        \\globalThis.__drainMicrotasks();
        \\result;
    , "err:disposer:body");
}

test "later: await using chains in-flight throw + disposer throw via SuppressedError" {
    try expectScriptStringWithBuiltins(
        \\async function f() {
        \\  try {
        \\    {
        \\      await using a = { [Symbol.asyncDispose]() { throw new Error("dispose-a"); } };
        \\      throw new Error("body");
        \\    }
        \\  } catch (e) {
        \\    return e.constructor.name + ":err=" + e.error.message + ":sup=" + e.suppressed.message;
        \\  }
        \\}
        \\let result = "?";
        \\f().then(v => { result = v; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "SuppressedError:err=dispose-a:sup=body");
}

test "later: await using async disposer awaits returned Promise" {
    // §9.5.2 step 1.a + §9.5.4 — when the disposer returns a
    // thenable, the walk awaits it before stepping to the next
    // resource.
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\async function f() {
        \\  {
        \\    await using b = { async [Symbol.asyncDispose]() {
        \\      await Promise.resolve();
        \\      log.push("b-resolved");
        \\    } };
        \\    await using a = { async [Symbol.asyncDispose]() {
        \\      log.push("a-pre");
        \\      await Promise.resolve();
        \\      log.push("a-resolved");
        \\    } };
        \\    log.push("body");
        \\  }
        \\  log.push("done");
        \\}
        \\f().then(() => {});
        \\globalThis.__drainMicrotasks();
        \\log.join(",");
    , "body,a-pre,a-resolved,b-resolved,done");
}

// §27.4 AsyncDisposableStack — ES2026 explicit-resource-management.
// Asynchronous resource stack. `.use(v)` accepts either
// `Symbol.asyncDispose` (preferred) or `Symbol.dispose`.
// `.disposeAsync()` returns a Promise that fulfils once the LIFO
// walk awaits every disposer; rejections compose via SuppressedError
// across multiple in-flight throws (§9.5.4 step 2.b.iv-vi).

test "later: AsyncDisposableStack is a function with length 0" {
    try expectScriptStringWithBuiltins(
        \\typeof AsyncDisposableStack + ":" + AsyncDisposableStack.length;
    , "function:0");
}

test "later: new AsyncDisposableStack() shape — .disposed is false" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.disposed + ":" + (s instanceof AsyncDisposableStack) + ":" +
        \\(Object.getPrototypeOf(s) === AsyncDisposableStack.prototype);
    , "false:true:true");
}

test "later: AsyncDisposableStack.prototype[Symbol.toStringTag]" {
    try expectScriptStringWithBuiltins(
        \\Object.prototype.toString.call(new AsyncDisposableStack());
    , "[object AsyncDisposableStack]");
}

test "later: AsyncDisposableStack.prototype[Symbol.asyncDispose] === .disposeAsync" {
    try expectScriptStringWithBuiltins(
        \\(AsyncDisposableStack.prototype[Symbol.asyncDispose] ===
        \\  AsyncDisposableStack.prototype.disposeAsync) + "";
    , "true");
}

test "later: AsyncDisposableStack.prototype has no Symbol.dispose" {
    // §27.4.3 — the async stack only carries [@@asyncDispose].
    // A user who tries to wire it into a sync `using` binding
    // gets a TypeError from `GetDisposeMethod(V, sync-dispose)`.
    try expectScriptStringWithBuiltins(
        \\(Symbol.dispose in AsyncDisposableStack.prototype) + "";
    , "false");
}

test "later: AsyncDisposableStack.prototype.use(value) returns value" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const r = { [Symbol.asyncDispose]() {} };
        \\(s.use(r) === r) + "";
    , "true");
}

test "later: AsyncDisposableStack.prototype.use null/undefined no-op" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\(s.use(null) === null) + ":" + (s.use(undefined) === undefined);
    , "true:true");
}

test "later: AsyncDisposableStack.prototype.use({}) throws TypeError" {
    // §9.5.2 GetDisposeMethod(V, async-dispose): step 1.a checks
    // @@asyncDispose; step 1.b falls back to @@dispose. Neither
    // is present here, so TypeError.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let kind = "";
        \\try { s.use({}); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: AsyncDisposableStack.use accepts Symbol.dispose fallback" {
    // §9.5.2 step 1.b — when V has no @@asyncDispose, the sync
    // @@dispose method is adopted. The async walk awaits its
    // (synchronous) return value anyway.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let log = "";
        \\s.use({ [Symbol.dispose]() { log = "sync-fallback"; } });
        \\let final = "";
        \\s.disposeAsync().then(v => { final = (v === undefined) + ":" + log; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , "true:sync-fallback");
}

test "later: AsyncDisposableStack.use prefers Symbol.asyncDispose over Symbol.dispose" {
    // §9.5.2 step 1.a — when both methods are present, the async
    // hint picks @@asyncDispose first and never consults @@dispose.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let picked = "";
        \\s.use({
        \\  [Symbol.asyncDispose]() { picked = "async"; },
        \\  [Symbol.dispose]() { picked = "sync"; },
        \\});
        \\s.disposeAsync();
        \\globalThis.__drainMicrotasks();
        \\picked;
    , "async");
}

test "later: AsyncDisposableStack.prototype.use after dispose throws ReferenceError" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.disposeAsync();
        \\globalThis.__drainMicrotasks();
        \\let kind = "";
        \\try { s.use({ [Symbol.asyncDispose]() {} }); }
        \\catch (e) { kind = e.constructor.name; }
        \\kind;
    , "ReferenceError");
}

test "later: AsyncDisposableStack.prototype.disposeAsync returns a Promise" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const p = s.disposeAsync();
        \\(p instanceof Promise) + "";
    , "true");
}

test "later: AsyncDisposableStack.disposeAsync fulfils with undefined after sync disposer" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let log = "";
        \\s.defer(() => { log = "fired"; });
        \\let result = "?";
        \\s.disposeAsync().then(v => { result = log + ":" + (v === undefined); });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "fired:true");
}

test "later: AsyncDisposableStack awaits an async disposer" {
    // The disposer returns a Promise; the next step doesn't fire
    // until that Promise settles. We assert ordering: the sentinel
    // string is built up across two microtask turns.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const log = [];
        \\s.defer(() => Promise.resolve().then(() => { log.push("A-done"); }));
        \\s.defer(() => { log.push("B-sync"); });
        \\let final = "";
        \\s.disposeAsync().then(() => { log.push("settled"); final = log.join(","); });
        \\globalThis.__drainMicrotasks();
        \\final;
    , "B-sync,A-done,settled");
}

test "later: AsyncDisposableStack.disposeAsync disposal order is LIFO" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const log = [];
        \\s.defer(() => log.push("A"));
        \\s.defer(() => log.push("B"));
        \\s.defer(() => log.push("C"));
        \\let out = "";
        \\s.disposeAsync().then(() => { out = log.join(","); });
        \\globalThis.__drainMicrotasks();
        \\out;
    , "C,B,A");
}

test "later: AsyncDisposableStack single throwing disposer rejects Promise" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.defer(() => { throw new Error("boom"); });
        \\let msg = "";
        \\s.disposeAsync().then(
        \\  () => { msg = "fulfilled"; },
        \\  e => { msg = e.message; },
        \\);
        \\globalThis.__drainMicrotasks();
        \\msg;
    , "boom");
}

test "later: AsyncDisposableStack two throwing disposers wrap in SuppressedError" {
    // Disposal is LIFO: the second-added disposer (B) fires first;
    // when the first-added (A) then throws, A becomes [[Error]]
    // and B becomes [[Suppressed]] per §9.5.4 step 2.b.iv-vi.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const eA = new Error("A");
        \\const eB = new Error("B");
        \\s.defer(() => { throw eA; });
        \\s.defer(() => { throw eB; });
        \\let kind = "", err = null, sup = null;
        \\s.disposeAsync().then(
        \\  () => {},
        \\  e => { kind = e.constructor.name; err = e.error; sup = e.suppressed; },
        \\);
        \\globalThis.__drainMicrotasks();
        \\kind + ":" + err.message + ":" + sup.message;
    , "SuppressedError:A:B");
}

test "later: AsyncDisposableStack rejected async disposer composes via SuppressedError" {
    // A disposer that returns Promise.reject(...) is observably
    // the same as a sync-throwing disposer once awaited.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.defer(() => Promise.reject(new Error("A")));
        \\s.defer(() => { throw new Error("B"); });
        \\let kind = "", err = "", sup = "";
        \\s.disposeAsync().then(
        \\  () => {},
        \\  e => { kind = e.constructor.name; err = e.error.message; sup = e.suppressed.message; },
        \\);
        \\globalThis.__drainMicrotasks();
        \\kind + ":" + err + ":" + sup;
    , "SuppressedError:A:B");
}

test "later: AsyncDisposableStack.disposeAsync is idempotent" {
    // Second call must NOT walk the (now-empty) resource list
    // again; it returns a fulfilled-with-undefined Promise.
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let calls = 0;
        \\s.defer(() => { calls += 1; });
        \\s.disposeAsync();
        \\s.disposeAsync();
        \\s.disposeAsync();
        \\globalThis.__drainMicrotasks();
        \\calls + ":" + s.disposed;
    , "1:true");
}

test "later: AsyncDisposableStack second disposeAsync returns fulfilled Promise" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.disposeAsync();
        \\globalThis.__drainMicrotasks();
        \\let v = "?";
        \\s.disposeAsync().then(r => { v = (r === undefined) + ""; });
        \\globalThis.__drainMicrotasks();
        \\v;
    , "true");
}

test "later: AsyncDisposableStack.prototype.adopt awaits a thenable onDispose" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const log = [];
        \\const ret = s.adopt("payload", (v) => Promise.resolve().then(() => log.push("got:" + v)));
        \\let out = "";
        \\s.disposeAsync().then(() => { log.push("settled"); out = log.join(","); });
        \\globalThis.__drainMicrotasks();
        \\ret + "|" + out;
    , "payload|got:payload,settled");
}

test "later: AsyncDisposableStack.prototype.defer fires at disposeAsync with no args" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\let log = "";
        \\const ret = s.defer((...args) => { log = "fired:" + args.length; });
        \\let after = "";
        \\s.disposeAsync().then(() => { after = (ret === undefined) + ":" + log; });
        \\globalThis.__drainMicrotasks();
        \\after;
    , "true:fired:0");
}

test "later: AsyncDisposableStack.prototype.move returns a fresh AsyncDisposableStack" {
    try expectScriptStringWithBuiltins(
        \\const s1 = new AsyncDisposableStack();
        \\s1.defer(() => {});
        \\const s2 = s1.move();
        \\(s2 instanceof AsyncDisposableStack) + ":" +
        \\(s2 instanceof DisposableStack) + ":" +
        \\s1.disposed + ":" + s2.disposed;
    , "true:false:true:false");
}

test "later: AsyncDisposableStack.prototype.move transfers resources" {
    try expectScriptStringWithBuiltins(
        \\const s1 = new AsyncDisposableStack();
        \\const log = [];
        \\s1.defer(() => log.push("A"));
        \\s1.defer(() => log.push("B"));
        \\const s2 = s1.move();
        \\let out = "";
        \\s1.disposeAsync().then(() => {
        \\  log.push("s1-done");
        \\  s2.disposeAsync().then(() => { log.push("s2-done"); out = log.join(","); });
        \\});
        \\globalThis.__drainMicrotasks();
        \\out;
    , "s1-done,B,A,s2-done");
}

test "later: AsyncDisposableStack.prototype.move after dispose throws" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\s.disposeAsync();
        \\globalThis.__drainMicrotasks();
        \\let kind = "";
        \\try { s.move(); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "ReferenceError");
}

test "later: AsyncDisposableStack called without new throws TypeError" {
    try expectScriptStringWithBuiltins(
        \\let kind = "";
        \\try { AsyncDisposableStack(); } catch (e) { kind = e.constructor.name; }
        \\kind;
    , "TypeError");
}

test "later: AsyncDisposableStack brand check on prototype methods" {
    // §27.4.3 RequireInternalSlot(O, [[AsyncDisposableState]]):
    // a sync DisposableStack must NOT pass either, and a plain
    // object must NOT pass.
    try expectScriptStringWithBuiltins(
        \\const kinds = [];
        \\try { AsyncDisposableStack.prototype.use.call({}, null); }
        \\catch (e) { kinds.push(e.constructor.name); }
        \\try { AsyncDisposableStack.prototype.use.call(new DisposableStack(), null); }
        \\catch (e) { kinds.push(e.constructor.name); }
        \\try { DisposableStack.prototype.dispose.call(new AsyncDisposableStack()); }
        \\catch (e) { kinds.push(e.constructor.name); }
        \\kinds.join(",");
    , "TypeError,TypeError,TypeError");
}

test "later: AsyncDisposableStack.use fires Symbol.asyncDispose with correct this" {
    try expectScriptStringWithBuiltins(
        \\const s = new AsyncDisposableStack();
        \\const r = {
        \\  tag: "r1",
        \\  [Symbol.asyncDispose]() { return Promise.resolve(this.tag); },
        \\};
        \\let log = "";
        \\s.use(r);
        \\s.disposeAsync().then(() => { log = "done"; });
        \\globalThis.__drainMicrotasks();
        \\log;
    , "done");
}

test "later: tagged template passes cooked + raw arrays" {
    try expectScriptStringWithBuiltins(
        \\function tag(strs) {
        \\  return strs.length + ":" + strs[0] + ":" + strs.raw[0];
        \\}
        \\tag`a\nb`;
    , "1:a\nb:a\\nb");
}

test "later: tagged template forwards substitutions" {
    try expectScriptStringWithBuiltins(
        \\function tag(strs, x, y) {
        \\  return strs[0] + x + strs[1] + y + strs[2];
        \\}
        \\tag`<${1}-${2}>`;
    , "<1-2>");
}

test "later: Function.prototype.bind pins this + prefix args" {
    try expectScriptStringWithBuiltins(
        \\function f(a, b) { return this.x + ":" + a + ":" + b; }
        \\const me = { x: "self" };
        \\const g = f.bind(me, "first");
        \\g("second");
    , "self:first:second");
}

test "later: Function.prototype.bind chained" {
    try expectScriptIntWithBuiltins(
        \\function add(a, b, c, d) { return a + b + c + d; }
        \\const a1 = add.bind(null, 1);
        \\const a12 = a1.bind(null, 2);
        \\const a123 = a12.bind(null, 3);
        \\a123(4);
    , 10);
}

test "later: bound function [[Construct]] threads new.target to target (§10.4.1.2)" {
    // Mirrors built-ins/Function/prototype/bind/instance-construct-newtarget-self-new.js:
    // `new C()` where C = B.bind() and B = A.bind() — per step 5
    // of §10.4.1.2 [[Construct]], `SameValue(F, newTarget)`
    // collapses newTarget to the (fully-unwrapped) target. Inside
    // A, `new.target` must be A, not undefined.
    try expectScriptStringWithBuiltins(
        \\var nt;
        \\function A() { nt = new.target; }
        \\var B = A.bind();
        \\var C = B.bind();
        \\new C();
        \\(nt === A) ? "ok" : "no";
    , "ok");
}

test "later: Reflect.construct(BoundFn, args, NT) threads explicit newTarget (§10.5.14)" {
    // Mirrors built-ins/Function/prototype/bind/instance-construct-newtarget-boundtarget.js:
    // `Reflect.construct(C, [], A)` with C = B.bind(), B = A.bind()
    // — newTarget is the explicit A, propagates through the bound
    // chain unchanged, and is observable inside A.
    try expectScriptStringWithBuiltins(
        \\var nt;
        \\function A() { nt = new.target; }
        \\var B = A.bind();
        \\var C = B.bind();
        \\Reflect.construct(C, [], A);
        \\(nt === A) ? "ok" : "no";
    , "ok");
}

test "later: Reflect.apply accepts a callable argumentsList with a length getter (§7.3.18 / §6.1.7)" {
    // built-ins/Reflect/apply/arguments-list-is-not-array-like-but-still-valid.js:
    // §7.3.18 CreateListFromArrayLike requires `argumentsList` to be
    // an Object — and §6.1.7 a function IS an Object. A function with
    // a `length` getter returning 1 is a valid array-like; the call
    // receives `[undefined]`.
    try expectScriptIntWithBuiltins(
        \\function fn(...a) { return a.length; }
        \\let f = function () {};
        \\Object.defineProperty(f, "length", { get() { return 1; } });
        \\Reflect.apply(fn, null, f);
    , 1);
}

test "later: Reflect.apply callable argumentsList getter delivers undefined slot (§7.3.18)" {
    // The single indexed read on the function array-like is absent, so
    // CreateListFromArrayLike yields `[undefined]`.
    try expectScriptStringWithBuiltins(
        \\function fn(...a) { return (a.length === 1 && a[0] === undefined) ? "ok" : "no"; }
        \\let f = function () {};
        \\Object.defineProperty(f, "length", { get() { return 1; } });
        \\Reflect.apply(fn, null, f);
    , "ok");
}

test "later: Reflect.construct accepts a callable argumentsList with a length getter (§7.3.18 / §6.1.7)" {
    try expectScriptIntWithBuiltins(
        \\let received;
        \\function C(...a) { received = a; }
        \\let f = function () {};
        \\Object.defineProperty(f, "length", { get() { return 1; } });
        \\Reflect.construct(C, f);
        \\received.length;
    , 1);
}

test "later: Reflect.apply primitive argumentsList still throws TypeError (§7.3.18 step 2)" {
    // Type(argumentsList) is not Object — a number is a primitive, so
    // the negative guard must remain: TypeError, no over-loosening.
    try expectScriptThrowsWithBuiltins(
        \\function fn() {}
        \\Reflect.apply(fn, null, 42);
    );
}

test "later: Reflect.construct primitive argumentsList still throws TypeError (§7.3.18 step 2)" {
    try expectScriptThrowsWithBuiltins(
        \\function C() {}
        \\Reflect.construct(C, 42);
    );
}

test "later: Reflect.construct with a Proxy-chain newTarget unwraps to the constructor (§7.2.4 / §10.5.13)" {
    // A Proxy over a Proxy over a constructor IS a constructor, so the
    // newTarget resolution must descend the WHOLE chain — a single-level
    // unwrap wrongly threw "newTarget must be a constructor". Same-realm
    // here, so the created object's prototype resolves through the chain
    // to the underlying ctor's `prototype` (the cross-realm
    // GetFunctionRealm path is exercised by test262
    // built-ins/Proxy/get-fn-realm*).
    try expectScriptIntWithBuiltins(
        \\var P = new Proxy(new Proxy(Array, {}), {});
        \\var a = Reflect.construct(Array, [], P);
        \\(a instanceof Array) ? 1 : 0;
    , 1);
}

test "later: for-in walks own properties" {
    try expectScriptStringWithBuiltins(
        \\const o = { a: 1, b: 2, c: 3 };
        \\let s = "";
        \\for (const k in o) s = s + k;
        \\s;
    , "abc");
}

test "later: for-in own non-enumerable shadows proto enumerable" {
    // §14.7.5.6 EnumerateObjectProperties — an own
    // non-enumerable key shadows a prototype enumerable key of
    // the same name, so it's neither enumerated nor "punched
    // through" to the proto-side value.
    try expectScriptStringWithBuiltins(
        \\const proto = { p2: "proto" };
        \\const o = Object.create(proto, {
        \\  p1: { value: 1, enumerable: true },
        \\  p2: { value: 2, enumerable: false }
        \\});
        \\let s = "";
        \\for (const k in o) s = s + k;
        \\s;
    , "p1");
}

test "later: for-in over null/undefined yields nothing" {
    try expectScriptIntWithBuiltins(
        \\let n = 0;
        \\for (const k in null) n++;
        \\for (const k in undefined) n++;
        \\n;
    , 0);
}

test "later: for-in delivers each key as a string" {
    try expectScriptStringWithBuiltins(
        \\const o = { x: "a", y: "b" };
        \\let s = "";
        \\for (const k in o) s = s + k + ":" + (typeof k) + ",";
        \\s;
    , "x:string,y:string,");
}

test "later: closure-per-iteration in for (let x of …)" {
    try expectScriptStringWithBuiltins(
        \\const fns = [];
        \\for (let i of [1, 2, 3]) fns.push(() => i);
        \\fns[0]() + "," + fns[1]() + "," + fns[2]();
    , "1,2,3");
}

test "later: closure-per-iteration with const binding" {
    try expectScriptStringWithBuiltins(
        \\const out = [];
        \\for (const x of ["a", "b", "c"]) out.push(() => x);
        \\out[0]() + out[1]() + out[2]();
    , "abc");
}

test "later: var binding shares one slot across iterations (legacy)" {
    // `var` is hoisted to the function scope and intentionally
    // does NOT get per-iteration semantics — closures see the
    // final value. Spec §14.7.5.6 step 2.b.i.
    try expectScriptIntWithBuiltins(
        \\const fns = [];
        \\for (var i of [1, 2, 3]) fns.push(function () { return i; });
        \\fns[0]() + fns[1]() + fns[2]();
    , 9);
}

test "later: per-iter env doesn't leak: outer let is reachable" {
    try expectScriptStringWithBuiltins(
        \\let acc = "";
        \\for (let v of ["x", "y"]) acc = acc + v;
        \\acc;
    , "xy");
}

test "later: break in for-let-of pops the per-iter env" {
    // After break, accessing outer bindings must still work
    // (env stack restored by the compiler-emitted pop_env).
    try expectScriptStringWithBuiltins(
        \\let n = 0;
        \\for (let v of [1, 2, 3, 4]) {
        \\  if (v === 3) break;
        \\  n = n + v;
        \\}
        \\n + "/" + (typeof n);
    , "3/number");
}

test "later: continue lands at the per-iter env teardown" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let v of [1, 2, 3, 4]) {
        \\  if (v === 2) continue;
        \\  s = s + v;
        \\}
        \\s;
    , 8);
}

test "later: closure-per-iteration in C-style for-let" {
    try expectScriptStringWithBuiltins(
        \\const fns = [];
        \\for (let i = 0; i < 3; i++) fns.push(() => i);
        \\fns[0]() + "," + fns[1]() + "," + fns[2]();
    , "0,1,2");
}

test "later: C-style for-let body still updates the binding" {
    try expectScriptIntWithBuiltins(
        \\let total = 0;
        \\for (let i = 0; i < 5; i++) total = total + i;
        \\total;
    , 10);
}

test "later: C-style for-var keeps legacy single-slot semantics" {
    // `var` is hoisted to the function scope; closures share
    // one slot per the spec.
    try expectScriptIntWithBuiltins(
        \\const fns = [];
        \\for (var i = 0; i < 3; i++) fns.push(function() { return i; });
        \\fns[0]() + fns[1]() + fns[2]();
    , 9);
}

test "later: break in C-style for-let pops the per-iter env" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let i = 0; i < 100; i++) {
        \\  if (i === 4) break;
        \\  s = s + i;
        \\}
        \\s;
    , 6);
}

test "later: Object.defineProperty creates a non-enumerable property" {
    try expectScriptStringWithBuiltins(
        \\const o = {};
        \\Object.defineProperty(o, "x", { value: 42, enumerable: false });
        \\o.x + ":" + Object.keys(o).length;
    , "42:0");
}

test "later: Object.getOwnPropertyDescriptor reads back flags" {
    try expectScriptStringWithBuiltins(
        \\const o = {};
        \\Object.defineProperty(o, "k", { value: 7, writable: false, enumerable: true, configurable: false });
        \\const d = Object.getOwnPropertyDescriptor(o, "k");
        \\d.value + ":" + d.writable + ":" + d.enumerable + ":" + d.configurable;
    , "7:false:true:false");
}

test "later: built-in proto methods are non-enumerable" {
    // for-in over an array shouldn't surface push, pop, etc.
    try expectScriptStringWithBuiltins(
        \\const arr = [];
        \\arr.x = 1;
        \\arr.y = 2;
        \\let s = "";
        \\for (const k in arr) s = s + k + ",";
        \\s;
    , "x,y,");
}

test "later: Object.keys filters non-enumerable own properties" {
    try expectScriptIntWithBuiltins(
        \\const o = { a: 1, b: 2 };
        \\Object.defineProperty(o, "hidden", { value: 0, enumerable: false });
        \\Object.keys(o).length;
    , 2);
}

test "later: Object.getOwnPropertyNames includes non-enumerable" {
    // Unlike `keys`, `getOwnPropertyNames` returns ALL own property
    // names (excluding internal `__cynic_*` slots).
    try expectScriptIntWithBuiltins(
        \\const o = { a: 1 };
        \\Object.defineProperty(o, "hidden", { value: 0, enumerable: false });
        \\Object.getOwnPropertyNames(o).length;
    , 2);
}

test "later: Object.values walks accessor + data keys in chronological order" {
    // §7.3.21 EnumerableOwnPropertyNames + §10.1.11
    // OrdinaryOwnPropertyKeys: when `a` is installed as an
    // accessor before `b` is installed as a data property,
    // redefining `a` must NOT move its slot. Order is `[a, b]`.
    // built-ins/Object/values/order-after-define-property.js.
    try expectScriptStringWithBuiltins(
        \\const o = {};
        \\Object.defineProperty(o, "a", {
        \\  get() { return 1; },
        \\  enumerable: true,
        \\  configurable: true,
        \\});
        \\o.b = "b";
        \\Object.defineProperty(o, "a", { get() { return "a"; } });
        \\Object.values(o).join(",");
    , "a,b");
}

test "later: Promise.resolve + .then is microtask-deferred" {
    // Microtask scheduling: the.then callback runs only after
    // the current sync stack drains. With a real microtask
    // queue, the log should be "sync,then".
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\Promise.resolve(1).then(v => { log = log + "then" + v + ","; });
        \\log = log + "sync,";
        \\globalThis.__drainMicrotasks();
        \\log;
    , "sync,then1,");
}

test "later: Promise.race goes through the microtask queue (not sync settle)" {
    // §27.2.4.4.1 step 4.g — `Invoke(nextPromise, "then",
    // « cap.resolve, cap.reject »)`. Each item is forwarded
    // through `.then`, which queues a microtask; the result
    // capability's reactions only fire after that microtask
    // runs. So a `.then` reaction on a sibling Promise enqueued
    // BEFORE the race-result's reaction must fire FIRST. The
    // V8/spec order for the canonical fixture is [1,2,3,4,5];
    // a synchronous-settle implementation produced [1,2,3,5,4].
    try expectScriptStringWithBuiltins(
        \\let a = new Promise(resolve => resolve('a'));
        \\let b = new Promise(resolve => resolve('b'));
        \\let sequence = [1];
        \\a.then(() => sequence.push(3));
        \\Promise.race([a, b]).then(() => sequence.push(5));
        \\b.then(() => sequence.push(4));
        \\sequence.push(2);
        \\globalThis.__drainMicrotasks();
        \\sequence.join(",");
    , "1,2,3,4,5");
}

test "later: Promise.race honors a user-overridden .then on items" {
    // §27.2.4.4.1 step 4.g uses `Invoke(item, "then", …)` —
    // a `[[Get]]("then")` lookup that picks up the override.
    // Cynic's race must NOT call its native `then` impl
    // directly; user code is observably called.
    try expectScriptIntWithBuiltins(
        \\let calls = 0;
        \\const p = Promise.resolve(1);
        \\p.then = function() { calls += 1; return Promise.resolve(); };
        \\Promise.race([p]);
        \\globalThis.__drainMicrotasks();
        \\calls;
    , 1);
}

test "later: Promise.all resolves with the aggregated values via microtask" {
    // §27.2.4.1.2 — each item's resolveElement closure fills
    // a per-index slot; once `remainingElementsCount` hits zero
    // the cap.resolve fires. Driving this through `.then`
    // microtasks means the result Promise's reaction observes
    // the FULL array even when iteration finishes synchronously.
    try expectScriptStringWithBuiltins(
        \\let result = "";
        \\Promise.all([1, 2, 3]).then(arr => { result = arr.join(","); });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "1,2,3");
}

test "later: Promise.all rejects on the first rejected input" {
    // §27.2.4.1.2 — the per-element reject calls cap.reject
    // immediately; cap.resolve / .reject are idempotent so
    // later element settlements are no-ops.
    try expectScriptStringWithBuiltins(
        \\let result = "";
        \\Promise.all([Promise.resolve(1), Promise.reject("oops"), Promise.resolve(3)])
        \\  .then(() => { result = "fulfilled"; }, e => { result = "rejected:" + e; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "rejected:oops");
}

test "later: Promise.allSettled wraps each input as {status, value/reason}" {
    try expectScriptStringWithBuiltins(
        \\let result = "";
        \\Promise.allSettled([Promise.resolve("a"), Promise.reject("b")])
        \\  .then(arr => {
        \\    result = arr[0].status + ":" + arr[0].value + "," +
        \\             arr[1].status + ":" + arr[1].reason;
        \\  });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "fulfilled:a,rejected:b");
}

test "later: Promise.any resolves on first fulfilled input" {
    try expectScriptStringWithBuiltins(
        \\let result = "";
        \\Promise.any([Promise.reject("a"), Promise.resolve("b"), Promise.resolve("c")])
        \\  .then(v => { result = v; }, () => { result = "rejected"; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "b");
}

test "later: Promise.any rejects with AggregateError when all inputs reject" {
    try expectScriptStringWithBuiltins(
        \\let result = "";
        \\Promise.any([Promise.reject("a"), Promise.reject("b")])
        \\  .then(() => { result = "fulfilled"; },
        \\        e => { result = e.errors.join(","); });
        \\globalThis.__drainMicrotasks();
        \\result;
    , "a,b");
}

test "later: async function returns a Promise" {
    try expectScriptStringWithBuiltins(
        \\async function f() { return 42; }
        \\const p = f();
        \\typeof p.then;
    , "function");
}

test "later: async arrow returns a Promise (§15.8)" {
    // §15.8 Async Arrow Function Definitions — invoking an async
    // arrow must wrap the body via AsyncFunctionStart so the call
    // returns the implicit Promise, not the body's completion
    // value. Mirrors the async-function-expression behaviour above.
    try expectScriptStringWithBuiltins(
        \\const f = async () => 42;
        \\typeof f().then;
    , "function");
}

test "later: async arrow concise body resolves with body value" {
    try expectScriptIntWithBuiltins(
        \\let result = -1;
        \\(async () => 7)().then(v => { result = v; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , 7);
}

test "later: async/await round-trip with then" {
    try expectScriptIntWithBuiltins(
        \\async function f() {
        \\  const x = await Promise.resolve(7);
        \\  return x * 2;
        \\}
        \\let result = -1;
        \\f().then(v => { result = v; });
        \\globalThis.__drainMicrotasks();
        \\result;
    , 14);
}

test "later: async function suspends on pending await, resumes on settle" {
    try expectScriptIntWithBuiltins(
        \\let externalResolve;
        \\const p = new Promise((resolve, reject) => { externalResolve = resolve; });
        \\async function f() {
        \\  let x = await p;
        \\  return x + 1;
        \\}
        \\const result = f();
        \\externalResolve(41);
        \\globalThis.__drainMicrotasks();
        \\let captured;
        \\result.then(v => { captured = v; });
        \\globalThis.__drainMicrotasks();
        \\captured;
    , 42);
}

test "later: pending-await rejection throws inside the async body" {
    try expectScriptStringWithBuiltins(
        \\let externalReject;
        \\const p = new Promise((_, reject) => { externalReject = reject; });
        \\async function f() {
        \\  try { await p; return "unreachable"; }
        \\  catch (e) { return "caught:" + e; }
        \\}
        \\const result = f();
        \\externalReject("boom");
        \\globalThis.__drainMicrotasks();
        \\let captured;
        \\result.then(v => { captured = v; });
        \\globalThis.__drainMicrotasks();
        \\captured;
    , "caught:boom");
}

test "later: chained pending awaits suspend twice" {
    try expectScriptIntWithBuiltins(
        \\let r1; let r2;
        \\const p1 = new Promise((res) => { r1 = res; });
        \\const p2 = new Promise((res) => { r2 = res; });
        \\async function chain() {
        \\  const a = await p1;
        \\  const b = await p2;
        \\  return a + b;
        \\}
        \\const result = chain();
        \\r1(10);
        \\globalThis.__drainMicrotasks();
        \\r2(32);
        \\globalThis.__drainMicrotasks();
        \\let captured;
        \\result.then(v => { captured = v; });
        \\globalThis.__drainMicrotasks();
        \\captured;
    , 42);
}

test "later: chained .then on settled Promise propagates handler returns" {
    try expectScriptIntWithBuiltins(
        \\let final = 0;
        \\Promise.resolve(1)
        \\  .then(v => v + 10)
        \\  .then(v => v + 100)
        \\  .then(v => { final = v; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , 111);
}

test "later: chained .then on pending Promise fires after settle" {
    try expectScriptIntWithBuiltins(
        \\let final = 0;
        \\let res;
        \\const p = new Promise(r => { res = r; });
        \\p.then(v => v * 2).then(v => { final = v; });
        \\res(7);
        \\globalThis.__drainMicrotasks();
        \\final;
    , 14);
}

test "later: throwing .then handler rejects the result Promise" {
    try expectScriptStringWithBuiltins(
        \\let final = "none";
        \\Promise.resolve(1)
        \\  .then(v => { throw "boom"; })
        \\  .then(v => { final = "ok:" + v; }, e => { final = "err:" + e; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , "err:boom");
}

test "later: Promise-returning handler chains result settlement" {
    try expectScriptIntWithBuiltins(
        \\let final = 0;
        \\Promise.resolve(1)
        \\  .then(v => Promise.resolve(v + 100))
        \\  .then(v => { final = v; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , 101);
}

test "later: typeof Symbol() is 'symbol'" {
    try expectScriptStringWithBuiltins(
        \\typeof Symbol("k");
    , "symbol");
}

test "later: distinct symbols don't collide as property keys" {
    try expectScriptIntWithBuiltins(
        \\const a = Symbol("k");
        \\const b = Symbol("k");
        \\const obj = {};
        \\obj[a] = 1; obj[b] = 2;
        \\obj[a] + obj[b];
    , 3);
}

test "later: Symbol.prototype.description returns the description" {
    try expectScriptStringWithBuiltins(
        \\Symbol("hello").description;
    , "hello");
}

test "later: Symbol.prototype.toString returns Symbol(desc)" {
    try expectScriptStringWithBuiltins(
        \\Symbol("hello").toString();
    , "Symbol(hello)");
}

test "later: well-known Symbol.iterator works on arrays" {
    try expectScriptStringWithBuiltins(
        \\const it = [10, 20][Symbol.iterator]();
        \\const a = it.next();
        \\const b = it.next();
        \\const c = it.next();
        \\a.value + ":" + b.value + ":" + c.done;
    , "10:20:true");
}

test "later: Symbol.for round-trips through the registry" {
    try expectScriptStringWithBuiltins(
        \\const a = Symbol.for("x");
        \\const b = Symbol.for("x");
        \\(a === b) ? "same" : "different";
    , "same");
}

test "later: new Date(ms).getTime() round-trips" {
    try expectScriptIntWithBuiltins(
        \\const d = new Date(1000000);
        \\d.getTime();
    , 1000000);
}

test "later: new Boolean(false) is truthy as object but unwraps to false" {
    try expectScriptStringWithBuiltins(
        \\const b = new Boolean(false);
        \\const truthy = b ? "obj-truthy" : "obj-falsy";
        \\const num = b * 1;
        \\truthy + ":" + num;
    , "obj-truthy:0");
}

test "later: for-of declares the binding per iteration" {
    try expectScriptStringWithBuiltins(
        \\const xs = [];
        \\for (let x of [10, 20, 30]) xs.push(x);
        \\xs.join(",");
    , "10,20,30");
}

// later closure-per-iteration is on the deferred list — needs a
// per-iteration env push/pop with depth-tracking refactor that's
// out of scope for this milestone. The test below documents the
// expected later behaviour.

test "later: object-literal accessor pair" {
    try expectScriptIntWithBuiltins(
        \\const o = {
        \\  _v: 0,
        \\  get x() { return this._v; },
        \\  set x(v) { this._v = v + 10; }
        \\};
        \\o.x = 1;
        \\o.x;
    , 11);
}

test "later: Test262Error-shape constructor works end-to-end" {
    // The exact pattern from harness/sta.js — gating signal for
    // later (preloading the harness).
    try expectScriptString(
        \\function Test262Error(message) {
        \\  this.message = message || "";
        \\}
        \\Test262Error.prototype.toString = function () {
        \\  return "Test262Error: " + this.message;
        \\};
        \\const e = new Test262Error("boom");
        \\e.message;
    , "boom");
}

test "later: fizzbuzz-shaped program runs to completion" {
    // No console.log yet — accumulate the result into a
    // string and check the final value. Verifies for-loop +
    // if/else chain + string concat + variable assignment.
    try expectScriptString(
        \\let out = '';
        \\for (let i = 1; i <= 15; i = i + 1) {
        \\  if (i % 15 === 0) out = out + 'FizzBuzz,';
        \\  else if (i % 3 === 0) out = out + 'Fizz,';
        \\  else if (i % 5 === 0) out = out + 'Buzz,';
        \\  else out = out + i + ',';
        \\}
        \\out;
    , "1,2,Fizz,4,Buzz,Fizz,7,8,Fizz,Buzz,11,Fizz,13,14,FizzBuzz,");
}

// ── later: Multiple Scripts per Realm ──────────────────────────

test "later: top-level var visible in a later script on the same realm" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r1 = try evaluateScript(testing.allocator, &realm, "var x = 1;");
    try testing.expect(r1 != .thrown);

    const r2 = try evaluateScript(testing.allocator, &realm, "x;");
    const v = switch (r2) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 1), v.asInt32());
}

test "later: top-level let visible in a later script on the same realm" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "let x = 42;");
    const r = try evaluateScript(testing.allocator, &realm, "x;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 42), v.asInt32());
}

test "script completion: declaration-trailing is undefined, not the initializer" {
    // §16.1.6 ScriptEvaluation step 11 + §13.2 UpdateEmpty —
    // declarations have empty completion, which scripts convert to
    // undefined. Pre-fix the script `let x = 42;` would return 42
    // because the initializer left the value in the accumulator
    // and the trailing `return_` picked it up. Pin the spec
    // behaviour for every empty-completion trailing-statement
    // form so a REPL or embedder `evaluateScript` sees `undefined`.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    inline for (.{
        "let x = 42;",
        "const y = 7;",
        "var z = 99;",
        "function f() { return 1; }",
        "class C {}",
        ";",
    }) |src| {
        const r = try evaluateScript(testing.allocator, &realm, src);
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expect(v.isUndefined());
    }
}

test "script completion: expression-trailing carries its value through" {
    // Counterpart to the empty-completion pin above — expression
    // statements DO leave their value in the accumulator. Without
    // this the d8-style `cynic eval`-of-a-script flow and the REPL
    // value-line would both go silent.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r = try evaluateScript(testing.allocator, &realm, "let x = 42; x + 1;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 43), v.asInt32());
}

test "script completion: normal finally does not override the block value (§14.15.3)" {
    // §14.15.3 TryStatement : try Block Finally — let B = Block's
    // completion, F = Finally's completion; if F.[[Type]] is normal,
    // F is set to B, then UpdateEmpty(F, undefined) is returned. So a
    // finally that completes normally DISCARDS its own value; the
    // statement's completion is the Block's, UpdateEmpty'd. Pre-fix
    // the finally body's trailing ExpressionStatement `star`'d the
    // shared completion register, leaking the finally value as the
    // statement result.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    // Non-empty block, non-empty finally → block value wins.
    {
        const r = try evaluateScript(testing.allocator, &realm, "7; try { 7; } finally { 8; }");
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expectEqual(@as(i32, 7), v.asInt32());
    }
    // Empty block, non-empty finally → UpdateEmpty(empty, undefined).
    {
        const r = try evaluateScript(testing.allocator, &realm, "4; try { } finally { 5; }");
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expect(v.isUndefined());
    }
    // Non-empty block, empty finally → block value already correct
    // (guard against a regression).
    {
        const r = try evaluateScript(testing.allocator, &realm, "2; try { 3; } finally { }");
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expectEqual(@as(i32, 3), v.asInt32());
    }
}

test "script completion: normal finally with catch keeps the caught/block value (§14.15.3)" {
    // §14.15.3 TryStatement : try Block Catch Finally — B is the
    // Block (or, if it threw, the Catch result); a NORMAL Finally is
    // discarded, B (UpdateEmpty'd) is the completion.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    // Block throws → Catch result is B → normal finally discarded.
    {
        const r = try evaluateScript(testing.allocator, &realm, "9; try { throw 0; } catch { 7; } finally { 8; }");
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expectEqual(@as(i32, 7), v.asInt32());
    }
    // Block completes normally → Catch skipped, B is the block →
    // normal finally discarded.
    {
        const r = try evaluateScript(testing.allocator, &realm, "9; try { 6; } catch { 7; } finally { 8; }");
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expectEqual(@as(i32, 6), v.asInt32());
    }
}

test "abrupt finally still overrides the block completion (§14.15.3)" {
    // §14.15.3 step 3 only swaps in the block value when the finally
    // is NORMAL. An abrupt finally (return / throw / break /
    // continue) overrides — pin those so the value-discard fix
    // doesn't over-reach.

    // finally { return 2 } overrides try { return 1 }.
    try expectScriptInt("(() => { try { return 1; } finally { return 2; } })();", 2);
    // finally { break } drops out of the loop with the loop's
    // completion, not the try block's body value.
    try expectScriptInt(
        "let n = 0; for (;;) { try { n = 1; } finally { break; } } n;",
        1,
    );
    // finally { continue } resumes the loop; here it bounds the loop.
    try expectScriptInt(
        "let c = 0; for (let i = 0; i < 3; i++) { try { c += 1; } finally { continue; } c += 100; } c;",
        3,
    );
    // A throwing finally overrides a normal block.
    try expectScriptThrows("try { 1; } finally { throw 2; }");
}

test "script completion: abrupt finally carries its pre-transfer value (§14.15.3)" {
    // §14.15.3 — when the Finally completes ABRUPTLY via break /
    // continue, F is the finally's own completion, whose value is the
    // last value-producing statement evaluated *before* the transfer
    // (StatementListEvaluation). It overrides B. Mirrors test262
    // language/statements/try/completion-values.js.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const cases = .{
        // finally { 42; break } → break carries 42, overrides block 39.
        .{ "99; do { -99; try { 39 } catch (e) { -1 } finally { 42; break; -2 }; } while (false);", @as(i32, 42) },
        // finally { 42; continue } → continue carries 42.
        .{ "99; do { -99; try { 39 } catch (e) { -1 } finally { 42; continue; -3 }; } while (false);", @as(i32, 42) },
        // catch-then-finally with a value before break.
        .{ "99; do { -99; try { [].x.x } catch (e) { -1; } finally { 42; break; -3 }; } while (false);", @as(i32, 42) },
    };
    inline for (cases) |c| {
        const r = try evaluateScript(testing.allocator, &realm, c[0]);
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expectEqual(c[1], v.asInt32());
    }

    // finally { break } with no prior value → empty completion →
    // UpdateEmpty(empty, undefined).
    inline for (.{
        "99; do { -99; try { 39 } catch (e) { -1 } finally { break; -2 }; } while (false);",
        "99; do { -99; try { [].x.x } catch (e) { -1; } finally { break; -3 }; } while (false);",
    }) |src| {
        const r = try evaluateScript(testing.allocator, &realm, src);
        const v = switch (r) {
            .value, .yielded => |val| val,
            .thrown => return error.UnexpectedThrow,
        };
        try testing.expect(v.isUndefined());
    }
}

test "later: top-level function declaration visible across scripts" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "function f() { return 7; }");
    const r = try evaluateScript(testing.allocator, &realm, "f();");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 7), v.asInt32());
}

test "later: throw in script A doesn't poison script B" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r_throw = try evaluateScript(testing.allocator, &realm, "throw 1;");
    try testing.expect(r_throw == .thrown);

    const r_ok = try evaluateScript(testing.allocator, &realm, "2;");
    const v = switch (r_ok) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 2), v.asInt32());
}

test "later: cross-script var update is observable" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "var counter = 0;");
    _ = try evaluateScript(testing.allocator, &realm, "counter = counter + 1;");
    _ = try evaluateScript(testing.allocator, &realm, "counter = counter + 1;");
    const r = try evaluateScript(testing.allocator, &realm, "counter;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 2), v.asInt32());
}

test "later: const declared in script A is reachable in script B" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "const PI = 3;");
    const r = try evaluateScript(testing.allocator, &realm, "PI + 1;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 4), v.asInt32());
}

test "global-lexical slot: multi-script base offsets each script's slot 0" {
    // Slot-indexed global-lexical access — each script's slot 0
    // maps to a DISTINCT `decl_env` index because
    // `compileScriptAsChunk` snapshots `decl_env.count()` as the
    // chunk's `global_lexical_base` before hoisting. Three scripts
    // declaring distinct `let`s and cross-referencing the earlier
    // ones exercises the base arithmetic: script 2's slot 0 is
    // index 1, script 3's slot 0 is index 2.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "let s1 = 10;");
    _ = try evaluateScript(testing.allocator, &realm, "let s2 = s1 + 20;");
    const r = try evaluateScript(testing.allocator, &realm, "let s3 = s1 + s2 + 100; s3;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    // s1=10, s2=30, s3 = 10 + 30 + 100 = 140.
    try testing.expectEqual(@as(i32, 140), v.asInt32());
}

test "global-lexical slot: nested function reads slotted binding via inherited base" {
    // A nested function runs with its own sub-chunk; that chunk
    // must carry the script's `global_lexical_base` so a
    // `lda_global_slot` inside it resolves correctly. The function
    // is defined in script A and called in script B — the base is
    // baked into the function's chunk at compile time.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "let base = 7; function getBase() { return base; }");
    _ = try evaluateScript(testing.allocator, &realm, "let other = 3;");
    const r = try evaluateScript(testing.allocator, &realm, "getBase() + other;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 10), v.asInt32());
}

test "global-lexical slot: re-assignment and const guard hold across scripts" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    _ = try evaluateScript(testing.allocator, &realm, "let m = 1; const c = 2;");
    _ = try evaluateScript(testing.allocator, &realm, "m = m + 40;");
    const r = try evaluateScript(testing.allocator, &realm, "m;");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expectEqual(@as(i32, 41), v.asInt32());

    // §13.15.2 — re-assigning the `const` from a third script
    // throws a TypeError through `sta_global_slot`'s const check.
    const r_const = try evaluateScript(testing.allocator, &realm, "c = 9;");
    try testing.expect(r_const == .thrown);
}

test "later: delete o.x removes own property; subsequent read is undefined" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r = try evaluateScript(testing.allocator, &realm,
        \\(function () { var o = {x: 1, y: 2}; delete o.x; return o.x === undefined && o.y === 2; })()
    );
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expect(v.asBool());
}

test "later: delete o[k] (computed key) removes own property" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r = try evaluateScript(testing.allocator, &realm,
        \\(function () { var o = {a: 1}; var k = "a"; delete o[k]; return o.a === undefined; })()
    );
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expect(v.asBool());
}

test "later: delete on non-Reference operand evaluates and yields true" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r = try evaluateScript(testing.allocator, &realm, "delete (1 + 1);");
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expect(v.asBool());
}

test "later: built-in fn 'name' descriptor matches §10.2.9" {
    // §10.2.9 SetFunctionName — every built-in's `name` own
    // property is `{w:false, e:false, c:true}`. Cynic's SES freeze
    // pass flips `c:true` → `c:false` on the intrinsic graph
    // (matching @endo/ses post-`lockdown()`); the spec shape is
    // observable in the unhardened realm.
    try expectScriptIntUnhardened(
        \\const d = Object.getOwnPropertyDescriptor(decodeURIComponent, "name");
        \\(d.value === "decodeURIComponent" &&
        \\ d.writable === false &&
        \\ d.enumerable === false &&
        \\ d.configurable === true) ? 1 : 0;
    , 1);
}

test "later: built-in fn 'length' descriptor matches §10.2.4" {
    // §10.2.4 — `length` own property descriptor on any built-in
    // function is `{w:false, e:false, c:true}`. Same SES caveat as
    // the `name` test above.
    try expectScriptIntUnhardened(
        \\const d = Object.getOwnPropertyDescriptor(parseInt, "length");
        \\(typeof d.value === "number" &&
        \\ d.writable === false &&
        \\ d.enumerable === false &&
        \\ d.configurable === true) ? 1 : 0;
    , 1);
}

test "later/later: writable=false on built-in fn name throws TypeError in strict" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    const r = try evaluateScript(testing.allocator, &realm,
        \\(function () {
        \\    var orig = decodeURIComponent.name;
        \\    var threw = false;
        \\    var caughtType = false;
        \\    try { decodeURIComponent.name = "hijacked"; }
        \\    catch (e) { threw = true; caughtType = e instanceof TypeError; }
        \\    return threw && caughtType && decodeURIComponent.name === orig;
        \\})()
    );
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expect(v.asBool());
}

test "later: delete on configurable=true built-in fn slot succeeds" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);

    // `name` is configurable=true on built-in functions —
    // delete should succeed and subsequent `hasOwn` should
    // return false. Direct `f.name` reads still inherit from
    // the Function.prototype chain per §6.1.7.1 [[Get]].
    const r = try evaluateScript(testing.allocator, &realm,
        \\(function () {
        \\    function f() {}
        \\    var hadOwn = Object.prototype.hasOwnProperty.call(f, "name");
        \\    delete f.name;
        \\    return hadOwn === true && Object.prototype.hasOwnProperty.call(f, "name") === false;
        \\})()
    );
    const v = switch (r) {
        .value, .yielded => |val| val,
        .thrown => return error.UnexpectedThrow,
    };
    try testing.expect(v.asBool());
}

// ── §27.2.4.x Promise.try / Promise.withResolvers (ES2025) ────────────────

test "later: Promise.try(fn) fulfills with sync return value" {
    try expectScriptIntWithBuiltins(
        \\let final = 0;
        \\Promise.try(() => 42).then(v => { final = v; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , 42);
}

test "later: Promise.try(fn) rejects with sync throw" {
    try expectScriptStringWithBuiltins(
        \\let caught = "";
        \\Promise.try(() => { throw "boom"; }).catch(e => { caught = "caught:" + e; });
        \\globalThis.__drainMicrotasks();
        \\caught;
    , "caught:boom");
}

test "later: Promise.try forwards extra arguments to the callback" {
    try expectScriptIntWithBuiltins(
        \\let final = 0;
        \\Promise.try((a, b, c) => a + b + c, 10, 20, 12).then(v => { final = v; });
        \\globalThis.__drainMicrotasks();
        \\final;
    , 42);
}

test "later: Promise.try without a function rejects with TypeError" {
    try expectScriptStringWithBuiltins(
        \\let kind = "";
        \\Promise.try(123).catch(e => { kind = e instanceof TypeError ? "TypeError" : String(e); });
        \\globalThis.__drainMicrotasks();
        \\kind;
    , "TypeError");
}

test "later: Promise.withResolvers shape — has promise/resolve/reject" {
    try expectScriptStringWithBuiltins(
        \\const w = Promise.withResolvers();
        \\typeof w.promise.then + "," + typeof w.resolve + "," + typeof w.reject;
    , "function,function,function");
}

test "later: Promise.withResolvers().resolve(v) settles promise to fulfilled" {
    try expectScriptIntWithBuiltins(
        \\const w = Promise.withResolvers();
        \\let final = 0;
        \\w.promise.then(v => { final = v; });
        \\w.resolve(42);
        \\globalThis.__drainMicrotasks();
        \\final;
    , 42);
}

test "later: Promise.withResolvers().reject(e) settles promise to rejected" {
    try expectScriptStringWithBuiltins(
        \\const w = Promise.withResolvers();
        \\let caught = "";
        \\w.promise.catch(e => { caught = "caught:" + e; });
        \\w.reject("nope");
        \\globalThis.__drainMicrotasks();
        \\caught;
    , "caught:nope");
}

test "Promise.withResolvers.call(function(){}) throws TypeError — executor never set resolvers (§27.2.1.5)" {
    // §27.2.1.5 NewPromiseCapability steps 7-8 — a constructor whose
    // executor is never invoked leaves [[Resolve]]/[[Reject]] undefined,
    // so withResolvers (§27.2.4.6 step 2) must throw a TypeError.
    try expectScriptStringWithBuiltins(
        \\try { Promise.withResolvers.call(function () {}); "NO-THROW"; }
        \\catch (e) { e.constructor.name; }
    , "TypeError");
}

test "Promise.withResolvers.call(C) honors a constructor that invokes its executor" {
    try expectScriptStringWithBuiltins(
        \\const w = Promise.withResolvers.call(function (ex) { ex(function () {}, function () {}); });
        \\typeof w.resolve + "," + typeof w.reject;
    , "function,function");
}

test "Promise subclass withResolvers() runs the subclass constructor" {
    // §27.2.4.6 step 2 routes through NewPromiseCapability(C), so the
    // subclass constructor runs and the bundled promise is its instance.
    try expectScriptStringWithBuiltins(
        \\class P extends Promise {}
        \\const w = P.withResolvers();
        \\String(w.promise instanceof P) + "," + typeof w.resolve;
    , "true,function");
}

// ── §24.2.4.x Set ES2025 methods ──────────────────────────────────────────

test "later: Set.prototype.union returns the merged set" {
    try expectScriptStringWithBuiltins(
        \\const a = new Set([1, 2]);
        \\const b = new Set([2, 3]);
        \\Array.from(a.union(b)).sort().join(",");
    , "1,2,3");
}

test "Set.prototype.union rejects a set-like with negative size as RangeError (§24.2.1.2 step 3.f)" {
    // §24.2.1.2 GetSetRecord step 3.f — a negative `.size` is a
    // RangeError, distinct from the NaN-size TypeError of step 3.e.
    try expectScriptStringWithBuiltins(
        \\const bad = { size: -1, has() { return false; }, keys() { return [].values(); } };
        \\try { new Set([1]).union(bad); "NO-THROW"; } catch (e) { e.constructor.name; }
    , "RangeError");
}

test "later: Set.prototype.intersection returns elements present in both" {
    try expectScriptStringWithBuiltins(
        \\const a = new Set([1, 2, 3]);
        \\const b = new Set([2, 3, 4]);
        \\Array.from(a.intersection(b)).sort().join(",");
    , "2,3");
}

test "later: Set.prototype.difference returns elements in this but not other" {
    try expectScriptStringWithBuiltins(
        \\const a = new Set([1, 2, 3]);
        \\const b = new Set([2, 3, 4]);
        \\Array.from(a.difference(b)).sort().join(",");
    , "1");
}

test "later: Set.prototype.symmetricDifference returns the XOR" {
    try expectScriptStringWithBuiltins(
        \\const a = new Set([1, 2, 3]);
        \\const b = new Set([2, 3, 4]);
        \\Array.from(a.symmetricDifference(b)).sort().join(",");
    , "1,4");
}

test "later: Set.prototype.isSubsetOf — true case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 2]).isSubsetOf(new Set([1, 2, 3])) ? 1 : 0;
    , 1);
}

test "later: Set.prototype.isSubsetOf — false case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 4]).isSubsetOf(new Set([1, 2, 3])) ? 1 : 0;
    , 0);
}

test "later: Set.prototype.isSupersetOf — true case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 2, 3]).isSupersetOf(new Set([1, 2])) ? 1 : 0;
    , 1);
}

test "later: Set.prototype.isSupersetOf — false case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 2, 3]).isSupersetOf(new Set([1, 4])) ? 1 : 0;
    , 0);
}

test "later: Set.prototype.isDisjointFrom — true case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 2]).isDisjointFrom(new Set([3, 4])) ? 1 : 0;
    , 1);
}

test "later: Set.prototype.isDisjointFrom — false case" {
    try expectScriptIntWithBuiltins(
        \\new Set([1, 2]).isDisjointFrom(new Set([2, 3])) ? 1 : 0;
    , 0);
}

// §27.5.1 — `%GeneratorPrototype%.[[Prototype]]` is
// `%IteratorPrototype%`. Without this link, `g().map(...)` on a
// generator instance is `undefined` and the iterator-helpers
// fixtures all fall over at the first method dispatch.
test "later: generator instance inherits .map from %Iterator.prototype%" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\typeof g().map;
    , "function");
}

// §27.1.4.1.1.1 step 5.b.iv — mapper is called as
// `Call(mapper, undefined, « value, 𝔽(counter) »)`. The counter
// starts at 0 and increments per yielded value, regardless of
// what the mapper returns.
test "later: Iterator.prototype.map passes (value, counter) to mapper" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield "a"; yield "b"; yield "c"; }
        \\const acc = [];
        \\for (const _ of g().map((v, i) => { acc.push(v + i); return v; }));
        \\acc.join(",");
    , "a0,b1,c2");
}

// §27.1.4.1.1 — `Iterator.prototype.map` returns an Iterator
// helper whose [[Prototype]] chains to `%Iterator.prototype%`.
// `instanceof Iterator` is the user-visible consequence.
test "later: Iterator.prototype.map result is instanceof Iterator" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; }
        \\(g().map(v => v) instanceof Iterator) + "";
    , "true");
}

// §27.1.4.1.1 / §7.4.10 — GetIteratorDirect snapshots `next`
// once at helper construction. Subsequent steps must NOT re-
// trigger a `get next` accessor on the underlying iterator.
test "later: Iterator.from snapshots next exactly once" {
    try expectScriptStringWithBuiltins(
        \\let nextGets = 0;
        \\const src = {
        \\  get next() {
        \\    ++nextGets;
        \\    let i = 0;
        \\    return function () {
        \\      return i < 3 ? { value: i++, done: false } : { value: undefined, done: true };
        \\    };
        \\  },
        \\};
        \\const it = Iterator.from(src);
        \\it.toArray();
        \\String(nextGets);
    , "1");
}

// §27.1.4.1.1.5 (toArray): drains the iterator. Smoke-test the
// generator → helper → terminal chain.
test "later: g().filter(...).toArray() returns an array" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; yield 2; yield 3; yield 4; }
        \\g().filter(v => v % 2 === 0).toArray().join(",");
    , "2,4");
}

test "later: Set methods accept any set-like (Map keys + has + size)" {
    // Spec says `other` is any set-like — { size, has, keys }.
    // A Map satisfies that protocol via its own size/has/keys.
    try expectScriptStringWithBuiltins(
        \\const a = new Set([1, 2, 3]);
        \\const m = new Map([[2, "x"], [3, "y"], [4, "z"]]);
        \\Array.from(a.intersection(m)).sort().join(",");
    , "2,3");
}

/// Stress-test the allocation-pressure GC trigger: same fixtures
/// as the surrounding suite, but with `gc_threshold = 1` so a full
/// mark-sweep fires between essentially every opcode. Any missing
/// root surfaces as either a use-after-free crash, a wrong answer
/// (a still-live value got swept and reallocated as garbage), or
/// a TypeError / ReferenceError from an early-collected global.
/// 734-test green here is a strong signal that the root walker in
/// `Realm.collectGarbage` covers the production set.
fn expectScriptIntUnderGcPressure(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    realm.heap.gc_threshold = 1;
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    if (v.isInt32()) {
        try testing.expectEqual(expected, v.asInt32());
    } else if (v.isDouble()) {
        try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble());
    } else return error.NotANumber;
}

test "GC: object-allocating loop survives gc_threshold=1" {
    // 50 fresh objects per iteration; with threshold=1 a full
    // mark-sweep fires after each `make_object`. The loop variable
    // `r` and the `o` reference must stay rooted via the active
    // frame's env / registers; the sum only comes out right if
    // every iteration sees the freshly-allocated `o` instead of
    // a swept-and-reallocated stale pointer.
    try expectScriptIntUnderGcPressure(
        \\let r = 0;
        \\for (let i = 0; i < 50; i++) {
        \\  let o = { a: i, b: i + 1 };
        \\  r += o.a + o.b;
        \\}
        \\r;
    , 2500);
}

test "GC: closures keep captured envs alive under gc_threshold=1" {
    // The arrow returned from `makeCounter` captures `n`; that
    // env is reachable only through the closure's `captured_env`
    // slot. Every call allocates fresh stack state and, with
    // threshold=1, runs GC mid-call. If `markValue` for
    // JSFunction skipped `captured_env` the counts would reset.
    try expectScriptIntUnderGcPressure(
        \\const make = (s) => { let n = s; return () => ++n; };
        \\const c = make(10);
        \\c() + c() + c();
    , 36);
}

test "GC: allocating tail-recursive loop paces the collector (PTC safe-point)" {
    // §15.10 PTC reuses the current frame and re-enters dispatch in
    // place, crossing neither the runFrames-entry safe point nor a
    // loop back-edge. Without a safe-point poll on the tail-call
    // path, an allocating tail-recursive loop never polls the
    // allocation-pressure GC: `allocs_since_gc` grows by one per
    // iteration without bound (RSS balloons, GC never fires) until
    // the realm is torn down. With the poll, the collector fires
    // periodically and resets the counter, so the residue stays
    // bounded. Regression guard for the ~193 MB
    // language/expressions/call/tco-call-args.js process-RSS spike.
    //
    // Self-validating in two ways: a 20000-deep recursion can only
    // return (rather than overflow the native stack) if PTC frame
    // reuse engaged, and `allocs_since_gc` can only stay bounded if
    // the tail-call re-entry crossed the safe point.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    // Drain the intrinsic-install residue so the post-run counter
    // reflects only the loop.
    realm.collectGarbage();
    realm.heap.gc_young_threshold = 256;
    realm.heap.gc_threshold = 1024;

    const v = switch (try evaluateScriptResult(&realm,
        \\function sum(n, acc) {
        \\  if (n === 0) return acc;
        \\  let o = { v: 1 };
        \\  return sum(n - 1, acc + o.v);
        \\}
        \\sum(20000, 0);
    )) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    // PTC frame reuse held across 20000 frames → correct sum.
    try testing.expectEqual(@as(i32, 20000), v.asInt32());
    // The loop allocated >20000 objects. Pre-fix `allocs_since_gc`
    // would be ~20000 (no collection during the loop); with the
    // poll, the young collector reset it every 256 allocations, so
    // the residue is a small remainder well under the per-iteration
    // total.
    try testing.expect(realm.heap.allocs_since_gc < 1024);
}

/// Stress variant — uses `setGcThreshold(1)` instead of just
/// `gc_threshold = 1`. That sets BOTH the young threshold (1) and
/// the major threshold (8), so minor cycles fire every allocation
/// and major cycles fire every 8 — the alternating-cycle pattern
/// that surfaces the colour-flip cross-cycle stale-mark hazard and
/// the recursive-marker stack-overflow on long chains. Matches the
/// CLI's `--gc-threshold=1` behaviour. Used by tests whose chain
/// depth needs both kinds of cycle to fire interleaved.
fn expectScriptIntUnderAlternatingGcPressure(source: []const u8, expected: i32) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    realm.heap.setGcThreshold(1);
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    if (v.isInt32()) {
        try testing.expectEqual(expected, v.asInt32());
    } else if (v.isDouble()) {
        try testing.expectEqual(@as(f64, @floatFromInt(expected)), v.asDouble());
    } else return error.NotANumber;
}

fn expectScriptStringUnderGcPressure(source: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    realm.heap.gc_threshold = 1;
    const v = switch (try evaluateScriptResult(&realm, source)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

test "GC: generator wrapper iteration survives gc_threshold=1" {
    // `for (v of g())` opens an iterator on the wrapper JSObject
    // returned by the generator call. The wrapper sits in the
    // for-of's `r_iter` register; the underlying JSGenerator is
    // reachable through `wrapper.generator_ref`. Each `next()`
    // call descends into a nested `runFrames` that walks the
    // generator's saved frame state — that nested walk must keep
    // the OUTER frame's wrapper register alive so the next
    // iteration finds the same generator.
    try expectScriptIntUnderGcPressure(
        \\function* g() { for (let i = 0; i < 5; i++) yield i * 100; }
        \\let s = 0; for (const v of g()) s += v;
        \\s;
    , 1000);
}

test "GC: Promise microtask chain survives gc_threshold=1" {
    // `.then(...).then(...)` queues `promise_reaction` microtasks
    // whose `reaction_result` is the chained sub-Promise. The
    // outer Promise the next-step reaction was registered on
    // must be kept alive across mid-drain collections — it lives
    // on `JSObject.promise_reactions[i].result_promise`, which
    // the walker reaches only via the source object's reaction list.
    try expectScriptIntUnderGcPressure(
        \\let acc = 0;
        \\Promise.resolve(1).then(v => v + 10).then(v => v + 100).then(v => { acc = v; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 111);
}

test "GC: Promise.resolve(thenable) survives gc_threshold=1" {
    // §27.2.4.7 fast path allocates a pending Promise, then calls
    // the resolve function which runs Get(resolution, "then") — a
    // user accessor that re-enters JS and GCs. `pending` is a native
    // local the GC can't see; without rooting it across that call,
    // gc_threshold=1 swept it and `Promise.resolve(t)` returned a
    // freed Promise whose `.then` segfaulted on the dangling shape.
    try expectScriptIntUnderGcPressure(
        \\var t = Object.defineProperty({}, 'then', { get: function() { throw 7; } });
        \\var acc = -1;
        \\Promise.resolve(t).then(function() { acc = 0; }, function(e) { acc = e; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 7);
}

test "GC: computed-key enumeration order survives gc_threshold=1" {
    // `o["k" + i] = i` allocates a fresh JSString key each iter and
    // borrows its bytes for `own_key_order`. Without anchoring the
    // JSString (the shape-absorbed `setComputedOwned` path), a sweep
    // freed the key out from under the order slice and Object.keys
    // came back reordered / corrupted under gc_threshold=1.
    try expectScriptStringUnderGcPressure(
        \\var o = {};
        \\for (var i = 0; i < 12; i++) o["k" + i] = i;
        \\Object.keys(o).join(",");
    , "k0,k1,k2,k3,k4,k5,k6,k7,k8,k9,k10,k11");
}

test "GC: integer-index keys on an array-like survive gc_threshold=1" {
    // `child[0..2] = …` are integer-index writes on a *non-array*
    // object. They route through setComputedOwned but skip
    // own_key_order (recordKey ignores integer keys), landing only in
    // the properties bag — which borrows the key slice. Without
    // anchoring the bag's first insertion, gc_threshold=1 swept the
    // index keys and Array.prototype.forEach on the array-like saw
    // zero elements (the length getter still returns 3; the indexed
    // reads missed). Sum must be 0 + 10 + 20 = 30.
    try expectScriptIntUnderGcPressure(
        \\var proto = { length: 0 };
        \\var Con = function() {};
        \\Con.prototype = proto;
        \\var child = new Con();
        \\Object.defineProperty(child, "length", { get: function() { return 3; }, configurable: true });
        \\child[0] = 0; child[1] = 10; child[2] = 20;
        \\var sum = 0;
        \\Array.prototype.forEach.call(child, function(v) { sum += v; });
        \\sum;
    , 30);
}

test "GC: suspended async fn result Promise survives gc_threshold=1" {
    // A fire-and-forget async function suspends on `await`; its
    // [[Promise]] (the value returned to the caller) is reachable
    // ONLY through the suspended JSGenerator's `result_promise`
    // slot once `.then` has registered its reaction and the caller
    // frame unwound. `markGenerator` did not mark `result_promise`
    // (nor `home_function` / `pending_return` / `pending_throw`),
    // so under gc_threshold=1 the awaited continuation's allocations
    // swept the result Promise — `.then`'s reaction was lost and
    // `acc` never updated (or the resume settled freed memory).
    try expectScriptIntUnderGcPressure(
        \\var acc = -1;
        \\async function f() { var x = await 1; var y = await (x + 2); return y + 4; }
        \\f().then(function(v) { acc = v; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 7);
}

test "GC: Array.fromAsync over a sync iterable survives gc_threshold=1" {
    // The fromAsync driver keeps its cursor in an engine-internal
    // `state` object reached through each continuation's `bound_this`.
    // Three roots had to hold under gc_threshold=1: the bound
    // resolve/reject callables (`makeBoundCb` allocated the inner fn
    // then the bound wrapper — a GC between freed the inner fn →
    // "value is not callable"); the generational write barrier on
    // `state` (promoted to mature across awaits, then a young
    // iterator stored into `__cynic_fa_iter__` was an un-remembered
    // edge); and `wrapValueInPromise`'s freshly-allocated Promise
    // across the resolve re-entry.
    try expectScriptIntUnderGcPressure(
        \\var acc = -1;
        \\Array.fromAsync([10, 20, 30]).then(function(a) { acc = a[0] + a[1] + a[2]; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 60);
}

test "GC: Array.fromAsync with a mapfn survives gc_threshold=1" {
    // Exercises the mapped-value branch: each element is mapped then
    // re-awaited via `awaitWithCbs` → `awaitAndThen` →
    // `wrapValueInPromise`. Before rooting the wrapper Promise across
    // the resolve re-entry, the awaited `source` was a dangling
    // pointer and `switch (source.promise_state)` paniced on a
    // corrupt enum value under gc_threshold=1.
    try expectScriptIntUnderGcPressure(
        \\var acc = -1;
        \\Array.fromAsync([1, 2, 3], function(x) { return x * 10; }).then(function(a) { acc = a[0] + a[1] + a[2]; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 60);
}

test "GC: long Promise microtask chain survives alternating GC pressure" {
    // The 3-deep chain above doesn't surface two interacting
    // hazards: (1) the colour-flip cross-cycle stale-mark hazard
    // where an unreachable mature object's mark_color happens to
    // match the post-flip live_color (fixed by the major-cycle
    // pre-mark clear in `beginMajorCycle`); and (2) the recursive
    // marker stack-overflow on deep `promise → reaction →
    // result_promise → reaction → …` graphs (fixed by deferring
    // `result_promise` to `mark_worklist` and draining iteratively
    // at cycle boundaries). A 250-deep chain churns enough cycles
    // to fire both — each handler increments by 1, final value 250.
    // Uses the alternating-pressure helper because the bugs require
    // *interleaved* minor + major cycles to surface.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let p = Promise.resolve(0);
        \\for (let i = 0; i < 250; i++) p = p.then(v => v + 1);
        \\let acc = 0;
        \\p.then(v => { acc = v; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 250);
}

test "GC: long closure chain survives alternating GC pressure" {
    // Sibling to the Promise-chain regression — synchronous control
    // flow. Each iteration's arrow captures its own `let` binding,
    // so each iteration's env survives to be referenced by the next
    // arrow. Long parent-env chains stress `markEnvironment`'s
    // recursion. Final call sums 1..200 = 20100.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let f = (acc) => acc;
        \\for (let i = 1; i <= 200; i++) {
        \\  const prev = f;
        \\  const step = i;
        \\  f = (acc) => prev(acc + step);
        \\}
        \\f(0);
    , 20100);
}

test "GC: class instance churn survives alternating GC pressure" {
    // Allocates 500 short-lived class instances, summing one field
    // from each. Tests that prototype-shape sharing, method-table
    // lookups, and the constructor / methods are all kept alive
    // through long-lived references (the class) while the instances
    // come and go. Sum 1..500 = 125250.
    try expectScriptIntUnderAlternatingGcPressure(
        \\class Box { constructor(n) { this.n = n; } add(o) { return this.n + o.n; } }
        \\const zero = new Box(0);
        \\let s = 0;
        \\for (let i = 1; i <= 500; i++) s = new Box(i).add(zero) + s;
        \\s;
    , 125250);
}

test "GC: Symbol.for registry churn survives alternating GC pressure" {
    // 200 `Symbol.for(k)` calls with distinct keys — each
    // allocates a registered symbol, pinned via the registry's
    // `pinned` bit (added in the GC pin commit). The pin must keep
    // every symbol alive across all cycles even when nothing else
    // references the symbol values directly. `Symbol.keyFor`
    // resolves each back to its key string at the end; total length
    // of "k0".."k199" = 10·2 + 90·3 + 100·4 = 690.
    try expectScriptIntUnderAlternatingGcPressure(
        \\for (let i = 0; i < 200; i++) Symbol.for("k" + i);
        \\let total = 0;
        \\for (let i = 0; i < 200; i++) total += Symbol.keyFor(Symbol.for("k" + i)).length;
        \\total;
    , 690);
}

test "GC: deep object property writes survive alternating GC pressure" {
    // Builds a tower of objects, each holding the previous one in
    // a property. Walks the chain to verify every link is alive.
    // The shape transition tree and per-object `properties` bag
    // both get exercised under high allocation pressure. 150 deep.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let cur = { d: 0 };
        \\for (let i = 1; i <= 150; i++) cur = { prev: cur, d: i };
        \\let s = 0;
        \\let walk = cur;
        \\while (walk) { s += walk.d; walk = walk.prev; }
        \\s;
    , 11325);
}

test "GC: generator wrapper iteration survives alternating GC pressure" {
    // The 5-yield generator survives the looser gc_threshold=1
    // test (above), but used to abort under the alternating-
    // cycle CLI behaviour because `make_function` for a generator
    // function removed the inherited `constructor` from the
    // function's `.prototype` bag without demoting the shadow
    // shape — `verifyShapeInvariant` then panicked on the next
    // mark. Fix sites: `lantern/interpreter.zig` (make_function
    // generator-prototype rewire), `class.zig` (instance + static
    // class generator methods), `builtins/iterator.zig`
    // (Iterator.prototype constructor / @@toStringTag).
    try expectScriptIntUnderAlternatingGcPressure(
        \\function* g() { for (let i = 0; i < 5; i++) yield i * 100; }
        \\let s = 0; for (const v of g()) s += v;
        \\s;
    , 1000);
}

test "GC: Iterator.prototype.map chain survives alternating GC pressure" {
    // `.map().filter().toArray()` pipeline — every helper allocates
    // an IteratorHelperState + a fresh wrapper. The chain shares
    // its prototype graph with the generator path above; same
    // shadow-shape removal hazard surfaces here under alternating
    // cycles.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let s = 0;
        \\Iterator.from([1, 2, 3, 4, 5]).map(x => x * 2).filter(x => x > 4).toArray().forEach(v => s += v);
        \\s;
    , 24);
}

test "GC: 2k-deep closure chain survives the iterative env worklist" {
    // Each iteration wraps the previous closure, so the env chain
    // (and the closure chain through each captured_env's slot 0)
    // grows linearly. Pre-fix, `markValue → markEnvironment →
    // markValue(captured_env slot=function) → markEnvironment(…)`
    // recurses 2k deep and aborts on the Debug call stack.
    // Post-fix, `markValue`'s function arm pushes captured_env to
    // `mark_env_worklist` and `markEnvironment` pushes parent to
    // the same worklist; the iterative drain at cycle boundaries
    // walks them flat.
    //
    // We DON'T invoke the chain (`f(0)` would overflow the JS
    // call stack at 2k depth, independent of GC). Building it is
    // enough — every alloc under setGcThreshold(1) triggers a GC
    // cycle whose mark phase walks the full reachable closure
    // chain. Return 1 as a trivial assertion.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let f = (acc) => acc;
        \\for (let i = 1; i <= 2000; i++) {
        \\  const prev = f;
        \\  const step = i;
        \\  f = (acc) => prev(acc + step);
        \\}
        \\1;
    , 1);
}

test "GC: 1k-deep prototype chain survives the iterative proto worklist" {
    // `Object.create(prev)` builds an N-deep `[[Prototype]]`
    // chain. Pre-fix, marking an object recursed through
    // `o.prototype` via `markValue(taggedObject(p))`, so a 1k-
    // deep chain overflowed the marker stack. Post-fix, both
    // `markValue`'s object arm and `markObjectInternalSlots`
    // push the prototype to `mark_worklist` instead of recursing.
    // Constructing the chain is the test — reaching the end
    // without aborting is the assertion. Return 1 to confirm.
    try expectScriptIntUnderAlternatingGcPressure(
        \\let cur = {};
        \\for (let i = 0; i < 1000; i++) cur = Object.create(cur);
        \\1;
    , 1);
}

test "GC: Promise constructor executor survives gc_threshold=1" {
    // `new Promise(executor)` runs the executor synchronously
    // with the bound capability state as `this`. The cap record
    // is reachable only through the bound function's `bound_this`
    // until the executor stores resolve/reject in it; the
    // executor's body can allocate (closures, captured envs,
    // ToString of the input) before that store, so the cap state
    // must stay marked through every nested allocation.
    try expectScriptIntUnderGcPressure(
        \\let r = 0;
        \\new Promise((resolve, reject) => {
        \\  for (let i = 0; i < 10; i++) {
        \\    let o = { a: i };
        \\    r += o.a;
        \\  }
        \\  resolve(r);
        \\}).then(v => { r = v + 1000; });
        \\globalThis.__drainMicrotasks();
        \\r;
    , 1045);
}

test "GC: Iterator.prototype.map chain survives gc_threshold=1" {
    // Each `.map` / `.filter` allocates an IteratorHelperState
    // and a fresh wrapper. With threshold=1 a sweep fires after
    // every alloc. The state's `source` / `next_fn` / `payload`
    // Values must stay rooted through the wrapper construction
    // (which allocates two natives — `next` and `return` — after
    // the IteratorHelperState is installed).
    try expectScriptIntUnderGcPressure(
        \\function* g() { yield 1; yield 2; yield 3; yield 4; yield 5; }
        \\let s = 0;
        \\for (const v of Iterator.from(g()).map(x => x * 10).filter(x => x > 15)) s += v;
        \\s;
    , 140);
}

test "GC: Map iterable construction survives gc_threshold=1" {
    // `new Map(iterable)` opens an iterator on `iterable` and
    // walks pairs. Each pair object is allocated then immediately
    // consumed; the Map instance is reachable only through the
    // `r_iter` register of the surrounding caller. Each `Map.set`
    // allocates an entry slot.
    try expectScriptIntUnderGcPressure(
        \\const m = new Map([[1,10],[2,20],[3,30],[4,40],[5,50]]);
        \\let s = 0; for (const [, v] of m) s += v;
        \\s;
    , 150);
}

test "GC: Iterator.from + .toArray survives gc_threshold=1" {
    // Iterator.from snapshots `next`, allocates a wrapper +
    // state; .toArray then walks every step, allocating each
    // result object inside `invokeIterNextFn`. The toArray
    // accumulator array's `length` is updated last — must
    // survive GC inside every step.
    try expectScriptIntUnderGcPressure(
        \\function* g() { for (let i = 1; i <= 8; i++) yield i; }
        \\const arr = Iterator.from(g()).toArray();
        \\let s = 0; for (const v of arr) s += v;
        \\s;
    , 36);
}

test "GC: Promise.all aggregator survives gc_threshold=1" {
    // Promise.all's aggregator state (kind, remaining, values
    // array, cap resolve/reject) is the most allocation-heavy
    // Promise path: one element-closure pair per input, each
    // with its own state-wrapper JSObject. All of those must
    // stay rooted until the aggregator settles.
    try expectScriptIntUnderGcPressure(
        \\let r = 0;
        \\Promise.all([Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)])
        \\  .then(vs => { r = vs[0] + vs[1] + vs[2]; });
        \\globalThis.__drainMicrotasks();
        \\r;
    , 6);
}

test "GC: Iterator.concat survives gc_threshold=1" {
    // Iterator.concat keeps its validated {iterable, openMethod}
    // records on the typed `iter_helper.concat_inputs` slot. With
    // threshold=1 a sweep fires after every alloc in the per-arg
    // @@iterator GetMethod loop and the wrapper build; the records
    // must stay rooted, or `concatNext` reads a freed method.
    try expectScriptIntUnderGcPressure(
        \\let s = 0;
        \\for (const v of Iterator.concat([1, 2], [3, 4], [5])) s += v;
        \\s;
    , 15);
}

test "GC: Iterator.zip survives gc_threshold=1" {
    // zip collects per-input {iter, next, active, pad} records into
    // the typed `iter_helper.zip_inputs` slot; collectZipIters and
    // buildZipWrapper must root them across every @@iterator and
    // step re-entry.
    try expectScriptIntUnderGcPressure(
        \\let s = 0;
        \\for (const t of Iterator.zip([[1, 2, 3], [10, 20, 30]])) s += t[0] + t[1];
        \\s;
    , 66);
}

test "GC: Iterator.zipKeyed result keys survive gc_threshold=1" {
    // `storeZipResult` must `setComputedOwned`-anchor each result
    // key onto the tuple object — a plain `set` borrows the slice
    // from the zip wrapper's `zip_inputs`, which dies when the
    // iterator is dropped, leaving the tuple's keys dangling. The
    // reads below run after the wrapper is unreachable, so a
    // gc-threshold=1 sweep would reuse the freed key bytes.
    try expectScriptIntUnderGcPressure(
        \\const r = Array.from(Iterator.zipKeyed({ a: [1, 2], b: [10, 20] }));
        \\r[0].a + r[0].b + r[1].a + r[1].b;
    , 33);
}

test "GC: Map iterator survives gc_threshold=1" {
    // The Map iterator's [[IteratedMap]] / [[MapNextIndex]] /
    // [[MapIterationKind]] live on the typed `map_set_iter` slot;
    // the iterated Map must stay marked across each next().
    try expectScriptIntUnderGcPressure(
        \\const m = new Map([["a", 1], ["b", 2], ["c", 3]]);
        \\let s = 0;
        \\for (const [k, v] of m) s += v;
        \\s;
    , 6);
}

test "GC: Set iterator survives gc_threshold=1" {
    // The Set iterator's [[IteratedSet]] / [[SetNextIndex]] live on
    // the typed `map_set_iter` slot.
    try expectScriptIntUnderGcPressure(
        \\const set = new Set([10, 20, 30]);
        \\let s = 0;
        \\for (const v of set) s += v;
        \\s;
    , 60);
}

test "GC: String.prototype.matchAll survives gc_threshold=1" {
    // The RegExp String Iterator's [[IteratingRegExp]] /
    // [[IteratedString]] live on the typed `regexp_string_iter`
    // slot; both must stay marked across each RegExpExec.
    try expectScriptStringUnderGcPressure(
        \\let out = "";
        \\for (const m of "a1b2c3".matchAll(/[a-z]\d/g)) out += m[0];
        \\out;
    , "a1b2c3");
}

test "GC: JSON.stringify replacer holder survives gc_threshold=1" {
    // §25.5.2 JSON.stringify wraps the value in a synthetic
    // `{ "": value }` holder and passes it as the replacer's `this`
    // (SerializeJSONProperty step 2.a → 2.b's Call). The holder is a
    // native local; the property reads + ToString coercions before
    // the replacer call allocate, so with threshold=1 a sweep fired
    // and left a dangling `this` for the replacer call. Asserting the
    // serialized output proves the holder (and the value it owns)
    // stayed live across every replacer re-entry.
    try expectScriptStringUnderGcPressure(
        \\JSON.stringify({ a: 1, b: 2, c: 3 }, function (k, v) { return v; });
    , "{\"a\":1,\"b\":2,\"c\":3}");
}

test "GC: RegExp.prototype[@@match] global array survives gc_threshold=1" {
    // §22.2.5.8 step 6 — the global match loop allocates result
    // array A up front, then repeatedly RegExpExecs and
    // CreateDataPropertys the per-match strings into A. A, the
    // subject S, and the per-iteration exec result / match string
    // are native locals; under threshold=1 a sweep mid-loop freed
    // A and the next `out.set` dereferenced its poisoned extension.
    try expectScriptStringUnderGcPressure(
        \\"a1b2c3".match(/\d/g).join("");
    , "123");
}

test "GC: RegExp.prototype[@@split] with captures survives gc_threshold=1" {
    // §22.2.5.13 step 19 — the split loop allocates result array A
    // and a species-constructed splitter up front, then repeatedly
    // RegExpExecs, Gets `length`/captures, and CreateDataPropertys
    // segment + capture strings into A. A, S, the splitter, and the
    // per-iteration exec result / segment / capture values are
    // native locals; under threshold=1 a sweep mid-loop freed A and
    // the next `out.set` dereferenced poisoned memory.
    try expectScriptStringUnderGcPressure(
        \\"a1b2c".split(/(\d)/).join("-");
    , "a-1-b-2-c");
}

test "GC: TypedArray.prototype.map species result survives gc_threshold=1" {
    // §23.2.3.20 — map allocates the result typed array up front via
    // TypedArraySpeciesCreate, holds its raw backing-buffer view, then
    // runs the user callback per element. The callback re-enters JS and
    // can GC; the result object was a native local reachable through
    // nothing, so under threshold=1 a sweep mid-loop freed it and the
    // next element write-back dereferenced its poisoned buffer.
    try expectScriptStringUnderGcPressure(
        \\new Int32Array([1, 2, 3, 4, 5]).map(function (x) { return x * 2; }).join("-");
    , "2-4-6-8-10");
}

test "GC: TypedArray.prototype.toSorted result survives gc_threshold=1" {
    // §23.2.3.34 — toSorted allocates the result typed array, copies the
    // source into it, then sorts in place with a user comparator. The
    // comparator re-enters JS and can GC, and the post-sort write-back
    // re-fetches the result's backing buffer; the result was a native
    // local reachable through nothing, so under threshold=1 a comparator
    // sweep freed it and the write-back hit a dangling view.
    try expectScriptStringUnderGcPressure(
        \\new Int32Array([3, 1, 2]).toSorted(function (a, b) { return a - b; }).join("-");
    , "1-2-3");
}

test "GC: mature function's young bag value survives gc_threshold=1" {
    // A function that has survived a collection is in the mature
    // generation; attaching a freshly-allocated (young) object to one of
    // its property-bag slots creates a mature→young edge that the
    // generational write barrier must record, or a later minor sweep
    // reclaims the young value while the function still points at it.
    // `Object.defineProperty` on a function receiver routes through
    // JSFunction.setWithFlags (the bag-store path), distinct from the
    // sta_property opcode barrier. Churn allocations to age the function
    // and force minor collections, then read the value back.
    try expectScriptIntUnderGcPressure(
        \\function f() {}
        \\for (let i = 0; i < 40; i++) { ({}); }
        \\Object.defineProperty(f, "tag", {
        \\  value: { v: 42 }, writable: true, enumerable: true, configurable: true });
        \\for (let i = 0; i < 40; i++) { ({}); }
        \\f.tag.v;
    , 42);
}

test "GC: symbol-keyed property survives gc_threshold=1" {
    // §6.1.5.1 / §10.1 — a JSSymbol used as a property key is stored
    // flattened to its owned `<sym:N>` slug; the owner's mark walk
    // reaches the value but never the JSSymbol itself. A user symbol
    // reachable ONLY as a live object's key would be swept, its slug
    // freed, and the owner's borrowed accessor-map key slice left
    // dangling — the key then resolves back to no Symbol
    // (`symbolForKey` returns null once the symbol leaves the list),
    // so `getOwnPropertySymbols` drops it. The symbol is created
    // inline and never bound, so `src`'s key is its sole reference;
    // `getOwnPropertySymbols` re-enumerates the key without needing a
    // handle to the symbol. Alternating pressure (young threshold 1)
    // fires a minor cycle on every allocation and a full cycle every
    // eighth, exercising both `markSymbolKeys` call sites. Returns 0
    // if the key was swept, 1 once it survives.
    try expectScriptIntUnderAlternatingGcPressure(
        \\function make() {
        \\  const o = {};
        \\  Object.defineProperty(o, Symbol("k"), {
        \\    get: function () { return 1; },
        \\    enumerable: true, configurable: true });
        \\  return o;
        \\}
        \\const src = make();
        \\for (let i = 0; i < 60; i++) { ({}); }
        \\Object.getOwnPropertySymbols(src).length;
    , 1);
}

test "GC: ToPrimitive receiver survives gc_threshold=1" {
    // §7.1.1 ToPrimitive — coerce a temporary object that lives only
    // in the interpreter accumulator (never a named binding, so the
    // GC reaches it through nothing it scans). The object's
    // @@toPrimitive is an accessor: ToPrimitive fetches the trap via
    // `getPropertyChain` (which fires the getter — a JS re-entry that
    // builds a call frame), then allocates the hint string before
    // Calling the trap. That lookup-then-allocate window is reachable
    // by the GC only through toPrimitive's own `value` local, so under
    // young-gen pressure (threshold 1) a sweep there reclaimed the
    // receiver and the trap Call dereferenced freed memory. Returns 42
    // once the receiver is rooted across the whole coercion.
    try expectScriptIntUnderAlternatingGcPressure(
        \\function mk() {
        \\  const o = {};
        \\  Object.defineProperty(o, Symbol.toPrimitive, {
        \\    get: function () { return function () { return 42; }; },
        \\  });
        \\  return o;
        \\}
        \\+mk();
    , 42);
}

test "GC: String.prototype.slice fresh-ToString receiver survives gc_threshold=1" {
    // §22.1.3.20 — an object receiver makes `coerceThisToJSString`
    // stringify via §7.1.17 ToString, producing a FRESH `JSString`
    // reachable only through slice's native local. The `end` argument
    // then re-enters JS (§7.1.4 ToNumber → user `valueOf`), and that
    // re-entry's frame churn drives a young-gen collection which —
    // before the fix — reclaimed the receiver. The subsequent
    // code-unit slice read of its freed bytes then either returned
    // corruption or tripped a WTF-8 decode panic. Astral receiver so
    // the slice cuts exactly at the surrogate-pair boundary (2 code
    // units): the result is the 4-byte UTF-8 of U+1F600.
    try expectScriptStringUnderGcPressure(
        \\var end = { valueOf: function () {
        \\  var s = ""; for (var i = 0; i < 300; i++) { s = ("" + i).padStart(6, "0"); }
        \\  return 2;
        \\} };
        \\var weird = { toString: function () { return String.fromCodePoint(0x1F600) + "ab"; } };
        \\String.prototype.slice.call(weird, 0, end);
    , "\u{1F600}");
}

test "GC: String.prototype.codePointAt fresh-ToString receiver survives gc_threshold=1" {
    // §22.1.3.4 — same fresh-receiver hazard, but the read happens
    // *after* the argument coercion rather than producing a new
    // string: `pos`'s `valueOf` re-enters and collects, then
    // codePointAt decodes the receiver's bytes at the resolved index.
    // Reading the astral code point at index 0 must still yield
    // 0x1F600 (128512) with the receiver rooted across the coercion.
    try expectScriptIntUnderGcPressure(
        \\var pos = { valueOf: function () {
        \\  var s = ""; for (var i = 0; i < 300; i++) { s = ("" + i).padStart(6, "0"); }
        \\  return 0;
        \\} };
        \\var weird = { toString: function () { return String.fromCodePoint(0x1F600) + "ab"; } };
        \\String.prototype.codePointAt.call(weird, pos);
    , 128512);
}

test "GC: String.prototype.indexOf fresh receiver survives needle coercion under gc_threshold=1" {
    // §22.1.3.9 — the fresh receiver `s` is held across the SEARCH
    // STRING's coercion: `stringifyArg(needle)` re-enters JS (ToString
    // on the object needle) and collects. Before the fix the receiver
    // was freed there and the code-unit search read freed bytes. With
    // the astral lead the match index is in code units: "ab" sits at
    // index 2 (the surrogate pair occupies units 0-1).
    try expectScriptIntUnderGcPressure(
        \\var needle = { toString: function () {
        \\  var s = ""; for (var i = 0; i < 300; i++) { s = ("" + i).padStart(6, "0"); }
        \\  return "ab";
        \\} };
        \\var weird = { toString: function () { return String.fromCodePoint(0x1F600) + "abXYZ"; } };
        \\String.prototype.indexOf.call(weird, needle);
    , 2);
}

test "GC: destructuring iterator record survives gc_threshold=1" {
    // `[a, b, c] = src` runs three iter_steps; the cached
    // [[NextMethod]] / [[Done]] live on the iterated object's typed
    // `iter_record` slot and must survive each next() sweep.
    try expectScriptIntUnderGcPressure(
        \\const g = { [Symbol.iterator]() { return this; }, i: 0,
        \\  next() { return { value: ++this.i, done: this.i > 4 }; } };
        \\let [a, b, c] = g;
        \\a + b + c;
    , 6);
}

test "GC: object-rest target survives gc_threshold=1" {
    // §7.3.27 CopyDataProperties (`const {a, ...rest} = src`). The
    // `object_rest_from` opcode allocates `rest` up front, then walks
    // the source's own keys reading each through `[[Get]]` — and an
    // accessor getter (`get c`) re-enters JS, so with threshold=1 a
    // full sweep fires mid-walk. `rest` is reachable only through a
    // native local until it lands in the accumulator at the end, so
    // without rooting it the sweep freed it and the next
    // `storeProperty(rest, …)` dereferenced poisoned memory (the
    // for-await-of segfault). Reads back the copied props to prove
    // the target stayed live across the getter.
    try expectScriptIntUnderGcPressure(
        \\const src = { a: 1, b: 2, get c() { return 3; }, d: 4 };
        \\const { a, ...rest } = src;
        \\rest.b + rest.c + rest.d;
    , 9);
}

test "GC: object-rest over a primitive source survives gc_threshold=1" {
    // Same opcode, ToObject(source) branch: a String primitive boxes
    // into a fresh wrapper held across the same getter re-entries as
    // the target. `{...rest} = "wxyz"` copies the indexed chars; the
    // coerced wrapper must be rooted too, or it's swept mid-walk.
    try expectScriptStringUnderGcPressure(
        \\const { 0: first, ...rest } = "wxyz";
        \\rest[1] + rest[2] + rest[3];
    , "xyz");
}

test "GC: young fn assigned to a promise's .then survives gc_threshold=1" {
    // §27.2.4 Promise aggregators forward each item via
    // `Invoke(item, "then", « resolve, reject »)`, calling the
    // per-item user `.then`. This fixture (mirrors test262
    // built-ins/Promise/any/invoke-then-on-promises-every-iteration)
    // overwrites each promise's `.then` with a fresh (young) closure
    // inside `forEach`. The aggregator's native write path stamped
    // that young function into the mature promise's shape slot
    // without the generational write barrier, so the next minor
    // sweep collected the still-reachable closure (`verifyRememberedSet`
    // slot[0]->young). `calls` only reaches 3 if every overridden
    // `.then` survived to be invoked.
    try expectScriptIntUnderGcPressure(
        \\let calls = 0;
        \\const ps = [Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)];
        \\ps.forEach(p => {
        \\  const bound = p.then.bind(p);
        \\  p.then = function(onF, onR) { calls++; return bound(onF, onR); };
        \\});
        \\let done = 0;
        \\Promise.any(ps).then(() => { done = calls; });
        \\globalThis.__drainMicrotasks();
        \\done;
    , 3);
}

test "GC: Map.groupBy buckets survive gc_threshold=1" {
    // §24.1.1.1 GroupBy — the native allocates the result Map, then
    // drives `next()` + the grouping callback (both re-enter JS) and
    // allocates a fresh bucket array + index string per group. The
    // result Map, the iterator, and the per-iteration `item` / key /
    // bucket are all held raw across those allocations; without
    // rooting them the openIterator / allocateString / allocateObject
    // sweeps freed the half-built Map (or a young item) and the next
    // `bucket.set(…)` dereferenced poison. `n` only sums to 12 if
    // every grouped object survived to land in its bucket.
    try expectScriptIntUnderGcPressure(
        \\const items = [];
        \\for (let i = 0; i < 12; i++) items.push({ v: i });
        \\const g = Map.groupBy(items, (o) => o.v % 3);
        \\g.get(0).length + g.get(1).length + g.get(2).length;
    , 12);
}

test "GC: Set.prototype.intersection result survives gc_threshold=1" {
    // §24.2.4.5 — when `this` is the smaller set the native iterates
    // `this` and probes `other.has(value)`; a user `has` re-enters JS
    // and, with threshold=1, sweeps mid-loop. The fresh result Set is
    // held raw across every probe, so without rooting it the sweep
    // freed it and the next `setAddInternal` dereferenced poison via
    // `out.getSetData()`. Size is 2 only if `out` stayed live.
    try expectScriptIntUnderGcPressure(
        \\const a = new Set([10, 20, 30]);
        \\const b = { size: 99, has(x) { return x === 10 || x === 30; },
        \\            keys() { return [][Symbol.iterator](); } };
        \\a.intersection(b).size;
    , 2);
}

test "GC: WeakSet from a custom iterable survives gc_threshold=1" {
    // §24.4.1.1 — the WeakSet constructor drives a user iterator and
    // routes each value through the (possibly overridden) `add`. The
    // iterator object / target set / adder fn are held raw across the
    // `next()` and `add` re-entries; without rooting them a sweep
    // freed the iterator and the next `iter_obj.get("next")` walked a
    // poisoned shape pointer. Counts to 3 only if all three members
    // were added.
    try expectScriptIntUnderGcPressure(
        \\const a = {}, b = {}, c = {};
        \\const iterable = { [Symbol.iterator]() {
        \\  let i = 0; const arr = [a, b, c];
        \\  return { next() { return i < arr.length
        \\    ? { value: arr[i++], done: false }
        \\    : { value: undefined, done: true }; } };
        \\} };
        \\const ws = new WeakSet(iterable);
        \\(ws.has(a) ? 1 : 0) + (ws.has(b) ? 1 : 0) + (ws.has(c) ? 1 : 0);
    , 3);
}

test "GC: Object.fromEntries result survives gc_threshold=1" {
    // §20.1.2.7 — the native opens the iterator, then allocates the
    // result object; that `allocateObject` GCs under threshold=1 and
    // would sweep the still-unrooted iterator (the first `next_fn`
    // call would then dereference poison). Rooting the iterator before
    // the result allocation keeps it live; the sum is 6 only if the
    // iteration ran to completion.
    try expectScriptIntUnderGcPressure(
        \\const o = Object.fromEntries([["a", 1], ["b", 2], ["c", 3]]);
        \\o.a + o.b + o.c;
    , 6);
}

test "debug globals: installBuiltins is debug-clean — production realms ship without test hooks" {
    // A `Realm.init + installBuiltins` (the production-style
    // embedding shape) MUST NOT install `__collectGarbage` /
    // `__clearKeptObjects` / `__drainMicrotasks`. These are
    // documented attack surfaces (forced GC → DoS; KeptAlive
    // confusion; microtask reorder TOCTOU). They live behind
    // `Realm.installTestGlobals` instead — opt-in for the test
    // harness, inline tests, the playground, and
    // `cynic run --debug-globals`. The CLI `cynic run` / `cynic eval`
    // default and any host embedding without the opt-in get a
    // clean realm.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    try testing.expect(realm.globals.get("__collectGarbage") == null);
    try testing.expect(realm.globals.get("__clearKeptObjects") == null);
    try testing.expect(realm.globals.get("__drainMicrotasks") == null);
    // After explicit opt-in, all three appear.
    try realm.installTestGlobals();
    try testing.expect(realm.globals.get("__collectGarbage") != null);
    try testing.expect(realm.globals.get("__clearKeptObjects") != null);
    try testing.expect(realm.globals.get("__drainMicrotasks") != null);
}

test "GC: WeakRef to an unreachable target clears after a major GC" {
    // §26.1 — a WeakRef whose target is no longer strongly
    // reachable must `deref()` to `undefined` after a major
    // collection. The target object `{tag: 1}` is allocated inside
    // a helper whose frame is popped before `__collectGarbage()`
    // runs, so the only edge to it is the WeakRef's weak slot —
    // which `Heap.collectFull` does not strong-mark.
    //
    // §26.1.1.1 step 4 — the `new WeakRef(target)` constructor
    // also pins `target` in §9.10 [[KeptAlive]] for the current
    // job. The synthetic `__clearKeptObjects()` drains the list
    // so the GC sees the target as unreachable. (Real engines
    // drain at the next microtask checkpoint; tests don't cross
    // one.)
    try expectScriptIntWithBuiltins(
        \\function makeRef() { return new WeakRef({ tag: 1 }); }
        \\const wr = makeRef();
        \\globalThis.__clearKeptObjects();
        \\globalThis.__collectGarbage();
        \\wr.deref() === undefined ? 1 : 0;
    , 1);
}

test "GC: WeakRef to a strongly-reachable target is NOT cleared" {
    // §26.1 — the weak slot must NOT clear while the target is
    // still strongly held. `keep` roots the target through the
    // script-top environment, so the trace marks it and the
    // post-mark pass leaves `weak_ref_target` intact.
    try expectScriptIntWithBuiltins(
        \\const keep = { tag: 2 };
        \\const wr = new WeakRef(keep);
        \\globalThis.__collectGarbage();
        \\(wr.deref() === keep && wr.deref().tag === 2) ? 1 : 0;
    , 1);
}

test "GC: WeakMap entry whose key is unreachable is gone after a major GC" {
    // §24.3 — a WeakMap entry whose key object becomes unreachable
    // is tombstoned by the collector's post-mark weak pass. The key
    // is created inside `addEntry`, whose frame is gone before the
    // GC; the WeakMap keeps a `WeakRef` to it only so the test can
    // ask `has()` afterwards.
    try expectScriptIntWithBuiltins(
        \\const wm = new WeakMap();
        \\function addEntry() {
        \\  const k = { id: 3 };
        \\  wm.set(k, "v");
        \\  return new WeakRef(k);
        \\}
        \\const probe = addEntry();
        \\globalThis.__clearKeptObjects();
        \\globalThis.__collectGarbage();
        \\let r = 0;
        \\const k2 = probe.deref();
        \\if (k2 === undefined) r += 1;          // key collected
        \\if (k2 === undefined || !wm.has(k2)) r += 10; // entry gone
        \\r;
    , 11);
}

test "GC: WeakMap entry whose key stays reachable survives a major GC" {
    // §24.3 — the symmetric case: a live key keeps its entry (and,
    // via the ephemeron rule, its value) alive across a major GC.
    try expectScriptIntWithBuiltins(
        \\const wm = new WeakMap();
        \\const key = { id: 4 };
        \\wm.set(key, "kept");
        \\globalThis.__collectGarbage();
        \\(wm.has(key) && wm.get(key) === "kept") ? 1 : 0;
    , 1);
}

test "GC: WeakMap ephemeron — value reachable only via map+key dies with the key" {
    // §24.3 ephemeron semantics — a WeakMap value is reachable iff
    // its key is. Here the value object is reachable ONLY through
    // `wm` + the (live) key, so while the key lives the value lives;
    // a WeakRef to the value still derefs. (The dies-with-the-key
    // half is covered by the unreachable-key test above — once the
    // key goes, the value's sole edge goes too.)
    try expectScriptIntWithBuiltins(
        \\const wm = new WeakMap();
        \\const key = { id: 5 };
        \\function attach() {
        \\  const val = { payload: 99 };
        \\  wm.set(key, val);
        \\  return new WeakRef(val);
        \\}
        \\const valRef = attach();
        \\globalThis.__collectGarbage();
        \\// key is live → ephemeron keeps `val` alive → WeakRef holds.
        \\let r = 0;
        \\const v = valRef.deref();
        \\if (v !== undefined && v.payload === 99) r += 1;
        \\if (wm.get(key) === v) r += 10;
        \\r;
    , 11);
}

test "GC: WeakSet member that is unreachable is gone after a major GC" {
    // §24.4 — a WeakSet member object that becomes unreachable is
    // tombstoned by the collector's post-mark weak pass.
    try expectScriptIntWithBuiltins(
        \\const ws = new WeakSet();
        \\function addMember() {
        \\  const m = { id: 6 };
        \\  ws.add(m);
        \\  return new WeakRef(m);
        \\}
        \\const probe = addMember();
        \\globalThis.__clearKeptObjects();
        \\globalThis.__collectGarbage();
        \\let r = 0;
        \\const m2 = probe.deref();
        \\if (m2 === undefined) r += 1;
        \\if (m2 === undefined || !ws.has(m2)) r += 10;
        \\r;
    , 11);
}

test "GC: WeakSet member that stays reachable survives a major GC" {
    // §24.4 — a live member is retained across a major GC.
    try expectScriptIntWithBuiltins(
        \\const ws = new WeakSet();
        \\const member = { id: 7 };
        \\ws.add(member);
        \\globalThis.__collectGarbage();
        \\ws.has(member) ? 1 : 0;
    , 1);
}

test "GC: FinalizationRegistry fires cleanup for an unreachable target" {
    // §26.2 — when a registered target becomes unreachable, the
    // collector enqueues a `cleanupCallback(heldValue)` host job.
    // The job runs on the next microtask drain (never synchronously
    // inside GC), so the test drains explicitly and checks the
    // held value reached the callback. The cell is also tombstoned.
    try expectScriptIntWithBuiltins(
        \\let cleaned = 0;
        \\const fr = new FinalizationRegistry((held) => { cleaned = held; });
        \\function register() {
        \\  const target = { id: 8 };
        \\  fr.register(target, 42);
        \\}
        \\register();
        \\globalThis.__collectGarbage();
        \\globalThis.__drainMicrotasks();
        \\cleaned;
    , 42);
}

test "GC: FinalizationRegistry does NOT fire for a live target" {
    // §26.2 — a still-reachable target must not trigger cleanup.
    try expectScriptIntWithBuiltins(
        \\let cleaned = 0;
        \\const fr = new FinalizationRegistry((held) => { cleaned = held; });
        \\const target = { id: 9 };
        \\fr.register(target, 77);
        \\globalThis.__collectGarbage();
        \\globalThis.__drainMicrotasks();
        \\cleaned;
    , 0);
}

test "iterator internal state is not an observable own property" {
    // Map / Set / RegExp-string / concat / zip iterators and the
    // destructuring iterator record keep their state in typed
    // internal slots, never as `__cynic_*` property-bag keys — a
    // spec-conformant iterator exposes no such own property, and
    // `__cynic_*` keys would still leak via direct get / `in` /
    // getOwnPropertyDescriptor / hasOwn even though `recordKey`
    // hides them from enumeration.
    try expectScriptIntWithBuiltins(
        \\const slots = ["__cynic_iter_input_0__", "__cynic_iter_method_0__",
        \\  "__cynic_iter_zip_0__", "__cynic_iter_zipnext_0__", "__cynic_iter_active_0__",
        \\  "__cynic_iter_key_0__", "__cynic_iter_pad_0__", "__cynic_map__", "__cynic_set__",
        \\  "__cynic_kind__", "__cynic_idx__", "__cynic_matchall_re__",
        \\  "__cynic_matchall_done__", "__cynic_iter_next__", "__cynic_iter_done__"];
        \\function leaks(it) {
        \\  let n = 0;
        \\  for (const k of Object.getOwnPropertyNames(it))
        \\    if (k.indexOf("__cynic") === 0) n++;
        \\  for (const s of slots) {
        \\    if (s in it) n++;
        \\    if (Object.getOwnPropertyDescriptor(it, s) !== undefined) n++;
        \\    if (Object.hasOwn(it, s)) n++;
        \\  }
        \\  return n;
        \\}
        \\let total = 0;
        \\total += leaks(Iterator.concat([1, 2]));
        \\total += leaks(Iterator.zip([[1], [2]]));
        \\total += leaks(new Map([[1, 1]]).entries());
        \\total += leaks(new Set([1]).values());
        \\total += leaks("ab".matchAll(/./g));
        \\const g = { [Symbol.iterator]() { return this; }, i: 0,
        \\  next() { return { value: this.i++, done: this.i > 2 }; } };
        \\let [da, db] = g;
        \\total += leaks(g);
        \\total;
    , 0);
}

test "iterator helpers share %IteratorHelperPrototype%" {
    // §27.1.4.1 — every iterator helper result (map / filter /
    // take / drop / flatMap / concat / zip) inherits one shared
    // %IteratorHelperPrototype%, which is distinct from
    // %IteratorPrototype%, chains to it, and carries the
    // "Iterator Helper" @@toStringTag.
    try expectScriptStringWithBuiltins(
        \\const a = [1, 2, 3].values();
        \\const hp = Object.getPrototypeOf(a.map(x => x));
        \\const shared = hp === Object.getPrototypeOf(a.filter(x => x)) &&
        \\  hp === Object.getPrototypeOf(a.take(1)) &&
        \\  hp === Object.getPrototypeOf(a.drop(0)) &&
        \\  hp === Object.getPrototypeOf(a.flatMap(x => [x])) &&
        \\  hp === Object.getPrototypeOf(Iterator.concat()) &&
        \\  hp === Object.getPrototypeOf(Iterator.zip([]));
        \\const placed = hp !== Iterator.prototype &&
        \\  Object.getPrototypeOf(hp) === Iterator.prototype;
        \\const tag = Object.prototype.toString.call(a.map(x => x));
        \\((shared && placed) ? "ok:" : "BAD:") + tag;
    , "ok:[object Iterator Helper]");
}

test "GC: property-bag growth survives gc_threshold=1" {
    // Loop writes 20 keys onto a single object, triggering at
    // least one `StringArrayHashMap.grow`. The keys are JSStrings
    // allocated for `"k" + i`; with threshold=1, each `+` and
    // `set` triggers a sweep. The object lives in a register;
    // its property entries' value pointers must survive the grow.
    try expectScriptStringUnderGcPressure(
        \\const o = {};
        \\for (let i = 0; i < 20; i++) o["k" + i] = "v" + i;
        \\let str = ""; for (let i = 0; i < 20; i++) str += o["k" + i];
        \\str;
    , "v0v1v2v3v4v5v6v7v8v9v10v11v12v13v14v15v16v17v18v19");
}

// Array-spread + iterator at gc_threshold=1 is a known gap —
// the spread loop's index-key JSStrings can be swept mid-loop
// when nothing roots them. The fix would anchor each index key
// on the target array via `setComputedOwned`, but the
// pathological poisoned-iterator fixture in test262
// (`spread-err-{sngl,mult}-err-itr-value.js`) iterates 16M
// times without breaking — anchoring those keys turns the GC
// walk quadratic and wedges the sweep. Tracked in
// `docs/handbook/gc.md`. The test below is omitted until we
// design a spread-loop allocation that's both anchored and
// quadratic-free (e.g. a real `JSArray` heap kind with packed
// indexed slots, no string keys).

// ---------------------------------------------------------------------------
// Leak / allocation-bound regressions for class machinery.
//
// 2026-05-11 — adding computed class property names
// (`class C { [expr]() {} }`) introduced a per-class ephemeral
// JSFunction allocation that, in its first iteration, also
// allocated a prototype JSObject (is_arrow=false path of
// `allocateFunction`). Under a tight class-creation loop at
// threads=4 the test262 harness OOM'd the laptop twice before
// we caught it. These tests pin the invariant at unit-test
// speed so regressions surface via `zig build test` instead of
// via "laptop fans spin up to max."
// ---------------------------------------------------------------------------

/// Build N classes with a computed key in a loop and assert
/// the heap's function pool stays bounded after a full GC.
/// Without the fix, every `[expr]` evaluation leaked an extra
/// JSObject (the auto-allocated prototype of an ephemeral key
/// function), pushing `realm.heap.objects.items.len` up linearly.
/// Run `source` (which builds N classes in a loop and drops
/// every reference to them), force a GC, and assert the heap's
/// live-object / live-function counts return to within
/// `slack`-of-baseline. Without the `is_arrow=true` fix in
/// `class.zig::resolveComputedKey`, the ephemeral key-evaluator
/// JSFunction's auto-allocated prototype JSObject would leak
/// per iteration; with the fix, post-loop counts equal pre-loop.
/// Slack absorbs the harness's own ephemeral plumbing (e.g. the
/// script's top-level chunk).
fn expectHeapBoundedAfterClassLoop(source: []const u8, slack: usize) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    realm.collectGarbage();
    const baseline_objects = realm.heap.objectCount();
    const baseline_functions = realm.heap.functionCount();
    const r = try evaluateScriptResult(&realm, source);
    switch (r) {
        .thrown => return error.UncaughtException,
        else => {},
    }
    realm.collectGarbage();
    try testing.expect(realm.heap.objectCount() <= baseline_objects + slack);
    try testing.expect(realm.heap.functionCount() <= baseline_functions + slack);
}

test "leak-bound: computed instance-method keys stay bounded under loop" {
    // 100 classes, each with one computed-key method. The
    // ephemeral key-evaluator function MUST NOT be retained
    // after the class is built. Loose bounds — what matters is
    // they don't grow with the loop count.
    try expectHeapBoundedAfterClassLoop(
        \\for (let i = 0; i < 100; i++) {
        \\  class C { [String(i)]() { return i; } }
        \\  void C;
        \\}
        \\1;
    , 16);
}

test "leak-bound: computed static-method keys stay bounded under loop" {
    try expectHeapBoundedAfterClassLoop(
        \\for (let i = 0; i < 100; i++) {
        \\  class C { static [String(i)]() { return i; } }
        \\  void C;
        \\}
        \\1;
    , 16);
}

test "leak-bound: computed field keys stay bounded under loop" {
    try expectHeapBoundedAfterClassLoop(
        \\for (let i = 0; i < 100; i++) {
        \\  class C { [String(i)] = i; }
        \\  void C;
        \\}
        \\1;
    , 16);
}

test "GC: non-computed class method survives gc_threshold=1" {
    // Baseline — non-computed class methods install before any
    // re-entry into the interpreter, so GC pressure shouldn't
    // affect them. Pinned here to catch regressions that break
    // the class machinery's basic GC roots.
    try expectScriptStringUnderGcPressure(
        \\class C { m1() { return 7; } }
        \\typeof C.prototype.m1;
    , "function");
}

test "GC: computed-key class method survives gc_threshold=1" {
    // Regression — evaluating the computed key `[k]` allocates (the
    // key string), which under threshold=1 promotes the class
    // prototype to the mature generation mid-build. The subsequent
    // `proto.setWithFlags(method)` then forms a mature→young edge to
    // the freshly-allocated method JSFunction. The minor cycle walks
    // only the remembered set (never `proto.properties`), so without
    // a post-store write barrier the next sweep freed the young
    // method and `C.prototype.m1` read back "undefined". The
    // non-computed baseline above stays green because its proto never
    // tenures before the store (no allocation in between). "function"
    // only if the barrier recorded the edge.
    try expectScriptStringUnderGcPressure(
        \\const k = "m1";
        \\class C { [k]() { return 7; } }
        \\typeof C.prototype.m1;
    , "function");
}

test "GC: computed-key static class method survives gc_threshold=1" {
    // Same hazard on the constructor side — the `ctor` tenures while
    // the computed key is evaluated, then the static-method store
    // (`ctor.set` / `ctor.private_properties.put`) forms a
    // mature→young edge. The write barrier before each store records
    // it. "function" only if the method survived the sweep.
    try expectScriptStringUnderGcPressure(
        \\const k = "s1";
        \\class C { static [k]() { return 7; } }
        \\typeof C.s1;
    , "function");
}

test "GC: static class field survives gc_threshold=1" {
    // The static field initializer's value is a freshly allocated
    // young object stored via `ctor.set(name, value)` on a ctor that
    // has already tenured. The pre-store `writeBarrier(.{ .function =
    // ctor }, value)` records the mature→young edge so the field
    // object isn't swept before it's read back. "object" only if it
    // survived.
    try expectScriptStringUnderGcPressure(
        \\class C { static f = { tag: 1 }; }
        \\typeof C.f;
    , "object");
}

test "GC: Promise.try capability survives gc_threshold=1" {
    // §27.2.4.7 Promise.try builds a PromiseCapability (promise +
    // resolve + reject) that lives only in a native struct, then runs
    // the callback — arbitrary user JS that GCs. The callback below
    // allocates, so a full sweep fires *inside* it; pre-fix the unrooted
    // capability island was swept and `capabilityResolve` then called a
    // freed function ("value is not callable"). With the triad rooted
    // via a HandleScope the chained `.then` observes the fulfilled
    // value. 42 only if the capability survived.
    try expectScriptIntUnderGcPressure(
        \\let acc = 0;
        \\Promise.try(function () { let o = { a: 1, b: 2 }; return o.a + o.b + 39; })
        \\  .then(function (v) { acc = v; });
        \\globalThis.__drainMicrotasks();
        \\acc;
    , 42);
}

test "GC: using SuppressedError chain survives gc_threshold=1" {
    // §9.5.4 DisposeResources, multi-throw: the running completion walks
    // error3 → SuppressedError(error2, error3) → SuppressedError(error1,
    // …). Each intermediate SuppressedError is bound to no JS variable,
    // so the next disposer re-entry (which GCs) swept it pre-fix and the
    // wrapped chain dangled — `e.suppressed.error` was no longer error2.
    // Rooting the running completion across the walk keeps the identity
    // chain intact. All five identity checks read "true" only if it
    // survived.
    try expectScriptStringUnderGcPressure(
        \\class MyError extends Error {}
        \\const error1 = new MyError();
        \\const error2 = new MyError();
        \\const error3 = new MyError();
        \\let out = "no-throw";
        \\try {
        \\  using _1 = { [Symbol.dispose]() { throw error1; } };
        \\  using _2 = { [Symbol.dispose]() { throw error2; } };
        \\  throw error3;
        \\} catch (e) {
        \\  out = [
        \\    e instanceof SuppressedError,
        \\    e.error === error1,
        \\    e.suppressed instanceof SuppressedError,
        \\    e.suppressed.error === error2,
        \\    e.suppressed.suppressed === error3,
        \\  ].join(",");
        \\}
        \\out;
    , "true,true,true,true,true");
}

// ---------------------------------------------------------------------------
// §23.1.3 Array.prototype — receiver coercion + spec dispatch regressions.
//
// 2026-05-11 — Lever #2 (`Array.prototype` Get(O, ToString(k)) dispatch).
// Three buckets of bugs, pinned here so future refactors don't slip
// back: (1) `lastIndexOf` was completely ignoring its `fromIndex`
// argument; (2) `findLastIndex` / `reduceRight` / `flatMap` skipped
// the prototype-chain walk, so an inherited indexed accessor was
// invisible; (3) failure paths returned an opaque `NativeThrew`
// instead of an explicit TypeError. test262's `15.4.4.X-*` legacy
// suite hits all three.
// ---------------------------------------------------------------------------

test "Array.prototype.lastIndexOf: respects fromIndex" {
    // §23.1.3.20 — fromIndex must clamp the search end. Previously
    // we ignored args[1] entirely and searched the whole array.
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, 1);", 1);
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, 0);", -1);
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, -1);", 1);
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, -3);", -1);
}

test "Array.prototype.lastIndexOf: coerces fromIndex via ToIntegerOrInfinity" {
    // Booleans coerce to 0 / 1; strings via ToNumber.
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, true);", 1);
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, false);", -1);
    try expectScriptIntWithBuiltins("[1, 2, 1].lastIndexOf(2, \"1\");", 1);
}

test "Array.prototype.reduceRight: walks prototype chain for indexed reads" {
    // Install an indexed accessor on Object.prototype — the
    // sparse slot in the array must surface it (spec uses
    // `HasProperty` + `Get`, both of which descend the chain).
    // Requires unhardened mode: hardened freezes Object.prototype
    // so `defineProperty` would throw before we can probe the
    // chain-walk.
    try expectScriptIntUnhardened(
        \\Object.defineProperty(Object.prototype, "0", { get() { return 10; }, configurable: true });
        \\const a = [];
        \\a.length = 1;
        \\const r = a.reduceRight((acc, v) => acc + v, 0);
        \\delete Object.prototype[0];
        \\r;
    , 10);
}

test "Array.prototype.findLastIndex: walks prototype chain" {
    // Same SES caveat as the reduceRight test above — needs to
    // mutate Object.prototype, which hardened mode forbids.
    try expectScriptIntUnhardened(
        \\Object.defineProperty(Object.prototype, "0", { get() { return 42; }, configurable: true });
        \\const a = [];
        \\a.length = 1;
        \\const r = a.findLastIndex(v => v === 42);
        \\delete Object.prototype[0];
        \\r;
    , 0);
}

test "Array.prototype.lastIndexOf: sparse fast path walks own keys descending" {
    // `arr[2**32 - 2] = null` puts a single own slot at idx
    // 4294967294 with length = 4294967295. A naive linear walk
    // from `len - 1` hits `clampArrayLength`'s 16M cap and
    // returns -1; the sparse fast path walks `sparse_elements`
    // keys in descending order and finds it.
    try expectScriptStringWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = null;
        \\String(arr.lastIndexOf(null, Infinity));
    , "4294967294");
    try expectScriptStringWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = "x";
        \\arr[100] = "x";
        \\String(arr.lastIndexOf("x"));
    , "4294967294");
    try expectScriptIntWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = "x";
        \\arr[100] = "x";
        \\arr.lastIndexOf("x", 200);
    , 100);
    try expectScriptIntWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = "x";
        \\arr.lastIndexOf("missing");
    , -1);
}

test "Array.prototype.reduceRight: sparse fast path walks own keys descending" {
    // Three sparse own keys at 50, 100, 4294967294. reduceRight
    // visits them right-to-left; with an initial acc the
    // first iteration multiplies acc by the rightmost value.
    try expectScriptStringWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = 10;
        \\arr[100] = 1;
        \\arr[50] = 2;
        \\arr.reduceRight((acc, v, i) => acc + ":" + v + "@" + i, "S");
    , "S:10@4294967294:1@100:2@50");
}

test "Array.prototype.reduceRight: sparse without initial acc seeds from rightmost present" {
    try expectScriptIntWithBuiltins(
        \\const arr = [];
        \\arr[Math.pow(2, 32) - 2] = 100;
        \\arr[5] = 3;
        \\arr.reduceRight((acc, v) => acc + v);
    , 103);
}

test "Object.defineProperty: accessor at index >= length extends length" {
    // §10.4.2.4 ArraySetLength step 3.h — defining ANY property
    // (data OR accessor) at index P where P ≥ length sets
    // length to P + 1. The data path always did this; the
    // accessor path historically didn't, leaving Array.prototype.X
    // fixtures over a single-accessor array iterating zero times.
    try expectScriptIntWithBuiltins(
        \\const a = [];
        \\Object.defineProperty(a, "0", { get() { return 7; }, configurable: true });
        \\a.length;
    , 1);
    try expectScriptIntWithBuiltins(
        \\const a = [];
        \\Object.defineProperty(a, "5", { get() { return 7; }, configurable: true });
        \\a.length;
    , 6);
    try expectScriptIntWithBuiltins(
        \\const a = [];
        \\Object.defineProperty(a, "0", { get() { return 7; }, configurable: true });
        \\const r = a.map(v => v * 2);
        \\r[0];
    , 14);
}

test "Array.prototype.reduceRight: empty array without initial throws TypeError" {
    // §23.1.3.27 step 7 — TypeError, not opaque NativeThrew.
    try expectScriptStringWithBuiltins(
        \\try { [].reduceRight((a, b) => a + b); "no throw" }
        \\catch (e) { e.constructor.name }
    , "TypeError");
}

// ---------------------------------------------------------------------------
// §26.2 FinalizationRegistry
// ---------------------------------------------------------------------------

fn expectScriptThrowsWithBuiltins(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const result = try evaluateScriptResult(&realm, source);
    switch (result) {
        .value, .yielded => return error.ExpectedThrow,
        .thrown => {},
    }
}

test "later: FinalizationRegistry constructor exists" {
    try expectScriptStringWithBuiltins(
        \\typeof FinalizationRegistry;
    , "function");
}

test "later: FinalizationRegistry rejects non-callable cleanupCallback" {
    // §26.2.1.1 step 2 — IsCallable(cleanupCallback) is false → TypeError.
    try expectScriptThrowsWithBuiltins("new FinalizationRegistry({});");
    try expectScriptThrowsWithBuiltins("new FinalizationRegistry();");
    try expectScriptThrowsWithBuiltins("new FinalizationRegistry(null);");
    try expectScriptThrowsWithBuiltins("new FinalizationRegistry(42);");
}

test "later: FinalizationRegistry register returns undefined" {
    // §26.2.3.2 step 8 — register returns undefined.
    try expectScriptStringWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\const t = {};
        \\typeof fr.register(t, "held");
    , "undefined");
}

test "later: FinalizationRegistry register rejects non-weakly-holdable target" {
    // §26.2.3.2 step 3 — CanBeHeldWeakly(target) false → TypeError.
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\fr.register(undefined);
    );
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\fr.register(42);
    );
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\fr.register("not weakly holdable");
    );
}

test "later: FinalizationRegistry register rejects target same as heldValue" {
    // §26.2.3.2 step 4 — SameValue(target, heldValue) → TypeError.
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\const t = {};
        \\fr.register(t, t);
    );
}

test "later: FinalizationRegistry unregister returns true when token matched" {
    // §26.2.3.3 step 6 — return whether anything was removed.
    try expectScriptIntWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\const t = {};
        \\const tok = {};
        \\fr.register(t, "held", tok);
        \\fr.unregister(tok) ? 1 : 0;
    , 1);
}

test "later: FinalizationRegistry unregister returns false when no match" {
    try expectScriptIntWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\const tok = {};
        \\fr.unregister(tok) ? 1 : 0;
    , 0);
}

test "later: FinalizationRegistry unregister rejects non-weakly-holdable token" {
    // §26.2.3.3 step 3 — CanBeHeldWeakly(unregisterToken) false → TypeError.
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\fr.unregister(42);
    );
    try expectScriptThrowsWithBuiltins(
        \\const fr = new FinalizationRegistry(function() {});
        \\fr.unregister(undefined);
    );
}

test "later: FinalizationRegistry register/unregister survive prototype crossover" {
    // §26.2.3.2 step 2 / §26.2.3.3 step 2 — RequireInternalSlot([[Cells]])
    // → TypeError when called on receivers without [[Cells]].
    try expectScriptThrowsWithBuiltins(
        \\FinalizationRegistry.prototype.register.call({}, {});
    );
    try expectScriptThrowsWithBuiltins(
        \\FinalizationRegistry.prototype.unregister.call({}, {});
    );
}

// ---------------------------------------------------------------------------
// §26.1 WeakRef
// ---------------------------------------------------------------------------

test "later: WeakRef constructor accepts an object target" {
    try expectScriptIntWithBuiltins(
        \\const t = { x: 7 };
        \\const wr = new WeakRef(t);
        \\wr.deref().x;
    , 7);
}

test "later: WeakRef constructor accepts a function target" {
    // §6.2.10 CanBeHeldWeakly — functions are objects.
    try expectScriptIntWithBuiltins(
        \\const f = function () { return 42; };
        \\const wr = new WeakRef(f);
        \\wr.deref()();
    , 42);
}

test "later: WeakRef constructor accepts a non-registered symbol" {
    // §26.1.1.1 step 2 + §6.2.10 — Symbol() is weakly holdable.
    try expectScriptIntWithBuiltins(
        \\const s = Symbol("a");
        \\const wr = new WeakRef(s);
        \\wr.deref() === s ? 1 : 0;
    , 1);
}

test "later: WeakRef constructor rejects undefined target" {
    // §26.1.1.1 step 2 — CanBeHeldWeakly(undefined) is false.
    try expectScriptThrowsWithBuiltins(
        \\new WeakRef();
    );
}

test "later: WeakRef constructor rejects null target" {
    try expectScriptThrowsWithBuiltins(
        \\new WeakRef(null);
    );
}

test "later: WeakRef constructor rejects number target" {
    try expectScriptThrowsWithBuiltins(
        \\new WeakRef(1);
    );
}

test "later: WeakRef constructor rejects string target" {
    try expectScriptThrowsWithBuiltins(
        \\new WeakRef("not an object");
    );
}

test "later: WeakRef constructor rejects registered symbol target" {
    // §6.2.10 — Symbol.for() symbols are *not* weakly holdable.
    try expectScriptThrowsWithBuiltins(
        \\new WeakRef(Symbol.for("k"));
    );
}

test "later: WeakRef called without new throws" {
    // §26.1.1.1 step 1 — undefined NewTarget → TypeError.
    try expectScriptThrowsWithBuiltins(
        \\WeakRef({});
    );
}

test "later: WeakRef.prototype.deref on plain object throws" {
    // §26.1.3.2 step 2 — RequireInternalSlot([[WeakRefTarget]]).
    try expectScriptThrowsWithBuiltins(
        \\WeakRef.prototype.deref.call({});
    );
}

test "later: WeakRef.prototype.deref on prototype itself throws" {
    try expectScriptThrowsWithBuiltins(
        \\WeakRef.prototype.deref();
    );
}

test "later: WeakRef.prototype.deref on primitive throws" {
    try expectScriptThrowsWithBuiltins(
        \\WeakRef.prototype.deref.call(undefined);
    );
}

// ---------------------------------------------------------------------------
// §24.1.5 %MapIteratorPrototype% / §24.2.5 %SetIteratorPrototype%
// ---------------------------------------------------------------------------

test "later: MapIteratorPrototype is shared across .entries/.keys/.values" {
    // §24.1.5.1 — every Map iterator shares one prototype object.
    try expectScriptStringWithBuiltins(
        \\const m = new Map();
        \\const a = Object.getPrototypeOf(m.entries());
        \\const b = Object.getPrototypeOf(m.keys());
        \\const c = Object.getPrototypeOf(m.values());
        \\(a === b && b === c) ? "ok" : "no";
    , "ok");
}

test "later: MapIteratorPrototype Symbol.toStringTag is 'Map Iterator'" {
    // §24.1.5.2.2 — initial @@toStringTag is "Map Iterator".
    try expectScriptStringWithBuiltins(
        \\Object.getPrototypeOf(new Map().values())[Symbol.toStringTag];
    , "Map Iterator");
}

test "later: MapIteratorPrototype.next.length is 0 and name is 'next'" {
    try expectScriptStringWithBuiltins(
        \\const p = Object.getPrototypeOf(new Map().values());
        \\p.next.length + ":" + p.next.name;
    , "0:next");
}

test "later: MapIteratorPrototype.next throws on non-object this" {
    // §24.1.5.1 step 1 — RequireInternalSlot([[IteratedObject]]).
    try expectScriptThrowsWithBuiltins(
        \\const it = new Map().values();
        \\it.next.call(false);
    );
}

test "later: MapIteratorPrototype.next throws on plain {} this" {
    // §24.1.5.1 — missing internal slot → TypeError.
    try expectScriptThrowsWithBuiltins(
        \\const it = new Map().values();
        \\it.next.call({});
    );
}

test "later: SetIteratorPrototype is shared across .values/.entries" {
    try expectScriptStringWithBuiltins(
        \\const s = new Set();
        \\const a = Object.getPrototypeOf(s.values());
        \\const b = Object.getPrototypeOf(s.entries());
        \\(a === b) ? "ok" : "no";
    , "ok");
}

test "later: SetIteratorPrototype Symbol.toStringTag is 'Set Iterator'" {
    try expectScriptStringWithBuiltins(
        \\Object.getPrototypeOf(new Set().values())[Symbol.toStringTag];
    , "Set Iterator");
}

test "later: SetIteratorPrototype.next throws on non-object this" {
    try expectScriptThrowsWithBuiltins(
        \\const it = new Set().values();
        \\it.next.call(undefined);
    );
}

test "later: SetIteratorPrototype.next throws on plain {} this" {
    try expectScriptThrowsWithBuiltins(
        \\const it = new Set().values();
        \\it.next.call({});
    );
}

// ---------------------------------------------------------------------------
// §10.2.4 %ThrowTypeError%
// ---------------------------------------------------------------------------

test "later: %ThrowTypeError% is the callee getter on a strict arguments object" {
    // §10.4.4.7 step 5 — strict-mode arguments has a "callee"
    // accessor whose [[Get]] and [[Set]] are %ThrowTypeError%.
    try expectScriptStringWithBuiltins(
        \\typeof Object.getOwnPropertyDescriptor(function() { "use strict"; return arguments; }(), "callee").get;
    , "function");
}

test "later: %ThrowTypeError% throws TypeError when invoked" {
    try expectScriptThrowsWithBuiltins(
        \\const t = Object.getOwnPropertyDescriptor(function() { "use strict"; return arguments; }(), "callee").get;
        \\t();
    );
}

test "later: %ThrowTypeError% is unique per realm" {
    // §10.2.4 — one %ThrowTypeError% per realm; callee.get and
    // callee.set are the same function object.
    try expectScriptStringWithBuiltins(
        \\const d = Object.getOwnPropertyDescriptor(function() { "use strict"; return arguments; }(), "callee");
        \\(d.get === d.set) ? "ok" : "no";
    , "ok");
}

test "later: %ThrowTypeError%.length is 0" {
    try expectScriptIntWithBuiltins(
        \\Object.getOwnPropertyDescriptor(function() { "use strict"; return arguments; }(), "callee").get.length;
    , 0);
}

test "later: %ThrowTypeError% is frozen" {
    try expectScriptStringWithBuiltins(
        \\Object.isFrozen(Object.getOwnPropertyDescriptor(function() { "use strict"; return arguments; }(), "callee").get) ? "yes" : "no";
    , "yes");
}

// ── §10.1.8 / §10.1.14 — JSFunction accessor support ────────────
//
// JSFunction grew an `accessors` map mirroring JSObject.accessors,
// so `Object.defineProperty(fn, key, {get, set})` lands as an
// accessor descriptor instead of being silently coerced to a data
// property. The `new`-path GetPrototypeFromConstructor (§10.1.14)
// reads `prototype` through this map so user-installed getters
// on a NewTarget fire.

test "later: defineProperty(fn, key, {get}) fires getter on read" {
    try expectScriptIntWithBuiltins(
        \\function f() {}
        \\Object.defineProperty(f, 'p', { get: function() { return 42; } });
        \\f.p;
    , 42);
}

test "later: getOwnPropertyDescriptor(fn, key) reports accessor shape" {
    try expectScriptStringWithBuiltins(
        \\function f() {}
        \\const g = function() { return 7; };
        \\Object.defineProperty(f, 'p', { get: g });
        \\const d = Object.getOwnPropertyDescriptor(f, 'p');
        \\(d.get === g) + ":" + ("value" in d);
    , "true:false");
}

test "later: GetPrototypeFromConstructor honors accessor on bound NewTarget" {
    // Mirrors built-ins/WeakRef/prototype-from-newtarget-custom.js
    // — the bound function carries an accessor on `prototype`,
    // §10.1.14 returns whatever the getter produces.
    try expectScriptStringWithBuiltins(
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, 'prototype', {
        \\  get: function() { return Array.prototype; }
        \\});
        \\var wr = Reflect.construct(WeakRef, [{}], newTarget);
        \\Object.getPrototypeOf(wr) === Array.prototype ? "ok" : "no";
    , "ok");
}

test "later: GetPrototypeFromConstructor propagates abrupt getter throw" {
    // Mirrors built-ins/WeakRef/prototype-from-newtarget-abrupt.js
    // — getter throws, the throw escapes Reflect.construct.
    try expectScriptStringWithBuiltins(
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, 'prototype', {
        \\  get: function() { throw new Error('abrupt'); }
        \\});
        \\try { Reflect.construct(WeakRef, [{}], newTarget); "no-throw"; }
        \\catch (e) { e.message; }
    , "abrupt");
}

test "later: GetPrototypeFromConstructor derives default proto from newTarget's realm" {
    // §10.1.14 GetPrototypeFromConstructor step 4 — when
    // `Get(constructor, "prototype")` is not an Object, the default
    // prototype is the *constructor's* realm's intrinsic, not the
    // active realm's. Mirrors built-ins/Map/proto-from-ctor-realm.js:
    //   var C = new other.Function(); C.prototype = null;
    //   var o = Reflect.construct(Map, [], C);
    //   assert.sameValue(Object.getPrototypeOf(o), other.Map.prototype);
    // Map has no dedicated `Intrinsics` field, so the remap must
    // resolve it through the constructor realm's global binding.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const NativeError = @import("../function.zig").NativeError;
    const Noop = struct {
        fn body(r: *Realm, t: Value, a: []const Value) NativeError!Value {
            _ = r;
            _ = t;
            _ = a;
            return Value.undefined_;
        }
    };

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // The default proto the caller forwards is the *active* (parent)
    // realm's Map.prototype — exactly what `constructValue` passes as
    // `target.prototype` for `Reflect.construct(Map, …)`.
    const parent_map = heap_mod.valueAsFunction(parent.globals.get("Map").?).?;
    const child_map = heap_mod.valueAsFunction(child.globals.get("Map").?).?;
    const parent_map_proto = parent_map.prototype;
    const child_map_proto = child_map.prototype;
    try testing.expect(parent_map_proto != null);
    try testing.expect(child_map_proto != null);
    try testing.expect(parent_map_proto != child_map_proto);

    // Mint `C` in the child realm with a non-object `prototype`
    // (the fixture's `C.prototype = null`).
    const C = try parent.heap.allocateFunctionNative(&parent, Noop.body, 0, "C");
    C.realm = &child;
    try C.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    const lookup = try call.getPrototypeFromConstructor(testing.allocator, &parent, C, parent_map_proto, &parent);
    try testing.expect(lookup == .proto);
    try testing.expectEqual(child_map_proto, lookup.proto);
}

test "later: GetPrototypeFromConstructor remaps default proto through a Proxy newTarget's realm (§10.2.5)" {
    // §10.1.14 GetPrototypeFromConstructor step 4 + §10.2.5
    // GetFunctionRealm step 4 — when the newTarget is a Proxy whose
    // target function lives in another realm and whose `prototype` is
    // non-object, the default proto must resolve against that target
    // realm's intrinsics, recursed through the proxy chain — not the
    // active realm's. Mirrors built-ins/Proxy/get-fn-realm.js (one
    // level; get-fn-realm-recursive.js covers the multi-level chain).
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const NativeError = @import("../function.zig").NativeError;
    const Noop = struct {
        fn body(r: *Realm, t: Value, a: []const Value) NativeError!Value {
            _ = r;
            _ = t;
            _ = a;
            return Value.undefined_;
        }
    };

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const parent_map = heap_mod.valueAsFunction(parent.globals.get("Map").?).?;
    const child_map = heap_mod.valueAsFunction(child.globals.get("Map").?).?;
    const parent_map_proto = parent_map.prototype;
    const child_map_proto = child_map.prototype;
    try testing.expect(parent_map_proto != null);
    try testing.expect(child_map_proto != null);
    try testing.expect(parent_map_proto != child_map_proto);

    // `C`: a child-realm function with a non-object `prototype`.
    const C = try parent.heap.allocateFunctionNative(&parent, Noop.body, 0, "C");
    C.realm = &child;
    try C.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    // A callable Proxy over `C` with an empty handler, minted in the
    // parent (active) realm — the newTarget the construct path sees.
    const handler = try parent.heap.allocateObject();
    const proxy = try parent.heap.allocateObject();
    parent.heap.setProxyHandler(proxy, handler);
    parent.heap.setProxyTargetFn(proxy, C);
    proxy.proxy_callable = true;

    // The active-realm default the caller forwards is parent.Map.prototype
    // (what `Reflect.construct(Map, …)` passes). The remap must swap it for
    // the *child* realm's Map.prototype, since GetFunctionRealm(proxy) = child.
    const lookup = try call.getPrototypeFromConstructorValue(
        testing.allocator,
        &parent,
        heap_mod.taggedObject(proxy),
        parent_map_proto,
        &parent,
    );
    try testing.expect(lookup == .proto);
    try testing.expectEqual(child_map_proto, lookup.proto);
}

test "later: cross-realm generator instance derives its prototype from the function's realm (§9.1.14)" {
    // §15.6.2 EvaluateGeneratorBody → §10.1.13 OrdinaryCreateFromConstructor
    // → §10.1.14 GetPrototypeFromConstructor step 4 — a generator function
    // created in the child realm, with a non-object `prototype`, must produce
    // instances whose [[Prototype]] is the *child* realm's %GeneratorPrototype%
    // (GetFunctionRealm of the callee, §10.2.5), even when invoked while the
    // parent realm is running. Mirrors
    // language/expressions/generators/eval-body-proto-realm.js.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const intrinsics_mod = @import("../intrinsics.zig");
    const generator_mod = @import("generator.zig");

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // A generator function whose [[Realm]] is the child (created by an
    // indirect eval that runs in the child).
    const gfn_v = try intrinsics_mod.performIndirectEval(&child, "(function* () {})");
    const gfn = heap_mod.valueAsFunction(gfn_v).?;
    try testing.expectEqual(&child, gfn.realm.?);
    // §10.1.14 step 4 fallback: make `Get(fn, "prototype")` a non-object.
    try gfn.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    // Call it with the PARENT realm running.
    const res = try call.callJSFunction(testing.allocator, &parent, gfn, Value.undefined_, &.{});
    try testing.expect(res == .value);
    const gen = heap_mod.valueAsPlainObject(res.value).?;
    const child_gen_proto = try generator_mod.ensureGeneratorPrototype(&child);
    try testing.expectEqual(child_gen_proto, gen.prototype.?);
}

test "later: cross-realm async generator instance derives its prototype from the function's realm (§9.1.14)" {
    // §27.6.3.2 AsyncGeneratorStart — same §10.1.14 step-4 fallback as the
    // sync generator above, resolving to the child realm's
    // %AsyncGeneratorPrototype%. Mirrors
    // language/expressions/async-generator/eval-body-proto-realm.js.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const intrinsics_mod = @import("../intrinsics.zig");
    const generator_mod = @import("generator.zig");

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const agfn_v = try intrinsics_mod.performIndirectEval(&child, "(async function* () {})");
    const agfn = heap_mod.valueAsFunction(agfn_v).?;
    try testing.expectEqual(&child, agfn.realm.?);
    try agfn.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    const res = try call.callJSFunction(testing.allocator, &parent, agfn, Value.undefined_, &.{});
    try testing.expect(res == .value);
    const agen = heap_mod.valueAsPlainObject(res.value).?;
    const child_agen_proto = try generator_mod.ensureAsyncGeneratorPrototype(&child);
    try testing.expectEqual(child_agen_proto, agen.prototype.?);
}

test "later: Array [[Construct]] derives result proto from newTarget's realm" {
    // §22.1.1 Array(...) + §10.1.14 — `Reflect.construct(Array, args,
    // C)` where `C` is a cross-realm function with a non-object
    // `prototype` must yield an Array exotic object whose
    // [[Prototype]] is the *child* realm's %Array.prototype% (the
    // realm of GetFunctionRealm(C)), not the active realm's. Mirrors
    // built-ins/Array/proto-from-ctor-realm-{zero,one,two}.js. The
    // construct path pre-allocates `this` with the resolved proto;
    // arrayConstructor must recognise that cross-realm instance via
    // the realm-agnostic `is_array_exotic` chain marker and reuse it
    // in place rather than allocating a fresh Array with the active
    // realm's prototype.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const NativeError = @import("../function.zig").NativeError;
    const Noop = struct {
        fn body(r: *Realm, t: Value, a: []const Value) NativeError!Value {
            _ = r;
            _ = t;
            _ = a;
            return Value.undefined_;
        }
    };

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const parent_array = heap_mod.valueAsFunction(parent.globals.get("Array").?).?;
    const child_array = heap_mod.valueAsFunction(child.globals.get("Array").?).?;
    try testing.expect(parent_array.prototype != null);
    try testing.expect(child_array.prototype != null);
    try testing.expect(parent_array.prototype != child_array.prototype);

    const C = try parent.heap.allocateFunctionNative(&parent, Noop.body, 0, "C");
    C.realm = &child;
    try C.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    const res = try call.constructValue(
        testing.allocator,
        &parent,
        heap_mod.taggedFunction(parent_array),
        &[_]Value{ Value.fromInt32(1), Value.fromInt32(2) },
        heap_mod.taggedFunction(C),
    );
    try testing.expect(res == .value);
    const obj = heap_mod.valueAsPlainObject(res.value).?;
    try testing.expect(obj.is_array_exotic);
    try testing.expectEqual(child_array.prototype, obj.prototype);
}

test "later: Function [[Construct]] derives result proto from newTarget's realm" {
    // §20.2.1.1.1 CreateDynamicFunction step 22 + §10.1.14 —
    // `Reflect.construct(Function, [], C)` with `C` a cross-realm
    // function whose `prototype` is null must yield a function whose
    // [[Prototype]] is the *child* realm's %Function.prototype%.
    // Mirrors built-ins/Function/proto-from-ctor-realm.js.
    // functionConstructor must read the resolved proto from the
    // construct path's OCFC `this_value`, not hardcode the active /
    // constructor realm's %Function.prototype%.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");
    const NativeError = @import("../function.zig").NativeError;
    const Noop = struct {
        fn body(r: *Realm, t: Value, a: []const Value) NativeError!Value {
            _ = r;
            _ = t;
            _ = a;
            return Value.undefined_;
        }
    };

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const parent_fn_ctor = heap_mod.valueAsFunction(parent.globals.get("Function").?).?;
    const parent_fn_proto = parent.intrinsics.function_prototype;
    const child_fn_proto = child.intrinsics.function_prototype;
    try testing.expect(parent_fn_proto != null);
    try testing.expect(child_fn_proto != null);
    try testing.expect(parent_fn_proto != child_fn_proto);

    const C = try parent.heap.allocateFunctionNative(&parent, Noop.body, 0, "C");
    C.realm = &child;
    try C.setWithFlags(testing.allocator, "prototype", Value.null_, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    const res = try call.constructValue(
        testing.allocator,
        &parent,
        heap_mod.taggedFunction(parent_fn_ctor),
        &[_]Value{},
        heap_mod.taggedFunction(C),
    );
    try testing.expect(res == .value);
    const f = heap_mod.valueAsFunction(res.value).?;
    try testing.expectEqual(child_fn_proto, f.proto);
}

test "later: Object(primitive) boxes on a cross-realm method-call receiver" {
    // §20.1.1.1 Object(value) + §7.1.18 ToObject — a *plain* call
    // `other.Object(0n)` passes the member base (the other realm's
    // `globalThis`) as `this_value`. The §20.1.1.1 step-1 subclass
    // short-circuit ("`this_value` is a pre-allocated subclass
    // instance → return it") must NOT fire for that foreign receiver:
    // its [[Prototype]] chain reaches the *child* realm's
    // %Object.prototype%, never the caller's, so it is not an
    // Object-derived instance of this realm. Before the chain check,
    // the bare `proto != %Object.prototype%` test mistook the child
    // global for a subclass `this` and returned it verbatim, so
    // `other.Object(0n)` yielded the child global instead of a BigInt
    // wrapper — and the subsequent `BigInt.prototype.valueOf` brand
    // check threw. Mirrors built-ins/BigInt/prototype/valueOf/cross-realm.js.
    const call = @import("call.zig");
    const heap_mod = @import("../heap.zig");

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try installBuiltinsAllFeatures(&parent);

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // The foreign receiver's proto is the *child* realm's
    // %Object.prototype%, distinct from the caller (parent) realm's.
    try testing.expect(parent.intrinsics.object_prototype != child.intrinsics.object_prototype);

    const child_object = heap_mod.valueAsFunction(child.globals.get("Object").?).?;
    const child_global = child.globals.get("globalThis").?;

    const bi = try parent.heap.allocateBigInt(0);
    const bi_val = heap_mod.taggedBigInt(bi);

    // `other.Object(0n)` — the native runs in the caller (parent)
    // realm, with `this_value` = the child globalThis (member base).
    const res = try call.callJSFunction(
        testing.allocator,
        &parent,
        child_object,
        child_global,
        &[_]Value{bi_val},
    );
    try testing.expect(res == .value);
    // A fresh BigInt wrapper, NOT the foreign receiver returned verbatim.
    try testing.expect(res.value.bits != child_global.bits);
    const wrapper = heap_mod.valueAsPlainObject(res.value).?;
    // The boxed primitive is recoverable — exactly what
    // §21.2.3.4 thisBigIntValue reads in `BigInt.prototype.valueOf`.
    try testing.expect(wrapper.boxed_primitive != null);
    try testing.expectEqual(bi_val.bits, wrapper.boxed_primitive.?.bits);
}

test "later: new F() with non-object prototype falls back to %Object.prototype%" {
    // §10.2.2 base-kind [[Construct]] → OrdinaryCreateFromConstructor
    // with intrinsicDefaultProto = "%Object.prototype%". When an
    // ordinary function's `prototype` is not an Object
    // (`F.prototype = null`), §10.1.14 step 4 falls back to that
    // intrinsic — NOT the function's own (now stale) `.prototype`
    // slot. Exercises the interpreter `new_call` opcode default.
    try expectScriptStringWithBuiltins(
        \\function F() {}
        \\F.prototype = null;
        \\Object.getPrototypeOf(new F()) === Object.prototype ? "ok" : "bad";
    , "ok");
}

test "later: Reflect.construct(T, [], C) with C.prototype null uses %Object.prototype%" {
    // §28.1.2 Reflect.construct → §10.2.2 base-kind — the result's
    // [[Prototype]] derives from NewTarget `C`. With `C.prototype =
    // null` and an ordinary `T`, GetPrototypeFromConstructor falls
    // back to %Object.prototype%, not `T.prototype`. Exercises the
    // `reflectConstruct` proto-resolution path (distinct from the
    // interpreter opcode — Reflect.construct lets target ≠ NewTarget).
    try expectScriptStringWithBuiltins(
        \\function C() {}
        \\C.prototype = null;
        \\function T() {}
        \\var r = Reflect.construct(T, [], C);
        \\Object.getPrototypeOf(r) === Object.prototype ? "ok" : "bad";
    , "ok");
}

test "later: Reflect.construct(bound, [], C) with C.prototype null uses %Object.prototype%" {
    // §10.4.1.2 Bound Function [[Construct]] forwards to the unwrapped
    // base target with NewTarget preserved; §10.2.2 base-kind then
    // resolves the proto from `C`. With `C.prototype = null` the
    // fallback is %Object.prototype% (the unwrapped base target is an
    // ordinary function, so its own slot is irrelevant). Mirrors
    // built-ins/Function/prototype/bind/proto-from-ctor-realm.js's
    // single-realm shape.
    try expectScriptStringWithBuiltins(
        \\function C() {}
        \\C.prototype = null;
        \\var r = Reflect.construct(function(){}.bind(), [], C);
        \\Object.getPrototypeOf(r) === Object.prototype ? "ok" : "bad";
    , "ok");
}

test "later: new Function() with null prototype falls back to %Object.prototype%" {
    // §20.2.1.1.1 CreateDynamicFunction — `new Function()` (no source
    // string) yields an *ordinary* function. Cynic implements its body
    // natively, but its [[Construct]] is still the §10.2.2 base kind:
    // with `C.prototype = null`, §10.1.14 step 4 falls back to
    // %Object.prototype%, NOT the fresh ordinary object Cynic parked in
    // C's `.prototype` slot at creation. Regression guard for the
    // `native_ordinary_function` discriminator — without it, a native
    // function is mistaken for a built-in constructor and returns its
    // own slot. Single-realm analog of
    // built-ins/Array/{from,of}/proto-from-ctor-realm.js.
    try expectScriptStringWithBuiltins(
        \\var C = new Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(C, [])) === Object.prototype ? "ok" : "bad";
    , "ok");
}

// ── §20.2.3 Function.prototype own properties ──────────────────────────────
//
// Per §20.2.3 the Function prototype object has a `length` of 0 and
// a `name` of "" — both with §17 default flags
// `{w:false, e:false, c:true}`. Property order per §17 install order
// is `length` then `name`.

test "later: Function.prototype.length is 0 with §17 flags" {
    // §20.2.3 + §17 — `Function.prototype.length` is `0` with
    // `{w:false, e:false, c:true}`. The `c:true` spec attribute
    // is observable in the unhardened realm; SES `harden()` flips
    // it to `c:false` (matching @endo/ses post-`lockdown()`).
    try expectScriptStringUnhardened(
        \\const d = Object.getOwnPropertyDescriptor(Function.prototype, "length");
        \\d.value + ":" + d.writable + ":" + d.enumerable + ":" + d.configurable;
    , "0:false:false:true");
}

test "later: Function.prototype.name is '' with §17 flags" {
    // §20.2.3 + §10.2.9 SetFunctionName — `Function.prototype.name`
    // is `""` with `{w:false, e:false, c:true}`. Same SES freeze
    // caveat as the `length` test above.
    try expectScriptStringUnhardened(
        \\const d = Object.getOwnPropertyDescriptor(Function.prototype, "name");
        \\"<" + d.value + ">:" + d.writable + ":" + d.enumerable + ":" + d.configurable;
    , "<>:false:false:true");
}

test "later: Function.prototype property order: length before name" {
    try expectScriptStringWithBuiltins(
        \\const ns = Object.getOwnPropertyNames(Function.prototype);
        \\const li = ns.indexOf("length");
        \\const ni = ns.indexOf("name");
        \\(li >= 0 && ni === li + 1) ? "ok" : ("bad:" + li + "," + ni);
    , "ok");
}

// ── §20.2.3.6 Function.prototype[@@hasInstance] ────────────────────────────
//
// Per §20.2.3.6 the `[Symbol.hasInstance]` property on
// `Function.prototype` is a function that performs
// OrdinaryHasInstance(this, V). The descriptor itself is
// `{w:false, e:false, c:false}`. Its own `name` is
// "[Symbol.hasInstance]" and `length` is 1.

test "later: Function.prototype[@@hasInstance] is a function" {
    try expectScriptStringWithBuiltins(
        \\typeof Function.prototype[Symbol.hasInstance];
    , "function");
}

// §20.2.3 Properties of the Function Prototype Object — "the Function
// prototype object is itself a built-in function object that, when
// invoked, accepts any arguments and returns undefined." Cynic stores
// %Function.prototype% as a plain JSObject (the call dispatchers
// short-circuit on identity to return undefined), so any callable
// behaviour must round-trip through the engine's actual call paths.
// test262 fixtures: S15.3.3.1_A1.js, S15.3.4_A2_T1.js / T2.js / T3.js.

test "later: %Function.prototype% called with no args returns undefined" {
    try expectScriptStringWithBuiltins(
        \\typeof Function.prototype();
    , "undefined");
}

test "later: %Function.prototype% called with args returns undefined" {
    try expectScriptStringWithBuiltins(
        \\typeof Function.prototype(null, void 0, 42, "x");
    , "undefined");
}

test "later: %Function.prototype% call via .call still returns undefined" {
    // §20.2.3.3 Function.prototype.call routes the receiver as the
    // call's `this`; the receiver here IS %Function.prototype%, and
    // its [[Call]] returns undefined regardless of `this` or args.
    try expectScriptStringWithBuiltins(
        \\typeof Function.prototype.call({}, 1, 2);
    , "undefined");
}

test "later: %Function.prototype% typeof is 'function'" {
    // §13.5.3 typeof — the JSObject's proxy_callable flag flips
    // typeof from "object" to "function" so the call path's identity
    // check has the right precondition: typeof says callable, and a
    // call actually goes through.
    try expectScriptStringWithBuiltins(
        \\typeof Function.prototype;
    , "function");
}

test "later: Function.prototype[@@hasInstance] descriptor non-writable, non-configurable" {
    // §20.2.3.6 — the `[Symbol.hasInstance]` property is a DATA
    // descriptor with `{w:false, e:false, c:false}`. In hardened
    // mode the SES override-mistake fix replaces it with a
    // synthetic accessor pair, so `Object.getOwnPropertyDescriptor`
    // returns an accessor descriptor (no `writable` slot). The
    // unhardened realm exposes the spec-data shape directly.
    try expectScriptStringUnhardened(
        \\const d = Object.getOwnPropertyDescriptor(Function.prototype, Symbol.hasInstance);
        \\d.writable + ":" + d.enumerable + ":" + d.configurable;
    , "false:false:false");
}

test "later: Function.prototype[@@hasInstance] name and length" {
    try expectScriptStringWithBuiltins(
        \\const m = Function.prototype[Symbol.hasInstance];
        \\m.name + ":" + m.length;
    , "[Symbol.hasInstance]:1");
}

test "later: Function.prototype[@@hasInstance] returns true for matching prototype" {
    try expectScriptStringWithBuiltins(
        \\function F() {}
        \\const o = new F();
        \\F[Symbol.hasInstance](o) ? "y" : "n";
    , "y");
}

test "later: Function.prototype[@@hasInstance] returns false for non-object" {
    try expectScriptStringWithBuiltins(
        \\function F() {}
        \\const a = F[Symbol.hasInstance](42) ? "y" : "n";
        \\const b = F[Symbol.hasInstance](null) ? "y" : "n";
        \\const c = F[Symbol.hasInstance](undefined) ? "y" : "n";
        \\a + b + c;
    , "nnn");
}

test "later: Function.prototype[@@hasInstance] non-callable this returns false" {
    try expectScriptStringWithBuiltins(
        \\Function.prototype[Symbol.hasInstance].call({}) ? "y" : "n";
    , "n");
}

// ── §10.4.1.3 BoundFunctionCreate — name & length ──────────────────────────
//
// Per §20.2.3.2 Function.prototype.bind:
//   • SetFunctionName(F, targetName, "bound") — name becomes
//     "bound " + targetName.
//   • SetFunctionLength(F, max(0, target.length - args.length)).
// Both with §17 flags `{w:false, e:false, c:true}`.

test "later: bind sets name to 'bound ' + target name" {
    try expectScriptStringWithBuiltins(
        \\function foo() {}
        \\foo.bind().name;
    , "bound foo");
}

test "later: bind chained sets name to 'bound bound ' + target name" {
    try expectScriptStringWithBuiltins(
        \\function foo() {}
        \\foo.bind().bind().name;
    , "bound bound foo");
}

test "later: bind sets length to max(0, target.length - bound.length)" {
    try expectScriptStringWithBuiltins(
        \\function bar(x, y) {}
        \\"" + bar.bind(null).length + "," + bar.bind(null, 1).length + "," + bar.bind(null, 1, 2).length + "," + bar.bind(null, 1, 2, 3).length;
    , "2,1,0,0");
}

test "later: bind name is non-enumerable, non-writable, configurable" {
    try expectScriptStringWithBuiltins(
        \\function foo() {}
        \\const d = Object.getOwnPropertyDescriptor(foo.bind(), "name");
        \\d.writable + ":" + d.enumerable + ":" + d.configurable;
    , "false:false:true");
}

test "later: bind on target with non-string name yields 'bound '" {
    try expectScriptStringWithBuiltins(
        \\const f = function() {};
        \\Object.defineProperty(f, "name", { value: 42, configurable: true });
        \\"<" + f.bind().name + ">";
    , "<bound >");
}

// §27.5.4 / §7.4.2 — `Iterator.zip` snapshots each input
// iterator's `next` once at construction (GetIteratorDirect step 1).
// Subsequent steps dispatch through the cached snapshot, so a
// `get next()` accessor on an underlying iterator must fire
// exactly once per input — never on per-step iteration.
test "later: Iterator.zip snapshots each input.next once" {
    try expectScriptStringWithBuiltins(
        \\let aGets = 0, bGets = 0;
        \\const a = { get next() { ++aGets; let i = 0; return function () { return i < 3 ? { value: i++, done: false } : { value: undefined, done: true }; }; } };
        \\const b = { get next() { ++bGets; let i = 10; return function () { return i < 13 ? { value: i++, done: false } : { value: undefined, done: true }; }; } };
        \\const z = Iterator.zip([a, b]);
        \\z.next(); z.next(); z.next(); z.next();
        \\aGets + ":" + bGets;
    , "1:1");
}

// §27.5.4 step 14d.iii (strict) + §7.4.13 IteratorCloseAll —
// when one input is exhausted before the others in `mode: "strict"`,
// every still-open iter is closed in REVERSE order via `return()`,
// then a TypeError is thrown.
test "later: Iterator.zip(strict) closes other iters in reverse on mismatch" {
    try expectScriptStringWithBuiltins(
        \\const log = [];
        \\const mk = (name, n, isShort) => ({
        \\  next() {
        \\    log.push(name + "_next");
        \\    return isShort ? { done: true } : { value: 0, done: false };
        \\  },
        \\  return() { log.push(name + "_ret"); return {}; },
        \\});
        \\let threw = false;
        \\try { Iterator.zip([mk("A", 1, false), mk("B", 1, true), mk("C", 1, false)], { mode: "strict" }).next(); }
        \\catch (e) { threw = (e instanceof TypeError); }
        \\threw + ":" + log.join(",");
    , "true:A_next,B_next,C_ret,A_ret");
}

// ── §10.4.2 — Array exotic packed elements ──────────────────────────────────

test "later: Array(N) with N writes leaves length at N" {
    try expectScriptIntWithBuiltins(
        \\var x = Array(100);
        \\x[0] = 1;
        \\x[50] = 2;
        \\x.length;
    , 100);
}

test "later: arr.length = N truncates elements past N" {
    try expectScriptStringWithBuiltins(
        \\var a = [1, 2, 3, 4, 5];
        \\a.length = 2;
        \\a.length + ":" + a.join(",");
    , "2:1,2");
}

test "later: holes fall through to prototype-chain accessors" {
    // §10.4.2.1 step 2 — sparse holes are NOT own properties;
    // reads delegate to the prototype chain, where Array.prototype's
    // accessor at "1" fires. Needs unhardened mode to install
    // the accessor on Array.prototype (hardened freezes it).
    try expectScriptStringUnhardened(
        \\var got;
        \\Object.defineProperty(Array.prototype, "1", {
        \\  get: function() { return 42; },
        \\  configurable: true,
        \\});
        \\try { got = String([0,,2][1]); } finally {
        \\  delete Array.prototype[1];
        \\}
        \\got;
    , "42");
}

test "later: Array() spread does not allocate per-index strings" {
    // Smoke-only — exercises the array_spread fast path that
    // routes directly into the packed `elements` vector.
    try expectScriptIntWithBuiltins(
        \\function* g() { for (let i = 0; i < 100; i++) yield i; }
        \\const a = [...g()];
        \\a.length;
    , 100);
}

test "later: arr[3] = v auto-extends length on Array exotic" {
    try expectScriptIntWithBuiltins(
        \\var a = [];
        \\a[3] = "x";
        \\a.length;
    , 4);
}

test "later: delete arr[i] holes the slot but leaves length" {
    try expectScriptStringWithBuiltins(
        \\var a = [1, 2, 3];
        \\delete a[1];
        \\a.length + ":" + (1 in a ? "y" : "n") + ":" + a[1];
    , "3:n:undefined");
}

// ── §14.3.3.5 / §13.15.5.5 — Array destructuring uses iterator protocol ──

test "later: var [a, b] = generator binds the first two yields" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield "a"; yield "b"; yield "c"; }
        \\var [a, b] = g();
        \\a + ":" + b;
    , "a:b");
}

test "later: var [a, ...rest] = generator drains the rest" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 1; yield 2; yield 3; yield 4; }
        \\var [a, ...rest] = g();
        \\a + ":" + rest.join(",");
    , "1:2,3,4");
}

test "later: array destructuring closes the iter on partial bind" {
    // §7.4.10 — when more elements remain in the iter than slots
    // in the pattern, IteratorClose calls `.return()` once.
    try expectScriptIntWithBuiltins(
        \\var closed = 0;
        \\var iter = {
        \\  i: 0,
        \\  [Symbol.iterator]() { return this; },
        \\  next() { this.i++; return this.i > 5 ? {done:true} : {value: this.i, done:false}; },
        \\  return() { closed++; return {}; },
        \\};
        \\var [x, y] = iter;
        \\closed;
    , 1);
}

test "later: rest element drains iter; no IteratorClose call" {
    try expectScriptIntWithBuiltins(
        \\var closed = 0;
        \\var iter = {
        \\  i: 0,
        \\  [Symbol.iterator]() { return this; },
        \\  next() { this.i++; return this.i > 3 ? {done:true} : {value: this.i, done:false}; },
        \\  return() { closed++; return {}; },
        \\};
        \\var [a, ...rest] = iter;
        \\closed;
    , 0);
}

test "later: assignment destructuring through iterator protocol" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 10; yield 20; }
        \\var a, b;
        \\[a, b] = g();
        \\a + ":" + b;
    , "10:20");
}

test "later: array destructuring elision steps the iter" {
    // `[,,] = g` consumes 2 yields without binding them
    try expectScriptIntWithBuiltins(
        \\var count = 0;
        \\var g = function*() { count++; yield; count++; yield; count++; yield; };
        \\var src = g();
        \\[,,] = src;
        \\count;
    , 2);
}

// ── §15.7 — Private accessors + static private ──────────────────────────────

test "later: private getter dispatches as accessor" {
    try expectScriptIntWithBuiltins(
        \\class C { get #x() { return 42; } getX() { return this.#x; } }
        \\new C().getX();
    , 42);
}

test "later: private setter dispatches as accessor" {
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  #buf = 0;
        \\  set #x(v) { this.#buf = v * 10; }
        \\  setX(v) { this.#x = v; return this.#buf; }
        \\}
        \\new C().setX(7);
    , 70);
}

test "later: read of write-only private accessor throws TypeError" {
    // §10.1.8.1 PrivateFieldGet step 6.b — accessor without [[Get]]
    // throws TypeError.
    try expectScriptStringWithBuiltins(
        \\class C { set #x(v) {} readX() { return this.#x; } }
        \\let kind = "none";
        \\try { new C().readX(); } catch (e) { kind = e instanceof TypeError ? "type" : "other"; }
        \\kind;
    , "type");
}

test "later: assigning to a private method throws TypeError" {
    // §7.3.30 PrivateSet step 4 — methods aren't writable.
    try expectScriptStringWithBuiltins(
        \\class C { #m() {} assign() { this.#m = 0; } }
        \\let kind = "none";
        \\try { new C().assign(); } catch (e) { kind = e instanceof TypeError ? "type" : "other"; }
        \\kind;
    , "type");
}

// ── §15.7.1 ClassDefinitionEvaluation — inner C binding ────────────────────

test "later: methods see the inner immutable C even after outer C is reassigned" {
    try expectScriptStringWithBuiltins(
        \\class C { method() { return C; } }
        \\let cls = C;
        \\C = null;
        \\let result = cls.prototype.method();
        \\result === cls ? "inner" : "leaked";
    , "inner");
}

test "later: class with heritage — methods still see the inner C" {
    try expectScriptStringWithBuiltins(
        \\class P {}
        \\class C extends P { method() { return C; } }
        \\let cls = C;
        \\C = null;
        \\cls.prototype.method() === cls ? "inner" : "leaked";
    , "inner");
}

test "later: class expression's named inner binding visible to methods" {
    try expectScriptStringWithBuiltins(
        \\let cls = class C { method() { return C; } };
        \\cls.prototype.method() === cls ? "inner" : "leaked";
    , "inner");
}

test "later: abrupt static-field initializer halts class definition" {
    // §15.7.14 step 34 / DefineField — a thrown initializer
    // aborts ClassDefinitionEvaluation, so later static fields
    // must not run.
    try expectScriptStringWithBuiltins(
        \\let ran_b = false;
        \\let kind = "none";
        \\try {
        \\  class C {
        \\    static a = (() => { throw new TypeError("boom"); })();
        \\    static b = (ran_b = true);
        \\  }
        \\} catch (e) { kind = (e instanceof TypeError && !ran_b) ? "ok" : "leak"; }
        \\kind;
    , "ok");
}

test "later: assigning to a static private method throws TypeError" {
    try expectScriptStringWithBuiltins(
        \\class C { static #m() {} static assign() { this.#m = 0; } }
        \\let kind = "none";
        \\try { C.assign(); } catch (e) { kind = e instanceof TypeError ? "type" : "other"; }
        \\kind;
    , "type");
}

test "later: read of static write-only private accessor throws TypeError" {
    // §10.1.8.1 PrivateFieldGet step 6.b — static accessor path.
    try expectScriptStringWithBuiltins(
        \\class C { static set #x(v) {} static readX() { return this.#x; } }
        \\let kind = "none";
        \\try { C.readX(); } catch (e) { kind = e instanceof TypeError ? "type" : "other"; }
        \\kind;
    , "type");
}

test "later: static private field reads back via this.#x" {
    try expectScriptIntWithBuiltins(
        \\class C { static #x = 42; static getX() { return this.#x; } }
        \\C.getX();
    , 42);
}

test "later: static private accessor + method round-trip" {
    try expectScriptStringWithBuiltins(
        \\class C {
        \\  static #v = 1;
        \\  static get #x() { return this.#v * 2; }
        \\  static set #x(n) { this.#v = n; }
        \\  static #m() { return "m"; }
        \\  static api() { var a = this.#x; this.#x = 50; return a + ":" + this.#x + ":" + this.#m(); }
        \\}
        \\C.api();
    , "2:100:m");
}

test "later: static private brand check throws on cross-instance" {
    try expectScriptStringWithBuiltins(
        \\class A { static #x = 1; static peek(o) { return o.#x; } }
        \\class B {}
        \\try { A.peek(B); "no throw"; } catch (e) { e.constructor.name; }
    , "TypeError");
}

// ── §14.7.5 / §27.1.4.3 — for-await-of ──────────────────────────────────────

test "later: for-await-of drives an async generator" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\async function* g() { yield "a"; yield "b"; yield "c"; }
        \\async function run() {
        \\  for await (const v of g()) log += v;
        \\  return log;
        \\}
        \\let out;
        \\run().then(r => out = r);
        \\__drainMicrotasks();
        \\out;
    , "abc");
}

test "later: for-await-of over a sync iterable still works (await unwraps non-Promises)" {
    try expectScriptStringWithBuiltins(
        \\async function run() {
        \\  let s = "";
        \\  for await (const v of [10, 20, 30]) s += v + ",";
        \\  return s;
        \\}
        \\let out;
        \\run().then(r => out = r);
        \\__drainMicrotasks();
        \\out;
    , "10,20,30,");
}

test "later: for-await-of unwraps Promise-of-value yields" {
    try expectScriptStringWithBuiltins(
        \\async function* g() { yield Promise.resolve("x"); yield "y"; yield Promise.resolve("z"); }
        \\async function run() {
        \\  let s = "";
        \\  for await (const v of g()) s += v;
        \\  return s;
        \\}
        \\let out;
        \\run().then(r => out = r);
        \\__drainMicrotasks();
        \\out;
    , "xyz");
}

// ── §27.6.3.4 / §27.6.3.5 — AsyncGeneratorQueue ordering ────────────────────

// Three back-to-back `.next()` calls before any microtask drain must settle
// their capability promises in spec order: the first call's promise reaches
// its `.then` callback first, second next, third last. The fixture mirrors
// the test262 `built-ins/AsyncGeneratorPrototype/next/request-queue-order.js`
// pattern (registered `.then`s read against an `order` counter).
test "asyncgen: three .next() calls settle in spec order" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\async function* g() { yield "a"; yield "b"; }
        \\let iter = g();
        \\let item1 = iter.next();
        \\let item2 = iter.next();
        \\let item3 = iter.next();
        \\item3.then(r => log += "3:" + r.value + ":" + r.done + ";");
        \\item2.then(r => log += "2:" + r.value + ":" + r.done + ";");
        \\item1.then(r => log += "1:" + r.value + ":" + r.done + ";");
        \\__drainMicrotasks();
        \\log;
    , "1:a:false;2:b:false;3:undefined:true;");
}

// ── §13.3.7 — super.x = v, super(...spread), super in static methods ───────

test "later: super.method() chain works" {
    try expectScriptStringWithBuiltins(
        \\class A { foo() { return "A.foo"; } }
        \\class B extends A { foo() { return "B." + super.foo(); } }
        \\new B().foo();
    , "B.A.foo");
}

test "later: super.x = v invokes parent setter" {
    try expectScriptIntWithBuiltins(
        \\class P { set p(v) { this._p = v * 2; } }
        \\class C extends P { setIt(v) { super.p = v; return this._p; } }
        \\new C().setIt(7);
    , 14);
}

test "later: super(...spread) forwards arguments" {
    try expectScriptStringWithBuiltins(
        \\class A { constructor(...args) { this.args = args; } }
        \\class B extends A { constructor() { super(...[1, 2, 3]); } }
        \\new B().args.join(",");
    , "1,2,3");
}

test "later: super.method() in static method walks ctor.[[Prototype]]" {
    try expectScriptStringWithBuiltins(
        \\class I { static greet() { return "I"; } }
        \\class J extends I { static who() { return "J/" + super.greet(); } }
        \\J.who();
    , "J/I");
}

test "later: super.x in static reads parent's static accessor" {
    try expectScriptIntWithBuiltins(
        \\class A { static get p() { return 42; } }
        \\class B extends A { static getIt() { return super.p; } }
        \\B.getIt();
    , 42);
}

test "later: super.x = v in static invokes parent's static setter" {
    try expectScriptIntWithBuiltins(
        \\class A { static set p(v) { A._p = v; } static get p() { return A._p; } }
        \\class B extends A { static setIt(v) { super.p = v; return super.p; } }
        \\B.setIt(99);
    , 99);
}

// ── §13.15.5 — Numeric-key object destructuring ─────────────────────────────

test "later: destructuring {0: a, 1: b} pulls indexed slots" {
    try expectScriptStringWithBuiltins(
        \\var {0: a, 1: b} = ["x", "y", "z"];
        \\a + ":" + b;
    , "x:y");
}

test "later: rest with numeric-key object pattern" {
    try expectScriptStringWithBuiltins(
        \\function f([...{0: v, 1: w, length: z}]) { return v + ":" + w + ":" + z; }
        \\f([7, 8, 9]);
    , "7:8:3");
}

// ── §13.15.5 / §14.3.3 — Computed-key object destructuring ───────────────────

test "later: computed-key in object destructuring binds the value" {
    try expectScriptStringWithBuiltins(
        \\let k = "foo";
        \\let { [k]: v } = { foo: "bar" };
        \\v;
    , "bar");
}

test "later: computed-key dstr evaluates the key expression" {
    try expectScriptInt(
        \\let calls = 0;
        \\function k() { calls = calls + 1; return "x"; }
        \\let { [k()]: v } = { x: 42 };
        \\v + calls * 1000;
    , 1042);
}

test "later: computed-key dstr — thrown key propagates" {
    try expectScriptStringWithBuiltins(
        \\function thrower() { throw "k-boom"; }
        \\let captured = "no";
        \\try { let { [thrower()]: x } = {}; }
        \\catch (e) { captured = e; }
        \\captured;
    , "k-boom");
}

test "later: computed-key dstr in assignment pattern" {
    try expectScriptStringWithBuiltins(
        \\let k = "a";
        \\let v;
        \\({ [k]: v } = { a: "hi" });
        \\v;
    , "hi");
}

// ── §27.5.1.3 — Generator.prototype.return drives pending finallys ─────────

test "later: gen.return runs pending finally before completing" {
    try expectScriptStringWithBuiltins(
        \\let log = "";
        \\function* g() {
        \\  try {
        \\    yield 1;
        \\    log += "no";
        \\  } finally {
        \\    log += "fin";
        \\  }
        \\}
        \\let it = g();
        \\it.next();          // suspended inside try
        \\let r = it.return("done");
        \\log + ":" + r.value + ":" + r.done;
    , "fin:done:true");
}

test "later: for-of break calls gen.return which runs finally" {
    try expectScriptIntWithBuiltins(
        \\let finallyCount = 0;
        \\function* values() {
        \\  try { yield 1; } finally { finallyCount += 1; }
        \\}
        \\(function() {
        \\  for (var x of values()) { break; }
        \\})();
        \\finallyCount;
    , 1);
}

test "later: for-of return calls gen.return which runs finally" {
    try expectScriptIntWithBuiltins(
        \\let finallyCount = 0;
        \\function* values() {
        \\  try { yield 1; } finally { finallyCount += 1; }
        \\}
        \\(function() {
        \\  for (var x of values()) { return; }
        \\})();
        \\finallyCount;
    , 1);
}

// ── §14.4.14 / §27.6.3.7 — yield* delegation ───────────────────────────────

test "later: sync yield* delegates to a generator" {
    try expectScriptStringWithBuiltins(
        \\function* a() { yield 1; yield 2; }
        \\function* b() { yield 0; yield* a(); yield 3; }
        \\var out = [];
        \\for (var v of b()) out.push(v);
        \\out.join(",");
    , "0,1,2,3");
}

test "later: sync yield* of an array iterable" {
    try expectScriptStringWithBuiltins(
        \\function* g() { yield 0; yield* [10, 20]; yield 30; }
        \\var out = [];
        \\for (var v of g()) out.push(v);
        \\out.join(",");
    , "0,10,20,30");
}

test "later: async yield* delegates to an async generator" {
    try expectScriptStringWithBuiltins(
        \\async function* a() { yield 1; yield 2; }
        \\async function* b() { yield 0; yield* a(); yield 3; }
        \\async function run() { var out = []; for await (var v of b()) out.push(v); return out.join(","); }
        \\var got;
        \\run().then(r => got = r);
        \\__drainMicrotasks();
        \\got;
    , "0,1,2,3");
}

test "globalThis: late-installed host binding is visible via globalThis.X" {
    // §19.3 — `realm.globals` is a live view over the globalThis
    // object. A host-installed binding pushed AFTER `installBuiltins`
    // returns must show up via `globalThis.X` without a snapshot
    // catch-up. This pins the test262 `$DONE` / `$262` pattern.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    // Install a fresh global after intrinsics setup.
    const name_v = try realm.heap.allocateString("LATE_HOST_BINDING");
    _ = name_v;
    try realm.globals.put(realm.allocator, "LATE_HOST_BINDING", @import("../value.zig").Value.fromInt32(42));
    // Read it back via `globalThis.LATE_HOST_BINDING` — the
    // snapshot-era implementation returned `undefined` here.
    const v = switch (try evaluateScriptResult(&realm, "globalThis.LATE_HOST_BINDING")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 42), v.asInt32());
}

test "globalThis: bare-identifier read sees a late-installed host binding" {
    // Sibling to the test above — the bare-identifier
    // (`lda_global`) path resolves against `realm.globals`, which
    // is the same storage as `gt.properties`. A regression that
    // forks the two would surface here too.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    try realm.globals.put(realm.allocator, "LATE_BARE_BINDING", @import("../value.zig").Value.fromInt32(7));
    const v = switch (try evaluateScriptResult(&realm, "LATE_BARE_BINDING + 1")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 8), v.asInt32());
}

// ── §22.1.5 String.prototype.length — code-unit counts ─────────────────────

test "String.prototype.length: ASCII matches char count" {
    try expectScriptIntWithBuiltins("\"abc\".length;", 3);
}

test "String.prototype.length: BMP non-ASCII counts as one code unit" {
    // §22.1.5.1 — `\xFF` is U+00FF, a single BMP code unit
    // (encoded as 2 WTF-8 bytes). Byte-length would have returned 2.
    try expectScriptIntWithBuiltins("\"a\\xFFc\".length;", 3);
}

test "String.prototype.length: supplementary counts as two code units" {
    // U+1F600 is a supplementary code point that occupies one
    // 4-byte UTF-8 sequence but exposes two UTF-16 code units
    // (high+low surrogate pair). Byte-length would have returned 6.
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".length;", 4);
}

test "String.prototype.length: lone surrogate counts as one code unit" {
    // \uD83D is a lone high surrogate; it's its own single code
    // unit even though the WTF-8 encoding takes 3 bytes.
    try expectScriptIntWithBuiltins("\"a\\uD83Dc\".length;", 3);
}

test "String.prototype.length: indexed access by code unit (BMP)" {
    try expectScriptStringWithBuiltins("\"a\\xFFc\"[1];", "\xC3\xBF");
}

test "String.prototype.length: indexed access splits surrogate pair" {
    // `s[1]` and `s[2]` of "a\u{1F600}c" yield the high and low
    // surrogate halves of the pair (each encoded as a 3-byte
    // WTF-8 escape).
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\"[1];", "\xED\xA0\xBD");
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\"[2];", "\xED\xB8\x80");
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\"[3];", "c");
}

// ── §22.1.3.1 charAt / §22.1.3.2 charCodeAt / §22.1.3.0 at ─────────────────

test "String.prototype.charAt: ASCII index" {
    try expectScriptStringWithBuiltins("\"abc\".charAt(1);", "b");
}

test "String.prototype.charAt: BMP non-ASCII at non-byte index" {
    // `\xFF` is 2 WTF-8 bytes; old byte-index code returned
    // garbage. charAt(1) is the U+00FF code unit.
    try expectScriptStringWithBuiltins("\"a\\xFFc\".charAt(1);", "\xC3\xBF");
    try expectScriptStringWithBuiltins("\"a\\xFFc\".charAt(2);", "c");
}

test "String.prototype.charAt: surrogate halves at supplementary" {
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".charAt(1);", "\xED\xA0\xBD");
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".charAt(2);", "\xED\xB8\x80");
}

test "String.prototype.charAt: out of range returns empty string" {
    try expectScriptStringWithBuiltins("\"abc\".charAt(99);", "");
    try expectScriptStringWithBuiltins("\"abc\".charAt(-1);", "");
}

test "String.prototype.charCodeAt: ASCII" {
    try expectScriptIntWithBuiltins("\"abc\".charCodeAt(1);", 'b');
}

test "String.prototype.charCodeAt: BMP non-ASCII returns 0xFF" {
    try expectScriptIntWithBuiltins("\"a\\xFFc\".charCodeAt(1);", 0xFF);
}

test "String.prototype.charCodeAt: surrogate halves at supplementary" {
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".charCodeAt(1);", 0xD83D);
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".charCodeAt(2);", 0xDE00);
}

test "String.prototype.charCodeAt: lone surrogate round-trip" {
    try expectScriptIntWithBuiltins("\"a\\uD83Dc\".charCodeAt(1);", 0xD83D);
}

test "String.prototype.at: negative wraps from end (supplementary)" {
    // `at(-1)` is the last code unit which for "a\u{1F600}c" is
    // the literal `c`.
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".at(-1);", "c");
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".at(-2);", "\xED\xB8\x80");
}

test "String.prototype.at: out of range returns undefined" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"abc\".at(99);")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isUndefined());
}

// ── §22.1.3.20 slice / §22.1.3.24 substring — code-unit ranges ─────────────

test "String.prototype.slice: ASCII range" {
    try expectScriptStringWithBuiltins("\"abcdef\".slice(1, 4);", "bcd");
}

test "String.prototype.slice: BMP non-ASCII range" {
    // "a\xFFc" — slice(0,2) yields "a\xFF" (2 code units, 3 bytes).
    try expectScriptStringWithBuiltins("\"a\\xFFc\".slice(0, 2);", "a\xC3\xBF");
}

test "String.prototype.slice: supplementary fully-included" {
    // slice(0,4) of "a\u{1F600}c" returns the whole string.
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".slice(0, 4);", "a\xF0\x9F\x98\x80c");
}

test "String.prototype.slice: end mid-surrogate emits lead surrogate" {
    // slice(0,2) ends at the trail half — the included unit is
    // the lone lead surrogate (3-byte CESU-8 escape).
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".slice(0, 2);", "a\xED\xA0\xBD");
}

test "String.prototype.slice: start mid-surrogate emits trail surrogate" {
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".slice(2, 4);", "\xED\xB8\x80c");
}

test "String.prototype.slice: negative wraps from end" {
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".slice(-1);", "c");
}

test "String.prototype.substring: ASCII range" {
    try expectScriptStringWithBuiltins("\"abcdef\".substring(2, 5);", "cde");
}

test "String.prototype.substring: negative clamps to 0" {
    try expectScriptStringWithBuiltins("\"abc\".substring(-5, 2);", "ab");
}

test "String.prototype.substring: out of order swaps" {
    try expectScriptStringWithBuiltins("\"abcdef\".substring(4, 1);", "bcd");
}

test "String.prototype.substring: supplementary mid-pair end" {
    try expectScriptStringWithBuiltins("\"a\\u{1F600}c\".substring(0, 2);", "a\xED\xA0\xBD");
}

// ── §22.1.3.8 indexOf / §22.1.3.9 lastIndexOf — code-unit indices ─────────

test "String.prototype.indexOf: ASCII" {
    try expectScriptIntWithBuiltins("\"abcabc\".indexOf(\"b\");", 1);
    try expectScriptIntWithBuiltins("\"abcabc\".indexOf(\"b\", 2);", 4);
    try expectScriptIntWithBuiltins("\"abc\".indexOf(\"x\");", -1);
}

test "String.prototype.indexOf: needle after BMP non-ASCII reports code-unit index" {
    // "a\xFFcb" — code units (a, \xFF, c, b); byte offsets
    // (0, 1, 3, 4). indexOf("b") must return 3 (code units), not
    // 4 (the byte offset).
    try expectScriptIntWithBuiltins("\"a\\xFFcb\".indexOf(\"b\");", 3);
}

test "String.prototype.indexOf: needle after supplementary code point" {
    // "a\u{1F600}c" — code units (a, lead, trail, c); indexOf("c")
    // = 3 (code units), not 5 (the byte offset post-4-byte UTF-8).
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".indexOf(\"c\");", 3);
}

test "String.prototype.indexOf: position is code-unit indexed" {
    // Same string; position=2 means start at the trail surrogate
    // (which is at byte offset 1). "c" is at code-unit index 3,
    // so a code-unit-aware search returns 3.
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".indexOf(\"c\", 2);", 3);
}

test "String.prototype.indexOf: empty needle returns clamped position" {
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".indexOf(\"\", 2);", 2);
}

test "String.prototype.lastIndexOf: ASCII" {
    try expectScriptIntWithBuiltins("\"abcabc\".lastIndexOf(\"b\");", 4);
}

test "String.prototype.lastIndexOf: code-unit index after supplementary" {
    try expectScriptIntWithBuiltins("\"a\\u{1F600}c\".lastIndexOf(\"c\");", 3);
}

test "String.prototype.lastIndexOf: lone surrogate haystack" {
    // "a\uD83Dc" — the lone surrogate is one code unit, c is at
    // code-unit index 2.
    try expectScriptIntWithBuiltins("\"a\\uD83Dc\".lastIndexOf(\"c\");", 2);
}

// ── §22.1.3.7 includes / §22.1.3.21 startsWith / §22.1.3.6 endsWith ────────

test "String.prototype.startsWith: ASCII" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"abc\".startsWith(\"ab\");")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isBool() and v.asBool());
}

test "String.prototype.startsWith: position is code-unit indexed (supplementary)" {
    // "a\u{1F600}c".startsWith("c", 3) — code-unit index 3 is
    // the byte offset 5 (post-4-byte UTF-8). A byte-counting
    // implementation that converted 3 → byte 3 would land
    // mid-supplementary and return false.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"a\\u{1F600}c\".startsWith(\"c\", 3);")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isBool() and v.asBool());
}

test "String.prototype.endsWith: ASCII" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"abc\".endsWith(\"bc\");")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isBool() and v.asBool());
}

test "String.prototype.endsWith: endPosition is code-unit indexed" {
    // "a\u{1F600}c".endsWith("\u{1F600}", 3) — the substring of
    // length 2 ending at unit 3 is exactly the supplementary pair.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"a\\u{1F600}c\".endsWith(\"\\u{1F600}\", 3);")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isBool() and v.asBool());
}

// ── §22.1.3.14 padStart / §22.1.3.13 padEnd — code-unit padding ───────────

test "String.prototype.padStart: ASCII" {
    try expectScriptStringWithBuiltins("\"abc\".padStart(5, \"-\");", "--abc");
}

test "String.prototype.padStart: maxLength counted in code units" {
    // "a\xFF" — 2 code units, 3 bytes. padStart(4, "-") should
    // add 2 dashes, not 1.
    try expectScriptStringWithBuiltins("\"a\\xFF\".padStart(4, \"-\");", "--a\xC3\xBF");
}

test "String.prototype.padStart: supplementary receiver counts as two code units" {
    // "\u{1F600}" — 2 code units, 4 bytes. padStart(4, "-") adds 2.
    try expectScriptStringWithBuiltins("\"\\u{1F600}\".padStart(4, \"-\");", "--\xF0\x9F\x98\x80");
}

test "String.prototype.padStart: fill truncated by code units" {
    // fill = "\u{1F600}" (2 cu); target=5, receiver=1 cu, pad=4 cu
    // → two full copies of the supplementary pair.
    try expectScriptStringWithBuiltins("\"x\".padStart(5, \"\\u{1F600}\");", "\xF0\x9F\x98\x80\xF0\x9F\x98\x80x");
}

test "String.prototype.padEnd: ASCII" {
    try expectScriptStringWithBuiltins("\"abc\".padEnd(5, \".\");", "abc..");
}

test "String.prototype.padEnd: maxLength counted in code units" {
    try expectScriptStringWithBuiltins("\"\\u{1F600}\".padEnd(4, \".\");", "\xF0\x9F\x98\x80..");
}

// ---------------------------------------------------------------------------
// §20.1.3.5 Object.prototype.toLocaleString
// §20.1.3.6 Object.prototype.toString
// ---------------------------------------------------------------------------

test "Object.prototype.toString: revoked Proxy throws TypeError" {
    // §20.1.3.6 step 4 + §7.2.2 IsArray — the IsArray walk on a
    // revoked proxy throws before the @@toStringTag step.
    try expectScriptThrowsWithBuiltins(
        \\const h = Proxy.revocable([], {});
        \\h.revoke();
        \\Object.prototype.toString.call(h.proxy);
    );
}

test "Object.prototype.toString: callable Proxy reports [object Function]" {
    // §10.5 ProxyCreate sets [[Call]] from a callable target;
    // toString's builtinTag is "Function".
    try expectScriptStringWithBuiltins(
        \\Object.prototype.toString.call(new Proxy(function() {}, {}));
    , "[object Function]");
}

test "Proxy [[Call]]: non-callable-target proxy throws on call (§10.5.12)" {
    // §10.5.1 ProxyCreate step 3 installs a [[Call]] internal method
    // only when IsCallable(target) is true. A proxy over a plain
    // object therefore has no [[Call]]: invoking it throws TypeError,
    // and the installed `apply` trap must NOT fire.
    try expectScriptThrowsWithBuiltins(
        \\const p = new Proxy({}, { apply() { return "called"; } });
        \\p();
    );
}

test "Proxy [[Call]]: non-callable-target proxy has typeof object" {
    // A non-callable proxy is not a function — §14 typeof reports
    // "object", confirming the absence of [[Call]].
    try expectScriptStringWithBuiltins(
        \\typeof new Proxy({}, { apply() {} });
    , "object");
}

test "Proxy [[Call]]: callable-target proxy still dispatches apply trap" {
    // The fix must not disturb the genuine callable path — a proxy
    // over a function keeps its [[Call]] and fires the apply trap.
    try expectScriptStringWithBuiltins(
        \\const p = new Proxy(function () {}, { apply() { return "ok"; } });
        \\p();
    , "ok");
}

test "Proxy [[Call]]: non-callable proxy rejected via Reflect.apply" {
    // Reflective callers route through the same callValue chokepoint.
    try expectScriptThrowsWithBuiltins(
        \\Reflect.apply(new Proxy({}, { apply() { return 1; } }), undefined, []);
    );
}

test "Proxy [[GetOwnProperty]]: trap can't report non-configurable target as configurable (§10.5.5)" {
    // §10.5.5 steps 16-18 IsCompatiblePropertyDescriptor — a
    // getOwnPropertyDescriptor trap that claims configurable:true for
    // a non-configurable target property is an invariant violation.
    try expectScriptThrowsWithBuiltins(
        \\const t = {};
        \\Object.defineProperty(t, "x", { value: 1, configurable: false, writable: true });
        \\const p = new Proxy(t, {
        \\  getOwnPropertyDescriptor() {
        \\    return { value: 1, configurable: true, writable: true, enumerable: true };
        \\  }
        \\});
        \\Object.getOwnPropertyDescriptor(p, "x");
    );
}

test "Proxy [[GetOwnProperty]]: compatible descriptor passes through" {
    // A configurable target property whose trap descriptor agrees is
    // returned unchanged — the new invariant check must not over-reject.
    try expectScriptStringWithBuiltins(
        \\const t = { x: 1 };
        \\const p = new Proxy(t, {
        \\  getOwnPropertyDescriptor(tt, k) { return Object.getOwnPropertyDescriptor(tt, k); }
        \\});
        \\String(Object.getOwnPropertyDescriptor(p, "x").value);
    , "1");
}

test "Object.prototype.toString: @@toStringTag getter throw propagates" {
    // §20.1.3.6 step 15 — Get(O, @@toStringTag) can throw.
    try expectScriptThrowsWithBuiltins(
        \\const o = Object.defineProperty({}, Symbol.toStringTag, {
        \\  get: function() { throw new Error("boom"); }
        \\});
        \\o.toString();
    );
}

test "Object.prototype.toString: @@toStringTag on Boolean.prototype overrides primitive" {
    // §20.1.3.6 step 15 — user tag string on Boolean.prototype
    // wins over the builtin "Boolean" tag. Needs unhardened
    // mode: hardened freezes Boolean.prototype so the assignment
    // would throw before we could probe the override.
    try expectScriptStringUnhardened(
        \\Boolean.prototype[Symbol.toStringTag] = 'test262';
        \\Object.prototype.toString.call(true);
    , "[object test262]");
}

test "Object.prototype.toLocaleString invokes the receiver's toString" {
    // §20.1.3.5 — `Return ? Invoke(O, "toString")`.
    try expectScriptStringWithBuiltins(
        \\({}).toLocaleString();
    , "[object Object]");
}

test "Object.prototype.toLocaleString: primitive 'this' reaches Boolean.prototype.toString" {
    // §20.1.3.5 GetV(true, "toString") finds the toString on
    // Boolean.prototype and invokes it with `true` as receiver.
    // Same SES caveat as the @@toStringTag test above —
    // hardened freezes Boolean.prototype.
    try expectScriptStringUnhardened(
        \\Boolean.prototype.toString = function() { return typeof this; };
        \\true.toLocaleString();
    , "boolean");
}

test "String.prototype.includes: position is code-unit indexed" {
    // "a\u{1F600}c".includes("c", 3) — should find c at code-unit
    // index 3. A byte-counting impl would translate pos=3 → byte=3,
    // which is mid-4-byte sequence; std.mem.indexOf would still
    // find c (by lucky offset) but the test for pos=4 catches the
    // off-by-one.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const v = switch (try evaluateScriptResult(&realm, "\"a\\u{1F600}c\".includes(\"c\", 3);")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isBool() and v.asBool());
    const v2 = switch (try evaluateScriptResult(&realm, "\"a\\u{1F600}c\".includes(\"c\", 4);")) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v2.isBool() and !v2.asBool());
}

// ─────────────────────────────────────────────────────────────────────
// call_method inline-cache correctness — regression coverage for the
// monomorphic call IC. The IC caches the last callee fn pointer at
// each call site and skips the proxy / callable / revocable / bound
// dispatch when it matches. These tests target the failure modes the
// cache introduces.
// ─────────────────────────────────────────────────────────────────────

test "call IC: hot monomorphic site produces correct cumulative result" {
    // Drives the same call site through 1000 iterations on a single
    // shape. The IC stays warm across every call; result asserts
    // the cached callee evaluates the same as a fresh slow-path
    // lookup would.
    try expectScriptIntWithBuiltins(
        \\const o = { n: 0, inc() { this.n++; return this.n; } };
        \\let acc = 0;
        \\for (let i = 0; i < 1000; i++) acc = o.inc();
        \\acc;
    , 1000);
}

test "call IC: reassigning the method invalidates a stale cached callee" {
    // The IC's hit condition is `valueAsFunction(callee_v) ==
    // cell.callee`, so reassigning the method swaps callee_v's
    // function pointer and the next call must miss → refill →
    // dispatch the new function. Without that, the cached pointer
    // would shadow the live property.
    try expectScriptIntWithBuiltins(
        \\const o = { f: () => 1 };
        \\let a = o.f();
        \\o.f = () => 100;
        \\let b = o.f();
        \\a + b;
    , 101);
}

test "call IC: same call site, two receivers of the same shape" {
    // Two object literals built from the same property list share
    // a shape through the transition tree. The call site sees both
    // — IC must hit on both (returning the per-receiver `n`),
    // never serving the wrong receiver's slot.
    try expectScriptIntWithBuiltins(
        \\const a = { n: 7, get() { return this.n; } };
        \\const b = { n: 35, get() { return this.n; } };
        \\let acc = 0;
        \\for (let i = 0; i < 50; i++) { acc += a.get(); acc += b.get(); }
        \\acc;
    , (7 + 35) * 50);
}

test "call IC: polymorphic site degrades safely on shape change" {
    // First object has shape A (one property). Second has shape B
    // (different property layout). Same call site sees both —
    // first warms cache with A, then call on B misses + refills,
    // then back to A misses + refills. Each call still returns
    // the right callee's value.
    try expectScriptIntWithBuiltins(
        \\const a = { tag: 1, get() { return this.tag; } };
        \\const b = { tag: 10, extra: 99, get() { return this.tag; } };
        \\let acc = 0;
        \\for (let i = 0; i < 30; i++) {
        \\  const recv = (i % 2) === 0 ? a : b;
        \\  acc += recv.get();
        \\}
        \\acc;
    , 15 * 1 + 15 * 10);
}

test "call IC: bound function on the call site stays correct" {
    // Bound functions live on the slow path — the IC refills only
    // on plain functions. A bound callee must NOT cache; the next
    // call (still bound) must run the bound dispatch correctly.
    try expectScriptIntWithBuiltins(
        \\function plain() { return this.n + 1; }
        \\const ctx = { n: 41 };
        \\const o = { f: plain.bind(ctx) };
        \\let acc = 0;
        \\for (let i = 0; i < 5; i++) acc += o.f();
        \\acc;
    , 42 * 5);
}

test "call IC: cell survives a forced GC mid-loop" {
    // gc-stress: trigger a collection mid-loop and confirm the
    // cached callee still dispatches correctly afterwards. Without
    // the GC weak-clear handling, a swept-and-reused fn address
    // could match a stale cell.callee and execute the wrong body.
    try expectScriptIntWithBuiltins(
        \\const o = { n: 0, inc() { this.n++; return this.n; } };
        \\let acc = 0;
        \\for (let i = 0; i < 200; i++) {
        \\  // Allocate garbage every other iteration so the GC
        \\  // threshold trips somewhere inside the loop. The
        \\  // `inc` callee survives via the realm's `o` root, so
        \\  // a correct weak-clear leaves the IC cell intact.
        \\  if ((i & 1) === 0) { const _ = [1, 2, 3, 4, 5]; }
        \\  acc = o.inc();
        \\}
        \\acc;
    , 200);
}

test "call IC: nested call sites — IC per site, no cross-talk" {
    // Two distinct call sites in the same function. Each must
    // have its own IC slot — caching `outer.outerCall` at site A
    // must not cause site B to dispatch the wrong inner callee.
    try expectScriptIntWithBuiltins(
        \\const inner = { x: 3, getX() { return this.x; } };
        \\const outer = {
        \\  y: 11,
        \\  combine() { return this.y + inner.getX(); },
        \\};
        \\let acc = 0;
        \\for (let i = 0; i < 20; i++) acc += outer.combine();
        \\acc;
    , (11 + 3) * 20);
}

test "call IC: callable Proxy as method stays on slow path" {
    // A callable Proxy on the callee value triggers the proxy
    // dispatch branch in call_method's slow path. The IC must not
    // skip past it (which would bypass the apply trap entirely).
    try expectScriptIntWithBuiltins(
        \\const target = function() { return 7; };
        \\const handler = { apply(t, thisArg, args) { return 42; } };
        \\const proxied = new Proxy(target, handler);
        \\const o = { f: proxied };
        \\let acc = 0;
        \\for (let i = 0; i < 3; i++) acc += o.f();
        \\acc;
    , 42 * 3);
}

// ─────────────────────────────────────────────────────────────────────
// Prototype-load IC correctness — coverage for `lda_property` when
// the property is inherited from the prototype chain (the dominant
// real-world case: built-in methods, class instance methods, user
// hierarchies). The IC must catch invalidation when:
//   1. `Object.setPrototypeOf` swaps the chain
//   2. `Reflect.setPrototypeOf` swaps the chain
//   3. A prototype's property is reassigned (same shape, new slot value)
//   4. A prototype's property is deleted (shape change on the proto)
//   5. A prototype's property is redefined data→accessor (shape change)
//   6. The chain has depth > 1
// ─────────────────────────────────────────────────────────────────────

test "proto-load IC: built-in Array.prototype.push hot loop" {
    // Array.prototype.push is the canonical inherited method. Slow
    // path walks Array.prototype every call today; with a working
    // proto-load IC, the cell hits on the chain shape after the
    // first miss + refill. Result asserts cumulative correctness.
    try expectScriptIntWithBuiltins(
        \\const a = [];
        \\for (let i = 1; i <= 100; i++) a.push(i);
        \\a.length;
    , 100);
}

test "proto-load IC: class instance method on hot loop" {
    // Class methods land on `C.prototype.m`, so every `c.m()` is a
    // prototype-load. Without the proto IC, the slow path walks
    // C.prototype every call.
    try expectScriptIntWithBuiltins(
        \\class C { add(x) { return x + 1; } }
        \\const c = new C();
        \\let acc = 0;
        \\for (let i = 0; i < 100; i++) acc = c.add(acc);
        \\acc;
    , 100);
}

test "proto-load IC: setPrototypeOf invalidates the cached proto" {
    // First call caches `obj.greeting` from proto1. After
    // Object.setPrototypeOf swaps to proto2 (different greeting),
    // the next read MUST observe proto2's value — not the cached
    // proto1 slot.
    try expectScriptStringWithBuiltins(
        \\const proto1 = { greeting: "first" };
        \\const proto2 = { greeting: "second" };
        \\const obj = Object.create(proto1);
        \\// Warm the IC against proto1.
        \\for (let i = 0; i < 5; i++) obj.greeting;
        \\Object.setPrototypeOf(obj, proto2);
        \\obj.greeting;
    , "second");
}

test "proto-load IC: Reflect.setPrototypeOf invalidates" {
    // Same shape as above but via Reflect.setPrototypeOf — must
    // bump the same invalidation counter.
    try expectScriptStringWithBuiltins(
        \\const p1 = { tag: "alpha" };
        \\const p2 = { tag: "beta" };
        \\const o = Object.create(p1);
        \\for (let i = 0; i < 5; i++) o.tag;
        \\Reflect.setPrototypeOf(o, p2);
        \\o.tag;
    , "beta");
}

test "proto-load IC: reassigning the prototype's property serves the new value" {
    // Cell caches `obj.x` inherited from proto. Mutating
    // `proto.x = newValue` keeps proto's shape but updates the
    // slot value (shadowSet path). Next obj.x must see newValue.
    try expectScriptIntWithBuiltins(
        \\const proto = { x: 10 };
        \\const obj = Object.create(proto);
        \\let acc = 0;
        \\for (let i = 0; i < 3; i++) acc += obj.x;
        \\proto.x = 100;
        \\acc + obj.x;
    , 10 * 3 + 100);
}

test "proto-load IC: deleting the prototype's property invalidates" {
    // After `delete proto.x`, proto's shape changes (demote /
    // dictionary) so the proto-load IC must miss — next obj.x is
    // undefined.
    try expectScriptStringWithBuiltins(
        \\const proto = { x: "live" };
        \\const obj = Object.create(proto);
        \\for (let i = 0; i < 5; i++) obj.x;
        \\delete proto.x;
        \\typeof obj.x;
    , "undefined");
}

test "proto-load IC: data→accessor conversion on proto fires the getter" {
    // Cache `obj.x` as inherited data. Object.defineProperty
    // converts proto.x to an accessor; the IC must miss (proto's
    // shape demoted on accessor install). Next obj.x runs getter.
    try expectScriptIntWithBuiltins(
        \\const proto = { x: 1 };
        \\const obj = Object.create(proto);
        \\for (let i = 0; i < 5; i++) obj.x;
        \\Object.defineProperty(proto, "x", { get() { return 999; } });
        \\obj.x;
    , 999);
}

test "proto-load IC: chain depth 2 — inherited from grandparent" {
    // obj → mid → grand, property only on grand. The IC must
    // either cache the resolved (grand-side) slot or miss safely;
    // either way the read returns grand's value.
    try expectScriptIntWithBuiltins(
        \\const grand = { value: 77 };
        \\const mid = Object.create(grand);
        \\const obj = Object.create(mid);
        \\let acc = 0;
        \\for (let i = 0; i < 20; i++) acc += obj.value;
        \\acc;
    , 77 * 20);
}

test "proto-load IC: setPrototypeOf to chain lacking the key reads undefined" {
    // Warm the cache. Then setPrototypeOf to an object that
    // doesn't have the key. Reading it must return undefined,
    // not the stale cached value.
    try expectScriptStringWithBuiltins(
        \\const p1 = { x: "yes" };
        \\const p2 = {};
        \\const o = Object.create(p1);
        \\for (let i = 0; i < 5; i++) o.x;
        \\Object.setPrototypeOf(o, p2);
        \\typeof o.x;
    , "undefined");
}

test "proto-load IC: polymorphic receivers sharing one prototype" {
    // Two different objects, both inheriting from the same proto,
    // pass through the same call site. The proto-load IC should
    // hit on both (chain identity preserved) and return the right
    // proto-side value each time.
    try expectScriptIntWithBuiltins(
        \\const proto = { fn() { return 5; } };
        \\const a = Object.create(proto);
        \\const b = Object.create(proto);
        \\let acc = 0;
        \\for (let i = 0; i < 50; i++) { acc += a.fn(); acc += b.fn(); }
        \\acc;
    , 5 * 100);
}

test "proto-load IC: receiver's own accessor shadows inherited data" {
    // `child` has an own accessor for `length` installed via
    // `Object.defineProperty`; `proto` carries a data property of
    // the same name. A property read on `child.length` MUST dispatch
    // the accessor — serving the inherited proto data would return
    // 3 instead of 2.
    //
    // Regression: the early proto-load IC walk skipped the
    // receiver's own accessor check and miscached the proto's data
    // slot, breaking test262 fixtures like
    // `built-ins/Array/prototype/reduce/15.4.4.21-2-8.js`.
    try expectScriptIntWithBuiltins(
        \\const proto = { length: 3 };
        \\const child = Object.create(proto);
        \\Object.defineProperty(child, "length", { get() { return 2; } });
        \\let acc = 0;
        \\// Hot loop — first iteration warms the cell. The
        \\// remaining 99 must still fire the accessor.
        \\for (let i = 0; i < 100; i++) acc = child.length;
        \\acc;
    , 2);
}

test "proto-load IC: dictionary-mode proto doesn't leak to the next chain link" {
    // Built-in `%String.prototype%` is marked as a String exotic at
    // realm init, which demotes its shape to dictionary mode while
    // `properties` still carries `constructor`. A naive proto walk
    // would skip the shapeless String.prototype and miscache
    // `Object.prototype.constructor` (= Object) as the resolution.
    // The walk must break at any proto whose `properties` claims
    // the key — letting the slow path resolve correctly.
    //
    // Regression: pre-fix, `new String("a").constructor === String`
    // returned false (the walk served Object). Drove ~50 test262
    // fixtures under `built-ins/String` and `built-ins/Object`.
    try expectScriptStringWithBuiltins(
        \\const a = new String("a");
        \\const b = new String("b");
        \\const c = new Object("c"); // also boxes to a String wrapper
        \\const ok = (a.constructor === String) &&
        \\           (b.constructor === String) &&
        \\           (c.constructor === String);
        \\String(ok);
    , "true");
}

test "proto-load IC: hot loop on dictionary-mode proto stays correct" {
    // Same dictionary-mode-proto guard, exercised across many
    // iterations of the same callsite to ensure no stale cache
    // sneaks in mid-loop.
    try expectScriptIntWithBuiltins(
        \\const obj = new String("hot");
        \\let hits = 0;
        \\for (let i = 0; i < 200; i++) {
        \\  if (obj.constructor === String) hits++;
        \\}
        \\hits;
    , 200);
}

test "proto-load IC: two receivers with different protos at the same site" {
    // Same call site, two receivers whose own shape happens to
    // match (both at the shape-tree root) but whose prototypes
    // differ. The IC must NOT serve the cached proto's slot when
    // the receiver's actual prototype is different — covered by
    // the `obj_in.prototype == cell.proto` identity check.
    //
    // Regression target: without the identity check, the cell
    // filled by the first call would hit-and-mis-serve on the
    // second.
    try expectScriptStringWithBuiltins(
        \\function read(o) { return o.constructor.name; }
        \\const a = new String("x");
        \\const b = new Number(7);
        \\// Alternate receivers through the same compiled site.
        \\let s = "";
        \\for (let i = 0; i < 10; i++) {
        \\  s += read((i & 1) === 0 ? a : b) + ",";
        \\}
        \\s;
    , "String,Number,String,Number,String,Number,String,Number,String,Number,");
}

// ─────────────────────────────────────────────────────────────────────
// Literal-shape template cache (b79e9e6) — `make_object_shape`
// regression coverage. The compiler captures static-key object
// literals in a chunk-side template; runtime stamps the cached
// `Shape*` on the new object so downstream `def_property` opcodes
// don't re-walk the shape transition tree per key. The same-attrs
// path in `def_property` must let the redefine pass without
// demoting.
// ─────────────────────────────────────────────────────────────────────

test "literal shape: basic data literal returns correct property values" {
    try expectScriptIntWithBuiltins(
        \\const o = {a: 1, b: 2, c: 3};
        \\o.a + o.b + o.c;
    , 6);
}

test "literal shape: Object.keys preserves insertion order" {
    // §10.1.11 OrdinaryOwnPropertyKeys — `own_key_order` populated
    // by `recordKey` (inside def_property's setWithFlags). Keys
    // enumerate in source order regardless of the template path.
    try expectScriptStringWithBuiltins(
        \\const o = {alpha: 1, beta: 2, gamma: 3};
        \\Object.keys(o).join(",");
    , "alpha,beta,gamma");
}

test "literal shape: hot allocating loop produces correct cumulative values" {
    // Main perf target — `{a: i, b: i+1}` in a tight loop. Shape
    // cached after the first iteration; every subsequent stamp
    // skips the per-key transition walk. Assert correctness
    // across 1000 iterations.
    try expectScriptIntWithBuiltins(
        \\let r = 0;
        \\for (let i = 0; i < 1000; i++) {
        \\  const o = {a: i, b: i + 1};
        \\  r += o.a + o.b;
        \\}
        \\r;
    , 1000000); // sum(2*i+1, i=0..999) = 1000 + 2*sum(0..999) = 1000 + 999000
}

test "literal shape: two literals with identical key list share the cached shape" {
    // `ShapeTree.transition` is find-or-create, so two distinct
    // `make_object_shape` ops with the same key list build the
    // same `Shape*` on first hit and reuse it. Reads at both
    // sites must work.
    try expectScriptIntWithBuiltins(
        \\function make1(i) { return {x: i, y: i * 2}; }
        \\function make2(i) { return {x: i * 10, y: i * 20}; }
        \\const a = make1(3);
        \\const b = make2(5);
        \\a.x + a.y + b.x + b.y;
    , 3 + 6 + 50 + 100);
}

test "literal shape: same-attrs reassignment via sta_property preserves shape" {
    // After `make_object_shape` stamps the shape, `obj.x = …`
    // goes through `sta_property` (IC-served write). The shape
    // stays; the write IC verifies the value reads back
    // correctly.
    try expectScriptIntWithBuiltins(
        \\const o = {x: 1, y: 2};
        \\o.x = 100;
        \\o.x + o.y;
    , 102);
}

test "literal shape: defineProperty with non-default flags handles shape demote" {
    // After the shape stamp, `Object.defineProperty` with attrs
    // that diverge from the shape's default must demote and
    // route through the audit-fixed dictionary path.
    try expectScriptIntWithBuiltins(
        \\const o = {x: 1, y: 2};
        \\Object.defineProperty(o, "x", { value: 99, writable: true, enumerable: true, configurable: false });
        \\o.x + o.y;
    , 101);
}

test "literal shape: __proto__ literal key bails out of templatization" {
    // `__proto__` is detected at compile time and bails — the
    // template path's key list would skip it but the prototype
    // mutation needs `set_proto_literal`. Compiler routes to the
    // non-template path.
    try expectScriptIntWithBuiltins(
        \\const parent = { greet: 42 };
        \\const o = { __proto__: parent, x: 1 };
        \\o.x + o.greet;
    , 43);
}

// §13.2.5.5 PropertyDefinitionEvaluation — the `__proto__:` magic
// (Annex B §B.3.6) only applies to the
//   `PropertyDefinition : PropertyName : AssignmentExpression`
// production with a non-computed `__proto__` key. The CoverInitialized-
// Name shorthand `{__proto__}` and ComputedPropertyName `{[k]: v}`
// productions are normative and create a regular own data property.
// test262 fixture: `language/expressions/object/__proto__-permitted-
// dup-shorthand.js`.

test "later: shorthand {__proto__} creates an own data property" {
    try expectScriptStringWithBuiltins(
        \\var __proto__ = 2;
        \\var obj = { __proto__ };
        \\obj.hasOwnProperty("__proto__") + ":" + obj.__proto__;
    , "true:2");
}

test "later: duplicate shorthand __proto__ is legal and writes own" {
    try expectScriptStringWithBuiltins(
        \\var __proto__ = 2;
        \\var obj = { __proto__, __proto__ };
        \\obj.hasOwnProperty("__proto__") + ":" + obj.__proto__;
    , "true:2");
}

test "later: computed __proto__ key creates own data property" {
    // §13.2.5.5 — ComputedPropertyName bypasses §B.3.6. Even when
    // the key happens to be the string "__proto__", the result is
    // a regular own property, not a [[Prototype]] mutation.
    try expectScriptStringWithBuiltins(
        \\var k = "__proto__";
        \\var obj = { [k]: 5 };
        \\obj.hasOwnProperty("__proto__") + ":" + obj.__proto__;
    , "true:5");
}

test "later: __proto__: literal still sets prototype (Annex B §B.3.6 retained)" {
    // The non-shorthand colon form keeps its Annex B prototype-
    // setting semantics. `obj.x` falls through the prototype chain.
    try expectScriptIntWithBuiltins(
        \\const parent = { greet: 7 };
        \\const obj = { __proto__: parent, own: 3 };
        \\obj.greet + obj.own;
    , 10);
}

test "literal shape: computed key bails out of templatization" {
    // `[expr]: value` keys are runtime-known. Template build
    // detects `.computed` and bails; compiler falls back to
    // `make_object` + `def_computed`.
    try expectScriptIntWithBuiltins(
        \\const k = "dynamic";
        \\const o = {a: 1, [k]: 99};
        \\o.a + o.dynamic;
    , 100);
}

test "literal shape: method definition bails out of templatization" {
    // Method syntax `{ fn() {} }` goes through `make_function`
    // + def_property of a function value. Template build's
    // `.method` branch bails.
    try expectScriptIntWithBuiltins(
        \\const o = { x: 1, get() { return this.x * 10; } };
        \\o.x + o.get();
    , 11);
}

test "literal shape: duplicate keys fall back to non-template path" {
    // `{a: 1, a: 2}` — second `a` overrides. Template build
    // detects the duplicate and bails (a transition fork or
    // alias would corrupt the shape). The non-template path
    // handles the override via def_property's had_own redefine.
    try expectScriptIntWithBuiltins(
        \\const o = {a: 1, b: 2, a: 3};
        \\o.a + o.b;
    , 5);
}

// ── Proper Tail Calls (§15.10) ───────────────────────────────────────

test "PTC: deep self-recursion via return f() does not overflow" {
    // §15.10 — `return f(n - 1)` is in tail position. The compiler
    // emits `.tail_call`, the interpreter reuses the current
    // frame, and 3000 calls fit in one dispatch frame. The
    // 1024-frame `max_call_frames` cap is never hit. 3000 is
    // chosen as a comfortable margin over the cap while staying
    // fast in Debug builds.
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  if (n === 0) return 42;
        \\  return f(n - 1);
        \\}
        \\f(3000);
    , 42);
}

test "PTC: mutual recursion in tail position does not overflow" {
    // §15.10 PTC covers mutual recursion too — every call from
    // even→odd / odd→even is the last operation of its frame.
    try expectScriptIntWithBuiltins(
        \\function even(n) { return n === 0 ? 1 : odd(n - 1); }
        \\function odd(n)  { return n === 0 ? 0 : even(n - 1); }
        \\even(3000);
    , 1);
}

test "PTC: arrow concise body is in tail position (§15.10.1)" {
    // The body expression of an arrow with concise body IS the
    // return value, so the call inside it is in tail position.
    try expectScriptIntWithBuiltins(
        \\const f = (n) => n === 0 ? 7 : f(n - 1);
        \\f(3000);
    , 7);
}

test "PTC: conditional consequent / alternate propagate tail position" {
    // §15.10.1 — the consequent and alternate of a ternary
    // inherit the surrounding tail-position; the test does not.
    try expectScriptIntWithBuiltins(
        \\function loop(n, acc) {
        \\  return n === 0 ? acc : loop(n - 1, acc + 1);
        \\}
        \\loop(3000, 0);
    , 3000);
}

test "PTC: logical && / || rhs propagates tail position" {
    // §13.13 — the rhs of `&&` / `||` is evaluated only when
    // short-circuit doesn't fire; §15.10.1 says it's in tail
    // position when the operator is. lhs is NOT. N=3000 matches
    // the rest of the PTC tests — comfortably above the
    // 1024-frame cap so a missing PTC would RangeError, but
    // small enough that the Debug-mode interpreter completes in
    // ~4 s instead of the ~63 s an N=50000 fixture took.
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  return n === 0 || f(n - 1);
        \\}
        \\f(3000) === true ? 1 : 0;
    , 1);
}

test "PTC: comma's last operand inherits tail position" {
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  return (0, n === 0 ? 99 : f(n - 1));
        \\}
        \\f(3000);
    , 99);
}

test "PTC: parenthesized expressions are transparent for tail position" {
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  return ((n === 0 ? 5 : f(n - 1)));
        \\}
        \\f(3000);
    , 5);
}

test "PTC: try-with-catch suppresses PTC in the try block (§15.10.1)" {
    // §15.10.1 — TryStatement : try Block Catch asks `Catch`,
    // not `Block`, for tail-position eligibility. So a call in
    // the try block is NOT in tail position when a catch is
    // installed in the same chunk: reusing the frame would lose
    // the handler PC range and the catch would never see the
    // throw.
    //
    // Design of the test: each recursive frame's catch catches
    // any thrown RangeError and returns `-1`. With PTC ON and
    // SUPPRESSION WORKING, the recursion pushes real frames,
    // overflows at the 1024-frame cap, the deepest frame's
    // catch fires, returns -1 — propagates up through the
    // returns and the top-level call yields -1.
    //
    // If the compiler INCORRECTLY emitted `.tail_call` for the
    // call inside the try, frames would be reused, n would
    // count down to 0 cleanly, and the call would yield 99 with
    // no throw observed. So an answer of -1 confirms the
    // suppression. Run with PTC ON to actually exercise the
    // gate.
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  try {
        \\    return n === 0 ? 99 : f(n - 1);
        \\  } catch (e) { return -1; }
        \\}
        \\f(3000);
    , -1);
}

test "PTC: catch body IS in tail position (§15.10.1 — Catch is the inner)" {
    // The companion to the test above — `return f(n-1)` INSIDE
    // the catch body IS in tail position per §15.10.1's
    // `HasCallInTailPosition of Catch with argument call` rule.
    // Confirms `try_with_handler_depth` resets when leaving the
    // try block (not when leaving the whole try statement).
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  if (n === 0) return 7;
        \\  try { throw null; } catch (e) { return f(n - 1); }
        \\}
        \\f(3000);
    , 7);
}

test "PTC: finally body IS in tail position (§15.10.1)" {
    // `try { } finally { return f(n-1) }` — the finally body is
    // the tail of the try statement; spec says it IS in tail
    // position. Cynic's compileTry pops the finally context
    // BEFORE compiling the finally body, so `finally_chain`
    // sees null and the PTC gate allows the tail call.
    try expectScriptIntWithBuiltins(
        \\function f(n) {
        \\  if (n === 0) return 3;
        \\  try { } finally { return f(n - 1); }
        \\}
        \\f(3000);
    , 3);
}

test "PTC: try/finally suppresses PTC (§15.10.1 — finally would never run)" {
    // The recursive call is syntactically in tail position, but
    // a `finally` block still has to run after the return.
    // §15.10.1 says the try block is NOT a tail-position site
    // when a finally is owed.
    //
    // Tested with PTC ON — if the compiler incorrectly emitted
    // `.tail_call` here, the 3000-iter recursion would complete.
    // The `finally_chain != null` gate in `shouldEmitTailCall`
    // keeps it as `.call` and the recursion overflows.
    try expectScriptThrowsWithBuiltins(
        \\function f(n) {
        \\  try {
        \\    return n === 0 ? 42 : f(n - 1);
        \\  } finally {}
        \\}
        \\f(3000);
    );
}

test "PTC: for-of body suppresses PTC (iterator close discipline)" {
    // §7.4.6 IteratorClose says the iterator's return() runs
    // when control leaves the loop. PTC frame-reuse would
    // perform the recursive call before iter_close (or skip it
    // entirely), so the compiler suppresses PTC when any
    // enclosing loop owns an open iterator. Tested with PTC ON
    // so the suppression is what's actually exercising the
    // overflow.
    try expectScriptThrowsWithBuiltins(
        \\function f(n) {
        \\  for (const _ of [1]) {
        \\    return n === 0 ? 0 : f(n - 1);
        \\  }
        \\}
        \\f(3000);
    );
}

test "PTC: non-tail position recursive call still overflows" {
    // `1 + f(n - 1)` is NOT in tail position (the `+` consumes
    // the result), so the compiler must emit `.call`, not
    // `.tail_call`. Confirms the in_tail_position flag is
    // CLEARED by non-propagating expression types. Tested with
    // PTC ON: the binary `+` arm of `compileExpression` clears
    // the flag for its sub-expressions; without that clear, the
    // call inside would tail-call and the recursion would
    // succeed.
    try expectScriptThrowsWithBuiltins(
        \\function f(n) {
        \\  if (n === 0) return 0;
        \\  return 1 + f(n - 1);
        \\}
        \\f(3000);
    );
}

test "PTC: method call in tail position uses tail_call_method" {
    try expectScriptIntWithBuiltins(
        \\const o = {
        \\  step(n, acc) { return n === 0 ? acc : o.step(n - 1, acc + 2); }
        \\};
        \\o.step(3000, 0);
    , 6000);
}

test "PTC: arrow's captured this/new.target preserved across tail call" {
    // Arrows tail-called from a method body inherit the captured
    // this — the reframe step copies captured_this rather than
    // the call-site receiver.
    try expectScriptIntWithBuiltins(
        \\class C {
        \\  constructor() { this.v = 11; }
        \\  go(n) {
        \\    const self = this;
        \\    const step = (k) => k === 0 ? self.v : step(k - 1);
        \\    return step(n);
        \\  }
        \\}
        \\new C().go(3000);
    , 11);
}

// ─────────────────────────────────────────────────────────────────────
// Frame register pool regression coverage. Every JS call acquires
// a `[]Value` register file from `realm.frame_pool`; release returns
// it for reuse. Stale buffer contents from the previous frame are
// the obvious failure mode — verify a hot call loop never sees
// leaked register values.
// ─────────────────────────────────────────────────────────────────────

test "frame pool: hot call loop produces correct cumulative result" {
    // Each iteration acquires the same-sized register file from
    // the pool. The call site memsets to undefined after acquire,
    // so prior callees' register contents must not leak into the
    // new frame.
    try expectScriptIntWithBuiltins(
        \\function add1(x) { return x + 1; }
        \\let r = 0;
        \\for (let i = 0; i < 5000; i++) r = add1(r);
        \\r;
    , 5000);
}

test "frame pool: alternating callees with different register counts" {
    // Different register_counts → different bins. The pool keeps
    // both bins; the bench loop alternates which one is acquired.
    try expectScriptIntWithBuiltins(
        \\function small(x) { return x + 1; }
        \\function big(x) {
        \\  const a = x + 1, b = x + 2, c = x + 3, d = x + 4, e = x + 5;
        \\  return a + b + c + d + e;
        \\}
        \\let r = 0;
        \\for (let i = 0; i < 12; i++) {
        \\  r = small(r);
        \\  r = big(r);
        \\}
        \\r;
        // small adds 1; big computes 5*(x+1)+15 = 5x+20. Per loop
        // iteration r' = 5*r + 20, closed-form r_n = 5*(5^n − 1).
        // N=12 → r = 5*(5^12 − 1) = 5*244140624 = 1_220_703_120,
        // still inside the i32 range expectScriptIntWithBuiltins
        // takes. N=100 (the original intent) overflows i32 and
        // produces a JS double — fold into the alternating-callees
        // stress without needing string-assert plumbing.
    , 1220703120);
}

test "frame pool: method call hot loop on class instance" {
    // The class_instantiate / method_call benches surfaced this:
    // 500k calls to the same method, all share the pool's bin for
    // `register_count`. Verify both correctness AND that the
    // method body's register file isn't holding garbage values
    // from prior iterations.
    try expectScriptIntWithBuiltins(
        \\class Counter {
        \\  constructor() { this.n = 0; }
        \\  inc() { this.n += 1; return this.n; }
        \\}
        \\const c = new Counter();
        \\let acc = 0;
        \\for (let i = 0; i < 1000; i++) acc = c.inc();
        \\acc;
    , 1000);
}

test "frame pool: recursive call releases + reacquires same-size frame" {
    // Tail-recursive (PTC) call releases the caller's register
    // file then acquires the callee's. With identical
    // register_count, the pool's same bin pops the just-released
    // buffer — verifies the pool doesn't hand back a buffer
    // currently in use elsewhere.
    try expectScriptIntWithBuiltins(
        \\function loop(n, acc) { return n === 0 ? acc : loop(n - 1, acc + 1); }
        \\loop(2000, 0);
    , 2000);
}

test "frame pool: nested construction reuses frames" {
    // `new` allocates a frame for the constructor body. A loop
    // of `new`s exercises the pool's `class_instantiate`-shaped
    // path — pool churn on each iteration.
    try expectScriptIntWithBuiltins(
        \\class Point {
        \\  constructor(x, y) { this.x = x; this.y = y; }
        \\}
        \\let sum = 0;
        \\for (let i = 0; i < 500; i++) {
        \\  const p = new Point(i, i + 1);
        \\  sum += p.x + p.y;
        \\}
        \\sum;
    , 250000); // sum(i + (i+1), i=0..499) = sum(2i+1) = 2*(499*500/2) + 500 = 250000
}

// ── loop_inc_lt — direct opcode tests ──────────────────────────────
// Hand-built chunks that exercise the fused counter-loop opcode
// without going through the compiler. Confirms both the int32 fast
// path (counter + bound both int32, no overflow) and the
// general-case slow fallback (counter coerced to double via overflow,
// non-int32 operands).

fn runHandBuiltChunk(chunk: *chunk_mod.Chunk) !Value {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    return switch (try run(testing.allocator, &realm, chunk)) {
        .value, .yielded => |v| v,
        .thrown => return error.UncaughtException,
    };
}

test "loop_inc_lt: int32 fast path sums 0..4" {
    // Equivalent to `for (let i = 0; i < 5; i++) sum += i;` —
    // r0 holds the counter, r1 the bound, r2 the running sum.
    var b = chunk_mod.Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r_counter = try b.reserveRegister();
    const r_bound = try b.reserveRegister();
    const r_sum = try b.reserveRegister();

    try b.emitOp(.lda_smi, span);
    try b.emitI32(0);
    try b.emitOp(.star, span);
    try b.emitU8(r_counter);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(5);
    try b.emitOp(.star, span);
    try b.emitU8(r_bound);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(0);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    // Entry test: if !(counter < bound) jump to exit. `lt r`
    // computes `acc = reg < acc`, so put the bound in acc and
    // the counter in the register operand to get `counter < bound`.
    try b.emitOp(.ldar, span);
    try b.emitU8(r_bound);
    try b.emitOp(.lt, span);
    try b.emitU8(r_counter);
    try b.emitOp(.jmp_if_false, span);
    const entry_exit = b.here();
    try b.emitI16(0);

    // Body: sum = sum + counter.
    const body_start = b.here();
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.add, span);
    try b.emitU8(r_counter);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    // Fused bottom: counter++; if counter < bound, jump back.
    try b.emitOp(.loop_inc_lt, span);
    try b.emitU8(r_counter);
    try b.emitU8(r_bound);
    const back_patch = b.here();
    try b.emitI16(0);
    try b.patchI16(back_patch, body_start);

    // Exit: leave sum in acc and return.
    const exit_pc = b.here();
    try b.patchI16(entry_exit, exit_pc);
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.return_, span);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const v = try runHandBuiltChunk(&chunk);
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 10), v.asInt32()); // 0+1+2+3+4
}

test "loop_inc_lt: slow path with double counter still iterates" {
    // Counter starts as the double 3.0 — the int32 fast path
    // bails on the first iteration, the slow path takes over via
    // `arith.incOrDec` + `relational(.lt, …)`. Sum should be
    // 3+4 = 7 (counter visits 3 then 4, both int-valued doubles).
    var b = chunk_mod.Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r_counter = try b.reserveRegister();
    const r_bound = try b.reserveRegister();
    const r_sum = try b.reserveRegister();

    const k_three = try b.addConstant(Value.fromDouble(3.0));
    try b.emitOp(.lda_constant, span);
    try b.emitU16(k_three);
    try b.emitOp(.star, span);
    try b.emitU8(r_counter);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(5);
    try b.emitOp(.star, span);
    try b.emitU8(r_bound);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(0);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    try b.emitOp(.ldar, span);
    try b.emitU8(r_bound);
    try b.emitOp(.lt, span);
    try b.emitU8(r_counter);
    try b.emitOp(.jmp_if_false, span);
    const entry_exit = b.here();
    try b.emitI16(0);

    const body_start = b.here();
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.add, span);
    try b.emitU8(r_counter);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    try b.emitOp(.loop_inc_lt, span);
    try b.emitU8(r_counter);
    try b.emitU8(r_bound);
    const back_patch = b.here();
    try b.emitI16(0);
    try b.patchI16(back_patch, body_start);

    const exit_pc = b.here();
    try b.patchI16(entry_exit, exit_pc);
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.return_, span);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const v = try runHandBuiltChunk(&chunk);
    // Int32-safe sum lands back in int32 once int32+int32 (added
    // to the running int32 sum) succeeds without overflow. Double
    // 3 + int 0 → int32 3 via addValues' int32-or-double dispatch
    // — accept either tag and compare numerically.
    const n: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    try testing.expectEqual(@as(f64, 7.0), n);
}

test "loop_inc_lt: zero iterations when entry test fails" {
    // counter = 5, bound = 5 — entry test bails before the body
    // runs. Sum stays at 100 (its seed).
    var b = chunk_mod.Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r_counter = try b.reserveRegister();
    const r_bound = try b.reserveRegister();
    const r_sum = try b.reserveRegister();

    try b.emitOp(.lda_smi, span);
    try b.emitI32(5);
    try b.emitOp(.star, span);
    try b.emitU8(r_counter);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(5);
    try b.emitOp(.star, span);
    try b.emitU8(r_bound);

    try b.emitOp(.lda_smi, span);
    try b.emitI32(100);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    try b.emitOp(.ldar, span);
    try b.emitU8(r_bound);
    try b.emitOp(.lt, span);
    try b.emitU8(r_counter);
    try b.emitOp(.jmp_if_false, span);
    const entry_exit = b.here();
    try b.emitI16(0);

    const body_start = b.here();
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.add, span);
    try b.emitU8(r_counter);
    try b.emitOp(.star, span);
    try b.emitU8(r_sum);

    try b.emitOp(.loop_inc_lt, span);
    try b.emitU8(r_counter);
    try b.emitU8(r_bound);
    const back_patch = b.here();
    try b.emitI16(0);
    try b.patchI16(back_patch, body_start);

    const exit_pc = b.here();
    try b.patchI16(entry_exit, exit_pc);
    try b.emitOp(.ldar, span);
    try b.emitU8(r_sum);
    try b.emitOp(.return_, span);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const v = try runHandBuiltChunk(&chunk);
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 100), v.asInt32());
}

// ── Counter-loop specialization — end-to-end tests ─────────────────
// Source-level coverage of the compiler pattern matcher: confirm
// the fused form runs correctly and stays observably identical to
// the legacy path on edge cases (break, continue, body-mutation,
// non-integer init, `<=` bound).

test "counter-loop: tight numeric sum 0..99" {
    try expectScriptIntWithBuiltins(
        \\let sum = 0;
        \\for (let i = 0; i < 100; i++) sum = (sum + i) | 0;
        \\sum;
    , 4950);
}

test "counter-loop: break exits at right iteration" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let i = 0; i < 100; i++) {
        \\  if (i === 4) break;
        \\  s = s + i;
        \\}
        \\s;
    , 6); // 0+1+2+3
}

test "counter-loop: continue skips to increment" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let i = 0; i < 10; i++) {
        \\  if ((i & 1) === 0) continue;  // skip even
        \\  s = s + i;
        \\}
        \\s;
    , 25); // 1+3+5+7+9
}

test "counter-loop: emits loop_inc_lt for canonical pattern" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\let s = 0; for (let i = 0; i < 10; i++) s = s + i; s;
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") != null);
    // Sanity: the standalone `Inc` opcode is NOT emitted for this
    // loop — the fused form replaces the inc + lt + jmp triple.
    try testing.expect(std.mem.indexOf(u8, out, " Inc ") == null);
}

test "counter-loop: body reassigning i falls back to legacy path" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\let s = 0;
        \\for (let i = 0; i < 10; i++) {
        \\  i = i + 1;  // body reassigns the counter — bail to legacy.
        \\  s = s + i;
        \\}
        \\s;
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") == null);
}

test "counter-loop: non-integer init falls back to legacy path" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\let s = 0;
        \\for (let i = 0.5; i < 5; i++) s = s + 1;
        \\s;
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") == null);
}

test "counter-loop: `<=` bound falls back to legacy path" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\let s = 0;
        \\for (let i = 0; i <= 5; i++) s = s + i;
        \\s;
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") == null);
}

test "counter-loop: closure capturing i falls back" {
    // A nested function mentions `i` — would attempt to capture
    // the register-promoted binding, which isn't in any env. The
    // safety walker bails to the legacy per-iter-env path.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\const fns = [];
        \\for (let i = 0; i < 3; i++) fns.push(function() { return i; });
        \\fns[0]() + fns[1]() + fns[2]();
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") == null);
}

test "counter-loop: prefix ++i matches the canonical pattern" {
    // `++i` and `i++` have identical for-update semantics (the
    // expression value is discarded), so both qualify.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try installBuiltinsAllFeatures(&realm);
    const out = try compileAndDisassemble(&realm,
        \\let s = 0; for (let i = 0; i < 5; ++i) s = s + i; s;
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LoopIncLt") != null);
}

test "counter-loop: nested fused loops compile correctly" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let i = 0; i < 5; i++) {
        \\  for (let j = 0; j < 5; j++) s = s + 1;
        \\}
        \\s;
    , 25);
}

test "counter-loop: break in nested fused loop exits inner only" {
    try expectScriptIntWithBuiltins(
        \\let s = 0;
        \\for (let i = 0; i < 3; i++) {
        \\  for (let j = 0; j < 100; j++) {
        \\    if (j >= 4) break;
        \\    s = s + 1;
        \\  }
        \\}
        \\s;
    , 12); // 3 outer * 4 inner = 12
}

test "counter-loop: zero-iteration when init equals bound" {
    try expectScriptIntWithBuiltins(
        \\let s = 100;
        \\for (let i = 5; i < 5; i++) s = 0;
        \\s;
    , 100);
}

test "SES Phase 3: iter spread on built-in iterators works under hardened" {
    // Regression pin for the iterator-dispatch bug surfaced by
    // `docs/handbook/ses-test262-policy.md` Phase 1 audit
    // (commit a104662 reported 65 `iterator.next is not callable`
    // failures, all on Set / Iterator methods that pass under
    // unhardened but failed when SES Phase 3 demoted the
    // built-in iterator-prototype `next` slot to a synthetic
    // accessor pair). `JSObject.get` walked the prototype chain
    // via data-slot lookup only — synthetic accessors silently
    // returned `undefined`, so the spread's `iter_obj.get("next")`
    // call site at `interpreter.zig:6790` saw a non-function and
    // threw. Fix routes `JSObject.get` through `synth_accessor.value`
    // for accessor entries it encounters during the chain walk.
    //
    // Three reproducers, all of which threw `TypeError: iterator.next
    // is not callable` pre-fix:
    try expectScriptStringWithBuiltins(
        \\let s = new Set([1, 2, 3]);
        \\[...s].join(",");
    , "1,2,3");
    try expectScriptStringWithBuiltins(
        \\let a = new Set([1, 2, 3]);
        \\let b = new Set([2, 3, 4]);
        \\[...a.intersection(b)].join(",");
    , "2,3");
    try expectScriptStringWithBuiltins(
        \\class Iterable {
        \\  get [Symbol.iterator]() {
        \\    return function () { return [10, 20, 30][Symbol.iterator](); };
        \\  }
        \\}
        \\[...Iterator.concat(new Iterable())].join(",");
    , "10,20,30");
}
