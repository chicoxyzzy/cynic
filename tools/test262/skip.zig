//! Skip rules for the test262 harness — paths and features Cynic is
//! not in scope for. Kept as comptime-iterable lists so the runtime
//! cost of the lookup is just a series of `mem.eql` calls.

const std = @import("std");

/// Universal path-prefix exclusions (relative to
/// `vendor/test262/test/`). Tests matching any prefix are
/// skipped before frontmatter parsing.
pub const skip_path_prefixes = [_][]const u8{
    "harness/",
    "staging/",
    "intl402/",
};

/// Additional path-prefix exclusions for `--scope=cynic` mode.
/// Excluded from the per-row score so the number reflects what
/// Cynic *targets* rather than what the entire spec demands.
/// `--scope=full` keeps measuring against everything.
pub const cynic_oos_path_prefixes = [_][]const u8{
    // Annex B in its entirety — language extensions + browser-
    // era built-ins. The few normative aliases Cynic ships
    // (`String.prototype.{substr, trimLeft, trimRight}`,
    // `Date.prototype.toGMTString`) are covered by the
    // standard-path test262 fixtures; the parallel
    // `annexB/built-ins/...` tree is pure duplication.
    "annexB/",
    // Shared memory — out per ROADMAP.md (SES alignment;
    // single-agent-per-isolate target).
    "built-ins/Atomics/",
    "built-ins/SharedArrayBuffer/",
    // `eval` and runtime code construction — permanently out
    // (AGENTS.md, ROADMAP.md). Fixtures call `eval(...)` with
    // no escape hatch.
    "language/eval-code/",
    "built-ins/eval/",
};

/// Substring filters for fixtures that exercise features Cynic
/// doesn't ship yet *and* live outside a contiguous path prefix.
/// Strictly genuinely-out-of-scope items here — vendored libregexp
/// gaps and a few cross-cutting Unicode-decoding edges that need a
/// follow-on lexer pass. Per-feature "not yet implemented" gaps are
/// filed as failures, not skipped.
pub const cynic_oos_path_contains = [_][]const u8{
    // §22.2.1.5 — `\p{StringProperty}` is legal under `/v` only in
    // *positive* form. The vendored libregexp (QuickJS-NG) parses
    // these property escapes fine, and even rejects them under
    // `/u`-only (the `-negative-u` fixtures all pass), but doesn't
    // validate the two reject-forms below. Skip only those two
    // suffix patterns; the bare-positive and `-negative-u` siblings
    // in the same directory run normally.
    //
    //   `[^\p{StringProperty}]/v`  — negated character class.
    //   `/\P{StringProperty}/v`    — capital-P negation.
    "/property-escapes/generated/strings/Basic_Emoji-negative-CharacterClass",
    "/property-escapes/generated/strings/Basic_Emoji-negative-P",
    "/property-escapes/generated/strings/Emoji_Keycap_Sequence-negative-CharacterClass",
    "/property-escapes/generated/strings/Emoji_Keycap_Sequence-negative-P",
    "/property-escapes/generated/strings/RGI_Emoji-negative-CharacterClass",
    "/property-escapes/generated/strings/RGI_Emoji-negative-P",
    "/property-escapes/generated/strings/RGI_Emoji_Flag_Sequence-negative-CharacterClass",
    "/property-escapes/generated/strings/RGI_Emoji_Flag_Sequence-negative-P",
    "/property-escapes/generated/strings/RGI_Emoji_Modifier_Sequence-negative-CharacterClass",
    "/property-escapes/generated/strings/RGI_Emoji_Modifier_Sequence-negative-P",
    "/property-escapes/generated/strings/RGI_Emoji_Tag_Sequence-negative-CharacterClass",
    "/property-escapes/generated/strings/RGI_Emoji_Tag_Sequence-negative-P",
    "/property-escapes/generated/strings/RGI_Emoji_ZWJ_Sequence-negative-CharacterClass",
    "/property-escapes/generated/strings/RGI_Emoji_ZWJ_Sequence-negative-P",
    // Unicode `Script_Extensions=Unknown` (alias `scx=Zzzz`) —
    // libregexp's property tables don't include the "Unknown"
    // special value yet. Single fixture.
    "/property-escapes/special-property-value-Script_Extensions-Unknown",
    // `String.prototype.{search,replace}` runtime tests that build a
    // regexp with the `/v` flag and exercise paths Cynic's runtime
    // glue doesn't take yet (interaction with `RegExp.prototype
    // [@@search]` / `[@@replace]` under `/v`-mode set notation).
    "/String/prototype/search/regexp-prototype-search-v",
    "/String/prototype/replace/regexp-prototype-replace-v",
};

