# Cynic — Roadmap

_Last refreshed at runtime conformance **40.67%** (21005 / 51639 test262
runtime tests, Cynic-targeted scope; parser at 54.76%). Sections below
are themes, not strict timelines — many run in parallel._

## Status

`spec%` is `pass / total` on the Cynic-targeted corpus (excludes
universally out-of-scope paths — Annex B language extensions,
`harness/`, `staging/`, `intl402/`, browser-era built-ins). `attempted%`
is `pass / (pass + fail)` — quality of what's shipped, ignoring skips.

| Layer | spec% | attempted% | pass / total | Notes |
|---|---|---|---|---|
| Parser | 54.76% | 95.61% | 28,542 / 52,125 | Strict-only; `InputElementRegExp` re-entry exposed for the parser |
| Runtime | 40.67% | 54.83% | 21,005 / 51,639 | Bytecode interpreter; reaches everything the parser accepts that doesn't depend on a missing built-in |

`zig build test` runs all unit tests; `zig build test262 -- --quiet`
runs the conformance harness. Score history + per-area breakdown live
in [test262-results.md](../test262-results.md).

## Lexer & parser

**Done.**

- Strict-only `InputElement{Div,RegExp}` lexer covering the full
  punctuator set, reserved words, all numeric forms (decimal / hex /
  octal / binary / BigInt), string literals with escapes, template
  literals, hashbang, private identifiers, and `\uXXXX` / `\u{...}`
  identifier escapes. Unicode tracks UCD `latest`.
- Recursive-descent / Pratt expression parser, ASI rules 1 and 2,
  diagnostic recovery, all strict-mode early errors (`eval` / `arguments`
  bindings, `delete` of bare ident, etc.), `StrictDirective`
  recognition.
- Full §13 expression grammar: literals, atoms, member / call /
  optional-chain (`?.`), `new`, spread, tagged templates, regex
  literals, classes, generators, async functions, async generators,
  arrow functions (concise + block body), destructuring patterns
  (array, object, rest, defaults, nesting, renaming), update / unary
  / binary / logical / nullish / conditional / sequence /
  assignment + compound assignment + logical-assignment.
- §14 statement grammar including `try` / `catch` / `finally`,
  `for` / `for-in` / `for-of` (incl. lhs destructuring),
  `switch`, labeled statements, lexical declarations with TDZ
  positioning, `class` declarations, `function` / `function*` /
  `async function*`, ES6 modules (`import` / `export` / namespace
  imports / re-exports).

**In progress / on the watch.**

- `for await of` — async iteration grammar.
- `yield*` — generator delegation (parser accepts; compiler errors).
- Top-level `await` in modules.
- Tagged template `.raw` access.

**Out of scope.** Annex B language extensions (no sloppy mode, no
labels-in-old-positions, no HTML-like comments, no legacy octal,
no for-in initializer); `eval` / `new Function(string)` / dynamic
code construction (aligns with SES).

## Bytecode & runtime

**Done.**

- NaN-boxed `Value` with int32 fast-path, double, bool, null,
  undefined, string, object, function, symbol, BigInt, Hole (TDZ).
- Bytecode VM with register file + accumulator, exception handler
  table, environment chains for `let` / `const` / `var` scoping,
  per-iteration env for `for` / `for-of` over `let`.
- Frames + call stack, return-completion, throw-completion,
  uncaught-throw → host. `try` / `catch` / `finally` including
  synthetic-handler for finally-on-throw and inlining of finally
  bodies on `return`.
- Functions: arrows, methods, generators, async, async generators
  (with synchronously-settled and pending-promise yield-await
  chaining), bound functions, classes (constructors, methods,
  static, private fields + methods, accessors, `extends` /
  `super` / `super[expr]`).
