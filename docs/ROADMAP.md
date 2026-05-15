# Cynic — Roadmap

_Sections below are themes, not strict timelines — many run in parallel._

## Status

Live scores, per-area breakdown, and history are in
[test262-results.md](../test262-results.md). That file is the
single source of truth; this roadmap deliberately doesn't snapshot
numbers so it can't drift.

`spec%` is `pass / total` on the Cynic-targeted corpus (excludes
universally out-of-scope paths — Annex B language extensions,
`harness/`, `staging/`, `intl402/`, browser-era built-ins).
`attempted%` is `pass / (pass + fail)` — quality of what's shipped,
ignoring skips.

`zig build test` runs all unit tests; `zig build test262 -- --quiet`
runs the conformance harness.

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
  `for` / `for-in` / `for-of` / `for-await-of` (incl. lhs
  destructuring), `switch`, labeled statements, lexical
  declarations with TDZ positioning, `class` declarations,
  `function` / `function*` / `async function*` (with `yield*`
  delegation), ES6 modules (`import` / `export` / namespace
  imports / re-exports).

**In progress / on the watch.**

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
  (with microtask-deferred `.then` reactions and pending-promise
  yield-await chaining), bound functions, classes (constructors,
  methods, static, private fields + methods, accessors, `extends`
  / `super` / `super[expr]`).
- Object model: own data + accessor properties with descriptor
  flags, prototype chain, `[[Extensible]]`, frozen / sealed /
  prevent-extensions, integer-indexed properties, ArraySetLength
  with strict-mode failure semantics, well-known `@@`-prefixed
  symbol keys, `Symbol.toPrimitive` integration in
  `==` / `!=` / `<` / `>` / `<=` / `>=` / arithmetic operators.
- Iteration: `iter_open` opcode, generator `next` / `return` /
  `throw`, async-generator `next` returning Promises,
  `iter_close` on for-of break + return walking the loop chain.
  `yield*` delegation for sync and async generators (spec-faithful
  `IteratorClose` / `AsyncIteratorClose` on abrupt completion).
  `for-await-of` end-to-end against async iterators (§14.7.5),
  including the sync-iterable-to-async-iterable wrap.
- Optional chaining (`?.`) + nullish coalescing (`??`) +
  logical-assignment (`&&=` / `\|\|=` / `??=`) including member
  targets + computed keys.
- Argument spread in regular calls + `new` (lowered to
  `Reflect.construct`).
- Microtask queue + `await` suspension via generator-shaped frame
  saves; promise reaction queue with then / catch / finally.
- Stop-the-world mark-sweep heap, fired on allocation pressure
  — both a count trigger (`gc_threshold` allocations between
  cycles, default 16,384) and a byte trigger (`gc_byte_threshold`,
  default 16 MiB) so allocate-and-discard string concat patterns
  GC promptly. Roots: globals, intrinsics, microtask queue,
  modules, top-level chunks, active call frames, open handle
  scopes. The heap stays bounded under any allocating loop /
  recursion / promise chain. Always-on counters surface
  `bytes_alloc_total` / `bytes_live_peak` / `gc_cycles_total`
  / `gc_time_ns_total` for engine-side memory profiling via the
  harness `--mem-summary` / `--top-alloc` / `--gc-stats` flags.
  Operational details + `HandleScope` contract for natives:
  [docs/handbook/gc.md](handbook/gc.md).
- Per-test interpreter step budget — the test262 harness caps
  each fixture at 50M opcodes so a `while(true){}` can't wedge
  the sweep.

**In progress / planned.**

- Generator `.return()` running pending `finally` blocks inside
  the body (currently only finally-on-throw fires).
- Tail-call optimization (PTC).
- Top-level `await` in modules.
- `typeof` of a callable proxy returning `"function"`.
- Plug the four known-leaking patterns at `gc_threshold=1`
  (generator wrapper iteration, promise microtask chain,
  property-bag growth, array spread) — see
  [docs/handbook/gc.md](handbook/gc.md#known-root-gaps).
- Generational / incremental GC.

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
  `resolve`, `reject`, `try`, `withResolvers`) + prototype `then`
  / `catch` / `finally`. Aggregators go through §27.2.1.5
  NewPromiseCapability and forward each item via
  `Invoke(item, "then", « cap.resolve, cap.reject »)`, so
  microtask ordering matches the spec.
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
  `filter`, `take`, `drop`, `flatMap`, `toArray`, `forEach`,
  `find`, `some`, `every`, `reduce`).
