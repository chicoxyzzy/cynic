//! Skip rules for the test262 harness — paths and features Cynic is
//! not in scope for. Organised by *why* something is skipped, so the
//! rationale travels with the entry. Lookup is `mem.startsWith`,
//! `mem.indexOf`, or `mem.eql` over comptime-iterable lists.
//!
//! Groups:
//!
//!   1. Annex B      — browser-era / sloppy-mode legacy Cynic doesn't
//!                     ship. Path-skipped wholesale.
//!   2. SES          — no `eval`, no shared memory. Policy. Path-
//!                     skipped at the directory level.
//!   3. Stage maturity — TC39 proposals not yet in a published edition
//!                       whose grammar would break the parser if we
//!                       attempted to handle the fixture.
//!   4. Non-standard — SpiderMonkey-only / browser-only. Currently
//!                     empty: previous entries parse fine and surface
//!                     as honest runtime-mode failures rather than
//!                     being hidden here.
//!   5. Planned      — standardised features we don't ship yet,
//!                     blocked on libregexp (the vendored matcher)
//!                     or other infra work. Reviewed each vendor bump.

const std = @import("std");

/// Universal path-prefix exclusions (relative to
/// `vendor/test262/test/`). Tests matching any prefix are
/// skipped before frontmatter parsing — they're harness /
/// staging-grounds / non-engine concerns.
pub const skip_path_prefixes = [_][]const u8{
    "harness/",
    "staging/",
    "intl402/",
};

// ── Group 1: Annex B ────────────────────────────────────────────────
//
// Cynic targets edge runtimes (Workers / Deno / server JS), not
// browsers. Annex B in its entirety — language extensions *and*
// browser-era built-ins — is out of scope per AGENTS.md / ROADMAP.md.
// The `annexB/` test262 tree is duplicate coverage of main-spec
// items we already test via the main path.

pub const skip_annex_b_paths = [_][]const u8{
    "annexB/",
};

pub const skip_annex_b_features = [_][]const u8{
    // Empty: Annex B identifiers and accessors (`__proto__`,
    // `__defineGetter__`, `RegExp.$1`, etc.) parse as ordinary
    // member access; they fail at runtime because Cynic doesn't
    // install the globals, and that failure should be visible in
    // runtime-mode scoring rather than hidden here.
};

// ── Group 2: SES alignment ──────────────────────────────────────────
//
// No `eval` / `new Function(string)` (runtime code construction
// breaks SES isolation and is a major optimisation fence). No
// shared memory (`SharedArrayBuffer` / `Atomics`) — Cynic's
// edge-runtime hosts are single-agent-per-isolate. Both are
// permanent decisions.

pub const skip_ses_paths = [_][]const u8{
    "language/eval-code/",
    "built-ins/eval/",
    "built-ins/Atomics/",
    "built-ins/SharedArrayBuffer/",
};

/// `built-ins/Function/` is a *mixed* bucket — the prototype
/// methods (`apply`, `call`, `bind`, …) are in scope, but every
/// test under §15.3.2 / §15.3.5 exercises `Function(string)` /
/// `new Function(string)` which is a permanent SES carve-out.
/// Match by basename substring so the prototype-method fixtures
/// stay attempted.
pub const skip_ses_substrings = [_][]const u8{
    "built-ins/Function/15.3.2",
    "built-ins/Function/S15.3.2",
    "built-ins/Function/S15.3.5",
};

/// AND-pair filters — both substrings must appear in the path. Used
/// when a coarse substring (`/class/elements/`) would over-skip, but
/// a generated-fixture suffix (`-eval-`, `-eval.js`) narrows it to
/// exactly the eval-dependent generated set. The §15.7 spec rule
/// ("eval inside class field initializer contains super → SyntaxError
/// at PerformEval-time") needs an actual eval — without one, Cynic
/// throws the wrong error class and these fixtures false-reject.
/// SES-aligned out of scope alongside the rest of eval.
pub const skip_ses_substring_pairs = [_][2][]const u8{
    .{ "/class/elements/", "-eval-" },
};

pub const skip_ses_features = [_][]const u8{
    // Empty: same reasoning as Annex B — fixtures parse fine but
    // need globals Cynic intentionally doesn't ship.
};

// ── Group 3: Stage maturity ─────────────────────────────────────────
//
// TC39 proposals not yet in a published edition whose grammar
// would break the parser if we attempted to handle the fixture.
// Reviewed each release cycle; promote out of here once
// implemented.

pub const skip_stage_maturity_features = [_][]const u8{
    "decorators", // Stage 3 — class decorator grammar.
    "explicit-resource-management", // Stage 3 — `using` / `await using`.
    "import-defer", // Stage 3 — `import defer * as ns from "…"`.
    "source-phase-imports", // Stage 3 — `import source x from "…"`.
};

// ── Group 4: Non-standard ───────────────────────────────────────────
//
// SpiderMonkey-only / browser-only behaviour. Currently empty:
// previously-listed entries (`Reflect.parse`, `IsHTMLDDA`,
// `legacy-regexp`, …) all parse cleanly and surface as honest
// runtime-mode failures.

