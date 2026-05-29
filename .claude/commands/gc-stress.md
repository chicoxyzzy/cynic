---
description: Stress the GC at --gc-threshold=1, find use-after-free clusters, fix by rooting or typed slots, verify
---

Hunt and fix the use-after-free class where a native builtin or an
interpreter opcode holds a raw heap pointer (`*JSObject` /
`*JSString` / `*JSFunction`, or a `Value` in a native list) across
a JS re-entry without rooting it — the GC then sweeps it. These
bugs are invisible at the default allocation threshold and only
surface under `--gc-threshold=1`, where a full mark-sweep runs
after (nearly) every allocation.

Read [docs/handbook/gc.md](../../docs/handbook/gc.md) first — the
HandleScope contract and the "finding these bugs" section are the
ground truth this workflow operationalises.

## 1. Build the harness

`zig build test262` installs `zig-out/bin/cynic-test262`
(ReleaseFast). Run that binary directly for filtered iteration —
it skips the ~100 s `zig build` graph cost. Pass
`-Dtest262-debug=true` only when you need a stack trace on a
panic inside the engine (Debug rebuilds the harness + linked
library; ~5-10× slower). Note: the `verifyRememberedSet` verifier
and 0xaa poison are **no-ops in ReleaseFast** — ReleaseFast still
exercises the real GC and catches crashes / wrong answers, but
for verifier asserts build the ReleaseSafe harness:
`zig build test262-safe` installs `zig-out/bin/cynic-test262-safe`
at a distinct path (it does **not** clobber the ReleaseFast binary
the way `-Dtest262-debug` does, so build each once and invoke
either directly). ReleaseSafe arms the verifier + poison while
running ~2-3× faster than Debug — the right binary for this
workflow.

## 2. Run the gc1 sweep — chunked

The full corpus at `--gc-threshold=1` is far too slow for one
budget (GC fires on every alloc; the RegExp `property-escapes`
tree is pathological). **Chunk it.** Loop over top-level buckets,
capturing each invocation's output fully before the next so a
crash mid-bucket doesn't lose prior results:

    tools/guarded-run.sh --timeout=1000 --rss=9000 -- bash -c '
      for f in language/expressions language/statements \
               built-ins/Object built-ins/Iterator built-ins/Map \
               built-ins/Set built-ins/Promise built-ins/Function; do
        r=$(./zig-out/bin/cynic-test262 --gc-threshold=1 --threads=4 \
              --filter=$f --list-failures=8 --quiet 2>&1)
        echo "$f | $(echo "$r" | grep -aE "pass:|fail:")"
        echo "$r" | grep -aE "Segmentation|panic|un-barriered|\[" | head -8
      done'

Skip `built-ins/RegExp/property-escapes` — it is pure libregexp +
plain string concat (no JS re-entry, so no UAF surface), just
slow. Always wrap in `tools/guarded-run.sh` (caps wall-time + RSS,
kills the whole tree); never a bare `timeout`.

## 3. Diff against the default sweep

For every bucket with `fail > 0` at gc1, run the same filter at
the **default** threshold. A fixture that **passes at default but
fails at gc1** is a use-after-free — that delta is the actionable
set. A fixture that fails at both is an ordinary conformance gap
(route it to `/triage`, not here).

## 4. Diagnose each cluster

For each gc1-only failure: read the fixture, find the native /
opcode it exercises, and locate the **JS re-entry** — a call that
runs user code and can therefore GC: `callJSFunction`,
`constructValue`, `getPropertyChain` (accessor / Proxy trap),
`stringifyArg` / `toPrimitive` / `toLengthValue` (coercion
hooks), `invokeIterNext`, a species constructor. Then ask: what
raw heap pointer is live across that call and reachable by the GC
through **nothing**?

Recurring offenders:
- A native `std.ArrayListUnmanaged` of `*JSFunction` / `Value` —
  the GC does not scan native lists.
- A freshly `allocateObject`'d result held across a later
  re-entry before it is linked into a rooted graph.
- A computed property key borrowed from a heap `JSString` that
  is never anchored (`object.zig` key-anchor contract).
- Engine state stashed as `__cynic_*` property-bag keys whose
  key slices dangle after a sweep.

## 5. Fix — one of two shapes

**(a) Root with a HandleScope.** For pointers that legitimately
live on a JS-visible object or are short-lived:

    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(value) catch return error.OutOfMemory;

`openScope` / `push` allocate from the raw allocator — they do
**not** trigger the engine GC. So rooting *before* the first
`realm.heap.allocate*` call in a function is airtight: there is
no GC between function entry and the rooting.

**(b) Move state into a typed JSObject slot.** Engine state must
never ride `__cynic_*` property-bag keys on any object reachable
by user JS — see the "No engine state on user-visible objects"
rule in [AGENTS.md](../../AGENTS.md). Add a typed struct in
`object.zig` (model: `IteratorHelperState`, `MapSetIterState`,
`RegExpStringIterState`, `IterRecord`), a `?*T` field on
`JSObject`, a `deinit` call, and GC marking in **both**
`markValue` paths of `heap.zig` (minor + full collection).

Editing the two `heap.zig` marking sites: a single-line 8-space
old_string is a substring of the 16-space one and matches twice —
use a multi-line old_string (per-line indentation differs, so it
stays unique) or anchor on the neighbouring block.

## 6. Verify

- gc1, the touched bucket: `cynic-test262 --gc-threshold=1
  --threads=4 --filter=<bucket>` → 0 fail, no `Segmentation` /
  `panic`.
- Default, same bucket → no regression vs the pre-fix count.
- `zig build test` → unit tests pass. Add a regression test to
  the `GC: …` cluster in `src/runtime/interpreter_test.zig`
  (`expectScriptIntUnderGcPressure` / `…StringUnderGcPressure`);
  for an observability fix, assert no `__cynic_*` own property
  survives via `getOwnPropertyNames` + `in` + `getOwnProperty
  Descriptor` + `hasOwn`.

## 7. Report

Per cluster: the fixture(s), the native / opcode, the re-entry
site, the fix shape applied, and the verified gc1 + default
counts. If a fix surfaces a bug no test262 fixture catches at the
default threshold, add an entry to
[docs/test262-upstream-gaps.md](../../docs/test262-upstream-gaps.md).
