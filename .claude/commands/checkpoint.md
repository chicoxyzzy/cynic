---
description: End-of-session housekeeping — refresh test262 + bench + cross-engine results (gated by file changes), audit docs/commands for drift
---

Re-measure every results file the project tracks, but **only if
its inputs changed since the last refresh of its output**. On a
clean state `/checkpoint` is a ~5 s no-op. After a typical commit
it runs in ~60 s instead of ~4 min.

**Show the user every freshly-printed table** (test262 row, bench
table, cross-engine snapshot) so deltas are visible at a glance —
the user shouldn't have to `cat` files after the run.

The harness runs parse + compile + execute in one unified mode —
parse-negative fixtures (`negative.phase: parse` in frontmatter)
resolve inline at their parse phase, so there's no separate
parser-only sweep to run.

**Do not commit anything.** Print a summary; the user decides
which deltas land.

## Gating helper

For each step, derive "needs refresh" via:

```sh
needs_refresh() {
    local output="$1"; shift
    local inputs=("$@")
    # If output is untracked / never committed → run.
    git ls-files --error-unmatch -- "$output" >/dev/null 2>&1 || return 0
    # Working-tree changes under inputs → run.
    [ -n "$(git status --porcelain -- "${inputs[@]}")" ] && return 0
    # Committed changes since output's last touch → run.
    local since
    since=$(git log -1 --format=%H -- "$output")
    [ -n "$(git diff --name-only "$since"..HEAD -- "${inputs[@]}")" ] && return 0
    return 1
}
```

If the helper returns false, **skip the step and report "skipped
(inputs unchanged)"** in the summary. Otherwise run and capture.

## 1. Leak-check (gated)

Inputs: `src/runtime/{heap,realm,object,function,environment,string,symbol,bigint,generator}.zig`
Output: `test262-results.md` (proxy — the leak-check guards the
test262 run, so its "freshness" tracks `test262-results.md`)

```sh
zig build test262 -- --quiet --filter=language/expressions --top-rss=10
```

Healthy: top deltas ≤ ~20 MiB. STOP and bisect if >20 MiB.

## 2. test262 runtime (gated, smoke first)

Inputs: `src/`, `vendor/test262/`, `tools/test262.zig`
Output: `test262-results.md`

**a. Smoke first (~5 s)** — does the pass count match the latest
runtime row?

```sh
./zig-out/bin/cynic-test262 --quiet --only-failing
```

Read the `pass:` value. Compare against the most-recent runtime
row in `test262-results.md`. If matches AND the SHA in that row
matches `git rev-parse --short HEAD`, **skip the full sweep**.

**b. Otherwise** run the full sweep with `--write-results`:

```sh
tools/guarded-run.sh --timeout=1800 -- \
    zig build test262 -- --quiet --write-results
```

**c. Print the row to the user.** After the run, extract the new
row from `test262-results.md`:

```sh
awk '/^### .*— cynic `[^`]+`/{c++} c==1' test262-results.md | head -10
```

(That's the most-recent `### date — cynic <sha> — …` block; print
the header + the runtime row + the Δ pass column.)

## 3. Bench (gated, single-engine)

Inputs: `src/`, `bench/`, `tools/bench.zig`
Output: `bench-results.md`

```sh
tools/guarded-run.sh --timeout=300 -- zig build bench
```

**Capture and print the entire table** to the user verbatim. Then
compare against the most-recent row in `bench-results.md` for the
same host (`Darwin 25.5.0 arm64`, or whatever `uname -srm` yields):

- Per-fixture % delta.
- Flag any fixture moving ≥5% in either direction.

The driver doesn't auto-write a row. If anything moved ≥5%, the
summary suggests appending a new row (format mirrors prior rows:
date + cynic SHA + host + per-fixture median/min/max/rss + prose
diff). **Don't append yourself — let the user decide.**

## 4. Cross-engine (gated)

Inputs: `src/`, `bench/`, `tools/bench-cross.sh`
Output: `bench-cross-results.md`

Also skipped when step 4 (bench) ran and found **no fixture moved
≥5 %** — cross-engine numbers reflect the same code; if Cynic
didn't move, cross-engine positions can't have shifted relative
to peers.

```sh
tools/guarded-run.sh --timeout=900 -- \
    tools/bench-cross.sh -o bench-cross-results.md
```

**Print the table to the user.** Then diff against the prior
snapshot via `git diff bench-cross-results.md` and call out:

- Cynic position vs QuickJS-NG (the headline peer).
- Newly noisy cells (`*` > 10 % spread).
- Position changes (a previously-leading engine got passed).

## 5. Audit docs (always; ~1 s)

Grep each for stale references:

- `docs/ROADMAP.md` — any "In progress / planned" item that
  shipped this session.
- `docs/handbook/*.md` — handbook entries for code that changed.
- `AGENTS.md` — flags, commands, invariants.
- `docs/benchmarking.md` — fixture table, iter counts.

Report ✓ or ⚠ with a specific edit suggestion per file.

## 6. Audit `.claude/commands/` (always; ~1 s)

Grep each command file for stale flag / command / path references.
Report ✓ or ⚠ per command.

## 7. Summary

Print a compact summary with the actual numbers visible:

```
## /checkpoint summary

| step | status | runtime |
|---|---|---|
| leak-check  | ran / skipped (reason) | … s |
| test262 runtime | ran (Δ pass = N) / skipped (smoke matched) | … s |
| bench | ran / skipped (inputs unchanged) | … s |
| cross-engine | ran / skipped (no bench movement) | … s |

### test262 row (if ran)
<extracted runtime row from test262-results.md, copy verbatim>

### Bench table (if ran)
<full table from zig build bench, copy verbatim>

### Bench movers (if any ≥5 %)
- <fixture>: <old> → <new> (Δ %)

### Cross-engine row (if ran)
<full table from bench-cross-results.md, copy verbatim>

### Docs audit
- file: ✓ / ⚠ <suggestion>

### Slash commands audit
- /name: ✓ / ⚠ <suggestion>

### Files modified
- <list of files this run touched>
```

End with: **"Stage and commit?"** — let the user pick which
deltas land. Do not stage or commit yourself.

## Args

| Arg | Effect |
|---|---|
| (none) | Default — gated leak/runtime/bench/cross-engine + always-on audit. |
| `--force` | Override gating — run every step regardless of input changes. Use after a tool/harness change that doesn't show up in input-paths grep. |
