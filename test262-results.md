# test262 conformance — Cynic

**Cynic passes 84.12 % of its 45096-fixture test262 corpus** under the default (hardened SES) posture (`cynic run`). The breakdown:

- **34841 pass** at the engine-true level (engine% = 99.90 % — see Legend).
- **3092 SES-policy divergences** — Cynic's hardened posture throws by design where test262 expects the spec-literal success (frozen primordials, locked descriptors, override-mistake fix). Counted as engine-correct in the headline `pass%` per Layout A; see `docs/handbook/ses-test262-policy.md`.
- **35 real engine failures** — all libregexp Annex B / `/v` grammar carve-outs documented in [AGENTS.md](../AGENTS.md).
- **7128 skipped** — **tech debt + vendor gaps**. Features Cynic should eventually ship (Temporal, `explicit-resource-management`) or fixtures blocked on vendored libregexp (`/v` set-difference, `\q{…}`, property-of-strings) and single-realm Cynic (`$262.createRealm()` cross-realm fixtures). Permanent out-of-scope (Annex B, `intl402/`, `staging/`, browser-era built-ins) is filtered before corpus — those are not counted here.

## Current scores

| posture | pass% | engine% | passes / corpus | divergent |
|---|---:|---:|---:|---:|
| **hardened** (default — `cynic run`) | 84.12 % | 99.90 % | 37933 / 45096 | 3092 |
| **unhardened** (`cynic --unhardened`) | 84.12 % | 99.91 % | 37933 / 45096 | — |

