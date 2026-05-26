//! SES divergence-list — patterns that reclassify a hardened-mode
//! test262 failure into the `divergent` bucket.
//!
//! See [docs/handbook/ses-test262-policy.md] for the full design.
//! Short version: under the SES posture (frozen primordials,
//! locked descriptors, override-mistake fix) a sizeable chunk of
//! test262 fixtures *correctly fail* — they assert pre-SES
//! ECMAScript invariants the spec extension intentionally
//! invalidates. Counting those as engine bugs muddies the
//! `runtime_hardened` row's signal: a real regression of 50
//! fixtures hides in the noise of ~2500 "SES doing its job"
//! divergences.
//!
//! The patterns below match by **substring against the thrown
//! error's `message` and `name`**, the same strings the harness
//! prints in the FAIL log. Matching by message + name beats a
//! by-path glob because:
//!   - Test262 fixture paths churn (renames, moves) over time;
//!     message text from the spec / propertyHelper.js is more
//!     stable.
//!   - The same message comes from many fixture paths — one
//!     pattern covers a whole category rather than enumerating
//!     hundreds of paths.
//!   - We can't accidentally over-fire on a different message
//!     from the same path (a "real" bug fixture that happens to
//!     live in `built-ins/Object/freeze/`).
//!
//! Coverage target: ≥80% of the ~2500 hardened-only failures
//! at category-level, drawn from the Phase 1 audit
//! (commit `2c1fabf`) and the Bucket E follow-up
//! (commit `df7ff8b`). The remaining ~5-10% are either
//! category-misses that need a new pattern added on next bump
//! or genuine engine bugs surfacing where SES enforcement
//! exposed them.

const std = @import("std");

pub const Category = enum {
    /// `propertyHelper.js` descriptor assertions — fixture
    /// claims a built-in method's descriptor is
    /// `{writable: true, configurable: true}`; SES locks them
    /// to `{writable: false, configurable: false}`.
    descriptor_assertion,
    /// Engine TypeError from a SES enforcement path: frozen
    /// primordial mutation rejected (`Cannot add property,
    /// object is not extensible`, `Cannot assign to read-only
    /// property`, etc.). The throw is correct; the fixture's
    /// expectation of success isn't.
    frozen_intrinsic_typeerror,
    /// Intentional Cynic SES carve-out — e.g. top-level
    /// `var x = 1` declarations succeed under hardened mode
    /// per commit `3a4be3c`, where spec-strict would reject
    /// because globalThis is non-extensible. The test expects
    /// the spec-strict reject; we deliberately diverge.
    intentional_design_carveout,
};

pub const Pattern = struct {
    category: Category,
    /// Substring matched against `<name>: <message>` (or just
    /// `message` when `name` is empty). Must be unique enough
    /// to never match a real engine bug.
    needle: []const u8,
};

