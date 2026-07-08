# Realm snapshots — design

Status: design; phase 1 landing in `src/runtime/snapshot.zig`
(format + build gate + capture/restore of a fresh installed realm).
Last updated 2026-07-08.
Scope: serialize a fully-initialized hardened realm (post-`Realm.init` +
`Realm.installBuiltins`) to a binary image; reload it for near-instant
startup, V8-snapshot style. Long-term: one snapshot backing N tenant
realms copy-on-write. Phase 1: dump one realm, reload it, prove the
reloaded realm behaves identically.

All `file:line` references verified against the working tree on
2026-07-08. Anything not directly verified is flagged inline with
**[unverified]**.

---

## 1. Motivation

Cynic's realm init walks the whole intrinsics install
(`src/runtime/intrinsics.zig:303` `install(realm)` — Error family,
stub + real constructors, ~40 builtin modules, the `%ThrowTypeError%`
wiring, the final `functions_young`/`functions_mature` proto backfill
at `intrinsics.zig:664-671`) and, on the hardened default, the
`freezePrimordials` pass (`intrinsics.zig:736`) — a full `hardenWalk`
over globalThis + every intrinsic, followed by the Phase-3
override-mistake fix that allocates a synthetic getter/setter
`JSFunction` **pair per data property per prototype**
(`installSyntheticAccessorPair`, `intrinsics.zig:841`). That is
thousands of heap allocations and hashmap inserts before the first
user opcode runs. Embedders that spin up a realm per request (edge
workers, per-tenant sandboxes — exactly the deployment Cynic's SES
posture targets) pay it every time.

Cynic is unusually well-positioned for snapshots:

- **Non-moving GC** (Metla, `docs/handbook/gc.md`) — object addresses
  are stable, so a serialized graph doesn't fight a compactor.
- **Frozen-by-default primordials** — after `freezePrimordials`, the
  intrinsic graph is *semantically immutable* (`[[Extensible]] =
  false`, every descriptor locked). Immutable state is trivially
  shareable, which is what makes the long-term COW vision (§10)
  plausible.
- **No bytecode in the snapshot set.** Verified: every builtin
  installed by `intrinsics.install` is a native function
  (`allocateFunctionNative` / `makeNativeFunction` — 47 direct call
  sites under `src/runtime/builtins/`, zero chunk-backed
  `allocateFunction` calls at install time). A fresh realm has
  `script_chunks`, `eval_sources`, `modules`, `microtask_queue`,
  `frame_stacks` all empty, `heap.const_roots` empty (populated only
  by `Heap.pinChunk`, `heap.zig:2248`, which runs at script compile).
  Phase 1 therefore needs **no bytecode serialization at all**.

## Baseline: realm init cost

Measured 2026-07-08 at `fbfbf2f`, ReleaseFast, `-Dintl=off`,
x86-64 Linux VM (4-core Xeon @ 2.80 GHz). Methodology: a temporary
in-process harness around `Realm.init` → `installBuiltins` →
`Realm.deinit` (10 warmup + 200 measured iterations per posture,
`CLOCK_MONOTONIC` phase stamps; medians reproduced within ~3 %
across two runs). Caveat: the container could not fetch the pinned
Zig 0.17-dev toolchain (proxy), so the numbers were taken with a
**Zig 0.16.0 stand-in** plus six local API-compat shims — no
engine-logic changes; ReleaseFast codegen deltas between the two
compilers should not move ms-scale medians materially, but a
re-measure on the pinned toolchain would remove the residual doubt.

| Hardened (default posture) | min | median | mean | max |
|---|---|---|---|---|
| `Realm.init` | 7.0 µs | 9.2 µs | 9.9 µs | 38.8 µs |
| `installBuiltins` (incl. freeze pass) | 1.219 ms | 1.290 ms | 1.307 ms | 1.718 ms |
| **`Realm.init` + `installBuiltins`** | **1.232 ms** | **1.300 ms** | **1.317 ms** | 1.728 ms |
| `Realm.deinit` | 230 µs | 253 µs | 264 µs | 382 µs |

| `--unhardened` (freeze pass skipped) | min | median | mean | max |
|---|---|---|---|---|
| `Realm.init` + `installBuiltins` | 406 µs | 436 µs | 440 µs | 539 µs |
| `Realm.deinit` | 84 µs | 100 µs | 106 µs | 192 µs |

Breakdown of the hardened median (~1.30 ms): `Realm.init` itself is
noise (~9 µs); builtin install proper is ~0.43 ms (= the unhardened
figure); the SES freeze pass (`freezePrimordials` — deep
`hardenWalk` + the override-mistake synthetic-accessor conversion)
is **~0.86 ms, about two thirds of the total**. Heap-charged
allocation (`heap.bytes_alloc_total` after install): 86,962 bytes
hardened vs 50,140 unhardened — the +36.8 KB delta is the
synthetic-accessor machinery.

Process-level context: `cynic eval '1'` (ReleaseFast, batch of 100)
is 5.18 ms/run hardened, 3.28 ms `--unhardened`, against a
1.54 ms/run bare fork+exec floor in the same container — so realm
setup + teardown (~1.30 + 0.25 ms) is roughly **40-45 % of the
cynic-specific startup**, and the dominant per-realm cost for an
embedder creating many realms. A restore that eliminates
init+install would cut ~1.3 ms/realm (median), dominated by the
freeze pass. This is the go/no-go input for the phase-2 perf work
(§9); phase 1 (correctness round-trip) proceeds regardless.

---

## 2. Prior art survey

### V8 — startup snapshots, custom snapshots, read-only heap

V8 boots by **deserializing a prepared snapshot blob directly into
the heap** instead of running the JS/native setup that builds the
builtins. Embedders can extend this: `v8::SnapshotCreator` captures
additional contexts ("custom startup snapshots") so app-level warmup
code is also pre-baked. Two mechanisms are directly relevant:

- **External references table.** Pointers that leave the V8 heap
  (C++ function addresses for builtins/callbacks, embedder fields)
  cannot be serialized raw. V8 serializes them as **indexes into an
  `external_references` array** the embedder supplies at both
  snapshot and load time; the deserializer maps index → live address
  (`kApiReference` case in the deserializer). Internal fields get the
  `SerializeInternalFieldsCallback` / `DeserializeInternalFieldsCallback`
  pair.
- **Read-only heap sharing.** Immutable objects live in a read-only
  space shared across isolates — the model for our COW ambition.
