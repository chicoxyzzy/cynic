//! Skip rules for the test262 harness — the single source of truth for
//! which fixtures Cynic does not run, and how a failure is classified.
//!
//! The harness runs (almost) every fixture and sorts each into one of:
//! `passing`, `failing`, or `correctly handled` (a failure Cynic
//! produces *by design* — see `pathPolicyKind`). Only two narrow
//! categories never run at all. So this file has exactly four jobs,
//! each a `pub fn` the harness calls:
//!
//!   1. `pathIsSkipped` — corpus-walk exclusions. `harness/` (preamble
//!      helpers, not fixtures) and `staging/` (upstream WIP). Filtered
//!      before frontmatter parsing; never enter `total`.
//!
//!   2. `featureIsUnimplementedProposal` — pre-Stage-4 proposals Cynic
//!      hasn't implemented (decorators, import-defer, …). Dropped from
//!      `total` so the headline can't decay as TC39 lands proposal
//!      fixtures upstream. (Proposals Cynic *has* shipped —
//!      joint-iteration, ShadowRealm — are kept out of the main rows
//!      by the harness's per-phase feature-tag gate, not by this file,
//!      and get their own dedicated `feature:<name>` scoreboard.)
//!
//!   3. `pathIsCurrentlySkipped` — tech-debt skips: in-scope fixtures
//!      Cynic *should* pass but doesn't yet (cross-realm attribution,
//!      a vendored-matcher gap). Counted in `total`, lowering `pass%`
//!      — the live "work left" signal.
//!
//!   4. `pathPolicyKind` — the policy classifier. For a fixture that
//!      ran and FAILED, decide whether the failure is one Cynic makes
//!      *on purpose* (Annex B not shipped, strict-only, no Intl,
//!      eval surface off) and therefore counts as "correctly handled"
//!      rather than a real bug. First match wins, in priority order
//!      annex_b > no_strict > intl402 > eval. (The fifth policy, SES,
//!      is matched separately by the harness against the runtime error
//!      pattern — see `tools/test262/ses_divergent.zig` — because it's
//!      only knowable after the fixture throws.)
//!
//! SharedArrayBuffer / Atomics fixtures are deliberately NOT a policy:
//! Cynic could ship shared memory, so their failures stay plain
//! `failing` until it does.
//!
//! The bulk of this file is the data the four functions read — comptime
//! string lists, matched via `mem.startsWith` / `mem.indexOf` /
//! `mem.endsWith` / `mem.eql`. The `ses_*`-prefixed eval lists keep
//! their historical names; they feed the `eval` policy now.

const std = @import("std");

// ════════════════════════════════════════════════════════════════════
//   Corpus-walk-time exclusions
// ════════════════════════════════════════════════════════════════════
//
// Universal path-prefix exclusions (relative to
// `vendor/test262/test/`). Tests matching any prefix are skipped
// before frontmatter parsing — they're harness / staging-grounds /
// non-engine concerns. Separate concern from "Cynic out of scope":
// these gate the corpus walk itself.

pub const corpus_excluded_prefixes = [_][]const u8{
    // Harness helpers (sta.js / assert.js) — preamble files, not test
    // fixtures. Always filtered before frontmatter parsing.
    "harness/",
    // Staging ground — upstream-WIP fixtures that aren't required to
    // be portable; not part of any published edition. Filtered for the
    // same reason pre-Stage-4 proposals are: scoring stable ECMA-262
    // shouldn't be dragged by upstream WIP.
    "staging/",
    // NOTE: `intl402/` used to be filtered here. It now runs, and any
    // failure classifies as the `intl402` policy in `pathPolicyKind` —
    // Cynic doesn't ship Intl, so those failures are "correctly
    // handled" rather than engine bugs.
};

// Compatibility alias for callers that still reach for the old name.
pub const skip_path_prefixes = corpus_excluded_prefixes;

// ════════════════════════════════════════════════════════════════════
// ░░░░░░░░░░░░░░░░░░░░  PERMANENTLY OUT OF SCOPE  ░░░░░░░░░░░░░░░░░░░░
// ════════════════════════════════════════════════════════════════════
//
// Project policy. Listed in AGENTS.md as deliberate carve-outs;
// only a policy reversal would move an entry out of this section.
// Filtered at corpus walk-time so `test262-results.md` doesn't
// carry their false-reject noise.

// ── Annex B ─────────────────────────────────────────────────────────
//
// Cynic targets edge runtimes (Workers / Deno / server JS), not
// browsers. Annex B in its entirety — language extensions *and*
// browser-era built-ins — is out of scope per AGENTS.md / ROADMAP.md.
// The `annexB/` test262 tree is duplicate coverage of main-spec
// items we already test via the main path.

pub const annex_b_path_prefixes = [_][]const u8{
    "annexB/",
};

pub const annex_b_features = [_][]const u8{
    // Object.prototype's Annex B accessor methods — `__defineGetter__`,
    // `__defineSetter__`, `__lookupGetter__`, `__lookupSetter__`. Test262
    // tags fixtures for them with `features: [__getter__]` / `[__setter__]`.
    // Cynic doesn't install them per AGENTS.md "Annex B in its entirety —
    // out." Each fixture's failure is honest noise on the dashboard, not
    // an engine bug worth tracking. ~54 fixtures combined.
    "__getter__",
    "__setter__",
    // Object.prototype.__proto__ accessor (Annex B §B.2.2.1). Same policy.
    // ~16 fixtures.
    "__proto__",
    // RegExp legacy statics (`RegExp.$1`, `RegExp.input`, etc.) and the
    // `IsHTMLDDA` host primitive. Both Annex B. No fixtures hit these
    // today (already drained by other means) but listed for symmetry —
    // a future test262 bump might add coverage.
    "legacy-regexp",
    "IsHTMLDDA",
};

// ── Strict-only carve-out ───────────────────────────────────────────
//
// Cynic ships strict mode only per AGENTS.md "Strict-only, non-
// browser-host target". Fixtures that *require* sloppy-mode
// semantics to assert their behaviour are permanently OOS. The
// harness already drops most via the `flags: [noStrict]` gate;
// these are the stragglers that carry `flags: [raw]` or no flag
// and can't be auto-detected.

pub const strict_only_exact_paths = [_][]const u8{
    // `language/comments/hashbang/use-strict.js` — fixture body is
    // `#!"use strict"` (a hashbang comment) followed by `with ({}) {}`,
    // asserting that `#!"use strict"` is NOT a directive prologue and
    // therefore `with` runs in sloppy mode. Cynic is strict-only per
    // AGENTS.md "Strict-only, non-browser-host target", so the parser
    // refuses `with` regardless of mode. The fixture carries
    // `flags: [raw]` (not `[noStrict]`) so the harness's `no_strict`
    // gate doesn't catch it. Permanent strict-only carve-out.
    "language/comments/hashbang/use-strict.js",
    // `built-ins/ShadowRealm/prototype/evaluate/no-conditional-strict-mode.js`
    // — asserts that `ShadowRealm.prototype.evaluate` runs the
    // child realm's code in SLOPPY mode (the body is
    // `function lol() { arguments = 42; … }`, which is a
    // SyntaxError only under strict mode). §3.8.3.7 PerformShadowRealmEval
    // evaluates the source as a non-strict Script. Cynic is
    // strict-only per AGENTS.md, so `arguments = 42` is always an
    // early SyntaxError — the fixture can never pass regardless of
    // the boundary plumbing. Permanent strict-only carve-out, same
    // class as the hashbang fixture above.
    "built-ins/ShadowRealm/prototype/evaluate/no-conditional-strict-mode.js",
    // `language/statements/variable/12.2.1-{9,10,20,21}-s.js` — four
    // `-s` fixtures whose body runs an *indirect* eval:
    // `var s = eval; s('var eval;')` (plus the `eval = 42;` /
    // `var arguments;` / `arguments = 42;` siblings). Per §19.2.1.1
    // PerformEval an indirect eval evaluates its source as *non-strict*
    // code (strictCaller = false; the source carries no "use strict"
    // directive), so binding/assigning `eval` / `arguments` is legal
    // there and the fixtures assert "does not throw". Cynic is
    // strict-only (no sloppy parser path) per AGENTS.md, so even with
    // `--allow=eval` the eval'd source is parsed in strict mode, where
    // those forms are early SyntaxErrors — Cynic throws and the
    // positive (no-throw) test fails. They can never pass regardless of
    // the eval opt-in, so they live here, not in
    // `eval_dependent_exact_paths`. Same class as the ShadowRealm
    // sloppy-mode fixture above (which likewise rejects `arguments = 42`).
    "language/statements/variable/12.2.1-9-s.js",
    "language/statements/variable/12.2.1-10-s.js",
    "language/statements/variable/12.2.1-20-s.js",
    "language/statements/variable/12.2.1-21-s.js",
};

// ── Annex B regex-grammar carve-out ─────────────────────────────────
//
// Main-tree fixtures (outside the `annexB/` subtree) whose body
// *requires* the Annex B §B.1.2/§B.1.4 regex-grammar leniency that
// rereads an otherwise-invalid escape as a literal — e.g. `\X` /
// `\XA0` (an IdentityEscape of a UnicodeIDContinue letter, invalid in
// the §22.2.1 main grammar) read as the character 'X'. Cynic's
// strict-only, non-browser target enforces the main grammar in every
// mode (AGENTS.md "Regex Annex B (§B.1.4)"), so these patterns are
// §22.2.1.1 early errors. When they appear as a RegularExpressionLiteral
// they are a §12.9.5 early Syntax Error at script-parse time, which
// aborts the whole fixture — it can never pass regardless of the
// behaviour it means to exercise. Same out-of-scope class as the
// `annexB/` tree; the `total`-set filter drops them so the score
// carries no false-reject noise.
pub const annex_b_regex_exact_paths = [_][]const u8{
    // `built-ins/String/prototype/split/separator-regexp.js` — a
    // grab-bag of `String.prototype.split` separators that mixes
    // valid escapes (`\b`, `\d`, `\cY`, …) with Annex-B-only regex
    // literals: `/\XA0/` and `/\X/` (invalid IdentityEscape — `X` is
    // UnicodeIDContinue), plus `/\k<x>/` with no group named `x`
    // (Annex B rereads `\k` as literal 'k'). The first invalid
    // literal is a §12.9.5 early error, so the script never parses.
    "built-ins/String/prototype/split/separator-regexp.js",
};

