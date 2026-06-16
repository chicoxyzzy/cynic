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