> **pass%** is the headline — `pass / corpus` (a fixture
> Cynic doesn't ship counts as a `skip`, lowering this).
> **engine%** = `pass / (pass + fail)` — of fixtures the
> engine attempted, the fraction that passed at the
> spec-literal level (skips and SES divergences drop
> out). **The engine-quality gauge** — moves only when
> a real fixture flips engine pass/fail, independent of
> what's left unimplemented or how SES policy weighs in.

*SES witness fidelity*: **10 / 10** witnesses classify as `divergent` (100.00 %). Curated set in `tools/test262/ses_witnesses.zig`; CI gates at 100 %. See `docs/handbook/ses-test262-policy.md`.

## Legend

### Rows (postures)

Same engine path, different SES posture. Both numbers
refer to the same parse → compile → run sweep.

- **hardened** — the default posture (`cynic run`).
  Primordials frozen, override-mistake fix on, locked
  descriptors on every built-in `.name` / `.length`.
  Fixtures that check spec-mandated `configurable: true`
  on those slots reclassify as **divergent** (the engine
  throws correctly; the test's expectation is the part
  invalidated by SES).
- **unhardened** — `cynic --unhardened` opt-out. Same
  engine, but `realm.hardened = false` — primordials
  stay mutable, globalThis extensible, no
  override-mistake fix. The pre-SES ECMAScript baseline.
  No fixtures get divergent-reclassified here.

### Columns

- **`pass%`** — `pass / corpus`. Under **hardened**, the
  numerator is `(pass + divergent)` per Layout A: divergent
  fixtures fail by the strict ECMA-262 letter (SES rejects
  writes the spec allows) but Cynic's default posture
  ships the SES policy, so they count as engine-correct.
  **This is what an embedder running `cynic run` sees
  succeed.** Under **unhardened**, the numerator is plain
  `pass`.
- **`engine%`** — `pass / (pass + fail)`. Of fixtures the
  engine actually attempted, the fraction that passed at
  the spec-literal engine level (no SES weighting). The
  pass numerator excludes `divergent`, so a hardened
  regression that flips a real fixture from pass to fail
  moves this column even when the divergent count masks
  the headline `pass%`. **This is the actual engine-
  quality gauge** — today >99.9 % both rows.
- **`passes / corpus`** — raw counts for `pass%`. Under
  hardened, `passes` includes divergent.
- **`divergent`** (hardened-only) — fixtures whose
  test262-written assertion conflicts with SES enforcement
  (frozen primordials, locked descriptors, override-mistake
  fix). The engine throws on the offending operation; the
  fixture's "expected pass" is invalidated by Cynic's SES
  policy. **These are spec-failures by ECMA-262's letter**,
  accepted as policy-correct under the hardened posture.
  Counted separately from `fail`. See
  `docs/handbook/ses-test262-policy.md`.
- **SES witness fidelity** (the italic note above) —
  Phase 3 positive-coverage signal. The curated witness
  set in `tools/test262/ses_witnesses.zig` is a small
  list of paths that MUST classify as `divergent` under
  hardened runs. Drift either way (witness now passes —
  SES enforcement weakened; or witness fails for a
  non-divergence reason — pattern miss or engine
  regression in the SES throw path) is a hard signal.
  CI gates the floor at 100 %.
- **`Δ pass`** (history) — change in `pass` versus the
  previous row of the same posture.
- **`elapsed`** (history) — wall-clock time of the run
  that produced the row. Recorded only for full sweeps
  (no `--filter`, no `--only-failing`); partial runs
  leave it blank. Sub-minute as `12.3 s`, minute+ as
  `2m 40s`.

### Why we don't claim "spec%"

The percentages here are **not** ECMA-262 spec
conformance. Spec conformance would require running every
normative requirement in the spec — there's no such
enumerable set. test262 is one community attempt at
covering the spec via concrete fixtures, and we run a
**filtered subset** of that (the `corpus`). So `pass%`
is right for "did anything regress?" tracking, but it's
a lower bound on spec coverage — a fixture not in
`corpus` doesn't get a verdict either way.

### Scope (what's in `corpus`)

Two-tier skiplist in
[`tools/test262/skip.zig`](../tools/test262/skip.zig)
(see the per-group comments there for the full list):

- **Filtered out** (not in `corpus`, won't ever be):
  Annex B language extensions + browser-era built-ins,
  `intl402/`, `harness/`, `staging/`, SES carve-outs
  (`eval()` until `--allow=eval` ships, SharedArrayBuffer
  / Atomics), pre-Stage-4 proposals Cynic ships behind
  `--enable=<name>` (each has its own phase sweep in
  `## Pre-Stage-4 proposals shipped` below).
- **In `corpus` as `skip`** — *tech debt*, should
  eventually pass: Stage-4 features Cynic hasn't shipped
  yet (Temporal, `explicit-resource-management`),
  libregexp `/v` grammar gaps (vendored matcher),
  cross-realm fixtures (`$262.createRealm()` —
  single-realm Cynic doesn't expose multi-realm to user
  JS yet). These count toward `corpus` so `pass%`
  reflects the actual work left instead of a trimmed-
  denominator headline.

Today: test262 ships ~52k fixtures; `corpus` is ~45k.
## Where the engine fails (and where SES diverges), by area

Per-bucket breakdown sourced from the **hardened (default)**
sweep so the numbers match `cynic run`. Bucketed on the
first two path components (`built-ins/Set`,
`language/expressions`, …).

**Reading guide:**

- The **top tier** (`1+ fails`) is the engine-work list.
  Today the only entry is `built-ins/RegExp` with 9
  libregexp Annex B / `/v` grammar gaps — fixtures that
  compile patterns the vendored libregexp matcher
  (QuickJS-NG) doesn't accept. All 9 are documented
  carve-outs in AGENTS.md ("Acknowledged exception —
  regex Annex B §B.1.4"). Closing them means patching
  vendored libregexp or switching matchers.
- The **0-fails tier** is sorted by `divergent ↓` so
  SES-hot buckets cluster at the top of the tail — that's
  where Cynic's frozen primordials / locked descriptors /
  override-mistake fix concentrate. `built-ins/Array`,
  `Object`, `TypedArray`, `String`, `Date`, `Math` are
  the heaviest — every primordial method's `.length` /
  `.name` slot SES locks down trips fixtures that read
  those descriptors back expecting `configurable: true`.
- ~~Strikethrough~~ rows are buckets we skip wholesale
  (out of scope per the Cynic-targeted skiplist — Annex B
  language extensions, `intl402`, `staging`, Temporal,
  browser-era built-ins, …).

| area | pass | fail | skip | divergent | pass% | engine% |
|---|---:|---:|---:|---:|---:|---:|
| **_10–99 fails — engine-work tier_** | | | | | | |
| `language/statements` | 8491 | 24 | 485 | 89 | 94 % | 100 % |
| **_1–9 fails — engine-work tier (libregexp Annex B carve-outs today)_** | | | | | | |
| `built-ins/AsyncDisposableStack` | 78 | 2 | 1 | 23 | 97 % | 98 % |
| `built-ins/RegExp` | 1504 | 9 | 269 | 89 | 85 % | 99 % |
| **_0 fails — passing / wholly OOS (sorted by divergent ↓)_** | | | | | | |
| `built-ins/Array` | 2477 | 0 | 41 | 558 | 99 % | 100 % |
| `built-ins/Object` | 2795 | 0 | 81 | 524 | 98 % | 100 % |
| `built-ins/TypedArray` | 1113 | 0 | 8 | 310 | 99 % | 100 % |
| `built-ins/String` | 1027 | 0 | 6 | 176 | 100 % | 100 % |
| `built-ins/Date` | 431 | 0 | 11 | 152 | 98 % | 100 % |
| `built-ins/Math` | 214 | 0 | 0 | 113 | 100 % | 100 % |
| `built-ins/Promise` | 526 | 0 | 39 | 101 | 94 % | 100 % |
| `language/expressions` | 9742 | 0 | 905 | 99 | 92 % | 100 % |
| `built-ins/TypedArrayConstructors` | 562 | 0 | 26 | 93 | 96 % | 100 % |
| `built-ins/Set` | 312 | 0 | 2 | 69 | 99 % | 100 % |
| `built-ins/Iterator` | 369 | 0 | 1 | 62 | 100 % | 100 % |
| `built-ins/DataView` | 457 | 0 | 12 | 53 | 98 % | 100 % |
| `built-ins/Map` | 152 | 0 | 2 | 50 | 99 % | 100 % |
| `built-ins/ArrayBuffer` | 137 | 0 | 5 | 45 | 97 % | 100 % |
| `built-ins/Reflect` | 111 | 0 | 0 | 41 | 100 % | 100 % |
| `built-ins/Number` | 301 | 0 | 1 | 38 | 100 % | 100 % |
| `built-ins/NativeErrors` | 52 | 0 | 6 | 36 | 94 % | 100 % |
| `built-ins/Function` | 227 | 0 | 18 | 29 | 93 % | 100 % |
| `built-ins/JSON` | 136 | 0 | 0 | 28 | 100 % | 100 % |
| `built-ins/WeakMap` | 113 | 0 | 1 | 27 | 99 % | 100 % |
| `built-ins/DisposableStack` | 69 | 0 | 1 | 23 | 99 % | 100 % |
| `built-ins/Symbol` | 57 | 0 | 19 | 22 | 81 % | 100 % |
| `built-ins/WeakSet` | 64 | 0 | 1 | 20 | 99 % | 100 % |
| `built-ins/BigInt` | 58 | 0 | 1 | 18 | 99 % | 100 % |
| `built-ins/Uint8Array` | 50 | 0 | 0 | 18 | 100 % | 100 % |
| `built-ins/Error` | 41 | 0 | 1 | 14 | 98 % | 100 % |
| `language/module-code` | 574 | 0 | 2 | 13 | 100 % | 100 % |
| `built-ins/RegExpStringIteratorPrototype` | 5 | 0 | 0 | 12 | 100 % | 100 % |
| `built-ins/AsyncGeneratorPrototype` | 37 | 0 | 0 | 11 | 100 % | 100 % |
| `built-ins/FinalizationRegistry` | 35 | 0 | 1 | 11 | 98 % | 100 % |
| `built-ins/GeneratorPrototype` | 50 | 0 | 0 | 11 | 100 % | 100 % |
| `built-ins/WeakRef` | 20 | 0 | 1 | 8 | 97 % | 100 % |
| `language/global-code` | 28 | 0 | 5 | 8 | 88 % | 100 % |
| `built-ins/AsyncGeneratorFunction` | 2 | 0 | 2 | 7 | 82 % | 100 % |
| `built-ins/Boolean` | 42 | 0 | 1 | 7 | 98 % | 100 % |
| `built-ins/GeneratorFunction` | 2 | 0 | 2 | 7 | 82 % | 100 % |
| `language/types` | 90 | 0 | 13 | 7 | 88 % | 100 % |
| `built-ins/AggregateError` | 17 | 0 | 1 | 6 | 96 % | 100 % |
| `built-ins/AsyncIteratorPrototype` | 7 | 0 | 0 | 6 | 100 % | 100 % |
| `built-ins/Proxy` | 287 | 0 | 13 | 6 | 96 % | 100 % |
| `built-ins/SuppressedError` | 15 | 0 | 1 | 6 | 95 % | 100 % |
| `built-ins/AsyncFunction` | 9 | 0 | 1 | 5 | 93 % | 100 % |
| `built-ins/ArrayIteratorPrototype` | 15 | 0 | 8 | 4 | 70 % | 100 % |
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
| `language/import` | 20 | 0 | 106 | 1 | 17 % | 100 % |
| `language/punctuators` | 10 | 0 | 0 | 1 | 100 % | 100 % |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncFromSyncIteratorPrototype` | 38 | 0 | 0 | 0 | 100 % | 100 % |
| `built-ins/Infinity` | 4 | 0 | 2 | 0 | 67 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 0 | 67 % | 100 % |
| ~~`built-ins/ShadowRealm`~~ | ~~0~~ | ~~0~~ | ~~64~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Temporal`~~ | ~~0~~ | ~~0~~ | ~~4588~~ | ~~0~~ | ~~0 %~~ | ~~0 %~~ |
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
| `joint-iteration` | 70 | 8 | 4860 | 1 % | 90 % |


## History

### 2026-05-26 — cynic `14c1e01`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 84.12 % | 99.91 % | 37933 / 45096 | 37933 / 37968 | — | +620 | 50.6 s |
| **runtime_hardened** | 84.12 % | 99.90 % | 37933 / 45096 | 34841 / 34876 | 3092 | +3601 | 55.6 s |

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
| **runtime** | 85.12 % | 91.56 % | 34872 / 40969 | 34872 / 38087 | — | +1623 |  |

### 2026-05-14 — cynic `aca1903`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 80.12 % | 85.56 % | 33249 / 41501 | 33249 / 38860 | — | +474 |  |

### 2026-05-13 — cynic `550a57e`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 70.79 % | 85.00 % | 32775 / 46296 | 32775 / 38559 | — | +1007 |  |

### 2026-05-12 — cynic `6800720`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 68.62 % | 82.38 % | 31768 / 46296 | 31768 / 38563 | — | +1877 |  |

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 64.53 % | 78.37 % | 29891 / 46320 | 29891 / 38141 | — | +4713 |  |

### 2026-05-10 — cynic `c5c12a0`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 54.36 % | 66.01 % | 25178 / 46320 | 25178 / 38143 | — | +1265 |  |

### 2026-05-09 — cynic `fcc5543`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 51.58 % | 62.65 % | 23913 / 46357 | 23913 / 38169 | — | +6048 |  |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | pass% | engine% | pass / corpus | pass / engine-attempt | divergent | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|---:|
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | 17865 / 38304 | — | n/a |  |

