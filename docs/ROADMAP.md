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

- Top-level `await` cycles via the full
  [[PendingAsyncDependencies]] graph (§16.2.1.5). Today's
  `module_link_complete` opcode + `pending_async_deps` slot
  covers the direct-dep and CycleRoot-via-cycle-leaf cases
  observably, but skips the [[AsyncEvaluationOrder]] sort and
  reverse `[[AsyncParentModules]]` propagation. The bucket is
  at 250 / 251 today — only fixtures that exercise the sort
  ordering will land beyond what we have. See
  [`handbook/environments.md`](handbook/environments.md).
- StringLiteral export/import names (§16.2.3.5) — `export {
  "x" as "y" }` strips quotes and treats both sides as
  identifiers; `import { "y" as local }` and `export * as
  "ns"` ship.

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

- **Tail-call optimization (PTC).** See the dedicated section
  below.
- **Incremental / concurrent GC marking.** The generational
  collector — young/mature split, write barrier, remembered set,
  `collectYoung` with promotion-by-relink — has shipped (see the
  Performance section); incremental marking of the mature set is
  the remaining GC step.

**Recently landed (was in progress; now done).**

- **Monomorphic property cache — `lda_property` + `sta_property`
  + `call_method`.** Three opcodes grew a `u16` IC operand and a
  chunk-local `inline_caches` / `inline_call_caches` table; the
  fast path is a single pointer compare against the cached
  receiver shape (or callee) and a direct `slots[slot]` load /
  write. Backed by the existing shape transition tree (V8 /
  JSC / SM lineage). Measured on `bench/micros/`: `prop_access`
  −66 % (48.94 → 16.47 ms), `prop_write` −63 % (92.24 → 33.70 ms).
  Polymorphic chain dispatch is the natural follow-up, deferred
  until a workload surfaces a hot polymorphic site.

- **GC — mark-colour flip replaces per-cycle clear loop.** Each
  heap kind carries a `mark_color: u1` instead of `marked: bool`;
  the cycle-start `live_color` flip ages every existing object's
  `mark_color` to "unmarked" automatically. Eliminates seven
  linear walks over the mature set per minor cycle. V8 ships
  this inside `MarkingState`, SpiderMonkey in `MarkingTracer`,
  JSC's Riptide uses the same idea. Plus: registered symbols
  (`Symbol.for("k")`) now pin at registration time — the per-
  cycle re-mark loop over `symbol_registry` is gone too. The
  `cynic` CLI gained `--gc-threshold=<n>` (parity with the
  test262 harness flag), so `cynic --gc-threshold=1 run foo.js`
  runs a stress sweep without going through the harness.

- **"Everything but RegExp" sweep — May 2026** moved Cynic from
  89.39 % to 91.48 % spec / 93.51 % to 98.52 % attempted (+847
  pass). Buckets fully cleared: top-level-await, WeakSet,
  Math.sumPrecise (Stage 4 shipped), JSON/isRawJSON (Stage 4
  shipped), Object.prototype.valueOf, Object.fromEntries,
  dynamic-import/catch, statements + expressions/async-
  generator, compound-assignment, logical-assignment,
  Array.from, Array.of, String.fromCharCode, built-ins/global,
  class/elements, AsyncFromSyncIterator, Reflect.set,
  Proxy.ownKeys, statements/break, Function.prototype,
  language/types/string. Highlights below.

- **Top-level `await` in modules — full bucket green** (250 → 251
  on `language/module-code/top-level-await`). Three-stage roll-
  out: always-defer `await` (§27.7.5.3 PromiseResolve+then),
  async-module drain-to-settlement on static import, owning-
  module thread-through on resume so `module_export` after a
  TLA-await lands in the right namespace. Final finisher added
  the `module_link_complete` opcode (drains microtasks after the
  importer's hoisted import block so sync siblings get to run
  while an async dep is mid-`await`; CycleRoot-via-cycle-leaf
  ordering falls out without modelling [[CycleRoot]] directly).
  Drive-by: `loadModule` now properly save/restores
  `current_module` (was clobbering to `null` on return);
  `publishExportedNamesFromDecl` walks BindingPattern leaves so
  `export const { x } = obj` publishes `x`.