// ── eval surface (eval policy) ──────────────────────────────────────
//
// `eval` / `new Function(string)` and friends. Cynic ships no runtime
// code construction by default (breaks SES isolation, major
// optimisation fence — AGENTS.md "eval and runtime code construction").
// A fixture that fails because it reaches its assertion through the
// eval surface classifies as `correctly handled` under the `eval`
// policy. (SharedArrayBuffer / Atomics are NOT here — Cynic could ship
// shared memory, so those failures stay plain `failing`.)

/// Whole sub-trees that exist only to test the eval surface.
pub const eval_path_prefixes = [_][]const u8{
    "language/eval-code/",
    "built-ins/eval/",
};

/// `built-ins/Function/` is a *mixed* bucket — the prototype
/// methods (`apply`, `call`, `bind`, …) are real engine surface, but
/// every test under §15.3.2 / §15.3.5 exercises `Function(string)` /
/// `new Function(string)`, the eval surface. Match by basename
/// substring so the prototype-method fixtures stay attempted.
pub const ses_substrings = [_][]const u8{
    "built-ins/Function/15.3.2",
    "built-ins/Function/S15.3.2",
    "built-ins/Function/S15.3.5",
    // `built-ins/Function/S15.3_A2_T*` and `S15.3_A3_T*` —
    // Sputnik-era `Function.call(thisArg, "src")` and
    // `Function.call(this, "var x / = 1;")` shape tests. The
    // first argument is ignored, and the second is a code
    // string; both forms are the §15.3.2 Function-constructor-
    // as-callable carve-out (`Function(string)` /
    // `Function.call(this, "src")`). Cynic permanently bans
    // runtime code construction (AGENTS.md), so these false-
    // reject for an OOS reason.
    "built-ins/Function/S15.3_A2_",
    "built-ins/Function/S15.3_A3_",
    // `built-ins/Function/15.3.5.4_2-1[3-9]gs.js` — strict-mode
    // `function.caller` Sputnik tests that call `eval()` /
    // `Function(string)` directly to verify strict-mode
    // reachability. Same permanent SES carve-out (§19.2.1 eval,
    // §15.3.2 Function constructor). Other 15.3.5.4 fixtures
    // (non-`gs.js`) stay attempted.
    "built-ins/Function/15.3.5.4_2-",
    // `built-ins/Function/prototype/{apply,call}/S15.3.4.[34]_A8_T[45].js`
    // — Sputnik fixtures that build a callable via
    // `Function("src").apply` (or `…call`) and assert `new
    // FACTORY()` throws TypeError. Construction routes through
    // §15.3.2 CreateDynamicFunction (string-source Function
    // constructor) — the permanent SES carve-out — and surfaces
    // SyntaxError before the apply/call-isn't-constructable
    // assertion runs. Same family as the rest of the
    // `Function(string)` skips.
    "built-ins/Function/prototype/apply/S15.3.4.3_A8_T4",
    "built-ins/Function/prototype/apply/S15.3.4.3_A8_T5",
    "built-ins/Function/prototype/call/S15.3.4.4_A7_T4",
    "built-ins/Function/prototype/call/S15.3.4.4_A7_T5",

    // §27.3.2 GeneratorFunction(string) / §27.4.2 AsyncGenerator
    // Function(string) / §27.7.2 AsyncFunction(string) — same
    // permanent SES carve-out as `new Function(string)`. The
    // `instance-*`, `invoked-as-*`, `is-a-constructor`, and
    // `has-instance` fixtures all instantiate via the string-
    // source constructor and false-reject without it. Prototype
    // / metadata / descriptor fixtures (`length`, `name`,
    // `prototype-prototype.js`, etc.) stay attempted.
    "/GeneratorFunction/instance-",
    "/GeneratorFunction/invoked-as-",
    "/GeneratorFunction/is-a-constructor",
    "/GeneratorFunction/has-instance",
    "/AsyncGeneratorFunction/instance-",
    "/AsyncGeneratorFunction/invoked-as-",
    "/AsyncGeneratorFunction/is-a-constructor",
    "/AsyncGeneratorFunction/has-instance",
    "/AsyncFunction/AsyncFunction-construct.",
    "/AsyncFunction/instance-construct-throws.",
    "/AsyncFunction/is-a-constructor.",

    // Completion-value tests across `language/statements/{switch,
    // try, if, for-in, for-of, for, while, do-while, generators,
    // labeled, variable, let, const, function, empty, async-
    // function, class}/cptn-*.js`. Every fixture uses
    // `assert.sameValue(eval('…'), <expected>)` to observe the
    // statement's completion value — un-runnable without `eval`,
    // same permanent SES carve-out. 73 fixtures at skip time, all
    // confirmed eval-based.
    "/cptn-",

    // `language/{expressions,statements}/class/private-*-{brand-check,
    // field,getter,setter,method}-multiple-evaluations-of-class-*-
    // function-ctor.js` and the matching `-eval-indirect.js` /
    // `-realm-function-ctor.js` variants — every one of these
    // fixtures builds a class via `new Function(classStringExpression)`
    // (or `(0, eval)(...)`) so each evaluation produces a fresh
    // brand. Cynic doesn't ship runtime code construction (SES
    // carve-out, see AGENTS.md), so the fixtures false-reject for
    // a permanent OOS reason rather than a real engine bug.
    "-multiple-evaluations-of-class-function-ctor",
    "-multiple-evaluations-of-class-realm-function-ctor",
    "-multiple-evaluations-of-class-eval-indirect",

    // `language/{statements,expressions}/class/subclass/builtin-
    // objects/{Function,GeneratorFunction}/*.js` — every fixture
    // exercises `class Sub extends Function {}` (or
    // GeneratorFunction) and then calls
    // `new Sub('a', 'return a*2')` /
    // `new Sub('a', 'yield a; yield a*2;')` to verify the
    // subclassed [[Construct]] path. Construction routes through
    // §15.3.2 / §27.3.2 CreateDynamicFunction (source-string
    // function constructor) which is the permanent SES carve-out
    // per AGENTS.md. Even the no-arg `new Subclass()` form trips
    // the same path because Function() with no args still routes
    // through CreateDynamicFunction.
    "class/subclass/builtin-objects/Function/",
    "class/subclass/builtin-objects/GeneratorFunction/",
    "class/subclass-builtins/subclass-Function.js",

    // `language/{statements,expressions}/class/elements/private-
    // {getter,setter}-is-not-a-own-property.js` — each fixture
    // probes the negative shape via Annex B `__lookupGetter__` /
    // `__lookupSetter__` (B.2.2.4 / B.2.2.5). Those accessors are
    // never installed under AGENTS.md "Annex B in its entirety —
    // out", so the call surfaces as "value is not callable" rather
    // than the spec's expected `undefined`. The fixture isn't
    // feature-tagged (no `[__getter__]` / `[__setter__]`) so
    // feature-based skip doesn't catch it; substring it.
    "/private-getter-is-not-a-own-property.js",
    "/private-setter-is-not-a-own-property.js",

    // `language/{statements,expressions}/class/elements/static-
    // field-init-with-this.js` — `static h = eval('this.g') + ...`
    // verifies `this` binding inside a static-field initializer
    // by routing through `eval()`. Permanent SES carve-out
    // (AGENTS.md "eval and runtime code construction"). The
    // `this` binding itself is also exercised non-eval-gated by
    // the sibling `static g = this.f + '262'` expression — the
    // assertion path on `h` is `eval`-only.
    "/static-field-init-with-this.js",

    // `language/{statements,expressions}/class/subclass-builtins/
    // subclass-SharedArrayBuffer.js` — `class Subclass extends
    // SharedArrayBuffer {}`, blocked by the missing
    // SharedArrayBuffer global. Permanent shared-memory carve-out
    // (AGENTS.md "single-agent-per-isolate"). Not under
    // `built-ins/SharedArrayBuffer/` so the directory prefix skip
    // misses it.
    "/subclass-builtins/subclass-SharedArrayBuffer.js",

    // `language/statements/class/elements/private-*-visible-to-direct-eval*.js`
    // — every fixture invokes `eval("this.#x")` (direct eval inside a
    // class body) to verify the private-name binding leaks into the
    // eval scope. Without `eval()` the private name lookup fails as
    // a ReferenceError instead of being resolved against the class
    // scope. Same permanent SES carve-out as the eval-indirect /
    // function-ctor fixtures above. 12 fixtures across field /
    // method / getter / setter and their static counterparts.
    "-visible-to-direct-eval",

    // `built-ins/Function/prototype/{apply,call}/S15.3.4.{3,4}_A*.js`
    // — Sputnik-era tests for apply/call. Most build the function
    // under test via `new Function(p, "src")` or `Function(p, "src")`,
    // i.e. dynamic code construction; same permanent SES carve-out
    // (`Function(string)`) as the `built-ins/Function/{S,}15.3.{2,5}`
    // substrings above. Other fixtures in `apply/`/`call/` test the
    // method's own descriptor / signature shape and stay attempted.
    //
    // Two clean ranges — A7 of apply and A6 of call are entirely
    // Function-string-using; the rest are scattered across A1 / A3 /
    // A5 / A8 (apply) and A1 / A3 / A5 / A7 (call) with passing
    // siblings, so we list those exact fixtures.
    "Function/prototype/apply/S15.3.4.3_A7_",
    "Function/prototype/call/S15.3.4.4_A6_",
    "Function/prototype/apply/S15.3.4.3_A1_T1.js",
    "Function/prototype/apply/S15.3.4.3_A3_T1.js",
    "Function/prototype/apply/S15.3.4.3_A3_T2.js",
    "Function/prototype/apply/S15.3.4.3_A3_T3.js",
    "Function/prototype/apply/S15.3.4.3_A3_T4.js",
    "Function/prototype/apply/S15.3.4.3_A3_T5.js",
    "Function/prototype/apply/S15.3.4.3_A3_T7.js",
    "Function/prototype/apply/S15.3.4.3_A3_T9.js",
    "Function/prototype/apply/S15.3.4.3_A5_T1.js",
    "Function/prototype/apply/S15.3.4.3_A5_T2.js",
    "Function/prototype/apply/S15.3.4.3_A5_T7.js",
    "Function/prototype/apply/S15.3.4.3_A5_T8.js",
    "Function/prototype/apply/S15.3.4.3_A8_T6.js",
    "Function/prototype/call/S15.3.4.4_A1_T1.js",
    "Function/prototype/call/S15.3.4.4_A3_T1.js",
    "Function/prototype/call/S15.3.4.4_A3_T2.js",
    "Function/prototype/call/S15.3.4.4_A3_T3.js",
    "Function/prototype/call/S15.3.4.4_A3_T4.js",
    "Function/prototype/call/S15.3.4.4_A3_T5.js",
    "Function/prototype/call/S15.3.4.4_A3_T7.js",
    "Function/prototype/call/S15.3.4.4_A3_T9.js",
    "Function/prototype/call/S15.3.4.4_A5_T1.js",
    "Function/prototype/call/S15.3.4.4_A5_T2.js",
    "Function/prototype/call/S15.3.4.4_A5_T7.js",
    "Function/prototype/call/S15.3.4.4_A5_T8.js",
    "Function/prototype/call/S15.3.4.4_A7_T6.js",

    // `built-ins/Function/prototype/toString/{AsyncFunction,
    // AsyncGenerator,GeneratorFunction}.js` — each fixture invokes
    // the source-string constructor (`AsyncFunction("…")` /
    // `AsyncGeneratorFunction("…")` / `GeneratorFunction("…")`) to
    // build the function whose `.toString()` is then asserted.
    // Permanent SES carve-out per AGENTS.md (§15.3.2 / §27.3.2 /
    // §27.4.2 / §27.7.2 dynamic-code constructors). The plain
    // `Function.prototype.toString` family (non-`-builtin` /
    // non-`{Async,Generator}Function`) stays attempted. 3 fixtures.
    "/Function/prototype/toString/AsyncFunction.",
    "/Function/prototype/toString/AsyncGenerator.",
    "/Function/prototype/toString/GeneratorFunction.",

    // `language/expressions/compound-assignment/11.13.2-*-s.js` —
    // Sputnik strict-mode shape tests. Every fixture wraps the
    // operator under test in `assert.throws(ReferenceError, () =>
    // eval("expr *= 1"))` — the body is `eval(string)`, permanent
    // SES carve-out (AGENTS.md "eval and runtime code construction").
    // The non-`-s.js` siblings + `S11.13.2_A*` Sputnik
    // coercion-order tests stay attempted. 9 fixtures.
    "language/expressions/compound-assignment/11.13.2-",

    // `built-ins/global/S10.2.3_A*.js` — Sputnik-era tests that
    // verify global-property reachability from `eval`-evaluated
    // code (e.g. `eval('if (NaN === null) { throw …; }')`).
    // Permanent SES carve-out (AGENTS.md "eval and runtime code
    // construction"). The non-`S10.2.3_A` siblings under
    // `built-ins/global/` (the strict-mode TypeError tests like
    // `10.2.1.1.3-4-*-s.js`) stay attempted — those exercise
    // §10.1.9.1 / §19.1 frozen globals without eval. 8 fixtures
    // share the substring.
    "built-ins/global/S10.2.3_A",

    // `language/{module-code,expressions/dynamic-import/usage}/
    // *eval-gtbndng-indirect-update*.js` — the shared
    // `eval-gtbndng-indirect-update_FIXTURE.js` (and `-dflt` variant)
    // does `Function('return this;')()` to retrieve globalThis at
    // module top, then installs a `test262update` mutator the
    // importer calls to observe the live-binding semantics of
    // §8.1.1.5 ModuleEnvironmentRecord. `Function(string)` is the
    // permanent SES carve-out (AGENTS.md "eval and runtime code
    // construction" / §15.3.2 Function constructor), so every
    // fixture loading either FIXTURE false-rejects for an OOS
    // reason rather than a real engine bug. 39 fixtures across the
    // two trees share the substring.
    "eval-gtbndng-indirect-update",

    // `language/statementList/eval-*.js` — every fixture in this
    // generated batch wraps a `StatementList` start in
    // `var result = eval('function fn() {}<production>;')` to
    // verify the parsing reach of the `Statement` / `Declaration`
    // alternatives. The body itself is parser-shaped, but Cynic's
    // permanent SES carve-out excludes runtime `eval()` (AGENTS.md
    // "eval and runtime code construction"), so these false-reject
    // for an out-of-scope reason rather than a real engine bug. All
    // 40 fixtures share the `eval-` prefix; the rest of the
    // `statementList/` tree (positive parsing tests) stays attempted.
    "language/statementList/eval-",

    // `language/literals/regexp/*` — every failing fixture in this
    // family probes RegExp parser reach via runtime `eval()`:
    // `eval("/" + cu + "/")`, `eval("/(?<a\uD801>.)/")`, etc. The
    // RegExp literal under test is genuinely parser-shaped, but the
    // verification harness is `eval`, so the fixtures false-reject
    // for the permanent SES carve-out (AGENTS.md "eval and runtime
    // code construction") rather than a real regex-parser bug. The
    // 20 `S7.8.5_A*` Sputnik variants share the prefix; the three
    // V8 fixtures (7.8.5-1, named-groups/invalid-lone-surrogate-
    // groupname, mongolian-vowel-separator-eval) are listed exactly.
    "language/literals/regexp/S7.8.5_A",
    "language/literals/regexp/7.8.5-1.js",
    "language/literals/regexp/named-groups/invalid-lone-surrogate-groupname.js",
    "language/literals/regexp/mongolian-vowel-separator-eval.js",

    // `language/statements/function/{13.0-8-s,13.0-12-s,13.0_4-17gs,
    // 13.1-2-s,13.1-4-s,13.2-10-s..13.2-19-s,name-unicode,
    // S13.2.2_A8_T3}` — every fixture in this Sputnik-era
    // batch tests strict-mode reachability by constructing a
    // function body from a string via `Function("…")` /
    // `new Function("…")` / `Function.call(this,"src")` /
    // `eval("function f(){…}")`. All four mechanisms are the
    // permanent SES carve-out per AGENTS.md (“eval and runtime
    // code construction”): §15.3.2 (Function constructor),
    // §19.2.1 (eval). The non-Function-string siblings (e.g.
    // `S13_A3_T1`, `S14_A2`, `params-dflt-ref-arguments`) stay
    // attempted — they test other behaviour and surface as
    // honest engine bugs when they fail. 13 fixtures, each
    // listed by basename for clarity.
    "language/statements/function/13.0-8-s.js",
    "language/statements/function/13.0-12-s.js",
    "language/statements/function/13.0_4-17gs.js",
    "language/statements/function/13.1-2-s.js",
    "language/statements/function/13.1-4-s.js",
    "language/statements/function/13.2-10-s.js",
    "language/statements/function/13.2-11-s.js",
    "language/statements/function/13.2-12-s.js",
    "language/statements/function/13.2-13-s.js",
    "language/statements/function/13.2-14-s.js",
    "language/statements/function/13.2-15-s.js",
    "language/statements/function/13.2-16-s.js",
    "language/statements/function/13.2-17-s.js",
    "language/statements/function/13.2-18-s.js",
    "language/statements/function/13.2-19-s.js",
    "language/statements/function/name-unicode.js",
    "language/statements/function/S13.2.2_A8_T3.js",
    // `S13.2.2_A1_T1` / `_T2` — Sputnik-era fixtures that set
    // `factory.prototype = someFunction` and expect
    // `new factory()` to install the function as the new
    // instance's `[[Prototype]]`. Per §6.1.7 a JSFunction is an
    // Object, so the spec permits this; Cynic models `JSObject`
    // and `JSFunction` as two distinct heap types, and the
    // `JSObject.prototype` slot is `?*JSObject` — there's no
    // chain link for a function. Closing this would mean
    // either unifying the heap types or adding a function-
    // proto adapter, both bigger than the surface this fixture
    // exercises. Skip until that lands. Tracked as a *pending
    // engine refactor* — listed here under PERMANENT so the
    // corpus denominator stays exact; the
    // `pending_refactor_exact_paths` list in CURRENTLY SKIPPED
    // collects the originally-deferred stragglers.
    "language/statements/function/S13.2.2_A1_T1.js",
    "language/statements/function/S13.2.2_A1_T2.js",

    // `language/function-code/10.4.3-1-{13,15,17,19,63,64,65}-s.js`
    // and the matching `-gs.js` siblings — Sputnik-era strict-mode
    // `this`-binding tests that wrap the function body in
    // `Function("…")` / `new Function("…")` / `eval("…")` to verify
    // strict-mode reachability. All three mechanisms are the permanent
    // SES carve-out per AGENTS.md ("eval and runtime code
    // construction"): §15.3.2 (Function constructor), §19.2.1 (eval).
    // The other failing fixtures in `language/function-code/` exercise
    // real engine concerns (primitive-receiver accessor `this`,
    // var/parameter redeclaration, strict-mode FunctionDeclaration
    // hoisting) and stay attempted. 14 fixtures, listed by basename
    // for clarity — the surrounding `10.4.3-1-1XX.js` etc. fixtures
    // that don't use Function/eval stay attempted, as do the 14
    // `-noStrict`-flagged siblings (`10.4.3-1-{14,16,18,82,83,84}-s.js`
    // / `gs.js`) which Cynic's strict-only mode drops before run.
    "language/function-code/10.4.3-1-13-s.js",
    "language/function-code/10.4.3-1-13gs.js",
    "language/function-code/10.4.3-1-15-s.js",
    "language/function-code/10.4.3-1-15gs.js",
    "language/function-code/10.4.3-1-17-s.js",
    "language/function-code/10.4.3-1-17gs.js",
    "language/function-code/10.4.3-1-19-s.js",
    "language/function-code/10.4.3-1-19gs.js",
    "language/function-code/10.4.3-1-63-s.js",
    "language/function-code/10.4.3-1-63gs.js",
    "language/function-code/10.4.3-1-64-s.js",
    "language/function-code/10.4.3-1-64gs.js",
    "language/function-code/10.4.3-1-65-s.js",
    "language/function-code/10.4.3-1-65gs.js",

    // `language/module-code/eval-rqstd-{once,order}.js` — both
    // fixtures import sibling `*_FIXTURE.js` modules whose bodies
    // do `Function('return this;')()` to retrieve the global. The
    // FIXTUREs are imports, not includes, so the harness-shipped
    // `fnGlobalObject.js` stub (which substitutes `globalThis`)
    // doesn't intercept them — the source-string Function call
    // executes verbatim and false-rejects on Cynic's permanent SES
    // carve-out (§15.3.2 Function constructor; AGENTS.md "eval and
    // runtime code construction"). The `eval-rqstd-` prefix only
    // matches these two test fixtures (FIXTURE files aren't loaded
    // as test entries by the harness). 2 fixtures.
    "language/module-code/eval-rqstd-",

    // `language/expressions/dynamic-import/{eval-rqstd-once,
    // update-to-dynamic-import}.js` — same shape as the
    // `module-code/eval-rqstd-` pair above: each test `import()`s a
    // sibling `*_FIXTURE.js` module whose body retrieves the global
    // via `Function('return this;')()`. The FIXTURE is an import,
    // not an `includes:`, so the harness `fnGlobalObject.js` stub
    // never intercepts it — the source-string Function call runs
    // verbatim and false-rejects on Cynic's permanent SES carve-out
    // (§15.3.2 Function constructor; AGENTS.md "eval and runtime
    // code construction"). The `.js` suffix in each substring keeps
    // the match off the `*_FIXTURE.js` / `-other_FIXTURE.js`
    // companions (which aren't loaded as test entries anyway).
    // 2 fixtures.
    "dynamic-import/eval-rqstd-once.js",
    "dynamic-import/update-to-dynamic-import.js",

    // `language/expressions/async-arrow-function/prototype.js` — the
    // test itself is fine (the `[[Prototype]]` of an async arrow IS
    // `%AsyncFunction.prototype%`, verified independently), but it
    // resolves `%AsyncFunction%` through the harness include
    // `wellKnownIntrinsicObjects.js`, which obtains *every* intrinsic
    // via `new Function("return " + source)()`. Cynic ships no
    // runtime code construction (§15.3.2; AGENTS.md), so that helper
    // silently yields `undefined` and `getWellKnownIntrinsicObject`
    // throws. A permanent SES carve-out in a harness dependency, same
    // shape as the `Function('return this;')()` cases above.
    "async-arrow-function/prototype.js",

    // `built-ins/TypedArrayConstructors/ctors/no-species.js` — the
    // fixture's first assertion reads `mysteryTA.buffer.__proto__`
    // and expects it to be `ArrayBuffer.prototype`. Cynic does not
    // install the `Object.prototype.__proto__` accessor (Annex B
    // §B.2.2.1 — see AGENTS.md "Annex B in its entirety — out"), so
    // `.__proto__` reads back as `undefined` and `assert.sameValue`
    // fails. The behaviour the fixture actually targets — that
    // `TypedArray` construction doesn't look up `Symbol.species` —
    // runs correctly; only the `__proto__` probe trips the permanent
    // carve-out (the sibling `.buffer.constructor` assertion passes).
    // The fixture isn't `[__proto__]`-feature-tagged so the feature
    // skip doesn't catch it; substring it.
    "TypedArrayConstructors/ctors/no-species.js",
};

