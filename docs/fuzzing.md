# Fuzzing Cynic

Cynic ships a coverage-instrumented binary, `cynic-fuzz`, that
speaks Fuzzilli's REPRL (Read-Eval-Print-Reset Loop) protocol over
the standard 4-FD pipe pair plus an LLVM SanitizerCoverage edge
bitmap. With the engine and the matching profile, any contributor
can run [Fuzzilli](https://github.com/googleprojectzero/fuzzilli)
against Cynic and triage the crashes locally.

The profile [`docs/fuzzilli/CynicProfile.swift`](fuzzilli/CynicProfile.swift)
lives in this repository because upstream Fuzzilli hasn't accepted
the contribution yet. Drop it into a local Fuzzilli clone, register
it in `Profile.swift`'s `profiles` dict, and Fuzzilli's `--profile=cynic`
selects it. When the upstream PR lands, this file moves out of
Cynic and Fuzzilli ships it directly.

## Setup

One-time, from a fresh checkout:

    # 1. Build the coverage-instrumented engine binary.
    zig build fuzz                 # → zig-out/bin/cynic-fuzz

    # 2. Clone Fuzzilli (anywhere — sibling directory is fine).
    cd ~/dev
    git clone https://github.com/googleprojectzero/fuzzilli.git
    cd fuzzilli

    # 3. Drop in Cynic's profile and register it. Two edits, both
    #    in Fuzzilli's Profiles directory.
    cp ~/path/to/cynic/docs/fuzzilli/CynicProfile.swift \
       Sources/Fuzzilli/Profiles/CynicProfile.swift

    # Append a single line at the end of the `profiles` dict in
    # Sources/Fuzzilli/Profiles/Profile.swift:
    #     "cynic": cynicProfile,

    # 4. Build Fuzzilli.
    swift build -c release

The local edit to Fuzzilli is two lines (one new file, one dict
entry). It survives upstream's main moving forward; rebase it
when Fuzzilli ships new features. When the profile gets
upstreamed, this whole step collapses to `git pull`.

## Running

    cd ~/dev/fuzzilli
    .build/release/FuzzilliCli \
      --profile=cynic \
      --storagePath=/tmp/fuzzilli-cynic \
      --maxRuntimeInHours=4 \
      --exportStatistics \
      /path/to/cynic/zig-out/bin/cynic-fuzz

Fuzzilli writes corpus samples to `/tmp/fuzzilli-cynic/corpus/`
and crash reproducers to `/tmp/fuzzilli-cynic/crashes/` as the
run progresses. The console reports live stats — coverage,
correctness rate, timeout rate, crashes found.

A 4-hour run on a recent MacBook produces ~100k samples,
~3-4k interesting corpus entries, ~17 % edge coverage, and
single-digit crashes against a well-tested cynic-fuzz. Crash
counts dropped dramatically as the GC-marker, host-safety, and
stack-guard fixes landed — fresh forks may see a higher initial
crash rate if they introduce regressions.

### Stressing the GC for use-after-free detection

Cynic slab-pools its GC objects, so a swept header returns to a
free-list rather than to the OS. A use-after-free on a borrowed
slice (a dangling property key, an unanchored cons-string leaf)
is caught by the 0xaa free-poison only if the stale read beats
the slab's reuse. The `FUZZ_GC_THRESHOLD` env var lowers the
allocation-pressure GC threshold so swept memory spends more
wall-clock poisoned and the race tips toward detection:

    FUZZ_GC_THRESHOLD=1 \
      .build/release/FuzzilliCli --profile=cynic \
        --storagePath=/tmp/fuzzilli-cynic-gc \
        /path/to/cynic/zig-out/bin/cynic-fuzz

`=1` collects on every allocation — maximal detection, slowest
exec rate. A mid value (e.g. `256`) trades some sensitivity for
throughput. Unset is the engine default (fastest). Worth a
dedicated campaign separate from the headline coverage run,
the same way `/gc-stress` complements a normal test262 sweep.

## Triage

Two steps: dedupe crashes by panic anchor, then check each
candidate against the carve-out registry to drop known-by-design
divergences.

    # 1. Bucket the crashes by panic anchor (file.zig:line).
    bash tools/fuzz/triage-crashes.sh /tmp/fuzzilli-cynic/crashes

    # 2. Read the carve-out registry. A candidate that matches an
    #    entry encodes a Cynic posture decision, not a bug.
    less docs/fuzz-carveouts.md

Carve-outs (strict-only, no Annex B, SES-aligned by default, eval
gated) catch the majority of "Cynic-vs-everyone-else" divergences
that Fuzzilli surfaces. The registry has stable ids so triage
output references them directly: a sample dismissed as
`cynic.proto-accessor` means it touched the `__proto__` accessor
that Cynic intentionally doesn't ship.

After triage, the survivors are the real findings. File them as
issues, write a minimal reproducer, and add a regression test
the same commit as the fix. The
[`docs/test262-upstream-gaps.md`](test262-upstream-gaps.md) file
collects fixes that no existing test262 fixture catches — these
are candidates to PR back to `tc39/test262`.

## Continuous fuzzing

The manual loop above also runs nightly as a CI regression gate:
[`.github/workflows/fuzz-nightly.yml`](../.github/workflows/fuzz-nightly.yml).
It builds `cynic-fuzz` and a local Fuzzilli against HEAD, runs a
bounded campaign, triages the crashes automatically, and **fails
only when it finds a NEW host-safety crash** — a Zig panic at an
anchor not already on the known-open allowlist.

### Why nightly, not per-PR

Fuzzing is slow and nondeterministic: which generated samples run
varies run to run, so the same bug surfaces on some nights and not
others. Gating *merges* on that would be flaky and would block the
project's constant direct pushes to `main`. The nightly cadence
catches a regression within a day of it landing without ever
blocking a merge. (The deterministic conformance / GC / JIT gates in
[`ci.yml`](../.github/workflows/ci.yml) stay per-PR; fuzzing is the
one stochastic check, so it stands alone.)

### What the job does

1. **Build.** `zig build -Doptimize=ReleaseSafe` (the `cynic` used to
   replay reproducers — ReleaseSafe so a crash reproduces at the same
   anchor, and *not* Debug, whose ~1000× DebugAllocator slowdown would
   make repros time out and mis-report as non-crashes) and
   `zig build fuzz` (the instrumented `cynic-fuzz` REPRL target).
2. **Build Fuzzilli.** Clone the pinned revision (see below), drop in
   [`docs/fuzzilli/CynicProfile.swift`](fuzzilli/CynicProfile.swift),
   register it, `swift build -c release`. Runs inside the official
   `swift` container (digest-pinned) on a **Linux** runner — cheaper
   than macOS minutes, and a different stack-size / allocator / libc
   surface than the macOS/aarch64 dev box, so it can surface
   host-safety bugs the dev box can't.
3. **Run bounded.** ~25 minutes by default, wrapped in
   [`tools/guarded-run.sh`](../tools/guarded-run.sh), which bounds
   wall-time **and** total tree RSS and SIGKILLs the whole process
   tree on exit — so a hung or OOMing Fuzzilli (or a runaway
   `cynic-fuzz` child) can't wedge or balloon the runner. Fuzzilli's
   own `--maxRuntimeInHours` is an `Int` (1-hour minimum), too coarse
   for a sub-hour budget, so the wall-clock bound lives in the wrapper;
   corpus and crashes are written to disk incrementally, so the hard
   kill loses nothing the triage needs.
4. **Triage + gate.** [`tools/fuzz/fuzz-ci-gate.sh`](../tools/fuzz/fuzz-ci-gate.sh)
   runs `triage-crashes.sh` to dedup crashes by panic anchor, drops
   non-reproducing `(no-panic)` samples (classifying them against the
   [carve-out registry](fuzz-carveouts.md) for the log), compares the
   surviving panic buckets to the committed baseline, and exits
   non-zero only on a bucket not on the allowlist.
5. **Surface.** On a new crash the failure message names the panic
   anchor, and the reproducer `.js` plus Fuzzilli's stats are uploaded
   as the `fuzz-nightly-<run>` artifact.

### The no-flake contract

A run that finds nothing, or finds only known-open / non-reproducing
buckets, is a **PASS**. A known-open bucket is on the allowlist
whether or not tonight's corpus happens to surface it, so sample-set
churn can never flip the verdict. Only a genuinely *new* reproducing
panic — a real host-safety regression — fails the gate. A new bug
that appears only intermittently is still a true positive (the
reproducer is attached); the next night passes if it isn't
re-triggered, and you decide whether to fix it or allowlist it.

Note a Zig panic is *never* a divergence carve-out. The
[carve-out registry](fuzz-carveouts.md) (strict-only, SES, Annex B,
eval-gate) describes *output* divergences; a panic on untrusted JS is
a host-safety violation per [AGENTS.md](../AGENTS.md) ("never abort
the host on untrusted input") — carve-out `cynic.crash-route` says so.
The registry is applied in the gate only to *explain* dropped
non-reproducing samples, never to dismiss a reproducing crash.

### The baseline allowlist

[`tools/fuzz/crash-baseline.txt`](../tools/fuzz/crash-baseline.txt)
lists the known-open crash buckets — real, tracked host-safety bugs
not yet fixed, which must not turn the nightly red every night. It is
an allowlist, not a bug tracker: **every entry is debt, and the goal
is an empty file.** Two entry forms:

- `src/runtime/object.zig:209` — an **exact** anchor (file + line).
  The default; prefer it.
- `src/runtime/object.zig:*` — a **whole-file** wildcard, matching any
  line in that file. Use only for a bucket whose line keeps drifting
  across unrelated refactors and that you've decided to tolerate
  file-wide. It is coarse — it masks *every* panic in that file,
  including a genuinely new one — so tighten back to the exact form
  once the line stabilises.

**Anchors drift.** The anchor is a source location in the engine
being fuzzed (HEAD); editing a file above a panic site shifts its
line, so the same bug reports a new anchor. Because the baseline is
committed alongside the source, the fix is to update the entry in the
**same commit** that moved the code. A drifted-but-not-updated entry
shows up as a nightly failure naming the new anchor — annoying, but
self-correcting and never a per-PR blocker.

**To fix a bucket:** land the fix and *delete* its line. The next
nightly re-fails if it somehow still reproduces — the regression
signal you want.

**To accept a new bucket as known-open** (prefer fixing): add its
anchor with a one-line `#` note — what it is, and a link to the
tracking issue. The reproducer is in the failed run's artifact.

#### Bootstrapping the baseline

The file ships seeded with the one bucket documented open when the
gate was introduced (`src/runtime/object.zig:209`). That line may
already be stale — recent host-safety / GC work may have fixed it, and
unrelated edits drift the number. **The first nightly run after this
gate lands recalibrates it:** if triage reports the bug at a different
`object.zig` line, update the number; if it no longer reproduces,
delete the entry. A first-run failure here costs nothing — it's
nightly, not a merge gate — and its artifact gives you the exact
anchor to seed from.

### Corpus cache + the Fuzzilli pin

A cold Fuzzilli run reaches only shallow coverage in 25 minutes, so
the job caches the corpus between nights (`actions/cache`) and resumes
warm (`--resume`). It caches the storage dir minus `crashes/` — corpus,
settings, and stats carry over; stale crashes never do, so each run's
triage sees only its own findings.

Fuzzilli's corpus is stored as **version-specific `.fzil` protobuf**,
so a cache written by one Fuzzilli build must never be fed to another.
The pin lives in one place — `env.FUZZILLI_REV` in the workflow — and
the corpus cache key embeds it, so bumping the SHA transparently
invalidates the old corpus (one cold start, then warm again under the
new revision). The Fuzzilli `.build` cache is keyed on the same SHA
plus a hash of the profile.

**To bump Fuzzilli:** pick a new upstream commit, update
`FUZZILLI_REV`, and re-confirm `CynicProfile.swift` still compiles
against it (the `profiles`-dict registration in the workflow is robust
to entry renames but the `Profile(...)` field set can change between
revisions — including the Swift floor: a recent Fuzzilli needs Swift
6.1 for SE-0439 trailing commas, so the container is `swift:6.1`, not
6.0). The `swift:6.1` tag floats across patch releases; refresh its
digest pin with `docker buildx imagetools inspect swift:6.1` when
bumping.

### Manual / on-demand runs

`workflow_dispatch` exposes three inputs: `duration_seconds` (a longer
campaign), `jobs` (Fuzzilli parallelism), and `gc_threshold`. Setting
`gc_threshold=1` runs the [GC-stress posture](#stressing-the-gc-for-use-after-free-detection)
(`FUZZ_GC_THRESHOLD=1`, collect on every allocation) for a use-after-free
hunt — the fuzzing analogue of [`/gc-stress`](../.claude/commands/gc-stress.md).

### OSS-Fuzz?

Whether Cynic should also pursue Google's OSS-Fuzz is assessed
separately in
[`docs/fuzz-ossfuzz-assessment.md`](fuzz-ossfuzz-assessment.md). Short
version: OSS-Fuzz does not run Fuzzilli for *any* project, so it is not
a home for this pipeline; the realistic OSS-Fuzz path is a separate
libFuzzer harness, and eligibility for a pre-production engine is
uncertain. The nightly Fuzzilli gate is the right near-term investment.

## The Fuzzilli host hook

Cynic's `fuzzilli(op, arg)` global is installed via
`installTestGlobals` — debug-clean by default, opt-in for
`cynic-fuzz`. Two operations:

- `fuzzilli('FUZZILLI_CRASH', code)` — aborts via `@panic`. The
  parent uses this in its startup test to confirm crash detection
  works; the `code` arg is ignored in Cynic (single-flavor abort).
- `fuzzilli('FUZZILLI_PRINT', value)` — writes a line to fd 103,
  Fuzzilli's differential output sink. Silent no-op when fd 103
  isn't open (running outside REPRL).

Anything else is ignored — extending the op set requires both an
engine change in `src/runtime/builtins/fuzzilli.zig` and matching
profile changes in `CynicProfile.swift`.

## Differential fuzzing (finding miscompiles)

The base `cynic` profile finds crashes. To find **silent
miscompiles** — a wrong value with no crash — `cynic-fuzz` also
supports an interpreter-vs-JIT differential via three argv flags:

- `--jit` — run with Bistromath on, tier-up threshold forced to 1.
- `--diff` — after each sample, write a canonical completion-value
  digest to fd 103 so Fuzzilli's fuzzout oracle can compare two runs.
- `--diff-self-test` — perturb that digest (harness validation only).

The matching Fuzzilli side — a fuzzout-comparison oracle and a
separate `cynicDiff` profile (target `--jit --diff` vs reference
`--diff`) — ships as [`docs/fuzzilli/CynicDiffProfile.swift`](fuzzilli/CynicDiffProfile.swift)
plus [`docs/fuzzilli/cynic-diff-oracle.patch`](fuzzilli/cynic-diff-oracle.patch),
applied to a local Fuzzilli clone the same way the base profile is.
Because both halves are the same engine at the same posture, the
carve-outs below never fire as false positives. See
[docs/fuzz-differential.md](fuzz-differential.md) for the full design,
why a cross-engine (interpreter-conformance) differential is deferred,
and the trigger condition to revisit it.

## The coverage protocol

`cynic-fuzz` builds with `-fsanitize-coverage=trace-pc-guard` so
every basic block calls into the LLVM SanitizerCoverage runtime.
The hooks in `tools/fuzz/fuzz_coverage.zig` map the POSIX shared-memory
region Fuzzilli sets up via `$SHM_ID`, publish edge-hit bits into
its bitmap, and reset between iterations. Fuzzilli reads the
bitmap to grow the corpus toward un-covered edges.

The thread-local `__sancov_lowest_stack` symbol that LLVM's
stack-depth probe references is defined via a tiny C file
(`tools/fuzz/fuzz_coverage_sancov.c`); Zig's TLS emission on Mach-O
didn't line up with the symbol shape LLVM expected, and C's
`__thread` does. See the file for the rationale.

The REPRL protocol encoder and the coverage-hook arithmetic carry
unit tests; they live with the host in `tools/fuzz/` (outside `src/`,
so the production `cynic` binary ships no fuzzing code) and run via:

    zig build test-fuzz

## Pre-Fuzzilli sanity

Before launching a long run, smoke-test the REPRL protocol with
a fake parent — no need to wait for Fuzzilli to build. Run the
`cynic-fuzz` binary bare: it speaks the same protocol, and without
the inherited FDs it surfaces the documented error instead of
looping.

    zig build fuzz
    ./zig-out/bin/cynic-fuzz
    # → error: `cynic-fuzz` expects FDs 100/101/102/103 inherited
    #          from Fuzzilli; invoke via the Fuzzilli harness, not
    #          directly.

That error message is the smoke test — if the binary instead
panics or segfaults, the engine has a regression. Worth running
after any rebase or refactor that touches `tools/fuzz/fuzz_reprl.zig`.
