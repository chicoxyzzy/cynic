//! Body-audited by-design registry — the manual verdicts as data.
//!
//! The test262 failure classifier (`failClassOf` in `../test262.zig`) works
//! from a fixture's *path* and *frontmatter*: it sees `flags: [noStrict]`,
//! `features: [intl-normative-optional]`, and Annex-B builtins named in the
//! path, and files everything else under `engine gaps`. But some fixtures fail
//! for a by-design reason that lives only in their *body* — a `Function(...)` /
//! `eval(...)` that produces sloppy-mode code, an Annex-B surface used inside
//! the test, or an outdated upstream fixture. Reading the body and judging
//! intent is a human step; this file is that judgment, encoded as data so it
//! stops going stale.
//!
//! Each entry maps an EXACT fixture path to the reason it fails by design. The
//! classifier consults it, reclassifies matched fixtures out of the raw
//! `engine gaps` count into their named reason, and leaves anything NOT listed
//! here in `engine gaps` — so a newly-added by-design fixture surfaces as an
//! "unaudited gap" for triage (`--list-gaps`) instead of silently inflating
//! the count, and a real engine bug is never auto-hidden. Matching is by exact
//! path (not glob) so a new fixture in an audited area still shows up.
//!
//! When the harness flags an unaudited gap: read the body, then either fix the
//! engine or add one line here with the reason. See `docs/test262-gap-audit.md`
//! for the methodology.

const std = @import("std");

/// Why a fixture in the registry fails by design. Kept in sync with the
/// matching `FailClass` arms in `../test262.zig`.
pub const Reason = enum {
    /// Sloppy-mode semantics the frontmatter can't reveal: a `Function(...)` /
    /// `eval(...)` body that runs as non-strict code (sloppy `this` reaching
    /// the global via `Function('return this')()`, `var eval` / `eval = 42`
    /// being legal), a `-non-strict` fixture, or an in-body `with`. Cynic is
    /// strict-only by design.
    sloppy_body,
    /// An Annex-B surface used inside the fixture body — an Annex-B regex
    /// identity escape, a legacy `String.prototype.substr`, an `__proto__` /
    /// `__lookup{Getter,Setter}__` poke in the test logic. Cynic ships no
    /// Annex B.
    annex_b_body,
    /// An outdated upstream fixture: Cynic is spec-correct, but the fixture
    /// predates a spec / data bump Cynic tracks (e.g. a CLDR version). Not a
    /// Cynic decline — a fixture that should be refreshed upstream.
    stale_fixture,
};

const Entry = struct { path: []const u8, reason: Reason };