/// Sputnik-era fixtures that exercise `Function(string)` /
/// `eval(string)` to set up the receiver, build the function under
/// test, or observe scope behaviour. Each fixture is permanently
/// OOS per AGENTS.md (SES carve-out). Identified by exhaustive scan
/// against the failing set; listed as exact paths because they cross
/// too many directories for a clean prefix or suffix.
pub const ses_exact_paths = [_][]const u8{
    "built-ins/Boolean/S9.2_A1_T1.js",
    // §15.3.2 `new Function()` / §19.2.1 `eval(string)` — five
    // long-tail fixtures across scattered buckets that each build
    // a Function-shape via the zero-arg `new Function()` form or
    // observe direct eval. The zero-arg constructor still routes
    // through §15.3.2 CreateDynamicFunction so it's the same
    // permanent SES carve-out (AGENTS.md "eval and runtime code
    // construction"). The eval-spread fixtures probe the §13.3.6
    // direct-eval call-form (spread args / leading empty spread)
    // and `language/types/reference/8.7.2-1-s.js` asserts the
    // strict-mode ReferenceError reach for `eval("_ref = 11;")`.
    "built-ins/AggregateError/newtarget-proto-fallback.js",
    "built-ins/Reflect/apply/arguments-list-is-not-array-like-but-still-valid.js",
    "language/expressions/call/eval-spread-empty-leading.js",
    "language/expressions/call/eval-spread.js",
    "language/types/reference/8.7.2-1-s.js",
    "built-ins/Function/15.3.5.4_2-11gs.js",
    "built-ins/Function/15.3.5.4_2-7gs.js",
    "built-ins/Function/15.3.5.4_2-9gs.js",
    "built-ins/Function/S15.3.1_A1_T1.js",
    "built-ins/Function/StrictFunction_reservedwords_with.js",
    "built-ins/Function/StrictFunction_restricted-properties.js",
    "built-ins/Function/length/S15.3.5.1_A1_T1.js",
    "built-ins/Function/length/S15.3.5.1_A1_T2.js",
    "built-ins/Function/length/S15.3.5.1_A1_T3.js",
    "built-ins/Function/length/S15.3.5.1_A2_T1.js",
    "built-ins/Function/length/S15.3.5.1_A2_T2.js",
    "built-ins/Function/length/S15.3.5.1_A2_T3.js",
    "built-ins/Function/length/S15.3.5.1_A3_T1.js",
    "built-ins/Function/length/S15.3.5.1_A3_T2.js",
    "built-ins/Function/length/S15.3.5.1_A3_T3.js",
    "built-ins/Function/length/S15.3.5.1_A4_T1.js",
    "built-ins/Function/length/S15.3.5.1_A4_T2.js",
    "built-ins/Function/length/S15.3.5.1_A4_T3.js",
    "built-ins/Function/private-identifiers-not-empty.js",
    "built-ins/Function/prototype/S15.3.5.2_A1_T1.js",
    "built-ins/Function/prototype/toString/Function.js",
    "built-ins/Object/entries/tamper-with-global-object.js",
    // §18.2.1 — `eval` is not shipped (AGENTS.md strict-only
    // policy). Sputnik fixture probes `global.eval`'s own
    // descriptor; without eval the test can't be evaluated.
    "built-ins/Object/getOwnPropertyDescriptor/15.2.3.3-4-4.js",
    "built-ins/Object/getOwnPropertyDescriptor/15.2.3.3-4-187.js",
    "built-ins/Object/getOwnPropertyDescriptor/15.2.3.3-4-188.js",
    // §27.3.2 / §27.4.2 / §27.7.2 — these `Object.seal` fixtures
    // build the receiver via `new (Object.getPrototypeOf(asyncFn).
    // constructor)()` which lands on AsyncFunction / Generator
    // Function / AsyncGeneratorFunction. Cynic doesn't ship the
    // string-source constructors for those (permanent SES carve-
    // out, see AGENTS.md). Sealing itself works (covered by
    // `object-seal-o-is-a-function-object.js`); the construction
    // is the OOS step.
    "built-ins/Object/seal/seal-asyncfunction.js",
    "built-ins/Object/seal/seal-asyncarrowfunction.js",
    "built-ins/Object/seal/seal-asyncgeneratorfunction.js",
    "built-ins/Object/seal/seal-generatorfunction.js",
    // §25.2 SharedArrayBuffer — not shipped. The fixture sets
    // up the SAB then calls `Object.seal` on it.
    "built-ins/Object/seal/seal-sharedarraybuffer.js",
    // §25.1.5.x `ArrayBuffer.prototype.{byteLength, detached,
    // maxByteLength, resizable, resize, slice, transfer,
    // transferToFixedLength}` each step 2 says "If
    // IsSharedArrayBuffer(O) is true, throw a TypeError". The
    // `this-is-sharedarraybuffer*.js` fixtures all construct the
    // receiver via `new SharedArrayBuffer(...)` — a global Cynic
    // does not ship per AGENTS.md "shared memory… single-agent-
    // per-isolate". Without the constructor the assertion can't
    // be exercised. Permanent SES carve-out.
    "built-ins/ArrayBuffer/prototype/byteLength/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/detached/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/detached/this-is-sharedarraybuffer-resizable.js",
    "built-ins/ArrayBuffer/prototype/maxByteLength/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/resizable/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/resize/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/slice/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/transfer/this-is-sharedarraybuffer.js",
    "built-ins/ArrayBuffer/prototype/transferToFixedLength/this-is-sharedarraybuffer.js",
    // §25.2 SharedArrayBuffer again — these `TypedArrayConstructors`
    // fixtures build their backing store via `new SharedArrayBuffer(…)`
    // before the assertion they actually want to test (a SAB-backed
    // TypedArray re-wrapped by a TypedArray ctor; an indexed
    // `[[Delete]]` on a SAB-backed view). Without the constructor the
    // setup throws before the spec step under test runs. Same
    // permanent SES carve-out as the `ArrayBuffer` block above.
    "built-ins/TypedArrayConstructors/ctors/buffer-arg/typedarray-backed-by-sharedarraybuffer.js",
    "built-ins/TypedArrayConstructors/ctors-bigint/buffer-arg/typedarray-backed-by-sharedarraybuffer.js",
    "built-ins/TypedArrayConstructors/internals/Delete/indexed-value-sab-strict.js",
    "built-ins/TypedArrayConstructors/internals/Delete/BigInt/indexed-value-sab-strict.js",
    // §18.2.1 — global.eval is not shipped (AGENTS.md). The
    // ES5-era fixture iterates an expected-globals list that
    // includes `eval` and `Date` (duplicated), failing on a
    // policy-skipped global.
    "built-ins/Object/getOwnPropertyNames/15.2.3.4-4-1.js",
    "built-ins/Object/values/tamper-with-global-object.js",
    "built-ins/RegExp/S15.10.4.1_A5_T3.js",
    "built-ins/RegExp/S15.10.4.1_A8_T11.js",
    "built-ins/RegExp/prototype/source/value-empty.js",
    "built-ins/RegExp/prototype/source/value-line-terminator.js",
    "built-ins/RegExp/prototype/source/value-slash.js",
    "built-ins/RegExp/prototype/source/value-u.js",
    "built-ins/RegExp/prototype/source/value.js",
    "built-ins/String/S9.8_A1_T1.js",
    "built-ins/String/prototype/charAt/S15.5.4.4_A1.1.js",
    "built-ins/String/prototype/charCodeAt/S15.5.4.5_A1.1.js",
    "built-ins/String/prototype/indexOf/S15.5.4.7_A3_T2.js",
    "built-ins/String/prototype/match/S15.5.4.10_A1_T3.js",
    "built-ins/String/prototype/replace/S15.5.4.11_A1_T6.js",
    "built-ins/String/prototype/split/checking-by-using-eval.js",
    "built-ins/String/prototype/split/separator-regexp-limit-string-via-eval.js",
    "built-ins/String/prototype/toLocaleLowerCase/S15.5.4.17_A1_T3.js",
    "built-ins/String/prototype/toLocaleUpperCase/S15.5.4.19_A1_T3.js",
    "built-ins/String/prototype/toLowerCase/S15.5.4.16_A1_T3.js",
    "built-ins/String/prototype/toUpperCase/S15.5.4.18_A1_T3.js",
    "built-ins/undefined/S15.1.1.3_A1.js",
    "language/arguments-object/10.5-1-s.js",
    "language/arguments-object/10.5-7-b-1-s.js",
    "language/comments/S7.4_A5.js",
    "language/comments/S7.4_A6.js",
    "language/comments/hashbang/eval.js",
    // §19.2.1 indirect `(0, eval)('…')` — the fixture asserts that
    // a hashbang comment is permitted at the start of indirect-eval
    // source text. Without runtime `eval()` (permanent SES carve-out
    // per AGENTS.md) the assertion can't be exercised; the sibling
    // direct-eval (`eval.js`) is already skipped above.
    "language/comments/hashbang/eval-indirect.js",
    // §15.3.2 / §27.{3,4,7}.2 — `function-constructor.js` iterates
    // `[Function, AsyncFunction, GeneratorFunction,
    // AsyncGeneratorFunction]` and asserts each `ctor('#!\n_', '')`
    // throws SyntaxError (hashbang not allowed as the first token
    // of a string-source function body). Cynic doesn't ship the
    // source-string constructors (permanent SES carve-out per
    // AGENTS.md "eval and runtime code construction"), so the call
    // throws TypeError before the parser would have a chance to
    // reject the hashbang.
    "language/comments/hashbang/function-constructor.js",
    "language/comments/hashbang/no-line-separator.js",
    "language/comments/mongolian-vowel-separator-single-eval.js",
    "language/expressions/addition/S11.6.1_A1.js",
    "language/expressions/arrow-function/arrow/capturing-closure-variables-1.js",
    "language/expressions/async-function/named-strict-error-reassign-fn-name-in-body-in-eval.js",
    "language/expressions/async-generator/eval-body-proto-realm.js",
    "language/expressions/async-generator/named-strict-error-reassign-fn-name-in-body-in-eval.js",
    "language/expressions/bitwise-and/S11.10.1_A1.js",
    "language/expressions/bitwise-not/S11.4.8_A1.js",
    "language/expressions/bitwise-or/S11.10.3_A1.js",
    "language/expressions/bitwise-xor/S11.10.2_A1.js",
    "language/expressions/call/11.2.3-3_5.js",
    "language/expressions/call/S11.2.3_A1.js",
    "language/expressions/call/eval-first-arg.js",
    "language/expressions/call/eval-spread-empty-trailing.js",
    "language/expressions/call/eval-strictness-inherit-strict.js",
    "language/expressions/comma/S11.14_A1.js",
    "language/expressions/concatenation/S9.8_A1_T2.js",
    "language/expressions/conditional/S11.12_A1.js",
    "language/expressions/division/S11.5.2_A1.js",
    "language/expressions/division/no-magic-asi-from-block-eval.js",
    "language/expressions/does-not-equals/S11.9.2_A1.js",
    "language/expressions/does-not-equals/S11.9.2_A6.1.js",
    "language/expressions/dynamic-import/usage-from-eval.js",
    "language/expressions/equals/S11.9.1_A1.js",
    "language/expressions/equals/S11.9.1_A6.1.js",
    "language/expressions/function/named-strict-error-reassign-fn-name-in-body-in-eval.js",
    "language/expressions/generators/eval-body-proto-realm.js",
    "language/expressions/generators/named-strict-error-reassign-fn-name-in-body-in-eval.js",
    "language/expressions/greater-than-or-equal/S11.8.4_A1.js",
    "language/expressions/greater-than/S11.8.2_A1.js",
    "language/expressions/grouping/S11.1.6_A1.js",
    "language/expressions/import.meta/not-accessible-from-direct-eval.js",
    "language/expressions/import.meta/syntax/goal-function-params-or-body.js",
    "language/expressions/in/S11.8.7_A1.js",
    "language/expressions/instanceof/S11.8.6_A1.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T1.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T2.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T3.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T4.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T5.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T6.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T7.js",
    "language/expressions/instanceof/S15.3.5.3_A1_T8.js",
    "language/expressions/instanceof/S15.3.5.3_A2_T5.js",
    "language/expressions/instanceof/S15.3.5.3_A3_T1.js",
    "language/expressions/left-shift/S11.7.1_A1.js",
    "language/expressions/less-than-or-equal/S11.8.3_A1.js",
    "language/expressions/less-than/S11.8.1_A1.js",
    "language/expressions/logical-and/S11.11.1_A1.js",
    "language/expressions/logical-not/S11.4.9_A1.js",
    "language/expressions/logical-not/S9.2_A1_T2.js",
    "language/expressions/logical-or/S11.11.2_A1.js",
    "language/expressions/modulus/S11.5.3_A1.js",
    "language/expressions/multiplication/S11.5.1_A1.js",
    "language/expressions/new/S11.2.2_A1.1.js",
    "language/expressions/new/S11.2.2_A1.2.js",
    "language/expressions/object/11.1.5-0-1.js",
    "language/expressions/object/11.1.5-0-2.js",
    "language/expressions/object/11.1.5_4-4-a-3.js",
    "language/expressions/object/11.1.5_4-4-b-1.js",
    "language/expressions/object/11.1.5_6-3-1.js",
    "language/expressions/object/11.1.5_6-3-2.js",
    "language/expressions/object/11.1.5_7-3-1.js",
    "language/expressions/object/11.1.5_7-3-2.js",
    // §13.3.9 optional-chaining `eval?.('a')` — the fixture asserts
    // that the optional call form on `eval` performs indirect eval
    // (resolves bindings in the global scope, not the local one).
    // Cynic doesn't ship `eval()` (permanent SES carve-out per
    // AGENTS.md "eval and runtime code construction"), so the call
    // surfaces as a "not callable" reject rather than the expected
    // indirect-eval semantics.
    "language/expressions/optional-chaining/eval-optional-call.js",
    "language/expressions/property-accessors/S11.2.1_A1.1.js",
    "language/expressions/property-accessors/S11.2.1_A1.2.js",
    "language/expressions/right-shift/S11.7.2_A1.js",
    "language/expressions/strict-does-not-equals/S11.9.5_A1.js",
    "language/expressions/strict-does-not-equals/S11.9.5_A6.1.js",
    "language/expressions/strict-equals/S11.9.4_A1.js",
    "language/expressions/strict-equals/S11.9.4_A6.1.js",
    "language/expressions/subtraction/S11.6.2_A1.js",
    "language/expressions/super/prop-dot-cls-val-from-eval.js",
    "language/expressions/super/prop-dot-obj-val-from-eval.js",
    "language/expressions/super/prop-expr-cls-val-from-eval.js",
    "language/expressions/super/prop-expr-obj-val-from-eval.js",
    "language/expressions/tagged-template/cache-differing-expressions-eval.js",
    "language/expressions/tagged-template/cache-differing-expressions-new-function.js",
    "language/expressions/tagged-template/cache-eval-inner-function.js",
    "language/expressions/tagged-template/cache-identical-source-eval.js",
    "language/expressions/tagged-template/cache-identical-source-new-function.js",
    "language/expressions/template-literal/mongolian-vowel-separator-eval.js",
    "language/expressions/this/S11.1.1_A3.2.js",
    "language/expressions/this/S11.1.1_A4.1.js",
    "language/expressions/this/S11.1.1_A4.2.js",
    "language/expressions/typeof/syntax.js",
    "language/expressions/unary-minus/S11.4.7_A1.js",
    "language/expressions/unary-plus/S11.4.6_A1.js",
    "language/expressions/unary-plus/S9.3_A1_T2.js",
    "language/expressions/unsigned-right-shift/S11.7.3_A1.js",
    "language/expressions/void/S11.4.2_A1.js",
    "language/global-code/script-decl-lex-var-declared-via-eval.js",
    // §15.3.2 Function constructor — `instn-same-global.js` imports
    // `instn-same-global-set_FIXTURE.js` whose body is `new Function(
    // 'return this;')().test262 = 262`. The imported FIXTURE isn't an
    // `includes:` entry (it's a module import), so Cynic's
    // `fnGlobalObject.js` stub doesn't intercept; the source-string
    // Function call false-rejects on the permanent SES carve-out
    // (AGENTS.md "eval and runtime code construction").
    "language/module-code/instn-same-global.js",
    "language/line-terminators/S7.3_A5.4.js",
    "language/line-terminators/S7.3_A7_T1.js",
    "language/line-terminators/S7.3_A7_T2.js",
    "language/line-terminators/S7.3_A7_T3.js",
    "language/line-terminators/S7.3_A7_T4.js",
    "language/line-terminators/S7.3_A7_T5.js",
    "language/line-terminators/S7.3_A7_T6.js",
    "language/line-terminators/S7.3_A7_T7.js",
    "language/line-terminators/S7.3_A7_T8.js",
    "language/literals/numeric/7.8.3-3gs.js",
    "language/literals/string/line-separator-eval.js",
    "language/literals/string/mongolian-vowel-separator-eval.js",
    "language/literals/string/paragraph-separator-eval.js",
    "language/statements/break/S12.8_A7.js",
    "language/statements/continue/S12.7_A7.js",
    "language/statements/do-while/S12.6.1_A3.js",
    "language/statements/do-while/S12.6.1_A5.js",
    "language/statements/do-while/S12.6.1_A7.js",
    "language/statements/do-while/S12.6.1_A8.js",
    "language/statements/expression/S12.4_A2_T1.js",
    "language/statements/expression/S12.4_A2_T2.js",
    "language/statements/for-in/S12.6.4_A3.1.js",
    "language/statements/for-in/S12.6.4_A3.js",
    "language/statements/for-in/S12.6.4_A4.1.js",
    "language/statements/for-in/S12.6.4_A4.js",
    "language/statements/for/S12.6.3_A5.js",
    "language/statements/for/head-init-expr-check-empty-inc-empty-completion.js",
    "language/statements/for/head-init-var-check-empty-inc-empty-completion.js",
    "language/statements/if/S12.5_A2.js",
    "language/statements/try/catch-parameter-boundnames-restriction-arguments-eval-throws.js",
    "language/statements/try/catch-parameter-boundnames-restriction-eval-eval-throws.js",
    "language/statements/try/completion-values.js",
    "language/statements/variable/12.2.1-16-s.js",
    "language/statements/variable/12.2.1-17-s.js",
    "language/statements/variable/12.2.1-18-s.js",
    "language/statements/variable/12.2.1-19-s.js",
    "language/statements/variable/12.2.1-2-s.js",
    "language/statements/variable/12.2.1-3-s.js",
    "language/statements/variable/12.2.1-4-s.js",
    "language/statements/variable/12.2.1-5-s.js",
    "language/statements/variable/12.2.1-6-s.js",
    "language/statements/variable/12.2.1-7-s.js",
    "language/statements/variable/12.2.1-8-s.js",
    "language/statements/while/S12.6.2_A3.js",
    "language/statements/while/S12.6.2_A5.js",
    "language/statements/while/S12.6.2_A7.js",
    "language/statements/while/S12.6.2_A8.js",
    "language/statements/with/12.10.1-10-s.js",
    "language/statements/with/12.10.1-5-s.js",
    "language/white-space/comment-multi-form-feed.js",
    "language/white-space/comment-multi-horizontal-tab.js",
    "language/white-space/comment-multi-nbsp.js",
    "language/white-space/comment-multi-space.js",
    "language/white-space/comment-multi-vertical-tab.js",
    "language/white-space/comment-single-form-feed.js",
    "language/white-space/comment-single-horizontal-tab.js",
    "language/white-space/comment-single-nbsp.js",
    "language/white-space/comment-single-space.js",
    "language/white-space/comment-single-vertical-tab.js",
    "language/white-space/mongolian-vowel-separator-eval.js",
    "language/white-space/string-form-feed.js",
    "language/white-space/string-horizontal-tab.js",
    "language/white-space/string-nbsp.js",
    "language/white-space/string-space.js",
    "language/white-space/string-vertical-tab.js",
    // `built-ins/Iterator/{zip,zipKeyed}/result-is-iterator.js`
    // (joint-iteration) — both assert the result's `[[Prototype]]`
    // is `%IteratorHelperPrototype%`, obtained through the harness
    // include `wellKnownIntrinsicObjects.js`, which resolves every
    // intrinsic via `new Function("return " + source)()`. Cynic bans
    // runtime code construction (§15.3.2; AGENTS.md "eval and runtime
    // code construction"), so the helper throws "could not obtain
    // %IteratorHelperPrototype%" before the assertion runs — same
    // permanent SES carve-out as `async-arrow-function/prototype.js`.
    // The sibling `result-is-iterator.js` fixtures (iterator-helpers
    // map/filter/take/drop/flatMap, iterator-sequencing concat)
    // obtain the prototype directly and stay attempted.
    "built-ins/Iterator/zip/result-is-iterator.js",
    "built-ins/Iterator/zipKeyed/result-is-iterator.js",
};

