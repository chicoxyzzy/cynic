# Triage test262 failures

Run the test262 conformance suite and analyze remaining failures.
The harness runs parse + compile + execute in one mode — parse-
negative fixtures (`negative.phase: parse`) resolve inline at
their parse phase and surface as `false-reject` / `false-accept`
in the per-fixture output, so a single sweep covers both classes
of failure.

1. Capture the failure list. For an exploratory run, `--only-failing`
   can skip the cached pass set:
   `zig build test262 -- --quiet --only-failing --list-failures=2000`
   (runtime is the default mode). Capture the output. If
   `.test262-pass-cache.txt` is stale (no recent full sweep of the same
   code and corpus),
   drop `--only-failing` and wrap the run in
   `tools/guarded-run.sh --timeout=1800 -- …` — it caps time +
   memory and kills the whole process tree (a bare `timeout`
   orphans the build / test subprocesses). A cached run is not a
   regression check or an authoritative score.

2. Parse out the failure paths and group by directory (everything
   before the basename). Show the top 10 directories by failure
   count, plus their per-bucket pass percentage from `test262-results.md`.

3. Pick the top 5 directories. For each:
   - Sample three distinct test files. Read each one (full file —
     frontmatter and body).
   - Identify the spec feature / abstract operation under test
     (cite the §X.Y.Z section).
   - Note whether the cluster is a runtime-semantics gap, a
     missing built-in method, a property-descriptor invariant
     issue, or an early-error / parser bug. Use the harness
     output labels (parser failures stay marked
     `false-reject` / `false-accept`).

4. For each group, propose **one concrete fix**:
   - File path under `src/runtime/builtins/`, `src/runtime/`,
     `src/bytecode/`, `src/parser/`, or `src/lexer/`.
   - What change is needed (missing branch, wrong coercion
     order, missing accessor walk, etc.).
   - Estimated test-count impact.

5. Report under 600 words. **Analysis only — do not implement.**

Read [the prior-art protocol](../handbook/prior-art.md)
before suggesting non-trivial fixes — survey how V8 / JSC /
SpiderMonkey handle the spec rule.
