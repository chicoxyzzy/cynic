# Cynic

A strict-only ECMAScript engine, written from scratch in Zig.

Cynic targets non-browser hosts — edge runtimes, Workers, server-side JS
— and omits browser-era legacy by design:

- **No sloppy mode.** Every source is parsed as strict. The strict
  reserved-word set, restricted assignment to `eval` / `arguments`, and
  the absence of `with`, labels, legacy octal, HTML-like comments, and
  Annex B *language* extensions (sloppy-mode-only function-in-block,
  `for-in` initializer, …) are baked in at the language level.
- **No browser-era built-ins.** `escape` / `unescape`, the 13
  `String.prototype` HTML wrappers (`anchor`, `bold`, …), and
  `Date.prototype.{getYear, setYear}` aren't shipped. The normative
  aliases real-world code actually uses
  (`String.prototype.{substr, trimLeft, trimRight}`,
  `Date.prototype.toGMTString`) are kept.
- **No runtime code construction.** `eval`, `new Function(string)`,
  `new GeneratorFunction(string)`, `new AsyncFunction(string)`. Aligns
  with [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses).

## Goals

- Track the spec faithfully — internal function names mirror ECMA-262
  abstract operations so test262 failures map cleanly to spec sections.
- Pass the strict subset of [test262](https://github.com/tc39/test262).
- Draw inspiration from production engines — V8 (Ignition + Sparkplug +
  Maglev + TurboFan), JavaScriptCore (LLInt + Baseline + DFG + FTL), and
  SpiderMonkey (Bytecode interp + Baseline Interp + Baseline Compiler +
  WarpMonkey) — without copying any one of them. Smaller engines like
  Hermes (AOT bytecode) and QuickJS (compact single-tier) are useful
  reference points; we vendor QuickJS-NG's `libregexp.c` for §22.2 RegExp.
  The plan is a clean bytecode interpreter first — **Lantern** (T0) —
  then tiered compilation: a baseline JIT (**Bistromath**, T1) and an
  optimizing JIT (**Ohaimark**, T2). The garbage collector is **Metla**.
  The exact tier shape stays open until we have working measurements
  against Lantern.
- Stay friendly to [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses)
  and the [Compartments](https://github.com/tc39/proposal-compartments) direction
  — strict-only and no Annex B *language* extensions already align Cynic
  with that world (the few normative Annex B *built-ins* we ship are
  trivial to omit per-realm); runtime design will keep tamper-proof
  primordials and Compartment-style isolation in mind.

## Status

Pre-alpha. Lexer + parser + Lantern (the T0 bytecode interpreter) ship,
with Metla (mark-sweep GC) underneath; the runtime is filling in.
The JIT tiers (Bistromath, Ohaimark) and generational GC are future
work. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the thematic breakdown.

### Conformance

Current scores, history, and per-bucket breakdown live in
[`test262-results.md`](test262-results.md). `spec%` is coverage
of the (Cynic-targeted) corpus; `attempted%` is the quality of
what's shipped, ignoring skips. Plus 700+ unit tests
(`zig build test`).

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
  `Reflect`, ES2025 `Set` ops (`union` / `intersection` / …),
  `Iterator` helpers (`map` / `filter` / `take` / `drop` /
  `flatMap` / etc.),
  `Proxy` (most traps), `Date` (UTC-only), the URI globals, the
  standard error hierarchy with `error-cause`.
- **TypedArrays** — `ArrayBuffer`, `DataView`, the typed-array
  family backed by the canonical `%TypedArray%.prototype`.
- **RegExp** — full ECMA-262 via vendored QuickJS-NG `libregexp.c`
  (named groups, lookbehind, `u` / `v` flags, indices). String
  methods dispatch through it.
- **Promises & async/await** — full chaining (settled and pending),
  pending-await suspension via `JSGenerator` capture, async
  generators with promise-reaction chaining, `Promise.try` and
  `Promise.withResolvers`.
- **Tooling** — `cynic parse | eval | run` plus a parallel test262
  harness with `--threads=N`, `--only-failing` cache, and a
  per-area scoreboard.

Internals: NaN-boxed values, Ignition-style register-file +
accumulator bytecode, stop-the-world mark-sweep heap fired on
allocation pressure (the heap stays bounded under any allocating
loop / recursion / promise chain — see
[`docs/handbook/gc.md`](docs/handbook/gc.md) for the trigger and
the `HandleScope` contract for natives).

### Known gaps

The big shaped items: top-level `await` in modules; the multi-file
module graph beyond single-file evaluation (cyclic imports, namespace
exotic, live mutable bindings — dynamic `import()` itself works);
async-generator yield-star resume-arg forwarding + `AsyncIteratorClose`
with `await`; `Array.fromAsync`; resizable-ArrayBuffer length-tracking
view semantics across the TypedArray prototype; generational GC; the
timezone story behind `Date` (UTC-only today);
`String.prototype.normalize` (passthrough — needs UCD tables);
`Set.prototype.{union, intersection, difference, …}` (ES2025). Each
takes a swing at the runtime score as it lands; the scoreboard in
[`test262-results.md`](test262-results.md) is the source of truth.

Proper Tail Calls (PTC, ES2015 §15.10) ship behind the
`tail-call-optimization` feature flag — opt in with
`cynic --enable=tail-call-optimization run foo.js`. Off-by-default
because `Error.stack` loses the eliminated frames per spec; on, Cynic
is the second engine shipping spec-mandated PTC alongside JSC.

## Build

```sh
git submodule update --init vendor/test262   # one-time; needed for `zig build test262`

zig build              # build cynic into zig-out/bin/
zig build test         # run all unit tests
zig build test262      # test262 conformance (runtime mode by default; main + every pre-Stage-4 feature phase when --write-results is set)
zig build run -- lex   path/to/file.js              # tokenize and print
zig build run -- parse path/to/file.js              # parse a Script
zig build run -- parse --module path/to/file.js     # parse a Module
zig build run -- parse path/to/file.mjs             # .mjs ⇒ module
zig build run -- eval  '1 + 2 * 3'                  # compile + run an expression
zig build run -- run   path/to/file.js              # compile + run a script
zig build run -- run   a.js b.js c.js               # multiple files share one realm
```

Requires Zig **0.17-dev** (master). The Zig project skipped a stable
0.16, so CI tracks `master` via `mlugg/setup-zig`. If your local
`zig version` reports an older dev tag, bump it.

The `cynic` CLI keeps pre-Stage-4 / experimental TC39 proposals off
by default — embedders see only stable ECMA-262. Opt in:

```sh
cynic --list-features                       # show available proposals
cynic --enable=joint-iteration eval '...'   # one feature
cynic --enable-experimental run foo.js      # all tracked features
cynic --disable=upsert eval '...'           # repeatable; later flags win
```

See `src/runtime/features.zig` for the set and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for what each proposal ships.

`zig build test262` accepts forwarded flags after `--`:

- `--filter=<substring>` — run only matching paths.
- `--list-failures=<n>` — print the first `n` failing paths after the tally.
- `--mode={runtime,parser}` — full parse → compile → execute (default), or parser-only.
- `--phase=<spec>` — pin the harness to a single sweep. `--phase=main` is the headline ECMA-262 sweep (pre-Stage-4 fixtures excluded); `--phase=feature:<name>` (e.g. `feature:joint-iteration`, `feature:upsert`) runs only that proposal's dedicated isolated sweep. Default: just main, unless `--write-results` is set — then main + every tracked feature run in sequence.
- `--quiet` / `--verbose` — progress noise dial.
- `--no-harness` — skip the `sta.js` + `assert.js` preamble in runtime mode (for measuring the floor).
- `--threads=<n>` — worker count (`0` = auto, `1` = sequential, `>1` = pool).
- `--only-failing` — skip-as-pass any path in `.test262-pass-cache.txt`. After a full sweep populates the cache, the next iteration runs only the ~7 k failing/skipped fixtures — ≤ 30 s vs ≤ 100 s. Don't use for score rows; use it for per-fix verification.
- `--gc-threshold=<n>` — per-fixture allocation-pressure GC threshold (default 32,768; engine default 16,384). `0` falls through to the engine default. The engine also has a 16 MiB byte trigger so allocate-and-discard patterns GC promptly regardless of count.
- `--write-results` — update `test262-results.md` with today's row for the given mode. Re-running the same `(date, mode)` replaces that day's row rather than appending. The default run never touches that file.
- **Memory / leak instrumentation:** `--gc-stats` (per-cycle pool counts + bytes), `--mem-summary` (end-of-sweep totals: cumulative bytes, max charged peak, GC cycles), `--top-rss=<n>` (top-N fixtures by process RSS delta ≥ 8 MiB), `--top-alloc=<n>` (top-N by cumulative bytes allocated ≥ 64 KiB — catches GC-cleaned thrash that RSS hides), `--leak-check` (route per-fixture bytes allocator through `std.heap.DebugAllocator`; stack trace per unfreed allocation), `--max-rss=<mb>` (abort with the offending path when RSS crosses budget).

The Unicode `ID_Start` / `ID_Continue` tables are committed under
`src/unicode/ident_tables.zig` (currently Unicode 17.0). ECMA-262 §3
references `unicode.org/versions/latest`, so we track upstream:
drop a refreshed `DerivedCoreProperties.txt` into `vendor/unicode/`
and run `zig build gen-unicode` to regenerate.

## Working on Cynic

Contributors — human or AI agent — should read
[`AGENTS.md`](AGENTS.md) for project conventions (tests-first,
prior-art surveys, spec-faithful naming) and pointers into the
engineering handbook under [`docs/handbook/`](docs/handbook/).

## License

Cynic is [MIT-licensed](LICENSE). Bundled third-party code under
`vendor/` keeps its own license:

- `vendor/quickjs/` — QuickJS-NG (`libregexp` + `libunicode`), MIT,
  © 2017–2018 Fabrice Bellard, © 2023+ QuickJS-NG contributors.
  Upstream: <https://github.com/quickjs-ng/quickjs>.
- `vendor/unicode/` — Unicode Character Database
  (`DerivedCoreProperties.txt`), under the Unicode, Inc. License
  Agreement. Upstream: <https://www.unicode.org/license.txt>.
- `vendor/test262/` — ECMAScript Test Suite, BSD-3-Clause (with
  Ecma International notices). git submodule pinned to
  `tc39/test262`. Upstream: <https://github.com/tc39/test262>.
