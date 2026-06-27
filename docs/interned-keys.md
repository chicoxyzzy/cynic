# Property-key interning (atoms) — design & go/no-go

Status: **measured dead-end (2026-06).** The Phase-1 prototype was
built behind `-Dintern-keys` and decided by the layout-controlled A/B
the design demanded (§9). It did **not** clear the bar — no reproducible
win, the deltas indistinguishable from code-layout noise — so it is
**not shipped**. The full result is in §11; do not re-attempt without a
materially different approach (and read §11 first). The sections below
are the original design, kept for the record. It is a *cross-lane*
change (shape/IC + string + GC), so it needed the owning efforts' buy-in
— see §8.

## 1. The problem

Profiling `deltablue` and `raytrace` (no-jit, ReleaseFast, samply) puts
**~13–16 %** of interpreter time in one cluster, on both macros:

| symbol | deltablue | raytrace | what it is |
|---|--:|--:|---|
| `runtime.shape.Shape.lookup` | 9.3 % | 7.1 % | transition-chain walk, `std.mem.eql` per node |
| `hash.wyhash.Wyhash.hash` | 2.4 % | 3.1 % | hashing the key string for the bag / transition cache |
| `runtime.string.JSString.flatBytes` | 3.2 % | 0.5 % | re-flattening the key string, per access |
| `runtime.shape.ShapeTree.transition` | — | 2.6 % | shape transitions building many small objects |

This is the **megamorphic IC-miss path**. A monomorphic named-property
IC hit is pure shape-pointer + slot — *no key is consulted at all*
([interpreter.zig:9599-9621](../src/runtime/lantern/interpreter.zig)):

```zig
if (cell.shape != null and cell.shape == obj_in.shape) { ... acc = obj_in.slotAt(cell.slot); ... }
```

The key only enters on a **miss** ([interpreter.zig:9626](../src/runtime/lantern/interpreter.zig)):

```zig
if (sh.lookup(key_s.flatBytes())) |entry| { ... }
```

deltablue's constraint-subclass sites are megamorphic (working set
wider than the mono IC / any small poly set — see the poly-IC dead-end
in [inline-caches.md](inline-caches.md)), so they miss almost every
access and pay `Shape.lookup`'s byte-compare chain walk + a per-access
`flatBytes` + a `Wyhash` every time.

## 2. What interning buys — and what it does NOT

`Shape.lookup` ([shape.zig:73-82](../src/runtime/shape.zig)) walks the
parent chain doing `std.mem.eql(u8, n.key, key)` per node, and the key
arrives as freshly-`flatBytes()`'d bytes. **Interned keys** give every
property name a single canonical identity (+ a cached hash), so:

- `std.mem.eql(n.key, key)` → a **pointer (or u32) compare**;
- the per-access `flatBytes()` disappears (the key *is* the atom);
- the bag's `Wyhash` re-hash disappears (hash cached on the atom).

**It does not** speed:

- the **IC-hit** path — already optimal (shape-ptr + slot, no key);
- the **O(depth) walk length** — interning makes each node's compare
  O(1), but the number of nodes is unchanged. Killing the walk needs a
  per-shape hash index (a separate, larger change — §9 Phase 2).

So the realistic win is the *compare + flatten + hash* fraction of the
~15 % cluster, **not all of it**. Estimate ~5–10 %, and — given the
[macro A/B layout-noise lesson](inline-caches.md) (the `flatBytes`
inline "win" was layout noise) — this **must be proven with a
layout-controlled A/B that clears ~8 % reproducibly**, not banked on
the profile alone. That uncertainty is the central caveat of this doc.

## 3. Prior art

Every production engine interns property keys, precisely because
shape/structure lookup is this hot:

- **V8** — *internalized strings* (`Name`): each property key is a
  unique internalized string with a cached hash; map (shape) descriptors
  store `Name*` and compare by pointer. The name table is a weak,
  GC-managed global.
- **JavaScriptCore** — `UniquedStringImpl` / `AtomStringImpl`
  (`Identifier`), cached hash; `Structure` stores the uniqued impl and
  compares by pointer; `PropertyName` wraps it.
