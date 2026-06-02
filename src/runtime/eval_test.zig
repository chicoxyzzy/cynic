//! Positive coverage for the `--allow=eval` runtime-code-construction
//! engine (§19.2.1 PerformEval, §20.2.1.1.1 CreateDynamicFunction).
//!
//! Sibling `eval_policy_test.zig` pins the *refusal* surface — the
//! default (gate-closed) SES posture where `eval` / `Function(string)`
//! throw, and the gate-open-but-stubbed transition. This file is the
//! complement: with `realm.allow_eval = true` AND a real eval engine,
//! the eval surface must actually execute source.
//!
//! Cynic parses all source as strict, so every eval is a strict eval
//! (§19.2.1.3): the eval'd code gets its own declarative + variable
//! environment and never injects `var` / function bindings into the
//! caller's scope. Direct eval still resolves free identifiers against
//! the caller's lexical environment for reads (and inherits the
//! caller's `this` / `new.target`).

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

/// Evaluate `source` against a realm with the eval gate open and
/// return the completion value. A thrown completion is surfaced as a
/// Zig error so a test asserting a value never silently passes on a
/// throw.
fn evalAllow(source: []const u8) !Value {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_eval = true;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => error.EvalThrewUnexpectedly,
    };
}

/// Evaluate `source` and assert the completion is the int32 `want`.
fn expectIntAllow(source: []const u8, want: i32) !void {
    const v = try evalAllow(source);
    if (!v.isInt32()) {
        std.debug.print("expected int32 {d}, got non-int value\n", .{want});
        return error.EvalResultNotInt;
    }
    try testing.expectEqual(want, v.asInt32());
}

/// Like `evalAllow`, but unhardened (mutable / extensible primordials)
/// — the posture the test262 sweep scores under and the one in which
/// §9.1.1.4.15/.16 CanDeclareGlobalVar / CanDeclareGlobalFunction can
/// fail (a hardened realm bypasses the extensibility check).
fn evalUnhardenedAllow(source: []const u8) !Value {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_eval = true;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => error.EvalThrewUnexpectedly,
    };
}

fn expectIntUnhardened(source: []const u8, want: i32) !void {
    const v = try evalUnhardenedAllow(source);
    if (!v.isInt32()) {
        std.debug.print("expected int32 {d}, got non-int value\n", .{want});
        return error.EvalResultNotInt;
    }
    try testing.expectEqual(want, v.asInt32());
}

// ── §19.2.1 indirect eval ───────────────────────────────────────────

test "eval: indirect (0,eval) evaluates as global code" {
    // `(0, eval)(s)` is the canonical indirect form — the callee is
    // the %eval% value but NOT the syntactic `eval(...)` reference,
    // so §19.2.1.1 runs `s` as global-scope code.
    try expectIntAllow("(0, eval)('1 + 1')", 2);
}

test "eval: indirect via globalThis.eval" {
    try expectIntAllow("globalThis.eval('40 + 2')", 42);
}

test "eval: completion value is the last expression" {
    // §19.2.1 returns the script's completion value; a trailing
    // declaration has empty completion (undefined), an expression
    // statement carries its value.
    try expectIntAllow("eval('var a = 3; a * a')", 9);
}

test "eval: strict eval var does not leak to the global env (direct)" {
    // §19.2.1.3 — strict eval gets its own variable environment, so a
    // top-level `var` binds locally and never escapes to the caller /
    // global. It works inside the eval, then is gone afterward.
    try expectIntAllow("eval('var a = 3; a * a')", 9);
    try expectIntAllow(
        \\eval('var leaked = 1;');
        \\(typeof globalThis.leaked === 'undefined' && !('leaked' in globalThis)) ? 1 : 0;
    , 1);
}

test "eval: indirect eval runs as global code" {
    // §19.2.1.1 — indirect eval is global code. The top-level `var b`
    // binds on the global env and the body's `b * b` reads it back.
    // (Whether a non-strict indirect `var` is observable on globalThis,
    // and that a strict-body indirect eval keeps it local, is pinned by
    // the unhardened §19.2.1.3 tests below.)
    try expectIntAllow("(0, eval)('var b = 4; b * b')", 16);
}

test "eval: function declared in eval does not leak to the global env" {
    // A top-level function declaration in eval'd code is part of the
    // eval's own variable environment, callable within the eval but
    // not installed on globalThis (§19.2.1.3 strict eval).
    try expectIntAllow("eval('function f(){ return 7; } f()')", 7);
    try expectIntAllow(
        \\eval('function g(){}');
        \\(typeof globalThis.g === 'undefined') ? 1 : 0;
    , 1);
}

test "eval: non-string argument returns unchanged" {
    // §19.2.1 step 2 — a non-String argument is returned as-is even
    // with the gate open.
    try expectIntAllow("eval(123)", 123);
}