- Object model: own data + accessor properties with descriptor
  flags, prototype chain, `[[Extensible]]`, frozen / sealed /
  prevent-extensions, integer-indexed properties, ArraySetLength
  with strict-mode failure semantics, well-known `@@`-prefixed
  symbol keys, `Symbol.toPrimitive` integration in
  `==` / `!=` / `<` / `>` / `<=` / `>=` / arithmetic operators.
- Iteration: `iter_open` opcode, generator `next` / `return` /
  `throw`, async-generator `next` returning Promises,
  `iter_close` on for-of break + return walking the loop chain.
- Optional chaining (`?.`) + nullish coalescing (`??`) +
  logical-assignment (`&&=` / `\|\|=` / `??=`) including member
  targets + computed keys.
- Argument spread in regular calls + `new` (lowered to
  `Reflect.construct`).
- Microtask queue + `await` suspension via generator-shaped frame
  saves; promise reaction queue with then / catch / finally.

**In progress / planned.**

- `yield*` delegation.
- `for await of` end-to-end.
- Generator `.return()` running pending `finally` blocks inside
  the body (currently only finally-on-throw fires).
- Tail-call optimization (PTC).
- Top-level `await` in modules.
- `typeof` of a callable proxy returning `"function"`.

## Standard library

**Done (with caveats noted).**

- `Object`, `Array`, `String`, `Number`, `Boolean`, `BigInt`,
  `Symbol` constructors + prototypes covering the bulk of static
  and instance methods.
- `Function.prototype.{call, apply, bind}` + bound-function
  trampoline.
- `Math` (including the ES2022 additions); `JSON.stringify` +
  `JSON.parse`; URI handling globals (`encodeURI` /
  `encodeURIComponent` / `decodeURI` / `decodeURIComponent` with
  full UTF-8 validation throwing `URIError` on malformed input).
- `Date` with full getter / setter surface (UTC-only — see
  caveats).
- `Map`, `Set`, `WeakMap`, `WeakSet` with `groupBy` statics.
- `Promise` static methods (`all`, `allSettled`, `any`, `race`,
  `resolve`, `reject`) + prototype `then` / `catch` / `finally`.
- `Reflect` covering `apply`, `construct`, `defineProperty`,
  `deleteProperty`, `get`, `getOwnPropertyDescriptor`,
  `getPrototypeOf`, `has`, `isExtensible`, `ownKeys`,
  `preventExtensions`, `set`, `setPrototypeOf`.
- `Proxy` with `get`, `set`, `has`, `deleteProperty`,
  `defineProperty`, `getOwnPropertyDescriptor`, `ownKeys` traps;
  callable proxies (function-target forwarding).
- `RegExp` backed by vendored QuickJS-NG `libregexp.c` (full
  ECMA-262 conformance — flags, captures, lookaround, named
  groups, `u` / `v` flags). String methods (`match`, `matchAll`,
  `replace`, `replaceAll`, `search`, `split`) all dispatch
  through it.
- `Iterator` global with `from` + prototype helpers (`map`,
  `filter`, `take`, `drop`, `toArray`, `forEach`, `find`,
  `some`, `every`, `reduce`).
- TypedArrays + DataView covering the common surface.
- Error class hierarchy: `Error`, `TypeError`, `RangeError`,
  `ReferenceError`, `SyntaxError`, `URIError`.

**Caveats / planned.**

- `Date` is UTC-only — `getTimezoneOffset` returns 0; locale
  formatting falls back to ISO. Real timezone handling needs a
  tz-data source.
- `String.prototype.normalize` is a passthrough — needs UCD
  normalization tables for real NFC/NFD/NFKC/NFKD.
- `Set.prototype.{union, intersection, difference,
  symmetricDifference, isSubsetOf, isSupersetOf, isDisjointFrom}`
  (ES2025) — not yet wired.
- `Promise.{try, withResolvers}` — not yet.
- `WeakRef` / `FinalizationRegistry` — not yet.
- `Function.prototype.toString` returning real source — currently
  approximate.