- TypedArrays + DataView covering the common surface.
- Error class hierarchy: `Error`, `TypeError`, `RangeError`,
  `ReferenceError`, `SyntaxError`, `URIError`, `EvalError`,
  `AggregateError`.

**Caveats / planned.**

- `Date` is UTC-only — `getTimezoneOffset` returns 0; locale
  formatting falls back to ISO. Real timezone handling needs a
  tz-data source.
- `String.prototype.normalize` is a passthrough — needs UCD
  normalization tables for real NFC/NFD/NFKC/NFKD.
- `Set.prototype.{union, intersection, difference,
  symmetricDifference, isSubsetOf, isSupersetOf, isDisjointFrom}`
  (ES2025) — not yet wired.
- `WeakRef` / `FinalizationRegistry` — not yet.
- `Function.prototype.toString` — returns the original source slice
  for declared functions; callable Proxy returns the spec sentinel
  `function () { [native code] }`. Remaining edge: CR vs LF
  normalization (test262 `line-terminator-normalisation-CR.js`).

**Deferred.** `Temporal` (ES2025) is not implemented yet —
~4500 test262 fixtures depend on it. It's a complete date/time
API replacement (calendars, time zones, ISO 8601, etc.) and a
multi-week project with its own tzdata story; until then it
stays feature-gated as `Temporal`, counts in the score
denominator, and pulls runtime spec% down accordingly. That's
intentional — it's the largest known coverage gap.

**Out of scope.** Annex B in its entirety — language extensions
*and* every browser-era built-in (`escape` / `unescape`, the
String HTML wrappers, `Date.prototype.{getYear, setYear,
toGMTString}`, `String.prototype.{substr, trimLeft, trimRight}`,
`Object.prototype.__proto__` accessor and the `__define*` /
`__lookup*` family, `RegExp.{$1, input, …}` legacy globals).
`Intl`; `SharedArrayBuffer` / `Atomics` (path-skipped — shared
memory defeats SES-style isolation, and Cynic's edge-runtime
hosts are single-agent-per-isolate).

## Modules

**Done.**

- ES6 module syntax (`import` / `export` / namespace re-exports)
  parses + compiles. Single-file evaluation works.
- `Realm.evaluateScript` host hook (powers multi-file
  `cynic run` and the test262 harness loader). Not exposed to
  user JS.
- `import.meta` (returns a fresh empty object — no metadata yet).
- Dynamic `import()` against the host module loader — fulfilled
  with the namespace on success, rejected with the loader's
  `TypeError` on failure (§13.3.10).

**Planned.**

- Real module graph: cyclic imports, namespace objects via
  `import * as ns`, hoisted `import` bindings with TDZ.
- Top-level `await` in module bodies.

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

**Acknowledged exception — Annex B regex grammar (§B.1.4).**
The vendored libregexp (QuickJS-NG) accepts a handful of
permissive forms that apply only when the pattern is compiled
*without* the `u` (or `v`) flag — e.g. `\1` outside a capturing
group treated as octal `\001`, and the lower-bound-elided
quantifier `{,n}`. With `u` / `v` both forms correctly throw
`SyntaxError`; without the flag libregexp accepts them, as
Annex B is part of the normative spec and every shipping
engine (V8 / JSC / SpiderMonkey) accepts the same forms.

This is the **only** Annex B carve-out Cynic ships. Everywhere
else the "no Annex B" stance from AGENTS.md is enforced
(language extensions, browser-era built-ins, accessor / legacy-
global aliases). Closing this leak would mean patching vendored
libregexp or building a Cynic-side pattern pre-validator on
top of it; both cost more than the leak is worth, real-world
regex code relies on the leak, and the `annexB/built-ins/
RegExp/` test corpus is already path-skipped.

## Tooling

**Done.**

- `cynic parse <file>` / `cynic eval '<expr>'` / `cynic run <file>`.
- `zig build test262 -- ...` parser and runtime modes; harness
  loads `harness/sta.js` + `assert.js` automatically; per-file
  outcome on `--verbose`; failure list on `--list-failures=N`;
  results history in [test262-results.md](../test262-results.md).
