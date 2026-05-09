//! Skip rules for the test262 harness — paths and features Cynic is
//! not in scope for. Kept as comptime-iterable lists so the runtime
//! cost of the lookup is just a series of `mem.eql` calls.

const std = @import("std");

/// Path-prefix exclusions (relative to `vendor/test262/test/`). Tests
/// matching any prefix are skipped before frontmatter parsing.
pub const skip_path_prefixes = [_][]const u8{
    "harness/",
    "staging/",
    "intl402/",
};

/// Additional path-prefix exclusions that apply ONLY when running in
/// `--scope=cynic` mode. Test paths Cynic explicitly considers
/// out-of-scope: Annex B language extensions (sloppy-mode-only),
/// Annex B browser-era built-ins we don't ship (`escape`/`unescape`,
/// String HTML wrappers, `Date.{getYear, setYear}`,
/// `RegExp.prototype.compile`), and sloppy-mode regex literals.
///
/// Excluded from the per-row score in `--scope=cynic` so the number
/// reflects what Cynic *targets* rather than what the entire spec
/// demands. The default `--scope=full` keeps measuring against
/// everything.
pub const cynic_oos_path_prefixes = [_][]const u8{
    // Annex B language extensions — sloppy mode only.
    "annexB/language/",
    // Annex B browser-era built-ins we deliberately don't ship.
    "annexB/built-ins/escape/",
    "annexB/built-ins/unescape/",
    "annexB/built-ins/String/prototype/anchor/",
    "annexB/built-ins/String/prototype/big/",
    "annexB/built-ins/String/prototype/blink/",
    "annexB/built-ins/String/prototype/bold/",
    "annexB/built-ins/String/prototype/fixed/",
    "annexB/built-ins/String/prototype/fontcolor/",
    "annexB/built-ins/String/prototype/fontsize/",
    "annexB/built-ins/String/prototype/italics/",
    "annexB/built-ins/String/prototype/link/",
    "annexB/built-ins/String/prototype/small/",
    "annexB/built-ins/String/prototype/strike/",
    "annexB/built-ins/String/prototype/sub/",
    "annexB/built-ins/String/prototype/sup/",
    "annexB/built-ins/Date/prototype/getYear/",
    "annexB/built-ins/Date/prototype/setYear/",
    "annexB/built-ins/Date/prototype/toGMTString/", // alias of toUTCString — kept but tested via standard path
    "annexB/built-ins/RegExp/", // legacy-regex extensions; full RegExp engine itself is "deferred" not "out of scope"
    "annexB/built-ins/Function/createdynfn-no-line-terminator-html-close-comment-params.js",
    // Shared-memory primitives — explicitly out of scope per
    // docs/ROADMAP.md. Aligns with SES / Hardened JavaScript:
    // shared memory enables side channels that defeat strong
    // isolation between workers / agents. Cynic targets edge
    // runtimes where the host model is single-agent-per-isolate
    // anyway, so there's nothing for `SharedArrayBuffer` /
    // `Atomics` to share with.
    "built-ins/Atomics/",
    "built-ins/SharedArrayBuffer/",
    // `eval` and runtime code construction — out permanently
    // (AGENTS.md, ROADMAP.md). Aligns with SES / Hardened
    // JavaScript. Fixtures under `language/eval-code/` and the
    // `built-ins/eval/` prototype-and-properties tree directly
    // call `eval(...)` with no escape hatch, so they all
    // false-reject under our config; reclassifying them here
    // stops the harness from advertising progress on something
    // we've already decided not to do.
    "language/eval-code/",
    "built-ins/eval/",
};

