//! Body-audited by-design registry — the manual verdicts as data.
//!
//! The test262 failure classifier (`failClassOf` in `../test262.zig`) works
//! from a fixture's *path* and *frontmatter*: it can see `flags: [noStrict]`,
//! `features: [intl-normative-optional]`, and Annex-B builtins named in the
//! path, and it files everything else under `engine gaps`. But some fixtures
//! fail for a by-design reason that lives only in their *body* — a
//! `Function(...)` / `eval(...)` that produces sloppy-mode code, an Annex-B
//! surface used inside the test, or an outdated upstream fixture. Reading the
//! body and judging intent is a human step (see `docs/test262-gap-audit.md`).
//!
//! This file is that judgment, encoded as data so it stops going stale:
//! each entry maps an exact fixture path to the reason it fails by design.
//! The classifier consults it, reclassifies matched fixtures out of the raw
//! `engine gaps` count into their named reason, and leaves anything NOT listed
//! here in `engine gaps` — so a newly-added by-design fixture surfaces as an
//! "unaudited gap" for triage instead of silently inflating the count, and a
//! real engine bug is never auto-hidden.
//!
//! Matching is by EXACT path (not glob) on purpose: a new fixture in an
//! already-audited area must still show up for triage rather than inherit a
//! sibling's verdict. When the harness flags an unaudited gap, read the body,
//! then either fix the engine or add one line here with the reason.

const std = @import("std");

/// Why a fixture in the registry fails by design. Kept in sync with the
/// matching `FailClass` arms in `../test262.zig`.
pub const Reason = enum {
    /// Sloppy-mode semantics the frontmatter can't reveal: a `Function(...)` /
    /// `eval(...)` body that runs as non-strict code (sloppy `this` reaching
    /// the global, `var eval` / duplicate params being legal), a `-non-strict`
    /// fixture, or an in-body `with`. Cynic is strict-only by design.
    sloppy_body,
    /// An Annex-B surface used inside the fixture body — an Annex-B regex
    /// grammar form, a legacy `String.prototype.substr`, an `__proto__` /
    /// `__lookup*` poke in the test logic. Cynic ships no Annex B.
    annex_b_body,
    /// An outdated upstream fixture: Cynic is spec-correct, but the fixture
    /// predates a spec / data bump Cynic tracks (e.g. a CLDR version). Not a
    /// Cynic decline — a fixture that should be refreshed upstream.
    stale_fixture,
};

const Entry = struct { path: []const u8, reason: Reason };

/// The audited registry. One line per fixture; grouped by reason. Add an
/// entry when the harness flags an unaudited gap you have confirmed is
/// by-design (path relative to the corpus root, e.g. `built-ins/...`).
pub const entries = [_]Entry{
    // ── Outdated upstream fixtures (Cynic is correct) ──────────────────────
    // Emits the CLDR-42 narrow-no-break space (U+202F) before the dayPeriod;
    // the fixture still expects the pre-42 U+0020. §3 tracks unicode latest.
    .{ .path = "intl402/DateTimeFormat/prototype/format/numbering-system.js", .reason = .stale_fixture },

    // ── Annex-B surface used in the body ───────────────────────────────────
    // Fails only on `result.substr(-6)` (Annex-B String.prototype.substr); the
    // Temporal IANA-annotation parse it actually tests is correct.
    .{ .path = "intl402/Temporal/Instant/prototype/toString/timezone-string-datetime.js", .reason = .annex_b_body },

    // ── Sloppy-mode semantics not visible in frontmatter ───────────────────
    // `#!"use strict"` is `flags: [raw]`; the hashbang must NOT be a directive
    // prologue, so the body stays sloppy and its `with ({}) {}` must be legal.
    .{ .path = "language/comments/hashbang/use-strict.js", .reason = .sloppy_body },
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
    try std.testing.expect(lookup("built-ins/Array/prototype/map/this-is-not-object.js") == null);
}
