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

- **Strings are UTF-16 code units at the JS level; WTF-8 at the
  storage level.** ECMA-262 §6.1.4 specifies the String type as
  "the set of all ordered sequences of zero or more 16-bit
  unsigned integer values"; §22.1.5 makes `length` the code-unit
  count, and every position argument on `String.prototype.*`
  (`charAt`, `slice`, `indexOf`, `padStart`, …) is a code-unit
  index. Cynic stores `JSString.bytes` as WTF-8 — UTF-8 with
  CESU-8 surrogate escapes (3-byte `0xED 0xA[0-F] 0x[8-B][0-F]`
  encodes a lone surrogate; valid surrogate pairs encode as the
  4-byte UTF-8 form of the supplementary code point). This means
  one UTF-16 code unit corresponds to either a 1/2/3-byte UTF-8
  sequence (one code unit) or half of a 4-byte sequence (two
  code units per supplementary character).

  Position-aware `String.prototype.*` methods MUST use
  `src/runtime/utf16.zig`'s helpers
  (`lengthInCodeUnits`, `byteIndexForCodeUnit`,
  `codeUnitIndexForByte`, `codeUnitAt`, `sliceCodeUnits`,
  `appendCodeUnitAsWtf8`) to translate between byte offsets and
  code-unit indices. The `slice` / `substring` family handles
  the mid-pair-surrogate case: cutting through a 4-byte UTF-8
  character at an odd code-unit boundary yields a lone-surrogate
  WTF-8 string the helpers can build.

  Methods that don't dereference positions — `concat`,
  `toLowerCase`, `toUpperCase`, `trim*`, `repeat`,
  `normalize` (passthrough today) — pass WTF-8 bytes through
  unchanged. Symbol-dispatched methods (`split`, `replace`,
  `replaceAll`, `match`, `matchAll`, `search`) route into
  libregexp via the bridge, which has its own UTF-16 view
  built in — don't reinvent code-unit arithmetic there.

  When adding or fixing a String.prototype method, cite the
  spec section (§22.1.3.x) and use the helpers; never index
  raw `bytes`.

## When you need to …