pub const skip_non_standard_features = [_][]const u8{};

// ── Group 5: Planned (vendor / infra gaps) ──────────────────────────
//
// Standardised features blocked on the vendored libregexp matcher
// (QuickJS-NG) or on runtime glue we haven't wired yet. Reviewed
// each libregexp bump.

pub const skip_planned_features = [_][]const u8{
    "regexp-duplicate-named-groups", // ES2025 — libregexp gap.
    "regexp-modifiers", // ES2024 inline `(?i:…)` / `(?-i:…)`.
};

pub const skip_planned_paths = [_][]const u8{
    // Temporal is a large Stage 4 surface (Calendar / TimeZone /
    // Instant / PlainDate / …). Every fixture parses fine but
    // runtime mode would attempt ~4500 tests against globals Cynic
    // doesn't install, drowning the rest of the runtime scoreboard
    // in 0 % noise. Path-skip wholesale until the implementation
    // phase.
    "built-ins/Temporal/",
    // ShadowRealm — Stage 2.7 (not yet Stage 3). Cynic doesn't
    // install the global; honest runtime-fail noise (0 / 64).
    // Re-evaluate once the proposal advances or SES integration
    // lands.
    "built-ins/ShadowRealm/",
    // `Uint8Array.{fromBase64, fromHex, prototype.{setFromBase64,
    // setFromHex, toBase64, toHex}}` — Stage 4 (ES2025 ArrayBuffer
    // ↔ base64/hex). The whole `built-ins/Uint8Array/` tree
    // tests this single proposal; Cynic's TypedArray surface ships
    // every other method, so no risk of over-skipping.
    "built-ins/Uint8Array/",
};

pub const skip_planned_path_contains = [_][]const u8{
    // Unicode `Script_Extensions=Unknown` (alias `scx=Zzzz`) —
    // libregexp's property tables don't include the "Unknown"
    // special value.
    "/property-escapes/special-property-value-Script_Extensions-Unknown",
};

// ── Lookup ──────────────────────────────────────────────────────────

pub fn pathIsSkipped(rel_path: []const u8) bool {
    for (skip_path_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// Cynic-scope skip — fixtures the project considers out of
/// scope. Always check `pathIsSkipped` first; this is an extra
/// filter on top.
pub fn pathIsCynicOutOfScope(rel_path: []const u8) bool {
    inline for (.{ skip_annex_b_paths, skip_ses_paths, skip_planned_paths }) |group| {
        for (group) |prefix| {
            if (std.mem.startsWith(u8, rel_path, prefix)) return true;
        }
    }
    for (skip_planned_path_contains) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return true;
    }
    for (skip_ses_substrings) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return true;
    }
    for (skip_ses_substring_pairs) |pair| {
        if (std.mem.indexOf(u8, rel_path, pair[0]) != null and
            std.mem.indexOf(u8, rel_path, pair[1]) != null) return true;
    }
    return false;
}