- **Proxy traps — full §9.5 invariant enforcement on proxy-of-
  proxy** (built-ins/Proxy: 81.67 → 90.68 % attempted). All
  five mutating traps (`get`, `set`, `has`, `deleteProperty`,
  `getOwnPropertyDescriptor`) recurse through chained Proxy
  ancestors; `Object.{keys, getOwnPropertyNames}` +
  `Reflect.ownKeys` route through the trap; strict-mode
  `delete` throws TypeError on trap-returned-false (§13.5.1.2
  step 6); `defineProperty`-trap-falsy → Reflect-false fall-
  through.

- **`super.method(...rest)` compile** (§13.3.7.1) — added
  `compileSuperSpreadMethodCall` as the apply-style parallel
  of `compileSpreadMethodCall`. Lands the seven Set
  `subclass-receiver-methods.js` fixtures plus collaterals.

- **§7.3.21 EnumerableOwnProperties for Object.{values,
  entries}** — Symbol + Proxy trap dispatch + per-key
  descriptor accessor walk.

- **§24 collection ctors — spec-faithful Map / WeakMap / Set
  / WeakSet** (Map 91 → 99 %, WeakMap 100 %, WeakSet 100 %,
  Set 91 → 97 %). `Get(set, "add")` consulted only when
  iterable provided; AddValuesFromIterable invokes user-
  installed `add`; IteratorClose on all abrupt paths.
  Symbols-as-WeakSet/Map-keys (CanBeHeldWeakly) shipped.

- **Genuinely weak `WeakRef` / `WeakMap` / `WeakSet` /
  `FinalizationRegistry`.** The major collector
  (`Heap.collectFull`) treats the weak slots as weak edges: a
  §24.3 WeakMap ephemeron fixpoint (a value is live iff its key
  is) plus a post-mark pass clears dead `WeakRef` targets,
  tombstones dead WeakMap/WeakSet entries, and queues
  `FinalizationRegistry` cleanup jobs onto the microtask drain.
  `collectYoung` keeps strong-marking — a young weak target
  tenures and is handled at the next major cycle (GC timing is
  spec-unspecified, so this is conformant). See
  [docs/handbook/gc.md](handbook/gc.md).

- **Math.sumPrecise (§21.3.2.21) + JSON.rawJSON + JSON.isRawJSON
  (§25.5.{3,4})** — two ES2025 Stage-4 built-ins shipped
  (Shewchuk exact-floating-point summation with overflow-
  recovery, raw-JSON brand bit + stringify fast-path).

- **§13.4 UpdateExpression BigInt-correct postfix / prefix**
  — new zero-operand `inc` / `dec` opcodes dispatching on
  numeric type. `0n++` no longer mixes BigInt + Number;
  `obj[k]++` evaluates `ToPropertyKey(k)` once across
  GetValue + PutValue.

- **§12.8.6 Tagged-template freezing + receiver binding** —
  template + raw arrays carry the §13.2.8.4 frozen
  descriptors (indexed slots `{w:F,e:T,c:F}`, length / raw
  `{w:F,e:F,c:F}`, extensible:false). Member-form tag
  binds `this` to the receiver via `call_method`. Quasi
  cooking handles `\xNN` / `\uNNNN` / `\u{N}` /
  line-continuation per spec.
- **§15.7.14 step 11 lexical private-name resolution across
  nested classes** — `#x` mangles with the *declaring* class's
  prefix, not the innermost. `ClassContext.private_names` +
  `manglePrivateRef` walk `class_stack` outward; the runtime
  carries `private_compile_prefix` alongside `private_brand` so
  `framePrivateBrand` picks the right per-evaluation brand by
  matching the key's `P{n}#` prefix against the prototype chain.
  `language/statements/class/elements` 54 → 42 fail (−12).
