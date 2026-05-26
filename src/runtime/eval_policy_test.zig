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

test "ses-eval: global eval is absent by default" {
    try expectAbsent(
        \\typeof globalThis.eval === 'undefined' ? 1 : 0;
    );
}

test "ses-eval: bare reference to eval throws ReferenceError" {
    // Without `eval` installed as a global, naming it as a
    // bare identifier surfaces a ReferenceError per the global
    // env record's resolve-binding semantics.
    try expectAbsent(
        \\let ok = 0;
        \\try { eval; } catch (e) {
        \\  ok = (e instanceof ReferenceError) ? 1 : 0;
        \\}
        \\ok;
    );
}

test "ses-eval: new Function(string) throws TypeError" {
    // `Function` IS shipped as a constructor for the
    // binding-friendly bound-function shape, but the
    // string-body construction path is the SES carve-out.
    // Calling `new Function("body")` must throw — anything
    // else means the runtime-code-construction barrier
    // has leaked.
    try expectAbsent(
        \\let ok = 0;
        \\try {
        \\  new Function("return 1");
        \\} catch (e) {
        \\  ok = (e instanceof TypeError) ? 1 : 0;
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
        \\  ok = (e instanceof TypeError) ? 1 : 0;
        \\}
        \\ok;
    );
}
