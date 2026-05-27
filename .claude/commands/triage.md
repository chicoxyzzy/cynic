---
description: Survey current test262 failures, group by pattern, suggest fixes (analysis only)
---

Run the test262 conformance suite and analyze remaining failures.
The harness runs parse + compile + execute in one mode — parse-
negative fixtures (`negative.phase: parse`) resolve inline at
their parse phase and surface as `false-reject` / `false-accept`
in the per-fixture output, so a single sweep covers both classes
of failure.

1. Capture the failure list — pair `--only-failing` with the
   harness so this run skip-as-passes the ~34 k cached pass-set
   and finishes in ≤ 30 s (vs ~100 s for a full sweep):
   `zig build test262 -- --quiet --only-failing --list-failures=2000`
   (runtime is the default mode) and capture the output. If
   `.test262-pass-cache.txt` is stale (no recent full sweep),
   drop `--only-failing` and wrap the run in
   `tools/guarded-run.sh --timeout=1800 -- …` — it caps time +
   memory and kills the whole process tree (a bare `timeout`
   orphans the build / test subprocesses).

2. Parse out the failure paths and group by directory (everything
   before the basename). Show the top 10 directories by failure
   count, plus their per-bucket spec% from `test262-results.md`.

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

Read [docs/handbook/prior-art.md](../../docs/handbook/prior-art.md)
before suggesting non-trivial fixes — survey how V8 / JSC /
SpiderMonkey handle the spec rule.