- **SpiderMonkey** — *atoms* (`JSAtom` = a `JSString` with the atom bit,
  interned in a per-zone atoms table, swept as weak); `PropertyKey`
  (`jsid`) is a tagged atom-pointer | small-int | symbol.
- **QuickJS** — `JSAtom` is a `u32` index into a per-runtime,
  refcounted atom array; property keys are these ints — the cheapest
  possible compare.

Common shape: the key *is* an atom carrying identity + cached hash; the
atom table is GC-managed (weak / refcounted) so dynamically-generated
keys don't grow it without bound. ECMA-262 PropertyKey (§6.1.7) is a
String or Symbol and is representation-agnostic, so interning is a
purely-internal, **observably transparent** optimization.

## 4. Cynic today (the substrate map)

- **No atom table.** Chunk-constant property names are `pinned`
  (realm-lifetime — [string.zig:90-94](../src/runtime/string.zig)) but
  **not deduplicated**: two chunks' `"x"` are distinct `JSString`s with
  distinct byte buffers, so pointer identity does *not* hold across (or
  even within) chunks today.
- **Shape keys are arena-duped byte copies**
  ([shape.zig:136](../src/runtime/shape.zig) `a.dupe(u8, key)`),
  realm-lifetime, matched by `std.mem.eql` (never by pointer).
- **The bag** is `std.StringArrayHashMapUnmanaged(Value)`
  ([object.zig:830](../src/runtime/object.zig)) with a byte-hashing
  `StringContext`; keys are kept alive by anchoring the source
  `JSString` in `key_anchors`
  ([object.zig:1241](../src/runtime/object.zig),
  `anchorKey` [object.zig:1387](../src/runtime/object.zig)).
- **The read IC caches keys only for computed access** (a 23-byte
  inline buffer, `cached_key_*` in
  [chunk.zig](../src/bytecode/chunk.zig)); named-property ICs cache no
  key.
- **Symbols** carry a per-symbol synthetic `prop_key`
  (`<sym:0xptr>`, [symbol.zig](../src/runtime/symbol.zig)) — already a
  unique identity, but a separate type from strings.

## 5. Proposed design

A **per-realm atom table**: `bytes → canonical *JSString` (the atom),
each atom a pinned, deduplicated `JSString` carrying a cached
`key_hash: u32`. Keep `[]const u8` at API boundaries; add an atom
identity alongside.

Two representations:

- **(a) Pointer-identity atoms (recommended).** Atoms are canonical
  `*JSString`. `Shape` stores the atom pointer (no `dupe` — the atom is
  realm-lifetime already); `Shape.lookup` compares `n.key_atom ==
  key_atom` with a `std.mem.eql` **fallback** for non-atom lookup keys.
  Smallest blast radius; incremental; the chunk-constant key at named
  sites becomes its interned atom so the common path is pointer-only.
- **(b) `Atom = u32` index (QuickJS-style).** Replaces `[]const u8`
  keys in shapes + bag with a small int. Cheapest compares, but the
  largest blast radius (every key site retyped). Deferred.

**Critical safety decision — intern only compile-time property-name
constants.** Dynamic / computed keys (`obj[s]`) keep the byte path.
Interning-on-access would let untrusted `obj[randomString()]` in a loop
grow the atom table without bound — a memory DoS that violates the
*never unbounded resource growth on untrusted input* contract
([AGENTS.md](../AGENTS.md) / [host-safety.md](handbook/host-safety.md)).
Static names are bounded by the program's distinct compile-time
property names, so a **strong-rooted** table is safe. Most hot access
(`deltablue`/`raytrace` `.foo`) is static → the win is captured without
the DoS. (Weak, GC-collectable atoms for dynamic keys are a later
option — §9 Phase 3 — and are what V8/SM do, but they need a GC
weak-clear pass.)