test "eval: nested eval" {
    try expectIntAllow("eval('eval(\"2 + 5\")')", 7);
}

// ── §20.2.1.1.1 CreateDynamicFunction ───────────────────────────────

test "Function: string constructor builds a callable" {
    try expectIntAllow("new Function('a', 'b', 'return a + b')(2, 3)", 5);
}

test "Function: call form (no new) builds a callable too" {
    try expectIntAllow("Function('x', 'return x * x')(6)", 36);
}

test "Function: single combined parameter list" {
    // §20.2.1.1.1 — the parameter strings are joined with commas, so
    // a single `"a, b, c"` argument is equivalent to three.
    try expectIntAllow("new Function('a, b, c', 'return a + b + c')(1, 2, 3)", 6);
}

test "Function: zero-arg body" {
    try expectIntAllow("new Function('return 7')()", 7);
}

test "GeneratorFunction: string constructor yields" {
    try expectIntAllow(
        \\const GF = (function*(){}).constructor;
        \\const g = new GF('yield 11; yield 22')();
        \\g.next().value;
    , 11);
}

test "AsyncFunction: string constructor returns a promise" {
    // The async function returns a Promise; we just confirm the
    // constructor builds + invokes without throwing and the result is
    // an object (the Promise).
    const v = try evalAllow(
        \\const AF = (async function(){}).constructor;
        \\const p = new AF('return 1')();
        \\(typeof p === 'object' && p !== null) ? 1 : 0;
    );
    try testing.expect(v.isInt32() and v.asInt32() == 1);
}

// ── §19.2.1 direct eval ─────────────────────────────────────────────

test "eval: direct reads a caller function local" {
    // The acceptance criterion. `x` is a top-level `let` (global
    // lexical), `y` is the IIFE's function local — direct eval must
    // resolve both against the caller's environment.
    try expectIntAllow(
        \\let x = 1;
        \\(function () { let y = 2; return eval('x + y'); })();
    , 3);
}

test "eval: direct sees a caller var binding" {
    try expectIntAllow(
        \\function f() { var n = 10; return eval('n + 5'); }
        \\f();
    , 15);
}

test "eval: direct inherits caller this" {
    // §19.2.1 — direct eval inherits the caller's `this` binding.
    try expectIntAllow(
        \\const obj = { v: 8, m() { return eval('this.v'); } };
        \\obj.m();
    , 8);
}

test "eval: reassigned globalThis.eval is an ordinary call, not direct" {
    // §19.2.1.1 — direct eval requires the callee to be the %eval%
    // intrinsic. Reassigning `globalThis.eval` to another function
    // makes `eval(...)` an ordinary call to that value; the runtime
    // identity check on the `direct_eval` opcode catches this and
    // falls back. In strict-only Cynic this is the ONLY non-direct
    // path — `eval` can't be a binding name (`const eval` / param
    // `eval` are SyntaxErrors per §13.1.1), so a user can't shadow it
    // lexically. Uses an unhardened realm so `globalThis` is writable.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_eval = true;
    realm.hardened = false;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm,
        \\globalThis.eval = function (s) { return 99; };
        \\eval('this would SyntaxError as real eval ===');
    );
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalThrewUnexpectedly,
    };
    try testing.expect(v.isInt32() and v.asInt32() == 99);
}

// ── posture: gate stays closed by default (regression guard) ─────────

test "eval: gate closed (default) throws EvalError (host refusal)" {
    // §19.2.1.2 HostEnsureCanCompileStrings — when the host refuses
    // code generation from strings (eval off by default), the thrown
    // value is host-defined. Cynic raises EvalError, matching Node's
    // `--disallow-code-generation-from-strings` and browser CSP
    // (`unsafe-eval` blocked). The refusal happens BEFORE parsing, so
    // a non-string operand still returns unchanged (covered above).
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    // allow_eval defaults to false — no flip.
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm,
        \\let cls = 'none';
        \\try { eval('1'); } catch (e) { cls = e.constructor.name; }
        \\cls === 'EvalError' ? 1 : 0;
    );
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalGateClosedThrew,
    };
    try testing.expect(v.isInt32() and v.asInt32() == 1);
}

test "eval: gate closed Function(string) throws EvalError too" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm,
        \\let cls = 'none';
        \\try { new Function('return 1'); } catch (e) { cls = e.constructor.name; }
        \\cls === 'EvalError' ? 1 : 0;
    );
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalGateClosedThrew,
    };
    try testing.expect(v.isInt32() and v.asInt32() == 1);
}

// ── §13.2 / §14.x statement completion value ────────────────────────
//
// `eval(src)` returns the completion value of the evaluated
// StatementList (§19.2.1.3). Per §14.x runtime semantics + UpdateEmpty,
// a no-iteration loop / empty statement / `switch` with no executed
// clause yields `undefined` — NOT the leftover loop condition or
// `switch` discriminant. A value-producing body statement yields its
// value, and an empty statement after a value-producing one keeps the
// prior value (UpdateEmpty). Regression guard for the completion-
// register fix in the compiler. Mirrors test262
// `language/eval-code/*/cptn-nrml-empty-*`.