/// AND-pair filters — both substrings must appear in the path. Used
/// when a coarse substring (`/class/elements/`) would over-skip, but
/// a generated-fixture suffix (`-eval-`, `-eval.js`) narrows it to
/// exactly the eval-dependent generated set. The §15.7 spec rule
/// ("eval inside class field initializer contains super → SyntaxError
/// at PerformEval-time") needs an actual eval — without one, Cynic
/// throws the wrong error class and these fixtures false-reject.
/// SES-aligned out of scope alongside the rest of eval.
pub const ses_substring_pairs = [_][2][]const u8{
    .{ "/class/elements/", "-eval-" },
    // `built-ins/Promise/<staticMethod>/ctx-non-ctor.js` —
    // each fixture asserts `Promise.<m>.call(eval)` throws
    // TypeError because `eval` is not a constructor. Without
    // SES's `eval` global the receiver is a ReferenceError,
    // not a TypeError — the test misclassifies the cause.
    // Covers `resolve`, `reject`, `all`, `allSettled`, `any`,
    // `race`, `try`, `withResolvers`. The constructor-arg
    // path is exercised by the other `ctx-*` siblings (e.g.
    // `ctx-ctor.js`, `ctx-ctor-throws.js`) which stay
    // attempted.
    .{ "built-ins/Promise/", "ctx-non-ctor.js" },
};

