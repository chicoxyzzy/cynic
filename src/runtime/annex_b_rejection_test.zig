//! Cynic-authored Annex B negative coverage.
//!
//! AGENTS.md commits Cynic to "Annex B in its entirety — out, with
//! one acknowledged exception (regex grammar §B.1.4)." The test262
//! corpus doesn't carry positive "feature is absent" assertions —
//! Annex B is normative for browsers, optional elsewhere, so the
//! spec doesn't mandate absence. The fixtures under `annexB/` test
//! that the feature *works* (which Cynic correctly fails), but
//! that's negative-of-presence, not positive-of-absence.
//!
//! This file is the latter. Each test asserts a specific Annex B
//! surface Cynic deliberately doesn't ship is observably absent.
//! A regression — Cynic accidentally installing one of these —
//! trips the test cleanly, regardless of how the absent feature
//! happened to creep in.
//!
//! Scope mirrors AGENTS.md's enumeration of what Annex B Cynic
//! drops (§B.2 + §B.1.1 parser rejection):
//!   - §B.2.3 String.prototype HTML wrappers + `substr` /
//!     `trimLeft` / `trimRight`.
//!   - §B.2.4 Date.prototype `getYear` / `setYear` / `toGMTString`.
//!   - §B.2.2.1 Object.prototype `__proto__` accessor.
//!   - §B.2.2 Object.prototype `__define{Getter,Setter}__` /
//!     `__lookup{Getter,Setter}__`.
//!   - §B.2.1 global `escape` / `unescape`.
//!   - §B.2.6 RegExp legacy statics (`RegExp.$1`–`$9`,
//!     `RegExp.input`, `lastMatch`, `lastParen`, `leftContext`,
//!     `rightContext`).
//!   - §B.1.1 legacy octal integer literal (`07`) — parser-
//!     rejected in strict mode.
//!
//! All tests run under the SES posture (hardened default — the
//! `installBuiltins` helper installs every realm intrinsic + the
//! SES freeze pass). The same assertions hold under
//! `--unhardened`; the test262 harness's `--phase=unhardened`
//! confirms continuity.
//!
//! Eval-policy tests (`eval`, `new Function(string)`) live in a
//! sibling file `eval_policy_test.zig` — those are a separate
//! Cynic commitment (SES alignment), not Annex B.
//!
//! See [docs/handbook/ses-test262-policy.md] §"Annex B negative
//! coverage" for the design.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

/// Evaluate `source` against a fresh realm with full builtins +
/// hardened SES posture, then assert the script's completion
/// value is `1` (the convention used by every test here for
/// "the absence assertion passed"). A `0` (or a thrown
/// completion) means the Annex B surface is observably present
/// and the regression has landed.
fn expectAbsent(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    const v = switch (outcome) {
        .value, .yielded => |val| val,
        .thrown => return error.AnnexBFeatureUnexpectedlyPresent,
    };
    if (!v.isInt32()) return error.AnnexBAssertionMisformed;
    if (v.asInt32() != 1) return error.AnnexBFeatureUnexpectedlyPresent;
}

// ── String.prototype Annex B methods ────────────────────────────────

test "annex-b: String.prototype.substr is absent" {
    try expectAbsent(
        \\typeof "".substr === 'undefined' ? 1 : 0;
    );
}

test "annex-b: String.prototype.trimLeft is absent" {
    try expectAbsent(
        \\typeof "".trimLeft === 'undefined' ? 1 : 0;
    );
}

test "annex-b: String.prototype.trimRight is absent" {
    try expectAbsent(
        \\typeof "".trimRight === 'undefined' ? 1 : 0;
    );
}

test "annex-b: String.prototype HTML wrappers all absent" {
    // §B.2.3 — the full HTML method wrapper family. Test them
    // as a set so a regression that ships one ships them all
    // (the install sites tend to come in pairs / lists).
    try expectAbsent(
        \\const html = ['anchor','big','blink','bold','fixed',
        \\              'fontcolor','fontsize','italics','link',
        \\              'small','strike','sub','sup'];
        \\html.every(m => typeof ""[m] === 'undefined') ? 1 : 0;
    );
}

// ── Date.prototype Annex B methods ──────────────────────────────────

test "annex-b: Date.prototype.getYear is absent" {
    try expectAbsent(
        \\typeof Date.prototype.getYear === 'undefined' ? 1 : 0;
    );
}

test "annex-b: Date.prototype.setYear is absent" {
    try expectAbsent(
        \\typeof Date.prototype.setYear === 'undefined' ? 1 : 0;
    );
}

test "annex-b: Date.prototype.toGMTString is absent" {
    try expectAbsent(
        \\typeof Date.prototype.toGMTString === 'undefined' ? 1 : 0;
    );
}

// ── Object.prototype Annex B accessors + methods ────────────────────