- **§13.2.5 ComputedPropertyName for class keys evaluates
  inline.** Sub-chunk dispatch (call-out to a synthesised
  function frame at class-definition time) is gone — keys
  evaluate in the enclosing generator frame so `yield` /
  `await` inside `[expr]` works. Eight `cpn-class-*-from-yield/
  await-expression` fixtures land.
- **module-code bucket: +32 pass** — `arbitrary-module-
  namespace-names` (StringLiteral as ModuleExportName, `export
  * as "ns"`), module namespace `IsExtensible` /
  `SetPrototypeOf` honor the §9.4.6 brand, `@@toStringTag`
  installs at brand-on-allocation time (not at finalisation —
  visible during cycles), hoisted `export default function`
  (anonymous + named), module-top `class C {}` as a let
  binding, `export var` published at module-instantiation
  hoist, cross-function `const` write defers to runtime
  (§9.1.1.1.4). Net: 87 → 92 % spec on `language/module-
  code`.

- **Spec-faithful `yield*` delegation** for both sync and
  async generators (§15.5.5 / §27.6.3.7). Three-step plan
  shipped: `Generator.prototype.throw` injects at the
  suspended yield site via a new `pending_throw` slot;
  sync forwarding wires `next` / `return` / `throw`
  through the inner iterator with IteratorClose-on-
  absent-throw (§14.4.14 step 7.iii.2); async mirrors
  with `await`-driven inner-call ticks.
  `built-ins/AsyncFromSyncIteratorPrototype` went 21 % →
  76 % spec; `built-ins/AsyncGeneratorPrototype` 67 % →
  77 %.
- **GlobalEnvironmentRecord split** (§9.1.1.4) — `let`
  / `const` / `class` at top level live in a declarative
  env-record alongside the object record (`var` /
  `function`), with `[[VarNames]]` tracked separately.
  `sta_global_init` / `sta_global_fn_decl` / `sta_global`
  opcodes dispatch through the split.
  `language/global-code` now at 100 %. See
  [handbook/environments.md](handbook/environments.md).
- **§16.1.7 GlobalDeclarationInstantiation early-error
  pass** — `lex`-vs-`lex` / `lex`-vs-`var` collision,
  `HasRestrictedGlobalProperty` (`NaN` / `Infinity` /
  `undefined`), `CanDeclareGlobalVar` /
  `CanDeclareGlobalFunction` on a non-extensible global.
- **Named function expression self-binding** (§15.6.5) —
  synthetic 1-binding wrapper env holds `G` as immutable
  inside the body; writes throw TypeError at runtime via
  `throw_assign_const`.
- **Module Namespace [[Get]] honors TDZ** — uninit lex
  binding access through a namespace surfaces as
  ReferenceError per §9.4.6.7 + §8.1.1.1.6.
  `[[HasProperty]]` / `[[OwnPropertyKeys]]` stay non-
  throwing.
- **Indirect import bindings + TDZ-Hole seeding on
  exports** — importer sees ReferenceError before source
  module evaluates (§8.1.1.5.5 + §15.2.1.16.4 step 12);
  writes throw TypeError. `re-export-from` (`export { X }
  from './x.js'`) flows through the same indirect path.
- **Spec-faithful Symbol.{split, match, matchAll, replace,
  search}** rewrites (§22.2.5.{8,9,11,13,15}) routing
  through `SpeciesConstructor`, `regExpExecGeneric`,
  `setPropertyChainOrThrow`, `advanceStringIndex` with
  full abrupt-completion propagation. RegExp `/d` flag +
  MakeIndicesArray (§22.2.7.{2,7}) shipped.
- **Date rewrite**: coercion order (§21.4.2 step 3
  in-order ToNumber per argument), `parse` boundary clamp
  (±8.64e15 ms), `toJSON`, `@@toPrimitive`, formatting,
  prop descriptors. Whole `built-ins/Date` bucket at
  100 %.
- **JSON.parse + JSON.stringify abrupt-completion
  propagation** (§25.5.1.1, §25.5.2) — proxy-aware
  Get / Delete / OwnKeys / CreateDataProperty, BigInt
  TypeError per spec, revoked-proxy-as-value TypeError.