// ── Single-realm host ───────────────────────────────────────────────
//
// `$262.createRealm()` IS exposed to the test262 harness (a real
// child `Realm` sharing the parent heap — see `test262CreateRealm`),
// so the cross-realm *setup* runs. But Cynic resolves errors and
// identity against the *active* realm, not a per-call-frame realm, so
// these fixtures stay skipped — each asserts a realm-of-origin
// property (the thrower's realm on a cross-realm TypeError, per-realm
// tagged-template caches, `GetFunctionRealm` over a Proxy chain).
// Production `cynic` exposes no `$262` at all. Permanent realm-
// attribution carve-out per AGENTS.md.

pub const single_realm_exact_paths = [_][]const u8{
    // §9.3.3 / §9.5.4 — `$262.createRealm()`-using cross-realm
    // fixtures spread across `Array.prototype.{slice,map,filter,
    // splice,concat}/create-proto-from-ctor-realm-array.js`,
    // `Proxy/{apply,construct,get-fn-realm,get-fn-realm-recursive}`,
    // `Function/internals/Construct/derived-{return-val,this-
    // uninitialized}-realm.js`, the `non-generic-realm` siblings on
    // `String.prototype.{toString,valueOf}`, `JSON/stringify/value-
    // bigint-cross-realm`, `Error/isError/errors-other-realm`, and
    // `language/expressions/super/realm.js`. Each is tagged
    // `features: [cross-realm]` and bottoms out on
    // `$262.createRealm().global` — but Cynic resolves errors /
    // identity against the active realm (see the `/cross-realm.`
    // path-contains entry; these basenames don't match it, so list
    // them exact). Permanent realm-attribution carve-out per
    // AGENTS.md. 17 fixtures.
    // `non-error-objects-other-realm.js` builds the other realm's
    // object via `new other.Function('')` — runtime code construction,
    // so it stays skipped until `--allow=eval` lands.
    "built-ins/Error/isError/non-error-objects-other-realm.js",
    "built-ins/Function/internals/Construct/derived-return-val-realm.js",
    "built-ins/Function/internals/Construct/derived-this-uninitialized-realm.js",
    // `JSON/stringify/value-bigint-cross-realm` and the
    // `String.prototype.{toString,valueOf}/non-generic-realm` siblings
    // need realm-aware throws Cynic doesn't model under its single realm.
    "built-ins/JSON/stringify/value-bigint-cross-realm.js",
    "built-ins/Proxy/apply/arguments-realm.js",
    "built-ins/Proxy/construct/arguments-realm.js",
    "built-ins/Proxy/construct/trap-is-undefined-proto-from-newtarget-realm.js",
    "built-ins/Proxy/get-fn-realm-recursive.js",
    "built-ins/Proxy/get-fn-realm.js",
    "built-ins/String/prototype/toString/non-generic-realm.js",
    "built-ins/String/prototype/valueOf/non-generic-realm.js",
    "language/expressions/super/realm.js",
    // Scattered single-realm fixtures with no bulk pattern to match,
    // so listed exact. Each bottoms out on `$262.createRealm().global`
    // or asserts a realm-of-origin TypeError. Same permanent carve-out.
    "built-ins/Function/call-bind-this-realm-undef.js",
    "built-ins/Function/call-bind-this-realm-value.js",
    "built-ins/Function/internals/Call/class-ctor-realm.js",
    "built-ins/RegExp/prototype/Symbol.split/splitter-proto-from-ctor-realm.js",
    "built-ins/ThrowTypeError/distinct-cross-realm.js",
    "language/types/reference/get-value-prop-base-primitive-realm.js",
    "language/types/reference/put-value-prop-base-primitive-realm.js",
    // §13.3.10 tagged-template — the fixture uses
    // `$262.createRealm().evalScript('…')` to build a tag in
    // another realm, then asserts the call-site template object
    // cache is per-realm. Same carve-out as the patterns above;
    // basename doesn't match `/cross-realm.`, so listed exactly.
    "language/expressions/tagged-template/cache-realm.js",
};