fn expectUndefinedAllow(source: []const u8) !void {
    const v = try evalAllow(source);
    if (!v.isUndefined()) {
        std.debug.print("expected undefined completion\n", .{});
        return error.EvalResultNotUndefined;
    }
}

test "eval completion: no-iteration while is undefined" {
    try expectUndefinedAllow("eval('while(false);')");
}

test "eval completion: no-iteration do-while is undefined" {
    try expectUndefinedAllow("eval('do ; while(false)')");
}

test "eval completion: untaken if is undefined" {
    try expectUndefinedAllow("eval('if (false) ;')");
}

test "eval completion: no-clause switch is undefined (not the discriminant)" {
    try expectUndefinedAllow("eval('switch(1){}')");
}

test "eval completion: no-iteration for is undefined" {
    try expectUndefinedAllow("eval('for(false;false;false);')");
}

test "eval completion: empty statement keeps prior value (UpdateEmpty)" {
    try expectIntAllow("eval('1; ;')", 1);
}

test "eval completion: loop body value, not the condition" {
    try expectIntAllow("eval('for (var i = 0; i < 1; i++) 42;')", 42);
}

test "eval completion: taken if yields its consequent value" {
    try expectIntAllow("eval('if (true) 7;')", 7);
}

test "eval completion: block yields its last statement value" {
    try expectIntAllow("eval('{ 9; }')", 9);
}

test "eval completion: trailing declaration leaves prior value" {
    // `5; var x = 99;` → 5 (the var declaration has empty completion).
    try expectIntAllow("eval('5; var x = 99;')", 5);
}

// ── §19.2.1.1 / §19.2.1.3 indirect-eval var environment ─────────────
//
// Indirect eval (`(0, eval)(src)`) is global code: a non-strict body's
// top-level `var` / function declarations bind on the realm's GLOBAL
// environment (§19.2.1 step 6 + §19.2.1.3), and §9.1.1.4.15/.16
// CanDeclareGlobalVar / CanDeclareGlobalFunction gate them (TypeError
// on failure). A body with a Use Strict Directive is a strict eval —
// its declarations stay in the eval's own variable environment. These
// guard the indirect-eval-var-env reversal. Mirrors test262
// `language/eval-code/indirect/{var-env-*,non-definable-global-*}`.

test "indirect eval: non-strict var binds on the global env" {
    try expectIntUnhardened("(0, eval)('var ieGlobalVar = 5'); ieGlobalVar", 5);
}

test "indirect eval: non-strict function binds on the global env" {
    try expectIntUnhardened("(0, eval)('function ieGlobalFn(){ return 7 }'); ieGlobalFn()", 7);
}

test "indirect eval: strict (use-strict) body keeps var eval-local" {
    // `ieStrictVar` must NOT leak to the global; reading it would be a
    // ReferenceError, so probe via `typeof`.
    try expectIntUnhardened(
        "(0, eval)(\"'use strict'; var ieStrictVar = 9\"); typeof ieStrictVar === 'undefined' ? 1 : 0",
        1,
    );
}

test "indirect eval: TypeError declaring a non-definable global function" {
    // §9.1.1.4.16 — `NaN` is a non-configurable, non-writable global,
    // so CanDeclareGlobalFunction('NaN') is false.
    try expectIntUnhardened(
        "var c = 'none'; try { (0, eval)('function NaN(){}'); } catch (e) { c = e.constructor.name; } c === 'TypeError' ? 1 : 0",
        1,
    );
}

test "indirect eval: TypeError declaring a var on a non-extensible global" {
    // §9.1.1.4.15 — a fresh var name on a non-extensible global object
    // is not definable.
    try expectIntUnhardened(
        "Object.preventExtensions(globalThis); var c = 'none'; try { (0, eval)('var ieUndefinable;'); } catch (e) { c = e.constructor.name; } c === 'TypeError' ? 1 : 0",
        1,
    );
}

test "eval: gate OPEN, genuine parse error still throws SyntaxError" {
    // §19.2.1 step 11 — once the gate is open and compilation proceeds,
    // a real parse failure in the evaluated source is a SyntaxError
    // (NOT the EvalError host refusal). The two are distinct: refusal
    // is a capability gate, SyntaxError is a parse outcome.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_eval = true;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm,
        \\let cls = 'none';
        \\try { eval('var = ;'); } catch (e) { cls = e.constructor.name; }
        \\cls === 'SyntaxError' ? 1 : 0;
    );
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalGateOpenParseThrew,
    };
    try testing.expect(v.isInt32() and v.asInt32() == 1);
}
