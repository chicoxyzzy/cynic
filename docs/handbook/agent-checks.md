# Regression checks for agent commits

When an agent (or human) lands a change that touches shared
compiler / runtime / harness machinery, the verification step
must be able to detect **new failures**, not just confirm that
previously-failing tests still fail. The default test262
iteration cadence — `--only-failing` against the pass cache —
cannot do that. This page is the protocol the project expects
before declaring "no regressions."

## The `--only-failing` trap

`zig build test262 -- --only-failing` skip-as-passes every
fixture listed in `.test262-pass-cache.txt`. The cache is
written by the most recent full sweep; it lists tests that
were passing then. After an edit, `--only-failing` re-runs
only the tests outside the cache — i.e. the previously-failing
or previously-skipped ones.

A test that **used to pass and now fails** is still in the
cache. `--only-failing` skips it. The fail count looks
unchanged. The regression is invisible.

This trap ate hours of debugging once a 800-LOC
GlobalEnvironmentRecord split shipped with a silent
const-destructuring regression: the agent's
`--filter=language/statements/const --only-failing` reported
"5 fail (all pre-existing)" — true within the cache, but the
full sweep then surfaced **56 fail** in the same bucket
because 51 newly-broken `const/dstr/*` fixtures were invisible
to the filter.

## Protocol

Before declaring a touch complete:

1. **Capture a pre-edit baseline.** From the *unedited* tree,
   run a *non-`--only-failing`* filter over the bucket(s)
   adjacent to the change. Record `pass` and `fail` counts.

   ```
   zig build test262 -- --quiet --filter=<bucket>
   ```

2. **Run the same filter post-edit.** Same flags, same
   bucket. Compare. If `pass` goes DOWN at all, investigate
   *before* moving on. A net-positive run with a small
   regression in a sub-bucket is still a regression — the
   sweep happens to mask it under wider gains.

3. **For flaky-by-history buckets, disambiguate with
   `--threads=1`.** `language/module-code` and
   `language/expressions/dynamic-import` were historically
   raced by the worker pool sharing `loader_state` (now
   fixed). If a bucket's count differs between two runs at
   the default thread count, confirm with `--threads=1`
   before assuming it's a real change.

4. **Session-end full sweep.** `--only-failing` is fine for
   the per-fix verification loop; a full
   `zig build test262 -- --quiet --write-results` at session
   end is the safety net that catches anything #1-3 missed
   plus refreshes the cache.

## Buckets to filter per touch type

Pick the bucket(s) that exercise the codepath you changed.
These are starting points, not exhaustive — when in doubt,
widen.

| Touch | Bucket filter |
|---|---|
| `src/bytecode/compiler.zig` (binding / scope) | `language/statements/{var,let,const,class}`, `language/expressions/{function,arrow-function,class}` |
| `src/runtime/realm.zig` | `language/{module-code,global-code}`, `built-ins/Object/keys`, `built-ins/Object/getOwnPropertyNames` |
| `src/runtime/interpreter.zig` (opcode) | the wider `language/` tree, plus the built-ins area whose semantics that opcode runs |
| `src/runtime/builtins/X.zig` | `built-ins/X` + any `language/expressions` / `language/statements` that dispatch into it |
| `src/runtime/module.zig` | `language/module-code`, `language/expressions/dynamic-import` |
| `src/lexer/` or `src/parser/` | `language/` entire (a parse change can affect any bucket) |
| `tools/test262/skip.zig` | none — but eyeball `total` count delta in the next sweep |
| `tools/test262.zig` harness | the whole sweep; harness changes can change *what counts as a pass* |

## The harness threading invariant

Any module-scope `var` in `tools/test262.zig` that the test
runner mutates per-fixture **must** be `threadlocal`. Workers
share the address space; a process-global reads/writes race
when two workers are mid-fixture. Today's example was the
`loader_state` slot used by `test262ModuleLoader` for
sibling-specifier resolution — a single non-`threadlocal`
slot served all workers and resolved imports against
whichever fixture was most recently set, producing
9 fail-and-pass-and-fail cycles per `module-code` run.

The rule generalises: in `tools/test262.zig`, anything written
inside `classifyAndRun` (or a callback installed on the realm
that reaches back into the harness) must be either passed
through the call chain or marked `threadlocal`. Process
globals are reserved for read-only data initialised before
the worker pool spawns.

## Why not always single-thread

Single-thread mode is the cleanest signal but ~4× slower
(~8 min instead of 2 m). The parallel pool is the default
because most fixtures are independent — the engine
constructs a fresh `Realm` per fixture, and worker arenas are
independent. As long as the harness keeps the "process
globals are read-only" invariant, parallel produces the same
counts as single-thread. The bug isn't in the policy, it's in
breaches of the policy; surface and fix the breach.