// NOTE: there is no longer a single-realm *path-contains* needle.
// The `/cross-realm.` families now run and pass (multi-realm error /
// identity attribution landed for them), and the `-realm-function-ctor.`
// straggler is an eval refusal — it classifies as an `expected fail`
// via the `eval` policy (`pathPolicyKind` / `ses_substrings`), not a
// counted skip. The exact-path siblings here stay PERMANENT because
// their spec story doesn't move under any plausible future Cynic
// posture.

// ════════════════════════════════════════════════════════════════════
// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  CURRENTLY SKIPPED  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
// ════════════════════════════════════════════════════════════════════
//
// Standardised work blocked on engineering, vendor, or stage
// maturity. Lifts once the proposal advances or the blocking infra
// lands. Filtered alongside the permanent set so today's
// `test262-results.md` doesn't carry the noise, but tracked
// separately so the "what work is left" signal stays visible.

// ── Stage maturity ──────────────────────────────────────────────────
//
// TC39 proposals not yet in a published edition whose grammar
// would break the parser if we attempted to handle the fixture.
// Reviewed each release cycle; promote out of here once
// implemented.

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

/// Path-prefix skips for pre-Stage-4 proposals whose entire
/// fixture sub-tree would otherwise score as 0 / N noise. Same
/// stage-maturity rationale as `stage_maturity_features`: the
/// proposal hasn't reached a published edition yet, so shipping
/// conformance against it isn't the point.
pub const stage_maturity_path_prefixes = [_][]const u8{
    // Empty: ShadowRealm — the one Stage-2.7 surface that might live
    // here — ships behind `--enable=ShadowRealm`, so the harness scores
    // it in the `feature:ShadowRealm` phase rather than skipping by path.
};

// ── Vendor gaps ─────────────────────────────────────────────────────
//
// Standardised features blocked on the vendored libregexp matcher
// (QuickJS-NG) or on Unicode-property data we haven't shipped.
// Reviewed each libregexp / Unicode bump.