- **Lexer `\u{XX}` identifier escape canonicalization**
  (§12.7) — `var \u{61} = 1; a === 1`. The
  `decodeIdentifierName` helper now feeds every binding-
  name resolve / declare / assign site, not just
  property-key.
- **Bulk SES skiplist** — 218 Sputnik + cross-realm
  fixtures using `Function(string)` / `eval(string)` /
  `new other.Function` exhaustively identified and moved
  to `skip_ses_exact_paths` (permanent OOS per AGENTS.md
  SES carve-out). Total count down from 40 700 to 40 411.
- **`tools/test262.zig` `loader_state` made `threadlocal`**
  — was a process-global racing across workers, surfacing
  as ~9 flaky `language/module-code` + ~20 flaky
  `language/expressions/dynamic-import` fixtures whose
  pass/fail flipped between runs. With the fix parallel
  and `--threads=1` agree exactly. See
  [handbook/agent-checks.md](handbook/agent-checks.md).
- Generator `.return()` drives pending `try { yield } finally`
  blocks via `unwindThrow` + an `is_finally` Handler flag and
  the `realm.gen_return_completion` sentinel that skips user
  `catch` clauses (§27.5.1.3).
- Async arrow IIFE now wraps the body value in a Promise
  (§15.8) — `(async () => 1)()` returns a Promise instead of
  the body's value. One-line compiler fix.
- `globalThis` is a live view over `realm.globals` (no
  snapshot) — late-installed host bindings (`$DONE`, `$262`,
  etc.) reflect through automatically. Replaces the
  `intrinsics.install`-time snapshot pattern.
- Labeled `break` / `continue` threaded through
  `LoopContext.labels` (§14.13 / §14.16 / §14.17).
- Computed-key object destructuring in both declaration and
  assignment patterns (§14.3.3 / §13.15.5).
- Class inner `C` lexical binding (§15.7.1 step 8): visible to
  method bodies, distinct from any outer scope's `C`.
- Three closed root gaps from the previous handbook list
  (frame stacks, promise reactions, key anchors) — the
  remaining residuals at `gc_threshold=1` would be new natives
  missing a `HandleScope`, not the previously-tracked four.

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
  `Set.prototype` covers the ES2025 family
  (`union`, `intersection`, `difference`, `symmetricDifference`,
  `isSubsetOf`, `isSupersetOf`, `isDisjointFrom`).
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
- TypedArrays + DataView covering the common surface. ES2024
  `Float16Array` + `DataView.{get,set}Float16` are wired
  (IEEE 754 binary16). ES2024 resizable ArrayBuffer (resize +
  maxByteLength), `IsFixedLengthArrayBuffer` propagation, and
  length-tracking views (`new TA(rab)` with omitted length) are
  shipped — view byteOffset / length / byteLength getters and
  every prototype iteration method re-resolve length per access.
  `%TypedArray%.from` + `%TypedArray%.of` ship as static methods
  on the abstract intrinsic and are inherited by every concrete
  ctor via the static_parent chain. `%TypedArray%[@@species]`
  accessor installed with accessor-aware lookup for subclass
  species ctor dispatch. Detached-buffer state on `ArrayBuffer`
  + `ValidateTypedArray` propagates to every TA/DataView
  operation per §25.1.3 / §10.4.5.x.
- `Array.fromAsync` (§23.1.2.1.1) — drives sync iterables,
  `@@asyncIterator`, and array-like fallback through a
  capability + bound `.then` chain (spec-conformant deferral via
  the microtask queue). Honors `this`-constructor for subclass
  calls and writes each element via CreateDataPropertyOrThrow.
- Error class hierarchy: `Error`, `TypeError`, `RangeError`,
  `ReferenceError`, `SyntaxError`, `URIError`, `EvalError`,
  `AggregateError`.

**Pre-Stage-4 proposals shipped (opt-in).** Cynic deliberately
ships a handful of TC39 proposals before they reach Stage 4 / a
published edition, where the spec text is stable enough and the
feature unlocks useful programs. Each is gated behind a per-realm
feature flag — `Realm.feature_flags`, defined in
`src/runtime/features.zig`. The `cynic` CLI defaults to all-off
(embedder-friendly default) and exposes flags to opt in:

