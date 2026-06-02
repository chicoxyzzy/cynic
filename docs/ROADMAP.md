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

- **Incremental / concurrent GC marking.** The generational
  collector — young/mature split, write barrier, remembered set,
  `collectYoung` with promotion-by-relink — has shipped (see the
  Performance section); incremental marking of the mature set is
  the remaining GC step.

**Recently landed (was in progress; now done).**

- **SES baseline by default — frozen primordials + override-
  mistake fix.** `intrinsics.freezePrimordials` runs as the last
  step of `installBuiltins` when `realm.hardened` is true (the
  default). Two passes: a `hardenWalk` over `globalThis` + every
  reachable intrinsic stamps `[[Extensible]] = false` and locks
  every descriptor `{writable: false, configurable: false}`
  (accessors: `{configurable: false}`); then a Phase 3 pass
  demotes each prototype's own data slot to a synthetic accessor
  pair so `Foo.prototype.toString = fn` succeeds as instance
  shadowing on `Foo.prototype` instead of throwing per §10.1.9.2's
  override-mistake reject. Constructors, namespace objects
  (`Math`, `JSON`, `Reflect`), and `globalThis` itself stay as
  frozen data slots — direct intrinsic mutation
  (`Array = …`, `Math.PI = 4`) still throws. The whole SES
  posture toggles atomically with `--unhardened`; `--allow=eval`
  stays separate because it carries compile-time optimization-
  fence cost. Multi-realm is partial but solid — per-function
  `[[Realm]]` (set at allocation), realm-aware resolution (a
  running function resolves its free globals — read + write —,
  its Error-constructor and §23.1.3.34 species intrinsics, and
  primitive boxing through its OWN realm, not the caller's),
  cross-realm species, and `ShadowRealm` (constructor +
  `.evaluate` + `.importValue` + the §3.8.3.4 callable boundary)
  all ship, the shared-heap GC marks every coexisting realm's
  roots (closing a cross-realm use-after-free), and a collected
  `ShadowRealm` frees its child realm record (per-realm teardown).
  Full Compartments are **postponed pending the TC39 proposal**: it's
  Stage 1 ([tc39/proposal-compartments](https://github.com/tc39/proposal-compartments)),
  so the API is still in flux and Cynic doesn't bake pre-Stage-4
  surface into its confinement boundary — the multi-realm substrate
  Compartments stand on already largely ships. The test262 sweep
  scores both modes — the
  `unhardened` row tracks the legacy ECMAScript baseline (the
  `--unhardened` opt-out), the `hardened` row tracks the
  SES posture. Brand bet
  delivered: Cynic ships the SES baseline natively, no
  `@endo/ses` import or `lockdown()` call required. Design +
  phase notes in [docs/ses-alignment.md](ses-alignment.md).

- **`harden()` global** — Phase 2 of the SES-by-default
  shopping list (`aed6a66`). Native recursive deep-freeze on
  `globalThis`, cycle-safe via a heap-pointer visited set.
  Reused by the Phase 1 freeze pass (`hardenWalk` is the same
  walker). See [docs/ses-alignment.md](ses-alignment.md) for
  the acknowledged corner-case gaps (module namespaces, Proxy
  trap routing, recursion depth).

- **§9.10 KeepDuringJob for WeakRef** (`d791920`). Both the
  `WeakRef` constructor (§26.1.1.1 step 4) and
  `WeakRef.prototype.deref` (§26.1.4.1 step 2a) call
  AddToKeptObjects(target), pinning the target in a per-agent
  [[KeptAlive]] list. `Realm.kept_alive` holds the list; the
  GC marker walks it as a strong root.
  `lantern.drainMicrotasks` calls ClearKeptObjects at start +
  after each drained microtask (§9.5.5 — each microtask is its
  own job). Closes a documented spec gap: previously
  `ref.deref()` twice in the same synchronous block could see
  a swept target on Cynic, observably different from
  V8 / JSC / SpiderMonkey.

- **Proper Tail Calls (PTC) — §15.10.** Two new opcodes
  (`tail_call`, `tail_call_method`) plus a static
  IsInTailPosition pass in the bytecode compiler: an inherited
  `in_tail_position` flag propagates through `ReturnStatement`,
  `ArrowFunction` concise body, parenthesized, conditional
  consequent / alternate, logical `&&` / `||` / `??` rhs, and
  comma's last operand; every other expression type clears it
  for its sub-expressions. The runtime handler reuses the
  current `CallFrame` in place — overwriting chunk / ip / env /
  this / registers — so `return f(n - 1)` recurses without
  growing the dispatch stack. The §15.10.1 disqualifiers Cynic
  honors: enclosing try-with-finally, try-with-catch in the
  same chunk, open for-of iterator owing `IteratorClose`, async
  / generator body. Exotic callees (proxy, bound, native,
  generator, async) fall back to ordinary call semantics — the
  unconditionally-emitted follow-up `return_` propagates the
  result. **On by default** (no feature flag) — Cynic is the
  second engine shipping spec-mandated PTC alongside
  JavaScriptCore. ~30 test262 fixtures under `language/*/tco-*`
  and the `tail-call-optimization` feature tag now pass.

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
- `RegExp` backed by **Perlex**, Cynic's own regex engine (full
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

- `--enable=<name>` — enable one feature.
- `--enable-experimental` — enable the whole tracked set.
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

- `Date` is UTC-only — `getTimezoneOffset` always returns 0,
  every `getXxx` method behaves like its `getUTCXxx` peer, and
  `toString` / `toLocaleString` render
  `... GMT+0000 (Coordinated Universal Time)`. Spec-conformant
  per §21.4 (the implementation picks the local time zone;
  `"UTC"` is a permitted choice) — every `built-ins/Date`
  fixture passes. Practical for edge / server JS where the host
  owns scheduling; not a polished story for a UI that needs to
  render local time. Real timezone handling would need a
  vendored tz-data source (IANA `tzdata`) plus the per-method
  local-time conversions; deferred until a user actually asks.
- `Intl` is not implemented in the default build —
  `Intl.NumberFormat`, `Intl.DateTimeFormat`, `Intl.Collator`,
  `Intl.Segmenter`, etc. are absent, and the whole `intl402/`
  test262 tree is path-skipped (out-of-scope per
  [AGENTS.md](../AGENTS.md)). Cynic's `localeCompare` returns a
  canonical-equivalence-aware compare via NFD-then-ordinal (note
  in §22.1.3.12); case-sensitive Turkish-style collation is
  what's missing, not basic NFC folding.

  **A future Intl-enabled build is contemplated.** ECMA-402 needs
  a CLDR/ICU-class locale database plus IANA `tzdata` — a large
  vendored dependency the default edge-runtime build deliberately
  omits to stay small and dependency-light. It's a separate
  *build flavour*, not a default-on feature: an opt-in Cynic that
  links the locale/tz stack. The seams are being kept clean so it
  can land without a rewrite — Temporal funnels every zone-offset
  lookup through a single `getOffsetNanosecondsFor` chokepoint
  (see "Temporal" below) so a named-IANA-zone provider drops in at
  one place, and `localeCompare` already isolates its NFD
  pipeline. If that build ships, the `intl402/` tree — named time
  zones, non-ISO calendars, and the `Intl.*` formatters — comes
  back into the scored scope with it.

**Shipped.** `Temporal` (ES2025) — the full value-type surface
plus `Temporal.Now`. All eight types land: `Instant`, `PlainTime`,
`PlainDate`, `PlainDateTime`, `PlainYearMonth`, `PlainMonthDay`,
`Duration`, and `ZonedDateTime`, each with its constructor,
getters, `from` / `compare`, `with*`, the arithmetic chain
(`add` / `subtract` / `until` / `since`), `round` / `total`, the
`toString` / `toJSON` / `toLocaleString` family with precision +
rounding options, and ISO-8601 string parsing — plus
`Date.prototype.toTemporalInstant`. The arithmetic and rounding
abstract operations (RoundNumberToIncrement, the duration
balance / round / difference chain, NudgeToCalendarUnit /
BubbleRelativeDuration, RoundRelativeDuration) are named to match
proposal-temporal so test262 failures map to spec steps.
`built-ins/Temporal` scores 3885 pass / 0 fail across the corpus,
and the headline runtime spec% moved to ~94.56% when the tree came
out of the skip list.

The scope is **ISO-8601 calendar + UTC/fixed-offset zones only**.
There is no vendored IANA `tzdata` in the default build, so named
zones (e.g. `"America/New_York"`), DST transitions, and non-ISO
calendars are deferred — they are the payoff of the future
Intl-enabled build (above), not of this effort. Every offset
lookup already routes through one `getOffsetNanosecondsFor` seam,
so that build plugs a tzdata provider in at a single place rather
than threading it through each `ZonedDateTime` operation.

**Out of scope.** Annex B in its entirety — language extensions
*and* every browser-era built-in (`escape` / `unescape`, the
String HTML wrappers, `Date.prototype.{getYear, setYear,
toGMTString}`, `String.prototype.{substr, trimLeft, trimRight}`,
`Object.prototype.__proto__` accessor and the `__define*` /
`__lookup*` family, `RegExp.{$1, input, …}` legacy globals).
`Intl` (the default build skips it — see the contemplated
Intl-enabled flavour above).

`SharedArrayBuffer` / `Atomics` are **planned, not refused.**
Shared memory sits in tension with SES-style isolation and
Cynic's single-agent-per-isolate hosts, so the design — a
guarded, opt-in shared-memory surface that keeps the isolation
boundary intact — is still open. The fixtures stay path-skipped
until it lands, but this is a roadmap item now, not a permanent
carve-out.

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

**Done.** Vendored QuickJS-NG `libregexp.c` (MIT, ~2600 LOC C)
provided the initial full ECMA-262 surface, bridged from Zig with
UTF-8 ↔ UTF-16 transcoding so match indices land in spec-correct
UTF-16 code units. The native backtracking engine — **Perlex**
(`src/perlex/`) — now sits first in dispatch and owns **every pattern
the test262 corpus exercises**: backreferences, named groups (incl.
duplicate-name early errors), lookahead / lookbehind (with captures,
backreferences, nested assertions), the whole `/v` UnicodeSets grammar
(set algebra, nested classes, `\q{…}` string disjunctions, `\p{…}`
properties of strings), `/iu` / `/iv` and non-`/u` `i` case folding
(§22.2.2.9 Canonicalize), the ES2024 inline-modifier groups
(`(?ims-ims:…)`), quantifiers over nullable bodies and over huge /
unbounded counts, and the §22.2.1.1 strict-grammar early errors (the
Annex B carve-outs below). No real engine failures remain in the
RegExp corpus.

**libregexp is gone.** The vendored matcher (`libregexp.c`), its
runtime bridge, the parse-time validator fallback, and the build
wiring have all been removed — Perlex is the sole regex engine. The
removal was gated on a fall-through census of **0** (no corpus pattern
ever reached the fallback, on either the runtime or the parse path)
and a head-to-head benchmark (Perlex is 1.9–3.5× faster, see above).
A pattern Perlex can't compile now throws `SyntaxError` with no
fallback; the only `error.Unsupported` residuals are census-invisible
(malformed UTF-8, the pathological `(a?){10^23}` bounded by the VM
step limit). `libunicode.c` is gone too — String case conversion
(`src/unicode/case_conv.zig`), normalization
(`src/unicode/normalization.zig`, NFC/NFD/NFKC/NFKD per §3.11 / UAX#15),
and Perlex case folding all run on native tables now. With both
matchers retired, the entire `vendor/quickjs/` directory was deleted
(`libregexp.c`, `libunicode.c`, `cutils.c`) — Cynic vendors no C.
The WASM glue went with it: `src/wasm_shim.c` and `src/runtime/c_alloc.zig`
are gone, so the WASM build has no C either (optional `wasm-opt -Oz`
minification step).

**Replacement-gate benchmark — Perlex vs libregexp.** The final
pre-removal snapshot (the `bench-regex` harness that produced it was
retired alongside libregexp — there is no second engine to compare
against now). In-process, ReleaseFast, identical `(pattern, UTF-16
input)` pairs; Perlex was faster on every case and returned the same
match on all of them (`agree: yes`). Run 2026-06-01, cynic `5090791`:

| Geomean (Perlex-owned cases) | Perlex speedup |
|---|--:|
| compile (all) | 1.90× |
| exec (common patterns) | 2.98× |
| exec (worst-case) | 3.49× |

Per-case medians (ns/iter; `comp×` / `exec×` = libregexp ÷ Perlex,
>1 → Perlex faster):

| Case | Cynic comp | lre comp | comp× | Cynic exec | lre exec | exec× |
|---|--:|--:|--:|--:|--:|--:|
| literal-hit | 794 ns | 1.21 µs | 1.52 | 277 ns | 674 ns | 2.43 |
| literal-miss | 291 ns | 479 ns | 1.65 | 472 ns | 1.58 µs | 3.35 |
| email | 955 ns | 3.47 µs | 3.63 | 526 ns | 2.77 µs | 5.27 |
| url | 615 ns | 1.56 µs | 2.54 | 312 ns | 793 ns | 2.54 |
| iso-date | 837 ns | 1.30 µs | 1.55 | 244 ns | 1.04 µs | 4.25 |
| first-word | 284 ns | 660 ns | 2.32 | 162 ns | 389 ns | 2.40 |
| integers | 253 ns | 493 ns | 1.95 | 197 ns | 576 ns | 2.93 |
| lower-run | 275 ns | 514 ns | 1.87 | 87 ns | 197 ns | 2.28 |
| anchored-num | 289 ns | 525 ns | 1.82 | 217 ns | 346 ns | 1.60 |
| alternation | 576 ns | 774 ns | 1.34 | 357 ns | 1.64 µs | 4.59 |
| ci-word | 220 ns | 418 ns | 1.90 | 97 ns | 223 ns | 2.31 |
| multiline-anchor | 200 ns | 395 ns | 1.97 | 135 ns | 422 ns | 3.13 |
| backref-dup | 614 ns | 1.28 µs | 2.08 | 95 ns | 246 ns | 2.59 |
| lookahead-px | 391 ns | 556 ns | 1.42 | 148 ns | 516 ns | 3.50 |
| prop-letter | 6.59 µs | 20.66 µs | 3.14 | 93 ns | 304 ns | 3.28 |
| emoji-class | 284 ns | 546 ns | 1.92 | 153 ns | 518 ns | 3.39 |
| nested-quant (worst) | 366 ns | 634 ns | 1.73 | 1.32 ms | 4.34 ms | 3.30 |
| alt-overlap | 325 ns | 553 ns | 1.70 | 2.66 ms | 8.76 ms | 3.29 |
| scan-miss-64k | 237 ns | 437 ns | 1.84 | 435 µs | 1.67 ms | 3.84 |
| class-scan-64k | 367 ns | 543 ns | 1.48 | 527 µs | 2.92 ms | 5.54 |
| restart-heavy | 301 ns | 471 ns | 1.56 | 534 µs | 1.88 ms | 3.53 |
| big-bound-exact | 233 ns | 551 ns | 2.37 | 9.02 µs | 31.73 µs | 3.52 |
| big-bound-range | 325 ns | 557 ns | 1.71 | 36.1 µs | 78.8 µs | 2.18 |

Memory (RegExp bucket, `--mem-summary`, engine-side counters — also the
post-removal runtime numbers): 42 MiB max
per-fixture engine peak, 5.6 MiB avg, 27 GC cycles / 25 ms total pause,
0 fail. The heaviest process-RSS fixtures (199 MB on `\S`-over-all-
Unicode, ~100 MB on the `CharacterClassEscapes` positive-cases) are
inherent whole-Unicode set-construction tests, engine-agnostic. The
regex removal dropped `libregexp.c` (2610 lines C) from the build, and
the subsequent native-Unicode work dropped `libunicode.c` (1746 lines)
and the rest of `vendor/quickjs/` with it. The ES2024 `regexp-modifiers`
feature ships via Perlex, so no regex *feature* is unshipped; remaining
polish is `RegExp.prototype` property edge cases (`lastIndex`, `flags`,
`dotAll`) and minor String.prototype dispatch corners.

**Annex B regex grammar (§B.1.4) — narrowed by Perlex.**
The §22.2.1 main grammar makes `]`, `{`, `}` SyntaxCharacters
with no literal reading, treats a DecimalEscape `\N` past the
capture count as an early error (§22.2.1.1), requires a
DecimalDigits lower bound on every Quantifier brace, and makes a
`-` class range with a CharacterClassEscape bound (`[\d-a]` /
`[a-\d]`) a §22.2.1.1 early error. Annex B §B.1.2 relaxes all of
these when a pattern is compiled *without* the `u` / `v` flag — a
stray brace/bracket becomes a literal ExtendedPatternCharacter,
`\N` rereads as a legacy octal/identity escape (e.g. `\1` outside
a group → `\001`), `{,n}` reads as literal text, and the `-` in
`[\d-a]` rereads as a literal (`\d`, `-`, `a`).

Cynic drops every one of these in every mode. **Perlex** — the
native regex engine and now the sole one — raises `SyntaxError` for
all of them, so every pattern is held to the strict main grammar
(`u` / `v` already rejected them; non-Unicode mode does too) with no
fallback to leak the Annex B leniency (the vendored libregexp matcher
that once did has been removed). Every shipping browser engine (V8 /
JSC / SpiderMonkey) accepts the Annex B forms; Cynic's non-browser
target is why it doesn't. Everywhere else the "no Annex B" stance
from AGENTS.md is enforced (language extensions, browser-era
built-ins, accessor / legacy-global aliases), and the
`annexB/built-ins/RegExp/` corpus stays path-skipped.

## Tooling

**Done.**

- `cynic parse <file>` / `cynic eval '<expr>'` / `cynic run <file>` /
  `cynic repl` (persistent realm, microtask drain between lines,
  `.exit` / `.quit` / Ctrl-D, `Name: message` error rendering).
- `cynic run --dump-bytecode` disassembles compiled chunks
  (script + every nested function template) and exits without
  executing — useful for tracing codegen shape and verifying
  peephole / IC work.
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
  micro-bench suite in `bench/micros/`, median of 10, diffing
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

2. **Leaner `JSObject` allocation — shipped.**
   `@sizeOf(JSObject)` dropped 960 → 512 bytes (-47 %, nearly
   halved) by moving every cold field (`accessors`, `private_*`,
   `namespace_*`, `map_data`, `set_data`, `promise_*`,
   `weak_ref_target`, `finalization_cells`, `array_buffer`,
   `typed_view`, `data_view`) behind a lazy
   `?*JSObjectExtension` pointer. Plain `{a, b}` literals now
   pay a single null pointer instead of the multi-kilobyte cold
   state. A follow-up slab pool for `JSObject` headers (`9871171`)
   replaced the per-allocation `libsystem_malloc` round-trip with
   an O(1) free-list pop. Combined: `object_alloc` 232 ns/alloc
   → ~159 ns/alloc — **-32 % per allocation** vs the original
   baseline.

   **Literal-shape template cache — shipped** (`22d2028`).
   `make_object` for an object-literal sequence carries a
   chunk-side template index; first execution walks the keys
   via `ShapeTree.transition` and caches the result; subsequent
   executions stamp `obj.shape = cached_shape` directly and the
   follow-up `def_property` opcodes skip the per-key transition
   lookup. V8 / JSC's "literal boilerplate" pattern.

   **Bag-mirror skip on shape-stable writes — shipped**
   (`8b98ba0`). `sta_property`'s IC hot path skips the bag write
   on a shape-stable object. `JSObject.get` / `.hasOwn` were
   already shape-first (`4133c7f`, `4b06eb4`).

   **Lazy property bag — shipped** (`0cab149` + `6d96854`,
   Phase 3 of [docs/lazy-property-bag.md](lazy-property-bag.md)).
   Drops the per-property `properties.put` mirror on shape-stable
   writes; the slot becomes the source of truth and the bag stays
   unallocated for the fresh-object case. `object_alloc` ~ -16 %
   (55.38 → 47 ms) — Cynic now leads QuickJS-NG on this fixture
   (47 vs 54 ms). Trades a few % on hot reads (`prop_access`,
   `arith_loop`) for the alloc win; recoverable via the IC
   shape-gate work tracked separately.

   Remaining structural wins on `object_alloc`:

   - **Brand-bool bit-packing.** ~10 single-byte bools on
     `JSObject` (`has_error_data`, `is_raw_json`,
     `is_module_namespace`, `is_weak_ref`, `is_arguments_exotic`,
     `proxy_revoked`, `proxy_callable`, `promise_already_resolved`,
     `has_array_buffer_data`, `is_sparse`) could pack into a
     single `u32` flags word. Saves ~10-16 bytes per `JSObject`
     after alignment — marginal; defer until measurement shows
     it matters.

3. **Packed `JSArray` element-kinds.** V8 / JSC distinguish
   `PackedSmiElements` (i32-flat), `PackedDoubleElements`
   (f64-flat), and `PackedElements` (Value-flat). Cynic stays on
   `PackedElements` everywhere (`elements: ArrayList(Value)`).
   The interpreter-tier payoff is small without a JIT — the
   kind-check dispatch overhead eats most of the per-element
   memory savings, and Hermes (the interpreter-tier engine Cynic
   most resembles) deliberately doesn't do this. Worth doing
   only when a baseline JIT lands and can speculate on the kind.

4. **Interpreter-core tuning for `arith_loop`** — Cynic is
   already within ~10 % of QuickJS-NG here; the remaining
   distance is to JSC's hand-written-assembly LLInt. Closing that
   without a JIT is deep, diminishing-returns micro-tuning of the
   dispatch core — lowest priority, and the point where a
   baseline JIT becomes the better investment.

**Planned — interpreter-tier optimizations beyond ICs.**

The IC arc (item 1 above) covered the biggest single chunk —
property access. Beyond ICs, several classical interpreter
optimizations remain on the table. Stack-ranked by expected
impact for an interpreter-only engine; numbers are estimates,
not measurements.

5. **Super-instructions (bytecode pair fusion).** Static
   analysis over compiled chunks identifies the top-N
   bytecode-pair sequences (e.g. `lda_const k; sta_property k2`,
   `ldar r; add r2`, `lda_int N; lt r`). Each pair becomes one
   opcode — one dispatch, one operand fetch. V8 Ignition ships
   ~30 super-instructions; the single biggest non-JIT perf
   lever after ICs. Compiler emits the fused form when the
   AST pattern matches; interpreter handler is the body of the
   two old opcodes inlined. Estimated ~10-20 % on synthetic
   benches.

6. **Counter-loop specialization — shipped.** `loop_inc_lt`
   opcode fuses the seven-opcode `add 1 + star + ldar + lt +
   jmp_if_true` tail of a canonical for-loop into one dispatch.
   The compiler pattern-matches `for (let i = INT; i < INT; i++)
   BODY` on the `ForStmt` AST and emits the fused form when the
   body has no closure (per-iter env elision precondition) and
   doesn't reassign `i`. The counter and bound live in plain
   registers — `i` is promoted off the env via a one-shot
   `is_register` binding flag, so body reads compile to `ldar
   r_counter`. Int32 fast path + slow fallback through
   `arith.incOrDec` / `relational` for non-int32 operands.
   Hermes calls the same shape `JLessNLong`; V8 Ignition has a
   `Jump…IncIfTrue` family. `arith_loop` measured at **−61 %**
   (80.10 → 31.55 ms) — overtakes QuickJS-NG (77 ms) on the
   cross-engine bench.

7. **Peephole pass at bytecode emit.** Pattern-match short
   sequences in the emitted bytecode and rewrite:
   - `lda_const 0; sub` → `negate`
   - `ldar r; star r2; ldar r2` → `mov r r2`
   - `lda_const c; jmp_if_false L` → fold (when c is statically
     truthy/falsy)
   - `jmp L1; L1: jmp L2` → `jmp L2` (jump threading)
   - dead code after unconditional `return` / `throw` / `jmp`
   Each rewrite is marginal; compounded across a real chunk
   they shrink bytecode and remove dispatch overhead. Easy
   first non-IC chunk to land.

8. **Frame register pool — shipped** (`b38f125`). Every
   JS-function call site (`call`, `call_method`, `new_call`,
   `tail_call`, `tail_call_method`) used to `allocator.alloc(
   Value, max(register_count, argc))` for the callee's register
   file and free it on frame pop — a libc malloc + free per
   call. Pool keyed by register_count amortises both. Surfaced
   by the cross-engine bench (`method_call` /
   `class_instantiate` running 2.2× behind QuickJS-NG); the
   pool closes most of that gap.

9. **String interning for property keys + small literals.**
   Identifier strings interned at compile time + at heap
   allocation. Property-bag lookups become pointer compares
   in the hash key path instead of byte compares. Compounds
   with the IC: even on a cache miss, the hash lookup is
   faster. Also a precondition for the
   computed-property IC (`obj[k]` with hot constant `k`).

10. **SMI fast paths in arithmetic / comparison opcodes.**
    Cynic uses NaN-boxing so an int32 value is identifiable
    by tag. The `add` / `sub` / `mul` / `lt` / `eq` opcodes
    can check `(lhs.isInt32() and rhs.isInt32())` early and
    take a non-overflow integer path before falling back to
    the full numeric-tower coercion. Some opcodes already
    have this; auditing for completeness is the work.

11. **Direct-threaded dispatch.** Pre-decode each chunk's
    bytecode into a list of `(handler_fn_ptr, operand_bytes)`
    pairs at chunk-finalize time; the dispatch loop indexes
    that list directly, skipping the opcode-byte → switch-arm
    indirection. JSC's LLInt uses this pattern. Significant
    rewrite — a chunk grows a parallel "decoded" representation,
    every opcode handler becomes addressable via `&handler`,
    and `Chunk` ownership/layout shifts. Worth it only after
    everything else is exhausted. The interpreter perf
    ceiling without a JIT.

12. **Inline small function bodies at bytecode-emit time.**
    For non-recursive, non-escaping, small (<N bytecode bytes)
    functions, inline the body at the call site. Bytecode-
    level inlining (no JIT speculation required). Niche but
    real for hot helper functions.

13. **Environment hoisting (more sites).** `for-of` and C-style
    `for` already hoist the per-iteration env when the body has
    no closure capture (shipped). `while` / `do-while` / classic
    `for` blocks with no closures are candidate sites for the
    same analysis. Each hoist avoids one `allocateEnvironment`
    per iteration.

14. **Loop unrolling / loop-invariant code motion.** Bytecode-
    level unrolling pays icache cost on bigger bodies; rarely
    a win in practice for an interpreter. LICM needs escape
    analysis (JIT-territory). Both skipped unless a profile
    shows a specific workload that warrants the cost.

15. **Tail call optimization** (§15.10 / PTC) — *shipped*.
    See the *Proper Tail Calls* section below for the
    implementation note and the feature-flag gate.

The cross-engine bench dictates the order. If `prop_access` /
`prop_write` / call-heavy workloads sit at parity with
QuickJS-NG post-IC, the next bottleneck is `arith_loop` (pure
dispatch + arithmetic throughput) — items 5, 6, 7, 10. If
allocation-heavy workloads dominate, items 8, 9.

**Planned — GC latency.**

- **Incremental / concurrent marking.** The generational
  collector (shipped, above) still stop-the-world marks the
  mature set on a major cycle; incremental marking would amortize
  the long-pause tail. The next GC step after the generational
  split.

## Proper Tail Calls (PTC) — shipped

ES2015 §15.10 (with §14.6 PrepareForTailCall) — function calls
*in tail position* (`return f(x)`, the last expression of an
arrow body, `return cond ? f() : g()`, etc.) reuse the caller's
stack frame instead of pushing a fresh one. Spec wording is
mandatory; in practice only **JavaScriptCore** had been shipping
it. Cynic is the second.

**On by default.** No feature flag — the compiler always emits
`tail_call` / `tail_call_method` at statically-detectable tail
positions. The test262 fixtures under `language/*/tco-*` and the
`tail-call-optimization` frontmatter tag run as part of the
main ECMA-262 sweep.

### Cross-engine status (2026)

| Engine | PTC | Notes |
|---|---|---|
| JavaScriptCore | ✅ | Shipped 2016, still in. Bun inherits. |
| **Cynic** | ✅ | Shipped on by default. |
| V8 | ❌ | Implemented briefly behind a flag (2016), removed. Cited reasons: lost stack frames break dev-tools / `Error.stack`, hot-path cost on every call site, and the [STC counter-proposal](https://github.com/tc39/proposal-ptc-syntax) wanting explicit `return continue f()` syntax. |
| SpiderMonkey | ❌ | [Tracking bug](https://bugzilla.mozilla.org/show_bug.cgi?id=1188320) open since 2015. |
| Hermes / QuickJS / XS / Boa | ❌ | None. |

### Implementation

1. **Static tail-position detection** runs in the bytecode
   compiler — an inherited `in_tail_position` flag set by
   `compileReturn` and the `ArrowFunction` concise-body path,
   propagated through the §15.10.1-transparent expression types
   (parenthesized, conditional consequent / alternate, logical
   `&&` / `||` / `??` rhs, comma's last operand). Every other
   expression type clears the flag for its sub-expressions.
2. **`tail_call` / `tail_call_method` opcodes** (`src/bytecode/op.zig`).
   Operand layouts mirror `call` and `call_method`. The
   interpreter handler frees the current frame's register file,
   allocates the callee's, copies args, and overwrites the
   frame's chunk / ip / env / this / new.target / home /
   owning_module in place — no new push, no matching pop.
   Exotic callees (proxy, bound, native, generator, async) fall
   back to ordinary call semantics; the unconditionally-emitted
   `return_` immediately following the `tail_call` in the
   bytecode propagates the result.
3. **Disqualifiers** consulted at the call-emission site in
   `shouldEmitTailCall` (`src/bytecode/compiler.zig`):
   enclosing function is async or generator; `finally_chain`
   non-null (try-with-finally that would never run);
   `try_with_handler_depth > 0` (try-with-catch whose handler
   would be lost on frame reuse); any enclosing loop owes an
   `IteratorClose` (for-of with an open iterator).
4. **`Error.stack` impact**: a tail-called function disappears
   from the chain. Stack traces become harder to read. This is
   the spec-prescribed cost.

Cynic ships PTC tractably for reasons that don't apply to V8 /
SpiderMonkey: no JIT (no TurboFan / Ion retrofit cost), no
sloppy mode (no §15.10.1 carve-outs), no `eval` (no §15.10.1
direct-eval interaction), no `with` (drops out of the spec
walk), no DevTools surface today (no installed expectation
that `Error.stack` shows eliminated frames).

## Future work (post-strict-only-runtime)

- **Bistromath** — baseline JIT (T1). Direct opcode-to-native,
  inline caches for property access. Modeled on JSC Baseline /
  V8 Sparkplug.
- **Ohaimark** — optimizing JIT (T2). IR (SSA), type speculation
  from inline caches, deopt back to Lantern on guard failure.
  Modeled on JSC DFG / V8 TurboFan or Maglev.