/// `features` names we know we don't support. When a test's frontmatter
/// includes any of these, we skip it. Unknown feature names that we
/// haven't classified default to "attempt anyway"; some will pass, some
/// won't, and over time we move them into one bucket or the other.
///
/// Roughly grouped by reason:
/// • Stage-3-or-newer proposals that aren't implemented in any
/// parser-affecting form.
/// • Annex B features (Cynic deliberately rejects Annex B).
/// • Runtime features that don't affect the parser but indicate the
/// test relies on harness/runtime support we don't have.
pub const unsupported_features = [_][]const u8{
    // Proposals / future syntax
    "decorators",
    "import-attributes",
    "import-assertions",
    "import-defer",
    "source-phase-imports",
    "explicit-resource-management",
    "async-explicit-resource-management",
    // RegExp feature gates that *used* to live here moved out
    // when the vendored QuickJS-NG `libregexp.c` was wired up:
    // named groups, lookbehind, `u`-flag, match indices, and
    // Unicode property escapes are all fully supported. The
    // `v`-flag is left ungated even though libregexp's support
    // is *partial*: basic patterns, `\p{…}` intersection
    // (`&&`), and string literals (`\q{ab|cd}`) work; set
    // difference (`[\p{Letter}--A]`) throws. Net-net we get
    // more passes than fails by attempting them. The ones
    // below remain skipped because libregexp doesn't ship them
    // at all:
    //   • `regexp-duplicate-named-groups` — ES2025 grammar
    //     change to allow the same name in alternative branches.
    //   • `regexp-modifiers` — ES2024 inline (?i:…)/(?-i:…)
    //     flag scoping.
    "regexp-duplicate-named-groups",
    "regexp-modifiers",
    "Temporal",
    "ShadowRealm",
    // Atomics.waitAsync / Atomics.pause used to be listed here,
    // but the whole `built-ins/Atomics/` tree is now path-skipped
    // as out-of-scope (SES / single-agent-per-isolate). Same for
    // SharedArrayBuffer.
    "json-modules",
    "json-parse-with-source",
    // (iterator-helpers — Cynic ships Iterator.from + map/filter/take/
    // drop/toArray/forEach/find/some/every/reduce. Gate dropped.)
    "async-iterator-helpers",
    "Array.fromAsync",
    "Float16Array",
    "Math.f16round",
    "Math.sumPrecise",
    "uint8array-base64",
    "arraybuffer-transfer",
    "resizable-arraybuffer",
    // (regexp-named-groups, regexp-lookbehind, regexp-match-indices,
    // regexp-unicode-property-escapes, regexp-v-flag — all supported
    // by the vendored libregexp; gates removed.)
    "well-formed-json-stringify",
    // (error-cause — ES2022 `new Error(msg, {cause}).cause` — shipped.)
    "hashbang",
    // `eval` and runtime-code-construction friends — Cynic
    // permanently doesn't ship these. Aligns with SES /
    // Hardened JavaScript and removes a major optimization fence.
    "eval",
    // Annex B — we deliberately reject these.
    "__getter__",
    "__setter__",
    "__proto__",
    "Reflect.parse",
    "legacy-regexp",
    "IsHTMLDDA",
    // Cynic-out-of-scope syntax (labels)
    "labels",
    // Runtime-only features (parser parses fine, but tests need runtime
    // semantics). We keep these out of the unsupported list so they
    // exercise the parser; comment lists any we'd want to skip
    // explicitly later if signal/noise gets bad.
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
    try testing.expect(!pathIsCynicOutOfScope("annexB/built-ins/String/prototype/substr/length-undef.js"));
    try testing.expect(!pathIsCynicOutOfScope("language/expressions/addition/order-of-evaluation.js"));
}

test "skip: unsupported features" {
    try testing.expect(featureIsUnsupported("decorators"));
    try testing.expect(featureIsUnsupported("Temporal"));
    try testing.expect(featureIsUnsupported("regexp-modifiers"));
    try testing.expect(!featureIsUnsupported("regexp-v-flag")); // libregexp ships v-flag (partial: no set-difference)
    try testing.expect(!featureIsUnsupported("regexp-named-groups"));
    try testing.expect(!featureIsUnsupported("class"));
    try testing.expect(!featureIsUnsupported("optional-chaining"));
    try testing.expect(!featureIsUnsupported("async-functions"));
}