- `--enable=<name>` / `--disable=<name>` — toggle one feature.
- `--enable-experimental` / `--disable-experimental` — toggle the
  whole tracked set.
- `--list-features` — print the available set with descriptions.

Each shipped proposal carries a `PRE-STAGE-4 PROPOSAL` comment at
the installer site so a future spec shift surfaces the right
place to revisit. The current set:

- **`joint-iteration`** (Stage 3) — `Iterator.zip(iterables)` and
  `Iterator.zipKeyed(iterables, options?)` on the `Iterator`
  global. Installer in `src/runtime/builtins/iterator.zig`.
  Semantics of the `mode` option ("shortest" | "longest" |
  "strict") and padding may still shift. The dedicated feature
  phase is at 76 / 2: `Iterator.zip` and `Iterator.zipKeyed` are
  conformant — the keyed-iterables walk routes through the spec
  `[[OwnPropertyKeys]]` / `[[GetOwnProperty]]` / `[[Get]]`
  operations (Proxy traps fire), padding is a keyed object for
  `zipKeyed` and an iterable for `zip`, `IteratorClose` runs in
  reverse, and the result tuples / per-input state live in typed
  internal slots with no observable `__cynic_*` own property.
  Helper results inherit `%IteratorHelperPrototype%`. The 2
  remaining `result-is-iterator.js` fixtures are **environmentally
  blocked, not an engine gap**: the test262 harness's
  `getWellKnownIntrinsicObject` (`wellKnownIntrinsicObjects.js`)
  populates every intrinsic by evaluating `new Function("return "
  + source)()`, and Cynic deliberately ships no `new Function`
  (SES alignment), so the helper can obtain no intrinsic at all.
  Off by default in the CLI and excluded from headline
  conformance.
- **`upsert`** (Stage 3) — `Map.prototype.{getOrInsert,
  getOrInsertComputed}` and the corresponding pair on
  `WeakMap.prototype`. Installer in
  `src/runtime/builtins/collections.zig`. Atomic "get value at
  key, or insert default if absent."

Revisit this list each TC39 meeting cycle. If a proposal stalls,
demotes, or its semantics flip, follow the comment trail in the
installer and either back the change out or update.

The conformance harness scores each tracked feature as its own
**dedicated phase sweep** — a `joint-iteration` fixture runs in a
realm where `Map.prototype.getOrInsert` is undefined, and vice
versa, so each row reflects the proposal in honest isolation.
A `zig build test262 -- --write-results` invocation runs the
main ECMA-262 sweep (pre-Stage-4 fixtures excluded entirely
from `total` / cache / per-area buckets) followed by one
dedicated sweep per feature; the per-feature numbers source the
`## Pre-Stage-4 proposals shipped` table in
`test262-results.md`. Iterate on one feature in isolation with
`--phase=feature:<name>`. Adding a new pre-Stage-4 proposal:
extend `FeatureFlag` in `src/runtime/features.zig`, gate the
installer site, and the harness picks up the new column
automatically on the next full sweep.

**Caveats / planned.**

- `Date` is UTC-only — `getTimezoneOffset` returns 0; locale
  formatting falls back to ISO. Real timezone handling needs a
  tz-data source.
- `String.prototype.normalize` is a passthrough — needs UCD
  normalization tables for real NFC/NFD/NFKC/NFKD.
- `Function.prototype.toString` — returns the original source slice
  for declared functions; callable Proxy returns the spec sentinel
  `function () { [native code] }`. Remaining edge: CR vs LF
  normalization (test262 `line-terminator-normalisation-CR.js`).