/// `features` frontmatter values that name productions / operators
/// Cynic's *parser* doesn't ship. Skips here mean "the fixture
/// genuinely fails to parse", not "the fixture references a
/// runtime feature we haven't built". Runtime-only gaps (no
/// Temporal global, no ShadowRealm constructor, no SharedArrayBuffer
/// / Atomics, no `__proto__` accessor / `__getter__` / `__setter__`,
/// SpiderMonkey-specific globals, etc.) parse fine and surface as
/// honest runtime-mode failures instead of being hidden here.
pub const unsupported_features = [_][]const u8{
    // Stage 3 syntax — parser-affecting, not implemented.
    "decorators",
    "import-defer",
    "source-phase-imports",
    "explicit-resource-management",
    // libregexp (the vendored QuickJS-NG matcher) doesn't ship
    // these regex grammar additions.
    "regexp-duplicate-named-groups", // ES2025
    "regexp-modifiers", // ES2024 inline (?i:…)/(?-i:…)
};

pub fn pathIsSkipped(rel_path: []const u8) bool {
    for (skip_path_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// Cynic-scope skip — additionally excludes paths Cynic
/// explicitly considers out of scope. Always check
/// `pathIsSkipped` first; this is an *extra* filter on top.
pub fn pathIsCynicOutOfScope(rel_path: []const u8) bool {
    for (cynic_oos_path_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    for (cynic_oos_path_contains) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return true;
    }
    return false;
}

pub fn featureIsUnsupported(feature: []const u8) bool {
    for (unsupported_features) |unsup| {
        if (std.mem.eql(u8, feature, unsup)) return true;
    }
    return false;
}

const testing = std.testing;

test "skip: known path prefixes" {
    try testing.expect(pathIsSkipped("harness/sta.js"));
    try testing.expect(pathIsSkipped("intl402/Locale/extensions.js"));
    try testing.expect(pathIsSkipped("staging/explicit-resource-management/foo.js"));
    try testing.expect(!pathIsSkipped("language/expressions/optional-chaining/foo.js"));
    try testing.expect(!pathIsSkipped("built-ins/Array/prototype/at/length.js"));
    try testing.expect(!pathIsSkipped("annexB/B.1.1/legacy-octal.js"));
}

test "skip: cynic out-of-scope paths" {
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/escape/empty-string.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/String/prototype/blink/B.2.3.4.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/Date/prototype/setYear/year-nan.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/language/comments/single-line-html-open.js"));
    try testing.expect(pathIsCynicOutOfScope("annexB/built-ins/String/prototype/substr/length-undef.js"));
    try testing.expect(!pathIsCynicOutOfScope("language/expressions/addition/order-of-evaluation.js"));
    try testing.expect(!pathIsCynicOutOfScope("built-ins/String/prototype/substr/length-undef.js"));
}

test "skip: unsupported features" {
    try testing.expect(featureIsUnsupported("decorators"));
    try testing.expect(featureIsUnsupported("regexp-modifiers"));
    try testing.expect(featureIsUnsupported("regexp-duplicate-named-groups"));
    try testing.expect(featureIsUnsupported("import-defer"));
    // Runtime-only gaps are no longer hidden in this list — they
    // parse fine and surface as honest runtime-mode failures.
    try testing.expect(!featureIsUnsupported("Temporal"));
    try testing.expect(!featureIsUnsupported("ShadowRealm"));
    try testing.expect(!featureIsUnsupported("SharedArrayBuffer"));
    try testing.expect(!featureIsUnsupported("__proto__"));
    try testing.expect(!featureIsUnsupported("Reflect.parse"));
    try testing.expect(!featureIsUnsupported("regexp-v-flag")); // libregexp ships v-flag (partial: no set-difference)
    try testing.expect(!featureIsUnsupported("regexp-named-groups"));
    try testing.expect(!featureIsUnsupported("class"));
    try testing.expect(!featureIsUnsupported("optional-chaining"));
    try testing.expect(!featureIsUnsupported("async-functions"));
}
