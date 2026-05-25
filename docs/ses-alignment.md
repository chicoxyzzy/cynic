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
| 1 | Ban `eval` / `new Function(string)` family | ✅ permanent | — |
| 2 | Strict mode only, no sloppy code paths | ✅ permanent | — |
| 3 | No Annex B (HTML comments, legacy octal, `with`, etc.) | ✅ permanent | — |
| 4 | **Freeze all primordials at realm init** | ❌ | Phase 1 |
| 5 | **`harden()` global** — recursive deep freeze | ❌ | Phase 2 |
| 6 | **Override-mistake fix** — data props on frozen prototypes become accessor pairs that allow instance shadowing | ❌ | Phase 3 |
| 7 | **`Compartment` class** — isolated realm-like sandboxes | ❌ — Cynic is single-realm | Deferred |
| 8 | Tame ambient state (`Math.random`, `Date.now`, …) | ❌ | Deferred (needs Compartments) |
| 9 | Tame error stacks | partial — minimal surface today | Phase 4 (small) |
| 10 | Tame RegExp legacy globals | ✅ explicitly out | — |
| 11 | **Frozen `globalThis`** | ❌ | Phase 1 (folded in) |
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
| `--allow=eval` | Independent opt-in for `eval`, `new Function(string)`, and the `GeneratorFunction` / `AsyncFunction` / `AsyncGeneratorFunction` constructors. **Not bundled** with `--unhardened` because eval is a compile-time optimization fence — every function eval-reachable gets per-function escape analysis + a conservative bytecode variant. Users who want mutable primordials WITHOUT paying the eval-taint compile cost stay on `--unhardened` alone. Requires the full eval implementation (deferred — see notes below). |

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

### Phase 1 — freeze primordials at realm init (+ globalThis)

The freezing pass. Recursive walk + memoization + descriptor
update. Wired as the last step of `intrinsics.install(realm)`.

The pass is gated on `realm.hardened` (the default-true flag the
single `--unhardened` switch flips). When `--unhardened` is set,
the pass is skipped — every intrinsic stays extensible and
writable, matching legacy JS expectations. Test262 sweep runs
the default (frozen) path; a per-feature `--phase=feature:
unhardened` sweep verifies the relaxation path stays functional.

**Risk:** medium. test262 fixtures that monkey-patch intrinsics
fail; need to measure. Probably <100 fixtures.
**Test262 risk:** measurable but bounded. Some fixtures explicitly
test "you can patch the prototype" — those become honest failures
in default mode, expected passes under `--unhardened`.

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

### Phase 3 — override-mistake fix

Extend the Phase 1 freezing pass: when freezing a prototype's data
property, install accessor pairs instead. The setter creates an
own data property on `this`.

**Risk:** medium-high. Subtle — the accessor pair has to behave
correctly when called from `Reflect.set` / `Reflect.defineProperty`
/ `Object.assign` / the spread operator / destructuring assignment.
Each path through OrdinarySet has to land on the synthetic setter
correctly.

**Perf risk:** prototype property reads go through getters. The IC
needs to optimize the synthetic getter case (the getter is pure;
its return value is the slot value, cacheable). If the IC can't
cache it, every prototype-inherited property read is 2-3× slower.

**Test262 risk:** moderate — fixtures that test "OrdinarySet
rejects non-writable proto slot" need to factor in the override
fix. The same `realm.hardened` flag gates this — `--unhardened`
skips the synthetic accessor swap and Cynic reverts to spec-
literal `OrdinarySetWithOwnDescriptor`.

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

This requires **multi-realm support** at the engine level. Cynic
explicitly punts multi-realm today (see `tools/test262/skip.zig`
for the `proto-from-ctor-realm*` skips and the note explaining
single-realm is permanent until that changes).

To ship Compartments, Cynic would need:
- Multiple realms per engine instance, user-visible
- Per-realm intrinsic installation (could share intrinsics across
  compartments — SES does this for memory efficiency)
- Per-compartment module loader (StaticModuleRecord /
  SyntheticModuleRecord)
- Endowment plumbing (what powers cross the boundary)

That's a **months-scale** project. Phases 1-3 above ship "the
useful 80%" of SES alignment without it.

Revisit Compartments when:
1. A real Compartment user shows up (Agoric-style high-integrity
   computation, hardened plugin system, etc.), OR
2. Multi-realm becomes necessary for another reason (e.g. a host
   embedding that needs per-tenant realms)

## Out of scope (deferred or rejected)

- **`Compartment` class** — Phase 7+ work. See above.
- **Tame ambient state** (`Math.random`, `Date.now`, etc.) — only
  useful with Compartments. SES taming is per-realm; without
  Compartments there's nothing to tame against.
- **Enforcing `lockdown()`-style intrinsic shape restrictions
  beyond freezing** — SES does extra work to remove "powerful"
  intrinsics. Cynic doesn't ship most of them anyway (no `eval`,
  no `Function(string)`, no `RegExp` legacy globals).
- **`StaticModuleRecord` / `SyntheticModuleRecord`** — module API
  for Compartments. Deferred with Compartments.
- **The full eval-implementation work** for `--allow=eval` — this
  is its own multi-month project (see the design conversation in
  session history; eval is a major optimization fence and needs
  per-function escape analysis). The flag is reserved here; the
  implementation lands in a separate effort.

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
