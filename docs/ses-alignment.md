# SES alignment — design & plan

Goal: Cynic ships **hardened by default** — frozen primordials, a
`harden()` global, and the SES override-mistake fix at every realm
init. No `lockdown()` step required, no `@endo/ses` import. Code
that needs the legacy "mutable primordials" world opts out with a
single `--unhardened` switch (the whole SES package toggles
atomically — see Phase 4).

Sister doc to [inline-caches.md](inline-caches.md) and
[lazy-property-bag.md](lazy-property-bag.md). This doc is the durable
plan — a fresh session should be able to pick up the next phase from
here without re-deriving the design.

## Why now — the position statement

Cynic was always strict-only, eval-banned, Annex-B-rejected — the
SES-friendly baseline. But "SES-friendly" is what every modern edge
runtime claims (Workers, Deno, Bun all ban `eval` at the runtime
boundary). What distinguishes a Cynic realm from a Workers isolate
today is roughly nothing visible — both refuse dynamic code, both
ship spec-compliant intrinsics, both are V8-shaped or
interpreter-shaped at the user's discretion.

**Frozen primordials by default** turns SES-friendly into
**SES-native**. The competitor on this axis isn't Workers — it's
"Node + `@endo/ses` + `lockdown()`". Cynic offers the same
guarantees without the userland import, without the lockdown
ceremony, without the configuration. That's the differentiator.

The trade-off: **monkey-patching primordials stops working out of
the box**. Code that polyfills `Array.prototype.flat`, stubs
`Date.now`, or proxies a built-in's prototype gets rejected by
default. Users who actually need that flip `--unhardened` to
disable the whole SES posture.

## What SES `lockdown()` does (the full checklist)

The `@endo/ses` reference defines SES operationally. Mapping each
guarantee against Cynic's status:

| # | SES requirement | Cynic today | This doc covers |
|---|---|---|---|
| 1 | Ban `eval` / `new Function(string)` family | ✅ default (gated by `--allow=eval`) | Phase 4 |
| 2 | Strict mode only, no sloppy code paths | ✅ permanent | — |
| 3 | No Annex B (HTML comments, legacy octal, `with`, etc.) | ✅ permanent | — |
| 4 | **Freeze all primordials at realm init** | ✅ shipped | Phase 1 |
| 5 | **`harden()` global** — recursive deep freeze | ✅ shipped | Phase 2 |
| 6 | **Override-mistake fix** — data props on frozen prototypes become accessor pairs that allow instance shadowing | ✅ shipped | Phase 3 |
| 7 | **`Compartment` class** — isolated realm-like sandboxes | ❌ — Cynic is single-realm | Deferred |
| 8 | Tame ambient state (`Math.random`, `Date.now`, …) | ❌ | Deferred (needs Compartments) |
| 9 | Tame error stacks | partial — minimal surface today | Phase 4 (small) |
| 10 | Tame RegExp legacy globals | ✅ explicitly out | — |
| 11 | **Frozen `globalThis`** | ✅ shipped | Phase 1 (folded in) |
| 12 | Whitelisted intrinsic shapes | mostly — Cynic ships only spec-defined surface | — |

Phases 1-3 + 11 land "SES baseline by default" — the meaningful
position. Compartments (7) require multi-realm support which Cynic
explicitly punts; revisit when a real compartment user arrives or
multi-realm shows up for another reason. Phase 4 (tame error stacks)
is small but has marginal value without Compartments — defer until
the rest is shipped and measured.

## What gets frozen (Phase 1)

Walk every reachable intrinsic from realm init and apply:
- `[[Extensible]] = false`
- Every data property → `{ writable: false, configurable: false }`
- Every accessor → `{ configurable: false }` (`get` / `set` stay
  the same callables, which themselves get frozen recursively)

Starts at `realm.intrinsics.object_prototype` and walks out through
every constructor, prototype, method, getter, setter, well-known
symbol. Cycle-safe via a memoization set (Object.prototype's
constructor → Object → Object.prototype is the canonical cycle).

