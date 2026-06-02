//! Cynic-authored SES eval-policy negative coverage.
//!
//! Per AGENTS.md "SES-aligned by default", Cynic doesn't ship
//! `eval()`, `new Function(string)`, `new GeneratorFunction(string)`,
//! or `new AsyncFunction(string)` by default. This is a separate
//! commitment from the Annex B drop (those are documented in §B
//! of ECMA-262; eval is normative §19.2 + §20.3.1 that we
//! deliberately omit). Aligns with SES / Hardened JavaScript and
//! removes a major optimization fence.
//!
//! Sibling file `annex_b_rejection_test.zig` covers the Annex B
//! surface; this file is the eval-shaped runtime-code-construction
//! boundary. Both files exist for the same reason: test262 doesn't
//! carry assertions of *absence*, so without these we have no
//! automated guard against an accidental install. The risk is
//! lower than for the active Annex B install sites (eval requires
//! more involved engine work to add than a single
//! `installNativeMethod` call), but the test is cheap and pins
//! the policy commitment.
//!
//! When the planned `--allow=eval` opt-in lands (see
//! [docs/ses-alignment.md] §Phase 4), update these tests to
//! check the **default** posture only — `--allow=eval` is
//! explicitly out of scope for the "Cynic ships strict-only,
//! SES-aligned" guarantee.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

/// Same shape as the Annex B helper — evaluate, assert the
/// completion is `1`. A `0` or thrown completion means the
/// eval-policy commitment has slipped.
fn expectAbsent(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalPolicyFeatureUnexpectedlyPresent,
    };
    if (!v.isInt32()) return error.EvalPolicyAssertionMisformed;
    if (v.asInt32() != 1) return error.EvalPolicyFeatureUnexpectedlyPresent;
}

test "ses-eval: global eval is installed as a throwing stub" {
    // Cynic installs `eval` as a *throwing* native rather than
    // omitting the binding entirely — Sputnik fixtures (S10.2.3_*)
    // and a handful of strict-mode global-property tests probe
    // `globalThis.eval` (e.g. `eval === null`) and would
    // ReferenceError on a missing binding rather than testing the
    // shape they actually care about. `typeof eval === "function"`
    // is the observable surface; invoking it throws — see
    // `globalEvalNotSupported` in `src/runtime/intrinsics.zig`.
    try expectAbsent(
        \\(typeof globalThis.eval === 'function') ? 1 : 0;
    );
}

test "ses-eval: invoking eval throws" {
    // The stub raises immediately so user code can't construct
    // code from a string. The observable guarantee for the
    // SES policy commitment is just "the call does not return
    // normally"; we don't pin the throw class.
    try expectAbsent(
        \\let ok = 0;
        \\try { eval("1"); } catch (e) { ok = 1; }
        \\ok;
    );
}

test "ses-eval: new Function(string) throws" {
    // `Function` IS shipped as a constructor for the
    // binding-friendly bound-function shape (so `Function.
    // prototype.bind(...)` and friends work), but the string-
    // body construction path is gated by `--allow=eval` per
    // AGENTS.md. With the gate closed the throw class is EvalError
    // (§19.2.1.2 HostEnsureCanCompileStrings host refusal — see
    // `eval_test.zig` for the type-pinning tests); the guarantee
    // for the policy commitment is just "the call does not return".
    try expectAbsent(
        \\let ok = 0;
        \\try {
        \\  new Function("return 1");
        \\} catch (e) {
        \\  ok = 1;
        \\}
        \\ok;
    );
}

test "ses-eval: Function call form rejects string body too" {
    // `Function("body")` (call form) should fail the same way
    // — Cynic's Function constructor doesn't grow a code-from-
    // string compile path in either invocation shape.
    try expectAbsent(
        \\let ok = 0;
        \\try {
        \\  Function("return 1");
        \\} catch (e) {
        \\  ok = 1;
        \\}
        \\ok;
    );
}

/// Evaluate `source` against a realm with `--allow=eval` set
/// (`realm.allow_eval = true`) and assert the completion is `1`.
fn expectAbsentAllowEval(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    // `--allow=eval` opens the policy gate before install.
    realm.allow_eval = true;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.EvalPolicyFeatureUnexpectedlyPresent,
    };
    if (!v.isInt32()) return error.EvalPolicyAssertionMisformed;
    if (v.asInt32() != 1) return error.EvalPolicyFeatureUnexpectedlyPresent;
}

test "ses-eval: --allow=eval opens the gate and eval evaluates" {
    // `--allow=eval` opens the SES policy gate AND the eval engine is
    // now implemented (§19.2.1), so `eval("1")` returns 1 rather than
    // refusing. The positive engine behaviour is covered in depth by
    // `eval_test.zig`; this pins the policy *transition* — the same
    // realm that refuses with the gate closed (above) now runs source.
    try expectAbsentAllowEval(
        \\eval("1");
    );
}

test "ses-eval: --allow=eval enables the dynamic Function constructor" {
    // §20.2.1.1.1 CreateDynamicFunction — with the gate open,
    // `new Function("return 1")()` builds + invokes a real function.
    try expectAbsentAllowEval(
        \\new Function("return 1")();
    );
}