- Score history written by `--write-results`. Fast iteration via
  `--only-failing` (skip-as-pass any path in
  `.test262-pass-cache.txt`, ~5× faster than a full sweep).
- Memory / leak instrumentation: `--gc-stats` (per-cycle pool
  counts + bytes), `--mem-summary` (end-of-sweep totals),
  `--top-rss=N` (heaviest fixtures by process RSS delta),
  `--top-alloc=N` (heaviest by cumulative bytes allocated —
  catches GC-cleaned thrash that RSS hides),
  `--leak-check` (route the per-fixture bytes allocator through
  `std.heap.DebugAllocator`; stack trace per unfreed allocation
  at exit), `--max-rss=<mb>` (abort with the offending fixture
  path when RSS crosses budget).
- CI: `zig build` + `zig build test` gating; test262 advisory
  + a `test262-rss-smoke` advisory job that prints per-fixture
  RSS deltas via `--top-rss`.

**Planned.**

- REPL.
- Disassembler integration on `cynic run --dump-bytecode`.
- Source-map–style position info in stack traces.

## Performance

Cynic targets edge runtimes — fast cold-start, small RSS,
predictable latency. The interpreter has never been a perf-first
target so far (correctness has dominated), but every item below
is on the menu. Cross-engine measurement infrastructure lives at
[docs/benchmarking.md](benchmarking.md); per-commit micro-bench
deltas are produced by the `/perf` slash command and hot-function
sampling by `/profile`.

**In progress.**

- **Profile-driven hotspot list** — `samply` over a test262
  runtime sweep, top-N hot functions exported as a per-commit
  artifact. Drives what gets optimized next. Driver lives at
  `tools/profile.sh`; slash command at `/profile`.
- **`/perf` micro-bench harness** — `tools/bench.zig` runs a
  fixed JS micro-bench suite under `zig-out/bin/cynic run`, prints
  wall time + max RSS per fixture, diffs against a prior baseline
  in `bench-results.md`. Phase 1 of [docs/benchmarking.md](benchmarking.md);
  full JetStream 2 / Octane integration is Phase 2.

**Planned (largest-win-first, after the profile data points at one).**

- **Inline property-shape caches** on hot member access. Every
  major engine built this *first*: V8 hidden classes, JSC structure
  IDs, SM shape trees. Today Cynic does an `ArrayHashMap` lookup
  per `.x` access; ICs collapse that to a one-cmp guard on the hot
  path. Biggest single win for typical JS workloads (10-100× on
  hot member access). Architectural; expensive to add but pays for
  itself many times over.
- **Real `JSArray` heap kind** with packed indexed storage as the
  base case, sparse fallback only for true sparse arrays. Some of
  this exists (`elements: ArrayListUnmanaged(Value)` +
  `is_array_exotic` flag); a unified heap kind would let the
  arithmetic / loop opcodes skip the per-access `is_array_exotic`
  branch and read `elements.items.ptr[i]` directly.
- **Generational GC** — nursery + tenuring. Most allocations die
  young; today's full mark-sweep walks the whole heap on every
  trigger. V8 Orinoco, SM nursery, Hermes YoungGen, JSC Riptide
  all do this first. Incremental marking is the next step after
  that, for long-pause amortization.
- **Inlined `Value` ops in the dispatch loop.** Worth checking the
  `ReleaseFast` disassembly of `Op.add` / `Op.lda` / property reads
  — Zig inlines aggressively but the per-opcode handler structure
  may still leave hot ops behind a function-call boundary. Cheap
  if the disassembly is bad; no-op if it's already inlined.
- **String concat in-place / ConsString**. Today every `result =
  result + x` (and `result += x`) allocates a fresh
  `len(result) + len(x)`-byte JSString. In tight build-string loops
  this is O(N²) cumulative bytes — measurably so on test262: each
  fixture under `built-ins/RegExp/CharacterClassEscapes/` allocates
  ~270 MB cumulative for a final string of a few MB (12 fixtures
  alloc ~1.6 GiB combined; surfaced by `--top-alloc`). The byte
  trigger keeps RSS bounded (~255 MB peak across 35 GC cycles)
  but the wall-time cost is real.

  **Cost re-estimate (after sketching):** a "compiler-only
  `add_inplace`" that only checks closure capture is unsound —
  intra-function aliasing (`let y = x; x = x + 'a';`) would let
  `y` observe the mutation. Correctness needs either real alias
  analysis (~2–3 days, brittle) or ConsString (the right answer):

  - **ConsString / ropes** — V8 / JSC style. `JSString` gets a
    `kind` discriminator (`flat` vs `cons (left, right, len)`);
    `concat()` is O(1); first observable use flattens to a single
    buffer. The ~412 `.bytes` access sites get a `flatten()`
    accessor (mostly mechanical, audit-heavy). Multi-day, no
    correctness risk because cons-strings are invisible at the
    JS level. Right answer when the perf cost becomes the
    bottleneck.
