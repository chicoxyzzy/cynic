# Cynic

[![CI](https://github.com/chicoxyzzy/cynic/actions/workflows/ci.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/ci.yml)
[![CodeQL](https://github.com/chicoxyzzy/cynic/actions/workflows/codeql.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/codeql.yml)
[![Playground](https://github.com/chicoxyzzy/cynic/actions/workflows/playground.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/playground.yml)

A strict-only ECMAScript engine, written from scratch in Zig.

Cynic targets non-browser hosts — edge runtimes, Workers, server-side JS
— and omits the web-compatibility surfaces by design:

- **No sloppy mode.** Every source is parsed as strict. The strict
  reserved-word set, restricted assignment to `eval` / `arguments`, and
  the absence of `with`, labels, legacy octal, HTML-like comments, and
  Annex B *language* extensions (sloppy-mode-only function-in-block,
  `for-in` initializer, …) are baked in at the language level.
- **No web-compatibility built-ins.** `escape` / `unescape`, the 13
  `String.prototype` HTML wrappers (`anchor`, `bold`, …),
  `Date.prototype.{getYear, setYear, toGMTString}`, and the
  `String.prototype.{substr, trimLeft, trimRight}` aliases aren't
  shipped. The canonical modern names (`trimStart` / `trimEnd`,
  `toUTCString`) are the only spelling.
- **No runtime code construction.** `eval`, `new Function(string)`,
  `new GeneratorFunction(string)`, `new AsyncFunction(string)`. Aligns
  with [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses).
- **SES-hardened by default.** Every modern edge runtime is
  "SES-friendly" — meaning user code can call `lockdown()` to harden
  primordials. Cynic skips the call. Realms boot with every intrinsic
  frozen (`[[Extensible]] = false`, non-writable / non-configurable
  descriptors), `harden()` shipped as a native global (recursive deep
  freeze, matches `@endo/ses`), and the override-mistake fix in place
  (`obj.x = 2` shadows a frozen prototype's data slot instead of
  throwing TypeError). `--unhardened` opts the whole posture out
  atomically for code that genuinely needs `OrdinarySet` semantics.
  Compartments are deferred (a TC39 Stage 1 proposal — the multi-realm
  substrate they need largely ships). See
  [`docs/ses-alignment.md`](docs/ses-alignment.md).

## Status

Pre-alpha. Lexer + parser + Lantern (T0 bytecode interpreter) +
Metla (mark-sweep GC) ship, alongside Perlex (the native §22.2
RegExp engine), Sarcasm (the from-scratch WebAssembly engine —
100 % of the spec-testsuite commands it scores), the native §3
Unicode tables, and
the hardened-by-default realm-boot pipeline. The runtime is filling
in §19-§28 one bucket at a time. Bistromath (the baseline JIT)
runs by default (`--no-jit` opts out) since the step-3 exit
([`docs/jit.md`](docs/jit.md)); Ohaimark (the optimizing tier) and
a moving generational GC are future work. See
[`docs/ROADMAP.md`](docs/ROADMAP.md) for the thematic breakdown.

### Conformance

Current scores, history, and per-bucket breakdown live in
[`test262-results.md`](test262-results.md). Scoring is binary under a
single posture (`--unhardened --allow=eval`): `pass%` is
`passing / total`, where `total` is `passing + failing` — there is
**no** "expected fail" reclassification, so an Annex B, no-Intl,
strict-only, SES, or eval miss counts as a plain `failing`, the same as
an engine bug. `total` excludes the upstream `harness/` / `staging/` /
`annexB/` paths, every Stage ≤ 3 proposal, and structurally-unrunnable
fixtures; shipped pre-Stage-4 proposals get their own per-feature
scoreboard. The WebAssembly engine has its own conformance run
([`wasm-results.md`](wasm-results.md) — 100 % of the commands it scores;
the scored set excludes tests for not-yet-implemented proposals).
The unit-test suite (`zig build test`) runs alongside.

### Build targets

- **Native CI (gating):** `x86_64-linux-gnu`,
  `aarch64-macos` (Apple Silicon). Full battery — build +
  unit tests + SES coverage.
- **Cross-compile CI (build-only, gating):** `aarch64-linux-gnu`,
  `x86_64-linux-musl`, `aarch64-macos` from Linux. Catches
  platform-specific compile breaks pre-merge.
- **WASM:** `wasm32-freestanding` powers the
  [playground](https://chicoxyzzy.github.io/cynic/playground/).
- **Not yet:** Windows (POSIX carve-outs in `src/runtime/heap.zig` +
  `tools/test262.zig`), Android (NDK + `build.zig` sysroot plumbing),
  iOS (Xcode SDK forwarding). Tracked separately.

### What works today

The shape, in broad strokes — the per-bucket numbers live in the
[`test262-results.md`](test262-results.md) scoreboard.

- **Parser** — every §13 expression form, classes (private members,
  static blocks, getters/setters), generators + async + async
  generators, ES6 modules in all forms, destructuring in every
  position the spec allows.
- **Statements & control flow** — the usual `if` / `switch` /
  `while` / `for` / `try` family, including TDZ enforcement and
  per-iteration closures for `for-let`. `for-of` walks any
  `@@iterator`-bearing iterable; iterator-close fires on `break`
  per §7.4.6.
- **Functions & classes** — closures, `arguments`, `bind` chains,
  `extends` / `super`, default-ctor synthesis, only-via-`new`,
  instance + private + static fields, static blocks, getters and
  setters.
- **Built-ins** — `Object`, `Array`, `String` / `Number` /
  `Boolean` / `BigInt` / `Symbol` (real primitives, not polyfills),
  `Math`, `JSON`, `Map` / `Set` / `WeakMap` / `WeakSet`,
  `WeakRef` / `FinalizationRegistry`,
  `Reflect`, ES2025 `Set` ops (`union` / `intersection` / …),
  `Iterator` helpers (`map` / `filter` / `take` / `drop` /
  `flatMap` / etc.),
  `Proxy` (most traps), `Date` (UTC-only), the URI globals, the
  standard error hierarchy with `error-cause`.
- **TypedArrays** — `ArrayBuffer`, `DataView`, the typed-array
  family backed by the canonical `%TypedArray%.prototype`.
- **Shared memory & atomics** — `SharedArrayBuffer` (growable) and the
  full `Atomics` surface (`wait` / `notify` / `waitAsync` /
  `compareExchange` / `isLockFree` / …), with real cross-thread
  `wait` / `notify` over OS threads, not a single-threaded stub.
- **RegExp** — full ECMA-262 via **Perlex**, Cynic's own native
  engine (named groups, lookbehind, `u` / `v` flags, indices). String
  methods dispatch through it.
- **Promises & async/await** — full chaining (settled and pending),
  pending-await suspension via `JSGenerator` capture, async
  generators with promise-reaction chaining, `Promise.try` and
  `Promise.withResolvers`.
- **WebAssembly** — Cynic runs Wasm through the `WebAssembly` JS
  API (`Module` / `Instance` / `Memory` / `Table` / `Global` /
  `Tag` / `Exception`, `compile` / `instantiate`, host imports,
  cross-module linking), powered by **Sarcasm** — a from-scratch
  in-place interpreter (SIMD, reference types, typed function
  references, memory64, multiple memories, tail calls, relaxed-SIMD,
  and the exception-handling proposal —
  `try_table` / `throw` / `throw_ref` / `exnref`). **100 %
  of the commands it scores (58779/58779)** on the official
  WebAssembly spec testsuite — the scored set excludes tests for
  not-yet-implemented proposals (see
  [`wasm-results.md`](wasm-results.md)). Off by default; opt in with
  `--allow=wasm` (same SES posture as `eval` — see
  [`docs/wasm-engine.md`](docs/wasm-engine.md)).
- **Proper Tail Calls** (ES2015 §15.10) — calls in tail position
  reuse the caller's frame instead of pushing a fresh one;
  `function f(n) { return f(n - 1); }` recurses without growing
  the dispatch stack. Second engine shipping spec-mandated PTC
  alongside JavaScriptCore.
- **Tooling** — `cynic parse | eval | run` plus a parallel test262
  harness with `--threads=N`, `--only-failing` cache, and a
  per-area scoreboard.

Internals: NaN-boxed values, Ignition-style register-file +
accumulator bytecode, stop-the-world mark-sweep heap fired on
allocation pressure (the heap stays bounded under any allocating
loop / recursion / promise chain — see
[`docs/handbook/gc.md`](docs/handbook/gc.md) for the trigger and
the `HandleScope` contract for natives).

## Build

```sh
git submodule update --init vendor/test262   # one-time; needed for `zig build test262`

zig build              # build cynic into zig-out/bin/
zig build test         # run all unit tests
zig build test262      # test262 conformance (parse + compile + execute; --write-results also runs each pre-Stage-4 feature phase)
```

Requires Zig **0.17-dev** (master). The Zig project skipped a stable
0.16, so CI tracks `master` via
[`xyzzylabs/setup-zig`](https://github.com/xyzzylabs/setup-zig). If
your local `zig version` reports an older dev tag, bump it.

`zig build test262` accepts forwarded flags after `--`:

- `--filter=<substring>` — run only matching paths.
- `--list-failures=<n>` — print the first `n` failing paths after the tally.
- `--phase=<spec>` — pin the harness to a single sweep. `--phase=main` is the headline ECMA-262 sweep (pre-Stage-4 fixtures excluded); `--phase=feature:<name>` (e.g. `feature:joint-iteration`, `feature:upsert`) runs only that proposal's dedicated isolated sweep. Default: just main, unless `--write-results` is set — then main + every tracked feature run in sequence.
- `--quiet` / `--verbose` — progress noise dial.
- `--no-harness` — skip the `sta.js` + `assert.js` preamble (for measuring the no-harness floor).
- `--threads=<n>` — worker count (`0` = auto, `1` = sequential, `>1` = pool).
- `--only-failing` — skip-as-pass any path in `.test262-pass-cache.txt`. After a full sweep populates the cache, the next iteration runs only the ~7 k failing/skipped fixtures — ≤ 30 s vs ≤ 100 s. Don't use for score rows; use it for per-fix verification.
- `--gc-threshold=<n>` — per-fixture allocation-pressure GC threshold (default 32,768; engine default 16,384). `0` falls through to the engine default. The engine also has a 16 MiB byte trigger so allocate-and-discard patterns GC promptly regardless of count.
- `--write-results` — update `test262-results.md` with today's row. Re-running on the same date replaces that day's row rather than appending. The default run never touches that file.
- **Memory / leak instrumentation:** `--gc-stats` (per-cycle pool counts + bytes), `--mem-summary` (end-of-sweep totals: cumulative bytes, max charged peak, GC cycles), `--top-rss=<n>` (top-N fixtures by process RSS delta ≥ 8 MiB), `--top-alloc=<n>` (top-N by cumulative bytes allocated ≥ 64 KiB — catches GC-cleaned thrash that RSS hides), `--leak-check` (route per-fixture bytes allocator through `std.heap.DebugAllocator`; stack trace per unfreed allocation), `--max-rss=<mb>` (abort with the offending path when RSS crosses budget).

The Unicode tables under `src/unicode/` are generated and committed:
`ident_tables.zig` (lexer `ID_Start` / `ID_Continue`),
`property_tables.zig` (RegExp `\p{…}` property escapes),
`case_fold_tables.zig` (RegExp `/iu` / `/iv` case folding),
`case_conv_tables.zig` (`String.prototype.toLowerCase` / `toUpperCase`),
`normalization_tables.zig` (UAX #15 NF{C,D,KC,KD}). Currently
Unicode 17.0. ECMA-262 §3 references `unicode.org/versions/latest`,
so we track upstream: drop the refreshed UCD files into
`vendor/unicode/` and run `zig build gen-unicode` to regenerate.

## Run

After `zig build`, the CLI is at `zig-out/bin/cynic` — put it on your
PATH or run `./zig-out/bin/cynic`. The examples use `cynic`:

```sh
cynic lex   path/to/file.js              # tokenize and print
cynic parse path/to/file.js              # parse a Script
cynic parse --module path/to/file.js     # parse a Module
cynic parse path/to/file.mjs             # .mjs ⇒ module
cynic eval  '1 + 2 * 3'                  # evaluate an expression
cynic run   path/to/file.js              # run a script
cynic run   a.js b.js c.js               # multiple files share one realm
cynic repl                               # interactive REPL (persistent realm)
```

The `cynic` CLI keeps pre-Stage-4 / experimental TC39 proposals off
by default — embedders see only stable ECMA-262. Opt in:

```sh
cynic --list-features                       # show available proposals
cynic --enable=joint-iteration eval '...'   # one feature
cynic --enable-experimental run foo.js      # all tracked features
```

See `src/runtime/features.zig` for the set and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for what each proposal ships.

## Working on Cynic

Contributors — human or AI agent — should read
[`AGENTS.md`](AGENTS.md) for project conventions (tests-first,
prior-art surveys, spec-faithful naming) and pointers into the
engineering handbook under [`docs/handbook/`](docs/handbook/).

## Security

Security policy, in-scope / out-of-scope, and disclosure channel:
see [`SECURITY.md`](SECURITY.md).

## License

Cynic is [MIT-licensed](LICENSE). Bundled third-party data under
`vendor/` keeps its own license:

- `vendor/unicode/` — Unicode Character Database files
  (`UnicodeData.txt`, `SpecialCasing.txt`, `CaseFolding.txt`, the
  Derived / PropList / Scripts / emoji set, and `NormalizationTest.txt`
  for the conformance test). All under the Unicode, Inc. License
  Agreement. Upstream: <https://www.unicode.org/license.txt>.
- `vendor/test262/` — ECMAScript Test Suite, BSD-3-Clause (with
  Ecma International notices). Git submodule pinned to
  [`tc39/test262`](https://github.com/tc39/test262).
