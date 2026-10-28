# Session checkpoint

Review verification, refresh affected reports, and check documentation at the
end of a work session. Use this procedure directly; it is not an agent command
or an executable script. Do not stage, commit, or push unless asked.

## 1. Decide what needs a run

Start with `git status --short` and the session's changes. Preserve unrelated
edits. For each report, inspect its recorded revision, corpus, host, posture,
and last update, then compare the relevant inputs with the current tree.
Uncommitted changes count too. If a report is absent or its provenance is
unclear, it is not a verified baseline.

| Check | Relevant inputs | Procedure / output |
|---|---|---|
| Conformance | `src/`, `build.zig`, toolchain pin, `tools/test262*`, `vendor/test262` | [Score](score.md); `test262-results.md` |
| Focused performance | Changed runtime/compiler mechanism and its fixtures | [Performance](perf.md); summary in the owning design document |
| Cross-engine performance | Runtime/JIT batch, fixtures, runner, peer versions, or host change | [Benchmarking](../benchmarking.md); `bench-cross-results.md` |
| Wasm conformance / performance | Wasm engine, JS bridge, metering, compiler, fixtures, or runner | [Wasm engine](../wasm-engine.md); `wasm-results.md`, `wasm-bench-results.md` |
| WPT Wasm JS API | Bridge, importer, runner, baselines, or corpus | [WPT](../wpt.md); `wpt-results.md` |

Skip irrelevant reruns and say why. When the user explicitly requests a full
refresh, run the applicable checks even if inputs look unchanged. Do not
declare a regression gate satisfied by `--only-failing`, matching aggregate
counts, or an old result file; use the full verification posture required by
[the regression protocol](../handbook/agent-checks.md).

## 2. Run the affected checks

- Conformance: follow [Score](score.md), including the memory precheck. Keep
  exact pass-list comparisons when establishing that no fixtures regressed.
- Performance: use a quiet, consistent host and the current
  [measurement protocol](../benchmarking.md#measurement-protocol). Keep
  interpreter-only and full-speed results separate. Print noise and failed
  samples instead of hiding them.
- Use the optional [remote runner](../../tools/bench/README.md) when configured
  and suitable. It measures published refs, not local uncommitted changes.
  Record the actual revision and do not implicitly publish work to run it.
- Respect resource limits and use `tools/guarded-run.sh` for long local runs.
  No agent-local hook or particular remote host is required.

Do not recreate routine snapshots in `bench-results.md`; it is an archive.
Record A/B conclusions beside the design decision and peer-facing snapshots
in `bench-cross-results.md`, following
[results ownership](../benchmarking.md#results-artifacts). A flat microbench
does not prove that macro workloads or peer versions are unchanged.

Write benchmark output to a temporary location first. Replace a tracked
snapshot only after the run finishes and the measurements are usable. If a
run is interrupted or contaminated, retain the prior snapshot and report the
problem. Never use a blanket checkout/reset to discard result-file edits.

## 3. Audit documentation and workflows

Inspect the documents affected by the work:

- `docs/ROADMAP.md`: shipped versus planned status.
- The owning subsystem document and `docs/handbook/`: current contracts.
- `AGENTS.md`: flags, commands, and invariants.
- `docs/benchmarking.md`: measurement protocol and report ownership.
- `docs/workflows/`: valid paths, flags, scoring posture, and no dependency on
  a specific agent, slash-command system, or local hook.
- `docs/README.md`: accurate links to the authoritative documents.

Report concrete stale references and correct those within the task's scope.
Do not copy live scores into overview documents.

## 4. Report

Give a compact table of checks run or skipped, with reasons and durations.
Show refreshed score and benchmark tables, their deltas, the host/revision,
and any noise or unresolved failures. List the files changed by this workflow
separately from pre-existing changes. Leave staging and publication to the
user's explicit request.
