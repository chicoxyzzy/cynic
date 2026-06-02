//! Skip rules for the test262 harness — the single source of truth for
//! which fixtures Cynic does not run at all.
//!
//! The harness scores every fixture as a binary **pass** or **fail**
//! under one posture (`--unhardened --allow=eval`). There is no
//! "expected fail" / policy reclassification and no in-corpus "skip"
//! bucket: a fixture that fails for any reason — Annex B, no Intl,
//! strict-only, SES, whatever — counts as a plain fail. So this file
//! has only two jobs, each a `pub fn` the harness calls:
//!
//!   1. `pathIsSkipped` — corpus-walk exclusions. `harness/` (preamble
//!      helpers, not fixtures), `staging/` (upstream WIP), and the whole
//!      `annexB/` tree (browser-only, out of scope per AGENTS.md).
//!      Filtered before frontmatter parsing; never enter `total`.
//!
//!   2. `featureIsUnimplementedProposal` — pre-Stage-4 proposals Cynic
//!      hasn't implemented (decorators, import-defer, …). Dropped from
//!      `total` so the headline can't decay as TC39 lands proposal
//!      fixtures upstream. (Proposals Cynic *has* shipped —
//!      joint-iteration, ShadowRealm — are kept out of the main rows
//!      by the harness's per-phase feature-tag gate, not by this file,
//!      and get their own dedicated `feature:<name>` scoreboard.)

const std = @import("std");

// ════════════════════════════════════════════════════════════════════
//   Corpus-walk-time exclusions
// ════════════════════════════════════════════════════════════════════
//
// Universal path-prefix exclusions (relative to
// `vendor/test262/test/`). Tests matching any prefix are skipped
// before frontmatter parsing — they're harness / staging-grounds /
// browser-only concerns and never enter `total`.

pub const corpus_excluded_prefixes = [_][]const u8{
    // Harness helpers (sta.js / assert.js) — preamble files, not test
    // fixtures. Always filtered before frontmatter parsing.
    "harness/",
    // Staging ground — upstream-WIP fixtures that aren't required to
    // be portable; not part of any published edition.
    "staging/",
    // Annex B — Cynic targets edge runtimes (Workers / Deno / server
    // JS), not browsers, so the whole `annexB/` tree is out of scope
    // per AGENTS.md / ROADMAP.md (it's duplicate coverage of main-spec
    // items already tested via the main path). Excluded from the
    // corpus rather than run-and-failed.
    "annexB/",
};

// ════════════════════════════════════════════════════════════════════
//   Pre-Stage-4 proposals (dropped from the corpus denominator)
// ════════════════════════════════════════════════════════════════════
//
// TC39 proposals not yet in a published edition. Their fixtures are
// dropped from `total` so the headline can't decay as TC39 lands new
// proposal fixtures upstream. Reviewed each release cycle; an entry
// lifts once the proposal reaches Stage 4 (it's then specced and
// re-enters `total`) or Cynic implements it (it graduates to a
// dedicated `feature:<name>` phase).

pub const stage_maturity_features = [_][]const u8{
    "decorators", // Stage 3 — class decorator grammar.
    "import-defer", // Stage 3 — `import defer * as ns from "…"`.
    "source-phase-imports", // Stage 3 — `import source x from "…"`.
    // Stage 3 `import-bytes` — `import data from "./x.png" with {
    // type: "bytes" }` returns a (frozen) Uint8Array. Needs the
    // immutable-arraybuffer (Stage 2.7) substrate too.
    "import-bytes",
    // Stage 2.7 — `new ArrayBuffer(len, { maxByteLength, immutable: true })`.
    // Substrate for `import-bytes` (frozen Uint8Array) and the
    // structured-clone / postMessage-zero-copy story; no proposal-
    // text-faithful runtime path yet.
    "immutable-arraybuffer",
    // Stage 2 `await-dictionary` — `Promise.allKeyed` /
    // `Promise.allSettledKeyed` (dictionary-shaped aggregators).
    "await-dictionary",
};

// Standardised features blocked on a vendored matcher or on
// Unicode-property data we haven't shipped. Currently empty; kept as
// the obvious home for such an entry when one arises.
pub const vendor_features = [_][]const u8{};

// ════════════════════════════════════════════════════════════════════
//   Lookup
// ════════════════════════════════════════════════════════════════════

pub fn pathIsSkipped(rel_path: []const u8) bool {
    for (corpus_excluded_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// Feature tags for pre-Stage-4 proposals Cynic hasn't implemented
/// (decorators, import-defer, source-phase-imports, …). Dropped from
/// `total` (reason `.pre_stage4`): they aren't in any published
/// ECMA-262 edition, so the headline shouldn't move when TC39 lands
/// their fixtures upstream. Recoverable two ways:
///   - the proposal reaches **Stage 4** → it's specced, so it leaves
///     `stage_maturity_features` and re-enters `total`; or
///   - Cynic **implements** it → it graduates to a dedicated
///     `feature:<name>` phase (a `FeatureFlag` — `joint-iteration`,
///     `ShadowRealm`), kept out of the main rows by the harness's
///     per-phase feature-tag gate.
pub fn featureIsUnimplementedProposal(feature: []const u8) bool {
    for (stage_maturity_features) |f| {
        if (std.mem.eql(u8, feature, f)) return true;
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════
//   Tests
// ════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "skip: corpus-walk exclusions" {
    try testing.expect(pathIsSkipped("harness/sta.js"));
    try testing.expect(pathIsSkipped("staging/explicit-resource-management/foo.js"));
    // The whole annexB/ tree is excluded from the corpus.
    try testing.expect(pathIsSkipped("annexB/B.1.1/legacy-octal.js"));
    // intl402 and main-tree fixtures RUN (binary pass/fail), so they
    // must NOT be path-skipped.
    try testing.expect(!pathIsSkipped("intl402/Locale/extensions.js"));
    try testing.expect(!pathIsSkipped("language/expressions/optional-chaining/foo.js"));
}

test "skip: pre-Stage-4 proposals dropped from total" {
    // Unshipped Stage <= 3 proposals — dropped via feature tag.
    try testing.expect(featureIsUnimplementedProposal("decorators"));
    try testing.expect(featureIsUnimplementedProposal("import-defer"));
    try testing.expect(featureIsUnimplementedProposal("source-phase-imports"));
    try testing.expect(featureIsUnimplementedProposal("await-dictionary"));
    try testing.expect(featureIsUnimplementedProposal("immutable-arraybuffer"));
    // Shipped pre-Stage-4 proposals (joint-iteration, ShadowRealm) are
    // NOT here — the harness keeps them out of the main rows via the
    // per-phase feature-tag gate, and scores them in dedicated phases.
    try testing.expect(!featureIsUnimplementedProposal("ShadowRealm"));
    try testing.expect(!featureIsUnimplementedProposal("joint-iteration"));
    // Shipped, specced features are runnable.
    try testing.expect(!featureIsUnimplementedProposal("class"));
    try testing.expect(!featureIsUnimplementedProposal("regexp-modifiers"));
    try testing.expect(!featureIsUnimplementedProposal("explicit-resource-management"));
}

test "skip: ShadowRealm is not path-skipped (feature-gated)" {
    // ShadowRealm ships behind `--enable=ShadowRealm`; the harness's
    // per-phase feature-tag gate keeps it out of the main rows, not a
    // skip.zig path list. So the corpus walk-skip doesn't fire.
    try testing.expect(!pathIsSkipped("built-ins/ShadowRealm/constructor.js"));
}
