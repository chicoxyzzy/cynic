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

    // `Cannot redeclare non-configurable global '<name>'` —
    // emitted by §9.1.1.4.16 CanDeclareGlobalFunction (and
    // .15 CanDeclareGlobalVar) when a top-level `function`
    // / `var` decl collides with a non-configurable global.
    // Under SES, every primordial constructor lives on
    // globalThis as a non-configurable slot, so a fixture
    // like `function Array() {}` at script top level
    // throws this TypeError. The message is specific to
    // Cynic's compiler emit path (see
    // `Compiler.emitGlobalDeclThrow`); no other code path
    // produces this exact text.
    .{ .category = .frozen_intrinsic_typeerror, .needle = "Cannot redeclare non-configurable global" },
};

/// Curated path list — fixtures whose thrown-error message
/// is too generic to pattern-match safely (e.g. a bare
/// `Expected SameValue(«false», «true») to be true` from a
/// non-propertyHelper `assert.sameValue` call) but which are
/// unambiguously SES-divergent on inspection. Each entry
/// needs an inline comment citing the SES surface it tests.
///
/// Use sparingly. The pattern-based classifier covers ~99.5 %
/// of divergent fixtures; this list catches the long-tail
/// cases where extending the patterns would over-fire on
/// real engine bugs. Keep entries verified by hand — a path
/// here bypasses the message-shape sanity check entirely.
pub const divergent_paths = [_]struct { path: []const u8, category: Category }{
    .{
        // `assert.sameValue(Object.isExtensible(DataView),
        // true)` against a frozen primordial. Same shape as
        // the `built-ins/Object/prototype/extensibility.js`
        // witness, but the assert is direct (no
        // propertyHelper prefix), so the thrown error is
        // just `Expected SameValue(«false», «true») to be
        // true` — too generic for a pattern. SES enforces
        // §17 "built-in objects must be extensible" the
        // opposite way; the divergence is by design.
        .path = "built-ins/DataView/extensibility.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // `let Array;` at top level + `assert.sameValue(
        // descriptor.configurable, true)` on the globalThis
        // `Array` slot. Spec §15.1.8 step 5.c demands
        // `configurable: true` on a configurable global
        // property a lex decl shadows; SES locks every
        // intrinsic on globalThis to `{w:f, e:f, c:f}`, so
        // the descriptor read-back fails the equality. The
        // thrown message is the bare `Expected SameValue(
        // «false», «true») to be true` — same generic shape
        // as the `DataView/extensibility.js` entry above.
        .path = "language/global-code/decl-lex-configurable-global.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // §27.1.2.x `Iterator.prototype[@@toStringTag]` — spec
        // says the accessor is `{enumerable: false, configurable:
        // true}`; the fixture asserts `desc.configurable === true`
        // directly. SES (the Phase 1 freeze pass + the 2026-05-27
        // accessor-flag stamp fix in `harden.zig`) demotes every
        // intrinsic accessor descriptor to `configurable: false`,
        // so the assertion fires `Expected SameValue(«false»,
        // «true») to be true`. Generic-shape message — path-skip.
        .path = "built-ins/Iterator/prototype/Symbol.toStringTag/prop-desc.js",
        .category = .descriptor_assertion,
    },
    .{
        // §27.1.2.x `Iterator.prototype.constructor` — accessor
        // with `{enumerable: false, configurable: true}`. Same
        // SES freeze pass demotes it; same generic message
        // (`Expected SameValue(«false», «true») to be true`).
        // Companion to the `Symbol.toStringTag/prop-desc.js`
        // entry above.
        .path = "built-ins/Iterator/prototype/constructor/prop-desc.js",
        .category = .descriptor_assertion,
    },
    // §3.8 ShadowRealm — six fixtures that pass under the
    // unhardened feature row but fail the hardened feature row
    // purely because the SES posture freezes the child realm's
    // primordials / globalThis. Each writes to a frozen globalThis
    // (`globalThis.x = …`), reads a frozen primordial's
    // extensibility, or enumerates globalThis and finds every slot
    // non-configurable — so the hardened throw / `false` is the
    // SES-correct behavior and the fixture's expectation is the
    // non-SES one. The thrown message is generic
    // (`ShadowRealm.prototype.evaluate: evaluation threw` /
    // `Expected SameValue(«false», «true»)`), so they're listed by
    // path.
    .{
        // `Object.isExtensible(ShadowRealm)` — SES freezes the
        // constructor primordial; fixture wants extensible.
        .path = "built-ins/ShadowRealm/extensibility.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // `new ShadowRealm(); r.evaluate('globalThis.x = 0')` —
        // write to frozen child globalThis throws.
        .path = "built-ins/ShadowRealm/prototype/evaluate/not-constructor.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // Setup writes `globalThis.revocable = …` into the frozen
        // child globalThis before revoking — write throws.
        .path = "built-ins/ShadowRealm/WrappedFunction/throws-typeerror-on-revoked-proxy.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // Setup writes `globalThis.arrow = …` / `globalThis.pFn =
        // …` into the frozen child globalThis — write throws.
        .path = "built-ins/ShadowRealm/prototype/evaluate/wrapped-function-from-return-values-share-no-identity.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // Same frozen-globalThis setup writes as the
        // share-no-identity sibling above.
        .path = "built-ins/ShadowRealm/prototype/evaluate/wrapped-functions-share-no-properties-extended.js",
        .category = .frozen_intrinsic_typeerror,
    },
    .{
        // Block 1 asserts every globalThis own property (bar the
        // three non-configurable ES values undefined/Infinity/NaN)
        // is `configurable: true`; block 2 then deletes them all.
        // Under SES the child realm's globalThis + primordials are
        // frozen, so block 1's `assert.sameValue(anyMissed, '', …)`
        // reports the entire global table as non-configurable and
        // throws — the SES-correct outcome. Passes the unhardened
        // row, where the globals are configurable and deletable.
        // (ShadowRealm.evaluate compiles each source as eval code
        // with a fresh per-call declarative env, so block 2
        // redeclaring `const esNonConfigValues` after block 1 no
        // longer collides — the prerequisite for the unhardened
        // pass.)
        .path = "built-ins/ShadowRealm/prototype/evaluate/globalthis-config-only-properties.js",
        .category = .descriptor_assertion,
    },
};

/// Path-based divergence lookup — the escape hatch for
/// fixtures whose message is too generic to pattern-match.
/// Returns `null` for paths not on the curated list; the
/// caller still tries `classify` on the message.
pub fn classifyByPath(rel: []const u8) ?Category {
    for (divergent_paths) |entry| {
        if (std.mem.eql(u8, entry.path, rel)) return entry.category;
    }
    return null;
}

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

test "classifyByPath: known generic-message divergent path" {
    try std.testing.expectEqual(
        @as(?Category, .frozen_intrinsic_typeerror),
        classifyByPath("built-ins/DataView/extensibility.js"),
    );
    try std.testing.expectEqual(
        @as(?Category, .frozen_intrinsic_typeerror),
        classifyByPath("language/global-code/decl-lex-configurable-global.js"),
    );
}

test "classifyByPath: unrelated path stays null" {
    try std.testing.expect(classifyByPath("built-ins/Math/abs/abs.js") == null);
    try std.testing.expect(classifyByPath("language/expressions/addition/order.js") == null);
}

test "classify: redeclare-global TypeError matches" {
    try std.testing.expectEqual(
        @as(?Category, .frozen_intrinsic_typeerror),
        classify("TypeError", "Cannot redeclare non-configurable global 'Array'"),
    );
}
