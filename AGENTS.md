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
- **Strict-only, non-browser-host target.** Cynic targets edge
  runtimes (Workers / Deno / server JS) — not browsers. So:
  - **Annex B language extensions** — out (no sloppy mode, no
    labels, no HTML-like comments, no sloppy-mode function-in-
    block, no legacy octal, no for-in initializer).
  - **Annex B browser-era built-ins** — out where they're
    purely browser legacy: `escape` / `unescape` (broken-by-
    design for non-ASCII; `encodeURIComponent` is the answer);
    the 13 `String.prototype` HTML wrappers (`anchor` / `bold`
    / `blink` / etc. — wrap text in `<font>` tags, useless
    server-side); `Date.prototype.{getYear, setYear}` (Y2K-
    quirky year-minus-1900 format).
  - **Annex B normative aliases** — kept where they're widely
    used in real-world code or near-free aliases:
    `String.prototype.{substr, trimLeft, trimRight}`,
    `Date.prototype.toGMTString`. See later in
    [docs/ROADMAP.md](docs/ROADMAP.md).
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
threshold, default 4,096; lower values stress-test the GC
trigger but currently surface the four known root gaps in
[docs/handbook/gc.md](docs/handbook/gc.md)). The harness
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
the same mode; the most recent row also gets a "Biggest movers"
sub-list naming the buckets that shifted most.

**Build mode.** The test262 harness binary is built `ReleaseFast`
by default (interpreters are 5-10× slower in Debug; the harness
chews ~50k fixtures). Pass `-Doptimize=Debug` or
`-Dtest262-debug=true` if you need stack traces on a panic
inside the engine — that rebuilds both the harness and the
`cynic` library it links at Debug.

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

## Style & code health

- Comments cite the ECMA-262 section that motivates the code.
  `§13.3.1 NewTarget` beats `// new.target`.
- Diagnostics over panics: lexer and parser accumulate
  `Diagnostic` records; the harness scores against the JS error
  class via `Code.errorClass()`.
- Span discipline: every AST node carries the source range it
  spans. Spans drive the printer (golden tests) and diagnostics.
- Arena allocation per parse; no global state in the parser.