**Symbols** already have unique identity; an atom is then `interned
string-ptr | symbol-ptr` (the symbol's existing pointer *is* its atom),
unifying the two key kinds without a parallel table.

## 6. Blast radius

| file | change |
|---|---|
| `runtime/string.zig` | add `key_hash: u32` (cached); `internProperty(bytes) -> *JSString` |
| `runtime/realm.zig` | own the per-realm atom table; free on realm teardown (ShadowRealm-safe) |
| `bytecode/chunk.zig` + compiler | intern property-name constants at `pinChunk` / chunk-finalize → dedup into the realm table |
| `runtime/shape.zig` | `transition` stores the atom (no dupe); `lookup` compares atom identity + byte fallback |
| `runtime/object.zig` | (optional, Phase 2) bag keyed on atom hash/identity |
| `runtime/heap.zig` | atom table as a strong root (static-only ⇒ bounded); weak-clear pass only if Phase 3 |
| `lantern/interpreter.zig` | named-property miss path passes the interned atom instead of `flatBytes()` |

## 7. GC & safety

- **Bounded by construction.** Static-only atoms ⇒ a strong root that
  can't grow without bound on hostile input. This is the load-bearing
  safety property; it is why dynamic keys are excluded in Phase 1.
- **Per-realm.** The table lives on the realm, so `ShadowRealm` / realm
  teardown frees it — no cross-realm leak, consistent with
  [multi-realm.md](multi-realm.md).
- **Transparency.** PropertyKey identity is unobservable (§6.1.7);
  interning must be byte-for-byte transparent — the test262 gate
  (full sweep, byte-identical pass set) is the correctness contract.
  Symbol identity semantics are unchanged.
- **SES.** Frozen primordials' property names are a natural atom set;
  interning is non-observable so there is no hardening conflict.

## 8. Lane coordination (read before coding)

This crosses **three** ownership lanes: the **shape / IC substrate**
(`shape.zig`, `ICCell`), the **string** representation (`string.zig`),
and **GC rooting** (`heap.zig`). It is *not* a solo interpreter-perf
micro-opt. Before implementation it needs sign-off from the IC owner
(shape/ICCell invariants, Bistromath's fixed-offset reads of the cell)
and the GC owner (the atom table as a root; any future weak-clear).
The Bistromath JIT reads `ICCell` at fixed offsets
([jit.md](jit.md)) — atoms touch the *miss* path and the shape's key
storage, not the cell layout, but the `--jit` differential gate must
stay exact.

## 9. Phasing & gates

- **Phase 1** — realm atom table; intern chunk-constant property names;
  `Shape` stores/compares atoms (static keys), byte fallback for
  computed. **Behind a build flag.** Gate: full test262 byte-identical
  + `--jit` differential exact + gc-stress clean (`--gc-threshold=1`) +
  a **layout-controlled** macro A/B (multiple independently-perturbed
  builds; ship only if it clears ~8 % reproducibly — else it is noise,
  like `flatBytes`, and Phase 1 is reverted).
- **Phase 2** (only if Phase 1 clears) — bag keyed on atom hash; a
  per-shape hash index to attack the O(depth) walk length itself.
- **Phase 3** (deferred) — weak, GC-collectable atoms for dynamic keys
  (with a GC weak-clear pass), lifting the static-only restriction.

## 10. Go / no-go

**The lever is real** (a profiled ~15 % cluster on two macros, the same
target the poly-IC dead-end pointed at) **but the deliverable magnitude
is uncertain** — interning addresses the per-node compare + flatten +
hash, not the walk length, so the honest expectation is a fraction of
that cluster, plausibly near the layout-noise floor that just sank the
`flatBytes` change.

**Recommendation: a flag-gated Phase-1 prototype, decided by a
layout-controlled A/B — not a commitment to the full substrate change
on the profile alone.** Build Phase 1 behind a flag, prove ≥~8 %
reproducible on `deltablue`/`raytrace` across perturbed builds, and only
then wire it on and proceed to Phase 2. If it can't clear the floor,
record it as a measured dead-end (like poly-IC and `flatBytes`) and stop
— the three landed interpreter wins (richards/navier/crypto) are the
harvest, and the remaining macro gaps are out-of-lane (JIT poly
dispatch, GC).

Because Phase 1 still touches the shape/IC + GC substrate, even the
prototype needs the §8 coordination. It is the right next interpreter
lever **if** the user wants a real macro win and is willing to run a
cross-lane effort; otherwise it stands here as the documented future
direction.

## 11. Measured result — Phase 1 prototype (dead end, 2026-06)

Phase 1 was built exactly as scoped (per-heap atom table; chunk-constant
property names interned in place at `pinChunk`; `Shape` stores/compares
atoms with a `std.mem.eql` byte fallback; the hot read miss path and the
`shadowSet` / `resolveCtorInitialShape` / `make_object_shape` shape
builders wired to atoms), behind `-Dintern-keys` (default off).

**Correctness was clean.** Transparency held to the letter: the full
test262 pass set was byte-identical flag-on vs flag-off (46798 pass /
3097 fail both), the `--jit` differential was exact, gc-stress at
`--gc-threshold=1` was crash-free with identical pass/fail, and
`test-fast` was green both ways. PropertyKey identity (§6.1.7) stayed
unobservable. So the optimization is *sound* — it simply doesn't pay.

**Perf did not clear the bar.** The decision used the design's own
layout-controlled A/B (§9): one flag-off baseline, three independently
layout-perturbed flag-on builds (`-Dbench-pad ∈ {0, 96, 192}`),
interleaved on the remote box (host drift cancelled). Octane macros,
`--no-jit` (the interpreter tier the lever targets), ratio = flag-on /
flag-off (>1 ⇒ interning **slower**):

| macro | pad 0 | pad 96 | pad 192 |
|---|--:|--:|--:|
| deltablue | 1.019 | 1.004 | 0.977 |
| raytrace  | 1.015 | 1.035 | 1.030 |
| crypto    | 1.062 | 1.016 | 1.040 |
| richards  | 1.032 | 1.011 | 1.017 |

(JIT-tier ratios were the same shape; spreads ran 12–43%, dwarfing every
delta.)

**Why it's noise, not a win.** Two independent tells:

1. **The sign is not stable.** deltablue crosses 1.0 across the perturbed
   builds (1.019 → 0.977). A real effect keeps its sign under
   perturbation; this doesn't.
2. **A macro that cannot benefit moves the same amount.** `crypto` is
   integer-bound (RSA) and barely touches named-property access, yet it
   shifts ~2–6% in lockstep with the rest. The deltas are therefore a
   global **code-layout / code-size** artifact of the larger flag-on
   binary, not a property-path effect — exactly the trap the `flatBytes`
   inline "win" set (§2, [inline-caches.md](inline-caches.md)).

Nothing approached the **≥8% reproducible** floor the gate required, and
the only *consistent* direction across pads was **marginally slower**.

**Mechanistic reading (why the ceiling is so low).** Interning attacks
the per-node `std.mem.eql` + per-access flatten/hash (§2), but on real
property names — 3–8-byte identifiers — `std.mem.eql` is already a
couple of byte compares, and the read key is already flat (its
`flatBytes()` is a slice return). So the read-side saving is tiny.
Against it, the prototype *adds* per-shape-mode-write cost: `shadowSet`
calls `internLookup` (a Wyhash) on every write to resolve the canonical
atom, plus a branch per node in `lookupAtom`, plus the code-size bloat
above. The arithmetic nets to ~zero — and the megamorphic-miss cluster
the profile flagged (§1) is dominated by the **O(depth) walk length and
the bag `Wyhash` in `hasAccessor`/`ownDataContains`**, neither of which
interning touches (§2 "what it does NOT"). Interning makes each *node's*
compare O(1); it does not shorten the walk or remove the bag probes.

**Verdict: do not re-attempt as specified.** This joins the poly-IC
dead-end and the `flatBytes`-inline change as a measured layout-noise
result. The Phase-1 prototype was reverted (kept only here as the
record). Anything that revisits property-lookup perf should target the
parts interning provably *can't*: a **per-shape hash index** to kill the
O(depth) walk itself (the original §9 Phase 2, but it must be justified
on the walk-length cost, standalone — not as a follow-on to interning),
or making `hasAccessor`/`ownDataContains` shape-first to drop the
bag `Wyhash` on the miss path. A bare atom-identity compare is not it.