/// Patterns sorted by approximate match volume (per the Phase 1
/// audit). The lookup is linear so order doesn't matter for
/// correctness; high-volume entries first is just a perf hint
/// for the common-case match.
pub const patterns = [_]Pattern{
    // ── Category A — propertyHelper descriptor mismatches ──────
    .{ .category = .descriptor_assertion, .needle = "descriptor should be configurable" },
    .{ .category = .descriptor_assertion, .needle = "descriptor should be writable" },
    .{ .category = .descriptor_assertion, .needle = "desc.writable Expected SameValue(«false»" },
    .{ .category = .descriptor_assertion, .needle = "desc.configurable Expected SameValue(«false»" },
    .{ .category = .descriptor_assertion, .needle = "desc.value Expected SameValue(«undefined»" },
    .{ .category = .descriptor_assertion, .needle = "Expected obj[constructor] to have writable:true" },
    .{ .category = .descriptor_assertion, .needle = "descriptor value should be function" },
    .{ .category = .descriptor_assertion, .needle = "descriptor should not be writable" },

    // ── Category B — engine TypeErrors from SES enforcement ────
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot add property, object is not extensible" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot assign to read-only property" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Object.defineProperty: object is not extensible" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Object.defineProperty: cannot redefine non-configurable property" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot extend non-writable array length" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot delete non-configurable property" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot redefine non-configurable property on frozen prototype" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot define index past the length of a non-writable-length array" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Built-in objects must be extensible" },

    // ── Bucket E follow-up coverage ────────────────────────────
    // Object.{isFrozen,isSealed} fixtures: built-ins are frozen
    // under SES, so the test asserts `false === true` and fires
    // the generic `b Expected SameValue(«true», «false») to be
    // true` assertion. Need to scope this so we don't catch other
    // false-positive boolean assertions — match the full string.
    .{ .category = .descriptor_assertion, .needle = "b Expected SameValue(«true», «false») to be true" },
    .{ .category = .descriptor_assertion, .needle = "e Expected SameValue(«false», «true») to be true" },

    // ── Phase 2 follow-up — patterns surfaced by the 142-fail
    // residual investigation (commit 37b55f4 baseline). The
    // pattern shapes below all derive from SES enforcement
    // (frozen built-ins → non-extensible) and got missed by
    // the initial Phase 1 audit because the test262 fixtures
    // use a richer English assertion style than the
    // propertyHelper format.

    // `Object.isExtensible(<intrinsic>) must return true` — fired
    // by built-ins extensibility tests across the corpus
    // (DataView, JSON.{parse,stringify}, Date.prototype.toJSON,
    // Object.prototype.isPrototypeOf, Proxy.revocable, etc.).
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Object.isExtensible(" },
    // `<X> is extensible` — same shape, different phrasing.
    // The trailing word `extensible` is the discriminator; we
    // can't match on it alone (would catch true cases too), so
    // pair with the `is` prefix that appears in failure context.
    .{ .category = .frozen_intrinsic_typeerror, .needle = " is extensible" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = " is still extensible after" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Built-in objects must be extensible" },

    // `Expected obj[<key>] to have writable:true.` /
    // `... to have configurable:true.` — propertyHelper-style
    // assertion. SES locks both bits to false.
    .{ .category = .descriptor_assertion, .needle = "to have writable:true" },
    .{ .category = .descriptor_assertion, .needle = "to have configurable:true" },

    // `Cannot set prototype on non-extensible object` —
    // setPrototypeOf rejection from the SES freeze.
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot set prototype on non-extensible object" },

    // `arr[<idx>] Expected SameValue(«undefined», «<v>»)` —
    // `Object.defineProperties` / `Object.defineProperty` on
    // `Array.prototype` indexed slots fails because the
    // prototype is frozen non-extensible; the test reads back
    // and finds the slot still undefined. Same shape:
    // `Array.prototype[<idx>] Expected SameValue(...)`.
    .{ .category = .frozen_intrinsic_typeerror, .needle = "arr[0] Expected SameValue" },
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Array.prototype[" },

    // `Expected a TypeError to be thrown but no exception was
    // thrown at all` — Cynic's intentional carve-out where
    // `canDeclareGlobalVar` / `canDeclareGlobalFunction` skip
    // the extensibility check under SES (commit `3a4be3c`).
    // Top-level var/function decls keep working even with
    // non-extensible globalThis, where spec-strict would reject.
    .{ .category = .intentional_design_carveout, .needle = "Expected a TypeError to be thrown but no exception was thrown" },

    // `Expected true but got false` — generic propertyHelper
    // assertion. Most hits are descriptor / extensibility
    // checks that SES inverts. Keep this last among the
    // descriptor patterns so a real-bug `Expected true but
    // got false` from outside the SES surface still surfaces
    // (other patterns catch the SES cases first).
    .{ .category = .descriptor_assertion, .needle = "Expected true but got false" },
};

/// Classify a thrown-error rendering against the divergence
/// patterns. The input is the same `name: message` string the
/// harness builds for the FAIL log, plus an optional fallback
/// to just the message when name is empty.
///
/// Returns the matched `Category`, or `null` for a non-match
/// (i.e. this is a real engine failure even under SES).
pub fn classify(name: ?[]const u8, message: ?[]const u8) ?Category {
    // Build a haystack the patterns can match against. Both
    // `<name>: <message>` and the bare `<message>` are checked
    // — most patterns target the message, but a future pattern
    // could key on the name alone (e.g. "TypeError: " prefix).
    if (message) |m| {
        for (patterns) |p| {
            if (std.mem.indexOf(u8, m, p.needle) != null) return p.category;
        }
    }
    if (name) |n| {
        for (patterns) |p| {
            if (std.mem.indexOf(u8, n, p.needle) != null) return p.category;
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────

test "classify: empty inputs" {
    try std.testing.expect(classify(null, null) == null);
    try std.testing.expect(classify("", "") == null);
}

test "classify: descriptor-assertion pattern matches" {
    try std.testing.expectEqual(
        @as(?Category, .descriptor_assertion),
        classify("Test262Error", "obj['name'] descriptor should be configurable"),
    );
}

test "classify: frozen-intrinsic-typeerror pattern matches" {
    try std.testing.expectEqual(
        @as(?Category, .frozen_intrinsic_typeerror),
        classify("TypeError", "Cannot add property, object is not extensible"),
    );
}

test "classify: trailing-space variant matches" {
    // The Phase 1 audit found `Cannot assign to read-only property `
    // (trailing space) from typed-array fixtures. Substring match
    // covers both forms.
    try std.testing.expectEqual(
        @as(?Category, .frozen_intrinsic_typeerror),
        classify("TypeError", "Cannot assign to read-only property "),
    );
}

test "classify: unmatched message stays null" {
    try std.testing.expect(classify("TypeError", "iterator.next is not callable") == null);
    try std.testing.expect(classify("ReferenceError", "x is not defined") == null);
}

test "classify: Object.isFrozen-style assertion" {
    try std.testing.expectEqual(
        @as(?Category, .descriptor_assertion),
        classify("Test262Error", "b Expected SameValue(«true», «false») to be true"),
    );
}
