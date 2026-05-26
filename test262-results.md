# test262 conformance score history

## Current scores

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent |
|---|---|---|---|---|---:|
| **parser** | 73.22 % | 100.00 % | 29406 / 40161 | 29406 / 29406 | — |
| **runtime** | 93.04 % | 99.98 % | 37430 / 40229 | 37430 / 37439 | — |
| **runtime_hardened** | 93.04 % | 99.97 % | 37430 / 40229 | 34413 / 37441 | 3017 |

*SES witness fidelity*: **10 / 10** witnesses classify as `divergent` (100.00 %). Curated set in `tools/test262/ses_witnesses.zig`; CI gates at 100 %. See `docs/handbook/ses-test262-policy.md`.

## Where the runtime stands, by area

Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …) under the **hardened (default)**
posture, so the numbers match what an embedder running
`cynic run` sees. Grouped into fail-magnitude tiers
(1000+, 100–999, 10–99, 1–9, 0) — heavy-hitter areas
surface at the top, related siblings stay neighbours so
the table is scannable. Within the 0-fails tier, rows
are sorted by `divergent` descending so SES-hot buckets
cluster at the front of the tail.

Columns:

- `pass` / `fail` / `skip` are the engine-true outcomes.
- `divergent` (Phase 2 of
  `docs/handbook/ses-test262-policy.md`) is the count of
  fixtures whose test262-written assertion conflicts with
  Cynic's SES enforcement (frozen primordials, locked
  descriptors, override-mistake fix). The fixture would
  pass on a spec-literal engine (V8 / JSC / SpiderMonkey),
  but Cynic's hardened posture throws by design — the
  throw is correct, the fixture's expectation of success
  is invalidated by Cynic's SES policy. So divergent is
  **policy-accepted**, not spec-passing.