/// The audited registry — one line per fixture, grouped by reason. Populated
/// from a `--list-gaps` dump, each verdict confirmed by reading the body.
pub const entries = [_]Entry{
    // ── Outdated upstream fixtures (Cynic is spec-correct) ─────────────────
    .{ .path = "intl402/DateTimeFormat/prototype/format/numbering-system.js", .reason = .stale_fixture },

    // ── Annex-B surface used inside the fixture body ───────────────────────
    .{ .path = "intl402/Temporal/Instant/prototype/toString/timezone-string-datetime.js", .reason = .annex_b_body },
    .{ .path = "built-ins/TypedArrayConstructors/ctors/no-species.js", .reason = .annex_b_body },
    .{ .path = "language/expressions/class/elements/private-getter-is-not-a-own-property.js", .reason = .annex_b_body },
    .{ .path = "language/expressions/class/elements/private-setter-is-not-a-own-property.js", .reason = .annex_b_body },
    .{ .path = "language/literals/regexp/S7.8.5_A1.4_T2.js", .reason = .annex_b_body },
    .{ .path = "language/literals/regexp/S7.8.5_A2.4_T2.js", .reason = .annex_b_body },
    .{ .path = "language/statements/class/elements/private-getter-is-not-a-own-property.js", .reason = .annex_b_body },
    .{ .path = "language/statements/class/elements/private-setter-is-not-a-own-property.js", .reason = .annex_b_body },

    // ── Sloppy-mode semantics not visible in frontmatter ───────────────────
    .{ .path = "language/comments/hashbang/use-strict.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-2-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-4-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-6-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-7-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-8-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/15.3.2.1-11-9-s.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3.2.1_A3_T8.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3.5_A2_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3.5_A2_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3_A3_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3_A3_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3_A3_T5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/S15.3_A3_T6.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/call-bind-this-realm-undef.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/call-bind-this-realm-value.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/length/S15.3.5.1_A1_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/length/S15.3.5.1_A2_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/length/S15.3.5.1_A3_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/length/S15.3.5.1_A4_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T4.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T7.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A3_T9.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A5_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A5_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A7_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A7_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A7_T5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A7_T7.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/apply/S15.3.4.3_A7_T8.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T3.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T4.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T7.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A3_T9.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A5_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A5_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A6_T1.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A6_T2.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A6_T5.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A6_T7.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Function/prototype/call/S15.3.4.4_A6_T8.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Object/entries/tamper-with-global-object.js", .reason = .sloppy_body },
    .{ .path = "built-ins/Object/values/tamper-with-global-object.js", .reason = .sloppy_body },
    .{ .path = "language/eval-code/indirect/always-non-strict.js", .reason = .sloppy_body },
    .{ .path = "language/eval-code/indirect/var-env-global-lex-non-strict.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/eval-rqstd-once.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/update-to-dynamic-import.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-arrow-assignment-expression-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-arrow-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-arrow-function-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-arrow-function-return-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-function-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-function-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-function-return-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-gen-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-async-gen-return-await-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-block-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-do-while-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-else-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-function-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-if-braceless-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-if-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/nested-while-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/syntax-nested-block-labeled-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/dynamic-import/usage/top-level-import-then-eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/expressions/this/S11.1.1_A4.1.js", .reason = .sloppy_body },
    .{ .path = "language/function-code/10.4.3-1-13-s.js", .reason = .sloppy_body },
    .{ .path = "language/function-code/10.4.3-1-13gs.js", .reason = .sloppy_body },
    .{ .path = "language/function-code/10.4.3-1-15-s.js", .reason = .sloppy_body },
    .{ .path = "language/function-code/10.4.3-1-15gs.js", .reason = .sloppy_body },
    .{ .path = "language/module-code/eval-gtbndng-indirect-update-as.js", .reason = .sloppy_body },
    .{ .path = "language/module-code/eval-gtbndng-indirect-update.js", .reason = .sloppy_body },
    .{ .path = "language/module-code/eval-rqstd-once.js", .reason = .sloppy_body },
    .{ .path = "language/module-code/eval-rqstd-order.js", .reason = .sloppy_body },
    .{ .path = "language/module-code/instn-same-global.js", .reason = .sloppy_body },
    .{ .path = "language/statements/function/13.0-12-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/function/13.0_4-17gs.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-10-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-16-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-17-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-20-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-21-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-5-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-6-s.js", .reason = .sloppy_body },
    .{ .path = "language/statements/variable/12.2.1-9-s.js", .reason = .sloppy_body },
};

/// Look up a fixture's by-design reason, or null if it is not audited (in
/// which case a failure stays an `engine gap` for triage). Linear scan —
/// consulted only for the handful of failures that reach the `gap` fallback,
/// so it is never hot.
pub fn lookup(rel: []const u8) ?Reason {
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, rel)) return e.reason;
    }
    return null;
}

test "gap_audit: registered paths resolve, unregistered do not" {
    try std.testing.expectEqual(Reason.stale_fixture, lookup("intl402/DateTimeFormat/prototype/format/numbering-system.js").?);
    try std.testing.expectEqual(Reason.sloppy_body, lookup("language/comments/hashbang/use-strict.js").?);
    try std.testing.expectEqual(Reason.annex_b_body, lookup("built-ins/TypedArrayConstructors/ctors/no-species.js").?);
    // Real / uncertain gaps are intentionally NOT registered — they stay a gap.
    try std.testing.expect(lookup("built-ins/String/prototype/split/separator-regexp.js") == null);
}
