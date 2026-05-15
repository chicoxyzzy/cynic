# Working on Cynic

Cynic is a strict-only ECMAScript engine in Zig, built from scratch.
This document is the entry point for any contributor — human or AI
agent (Claude Code, Codex, Cursor, Aider, …). Tools that don't read
this file by name can be pointed at it (`aider --read AGENTS.md`,
Cursor `.cursor/rules/*.mdc` referencing it, etc.); Claude Code
reads it via a one-line `CLAUDE.md` that imports this file.

## Project conventions

These are project rules — they apply to everyone.

- **Tests first.** Write failing tests before the production code
  that satisfies them. See [docs/handbook/tdd.md](docs/handbook/tdd.md).
- **Survey prior art** before non-trivial design choices. Look at
  V8, JavaScriptCore, SpiderMonkey, Hermes, QuickJS, XS, Boa; cite
  the ECMA-262 section; note any test262 / SES implications. See
  [docs/handbook/prior-art.md](docs/handbook/prior-art.md).
- **Spec-faithful naming.** Internal function names mirror
  ECMA-262 abstract operations so test262 failures map cleanly to
  spec sections.
- **Microtasks are spec-conformant.** Cynic ships a real
  microtask queue (see `realm.microtask_queue` and
  `interpreter.drainMicrotasks`). `.then` always defers — settled
  Promises queue the reaction at `.then` time, pending Promises
  register on the source and queue at settlement. The aggregators
  (`Promise.{all, allSettled, race, any}`) build a fresh
  capability via §27.2.1.5 NewPromiseCapability and forward each
  item via `Invoke(item, "then", « cap.resolve, cap.reject »)`,
  so user-installed `.then` reactions interleave per spec. Don't
  introduce new code paths that settle a Promise synchronously
  in user-observable order — Workers, Deno, and SES all rely on
  the spec ordering.
- **Strict-only, non-browser-host target.** Cynic targets edge
  runtimes (Workers / Deno / server JS) — not browsers. So:
  - **Annex B in its entirety** — out, with one acknowledged
    exception (regex grammar §B.1.4 — see below). No sloppy
    mode, no labelled function declarations (B.3.1), no
    HTML-like comments, no sloppy-mode function-in-block, no
    legacy octal, no for-in initializer. No `escape` /
    `unescape`, no String HTML wrappers, no `Date.prototype.
    {getYear, setYear, toGMTString}`, no `String.prototype.
    {substr, trimLeft, trimRight}`, no `Object.prototype.
    __proto__` accessor, no `Object.prototype.__define
    {Getter,Setter}__` / `__lookup{Getter,Setter}__`, no
    `RegExp.{$1, input, …}` legacy globals. The whole `annexB/`
    test262 tree is path-skipped; feature flags for browser-
    only constructs (`__proto__`, `__getter__`, `__setter__`,
    `legacy-regexp`, `IsHTMLDDA`) are not in the unsupported-
    features list because the fixtures using them parse fine
    — they show as honest runtime-mode failures.

    **Acknowledged exception — regex Annex B (§B.1.4).** The
    vendored libregexp (QuickJS-NG) accepts permissive forms
    like `\1` outside a capturing group (octal `\001`) and the
    lower-bound-elided quantifier `{,n}` when the pattern is
    compiled without `/u` or `/v`. Every shipping engine
    (V8 / JSC / SpiderMonkey) accepts the same forms — Annex B
    is normative spec and real-world regexes rely on these
    leaks. Closing it would mean patching vendored libregexp or
    adding a Cynic-side pattern pre-validator; we deemed the
    leak narrower than the policy and live with it. See
    [docs/ROADMAP.md](docs/ROADMAP.md) under "Regex".
  - **`eval` and runtime code construction** — out
    permanently. `eval()` itself, `new Function(string)` /
    `new GeneratorFunction(string)` / `new AsyncFunction(string)`,
    and dynamic-code-from-string generally aren't shipped.
    Aligns with [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses)
    and removes a major optimization fence. Cynic's host-level
    `Realm.evaluateScript` (powering multi-file `cynic run`,
    the test262 harness loader, and a future REPL) is a
    different mechanism — it's not exposed to user JS.