| Goal | Read |
|---|---|
| Understand the architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| See what's planned and what's done | [docs/ROADMAP.md](docs/ROADMAP.md) |
| Decide between two designs | [docs/handbook/prior-art.md](docs/handbook/prior-art.md) |
| Add a lexer / parser / runtime feature | [docs/handbook/tdd.md](docs/handbook/tdd.md), then [docs/handbook/compiler-engineering.md](docs/handbook/compiler-engineering.md) |
| Touch heap-allocating native code | [docs/handbook/gc.md](docs/handbook/gc.md) (`HandleScope` contract for natives that re-enter JS) |
| Touch binding / scope / top-level resolution | [docs/handbook/environments.md](docs/handbook/environments.md) (GlobalEnvironmentRecord split, named-fn-expr wrapper, module env-record, top-level write opcodes) |
| Verify a shared-machinery change without missing regressions | [docs/handbook/agent-checks.md](docs/handbook/agent-checks.md) (the `--only-failing` trap, per-touch bucket filters, harness threading invariant) |
| Look up a Zig idiom Cynic uses | [docs/handbook/zig.md](docs/handbook/zig.md) |
| Score current conformance | `zig build test262 -- --quiet`; history in [test262-results.md](test262-results.md) |
| Measure perf (micros) | `zig build bench` (or `/perf`); design in [docs/benchmarking.md](docs/benchmarking.md) |
| Find a hot function | `tools/profile.sh "<filter>"` (or `/profile`); requires `samply` |
| See engine memory shape | `zig build test262 -- --filter=<x> --mem-summary --top-alloc=10` (engine-side counters) |
| Profile allocations with call stacks (macOS) | `xcrun xctrace record --template Allocations --launch -- <path-to-test262-binary> --filter=<x>` |
| Find spec text | [tc39.es/ecma262](https://tc39.es/ecma262/), or via the `tc39` MCP server in `.mcp.json` — `search_spec` / `get_spec_section` (also `list_proposals`, `search_notes`) |
| Inspect test262 fixtures | `vendor/test262/test/<area>` |

## Build & test

Zig 0.17-dev — pinned to a specific dev SHA in both `build.zig.zon`
(`.minimum_zig_version`, read by [anyzig](https://github.com/marler8997/anyzig))
and `.github/workflows/ci.yml` (`version:`). Bump both in
lockstep when a Zig parser/codegen change forces it (use
`anyzig` locally so `zig build` resolves to the pinned SHA).
One-time setup:

    git submodule update --init vendor/test262

Common commands:

    zig build                                       # build cynic into zig-out/bin/
    zig build test                                  # all unit tests
    zig build test262                               # full conformance run (runtime mode)
    zig build run -- parse <file>                   # script-mode parse
    zig build run -- parse --module <file>          # module-mode parse (alias: -m)
    zig build run -- parse <file>.mjs               # `.mjs` auto-detected as module
    zig build run -- eval '<expr>'                  # compile + run a single expression
    zig build run -- run <file>                     # compile + run a script

The `cynic` CLI defaults pre-Stage-4 / experimental TC39
proposals (currently `joint-iteration`, `upsert`) to off so
embedders see only stable ECMA-262. Opt in:

    cynic --enable=<name> run foo.js                # one feature
    cynic --enable-experimental run foo.js          # all tracked features
    cynic --list-features                           # show available + descriptions

See `src/runtime/features.zig` for the full list and
[docs/ROADMAP.md](docs/ROADMAP.md) under "Pre-Stage-4 proposals
shipped" for what each ships. The test262 harness independently
flips every tracked flag on inside the per-feature dedicated
sweeps.

`zig build test262` accepts forwarded flags after `--`:
`--filter=<substring>`, `--list-failures=<n>`, `--quiet`, `--verbose`,
`--mode={runtime,parser}` (default `runtime`; runs parse +
compile + execute. Pass `--mode=parser` for parser-only iteration),
`--phase=<spec>` (`main` runs the headline ECMA-262 sweep with
pre-Stage-4 fixtures excluded; `feature:<name>` runs only that
proposal's dedicated isolated sweep — only its realm flag on,
only its tagged fixtures included. Default: just main, unless
`--write-results` is set — then main + every tracked feature
run in sequence), `--no-harness` (disable the
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
trigger. The historical root gaps documented in
[docs/handbook/gc.md](docs/handbook/gc.md) have been closed
(frame stacks, promise reactions, key anchors); a residual at
`gc_threshold=1` would be a new native missing a `HandleScope`.
`0` falls through to the engine default of 16,384, paired with
a 16 MiB byte trigger),
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
*what* was unfreed),
`--mem-summary` (end-of-sweep one-pager: cumulative bytes
allocated, max per-fixture charged peak, total GC cycles +
pause time, avg bytes per fixture. Reads engine-side
`Heap.bytes_alloc_total` etc. — different signal from RSS
which includes binary/libc/allocator slack. Forces
`--threads=1`),
`--top-alloc=<n>` (top-N fixtures by cumulative bytes
allocated ≥ 64 KiB. Catches allocate-and-discard thrash that
`--top-rss` misses — e.g. a fixture with 1 GiB cumulative
alloc but 10 MiB peak live (all freed by GC) is invisible in
RSS but obvious here. Forces `--threads=1`),
`--top-gc-time=<n>` (top-N fixtures by accumulated GC pause
time ≥ 1 ms. Different signal from `--top-alloc` — surfaces
fixtures whose wall-time is dominated by GC even when bytes
look moderate. Forces `--threads=1`). The harness
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

    zig build test262 -- --quiet \
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
    zig build test262 -- --quiet \
      --filter=<narrowest pattern>

    # Per-fix verification (filter + --only-failing).
    zig build test262 -- --quiet \
      --filter=<bucket root> --only-failing

    # Leak check.
    zig build test262 -- --quiet \
      --filter=<bucket root> --top-rss=10

    # Session-end full sweep (no filter, no --only-failing —
    # this refreshes the cache for the next session, and runs the
    # main phase + every pre-Stage-4 feature phase in one go).
    zig build test262 -- --quiet --write-results

    # Between agent batches, when you only want to refresh the
    # cache (no score row): drop --write-results. Same main-phase
    # sweep but no per-feature phases and no edit to
    # `test262-results.md`. Refreshes the cache for the next
    # agent in ~100 s.
    zig build test262 -- --quiet

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

## Upstream-gap log

When a fix lands for a bug that **no existing test262 fixture catches**
— either because the bug surfaces in a path the spec covers but
the corpus doesn't exercise, or because it's an engine-shape bug
(crash, memory safety, observable side effect ordering) outside
the corpus's reach — add an entry to
[docs/test262-upstream-gaps.md](docs/test262-upstream-gaps.md).

The log exists so we can later contribute fixture(s) back to
[`tc39/test262`](https://github.com/tc39/test262) covering each
gap. Every entry should include:

- the commit SHA that fixed the bug in Cynic;
- the ECMA-262 section the bug touched (cite `§X.Y.Z`);
- a minimal JS reproducer (8-15 lines);
- the expected vs. observed behaviour pre-fix;
- a one-line note on what shape the test262 fixture would take
  (positive / negative, runtime / parser, async-flagged, …).

Bugs that *are* covered by an existing test262 fixture don't go
in the log — the harness already exercises them.

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

## Website voice

`gh-pages/index.html` is the project's marketing surface and it
has a *voice* — deadpan, self-deprecating, technically precise,
slightly hostile to JavaScript-as-marketed. Preserve it. Any
edit landing on the `gh-pages` branch must read like the rows
already there. The brand is "Cynic doesn't oversell itself and
gently distrusts everything else."

What that looks like:

- **Concrete claims, casual register.** "Works." beats "✓
  Implemented per spec." "Don't ship anything to prod, frankly."
  beats "Production readiness is not yet guaranteed."
- **Match the existing patterns** in the status table — short
  middle column ("Works." / "Mostly." / "In progress." /
  "Future Cynic's problem."), one-line right-column with a
  technical jab. Look at sibling rows before writing.
- **Self-aware about caveats.** "Surprisingly. We checked." —
  "All the views. All the bytes. None of the drama." — "The
  plan is real. The plan is also not the code." Cite the
  uncertainty; let the reader decide.
- **No hype words.** No "blazingly fast", no "production-ready",
  no "10×", no "enterprise". The site explicitly avoids
  benchmark theatre.
- **Spec sections are fair game.** "Returns ReferenceError on
  uninit lex bindings, like the spec asked." Concrete §X.Y.Z
  pointers are on-brand because they signal precision without
  performing it.
- **Numbers only when stable.** Avoid hard pass-counts like
  "987 unit tests" or "89% spec" in the body — they go stale
  within days. Phrasings like "A lot." or "Getting there.
  Bigger than last week. Smaller than next week." stay true
  across sweeps. The `test262-results.md` link at the bottom
  carries the live numbers.
- **No emoji.** No exclamation points. No call-to-action
  buttons. The hero already does the work.

When in doubt: read the existing site top to bottom before
proposing copy. The voice is unmistakable, and a tone slip
reads louder than a missing feature.

(See also the memory rule: never edit `gh-pages` without
explicit user approval; surface the proposed diff as a
separate question first.)
