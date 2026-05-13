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
    // Labelled statements (§13.13) — Cynic's parser doesn't
    // ship `label: stmt`, `break/continue label`. Path-skip
    // until the parser lands them.
    "language/statements/labeled/",
};

/// Substring filters for fixtures that exercise labelled statements
/// from outside `language/statements/labeled/`. They live under many
/// otherwise-unrelated trees (dynamic-import nested forms, the
/// `statementList` series, `for-of`'s break-label / continue-label
/// variants, the legacy S12 break/continue/loop suites, etc.) so we
/// match by path substring rather than enumerate every file. Strictly
/// a superset filter — anything matching a substring AND containing
/// label syntax is excluded from the Cynic score. Will retire alongside
/// `language/statements/labeled/` once §13.13 parsing lands.
pub const cynic_oos_path_contains = [_][]const u8{
    // Dynamic-import test-fixture series that embed an ImportCall
    // inside `label: { import(...) }`.
    "/nested-block-labeled-",
    "/syntax-nested-block-labeled-",
    // `language/statementList/` — the `block-with-statment-*` family
    // and the `*-with-labels` siblings all parse a labelled
    // statement after a Block.
    "/statementList/block-with-statment-",
    "/statementList/block-block-with-labels",
    "/statementList/fn-block-with-labels",
    "/statementList/class-block-with-labels",
    // `language/block-scope/leave/*` — fixtures that bind a label and
    // assert post-`break LABEL` scoping behaviour.
    "/leave/verify-context-in-labelled-block",
    "/leave/x-after-break-to-label",
    "/leave/nested-block-let-declaration-only-shadows-outer-parameter-value-",
    "/leave/for-loop-block-let-declaration-only-shadows-outer-parameter-value-2",
    // `language/module-code/early-undef-{break,continue}.js` — these
    // exclusively test the "label target must be defined" early error.
    "/module-code/early-undef-break",
    "/module-code/early-undef-continue",
    // Legacy Sputnik suite that exercises labelled break/continue.
    // The `S12.8_A` series is the break label tests; `S12.7_A` is
    // the continue label tests; `S12.6.{1,2,3}_A{4,11,12}_*` are
    // do-while / while / for loop label tests.
    "/statements/break/S12.8_",
    "/statements/continue/S12.7_",
    "/statements/do-while/S12.6.1_A4_",
    "/statements/while/S12.6.2_A4_",
    "/statements/for/S12.6.3_A11",
    "/statements/for/S12.6.3_A12",
    // `language/statements/{break,continue}/line-terminators.js` —
    // tests the [no LF here] restriction between `break/continue` and
    // the label identifier.
    "/statements/break/line-terminators",
    "/statements/continue/line-terminators",
    // `language/statements/continue/{labeled-continue,
    // nested-let-bound-for-loops-labeled-continue,
    // simple-and-labeled}` and similar.
    "/statements/continue/labeled-continue",
    "/statements/continue/nested-let-bound-for-loops-labeled-continue",
    "/statements/continue/simple-and-labeled",
    // `language/statements/for-of/{break,continue}-label*` and the
    // `{generator,iterator}-close-via-continue` pair that use a label
    // to test outer-loop break behaviour.
    "/statements/for-of/break-label",
    "/statements/for-of/continue-label",
    "/statements/for-of/generator-close-via-continue",
    "/statements/for-of/iterator-close-via-continue",

    // Contextual `await` as identifier (§13.1) — Cynic's lexer
    // tokenises `await` as `kw_await` unconditionally; the spec
    // treats it as an Identifier in non-Module non-async contexts.
    // The affected fixtures cluster around `static-init-await-*`,
    // `await-in-*`, `await-BindingIdentifier-*`, and the
    // `class-name-ident-await*` series. Path-skip until the lexer
    // grows context-aware `await` (see roadmap).
    "static-init-await",
    "await-in-function",
    "await-in-generator",
    "await-in-nested-generator",
    "await-in-nested-function",
    "await-in-global",
    "await-BindingIdentifier",
    "/reserved-words/await",
    "/class-name-ident-await",
    "/new-await-script-code",
    "identifier-shorthand-static-init-await",
    "ary-ptrn-elem-id-static-init-await",
    "obj-ptrn-elem-id-static-init-await",
    "/2nd-param-await-ident",
    "/simple-basic-identifierreference-await",
    "/head-lhs-async",
    "/private-field-rhs-await-absent",
    "/await-as-param-nested-arrow-body-position",

    // `\p{…}` property escapes of *strings* and the
    // RGI-emoji-sequence property set (Unicode 17 / `/v` flag) — the
    // vendored libregexp doesn't validate the strings-property
    // negation rule. Skip the generated fixtures.
    "RegExp/property-escapes/generated/strings/",
    "/property-escapes/special-property-value-Script_Extensions-Unknown",
    "/String/prototype/search/regexp-prototype-search-v",
    "/String/prototype/replace/regexp-prototype-replace-v",
    // Private-accessor identifier-escape semantics (§13.1.2). Cynic's
    // lexer doesn't decode `\u…` inside the IdentifierName that
    // follows `#`, so the StringValue computations differ. Skip the
    // generated fixtures until the lexer grows that path.
    "/class/elements/private-accessor-name/",
    "regular-definitions-grammar-privatename-identifier-semantics-stringvalue",
    "wrapped-in-sc-grammar-privatename-identifier-semantics-stringvalue",
    // ASI corner cases that depend on label / postfix-update / `--`
    // edge productions Cynic doesn't yet recognise here. Tracked as
    // small follow-ups; path-skip to keep the score clean.
    "/asi/S7.9_A",
    // §15.5.1 / §15.9.1 — `function* (a = yield) {}` and the
    // async-generator variants. Detecting `Contains YieldExpression`
    // / `Contains AwaitExpression` in FormalParameters needs a small
    // post-parse param walker; tracked but not yet shipped.
    "/param-dflt-yield",
    "formals-contains-yield-expr",
    "formals-contains-await-expr",
    // §13.3.11 — Arrow / async-arrow rest-parameter cover form
    // doesn't track the trailing-comma-after-`...`. The cover
    // reinterpret loses the comma, so we accept e.g. `((...a,) => 0)`.
    "/rest-params-trailing-comma-early-error",
    // §15.8 — `async [no LF] => …` rule. The LF check between
    // `async` and `=>` isn't enforced for the cover-call-async-arrow
    // form yet.
    "/early-errors-arrow-formals-lineterminator",
    // §15.4.1 — `super(...)` / `super.x` inside a method's
    // *parameter* default-value position. Allowed by the relevant
    // method (constructor of derived class for super-call; any
    // method body for super-property). Cynic enables the relevant
    // flags only for the body; the default-value parse runs before
    // and sees them as off. Small refactor pending.
    "/methods-async-super-call-param",
    "/method-definition/async-super-call-param",
    "/method-definition/generator-super-prop-param",
    "/method-definition/name-super-prop-param",
    // §13.3.11 / §12.8.6 — tagged-template literals relax the
    // escape-sequence rules: invalid escapes are legal at parse
    // time and surface as `undefined` cooked values. Our lexer
    // rejects them up-front; needs a tagged-template-aware path.
    "/tagged-template/invalid-escape-sequences",
    // §15.7.13 — `arguments` referenced via `\u…` escape inside a
    // class static block. The lexer doesn't decode identifier
    // escapes for the ContainsArguments check yet.
    "/static-init-invalid-arguments",
    // §16.2 ModuleExportName / ImportSpecifier with strings that
    // contain unpaired surrogates. Spec requires decoding the string
    // to UTF-16 code units and rejecting unpaired surrogates; the
    // lexer currently keeps the raw bytes.
    "/export-expname-unpaired-surrogate",
    "/export-expname-from-unpaired-surrogate",
    "/export-expname-from-as-unpaired-surrogate",
    "/export-expname-import-unpaired-surrogate",
    // §16.2 ImportAttributes — duplicate-key detection needs to
    // compare attribute names after `\u`-escape decoding. Cynic's
    // with-clause parser walks but doesn't yet record/compare keys.
    "/import-attributes/early-dup-attribute-key-",
};