Also frozen: `globalThis` itself — its named bindings become
non-writable / non-configurable. New global assignments stop
working in default mode.

**Not frozen** (these stay mutable per spec):
- User-allocated objects (every `{}`, `new` invocation, array
  literal, etc.)
- The globalThis-as-environment-record bindings created by
  top-level `let` / `const` / `var` in user scripts
- `Realm.evaluateScript`-injected modules' top-level bindings

The freeze fires **once per realm**, as the last step of
`intrinsics.install(realm)` after every builtin is wired. New
intrinsics installed by future built-ins after that point would
not be frozen — the install order matters; new builtins land
before the freeze, not after.

## `harden(value)` (Phase 2)

A global builtin that recursively freezes a value (and its
prototype chain, methods, etc.). Returns the original (mutated)
value.

Spec from `@endo/ses`:
1. If `value` is a primitive, return it
2. If `value` is already in the in-progress set, return (cycle break)
3. Add `value` to the in-progress set
4. For each own property descriptor:
   - If it's a data descriptor, recursively `harden(d.value)`
   - If it's an accessor descriptor, recursively `harden(d.get)` and `harden(d.set)`
5. `harden(Object.getPrototypeOf(value))`
6. `Object.freeze(value)`

Implementation in Zig (~100-150 lines), exposed on `globalThis` as
a non-configurable, non-writable property (it freezes itself
through being part of the intrinsic freeze pass).

Userland equivalent on every other engine is `import { harden }
from '@endo/ses'`. Cynic ships it natively.

## Override-mistake fix (Phase 3)

ECMAScript §10.1.9 OrdinarySetWithOwnDescriptor: assigning to an
own property that exists *only* on a frozen prototype:
- Strict mode: TypeError
- Sloppy mode: silent no-op

Cynic is always strict, so the current behaviour throws:

```js
const proto = Object.freeze({ x: 1 });
const obj = Object.create(proto);
obj.x = 2;   // TypeError
```

The "mistake": the user almost certainly meant to **shadow** the
prototype's `x` on the instance, creating an own property
`{ x: 2 }`. The spec says no because the prototype's descriptor is
non-writable, and §10.1.9 rejects the shadow.

SES's fix: when freezing a prototype, replace each data property
with an **accessor pair**:
- `get` returns the original value
- `set` calls `Reflect.defineProperty(this, key, { value, writable: true, enumerable: true, configurable: true })` — which creates the shadow on the receiver

Result: assignment-to-frozen-proto-prop succeeds as instance
shadowing instead of throwing. The prototype's value is still
globally immutable; instances can have their own values.

This is spec-conforming because accessor setters get called
through OrdinarySet, not through OrdinarySetWithOwnDescriptor's
non-writable rejection path. The behaviour matches what `@endo/ses`
does in its `lockdown()` implementation.

Implementation: extend the Phase 1 freezing pass to install
accessor pairs for data properties on **prototype objects only**
(not on constructors — those should stay frozen and reject
assignment). A single shared `(getter, setter)` pair can be
parameterised by the key, captured in closure.

Cost: the prototype's property access path goes from "direct slot
load" to "call the getter, which returns the slot" — a slowdown if
not optimised. The IC can still cache the getter's result if the
getter is pure (which it is for these synthetic accessors). The
fix needs care to not slow every prototype read by 2-3×.

## The `--unhardened` opt-out + `--allow=eval` (Phase 4)

SES-by-default means general-purpose JS that monkey-patches
primordials stops working in default mode. The opt-out surface
is intentionally minimal:

| Flag | Effect |
|---|---|
| `--unhardened` | Disables the **entire SES posture** atomically: primordials stay mutable (Phase 1 skipped), `globalThis` stays extensible, the `harden()` global is not installed (Phase 2), the override-mistake fix is skipped (Phase 3). Spec-literal `OrdinarySetWithOwnDescriptor` semantics. The single switch a user flips for full compatibility with general-purpose JS that monkey-patches `Array.prototype.X`, polyfills missing methods, or relies on the spec's "assign-to-frozen-proto throws" behaviour. |
| `--allow=eval` | Independent opt-in for `eval`, `new Function(string)`, and the `GeneratorFunction` / `AsyncFunction` / `AsyncGeneratorFunction` constructors. **Not bundled** with `--unhardened` because the two are orthogonal capabilities (a build can be unhardened yet eval-off, or hardened yet eval-on). **Shipped** — see "The eval engine" below. |

Why one umbrella switch instead of per-constraint flags:

- **SES is a coherent package** — frozen primordials + `harden()` +
  override-mistake fix are designed to work together. A user
  doesn't typically want "frozen primordials but no `harden()`"
  or "harden but no override fix"; they want either the hardened
  world or the legacy one. Atomic toggle matches the actual user
  decision.
- **One flag is easier to reason about** in CI, in embedder
  configuration, in deployment docs. Per-constraint flags
  (`--allow=primordial-mutation` / `--allow=extensible-globalThis`
  / `--allow=no-override-mistake-fix` / `--permissive` — an
  earlier iteration of this design) presented a menu where users
  would have to learn what each piece does just to know which
  ones to flip.