**Deferred.** `Temporal` (ES2025) is not implemented yet —
~4500 test262 fixtures depend on it. It's a complete date/time
API replacement (calendars, time zones, ISO 8601, etc.) and a
multi-week project with its own tzdata story; until then it
stays feature-gated as `Temporal`, counts in the score
denominator, and pulls runtime spec% down accordingly. That's
intentional — it's the largest known coverage gap.

**Out of scope.** Annex B browser-era built-ins (`escape` /
`unescape`, `String.prototype` HTML wrappers, `Date.{getYear,
setYear}`); `Intl`; `SharedArrayBuffer` / `Atomics` (path-
skipped — shared memory defeats SES-style isolation, and
Cynic's edge-runtime hosts are single-agent-per-isolate).

## Modules

**Done.**

- ES6 module syntax (`import` / `export` / namespace re-exports)
  parses + compiles. Single-file evaluation works.
- `Realm.evaluateScript` host hook (powers multi-file
  `cynic run` and the test262 harness loader). Not exposed to
  user JS.
- `import.meta` (returns a fresh empty object — no metadata yet).
- Dynamic `import()` (returns a `Promise` rejected with
  `TypeError` — syntax compiles, semantics are stubbed).

**Planned.**

- Real module graph: cyclic imports, namespace objects via
  `import * as ns`, hoisted `import` bindings with TDZ.
- Top-level `await` in module bodies.
- Real dynamic `import()` resolution.

## Regex

**Done.** Vendored QuickJS-NG `libregexp.c` (MIT, ~3500 LOC C). Full
ECMA-262 surface — backreferences, named groups, lookahead /
lookbehind, `u` / `v` flags, sticky / global / multiline / dotAll
/ ignoreCase. Bridged from Zig with UTF-8 ↔ UTF-16 transcoding so
match indices land in spec-correct UTF-16 code units.

**Planned.** None for the engine itself; integration polish:
`RegExp.prototype` properties matching V8 / JSC for `lastIndex`,
`flags`, `dotAll` accessor; minor edge cases in the
String.prototype dispatch.

**Known imperfection (Annex B grammar leakage).** §B.1.4
extends regex grammar with permissive forms that apply only
when the pattern is compiled *without* the `u` (or `v`) flag —
e.g. `\1` outside a capturing group treated as octal `\001`,
and the lower-bound-elided quantifier `{,n}`. With `u` / `v`
both forms correctly throw `SyntaxError`; without the flag the
vendored libregexp accepts them, since Annex B is part of the
normative spec and every other shipping engine does the same.
Cynic's "Annex B not on the menu" stance is about *language*
Annex B (sloppy mode, `with`, function-in-block, HTML comments,
`escape`/`unescape`, the String HTML wrappers) — regex Annex B
is left as-is. Tightening would mean either patching vendored
libregexp or adding a Cynic-side pattern pre-validator; both
cost more than the leak is worth and the `annexB/built-ins/RegExp/`
test corpus is already path-skipped.

## Tooling

**Done.**

- `cynic parse <file>` / `cynic eval '<expr>'` / `cynic run <file>`.
- `zig build test262 -- ...` parser and runtime modes; harness
  loads `harness/sta.js` + `assert.js` automatically; per-file
  outcome on `--verbose`; failure list on `--list-failures=N`;
  results history in [test262-results.md](../test262-results.md).
- Score history written by `--write-results`.
- CI: `zig build` + `zig build test` gating; test262 advisory.

**Planned.**

- REPL.
- Disassembler integration on `cynic run --dump-bytecode`.
- Source-map–style position info in stack traces.

## Future work (post-strict-only-runtime)

- **Baseline JIT** — direct opcode-to-native, inline caches for
  property access. Modeled on JSC Baseline / V8 Sparkplug.
- **Optimizing JIT** — IR (SSA), type speculation from inline
  caches, deopt back to interpreter on guard failure. Modeled on
  JSC DFG / V8 TurboFan or Maglev.