- `pass%` for this hardened-sourced table is
  `(pass + divergent) / (pass + fail + skip + divergent)`
  per the Layout A math — the fraction the embedder
  running `cynic run` sees succeed under Cynic's default
  posture. **Not strict-spec conformance** (a spec-literal
  engine wouldn't count `divergent` here); see the row-
  level legend.
- `engine%` is `pass / (pass + fail)` — the true
  engine-conformance gauge, independent of SES policy.
  Skips and divergent reclassifications drop out. Today
  this is **>99.9 % across every bucket** that has any
  attempted fixtures — the engine implements the spec
  it does ship.

Rows in ~~strikethrough~~ are buckets we skip wholesale
(out of scope per the Cynic-targeted skiplist — Annex B
language extensions, intl402, staging, Temporal,
browser-era built-ins …).

| area | pass | fail | skip | divergent | pass% | engine% |
|---|---:|---:|---:|---:|---:|---:|
| **_1–9 fails_** | | | | | | |
| `built-ins/RegExp` | 1504 | 9 | 161 | 89 | 90 % | 99 % |
| **_0 fails (passing or wholly OOS — sorted by divergent ↓)_** | | | | | | |
| `built-ins/Array` | 2477 | 0 | 36 | 558 | 99 % | 100 % |
| `built-ins/Object` | 2795 | 0 | 80 | 524 | 98 % | 100 % |
| `built-ins/TypedArray` | 1113 | 0 | 8 | 310 | 99 % | 100 % |
| `built-ins/String` | 1027 | 0 | 5 | 176 | 100 % | 100 % |
| `built-ins/Date` | 431 | 0 | 0 | 152 | 100 % | 100 % |
| `built-ins/Math` | 214 | 0 | 0 | 113 | 100 % | 100 % |
| `built-ins/Promise` | 526 | 0 | 38 | 101 | 94 % | 100 % |
| `language/expressions` | 9681 | 0 | 960 | 99 | 91 % | 100 % |
| `built-ins/TypedArrayConstructors` | 562 | 0 | 16 | 93 | 98 % | 100 % |
| `language/statements` | 8346 | 0 | 654 | 81 | 93 % | 100 % |
| `built-ins/Set` | 312 | 0 | 1 | 69 | 100 % | 100 % |
| `built-ins/Iterator` | 366 | 0 | 6 | 59 | 99 % | 100 % |
| `built-ins/DataView` | 457 | 0 | 11 | 53 | 98 % | 100 % |
| `built-ins/Map` | 152 | 0 | 1 | 50 | 100 % | 100 % |
| `built-ins/ArrayBuffer` | 137 | 0 | 4 | 45 | 98 % | 100 % |
| `built-ins/Reflect` | 111 | 0 | 0 | 41 | 100 % | 100 % |
| `built-ins/Number` | 301 | 0 | 0 | 38 | 100 % | 100 % |
| `built-ins/NativeErrors` | 52 | 0 | 0 | 36 | 100 % | 100 % |
| `built-ins/Function` | 221 | 0 | 10 | 29 | 96 % | 100 % |
| `built-ins/WeakMap` | 113 | 0 | 0 | 27 | 100 % | 100 % |
| `built-ins/Symbol` | 53 | 0 | 6 | 22 | 93 % | 100 % |
| `built-ins/JSON` | 123 | 0 | 21 | 20 | 87 % | 100 % |
| `built-ins/WeakSet` | 64 | 0 | 0 | 20 | 100 % | 100 % |
| `built-ins/BigInt` | 58 | 0 | 0 | 18 | 100 % | 100 % |
| `built-ins/Uint8Array` | 50 | 0 | 0 | 18 | 100 % | 100 % |
| `built-ins/Error` | 41 | 0 | 0 | 14 | 100 % | 100 % |
| `language/module-code` | 562 | 0 | 14 | 13 | 98 % | 100 % |
| `built-ins/RegExpStringIteratorPrototype` | 5 | 0 | 0 | 12 | 100 % | 100 % |
| `built-ins/AsyncGeneratorPrototype` | 37 | 0 | 0 | 11 | 100 % | 100 % |
| `built-ins/FinalizationRegistry` | 35 | 0 | 0 | 11 | 100 % | 100 % |
| `built-ins/GeneratorPrototype` | 50 | 0 | 0 | 11 | 100 % | 100 % |
| `built-ins/WeakRef` | 20 | 0 | 0 | 8 | 100 % | 100 % |
| `language/global-code` | 28 | 0 | 5 | 8 | 88 % | 100 % |
| `built-ins/AsyncGeneratorFunction` | 2 | 0 | 0 | 7 | 100 % | 100 % |
| `built-ins/Boolean` | 42 | 0 | 0 | 7 | 100 % | 100 % |
| `built-ins/GeneratorFunction` | 2 | 0 | 0 | 7 | 100 % | 100 % |
| `language/types` | 90 | 0 | 9 | 7 | 92 % | 100 % |
| `built-ins/AggregateError` | 17 | 0 | 0 | 6 | 100 % | 100 % |
| `built-ins/Proxy` | 287 | 0 | 12 | 6 | 96 % | 100 % |
| `built-ins/AsyncFunction` | 9 | 0 | 0 | 5 | 100 % | 100 % |
| `built-ins/ArrayIteratorPrototype` | 15 | 0 | 8 | 4 | 70 % | 100 % |
| `built-ins/AsyncIteratorPrototype` | 1 | 0 | 9 | 3 | 31 % | 100 % |
| `built-ins/MapIteratorPrototype` | 8 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/SetIteratorPrototype` | 8 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/StringIteratorPrototype` | 4 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/decodeURI` | 52 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/decodeURIComponent` | 53 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/encodeURI` | 28 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/encodeURIComponent` | 28 | 0 | 0 | 3 | 100 % | 100 % |
| `built-ins/global` | 6 | 0 | 0 | 3 | 100 % | 100 % |
| `language/function-code` | 91 | 0 | 109 | 3 | 46 % | 100 % |
| `language/arguments-object` | 202 | 0 | 57 | 2 | 78 % | 100 % |
| `language/identifier-resolution` | 7 | 0 | 5 | 2 | 64 % | 100 % |
| `built-ins/isFinite` | 14 | 0 | 0 | 1 | 100 % | 100 % |
| `built-ins/isNaN` | 14 | 0 | 0 | 1 | 100 % | 100 % |
| `built-ins/parseFloat` | 53 | 0 | 0 | 1 | 100 % | 100 % |
| `built-ins/parseInt` | 54 | 0 | 0 | 1 | 100 % | 100 % |
| `language/punctuators` | 10 | 0 | 0 | 1 | 100 % | 100 % |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~103~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncFromSyncIteratorPrototype` | 38 | 0 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~92~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Infinity` | 4 | 0 | 2 | 0 | 67 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 0 | 67 % | 100 % |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~21~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/ThrowTypeError` | 13 | 0 | 0 | 0 | 100 % | 100 % |
| `built-ins/undefined` | 4 | 0 | 3 | 0 | 57 % | 100 % |
| `language/asi` | 102 | 0 | 0 | 0 | 100 % | 100 % |
| `language/block-scope` | 145 | 0 | 0 | 0 | 100 % | 100 % |
| `language/comments` | 22 | 0 | 23 | 0 | 49 % | 100 % |
| `language/computed-property-names` | 48 | 0 | 0 | 0 | 100 % | 100 % |
| `language/destructuring` | 18 | 0 | 1 | 0 | 95 % | 100 % |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| `language/export` | 3 | 0 | 0 | 0 | 100 % | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 0 | 87 % | 100 % |
| `language/identifiers` | 268 | 0 | 0 | 0 | 100 % | 100 % |
| `language/import` | 4 | 0 | 123 | 0 | 3 % | 100 % |
| `language/keywords` | 25 | 0 | 0 | 0 | 100 % | 100 % |
| `language/line-terminators` | 32 | 0 | 0 | 0 | 100 % | 100 % |
| `language/literals` | 384 | 0 | 97 | 0 | 80 % | 100 % |
| `language/reserved-words` | 27 | 0 | 0 | 0 | 100 % | 100 % |
| `language/rest-parameters` | 11 | 0 | 0 | 0 | 100 % | 100 % |
| `language/source-text` | 1 | 0 | 0 | 0 | 100 % | 100 % |
| `language/statementList` | 40 | 0 | 0 | 0 | 100 % | 100 % |
| `language/white-space` | 51 | 0 | 0 | 0 | 100 % | 100 % |

## Pre-Stage-4 proposals shipped

Per-feature scores for the TC39 proposals Cynic ships at
Stage 1–3, ahead of their inclusion in the published
edition. **Each row is sourced from a dedicated phase
sweep** that runs only the fixtures whose frontmatter
`features:` list names the proposal, in a realm where only
that proposal's flag is enabled — a `joint-iteration`
fixture is scored here against a realm where
`Map.prototype.getOrInsert` is undefined, and vice versa,
so each row reflects the proposal in honest isolation.
**These fixtures are excluded entirely from the top-line
`## Current scores` and the per-area scoreboard** — they
are not in the Cynic corpus and not in any bucket, so the
headline number tracks stable ECMA-262 conformance only.
When a proposal advances to Stage 4 the row stays here
until its features ship in mainline ECMA-262.

| feature | pass | fail | skip | pass% | engine% |
|---|---:|---:|---:|---:|---:|
| `joint-iteration` | 68 | 10 | 0 | 87 % | 87 % |


## Legend

### What "spec%" would mean (and why we don't claim it)

The percentages here are **not** ECMA-262 spec conformance.
Spec conformance would require running every normative
requirement in the spec — there's no such enumerable set.
test262 is one community attempt at covering the spec via
concrete fixtures, and we run a **filtered subset** of
that (the "corpus" below).

So **`pass%` here means `pass / corpus`** — how many
fixtures we actually run pass. It's the right number for
"did anything regress?" tracking, but it's a lower bound
on spec coverage (a fixture not in `corpus` doesn't get a
verdict either way).

### Rows

- **`parser`** — parses the source only. A pass means
  Cynic's parser accepts or rejects the test as test262
  expects. The runtime is never invoked.
- **`runtime`** — parses, compiles, and executes against
  an *unhardened* realm (primordials mutable, globalThis
  extensible — the legacy ECMAScript baseline). Same
  engine path as `runtime_hardened`; the difference is
  the SES posture, not the spec.
- **`runtime_hardened`** — same as `runtime` but with the
  SES posture active (`realm.hardened = true`, the default
  for `cynic` / `cynic run`). Primordials are frozen; the
  override-mistake fix lets user code shadow on its own
  receivers. Fixtures that check spec-mandated
  `configurable: true` on built-in `.name` / `.length`
  reclassify as **divergent** (see column) — see
  `docs/handbook/ses-test262-policy.md`.

### Columns

- **`pass%`** — `pass / corpus`. For `parser` and `runtime`,
  the numerator is plain `pass`. For `runtime_hardened`,
  the numerator is `(pass + divergent)` per the Layout A
  math: divergent fixtures fail by the strict ECMA-262
  letter (SES rejects writes the spec allows), but Cynic's
  default posture ships the SES policy, so they're
  policy-accepted as engine-correct. **This is what an
  embedder running `cynic run` sees succeed.**
- **`engine%`** — `pass / (pass + fail)`. Of fixtures the
  engine actually attempted, the fraction that passed at
  the engine-true level (no SES weighting). The pass
  numerator excludes `divergent`, so a hardened regression
  that flips a real fixture from pass to fail moves this
  column even when the divergent count masks the headline
  `pass%`. **This is the actual engine-quality gauge.**
  Today >99.9 % across every row — Cynic implements the
  spec it does ship.
- **`pass / corpus`** — raw counts for `pass%`. `corpus` is
  the Cynic-targeted test262 subset (see Scope below);
  `skip = corpus - attempted - divergent`.
- **`pass / engine-attempt`** — raw counts for `engine%`.
  Numerator excludes divergent reclassifications, so an
  attentive reader can see at a glance how much of the
  hardened `pass%` is policy-accepted vs engine-true.
- **`divergent`** (`runtime_hardened` only) — fixtures
  whose test262-written assertion conflicts with SES
  enforcement (frozen primordials, locked descriptors,
  override-mistake fix). The engine throws on the
  offending operation; the fixture's "expected pass" is
  invalidated by Cynic's SES policy. **These are
  spec-failures by ECMA-262's letter**, accepted as
  policy-correct under the hardened posture. Counted
  separately from `fail`. See
  `docs/handbook/ses-test262-policy.md`. Other rows
  render `—`.
- **SES witness fidelity** (note under `## Current scores`)
  — Phase 3 positive-coverage signal. The curated witness
  set in `tools/test262/ses_witnesses.zig` is a small list
  of paths that MUST classify as `divergent` under
  hardened runs. Drift either way (a witness now passes
  — SES enforcement weakened; or a witness fails for a
  non-divergence reason — pattern miss or engine
  regression in the SES throw path) is a hard signal. CI
  gates the floor at 100 %.
- **`Δ pass`** (history) — change in `pass` versus the row
  immediately above (chronologically previous run of the
  same row identity).
- **`elapsed`** (history) — wall-clock time of the run
  that produced the row. Recorded only for full sweeps
  (no `--filter`, no `--only-failing`); partial runs
  leave it blank to keep the regression signal clean.
  Sub-minute as `12.3 s`, minute+ as `2m 40s`.

### Scope (what's in `corpus`)

`corpus` is the test262 fixture count *after* the
Cynic-targeted skiplist (`tools/test262/skip.zig`) filters
out:

- **Universally OOS**: `harness/`, `staging/`, `intl402/`
  (internationalization — Cynic doesn't ship Intl).
- **Annex B language extensions**: HTML-like comments,
  labelled function decls in sloppy mode, legacy octals,
  Annex B regex grammar (mostly — see the acknowledged
  `/u`-less leak in AGENTS.md). Cynic targets edge
  runtimes, not browsers.
- **Annex B built-ins**: `escape` / `unescape`,
  `String.prototype` HTML wrappers (`.bold` / `.fontsize`
  / etc.), `Date.{getYear, setYear, toGMTString}`,
  `String.prototype.{substr, trimLeft, trimRight}`,
  `Object.prototype.__proto__` accessor,
  `Object.prototype.__defineGetter__` /
  `__defineSetter__` / `__lookupGetter__` /
  `__lookupSetter__`, `RegExp.{$1, input, …}` legacy
  globals.
- **Planned features** Cynic doesn't ship yet: Temporal,
  explicit-resource-management (`using` / `await using` +
  `DisposableStack` / `AsyncDisposableStack` /
  `SuppressedError`), import-attributes + json-modules,
  Uint8Array `{from,to}{Base64,Hex}`, Float16Array,
  json-parse-with-source.
- **Pre-Stage-4 proposals** Cynic ships behind
  `--enable=<name>`: tracked in the per-feature scoreboard
  below, not in `corpus`. Each proposal's fixtures run
  in a dedicated phase sweep with only that one flag
  enabled, so the row reflects the proposal in honest
  isolation.

Today: test262 ships ~52k fixtures; `corpus` is 40161.

## History

### 2026-05-26 — cynic `023f094`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 73.22 % | 100.00 % | 29406 / 40161 | 29406 / 29406 | — | -905 | 5.6 s |
| **runtime** | 93.04 % | 99.98 % | 37430 / 40229 | 37430 / 37439 | — | +117 | 40.6 s |
| **runtime_hardened** | 93.04 % | 99.97 % | 37430 / 40229 | 34413 / 37441 | 3017 | +3098 | 40.6 s |

### 2026-05-25 — cynic `8e311c3`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.91 % | 99.98 % | 37313 / 40161 | 37313 / 37320 | — | +72 |  |
| **runtime_hardened** | 85.49 % | 91.99 % | 34332 / 40161 | 34332 / 37321 | — | n/a |  |

### 2026-05-24 — cynic `b49572e`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.90 % | 99.98 % | 37241 / 40089 | 37241 / 37248 | — | +47 |  |

### 2026-05-23 — cynic `a8caaf8`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.78 % | 99.93 % | 37194 / 40090 | 37194 / 37220 | — | -17 |  |

### 2026-05-22 — cynic `99b6566`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.82 % | 99.98 % | 37211 / 40090 | 37211 / 37218 | — | +3 |  |

### 2026-05-21 — cynic `0ad1d25`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.81 % | 99.97 % | 37208 / 40091 | 37208 / 37219 | — | +33 |  |

### 2026-05-20 — cynic `1708084`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.72 % | 99.87 % | 37175 / 40094 | 37175 / 37223 | — | +82 |  |

### 2026-05-19 — cynic `b2efa16`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.51 % | 99.64 % | 37093 / 40098 | 37093 / 37227 | — | +117 |  |

### 2026-05-18 — cynic `debcfcf`, test262 `b1f9a0aea3`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 92.17 % | 99.28 % | 36976 / 40115 | 36976 / 37244 | — | +314 |  |

### 2026-05-17 — cynic `400fbae`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 91.28 % | 98.25 % | 36662 / 40164 | 36662 / 37315 | — | +786 |  |

### 2026-05-16 — cynic `452bafa`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 88.78 % | 95.58 % | 35876 / 40411 | 35876 / 37535 | — | +1004 |  |

### 2026-05-15 — cynic `2b05c51`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 | — | -167 |  |
| **runtime** | 85.12 % | 91.56 % | 34872 / 40969 | 34872 / 38087 | — | +1623 |  |

### 2026-05-14 — cynic `aca1903`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 73.44 % | 100.00 % | 30478 / 41501 | 30478 / 30478 | — | +108 |  |
| **runtime** | 80.12 % | 85.56 % | 33249 / 41501 | 33249 / 38860 | — | +474 |  |

### 2026-05-13 — cynic `550a57e`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 65.76 % | 100.00 % | 30370 / 46183 | 30370 / 30370 | — | +964 |  |
| **runtime** | 70.79 % | 85.00 % | 32775 / 46296 | 32775 / 38559 | — | +1007 |  |

### 2026-05-12 — cynic `6800720`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 63.52 % | 96.48 % | 29406 / 46296 | 29406 / 30479 | — | +148 |  |
| **runtime** | 68.62 % | 82.38 % | 31768 / 46296 | 31768 / 38563 | — | +1877 |  |

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | 29258 / 30325 | — | ±0 |  |
| **runtime** | 64.53 % | 78.37 % | 29891 / 46320 | 29891 / 38141 | — | +4713 |  |

### 2026-05-10 — cynic `c5c12a0`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | 29258 / 30325 | — | +464 |  |
| **runtime** | 54.36 % | 66.01 % | 25178 / 46320 | 25178 / 38143 | — | +1265 |  |

### 2026-05-09 — cynic `fcc5543`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 | 28794 / 30345 | — | +252 |  |
| **runtime** | 51.58 % | 62.65 % | 23913 / 46357 | 23913 / 38169 | — | +6048 |  |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | 28542 / 29853 | — | n/a |  |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | 17865 / 38304 | — | n/a |  |