pub fn featureIsUnsupported(feature: []const u8) bool {
    inline for (.{
        skip_annex_b_features,
        skip_ses_features,
        skip_stage_maturity_features,
        skip_non_standard_features,
        skip_planned_features,
    }) |group| {
        for (group) |unsup| {
            if (std.mem.eql(u8, feature, unsup)) return true;
        }
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "skip: known path prefixes" {
    try testing.expect(pathIsSkipped("harness/sta.js"));
    try testing.expect(pathIsSkipped("intl402/Locale/extensions.js"));
    try testing.expect(pathIsSkipped("staging/explicit-resource-management/foo.js"));
    try testing.expect(!pathIsSkipped("language/expressions/optional-chaining/foo.js"));
    try testing.expect(!pathIsSkipped("built-ins/Array/prototype/at/length.js"));
    try testing.expect(!pathIsSkipped("annexB/B.1.1/legacy-octal.js"));
}

test "skip: Annex B out of scope" {
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/escape/empty-string.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/String/prototype/blink/B.2.3.4.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/Date/prototype/setYear/year-nan.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/language/comments/single-line-html-open.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/String/prototype/substr/length-undef.js"));
}

test "skip: SES out of scope" {
    try testing.expect(pathIsCynicOutOfScope("language/eval-code/direct/var.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/eval/length.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/Atomics/load/length.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/SharedArrayBuffer/length.js"));
    // §15.3.2 Function-constructor fixtures (always `Function(string)`).
    try testing.expect(pathIsCynicOutOfScope("built-ins/Function/S15.3.2.1_A1_T1.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/Function/15.3.2.1-11-9-s.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/Function/S15.3.5_A2_T2.js"));
    // …prototype methods stay in scope.
    try testing.expect(!pathIsCynicOutOfScope("built-ins/Function/prototype/apply/length.js"));
    try testing.expect(!pathIsCynicOutOfScope("built-ins/Function/prototype/call/length.js"));
    // Class field initializer fixtures whose assertion depends on
    // eval (cluster narrowed via the `class/elements/ + -eval-` pair).
    try testing.expect(pathIsCynicOutOfScope("language/expressions/class/elements/derived-cls-direct-eval-err-contains-supercall.js"));
    try testing.expect(pathIsCynicOutOfScope("language/statements/class/elements/arrow-body-direct-eval-err-contains-arguments.js"));
    // Non-eval class/elements fixtures stay in scope.
    try testing.expect(!pathIsCynicOutOfScope("language/expressions/class/elements/evaluation-error/computed-name-toprimitive-returns-nonobject.js"));
    try testing.expect(!pathIsCynicOutOfScope("language/statements/class/elements/private-class-field-initialization-is-visible-to-proxy.js"));
}

test "skip: main-spec paths not OOS" {
    try testing.expect(!pathIsCynicOutOfScope("language/expressions/addition/order-of-evaluation.js"));
    try testing.expect(!pathIsCynicOutOfScope("built-ins/String/prototype/substr/length-undef.js"));
}

test "skip: Temporal out of scope" {
    try testing.expect(pathIsCynicOutOfScope("built-ins/Temporal/Now/extensible.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/Temporal/PlainDate/prototype/add/branding.js"));
}

test "skip: ShadowRealm out of scope" {
    try testing.expect(pathIsCynicOutOfScope("built-ins/ShadowRealm/constructor.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/ShadowRealm/prototype/evaluate/this.js"));
}

test "skip: Uint8Array base64/hex (ES2025) out of scope" {
    try testing.expect(pathIsCynicOutOfScope("built-ins/Uint8Array/fromBase64/null.js"));
    try testing.expect(pathIsCynicOutOfScope("built-ins/Uint8Array/prototype/toHex/length.js"));
}

test "skip: planned vendor gaps" {
    try testing.expect(pathIsCynicOutOfScope(
        "built-ins/RegExp/property-escapes/special-property-value-Script_Extensions-Unknown.js",
    ));
    // The string-property positive form and `-negative-*` siblings
    // stay in scope — libregexp handles `\p{…}` for property-of-
    // strings, and Cynic's parse-time validator (§22.2.1.5) rejects
    // the spec-illegal `\P{StringProperty}` and `[^\p{StringProperty}]`
    // forms under `/v`.
    try testing.expect(!pathIsCynicOutOfScope(
        "built-ins/RegExp/property-escapes/generated/strings/RGI_Emoji.js",
    ));
    try testing.expect(!pathIsCynicOutOfScope(
        "built-ins/RegExp/property-escapes/generated/strings/RGI_Emoji-negative-u.js",
    ));
    try testing.expect(!pathIsCynicOutOfScope(
        "built-ins/RegExp/property-escapes/generated/strings/RGI_Emoji-negative-P.js",
    ));
    try testing.expect(!pathIsCynicOutOfScope(
        "built-ins/RegExp/property-escapes/generated/strings/RGI_Emoji-negative-CharacterClass.js",
    ));
}

test "skip: unsupported features — stage maturity + planned" {
    // Stage 3 syntax — parser would choke.
    try testing.expect(featureIsUnsupported("decorators"));
    try testing.expect(featureIsUnsupported("explicit-resource-management"));
    try testing.expect(featureIsUnsupported("import-defer"));
    try testing.expect(featureIsUnsupported("source-phase-imports"));
    // Planned — libregexp.
    try testing.expect(featureIsUnsupported("regexp-modifiers"));
    try testing.expect(featureIsUnsupported("regexp-duplicate-named-groups"));
}

test "skip: runtime-only gaps are NOT hidden" {
    // Annex B browser-era / SES-policy / Stage 3 runtime features
    // all parse fine; their fixtures show as honest runtime fails.
    try testing.expect(!featureIsUnsupported("__proto__"));
    try testing.expect(!featureIsUnsupported("__getter__"));
    try testing.expect(!featureIsUnsupported("__setter__"));
    try testing.expect(!featureIsUnsupported("legacy-regexp"));
    try testing.expect(!featureIsUnsupported("IsHTMLDDA"));
    try testing.expect(!featureIsUnsupported("Reflect.parse"));
    try testing.expect(!featureIsUnsupported("ShadowRealm"));
    try testing.expect(!featureIsUnsupported("SharedArrayBuffer"));
    try testing.expect(!featureIsUnsupported("Atomics"));
    try testing.expect(!featureIsUnsupported("eval"));
    try testing.expect(!featureIsUnsupported("Array.fromAsync"));
    try testing.expect(!featureIsUnsupported("Math.sumPrecise"));
    try testing.expect(!featureIsUnsupported("async-iterator-helpers"));
}

test "skip: shipping features not flagged unsupported" {
    try testing.expect(!featureIsUnsupported("regexp-v-flag")); // libregexp partial; positive forms ship
    try testing.expect(!featureIsUnsupported("regexp-named-groups"));
    try testing.expect(!featureIsUnsupported("class"));
    try testing.expect(!featureIsUnsupported("optional-chaining"));
    try testing.expect(!featureIsUnsupported("async-functions"));
}