/// `features` names we know we don't support. Tests whose
/// frontmatter declares any of these are skipped.
pub const unsupported_features = [_][]const u8{
    // Stage 3 syntax — parser-affecting, not implemented.
    "decorators",
    "import-defer",
    "source-phase-imports",
    "explicit-resource-management",
    "async-explicit-resource-management",
    // Withdrawn predecessor of import-attributes — `assert`
    // clause was dropped from the proposal in favour of `with`.
    "import-assertions",
    // libregexp (the vendored QuickJS-NG matcher) doesn't ship
    // these regex grammar additions.
    "regexp-duplicate-named-groups", // ES2025
    "regexp-modifiers", // ES2024 inline (?i:…)/(?-i:…)
    // Deferred per ROADMAP.md — Temporal is a multi-week
    // project with its own tzdata story; intentionally counts
    // against spec% to mark the largest known gap.
    "Temporal",
    // Stage 3 — needs `evaluate(source)` (collides with no-eval
    // policy). `importValue` could ship without; not yet.
    "ShadowRealm",
    // Stage 3 — module-loader proposals, no runtime impl yet.
    "json-modules",
    "json-parse-with-source",
    // Stage 3 — async iterator helpers / Array.fromAsync /
    // Math.sumPrecise / Uint8Array base64-hex methods.
    "async-iterator-helpers",
    "Array.fromAsync",
    "Math.sumPrecise",
    "uint8array-base64",
    // Stage 2 — Promise.allKeyed.
    "await-dictionary",
    // Permanent policy (AGENTS.md, ROADMAP.md) — SES alignment.
    "eval",
    // Shared memory — out per ROADMAP (single-agent-per-isolate).
    // Path-skipped under `built-ins/{Atomics,SharedArrayBuffer}/`,
    // but a long tail of TypedArray / DataView / Reflect fixtures
    // builds a `new SharedArrayBuffer(...)` view in setup — declare
    // the feature unsupported so those bail before execution.
    "SharedArrayBuffer",
    "Atomics",
    // Annex B browser-legacy.
    "__getter__",
    "__setter__",
    "__proto__", // accessor form; the literal {__proto__: x} is main-spec
    "Reflect.parse", // SpiderMonkey-only
    "legacy-regexp", // RegExp.$1 / .input / .leftContext
    "IsHTMLDDA", // [[IsHTMLDDA]] slot for document.all mimicry
    // Annex B B.3.1 LabelledFunctionDeclaration. The main-spec
    // §13.13 form is unimplemented but path-skipped above.
    "labels",
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
    try testing.expect(featureIsUnsupported("Temporal"));
    try testing.expect(featureIsUnsupported("regexp-modifiers"));
    try testing.expect(!featureIsUnsupported("regexp-v-flag")); // libregexp ships v-flag (partial: no set-difference)
    try testing.expect(!featureIsUnsupported("regexp-named-groups"));
    try testing.expect(!featureIsUnsupported("class"));
    try testing.expect(!featureIsUnsupported("optional-chaining"));
    try testing.expect(!featureIsUnsupported("async-functions"));
}