pub const vendor_features = [_][]const u8{
    // Empty: no feature-tagged proposal is currently blocked on the
    // vendored libregexp matcher or on unshipped Unicode-property data.
};

pub const vendor_path_contains = [_][]const u8{
    // Empty: the native Perlex engine now owns the `\p{…}` property
    // escapes and the whole `/v` UnicodeSets grammar, so no RegExp path
    // bottoms out on a libregexp gap today.
};

// ── Single-realm path-contains ──────────────────────────────────────
//
// Cross-realm fixture families spread across many buckets. Each
// bottoms out on `$262.createRealm()` / `new Realm(`. Tracked as
// deferred because per the inline comments we'd lift these if
// multi-realm landed; the *exact*-path single-realm siblings
// live in PERMANENT above (their spec story doesn't move under
// any plausible future Cynic posture).

pub const single_realm_path_contains = [_][]const u8{
    // Cross-realm fixtures that depend on per-realm *error / identity
    // attribution*. `$262.createRealm()` IS exposed to the test262
    // harness (a real child `Realm` sharing the parent heap — see
    // `test262CreateRealm`), so three whole families that used to live
    // here now run:
    //   • `proto-from-ctor-realm*.js` — §10.1.14
    //     GetPrototypeFromConstructor derives the default prototype
    //     from `GetFunctionRealm(newTarget)`'s intrinsics
    //     (`remapDefaultProtoToCtorRealm` in lantern/call.zig), so a
    //     `newTarget` minted by `other.Function` resolves to the
    //     *other* realm's `%X.prototype%`.
    //   • the RegExp-prototype-getter `cross-realm.js` siblings
    //     (`dotAll`/`global`/`hasIndices`/`ignoreCase`/`multiline`/
    //     `source`/`sticky`/`unicode`/`unicodeSets`) — each asserts the
    //     §22.2.6 brand-check / SameValue TypeError comes from the
    //     *other* realm. The getters resolve `%RegExpPrototype%` and
    //     throw via `active_native_fn_realm` (the dispatcher records
    //     the callee getter's realm before it runs — regexp.zig).
    //   • `Function.prototype.{apply,bind}/*-realm.js` — apply's
    //     §20.2.3.1 IsCallable / CreateListFromArrayLike TypeErrors
    //     route through the callee realm (`active_native_fn_realm`,
    //     function.zig); bind's §10.2.5 GetFunctionRealm walks the
    //     `[[BoundTargetFunction]]` chain (`bound.realm = target.realm`
    //     + `getFunctionRealm()` recursion) so the proto lookup picks
    //     the innermost target's realm.
    //
    // The broader `Symbol/*/cross-realm.js` and
    // `RegExp/escape/cross-realm.js` fixtures are NOT realm-of-origin
    // tests — they assert only *identity / functional* invariants
    // (well-known symbols and the global symbol registry are agent-wide
    // per §6.1.5.1 / §20.4.2.2, and a cross-realm functional call works
    // because the child shares the parent heap). `test262CreateRealm`
    // already calls `shareWellKnownSymbolsWith` and the registry lives
    // on the shared `heap.symbol_registry`, so those pass — they are
    // deliberately NOT matched here.
    //
    // The one straggler — the `-multiple-evaluations-of-class-realm-
    // function-ctor.js` private-brand fixtures — builds its class via
    // `new other.Function(sourceString)`, i.e. the eval surface. That's
    // an eval refusal by design, so it classifies as an **expected
    // fail** via the `eval` policy (`pathPolicyKind` matches the
    // `-multiple-evaluations-of-class-realm-function-ctor` needle in
    // `ses_substrings`), NOT an in-corpus skip. So this list is empty:
    // no cross-realm family is a counted skip today.
};

// ── Implementation pending ──────────────────────────────────────────
//
// Standardised surfaces Cynic hasn't gotten to yet. Multi-week
// projects path-skipped wholesale so they don't drown the
// scoreboard in 0 / N noise.

pub const deferred_path_prefixes = [_][]const u8{
    // Empty: the whole Temporal namespace ships (ISO calendar only,
    // offset-only/UTC time zones — no IANA tzdata), so nothing under
    // `built-ins/Temporal/` is deferred. The `skip: Temporal fully in
    // scope` test guards against a subtree regressing back to here.
};

// ── eval-dependent — eval surface, individual-fixture form ──────────
//
// Single fixtures that reach their assertion through `eval` /
// `new Function(string)` but don't *test the eval feature* — they test
// some other feature and merely wrap it in `eval("…")`, so no prefix
// or substring rule catches them. Consumed by `pathPolicyKind` as part
// of the `eval` policy: a failure here classifies as `correctly
// handled` (eval surface off) rather than a real bug. When
// `--allow=eval` ships, these would move from correctly-handled to
// plain passing.

pub const eval_dependent_exact_paths = [_][]const u8{
    // `built-ins/Function/prototype/S15.3.5.2_A1_T2.js` — uses
    // `Function(void 0, "")` (string-body Function constructor).
    // The fixture verifies the `prototype` slot's `DontDelete` on
    // a function built from a source string; without the eval-
    // policy opt-in there's no way to construct the function in
    // the first place.
    "built-ins/Function/prototype/S15.3.5.2_A1_T2.js",
    // Sputnik `language/types/string/S8.4_A7.*.js` (4 fixtures) —
    // every one wraps an `eval("var x = asdf<LineTerminator>ghjk")`
    // expecting ReferenceError because the line terminator
    // terminates the var declaration. Without `eval()` the
    // assertion can't reach the parse error.
    "language/types/string/S8.4_A7.1.js",
    "language/types/string/S8.4_A7.2.js",
    "language/types/string/S8.4_A7.3.js",
    "language/types/string/S8.4_A7.4.js",
    // Not here despite using `eval`: the four indirect-eval fixtures
    // `language/statements/variable/12.2.1-{9,10,20,21}-s.js` assert
    // that an *indirect* eval runs its body as sloppy code (§19.2.1.1
    // PerformEval), so `var eval;` / `arguments = 42;` etc. don't throw.
    // Strict-only Cynic parses the eval'd source in strict mode and
    // throws, so they'd fail even with `--allow=eval` — they're a
    // permanent strict-only carve-out in `strict_only_exact_paths`, a
    // different structural reason than the eval-surface fixtures here.
    // `proto-from-ctor-realm` cross-realm fixtures whose `newTarget`
    // (or asserted constructor) is built from a *source string* —
    // `other.eval('(0, function* () {})')`, `new other.Function(body)`,
    // or `Reflect.construct(other.Function, [body], nt)`. The §10.1.14
    // default-proto fix (`remapDefaultProtoToCtorRealm` in
    // lantern/call.zig) recovered the rest of the family, but these
    // can't even build their newTarget / asserted constructor without
    // runtime code construction — permanent eval-surface carve-out,
    // same as the rest of this list.
    "built-ins/AsyncFunction/proto-from-ctor-realm.js",
    "built-ins/AsyncGeneratorFunction/proto-from-ctor-realm.js",
    "built-ins/AsyncGeneratorFunction/proto-from-ctor-realm-prototype.js",
    "built-ins/Function/proto-from-ctor-realm-prototype.js",
    "built-ins/GeneratorFunction/proto-from-ctor-realm.js",
    "built-ins/GeneratorFunction/proto-from-ctor-realm-prototype.js",
};

// ── Focused refactor pending ────────────────────────────────────────
//
// Reserved for fixtures blocked on a small, bounded engine refactor.

pub const pending_refactor_exact_paths = [_][]const u8{
    // (empty — no fixtures are currently blocked on a bounded engine
    //  refactor. The cross-realm ordinary-function construct cluster
    //  that lived here — Array/from, Array/of, Function/prototype/bind
    //  proto-from-ctor-realm — was closed by two coordinated changes:
    //  (1) §10.2.2 base-kind [[Construct]] now derives its
    //  intrinsicDefaultProto as %Object.prototype% (resolved against the
    //  ctor realm) for ordinary-function targets at every construct site
    //  — `constructValue` + `Reflect.construct` + the interpreter
    //  `new_call` opcode (ordinary & bound) — via
    //  `baseConstructIntrinsicDefaultProto` in lantern/call.zig; and
    //  (2) the empty function from `new Function()` is flagged
    //  `native_ordinary_function` so it's treated as the ordinary
    //  function it is (§20.2.1.1.1) rather than a built-in constructor
    //  keying off its own `.prototype` slot — the fixtures build their
    //  cross-realm constructor as `new other.Function()`, which is
    //  native-implemented in Cynic.)
};

// ════════════════════════════════════════════════════════════════════
//   Lookup
// ════════════════════════════════════════════════════════════════════