- The snapshot captures *only the V8 heap*: "any interaction from V8
  with the outside is off-limits when creating the snapshot" — i.e. a
  quiescent-state requirement, which we adopt (§6.1).
- Reproducibility is hard-won: Node's built-in snapshot work
  documents long fights with nondeterministic heap state (Joyee
  Cheung's series).

Sources:
- https://v8.dev/blog/custom-startup-snapshots
- https://v8.github.io/api/head/classv8_1_1SnapshotCreator.html
- https://github.com/nodejs/node/blob/main/deps/v8/src/snapshot/deserializer.cc
- https://hashseed.blogspot.com/2015/03/improving-v8s-performance-using.html
- https://joyeecheung.github.io/blog/2024/09/28/reproducible-nodejs-builtin-snapshots-3/
- https://github.com/danbev/learning-v8/blob/master/notes/snapshots.md
- https://nodejs.org/api/v8.html (`v8.startupSnapshot` embedder API)
- https://github.com/nodejs/node/issues/9473 (dynamic custom snapshots discussion)

### JavaScriptCore — no classic snapshot

JSC ships **no heap-image snapshot**. It attacks startup differently:
lazy initialization of builtins/prototypes (many intrinsics are
created on first touch), builtins written in JS compiled lazily, and
fast interpreter-first tiering (LLInt) so nothing is JIT-compiled at
boot. Lesson for Cynic: *lazy install* is the main competing design
(§11 alternative A) — it avoids the whole serialization problem but
is invasive for a hardened engine, because `freezePrimordials` wants
the full graph to exist eagerly (you cannot freeze what you haven't
built, and deferring the freeze reopens the SES window).
**[unverified — from general knowledge; JSC has no snapshot doc to
cite. Do not treat specifics as load-bearing.]**

### Hermes — AOT bytecode, mmap-able images

Hermes moves work out of startup by compiling JS to bytecode at
*build* time; the `.hbc` file is designed to be **mmap'd and
interpreted without eager reading** (random access, page-in on
demand), with the string table and function headers laid out for
that. Early Hermes also shipped a serialized-heap experiment
("deserialization" of a pre-initialized runtime) **[unverified —
the public Design.md documents the bytecode path; the heap-image
path was in older releases]**. Lessons: (a) design the binary format
for mmap + lazy page-in (section alignment, offset-based access);
(b) whole-image validation up front, per-object work deferred.

Sources:
- https://github.com/facebook/hermes/blob/main/doc/Design.md
- https://engineering.fb.com/2019/07/12/android/hermes/

### QuickJS — bytecode only, deliberately no heap snapshot

`qjsc` compiles JS to bytecode embedded in C arrays;
`js_std_eval_binary()` skips the parser at runtime. There is **no
heap snapshot**: QuickJS runtime init is already cheap (~hundreds of
µs) because the engine is small, and its object model (reference
counting, C-heap allocations, opaque host pointers everywhere) makes
a faithful heap dump disproportionately hard — the same
pointer-classification problem we analyze in §5. Lesson: a snapshot
only pays if init cost is material — hence the Baseline section
above gates phase 2.

Sources:
- https://bellard.org/quickjs/quickjs.html
- https://github.com/quickjs-ng/quickjs/blob/master/qjsc.c
- https://quickjs-ng.github.io/quickjs/cli/

### Academic literature

Not surveyed in depth for this draft (time-boxed). The relevant
lineage is image-based systems (Smalltalk/Self images; Lisp
`save-lisp-and-die` / undump), and KASLR-era position-independent
heap images. A follow-up can use the `arxiv` MCP server per
`docs/handbook/prior-art.md` §3 if a phase-2 decision needs it.

---

## 3. What exactly is in a fresh hardened realm (verified inventory)

The snapshot must capture the transitive closure of the realm's GC
roots plus the non-GC side tables. Root walk verified against
`Realm.markRoots` (`src/runtime/realm.zig:1857-1973`) and heap-side
state in `src/runtime/heap.zig`.

### 3.1 GC heap objects (the per-kind pools)

Seven kinds, each in `_young`/`_mature` `ArrayListUnmanaged(*T)`
pairs on `Heap` (`heap.zig:386-449`):

| kind | struct | allocation | phase-1 population at capture |
|---|---|---|---|
| strings | `JSString` (`string.zig:84`) | header from `string_pool` slab, bytes from `bytes_allocator` | function-name strings (`installFunctionLengthAndName`, `heap.zig:1344`), `@@toStringTag` values, misc literals |
| functions | `JSFunction` (`function.zig:95`) | `allocator.create` | every builtin (all `native_callback`-backed, `chunk == null`), synthetic accessor getter/setter pairs |
| objects | `JSObject` (`object.zig:821`) | `object_pool` slab | globalThis, every prototype, namespace objects (`Math`, `JSON`, `Reflect`, `Temporal`, `Intl`), function `.prototype` objects |
| symbols | `JSSymbol` (`symbol.zig:20`) | `allocator.create` | the well-known set (`allocateWellKnownSymbol`, `heap.zig:1138`; installed by `builtins/symbol.zig:67` `installWellKnownSymbol`) |
| bigints | `JSBigInt` | `allocator.create` | expected zero at init **[unverified — assert at capture]** |
| environments | `Environment` (`environment.zig:25`) | `env_pool` slab + GPA slots | zero at init (no script has run) — assert |
| generators | `JSGenerator` | `allocator.create` | zero at init — assert |

Everything in the lists after a pre-capture full GC (§6.1) is live
(rooted from globalThis / intrinsics / name-string edges), so
**capture = serialize the lists wholesale**, no per-object
reachability trace needed.

### 3.2 The realm's roots and side tables (`Realm`, realm.zig:712)

Fields that carry heap references or must survive the round trip:

- `globals: GlobalBindings` (`realm.zig:287`) — `target` (the
  globalThis `*JSObject`; after `bindToObject` at
  `intrinsics.zig:325` the fallback map is empty), `decl_env` /
  `decl_consts` / `var_names` (all empty at init — assert),
  `decl_revision`, `heap` back-pointer.
- `intrinsics: Intrinsics` (`intrinsics.zig:47`) — a flat struct of
  ~150 `?*JSObject` / `?*JSFunction` fields **plus one `Value` field**
  (`array_iterator_next`, `intrinsics.zig:277`). Serialize by
  comptime field reflection, exactly the pattern `markRoots` uses at
  `realm.zig:1881-1889` — note markRoots skips the `Value`-typed
  field; the snapshot must handle all three field types.
- `synth_accessor_cells: ArrayListUnmanaged(*SyntheticAccessor)`
  (`realm.zig:1192`) — realm-allocator cells; each frozen prototype
  data property produced two (`intrinsics.zig:852-857`). Each
  `JSFunction.synth_accessor` (`function.zig:344`) borrows one.
  `SyntheticAccessor.key` (`function.zig:81-93`) borrows a
  heap-anchored key slice — relocation needed (§5.3).
- Posture flags to stamp into the header: `hardened`, `allow_eval`,
  `allow_wasm`, `agent_can_block`, `jit_enabled`, `feature_flags`
  (`FeatureSet`), plus the comptime intl flavour
  (`src/runtime/intl_config.zig`).
- Everything else on `Realm` is transient runtime state that must be
  **empty at capture and default-initialized at restore**:
  `microtask_queue`, `frame_stacks`, `kept_alive`,
  `pending_async_waits`, `modules`, `script_chunks`, `eval_sources`,
  `child_realms`, `derived_ctor_cells`, `wasm_*`, `frame_pool`,
  `value_stack` (re-alloc fresh, `realm.zig:1203`), `output`,
  `json_scratch_*`, `pending_exception`, counters
  (`proto_revision_counter` — restore to serialized value or reset
  to 1; either is safe since no IC cells exist yet).

### 3.3 Heap-side non-GC state (`Heap`, heap.zig:330)

- `shapes: ShapeTree` (`heap.zig:368`, `shape.zig:93`) — the
  agent-wide property-shape transition tree, arena-allocated, never
  GC-traced. **Must be serialized**: the global object is
  shape-resident (promoted at `intrinsics.zig:695-697`, then frozen
  in-shape via `freezeOwnDataInShape`, `realm.zig:2098` /
  `object.zig:2908`), and `JSObject.shape` pointers
  (`object.zig:846`) point into this arena. See §5.4.
- `function_prototype: ?*JSObject` (`heap.zig:403`) — borrowed
  pointer; re-wire at restore.
- `symbol_registry` (`heap.zig:453`) — `Symbol.for` registry; empty
  at init (assert), but serialize the mechanism anyway (cheap) so a
  future "warmup snapshot" (post-user-code) doesn't need a format
  bump.
- `next_symbol_id`, `class_brand_counter` — monotonic counters; must
  round-trip (symbol prop-keys `<sym:N>` must not collide after
  restore).
- `small_int_strings: [256]?*JSString` (`heap.zig:890`) — lazily
  populated pinned strings; expected all-null at init
  **[unverified]** — serialize as refs regardless.
- `const_roots`, `native_ctor_roots`, `handle_scopes`, `dirty_list`,
  `young_ptr_set`, weak worklists, `jit_code` — all empty/null at
  capture (assert), default at restore.
- GC tuning fields (`gc_threshold` etc.) — restore defaults; do not
  snapshot.
- `realms: ArrayListUnmanaged(*Realm)` — restore registers the new
  realm (`registerWithHeap`, `realm.zig:1775`).

### 3.4 Where native function pointers live (the external-reference problem)

Verified inventory of raw code/data pointers into the executable
image that the object graph holds:

1. **`JSFunction.native_callback: ?NativeFn`** (`function.zig:109`) —
   every builtin. The single biggest class.
2. **`Heap.finalization_enqueue_fn`** (`heap.zig:823`) — one function
   pointer, installed by `installBuiltins`
   (`realm.zig:1987`); re-installed at restore, not serialized.
3. **`Realm.module_loader`** (`realm.zig:910`) — host-installed after
   restore; not serialized.
4. **Rodata string slices used as borrowed hashmap keys and name
   slices.** Builtin installers pass comptime string literals
   directly into property maps — e.g.
   `f.properties.put(self.allocator, "length", …)`
   (`heap.zig:1356`), `setNonEnumerable(proto, alloc, "constructor",
   …)` (`intrinsics.zig:1013`), `JSFunction.name` for natives
   (`initNative` stores the passed literal, `function.zig:474-491`).
   These `[]const u8` slices point into the binary's rodata — same
   image-relative-stability class as function pointers, handled
   differently (§5.3: we *copy content* instead of externalizing).

There are **no vtables** in the graph (Zig, no dynamic dispatch); the
only comptime-known code pointers are `NativeFn`s and the two host
hooks above.

### 3.5 Pointer-bearing fields per struct (relocation surface)

- `JSString` (`string.zig:84`): `payload.flat: []const u8` (bytes
  allocator) or `payload.cons{left,right,heap}`. **Flatten every
  rope at capture** (post-install ropes are unlikely but possible via
  bound-name machinery); then only `flat` remains + the `heap`
  back-pointer disappears. `pinned`, `length_cu`, `byte_len` copied.
- `JSObject` (`object.zig:821`): `properties` /
  `property_flags` (StringArrayHashMaps — key slices + Values),
  `shape: ?*Shape`, `inline_slots[4]` + `overflow_slots` +
  `slot_count` (`object.zig:819` `inline_slot_cap = 4`;
  `object.zig:862-864`), `heap` back-pointer (restamp), `prototype` /
  `prototype_fn`, `elements` / `sparse_elements` (+
  `elements_pooled`, `object.zig:1230` — pooled buffers must be
  re-drawn from the pool or unpooled at restore), `key_anchors`
  (`object.zig:1241`), `own_key_order` (`object.zig:1262` — borrowed
  key slices, order is §10.1.11-observable), `extension:
  ?*JSObjectExtension` (`object.zig:517` — at init the populated
  fields are essentially `accessors` on prototypes from the
  override-mistake fix; ~40 other cold fields must be
  asserted-default at capture, §6.1), brand flags
  (`extensible`, `is_array_exotic`, `proxy_callable` — set on
  `%Function.prototype%` at `intrinsics.zig:374` — etc.), GC header
  (`mark_color`, `generation`, `dirty`, `needs_internal_scan`,
  `is_pristine`).
- `JSFunction` (`function.zig:95`): `chunk` (assert null),
  `native_callback` (external ref), `name: ?[]const u8` +
  `name_string: ?*JSString`, `source` (assert null for natives),
  `captured_env` (assert null), `owning_module` (assert null),
  `realm: ?*Realm` (restamp to restored realm — single-realm phase
  1), `captured_this`/`captured_new_target` (Values —
  undefined at init), `home_object`/`home_function`,
  `super_called_cell` (assert null), `bound_*` (assert
  null/undefined), `wasm_export` (assert null), `wrapped_target`
  (assert undefined), `static_parent`, `revocable_proxy` (assert
  null), `synth_accessor: ?*SyntheticAccessor` (cell-table ref, §5.3),
  `properties`/`property_flags`/`accessors`/`private_*` maps,
  `own_key_order`, `key_anchors`, `prototype`/`proto`, flags
  (`has_construct`, `is_class_constructor`, `defers_proto_lookup`,
  `native_ordinary_function`, `is_generator`, `is_async`,
  `extensible`, `constructor_kind`), `heap` (restamp).
- `JSSymbol` (`symbol.zig:20`): `description: ?[]const u8` (owned
  dupe), `prop_key: []const u8` (owned dupe — `@@iterator` /
  `<sym:N>`), `is_registered`, `pinned`.
- `SyntheticAccessor` (`function.zig:81`): `value: Value`, `key:
  []const u8` (borrowed), `is_setter`.

### 3.6 Why pool pages cannot be dumped wholesale

Tempting: `object_pool` / `string_pool` / `env_pool` are slab pools
(`QuarantinedPool` over `std.heap.MemoryPool`, `heap.zig:251`), so
"dump the slabs, fix up pointers" looks V8-ish. It does not work
here:

1. The headers embed `std.StringArrayHashMapUnmanaged` /
   `ArrayListUnmanaged` whose backing arrays are separate GPA
   allocations at arbitrary addresses — the "page image" is not
   self-contained.
2. Zig hashmap internals (index buffer layout, tombstones, hash
   function) are a std-lib implementation detail — snapshotting them
   bit-for-bit couples the format to the exact Zig std version far
   more tightly than a logical re-insert does. (The zon-pinned
   Zig-dev toolchain bumps regularly per AGENTS.md.)
3. `MemoryPool` slab addresses are not reproducible across runs, so
   a raw dump needs full pointer relocation anyway — at which point
   per-object logical encoding costs the same and is robust.

**Decision: object-by-object logical serialization; hashmaps rebuilt
by insertion at restore** (insertion order preserved — this is
load-bearing: `StringArrayHashMap` iteration order == insertion order
== the §10.1.11 own-key order the engine exposes). Wholesale-image
mapping returns as the *phase-3 COW substrate* (§10), which is where
it actually pays.

---

## 4. Snapshot binary format (proposal)

Container style follows the existing `CYTZ` / `CYCL` precedent
(AGENTS.md, tzdata/CLDR packs): magic + version + sections.

```
Offset  Size  Field
0       4     magic            "CYSN"
4       4     format_version   u32 (bump on any layout change)
8       32    build_id         hash identifying the exact engine build (§5.2)
40      8     flags            bitfield: hardened, allow_eval, allow_wasm,
                               agent_can_block, jit_enabled, intl flavour (2 bits),
                               reserved
48      8     feature_flags    serialized FeatureSet bits (features.zig)
56      8     section_count    u32 + reserved
64      ...   section table    (tag: u32, offset: u64, len: u64) entries
```

- **Endianness: little-endian only, no byte-swapping.** Cynic is
  64-bit LE targets only (NaN-boxing doc, `value.zig:15`; every
  supported host — x86-64, aarch64 — is LE). Assert
  `builtin.cpu.arch.endian() == .little` at comptime in
  `snapshot.zig`.
- **Alignment:** every section 8-byte aligned (future mmap
  friendliness, Hermes lesson); within sections, fixed-width
  little-endian scalars, `u32` counts, `u64` offsets.
- **Sections** (tags are ASCII u32):

| tag | content |
|---|---|
| `KEYS` | interned key/byte arena: one blob + (offset,len) entries. Every borrowed `[]const u8` in the graph (map keys, `own_key_order` entries, symbol prop_keys/descriptions, `SyntheticAccessor.key`, function `name` slices) is content-interned here (§5.3). |
| `STRS` | JSString table: per-entry `{pinned:u8, length_cu:u32, byte_len:u32, bytes_ref}` — bytes may share the KEYS blob (dedup) or a separate blob; ropes flattened at capture. |
| `SYMS` | JSSymbol table: `{desc_ref?, prop_key_ref, is_registered, pinned}`. |
| `BIGS` | JSBigInt table (expected empty; format reserved). |
| `SHAP` | shape tree: node array `{parent_idx:u32, key_ref, attrs:u8, kind:u8, slot:u32, property_count:u32}` in parent-before-child order; transition edge lists rebuilt at load by registering each node with its parent (append edge when `property_count == parent+1`, redefine edge when `==`, matching `ShapeTree.transition` / `redefineTransition`, `shape.zig:121/170`). Node 0 is the root. |
| `CELL` | SyntheticAccessor cell table: `{value:Value64, key_ref, is_setter:u8}`. |
| `OBJS` | JSObject records (variable length, per-field tagged — §4.2). |
| `FNCS` | JSFunction records (variable length). |
| `EXTR` | external-reference table: `{stable_id}` entries; every serialized `native_callback` is an index here (§5.2). |
| `RELM` | realm tables: globalThis ref, the `Intrinsics` struct as a field-name-hashed list of refs, `next_symbol_id`, `class_brand_counter`, `symbol_registry` entries, `small_int_strings` refs, `decl_env`/`decl_consts`/`var_names` entries (empty in phase 1 but encoded). |
| `CHCK` | integrity: counts per kind + a content hash of all prior sections. |

### 4.1 On-disk Value encoding (NaN-box rewrite)

A live `Value` (`value.zig:24`) is 64 bits: top-16 tag; heap tags are
`0xFFF9` (object-family pointer, low 2 bits of the 48-bit payload are
the kind: `kind_function=0, kind_object=1, kind_symbol=2,
kind_bigint=3` — `heap.zig:85-89`) and `0xFFFA` (string pointer).
All other tags (double / int32 / bool / null / undefined / hole) are
**pure bits — copied verbatim**.

Encode: if `v.isHeapValue()` (`value.zig:157`), rewrite the 48-bit
payload to a table reference; else copy `v.bits`.

```
on-disk heap ref payload (48 bits):
  bits 45..47  pool kind: 0=function, 1=object, 2=symbol, 3=bigint,
               4=string (tag 0xFFFA also implies string; keep kind
               redundant for validation)
  bits 0..44   index into that kind's table
```

Decode: look up the restored pointer for `(kind, index)`, re-tag via
`taggedFunction/taggedObject/taggedSymbol/taggedBigInt`
(`heap.zig:131-152`) or `Value.fromString`. 45 bits of index is
absurdly ample. Doubles round-trip bit-exactly (the offset encoding
is already applied in `bits`; we never re-encode).

### 4.2 Object/function record encoding

Variable-length records, **field-tagged** (tag:u8, payload) rather
than fixed layout — a fresh realm's objects are mostly defaults, so
tagged encoding is compact and, critically, lets the decoder reject
an unknown tag (forward-compat within a format version). Every
default-valued field is simply absent. Maps serialize as
`(count, [key_ref, payload]…)` in **iteration order** (== insertion
order — order is user-observable through `Object.getOwnPropertyNames`).

`own_key_order` serializes as a list of key_refs. `key_anchors` is
**not serialized**: after restore, every map key points into the
snapshot's KEYS arena, which is realm-lifetime — there is no
GC-swept backing string to anchor (§5.3). This deliberately
simplifies the GC contract for restored objects.

---

## 5. The four hard sub-problems

### 5.1 Pointer relocation (heap → index → heap)

Two-pass restore, mirroring V8's deserializer shape:

- **Pass 1 — allocate.** For each kind table, allocate all headers
  through the normal pools (`object_pool.create`,
  `string_pool.create`, `allocator.create(JSFunction)`, …) into a
  `[]*T` index→pointer table. No fields yet. This keeps every object
  inside the ordinary pool/sweep machinery — restored realms GC
  normally with zero special cases (phase-1 priority; the immortal
  generation comes later, §10).
- **Pass 2 — fill.** Decode records; every heap ref resolves through
  the tables; hashmaps rebuilt by insertion (with
  `ensureTotalCapacity` up front from the serialized counts);
  `heap`/`realm` back-pointers restamped.
- **Generation policy:** restore everything as `generation =
  .mature`, `dirty = false`, `mark_color = 0` with `live_color = 0`,
  and append to the `_mature` lists. Rationale: these objects
  already "survived install"; putting ~10⁴ objects in `_young`
  would make the first minor cycle scan and promote all of them for
  nothing. Mature placement is safe: post-restore stores of young
  values into these objects hit the existing write barrier
  (`Heap.writeBarrier` via the stamped `heap` back-pointer), exactly
  as for any promoted object. `needs_internal_scan` / `is_pristine`
  round-trip as serialized.
- Strings restored with their `pinned` flag intact (function-name
  strings are not pinned; well-known-symbol machinery strings vary —
  copy what capture saw).

### 5.2 External references (native code pointers)

Problem: `native_callback` values are code addresses; PIE + ASLR
means they differ every run even for the same binary.

**Phase-1 mechanism: anchor-relative offsets + build-id gate.**

- Choose one anchor symbol in the image, e.g.
  `const anchor = &Realm.installBuiltins;` (any always-linked
  function). Serialize each distinct `NativeFn` as
  `offset = @intFromPtr(cb) -% @intFromPtr(anchor)` (i64). Within a
  single build of a statically-linked Zig binary, function addresses
  are fixed relative to the image base at link time; ASLR slides the
  whole image, so anchor-relative offsets are stable across runs of
  the *same binary*.
- The `EXTR` section stores the distinct offsets once;
  `native_callback` fields store `EXTR` indices.
- **Fail-closed gate:** the header `build_id` must match the running
  engine or `restore` returns `error.SnapshotBuildMismatch` — a
  stale offset is arbitrary-code-execution-grade UB, so there is no
  "best effort" mode. `build_id` source: inject at build time via a
  `build.zig` option (git SHA + zig version + build mode + intl
  flavour hashed together); a comptime-derived hash of
  `builtin.zig_version_string` + a build-option string is the
  minimal viable version. **[decision for implementer: build.zig
  plumbing not yet designed — flagging]**
- **Phase-2 upgrade path (V8-parity):** a named registry —
  `allocateFunctionNative` (`heap.zig:1310`) additionally records
  `(name, callback)` into a heap-side registry at *install* time, and
  a generated table maps stable string IDs → callbacks so snapshots
  survive relinking as long as the builtin set matches. Not needed
  while the build-id gate exists; becomes needed if snapshots are
  ever distributed separately from the binary. The
  anchor-relative scheme keeps the format field identical (the EXTR
  entry gains a name), so this is additive.

The two non-serialized host hooks (`finalization_enqueue_fn`,
`module_loader`) are re-installed by `restore` / the embedder,
mirroring `installBuiltins` (`realm.zig:1987`).

### 5.3 Borrowed byte slices (rodata keys, key anchors, symbol keys)

Live property-map keys come from three provenances (verified §3.4):
comptime rodata literals; heap `JSString` bytes anchored via
`key_anchors`; allocator dupes (symbol `prop_key`, shape-arena key
dupes). Classifying provenance at capture (image-range checks against
/proc/self/maps etc.) is fragile.

**Decision: erase provenance — serialize every key by content into
the `KEYS` arena (content-deduped), and at restore point every map
key / `own_key_order` entry / `SyntheticAccessor.key` /
`JSFunction.name` / `JSSymbol.prop_key` into the snapshot-owned
arena** (one allocation, realm-lifetime, freed at realm teardown —
needs a `snapshot_arena` field or ownership hook on `Realm`
**[implementer decision]**). Consequences:

- No image-range classification, no rodata addressing at all outside
  `EXTR`.
- `key_anchors` lists restore empty (no GC hazard: the arena is not
  GC-swept). The AGENTS.md "property map borrows the key slice"
  invariant is satisfied by arena lifetime instead of anchoring.
- Cost: tens of KB of duplicated literal bytes per snapshot — noise.
- `JSSymbol.deinit` frees `prop_key`/`description`
  (`symbol.zig:80-84`); restored symbols would double-free arena
  bytes at sweep. Restored symbols must own *allocator dupes* for
  these two fields specifically (they are the only per-object-freed
  slices in the graph — `JSString.payload.flat` is likewise
  per-object-freed and therefore also restored as a
  `bytes_allocator` dupe, not an arena view, preserving
  `deinit`'s contract, `string.zig:194-208`). Rule of thumb the
  implementer must follow: **a slice freed by a `deinit` path is
  restored as an owned dupe; a slice only ever borrowed is restored
  as an arena view.**

### 5.4 Shapes and property storage

- The shape tree is serialized structurally (§4 `SHAP`) and rebuilt
  into a fresh `ShapeTree` arena; `JSObject.shape` fields are node
  indices. Shared-shape identity is preserved by construction (two
  objects referencing node 17 get the same restored `*Shape`).
- Redefinition nodes (SES freeze via `redefineTransition`,
  `shape.zig:170` — same slot, same property_count, new attrs) are
  distinguishable from append nodes by `property_count`; the loader
  registers each child in its parent's `transitions` list so
  post-restore transitions dedupe against the snapshot's tree
  exactly as against the original.
- Shape-mode objects: `slot_count` + the first 4 values from
  `inline_slots` + `overflow_slots` serialize as one logical slot
  vector (encoder reads through `slotAt`, decoder writes through
  `setSlot`/`resizeSlots` equivalents, keeping the inline/overflow
  split an implementation detail per `object.zig:857-859`).
- Dictionary-mode objects: `properties` + `property_flags` maps
  serialize directly. The Phase-3 lazy-bag invariant
  (`docs/lazy-property-bag.md`: "either the shape OR the bag is
  authoritative for a given key, never both with diverging values")
  is preserved verbatim because we serialize both sides as-is.
- ICs: none exist at capture (ICs live in chunk bytecode cells and
  the realm has no chunks). Nothing to drop. The
  `proto_struct_epoch` / `proto_revision_counter` counters restore
  to their serialized values (or 1 — no cells reference them yet).
- Symbol-keyed properties are ordinary string-keyed entries under
  the `@@`-prefixed / `<sym:N>` prop-key convention
  (`symbol.zig:44`), so they need no special casing beyond
  `next_symbol_id` round-tripping.

---

## 6. Phase-1 implementation plan

### 6.1 Capture envelope (fail-closed quiescence check)

`Snapshot.capture` first **validates** the realm is in the supported
envelope and errors otherwise (`error.RealmNotQuiescent` /
`error.Unsnapshotable`):

- `microtask_queue`, `frame_stacks`, `handle_scopes`,
  `native_ctor_roots`, `kept_alive`, `pending_async_waits`,
  `modules`, `script_chunks`, `eval_sources`, `child_realms`,
  `const_roots`, `dirty_list` all empty; `pending_exception == null`;
  `heap.realms.items.len == 1`; `wasm_arena == null`;
  `jit_code == null`.
- Per-object: `chunk == null` on every function; no generators, no
  environments; every `JSObjectExtension` field outside the
  supported set (`accessors`, `private_*`? — expected: only
  `accessors`) at its default, enforced by a comptime-exhaustive
  field switch so a new extension field breaks compilation here, not
  silently at runtime (mitigation for risk R2).
- Then run `realm.collectGarbage()` (`realm.zig:1692`) so the pools
  contain only live objects, then serialize the lists wholesale.

V8 has the same rule ("interaction with the outside is off-limits
during snapshot creation"); we make it a checked error instead of a
convention.

### 6.2 File layout & API

New file: `src/runtime/snapshot.zig` (runtime/, not builtins/ — it is
engine machinery, never JS-visible; per the repository-map rule of
thumb). Suggested surface:

```zig
pub const Snapshot = struct {
    pub const CaptureError = error{ OutOfMemory, RealmNotQuiescent, SnapshotUnsupported };
    pub const RestoreError = error{ OutOfMemory, SnapshotCorrupt,
        SnapshotVersionMismatch, SnapshotBuildMismatch };

    /// Serialize a quiescent, fully-installed realm. Caller owns the bytes.
    pub fn capture(realm: *Realm, allocator: std.mem.Allocator) CaptureError![]u8;

    /// Rebuild a realm from a snapshot. Returns a heap-allocated Realm
    /// (stable address — required by registerWithHeap / finalization ctx,
    /// realm.zig:1775/1987). The returned realm is registered with its
    /// heap and has the host hooks re-installed; it is ready for
    /// evaluateScript. Caller tears down via realm.deinit() +
    /// allocator.destroy(realm).
    pub fn restore(allocator: std.mem.Allocator, bytes: []const u8) RestoreError!*Realm;

    /// restore() variant mirroring Realm.initWithBytesAllocator for the
    /// test262 harness split-allocator setup (realm.zig:1227).
    pub fn restoreWithBytesAllocator(
        allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        bytes: []const u8,
    ) RestoreError!*Realm;
};
```

Posture: the snapshot header's flags are authoritative — `restore`
stamps `hardened` / `allow_eval` / `feature_flags` from the header
unconditionally (a hardened snapshot cannot be reopened unhardened;
the freeze is baked into the object graph). There is no
posture-override parameter, so no `SnapshotPostureMismatch` error
exists in the landed surface; an embedder that wants a different
posture builds the realm the ordinary way.

CLI integration (`cynic run --snapshot=…`, a `zig build gen-snapshot`
step) is explicitly **after** the round-trip test lands; phase 1 is
library + tests only.

### 6.3 TDD sequence (per docs/handbook/tdd.md — tests first, in snapshot.zig)

1. **Header/gate tests:** truncated buffer → `SnapshotCorrupt`; wrong
   magic/version → `SnapshotVersionMismatch`; flipped build_id →
   `SnapshotBuildMismatch`. (Write these against a hand-built header
   before any encoder exists.)
2. **Value codec:** exhaustive round-trip of non-heap Values
   (mirroring the `value.zig` test list: NaN canonicalization, -0.0
   bit-exactness, hole, int32 extremes) + heap-ref pack/unpack.
3. **String table:** WTF-8 lone-surrogate bytes round-trip
   byte-exactly; `length_cu`/`byte_len` preserved; a hand-built cons
   is flattened by capture.
4. **Shape tree:** capture/restore a tree with an append chain + a
   redefine node; assert shared-shape identity (`a.shape ==
   b.shape` post-restore) and that `lookup` returns identical
   `(slot, attrs, kind)`.
5. **Quiescence gate:** a realm with a queued microtask (or an eval'd
   script chunk) → `RealmNotQuiescent`.
6. **Full round-trip (the headline test):**
   `Realm.init` + `installBuiltins` (+ `installTestGlobals` in a
   second variant) → capture → restore → assert per-kind heap counts
   equal (`stringCount()` etc., `heap.zig:2552-2570`), then run
   behavioral probes through `evaluateScript` on BOTH realms and
   compare output strings:
   - `Object.getOwnPropertyNames(globalThis).sort().join(",")`
   - prototype-chain identity: `Object.getPrototypeOf([]) === Array.prototype`
   - hardened invariants: `Object.isFrozen(Object.prototype)`,
     `(()=>{try{Array.prototype.push=1;return "threw-not"}catch(e){return e instanceof TypeError}})()`
   - override-mistake fix: `const o={}; o.toString=()=>"x"; String(o)`
     (must shadow, not throw)
   - well-known symbol identity: `[][Symbol.iterator] === Array.prototype.values`
   - a real workload: `[1,2,3].map(x=>x*2).join("-")`,
     `JSON.stringify({a:[1,{b:2}]})`, a Promise `.then` ordering probe
     through `__drainMicrotasks` (test-globals variant).
7. **GC safety:** restored realm survives `collectGarbage()` +
   allocation-pressure sweeps; extend the `/gc-stress` methodology —
   run a filtered fixture set on a restored realm at
   `--gc-threshold=1` (ReleaseSafe binary for the verifiers per
   AGENTS.md). This is the test that catches a missed back-pointer
   restamp or generation-policy mistake.
8. **Differential sweep (exit gate, post-implementation):** a test262
   harness mode that builds each fixture's realm via
   restore-from-snapshot instead of `installBuiltins` must produce
   the **exact pass-set** of a normal sweep — same shape as the
   `--jit` differential gate (`docs/jit.md` §10, AGENTS.md test262
   flags). This is the strongest "behaves identically" proof
   available and should gate the feature's default-on.

### 6.4 Suggested commit sequence

1. Format constants + header codec + gate tests (no engine coupling).
2. Value codec + KEYS/STRS/SYMS encoders (leaf tables).
3. SHAP codec.
4. OBJS/FNCS record codec + capture-time envelope validator
   (comptime-exhaustive field handling).
5. Two-pass restore + realm/heap re-wiring + full round-trip test.
6. GC-stress + differential harness mode.

### 6.5 Phase-1 implementation notes (as landed)

`src/runtime/snapshot.zig` implements the format above with these
concrete choices / deviations:

- **Key ownership**: instead of a dedicated arena allocator, the
  restored realm owns a single duplicated copy of the `KEYS` blob
  (`Realm.snapshot_key_bytes`, freed in `Realm.deinit`); every
  restored map key / `own_key_order` entry / `SyntheticAccessor.key`
  is a view into it. `JSSymbol.{description, prop_key}` and
  `JSString` byte payloads are allocator dupes because their
  `deinit` paths free them (§5.3's owned-vs-borrowed rule).
- **build_id**: a comptime hash of the Zig version string, build
  mode, ISA, and intl flavour, plus three anchor-relative code-layout
  probe offsets checked at restore — a practical same-binary gate.
  `build.zig` plumbing for a git-SHA build id is still open
  (§5.2 flag); until it lands, snapshots are strictly same-process /
  same-binary artifacts.
- **Realm fields are NOT comptime-exhaustive** (deviation from the
  R2 treatment of `JSObject` / `JSFunction` / `JSObjectExtension`,
  which ARE exhaustive): `Realm` grows transient host-state fields
  regularly (step budgets, metering, wasm state) that are correctly
  default-initialized by `Realm.init` at restore. Serializing the
  known-durable set (posture flags, feature set, counters,
  intrinsics, globals target, synthetic-accessor cells) and
  defaulting the rest keeps snapshot.zig out of the way of
  concurrent Realm work; the quiescence gate (§6.1) rejects a realm
  whose transient state is non-empty at capture.
- **Unsupported-at-capture object state** (Map/Set data, typed
  arrays, ArrayBuffers, proxies, promises with reactions, iterator
  states, wasm backings, Temporal/Intl records, module namespaces,
  bound functions, chunk-backed functions, environments, generators,
  bigints) returns `error.SnapshotUnsupported` — these do not occur
  in a fresh `-Dintl=off` realm; extending coverage is phase-2 work
  and each addition is caught by the comptime-exhaustive field walk.
- **Not yet landed** (phase-1 TODO):
  - `-Dintl=stub/full` capture audit (R6) — capture is exercised at
    `-Dintl=off` only.
  - The §6.3.8 differential test262 harness mode (restore-instead-of-
    install exact-pass-set gate) and the §6.3.7 `/gc-stress` sweep
    over a restored realm.
  - `restoreWithBytesAllocator` for the test262 harness split
    allocator.
  - CLI integration (`cynic run --snapshot=…`) and a `restore` bench
    (the §9 phase-2 go/no-go).

---

## 7. Explicitly OUT of scope for phase 1

- **Bytecode / chunks / eval sources / modules** — capture refuses
  realms that have run code. (Warmup snapshots à la V8 custom
  snapshots are a future phase; they need chunk + IC serialization.)
- **JIT code** (`heap.jit_code`, Bistromath state) — never
  serialized; tier-up warmth restarts from zero.
- **Wasm** (arena, instances, `WebAssembly.*` backings) — refused.
- **In-flight anything:** open generators, pending promises/
  microtasks, handle scopes, frames — refused (quiescence gate).
- **ICs** — vacuously excluded (no chunks ⇒ no cells).
- **Child realms / ShadowRealm graphs** — single realm per snapshot.
- **Cross-build / cross-version snapshots** — hard-gated by
  `build_id`; no compatibility promise, ever, for phase 1.
- **Big-endian / 32-bit hosts** — comptime-excluded like NaN-boxing
  itself.
- **Multi-realm COW sharing** — vision only (§10).
- **`installTestGlobals` extras** are IN scope only as a test
  variant (they're ordinary natives; nothing special).

---

## 8. Risks / unknowns

- **R1 — External-reference integrity.** An offset applied under the
  wrong binary is memory corruption. Mitigation: fail-closed
  build_id, CHCK section hash, and never loading snapshots from
  untrusted input (document: a snapshot is trusted code, exactly as
  V8 documents theirs).
- **R2 — Field drift.** `JSObject`/`JSFunction`/`JSObjectExtension`
  have ~100 fields and grow regularly. A field the serializer
  doesn't know about silently produces a wrong realm. Mitigation:
  comptime-exhaustive `inline for (@typeInfo(T).@"struct".fields)`
  with an explicit handled/asserted-default/refused classification
  per field name so **adding a field fails the build** until
  snapshot.zig is updated; plus the differential sweep (§6.3.8).
  This is the single biggest ongoing-maintenance risk.
- **R3 — Order fidelity.** Own-key order, shape transition identity,
  symbol table order (`symbolForKey` does list-order linear scans,
  `heap.zig:1123`) are all user-observable. Encode-in-iteration-order
  / rebuild-by-insertion should preserve everything, but a single
  swapRemove-style disturbance breaks `Object.keys` ordering on some
  fixture. Mitigation: the differential sweep, plus a targeted
  key-order probe test.
- **R4 — Restore may not beat install by enough.** Both are O(heap);
  restore's win is "no freeze walk, no synthetic-accessor allocation
  logic, no hashmap re-hash-and-probe churn during transition
  replay" — likely 2-5× rather than 50×, until the COW/mmap phase.
  The Baseline TODO (§1) plus a `restore` bench decides whether
  phase 2 (bulk-preallocated maps, arena-packed records, lazy
  section decode) is warranted before COW.
- **R5 — Split bytes_allocator ownership.** The test262 harness
  restores with a distinct `bytes_allocator`; every restored slice
  must go to the right allocator (`JSString` bytes →
  `bytes_allocator`; headers/maps → `allocator`; keys → snapshot
  arena) or teardown corrupts. Covered by the leak-check tests
  (`std.testing.allocator` catches mismatched frees).
- **R6 — `intl=full` blob interactions.** At `-Dintl=full` the
  install wires CLDR/tzdata-backed objects; whether any of them
  cache pointers into the embedded blobs (which are rodata — stable
  under the build gate, but a provenance the KEYS-copy rule doesn't
  cover for non-key slices) is **[unverified — implementer must
  audit `builtins/intl.zig` / `runtime/cldr.zig` before enabling
  capture at `full`]**. Phase 1 can ship gated to `-Dintl=off`.
- **R7 — Hidden nondeterminism.** Anything address-derived that
  leaks into serialized state breaks reproducibility (Node's
  snapshot lesson). Known instance: user-symbol keys `<sym:N>` are
  counter-based (fine); `wasm_foreign_exn_tag` is address-identity
  (not serialized; fresh per realm — fine). An audit pass for
  pointer-formatted strings at capture is cheap insurance.

---

## 9. Phase 2 sketch (perf, after correctness)

- Preallocate every hashmap/list from serialized counts
  (`ensureTotalCapacity`) — removes rehash churn.
- Lazy section decode: mmap the file, decode STRS/KEYS by reference
  (bytes served straight from the mapping — requires the mapping to
  outlive the realm; ties into the arena-ownership hook from §5.3).
- Named external-reference registry (§5.2 upgrade) if snapshots ever
  ship separately from the binary.
- `zig build gen-snapshot` + embed the default snapshot in the
  binary (V8 `snapshot_blob.bin` embedded mode) so `cynic eval`
  boots from it transparently.

## 10. Long-term vision: one snapshot, N tenant realms, COW

The end state AGENTS.md's SES posture makes uniquely cheap for Cynic:
the frozen intrinsic graph is immutable after init, so N tenant
realms can *share* one physical copy.

Sketch (deliberately non-binding):

1. **Immortal generation.** Add a third `Generation` variant
   (`heap.zig:113` — `enum(u2)`, room exists) for snapshot-restored
   primordials: never swept, never promoted, and — critically —
   **never written by the collector** (marking must skip immortal
   objects entirely rather than stamp `mark_color`, or every major
   cycle dirties every shared page). This is V8's read-only space in
   Metla terms.
2. **Relocatable image.** Decode once into a contiguous arena with
   an (offset-table) relocation pass; tenants map it MAP_PRIVATE.
   Mutable-at-runtime words (GC header bits, any lazily-filled
   cache like `small_int_strings`) must be segregated onto private
   pages or out-of-line side tables, or they defeat the sharing.
3. **Per-tenant mutable skin:** each tenant realm owns its
   globalThis *bindings that differ*, its `GlobalBindings.decl_env`,
   microtask queue, pools — everything in §3.2's "transient" list —
   plus a fresh `Heap` whose pools allocate tenant-private objects
   that may point INTO the shared image (never the reverse:
   the frozen image cannot acquire pointers to tenant objects, which
   is exactly what `[[Extensible]] = false` + locked descriptors
   guarantee for user JS; engine-internal lazily-installed
   intrinsics — `generator_prototype` et al., `intrinsics.zig:150`
   — must be forced eager at capture or made per-tenant).
4. The write-barrier / remembered-set story stays sound because
   shared→tenant edges cannot form (see 3), so tenant GC never needs
   to scan the image.

Hazards to resolve before committing: hashmap storage inside shared
objects is pointer-ful (fine read-only, but any tenant write to a
shared map is a bug the type system won't catch — needs the
immutability to be *enforced*, e.g. PROT_READ mapping so a stray
write faults loudly); `Realm`-pointer fields inside shared functions
(`JSFunction.realm`) are per-tenant by definition and must move to a
side table or be resolved through the running realm (the
`getFunctionRealm` fallback-to-caller path, `function.zig:550`,
already tolerates null). That refactor is the real cost of COW and
is why it is phase 3+, not phase 1.

---

## 11. Alternatives considered

- **A. Lazy builtin install (JSC model)** — defer each builtin until
  first touch. Rejected as the primary strategy: conflicts with
  `freezePrimordials` (the SES freeze needs the full graph eagerly;
  lazily materializing into a "frozen" realm reopens the hardening
  window and makes `Object.isFrozen(globalThis)` a lie). Could
  complement snapshots for rarely-touched namespaces later.
- **B. Template realm + deep-clone in memory** (skip the file
  format; keep a pristine realm and memcpy-clone per tenant).
  Cheaper to build but solves only the same-process case, still
  needs the full field-by-field clone logic (≈ the serializer
  without the format), and doesn't give persistent startup wins.
  The serializer subsumes it.
- **C. Raw pool-page dump + relocation** — rejected for phase 1
  (§3.6): std hashmap internals and out-of-line GPA allocations make
  the image non-self-contained; returns as the COW substrate where
  the data layout is redesigned for it.

## 12. What I could not verify (implementer checklist)

- Exact live-object census of a fresh realm (bigints? populated
  `small_int_strings`? any cons strings?) — instrument with
  `--mem-summary`-style counters or a debug dump before finalizing
  the assert set in §6.1.
- `-Dintl=stub/full` object graphs (R6) and Temporal's
  `temporal_record` extension usage at install time.
- Whether `installTestGlobals`' `freezeOwnDataInShape` re-stamp
  (`realm.zig:2098`) leaves the global object's shape in a state the
  SHAP codec round-trips exactly (it should — redefine nodes — but
  test 4/6 must cover a test-globals realm).
- build.zig plumbing for `build_id` (§5.2).
- `Realm.evaluateScript`'s exact location/signature for the
  round-trip test harness (referenced in AGENTS.md; used by
  `builtins/webassembly.zig:1536` tests via
  `lantern.evaluateScript(alloc, &realm, src)` — use that form).