- `Number.prototype.{toFixed, toExponential, toPrecision}` — the
  digit string comes from a libc `printf`-style conversion, which
  rounds via the shortest-round-trip path. §21.1.3.3 / §21.1.3.2 /
  §21.1.3.5 instead specify the *exact* mathematical value of
  `n ÷ 10^f` (ties-to-larger), so `(1000000000000000128).toFixed(0)`
  must keep the full mantissa rather than collapse to
  `1000000000000000100`. Closing this needs a Ryū / Grisu-style
  exact dtoa with a controllable rounding mode — own work item,
  3 test262 fixtures honest-fail until then.
- `String.prototype.localeCompare` — compares by UTF-16 code unit.
  §22.1.3.12 permits a locale-sensitive collation; without `Intl`
  there is no canonical-equivalence folding, so `"ö"` (o +
  combining diaeresis) and `"ö"` (precomposed ö) compare
  unequal. Real NFC folding shares the UCD-normalization-table gap
  with `String.prototype.normalize` above.

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

**Done (additions).**

- Indirect import bindings as live aliases per §8.1.1.5.5
  CreateImportBinding, with TDZ-Hole-seeding on the source
  module's exports so the importer sees ReferenceError until
  the source body initialises (§15.2.1.16.4 step 12). Writes
  to an import throw TypeError.
- Module Namespace exotic [[Get]] honors TDZ — uninit lex
  binding surfaces ReferenceError per §9.4.6.7 + §8.1.1.1.6.
  `[[HasProperty]]` / `[[OwnPropertyKeys]]` stay non-throwing.
- Re-exports (`export { X } from './x.js'`) and star
  re-exports (`export * from`) route through indirect bindings.
- Top-level `await` in module bodies — full bucket green.
  Async module bodies run via `startAsyncCall`; the
  `module_link_complete` opcode drains microtasks after the
  hoisted import block; `loadModule` records suspended async
  deps on `ModuleRecord.pending_async_deps` and propagates
  rejection at the link boundary (§16.2.1.5 / §16.2.1.9
  parent-path, approximated). Dynamic `import()` chains its
  Promise to the dep's evaluation Promise so the import()
  result reflects the post-TLA namespace.
- StringLiteral as ModuleExportName (§16.2.3.5) — `export {
  X as "Y" }`, `export * as "ns" from "src"`, `import {
  "Y" as local }`. Quotes stripped at compile time; the
  raw key indexes the namespace.
- §9.4.6.{1,3} namespace `IsExtensible` / `SetPrototypeOf`
  are brand-aware — a Module Namespace exotic refuses
  extension and prototype change with the spec-mandated
  `false` return, not the OrdinaryObject default.
- `@@toStringTag` installs at brand-on-allocation time so
  cycles see `Object.prototype.toString.call(ns)` returning
  `"[object Module]"` while the namespace is still
  `extensible`.

**Planned.**

- Module-evaluation cycle resolution edge cases — the residual
  failures are in the `language/module-code/instn-{iee,star}-*`
  + `ambiguous-export-bindings/*` clusters and need the full
  §15.2.1.16.3 ResolveExport chain (indirect-export forward,
  ambiguity detection) + `export * from` namespace merge.