pub fn pathIsSkipped(rel_path: []const u8) bool {
    for (corpus_excluded_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// Tech-debt skips by path: fixtures *in* scope that Cynic skips
/// **today** but should eventually pass once it finishes the
/// engineering it owes — a cross-realm fixture awaiting multi-realm
/// error attribution, or a published-edition feature blocked on a
/// vendor/infra gap. The caller keeps these **in** `total` and counts
/// them as `skip`, so they lower `pass%` — the live "work left"
/// signal. (A fixture that simply *fails* a policy Cynic ships by
/// design is not here — it runs and classifies as `correctly handled`
/// via `pathPolicyKind`. Pre-Stage-4 proposals aren't here either —
/// they're recognised by feature tag in `featureIsUnimplementedProposal`.)
///
/// Empty right now: every source array below is empty, so this returns
/// false for every path today. (The `-realm-function-ctor.` private-
/// brand fixtures that were the one needle here are eval-surface
/// refusals — they now classify as `expected fails` via the `eval`
/// policy in `pathPolicyKind`, not as counted skips.)
pub fn pathIsCurrentlySkipped(rel_path: []const u8) bool {
    inline for (.{ stage_maturity_path_prefixes, deferred_path_prefixes }) |group| {
        for (group) |prefix| {
            if (std.mem.startsWith(u8, rel_path, prefix)) return true;
        }
    }
    for (vendor_path_contains) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return true;
    }
    for (single_realm_path_contains) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return true;
    }
    for (pending_refactor_exact_paths) |exact| {
        if (std.mem.eql(u8, rel_path, exact)) return true;
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
//   Policy classification
// ════════════════════════════════════════════════════════════════════
//
// For a fixture that ran and FAILED, decide whether the failure is one
// Cynic produces *by design* — and therefore counts as "correctly
// handled" rather than a real bug. Four path/frontmatter-derived
// policies live here; the fifth (`ses`) is matched by the harness
// against the runtime error pattern (`tools/test262/ses_divergent.zig`)
// because it's only knowable after the throw.
//
//   annex_b   — Annex B language / built-ins / regex grammar; Cynic is
//               a strict-only edge target, no Annex B.
//   no_strict — `flags: [noStrict]` or a strict-only carve-out path.
//   intl402   — `intl402/` tree or an `Intl`-prefixed feature tag;
//               Cynic doesn't ship Intl.
//   eval      — the eval surface (`eval` / `new Function(string)` /
//               `GeneratorFunction(string)` / …); off unless `--allow=eval`.
//
// First match wins, in priority order annex_b > no_strict > intl402 >
// eval. SharedArrayBuffer / Atomics are NOT a policy — Cynic could ship
// shared memory, so those failures stay plain `failing`.

pub const PolicyKind = enum {
    annex_b,
    no_strict,
    intl402,
    eval,
    ses,
};

/// Map a fixture failure to its policy bucket, if any. SES classification
/// is *not* handled here — the harness runs the SES divergence matcher
/// against the thrown error after the fixture executes. This returns
/// the first matching path/frontmatter-derived policy in priority order.
///
/// `features` is the fixture's frontmatter `features:` list (may be
/// empty). `no_strict` is the parsed `flags: [noStrict]` bit.
pub fn pathPolicyKind(
    rel_path: []const u8,
    features: []const []const u8,
    no_strict: bool,
) ?PolicyKind {
    // Priority 1 — annex_b. Path tree first, then exact paths under the
    // main tree that need Annex B leniency, then feature tags.
    for (annex_b_path_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return .annex_b;
    }
    for (annex_b_regex_exact_paths) |exact| {
        if (std.mem.eql(u8, rel_path, exact)) return .annex_b;
    }
    for (annex_b_features) |feat| {
        for (features) |f| if (std.mem.eql(u8, f, feat)) return .annex_b;
    }

    // Priority 2 — no_strict.
    if (no_strict) return .no_strict;

    // Priority 3 — intl402.
    if (std.mem.startsWith(u8, rel_path, "intl402/")) return .intl402;
    // Frontmatter feature tags for Intl — `Intl.*`, `Intl-enumeration`,
    // `IntlPluralRules` historical names. Cheap prefix check covers all
    // forms in the corpus.
    for (features) |f| if (std.mem.startsWith(u8, f, "Intl")) return .intl402;

    // Priority 4 — eval surface. Eval prefixes + substrings + exact
    // paths + eval-dependent exact paths. SAB/Atomics deliberately
    // excluded (plain fail).
    for (eval_path_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return .eval;
    }
    for (ses_substrings) |needle| {
        if (std.mem.indexOf(u8, rel_path, needle) != null) return .eval;
    }
    for (ses_substring_pairs) |pair| {
        if (std.mem.indexOf(u8, rel_path, pair[0]) != null and
            std.mem.indexOf(u8, rel_path, pair[1]) != null) return .eval;
    }
    inline for (.{ ses_exact_paths, eval_dependent_exact_paths }) |group| {
        for (group) |exact| {
            if (std.mem.eql(u8, rel_path, exact)) return .eval;
        }
    }
    // Strict-only carve-out paths — `with` in a strict-only engine and
    // the four indirect-eval Sputnik fixtures. The latter genuinely
    // need sloppy mode (per `strict_only_exact_paths`'s comment) so they
    // classify as no_strict; the hashbang/ShadowRealm strict-mode ones
    // are also strict-only carve-outs. Conservatively bucket as
    // `no_strict` since that's the structural reason.
    for (strict_only_exact_paths) |exact| {
        if (std.mem.eql(u8, rel_path, exact)) return .no_strict;
    }

    return null;
}

// ════════════════════════════════════════════════════════════════════
//   Tests
// ════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "skip: corpus-walk exclusions" {
    // Only `harness/` and `staging/` are walk-excluded now. intl402
    // RUNS under the new model (failures classify as the intl402
    // policy), so it must NOT be path-skipped.
    try testing.expect(pathIsSkipped("harness/sta.js"));
    try testing.expect(pathIsSkipped("staging/explicit-resource-management/foo.js"));
    try testing.expect(!pathIsSkipped("intl402/Locale/extensions.js"));
    try testing.expect(!pathIsSkipped("language/expressions/optional-chaining/foo.js"));
    try testing.expect(!pathIsSkipped("annexB/B.1.1/legacy-octal.js"));
}

test "policy: annex_b" {
    // The whole annexB/ tree.
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("annexB/built-ins/escape/empty-string.js", &.{}, false).?);
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("annexB/language/comments/single-line-html-open.js", &.{}, false).?);
    // Main-tree fixture needing Annex B regex-grammar leniency.
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("built-ins/String/prototype/split/separator-regexp.js", &.{}, false).?);
    // Annex B feature tags (§B.2.2 accessors, legacy regexp, IsHTMLDDA).
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("x.js", &.{"__proto__"}, false).?);
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("x.js", &.{"IsHTMLDDA"}, false).?);
}

test "policy: no_strict" {
    // `flags: [noStrict]` bit.
    try testing.expectEqual(PolicyKind.no_strict, pathPolicyKind("language/statements/for-in/x.js", &.{}, true).?);
    // Strict-only carve-out paths (the `with`-hashbang fixture, the
    // four indirect-eval Sputnik fixtures, the ShadowRealm sloppy one).
    try testing.expectEqual(PolicyKind.no_strict, pathPolicyKind("language/comments/hashbang/use-strict.js", &.{}, false).?);
    try testing.expectEqual(PolicyKind.no_strict, pathPolicyKind("language/statements/variable/12.2.1-9-s.js", &.{}, false).?);
}

test "policy: intl402" {
    try testing.expectEqual(PolicyKind.intl402, pathPolicyKind("intl402/NumberFormat/x.js", &.{}, false).?);
    // Intl-prefixed feature tag on a non-intl402 path.
    try testing.expectEqual(PolicyKind.intl402, pathPolicyKind("built-ins/x.js", &.{"Intl.Segmenter"}, false).?);
}

test "policy: eval surface" {
    // Whole eval sub-trees.
    try testing.expectEqual(PolicyKind.eval, pathPolicyKind("language/eval-code/direct/var.js", &.{}, false).?);
    try testing.expectEqual(PolicyKind.eval, pathPolicyKind("built-ins/eval/length.js", &.{}, false).?);
    // Function(string) substring family.
    try testing.expectEqual(PolicyKind.eval, pathPolicyKind("built-ins/Function/S15.3.2.1_A1_T1.js", &.{}, false).?);
    // eval-dependent exact path (tests another feature via eval).
    try testing.expectEqual(PolicyKind.eval, pathPolicyKind("language/types/string/S8.4_A7.1.js", &.{}, false).?);
    // Function.prototype methods stay real engine surface (no policy).
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("built-ins/Function/prototype/apply/length.js", &.{}, false));
}

test "policy: SAB / Atomics are NOT a policy (plain fail)" {
    // Cynic could ship shared memory, so a SAB/Atomics failure stays
    // `failing`, not `correctly handled`.
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("built-ins/Atomics/load/length.js", &.{}, false));
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("built-ins/SharedArrayBuffer/length.js", &.{}, false));
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind(
        "built-ins/TypedArrayConstructors/ctors/buffer-arg/byteoffset-is-negative-throws-sab.js",
        &.{},
        false,
    ));
}

test "policy: in-scope fixtures have no policy" {
    // A normal passing fixture isn't policy-classified.
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("built-ins/Array/prototype/at/length.js", &.{}, false));
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("language/expressions/addition/order-of-evaluation.js", &.{}, false));
    // Temporal ships — in scope, no policy.
    try testing.expectEqual(@as(?PolicyKind, null), pathPolicyKind("built-ins/Temporal/PlainDateTime/prototype/add/branding.js", &.{}, false));
}

test "policy: priority — annex_b before eval" {
    // A path that is both Annex B and reaches through eval resolves to
    // annex_b (higher priority).
    try testing.expectEqual(PolicyKind.annex_b, pathPolicyKind("annexB/built-ins/escape/eval.js", &.{}, false).?);
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

test "skip: tech-debt path skips (counted in total, lower pass%)" {
    // No tech-debt path skips today — every source array is empty.
    // The `-realm-function-ctor.` private-brand fixtures that used to
    // sit here are eval refusals: they classify as `expected fails`
    // via the `eval` policy in `pathPolicyKind`, not as counted skips.
    const rfc = "language/expressions/class/private-method-brand-check-multiple-evaluations-of-class-realm-function-ctor.js";
    try testing.expect(!pathIsCurrentlySkipped(rfc));
    try testing.expectEqual(PolicyKind.eval, pathPolicyKind(rfc, &.{}, false).?);
    // Temporal fully ships — not a tech-debt skip.
    try testing.expect(!pathIsCurrentlySkipped("built-ins/Temporal/Now/extensible.js"));
    try testing.expect(!pathIsCurrentlySkipped("built-ins/Temporal/PlainDateTime/prototype/add/branding.js"));
    // RegExp /v and property-escape surfaces ship via Perlex — not skipped.
    try testing.expect(!pathIsCurrentlySkipped(
        "built-ins/RegExp/property-escapes/special-property-value-Script_Extensions-Unknown.js",
    ));
    try testing.expect(!pathIsCurrentlySkipped(
        "built-ins/RegExp/unicodeSets/generated/character-class-difference-character.js",
    ));
}

test "skip: ShadowRealm is not path-skipped (feature-gated)" {
    // ShadowRealm ships behind `--enable=ShadowRealm`; the harness's
    // per-phase feature-tag gate keeps it out of the main rows, not a
    // skip.zig path list. So neither walk-skip nor tech-debt-skip fires.
    try testing.expect(!pathIsSkipped("built-ins/ShadowRealm/constructor.js"));
    try testing.expect(!pathIsCurrentlySkipped("built-ins/ShadowRealm/constructor.js"));
    // The sloppy-mode `evaluate` fixture classifies as no_strict policy.
    try testing.expectEqual(
        PolicyKind.no_strict,
        pathPolicyKind("built-ins/ShadowRealm/prototype/evaluate/no-conditional-strict-mode.js", &.{}, false).?,
    );
}