test "annex-b: Object.prototype.__proto__ accessor is absent" {
    // §B.2.2.1 — the `__proto__` accessor isn't installed.
    // Object.getOwnPropertyDescriptor returns `undefined`, NOT
    // an accessor descriptor with `get` / `set`. (User code can
    // still mention `__proto__` as an object-literal key — that's
    // a separate spec form Cynic supports — but it's not an
    // accessor on Object.prototype.)
    try expectAbsent(
        \\Object.getOwnPropertyDescriptor(Object.prototype, '__proto__') === undefined ? 1 : 0;
    );
}

test "annex-b: Object.prototype.__defineGetter__ is absent" {
    try expectAbsent(
        \\typeof Object.prototype.__defineGetter__ === 'undefined' ? 1 : 0;
    );
}

test "annex-b: Object.prototype.__defineSetter__ is absent" {
    try expectAbsent(
        \\typeof Object.prototype.__defineSetter__ === 'undefined' ? 1 : 0;
    );
}

test "annex-b: Object.prototype.__lookupGetter__ is absent" {
    try expectAbsent(
        \\typeof Object.prototype.__lookupGetter__ === 'undefined' ? 1 : 0;
    );
}

test "annex-b: Object.prototype.__lookupSetter__ is absent" {
    try expectAbsent(
        \\typeof Object.prototype.__lookupSetter__ === 'undefined' ? 1 : 0;
    );
}

// ── Global Annex B functions ────────────────────────────────────────

test "annex-b: global escape is absent" {
    try expectAbsent(
        \\typeof escape === 'undefined' ? 1 : 0;
    );
}

test "annex-b: global unescape is absent" {
    try expectAbsent(
        \\typeof unescape === 'undefined' ? 1 : 0;
    );
}

test "annex-b: globalThis.escape / unescape both absent" {
    try expectAbsent(
        \\(typeof globalThis.escape === 'undefined' &&
        \\ typeof globalThis.unescape === 'undefined') ? 1 : 0;
    );
}

// ── RegExp legacy statics ───────────────────────────────────────────

test "annex-b: RegExp.$1 through RegExp.$9 are absent" {
    // §B.2.6 — `RegExp.$N` / `RegExp.input` / `RegExp.lastMatch`
    // etc. legacy globals. None installed.
    try expectAbsent(
        \\const dollars = ['$1','$2','$3','$4','$5','$6','$7','$8','$9'];
        \\dollars.every(k => typeof RegExp[k] === 'undefined') ? 1 : 0;
    );
}

test "annex-b: RegExp.input / RegExp.$_ are absent" {
    try expectAbsent(
        \\(typeof RegExp.input === 'undefined' &&
        \\ typeof RegExp['$_'] === 'undefined') ? 1 : 0;
    );
}

test "annex-b: RegExp.lastMatch / RegExp['$&'] are absent" {
    try expectAbsent(
        \\(typeof RegExp.lastMatch === 'undefined' &&
        \\ typeof RegExp['$&'] === 'undefined') ? 1 : 0;
    );
}

test "annex-b: RegExp.lastParen / RegExp['$+'] are absent" {
    try expectAbsent(
        \\(typeof RegExp.lastParen === 'undefined' &&
        \\ typeof RegExp['$+'] === 'undefined') ? 1 : 0;
    );
}

test "annex-b: RegExp.leftContext / RegExp.rightContext are absent" {
    try expectAbsent(
        \\(typeof RegExp.leftContext === 'undefined' &&
        \\ typeof RegExp.rightContext === 'undefined') ? 1 : 0;
    );
}

// ── Sloppy-mode grammar (parser-rejected at compile time) ──────────

test "annex-b: legacy octal literal `07` rejected by parser in strict" {
    // §B.1.1 LegacyOctalIntegerLiteral — rejected in strict mode
    // per §12.8.3. Cynic is strict-only, so the parser rejects
    // unconditionally. `evaluateScript` returns
    // `error.ParseError` (not a runtime throw). The exact reject
    // mechanism lives in `parser/parser_test.zig`; this test
    // documents the user-visible behaviour: a script containing
    // a legacy octal literal doesn't run.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const result = lantern.evaluateScript(testing.allocator, &realm, "var x = 07;");
    try testing.expectError(error.ParseError, result);
}

// ── Sanity / framework checks ───────────────────────────────────────

test "annex-b: framework — known-present feature trips control assertion" {
    // Confidence check on the assertion shape itself. A *known
    // present* feature (`String.prototype.slice`) — assert it's
    // typeof 'function' — should return 1 from `expectAbsent`.
    // If the test infrastructure ever breaks this returns 0
    // (and the test fails), catching framework regressions
    // independently of any engine change.
    try expectAbsent(
        \\typeof "".slice === 'function' ? 1 : 0;
    );
}