- **Unicode tracks `latest`.** §3 normatively references
  [`unicode.org/versions/latest`](https://unicode.org/versions/latest)
  (undated) and §12.7 says identifier-category code points "in
  the latest version of the Unicode Standard must be treated as
  in those categories by all conforming ECMAScript
  implementations." When a new Unicode version ships, drop the
  refreshed `DerivedCoreProperties.txt` into `vendor/unicode/`
  and run `zig build gen-unicode` to regenerate
  `src/unicode/ident_tables.zig`. Bumping is a spec-conformance
  task, not a cosmetic refresh.

## When you need to …

| Goal | Read |
|---|---|
| Understand the architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| See what's planned and what's done | [docs/ROADMAP.md](docs/ROADMAP.md) |
| Decide between two designs | [docs/handbook/prior-art.md](docs/handbook/prior-art.md) |
| Add a lexer / parser / runtime feature | [docs/handbook/tdd.md](docs/handbook/tdd.md), then [docs/handbook/compiler-engineering.md](docs/handbook/compiler-engineering.md) |
| Touch heap-allocating native code | [docs/handbook/gc.md](docs/handbook/gc.md) (`HandleScope` contract for natives that re-enter JS) |
| Look up a Zig idiom Cynic uses | [docs/handbook/zig.md](docs/handbook/zig.md) |
| Score current conformance | `zig build test262 -- --quiet`; history in [test262-results.md](test262-results.md) |
| Measure perf (micros) | `zig build bench` (or `/perf`); design in [docs/benchmarking.md](docs/benchmarking.md) |
| Find a hot function | `tools/profile.sh "<filter>"` (or `/profile`); requires `samply` |
| Find spec text | [tc39.es/ecma262](https://tc39.es/ecma262/) |
| Inspect test262 fixtures | `vendor/test262/test/<area>` |

## Build & test

Zig 0.17-dev (master) — the Zig project skipped a stable 0.16, so
CI tracks `master`. One-time setup:

    git submodule update --init vendor/test262

Common commands:

    zig build                                       # build cynic into zig-out/bin/
    zig build test                                  # all unit tests
    zig build test262                               # parser-only conformance run
    zig build run -- parse <file>                   # script-mode parse
    zig build run -- parse --module <file>          # module-mode parse (alias: -m)
    zig build run -- parse <file>.mjs               # `.mjs` auto-detected as module
    zig build run -- eval '<expr>'                  # compile + run a single expression
    zig build run -- run <file>                     # compile + run a script

`zig build test262` accepts forwarded flags after `--`:
`--filter=<substring>`, `--list-failures=<n>`, `--quiet`, `--verbose`,
`--mode={parser,runtime}` (default `parser`; `runtime` parses,
compiles, and executes each test), `--no-harness` (disable the
`sta.js` + `assert.js` preamble in runtime mode),
`--write-results` (updates `test262-results.md`),
`--only-failing` (skip-as-pass any test path listed in
`.test262-pass-cache.txt` — iterative-dev shortcut; cache is
rewritten only on full runs without `--filter` and without
`--only-failing` itself), `--threads=<n>` (worker count;
`0` = auto via `std.Thread.getCpuCount`, `1` = sequential
reference path, `>1` = pool. Past ~4 threads diminishing
returns kick in from libc malloc contention),
`--gc-threshold=<n>` (per-fixture allocation-pressure GC
threshold, default 32,768; lower values stress-test the GC
trigger but currently surface the known root gaps in
[docs/handbook/gc.md](docs/handbook/gc.md). `0` falls through
to the engine default of 16,384),
`--gc-stats` (per-realm one-line stderr report after every
GC cycle — pause time + per-pool live counts; pair with
`--filter` to keep output sane),
`--top-slow=<n>` (after the tally, print the N slowest
fixtures over 50ms — V8 / JSC both surface this; long-tail
outliers usually dominate sweep wall-time),
`--top-rss=<n>` (after the tally, print the N memory-heaviest
fixtures with per-fixture RSS deltas over 8 MiB — use this to
spot allocation pathologies and creeping leaks; pair with
`--filter` for a sharper signal),
`--leak-check` (route the per-fixture bytes allocator through
`std.heap.DebugAllocator` so every unfreed allocation prints a
stack trace at exit — turns "RSS climbed by 200 MiB" into "this
exact call site leaked N bytes." Forces `--threads=1` because
DebugAllocator isn't thread-safe; pair with `--filter`, the
full corpus under leak-check is 10-20× slower than ReleaseFast),
`--max-rss=<mb>` (abort the run with exit code 2 the moment
process RSS crosses the budget after a fixture — prints the
offending path. Use this to bound a sweep that's at risk of
hanging the laptop and get a fixture pointer to bisect from.
Forces `--threads=1`. Complement to `--leak-check`: max-rss
traps *when* growth crossed the budget, leak-check tells you
*what* was unfreed). The harness
scores against the **Cynic-targeted scope**: paths under
`harness/`, `staging/`, `intl402/`, Annex B language extensions,
and the browser-era built-ins Cynic doesn't ship are dropped from
`total` entirely. Re-running for the same `(date, mode)` replaces
that day's row. Each row records `spec%` (pass / total) and
`attempted%` (pass / (pass + fail)). `test262-results.md` opens
with a `## Current scores` snapshot, a `## Legend` explaining the
columns, a `## Where the runtime stands, by area` per-bucket
scoreboard sorted by raw fail count (so the top of the list is
where the most fixtures move with the least work), and a
`## History` section of per-day mini-tables — newest day first.
Each history row shows the `Δ pass` against the previous run of
the same mode and the `elapsed` wall-clock time of that run (full
sweeps only; partial / filtered runs leave it blank). The most
recent row also gets a "Biggest movers" sub-list naming the
buckets that shifted most.

**Build mode.** The test262 harness binary is built `ReleaseFast`
by default (interpreters are 5-10× slower in Debug; the harness
chews ~50k fixtures). Pass `-Doptimize=Debug` or
`-Dtest262-debug=true` if you need stack traces on a panic
inside the engine — that rebuilds both the harness and the
`cynic` library it links at Debug.

**Leak-check before every full sweep.** Past leaks (e.g. JSString
bytes pinned in the per-fixture arena before `7a6a0d8`) ballooned
full sweeps to multi-GB RSS and locked the laptop. The byte-trigger
GC in `Heap` (`bytes_since_gc` + 16 MB threshold, paired with a
split `bytes_allocator`) bounds per-fixture RSS today — but a new
allocation path can bypass it. Before kicking off a full
`zig build test262`, run a filtered sweep with `--top-rss` and
confirm the top per-fixture deltas are in the healthy band:

    zig build test262 -- --quiet --mode=runtime \
      --filter=language/expressions --top-rss=10

Healthy: top per-fixture deltas ≤ ~20 MiB on
`language/expressions`, ≤ ~50 MiB on `built-ins/TypedArray`. If
the deltas climb noticeably above that, STOP and bisect the
regressing commit with the same filter before starting the full
sweep. Do NOT use `/usr/bin/time -l` for this — it measures
`zig build`'s RSS (the compile-and-fork wrapper, which holds
~1 GB during link), not the harness, and is wildly misleading.
For a stricter guard pair the filter with `--max-rss=<mb>` or
`--leak-check` (DebugAllocator); see flag table above.

**Fast iteration with `--only-failing`.** A full runtime sweep is
~100 s; that's too long to run after every fix. Use the cached
pass-set instead: any full sweep with `--write-results` populates
`.test262-pass-cache.txt` (~34 k known-passing fixtures). The
next run with `--only-failing` skip-as-passes those, so it only
executes the ~7 k failing/skipped tests — typically ≤ 30 s.

Iteration loop for a triage-and-fix session:

    # Baseline. Tighten the filter as much as you can.
    zig build test262 -- --quiet --mode=runtime \
      --filter=<narrowest pattern>

    # Per-fix verification (filter + --only-failing).
    zig build test262 -- --quiet --mode=runtime \
      --filter=<bucket root> --only-failing

    # Leak check.
    zig build test262 -- --quiet --mode=runtime \
      --filter=<bucket root> --top-rss=10

    # Session-end full sweep (no filter, no --only-failing —
    # this refreshes the cache for the next session).
    zig build test262 -- --quiet --mode=runtime --write-results

    # Between agent batches, when you only want to refresh the
    # cache (no score row): drop --write-results. Same full sweep
    # but no edit to `test262-results.md`. Refreshes the cache
    # for the next agent in ~100 s.
    zig build test262 -- --quiet --mode=runtime

The `--only-failing` cache won't surface a regression that flips
a previously-passing fixture to fail outside the touched bucket
— a session-end full sweep is the safety net. Don't use
`--only-failing` for score rows; they must be authoritative.

CI runs `zig build` and `zig build test` as gating jobs, plus
`zig build test262 -- --quiet` as an advisory job
([.github/workflows/ci.yml](.github/workflows/ci.yml)). A
test262 score regression isn't a CI failure today — that's
reviewed in PRs against `test262-results.md`.

## Repository map

    src/         lexer, parser, AST, bytecode, runtime, CLI — see README.md
                 for the per-file breakdown
    src/runtime/          Engine internals — heap-side data structures
                          (`value.zig`, `heap.zig`, `string.zig`, `function.zig`,
                          `object.zig`, `symbol.zig`, `bigint.zig`,
                          `generator.zig`, `environment.zig`, `module.zig`,
                          `class.zig`), the interpreter (`interpreter.zig`),
                          the realm (`realm.zig`), and the built-in
                          orchestrator (`intrinsics.zig`).
    src/runtime/builtins/ JS-visible API surface, one file per global /
                          prototype family. Each exports `pub fn install(realm)`
                          (or named installers) wired from `intrinsics.install`.
                          Adding a JS-callable method? It goes here.
    tools/       gen_unicode_idents.zig (regenerates UCD tables);
                 test262/ (frontmatter + skip rules);
                 test262.zig (conformance harness, parser + runtime modes)
    vendor/      pinned third-party data (UCD; test262 git submodule)
    docs/        ARCHITECTURE.md, ROADMAP.md, handbook/

**`runtime/<X>.zig` vs `runtime/builtins/<X>.zig`** — five names overlap
(`bigint`, `function`, `object`, `string`, `symbol`). The split is along
data-vs-API:

- **`runtime/<X>.zig`** holds the `JSX` Zig struct — fields, allocator-
  aware `init` / `deinit`, internal getters/setters. The interpreter,
  heap, and realm touch these directly.
- **`runtime/builtins/<X>.zig`** holds the JS spec surface — the global
  constructor body, the `<X>.prototype.*` methods, the statics, plus
  a `pub fn install(realm)` that wires everything to the realm at
  startup.

Rule of thumb: if you'd reach for it from inside the opcode dispatch,
it's `runtime/`. If it's only invoked because user JS called a built-in,
it's `builtins/`.

## Repeatable workflows

For Claude Code users these are slash commands under
[`.claude/commands/`](.claude/commands/); the markdown files describe
the workflow plainly and any agent or human can follow them by hand.

| Workflow | What it does | File |
|---|---|---|
| `/triage` | Survey current test262 failures, group by pattern, suggest fixes (analysis only) | [.claude/commands/triage.md](.claude/commands/triage.md) |
| `/score` | Append a fresh score row to `test262-results.md`, report the delta | [.claude/commands/score.md](.claude/commands/score.md) |
| `/bump-test262` | Bump the test262 submodule to upstream HEAD, rerun, score (do not commit) | [.claude/commands/bump-test262.md](.claude/commands/bump-test262.md) |
| `/perf` | Run the Phase 1 micro-bench suite; report per-fixture medians + RSS | [.claude/commands/perf.md](.claude/commands/perf.md) |
| `/profile` | Sample a `--filter`-scoped test262 sweep under `samply`; emit a top-N hot-function list (needs `samply` on PATH) | [.claude/commands/profile.md](.claude/commands/profile.md) |

## Style & code health

- Comments cite the ECMA-262 section that motivates the code.
  `§13.3.1 NewTarget` beats `// new.target`.
- Diagnostics over panics: lexer and parser accumulate
  `Diagnostic` records; the harness scores against the JS error
  class via `Code.errorClass()`.
- Span discipline: every AST node carries the source range it
  spans. Spans drive the printer (golden tests) and diagnostics.
- Arena allocation per parse; no global state in the parser.