- Full §16.2.1.5 [[PendingAsyncDependencies]] +
  [[AsyncEvaluationOrder]] graph — Cynic's `pending_async_
  deps` slot is a lightweight stand-in; the remaining
  fixtures that exercise sort ordering need the real machinery.

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
predictable latency. Correctness still leads, but the perf work
has started: the dispatch loop, the GC, and string concatenation
have all had a pass (see **Shipped** below). Cross-engine
measurement infrastructure lives at
[docs/benchmarking.md](benchmarking.md); per-commit micro-bench
deltas are produced by the `/perf` slash command and hot-function
sampling by `/profile`.

**Shipped.**

- **Threaded interpreter dispatch (rung-3 / 4 / 5).** The
  `while + switch` dispatch loop became a Zig labeled switch with
  per-opcode `continue :dispatch` tails (rung-3); opcode decode
  dropped a per-step `std.enums.fromInt` enum scan for a raw
  `@enumFromInt` cast (rung-4); arithmetic / comparison / bitwise
  opcodes gained int32 fast paths (rung-5). Combined, `arith_loop`
  fell ~20× — see `bench-results.md`.
- **Generational GC.** A JSC-Riptide-style non-moving
  generational collector — store-site routing, generation header
  bits, a write barrier + remembered set, `collectYoung` with
  promotion-by-relink, and a two-tier (alloc-count + byte)
  trigger. See [docs/handbook/gc.md](handbook/gc.md).
- **ConsString ropes.** `JSString` carries a flat/cons
  discriminator; `concat` is O(1) and flattens lazily on first
  observable use — removes the O(N²) `buildString +=` blow-up.
- **Cross-engine micro-bench harness** (`tools/bench-cross.sh`) —
  interpreter-tier comparison against QuickJS-NG / V8 /
  SpiderMonkey / Hermes with their JITs disabled. Phase 2 of
  [docs/benchmarking.md](benchmarking.md).

**In progress.**

- **Profile-driven hotspot list** — `samply` over a test262
  runtime sweep, top-N hot functions. Drives what gets optimized
  next. Driver lives at `tools/profile.sh`; slash command at
  `/profile`.
- **`/perf` micro-bench harness** — `zig build bench` builds a
  dedicated ReleaseFast `cynic-bench` binary and times the fixed
  micro-bench suite in `bench/micros/`, median of 5, diffing
  per-fixture wall time + RSS against the prior `bench-results.md`
  baseline. Phase 1 of [docs/benchmarking.md](benchmarking.md).

**Planned — the path to interpreter-tier parity.**

The cross-engine harness (interpreter tier, JITs off) puts Cynic
level with or ahead of QuickJS-NG on `array_iter`, `promise_chain`
and `string_concat`, and within ~10 % on `arith_loop` and
`object_alloc`. One gap is large — `prop_access` runs ~3× slower
than QuickJS-NG. Closing that, then trimming the two mid-pack
benches, is the work below, ordered largest-win-first. The goal
is honest parity with QuickJS-NG — the fairest non-JIT peer;
matching the JIT engines at full speed is a separate track (see
*Proper Tail Calls* and the baseline-JIT note).

1. **Inline property-shape caches** — the single biggest win.
   **Monomorphic shipped** — `lda_property`, `sta_property`, and
   `call_method` each carry a chunk-local IC cell; the fast path
   is a shape pointer compare and a `slots[slot]` load on reads,
   a slot write + bag mirror on writes, and a cached-callee match
   on call sites. `prop_access` measured at **−66 %** (48.94 →
   16.47 ms), `prop_write` at **−63 %** (92.24 → 33.70 ms). Every
   major engine built this first — V8 hidden classes, JSC
   structures, SM shape trees. Remaining: polymorphic dispatch
   (a small chain on the cell when the receiver's shape varies
   between two or three callers — most engines cap at ~4 entries
   before degrading to megamorphic / dictionary). Worth doing
   once a real workload surfaces a polymorphic site that's
   currently slow.

2. **Packed `JSArray` heap kind + leaner object allocation** —
   targets `object_alloc`. A unified array heap kind with packed
   indexed storage as the base case (sparse fallback only when
   genuinely sparse) lets the loop / arithmetic opcodes skip the
   per-access `is_array_exotic` branch and index
   `elements.items.ptr[i]` directly. Some of this exists already
   (`elements: ArrayListUnmanaged(Value)` + the `is_array_exotic`
   flag). The shape work above also thins ordinary-object
   allocation — shape-sharing objects no longer each carry a full
   hashmap.

3. **Interpreter-core tuning for `arith_loop`** — Cynic is
   already within ~10 % of QuickJS-NG here; the remaining
   distance is to JSC's hand-written-assembly LLInt. Closing that
   without a JIT is deep, diminishing-returns micro-tuning of the
   dispatch core — lowest priority of the three, and the point
   where a baseline JIT becomes the better investment.

**Planned — GC latency.**

- **Incremental / concurrent marking.** The generational
  collector (shipped, above) still stop-the-world marks the
  mature set on a major cycle; incremental marking would amortize
  the long-pause tail. The next GC step after the generational
  split.

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