## Proper Tail Calls (PTC) — research

ES2015 §10.2.4 + §15.6.1 + §15.10.1 — function calls *in tail
position* (`return f(x)`, the last expression of an arrow body,
`return cond ? f() : g()`, etc.) MUST reuse the caller's stack
frame, not push a fresh one. Spec wording is mandatory; in practice
only **JavaScriptCore** ships it. Reflected in the test262 corpus
by ~35 fixtures gated on the `tail-call-optimization` feature flag,
all currently skipped in `tools/test262/skip.zig`.

### Cross-engine status (2026)

| Engine | PTC | Notes |
|---|---|---|
| JavaScriptCore | ✅ | Shipped 2016, still in. Bun inherits. |
| V8 | ❌ | Implemented briefly behind a flag (2016), removed. Cited reasons: lost stack frames break dev-tools / `Error.stack`, hot-path cost on every call site, and the [STC counter-proposal](https://github.com/tc39/proposal-ptc-syntax) wanting explicit `return continue f()` syntax. |
| SpiderMonkey | ❌ | [Tracking bug](https://bugzilla.mozilla.org/show_bug.cgi?id=1188320) open since 2015. |
| Hermes / QuickJS / XS / Boa | ❌ | None. |

### What it takes to ship in Cynic

1. **Static tail-position detection** during bytecode compilation.
   Per §15.10.1, a `CallExpression` is in tail position iff:
   - It's the `Expression` of a `ReturnStatement`, or
   - The last expression of an `ArrowFunction` ConciseBody, or
   - The consequent / alternate of a tail-position conditional, or
   - Inside a tail-position `,` / `&&` / `||` / `??` right-hand side,
   *and* not inside a `try` block whose `finally` runs after the
   call, *not* inside a `with` (Cynic doesn't ship `with` — easier),
   *not* inside a `for-of` / `for-in` that owes the iterator a
   `return()` call on early exit (§7.4.6 IteratorClose).
2. **A `tail_call` bytecode op.** Instead of pushing a new
   `CallFrame`, the handler overwrites the *current* frame's
   registers, locals, and chunk pointer in-place with the callee's,
   then re-enters the dispatch loop. The discipline matches the
   JSC pattern (`emit_op_tail_call`); the implementation lifts
   cleanly into Cynic's existing frame-stack-as-`ArrayList` model.
3. **Cleanup of pending `iter_close` ops at tail-call sites** —
   PTC must run them *before* the frame is reused, otherwise the
   open iterators stay open across the call (and the spec says
   the loop is supposed to close on early exit).
4. **`Error.stack` impact**: a tail-called function disappears
   from the chain Cynic threads through `unwindThrow`. Stack
   traces become harder to read. The decision to ship PTC is
   partly a decision to give that up; mirroring JSC's tradeoff
   is the most defensible position.

### Why deferred

- ~35 fixtures of test262 score, small relative to other clusters.
- The static-analysis machinery (tail-position detection, escape
  analysis through `try`/`finally`) is *the same machinery* a
  baseline JIT will want. Building it twice is wasteful.
- No production demand: edge-runtime workloads don't write
  deeply-recursive JS by accident, and the SES / Hardened-
  JavaScript layer above Cynic doesn't require PTC.

Revisit alongside the baseline-JIT scaffolding (Future work
section), at which point the analysis cost amortises across
PTC + inline-cache shape guards + dead-store elimination.

## Future work (post-strict-only-runtime)

- **Baseline JIT** — direct opcode-to-native, inline caches for
  property access. Modeled on JSC Baseline / V8 Sparkplug.
- **Optimizing JIT** — IR (SSA), type speculation from inline
  caches, deopt back to interpreter on guard failure. Modeled on
  JSC DFG / V8 TurboFan or Maglev.