- **`harden()` is a capability addition**, not a restriction. It
  doesn't need a separate `--allow=*` flag because users who
  want their own `harden` just assign over `globalThis.harden`.
  Bundling it into the umbrella switch means a user who's
  rejecting the SES package also drops the Cynic-specific global
  cleanly (no leftover capability they'd have to manually undo).

Two distinct CLI verbs to keep separate:
- `--enable=<feature>` — turns on a not-yet-stable spec feature
  (`joint-iteration`, `upsert`, etc.). Forward-looking.
- `--unhardened` — the SES-posture toggle. Backward-compatible-
  with-legacy-JS.
- `--allow=<relaxation>` — kept as a verb for restrictions that
  have meaningfully different opt-in cost than the SES package.
  Currently only `--allow=eval` lives here.

The flag values get a `realm.allow.<name>: bool` field accessed at
the relevant gate in the engine. Default false; per-flag opt-in.

## Migration phases

Each phase builds green and is gated on `zig build test` + a
filtered `--only-failing` sweep, with a full sweep at the end of
each phase.

### Phase 1 — freeze primordials at realm init (+ globalThis) — **shipped**

`intrinsics.freezePrimordials` runs as the last step of
`intrinsics.install(realm)` when `realm.hardened` is true (the
default). Walks `globalThis` and every field of
`realm.intrinsics` through `hardenWalk` — the same recursive
deep-freeze `harden(value)` uses, keeping the Phase 1 freeze
shape in lockstep with the user-facing harden idiom. Cycle-safe
via the visited pointer set already in `harden.zig`.

After the pass:
- Every reachable intrinsic object / function has
  `[[Extensible]] = false`.
- Every own data descriptor is
  `{writable: false, configurable: false}`.
- Every accessor descriptor is `{configurable: false}`.
- `globalThis` itself is non-extensible — new bare-identifier
  assignments (`globalThis.x = 1`) throw.

`canDeclareGlobalVar` / `canDeclareGlobalFunction` carry a
`hardened` parameter (threaded through from
`realm.hardened`) and skip the extensibility check when set.
Top-level `var x = 1` keeps working under the SES posture — the
host's program-level binding install is distinct from user JS
poisoning globalThis by assignment.

`--unhardened` flips `realm.hardened` to `false` before
`installBuiltins`; the freeze pass is then a no-op and the
intrinsic graph stays mutable. Test262 verification:
`zig build test262 -- --phase=unhardened` runs the main-phase
fixture set with the freeze skipped.

Acknowledged gaps (inherited from `hardenWalk`):
- Array-exotic indexed slots aren't lowered into the property
  bag — none of the intrinsic objects today are array exotics
  (Array.prototype, etc. are plain objects in Cynic), so the
  gap is dormant on the intrinsic graph.
- Module Namespace objects can't be made non-extensible per
  §9.4.6.6; no intrinsic is a module namespace.
- Proxy receivers — no intrinsic is a Proxy.

**Test262 risk:** observed — handful of fixtures (those that
monkey-patch intrinsics) regress in the default hardened sweep;
the `--phase=unhardened` sweep confirms each comes back when
the freeze is skipped.

### Phase 2 — `harden()` global — **shipped**

Lives in `src/runtime/builtins/harden.zig`, installed at the end
of `intrinsics.install` (so the walk can reach the intrinsic graph
once it's wired). Native Zig — primitives pass through; objects /
functions get `extensible = false` + every own descriptor stamped
`{writable: false, configurable: false}`. Recursion walks own
property values, accessor getters / setters, and the
prototype chain. Visited set keyed by heap pointer makes the walk
cycle-safe. Three unit tests pin the contract (`harden recursively
freezes own data + nested + prototype`, `harden is cycle-safe +
returns its argument`, `harden of a primitive is a no-op`).

Known acknowledged gaps (acceptable for the MVP):
  - Module Namespace objects can't be made non-extensible per
    §9.4.6.6; skipped rather than throw.
  - Proxy receivers freeze via direct slot mutation here, not
    through the `preventExtensions` trap.
  - Recursion uses the Zig stack; pathological depth would
    overflow. Real-world capability graphs are shallow.

When Phase 1 ships, the primordial freeze runs first, so
`harden(globalThis)` becomes mostly a no-op walk over already-
frozen intrinsics — the path stays correct (the visited set
short-circuits the redundant freezes).

### Phase 3 — override-mistake fix — **shipped**

`installOverrideMistakeFix` runs as Pass 2 of
`freezePrimordials`. For every prototype object reachable
through `realm.intrinsics` (every `*_prototype` field + every
constructor's `.prototype` slot), each own data descriptor is
demoted to a synthetic accessor pair: the getter returns the
captured value verbatim; the setter performs
DefineOwnProperty on the *receiver* with `{value, writable:
true, enumerable: true, configurable: true}`. Constructors,
namespace objects (`Math`, `JSON`, `Reflect`), and `globalThis`
keep their data descriptors so direct intrinsic mutation
(`Math.PI = 4`) still throws.

The `constructor` back-edge is left as a frozen data slot to
avoid routing every `instance.constructor` read through a
getter — that property is on every prototype and would
multiply IC misses.

The synthetic setter throws if asked to redefine on the frozen
holder (`Array.prototype.flat = badImpl`), since the accessor
slot is non-configurable. Receivers further down the prototype
chain succeed by creating the own data property — the
override-mistake fix proper.

**IC interaction.** `callJSFunction` short-circuits on
`JSFunction.synth_accessor` before allocating a call frame —
the getter is a pointer load, the setter is a property-define
op. The `lda_property` slow-path also fast-paths synthetic
getters on its hot arms (plain-object receiver,
function-receiver). Future work: extend the inline cache to
remember the captured value at the call site so the hot
`obj.toString()` read avoids the `lookupAccessor` walk entirely.

**Test262 risk:** observed — fixtures that pin built-in
function `.name` / `.length` descriptors as `configurable: true`
per §17 regress because the freeze locks them
non-configurable. These are the dominant cluster of regressions
under the `hardened` score row; the `unhardened` row
recovers them in full.

### Phase 4 — `--unhardened` flag wiring

Trivial — collect the gates (Phase 1 freeze, Phase 2 harden
install, Phase 3 override fix) and skip them all when
`realm.hardened == false`. Single CLI parser change + docs +
one struct field on Realm. `--allow=eval` is independent and
landed separately when eval ships.

### Phase 5 — measurement, doc updates, gh-pages

- Run the full bench suite — confirm no regression
  (the override-mistake accessor pair is the perf risk)
- Run test262 with `--unhardened` isolated as a phase, confirm
  the relaxation path keeps test fixtures that depend on
  prototype-mutation alive
- Update website (`gh-pages/index.html`) — the "Cynic says" column
  for the SES-adjacent rows gains "hardened by default"
- Update `bench-cross-results.md` if the perf moved

## Compatibility risks

Things that **stop working** by default after Phase 1:

```js
Array.prototype.flat = function() { ... };     // throws — proto frozen
Object.prototype.foo = 'bar';                  // throws
Date.now = () => 0;                            // throws (intrinsic frozen)
globalThis.x = 1;                              // throws — globalThis frozen
String.prototype.includes ??= function() {};   // throws if shipped
```

Things that **continue to work**:

```js
const obj = { a: 1 };
obj.a = 2;                                     // user-allocated, mutable
obj.b = 3;
class Foo {}; Foo.prototype.method = () => {}; // user class, mutable
const arr = [1, 2, 3]; arr.length = 0;         // user array, mutable
let x = 5; x = 10;                             // user binding, mutable
```

The dividing line: **engine-installed intrinsics are frozen; user-
allocated objects are not**. SES's whole bet is that this line is
where security matters and where compatibility costs are lowest.

## Compartments — why deferred

`Compartment` is what makes SES SES rather than "just hardened
primordials". It's the API for confining code:

```js
const c = new Compartment({ globals: { fetch: limitedFetch } });
c.evaluate('await fetch("/api")');  // only sees limitedFetch
```

**Primary reason it's postponed: `Compartment` is a TC39 *Stage 1*
proposal** ([tc39/proposal-compartments](https://github.com/tc39/proposal-compartments)).
Stage 1 means the shape is still being explored — the constructor
options, the module-descriptor design, and the `import` hook are all
subject to change. Cynic's policy is to not ship pre-Stage-4 proposals
by default (see [ROADMAP.md](ROADMAP.md) "Pre-Stage-4 proposals
shipped" — only stabilising proposals graduate in), and an unstable,
churning API is the wrong thing to bake into the engine's
confinement boundary. So Compartments waits on the proposal, not on
Cynic.

The engine substrate they need has, in fact, largely landed (see
[multi-realm.md](multi-realm.md)): multiple coexisting realms with
per-realm intrinsics + globals, realm-aware free-binding / intrinsic
resolution, a shared-heap GC that marks every realm's roots, and
`ShadowRealm` (constructor + `.evaluate` + `.importValue` + the
callable boundary) with per-realm teardown. What a `Compartment`
constructor would still add on top:
- the user-visible `Compartment` class + its options object,
- a per-compartment module loader (the proposal's module
  descriptors / virtual modules — themselves Stage 1 and in flux),
- endowment plumbing (deep-frozen globals handed in at construction).

Revisit Compartments when:
1. **The proposal advances** (Stage 2+), so the API surface is stable
   enough to commit to; AND/OR
2. A real Compartment user shows up (Agoric-style high-integrity
   computation, a hardened plugin system, a host needing per-tenant
   confinement).

## Out of scope (deferred or rejected)

- **`Compartment` class** — Phase 7+ work. See above.
- **Tame ambient state** (`Math.random`, `Date.now`, etc.) — only
  useful with Compartments. SES taming is per-realm; without
  Compartments there's nothing to tame against.
- **Enforcing `lockdown()`-style intrinsic shape restrictions
  beyond freezing** — SES does extra work to remove "powerful"
  intrinsics. Cynic doesn't ship most of them anyway (`eval` /
  `Function(string)` are off unless `--allow=eval`; no `RegExp`
  legacy globals).
- **`StaticModuleRecord` / `SyntheticModuleRecord`** — module API
  for Compartments. Deferred with Compartments.
- **Compartment confinement of eval'd code** — `--allow=eval` runs
  eval'd source in the realm itself, not a sandbox (see "The eval
  engine"). True SES Compartment confinement (endowment-only globals)
  is deferred with Compartments.

## The eval engine (`--allow=eval`)

Shipped behind the `--allow=eval` gate (`realm.allow_eval`, default
false). With the gate closed Cynic refuses runtime code construction:
§19.2.1.2 HostEnsureCanCompileStrings throws an `EvalError` (the spec
leaves the error type host-defined; `EvalError` matches Node's
`--disallow-code-generation-from-strings` and browser CSP). A genuine
parse failure *after* the gate opens is a `SyntaxError` instead — the
two are distinct (capability refusal vs parse outcome). With the gate
open the following run for real:

- **`eval(x)` — §19.2.1.** Indirect eval (`(0, eval)(s)`,
  `globalThis.eval(s)`) evaluates `s` as global-scope code through the
  existing `evaluateEval` pipeline. Direct eval (the syntactic
  `eval(...)` form) is detected at compile time and lowered to a
  dedicated `direct_eval` opcode that captures a snapshot of the
  caller's visible env-slot bindings; at runtime the eval'd source is
  compiled against a synthetic outer scope rebuilt from that snapshot
  and run in a frame whose environment is parented to the caller's, so
  free identifiers resolve against the caller's locals and the eval
  inherits the caller's `this` / `new.target` / home object. A
  non-string argument is returned unchanged (§19.2.1 step 2). The
  runtime re-checks that the callee is actually `%eval%`, so a
  reassigned `globalThis.eval` is an ordinary call, not a direct eval.
- **`Function` / `GeneratorFunction` / `AsyncFunction` /
  `AsyncGeneratorFunction` string constructors — §20.2.1.1.1
  CreateDynamicFunction.** Implemented by source synthesis: the
  parameter strings + body are wrapped in a parenthesized function
  expression with the kind's prefix and run through `evaluateEval`, so
  the new function's scope is the global environment per spec.

**Strict-only — conformant for direct eval, a deliberate divergence
for indirect.** Cynic parses all source as strict, so it runs *every*
eval as strict code. For **direct** eval this is spec-conformant:
§19.2.1.1 PerformEval sets `strictEval = strictCaller OR IsStrict(body)`,
and every Cynic caller is strict, so `strictCaller` (hence `strictEval`)
is always true. For **indirect** eval it is a divergence: there
`strictCaller` is false (§19.2.1.1 step 1), so `strictEval = IsStrict(body)`
— a source with no `"use strict"` directive is *sloppy*, and engine262
(the reference) plus every shipping engine (V8 / JSC / SpiderMonkey /
QuickJS) run it sloppy. Cynic has no sloppy parser, so it runs indirect
eval strict like all its other code: strict-compatible source evaluates
correctly, while sloppy-only behaviour — `with`, `delete unqualifiedName`,
an undeclared assignment creating a global — is rejected or runs strict,
the same strict-only divergence Cynic carries for any script. (Nearest
prior art: Hermes also rejects `with` in eval'd source, though it keeps
other sloppy semantics. No shipping engine runs indirect eval strict —
that posture is unique to a strict-only engine.)

Either way the eval body gets its own variable environment (§19.2.1.3),
so top-level `var` / function declarations bind eval-locally and never
leak to the global env (indirect eval) or the caller's scope (direct
eval). Direct eval still *reads* the caller's scope for free
identifiers. Implemented via the compiler's `eval_local` mode, which
routes the eval body's top-level bindings through the same non-global
path module bodies use; `ShadowRealm.prototype.evaluate` stays on Script
evaluation (var → the shadow realm's global env, §3.8.3.7) and is
unaffected. Corollary: test262 fixtures asserting *indirect* eval runs
as sloppy can never pass and stay permanently out of scope
(`strict_only_exact_paths` in `tools/test262/skip.zig`).

**Posture interaction.** The eval engine is posture-agnostic; the
realm's existing freeze state does the confinement. Under the hardened
default, eval'd code sees the frozen primordials + override-mistake
fix — so `eval("Array.prototype.push = 1")` throws, and that freeze
*is* the confinement Cynic can offer pre-Compartments. Under
`--unhardened` the same eval'd code sees mutable primordials. No fake
endowment / confinement layer is built; full SES Compartment
confinement is deferred (see "Out of scope").

**test262.** The harness scores every fixture binary pass/fail under
a single posture — `--unhardened --allow=eval` (`realm.hardened =
false`, `realm.allow_eval = true`) — so the eval surface (~2,100
fixtures) runs for real and any eval-surface miss counts as a plain
`failing`, same as an engine bug. There is no eval-off "correctly
handled" reclassification. See `test262-results.md` and
[handbook/ses-test262-policy.md](handbook/ses-test262-policy.md)
(retired policy model) for the full picture.

**Default-off is a permanent, intentional divergence.** `eval` /
`Function(string)` / `Async`/`GeneratorFunction` refusing by default is
a deliberate, terminal design choice, not a stop-gap — the same class of
default-non-conformance Cynic already carries for Annex B and sloppy
mode. The spec (§19.2.1, §20.2.1.1, §27.5.1.1, §27.7.1.1) defines these
as callable with no host-refusal branch outside the gate, and every
shipping engine (V8 / Node, JSC, SpiderMonkey, QuickJS) runs them by
default; Cynic's hardened-by-default posture overrides that, the same
way it ships strict-only and Annex-B-out. Three points settle the
question (tracked as issue #25):

- **Conformance scoring is not affected.** The test262 harness self-sets
  `realm.allow_eval = true` (the scored `--unhardened --allow=eval`
  posture above), so the ~2,100 eval-surface fixtures already run for
  real. Default-off costs zero test262 points.
- **A `--conformance` mode that flips only eval would be redundant**
  with the existing `--allow=eval`, and a *true* conformance mode is
  incompatible with Cynic's strict-only / Annex-B-out target (it would
  have to re-enable sloppy mode and Annex B), so there is nothing
  coherent for it to mean here.
- **`--allow=eval` is the documented escape hatch** for an embedder or
  user who genuinely needs runtime code construction, and it runs the
  real engine described above.

So Cynic does **not** claim default-configuration conformance on this
surface and will not flip the default. Users who want spec-default eval
pass `--allow=eval`; everyone else gets the hardened posture.

## Verification

- `zig build test` after each phase
- `zig build test262 -- --quiet` runtime sweep after each phase —
  measure the regression (expected: tens of fixtures in default
  mode that monkey-patch intrinsics)
- `zig build test262 -- --quiet --phase=feature:unhardened` —
  confirms the opt-out path restores fixtures that monkey-patch
  primordials
- `zig build bench` after Phase 3 — perf check on the override-
  mistake accessor pair (the headline risk)
- New unit tests pinning:
  - `Object.freeze` semantics on intrinsics (Phase 1)
  - `harden()` on cyclic and deep structures (Phase 2 — shipped)
  - Override shadowing via assignment + Reflect.set + spread (Phase 3)
  - `--unhardened` actually disables every gated piece (Phase 4)
- Manual smoke test: import an SES-using package (`@endo/marshal`,
  the canonical one) and confirm it runs without `lockdown()`

## Abort criteria

Pull the change at any phase where:

1. Test262 default-mode sweep regresses by >150 fixtures and the
   regressions don't cluster around a single fixable mistake
2. The Phase 3 accessor-pair design causes a >15 % perf regression
   on `prop_access` (the IC has to optimize the synthetic getter
   case — if it can't, redesign or abandon the override-mistake fix)
3. A user-facing brand survey shows the SES-by-default messaging
   isn't resonating (this is a brand bet; if the market signal is
   clearly against, revisit)
