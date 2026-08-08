# Native differential fuzzing for Cynic

Fuzzilli against `cynic-fuzz` finds **crashes** (panic / SIGSEGV /
SIGABRT) out of the box. It did not find **silent miscompiles** —
inputs where Cynic returns a wrong value without crashing. Those were
caught only post-hoc, by the private `pragmatist` project's
multi-engine `engines.diff` (V8 / JSC / SpiderMonkey / Hermes /
QuickJS / engine262 / Cynic, engine262 as authority).

Fuzzilli has a *native* differential mode (`Profile.processArgsReference`
non-nil ⇒ `isDifferential`). This document records what that mode
actually does, and what was built on top of it for Cynic.

**Outcome, in one paragraph.** Fuzzilli's native differential mode (in
the local fork `~/dev/opensource/fuzzilli`, HEAD `dee399a`) is a
**V8-internal, single-binary, frame-dump** mechanism — it cannot do
cross-engine output comparison without Swift surgery, and the post-hoc
`pragmatist` lane already covers cross-engine conformance better
(§1–§3, §5). The one differential variant that fits the native mode
cleanly *and* is noise-free — **Cynic-interpreter-vs-Cynic-JIT** — has
been **implemented as a working PoC** (§4): a fuzzout-comparison oracle
in the local Fuzzilli fork, a `cynicDiff` profile, and four flags on
`cynic-fuzz`. It demonstrably fires on an injected divergence and stays silent
(0 false positives over ~7k execs) on real interpreter-vs-JIT.

---

## 1. How Fuzzilli's native differential mode actually works

The mode is the **V8 "Dumpling"** interpreter-vs-JIT differential. It
is not a generic "run a sample through engine A and engine B, compare
printed output" facility. Three load-bearing facts, each verified in
the fork's source:

### 1.1 One binary, two argument sets — not two engines

`FuzzilliCli/main.swift:120` takes exactly one positional argument:

```swift
let jsShellPath = args[0]
```

Both the target runner and the reference runner are built from that
*same* path (`main.swift:451-474`):

```swift
let createRunner = { (baseArgs, forReferenceRunner) -> REPRL in
    return REPRL(executable: jsShellPath, processArguments: finalArgs, ...)
}
let runner          = createRunner(jsShellArguments, false)   // target
let referenceRunner = createRunner(refArgs,          true)    // reference
```

`processArgs` vs `processArgsReference` are two *flag sets for the
same executable*. **There is no CLI option for a second/reference
binary.** Pointing the reference at engine262 or QuickJS is
structurally impossible without patching `main.swift`.

### 1.2 The comparison is V8 internal frame dumps on disk — not REPRL output

The oracle does not compare `stdout`, and out of the box it does not
compare `fuzzout` (the fd-103 `FUZZILLI_PRINT` channel). It compares
**V8-internal stack-frame dumps written to files on disk**.

`Configuration.swift` injects a per-instance dump-filename flag into
each runner's args; `Fuzzer.executeDifferentialIfNeeded` reads those
files back and hands them to `DumplingDiffOracle/Oracle.swift`, which
parses a V8-specific frame format (`---I`/`---S`/`---M`/`---T`
headers; `b:` offset, `x:` accumulator, `a0:`/`r0:` slots) and matches
optimized frames against unoptimized ones.

**Consequence for a non-V8 engine:** `cynic-fuzz` writes no dump file,
so the optimized dump is empty, so `executeDifferentialIfNeeded`
returns early on *every* sample. The Dumpling path is completely inert
for Cynic — it flags zero divergences, not because Cynic is correct,
but because the oracle has nothing to read.

### 1.3 `fuzzout` is captured but the Dumpling oracle ignores it

`Execution/REPRL.swift:219` exposes the fd-103 channel
(`reprl_fetch_fuzzout`). The Dumpling verdict, though, is
`DiffOracle.relate(optDumpOut, with: unoptDumpOut)` over the dump
files. `fuzzout` is only attached to reports for human debugging.
Even the V8 team — doing a *within-engine* differential — chose
internal frame dumps over printed-output comparison because printed
output is the noisier signal. That fact directly informs the
cross-engine analysis in §3.

### 1.4 Orchestration summary

`Fuzzer.swift:778`: after a successful target run, if
`isDifferentialFuzzing && purpose.supportsDifferentialRun`, run the
differential. A divergence produces `ExecutionOutcome.differential`,
which `ProgramCoverageEvaluator` treats like a crash — the sample is
minimized and kept, so the corpus is *steered* toward
divergence-triggering inputs. That steering is the one thing native
differential does that a post-hoc diff cannot, and the reason the
mode is worth anything for Cynic.

---

## 2. Reference-engine evaluation (for a cross-engine differential)

A cross-engine differential needs a reference that is (a) strict-mode
compatible (Cynic is strict-only; see `cynic.strict-only` in
[fuzz-carveouts.md](fuzz-carveouts.md)), (b) REPRL-capable, (c) not
sharing Cynic's bugs, (d) fast enough to run in-loop.

| Candidate | Strict? | REPRL? | Oracle quality | In-loop speed | Verdict |
|---|---|---|---|---|---|
| **engine262** | yes (configurable) | **no native build** | **ideal — spec authority** | **~100× too slow** (meta-circular JS interpreter on Node) | Ideal *post-hoc* oracle, impractical *in-loop* |
| **QuickJS (`qjs --reprl`)** | per-source `"use strict"` only | **yes** (`QjsProfile.swift`) | independent impl; not authoritative | fast | Possible, but Annex-B/sloppy noise + needs a 3rd engine to adjudicate |
| **Second Cynic build** | yes (same engine) | yes (reuse `cynic-fuzz`) | only finds *intra-Cynic* divergences (JIT vs interpreter) | fast | Viable + noise-free — **this is what §4 implements** |

- **engine262** is the right *oracle* (it is `pragmatist`'s authority)
  but the wrong *in-loop* reference: no native REPRL build, and as a
  meta-circular interpreter on Node it is orders of magnitude slower
  than a fuzzer's target. It belongs in the post-hoc lane.
- **QuickJS** has REPRL and is fast, but is sloppy-by-default with full
  Annex B, so a naive Cynic-vs-qjs diff fires on every carve-out in §3,
  and a qjs/Cynic disagreement still needs a third engine to
  adjudicate — exactly what `pragmatist`'s 7-engine panel gives and a
  2-engine in-loop diff cannot.
- **Second Cynic build** is the only fast, noise-free option, because
  identical posture ⇒ no carve-out false positives and identical
  output format ⇒ no canonicalization noise. Its limitation: two Cynic
  *interpreter* runs are identical, so the only divergence it surfaces
  is **interpreter-vs-JIT**.

---

## 3. The carve-out / noise problem for cross-engine

`cynic-fuzz` already neutralizes two of the five carve-out classes:
its fixed posture is `--unhardened` (`fuzz_reprl.zig`, kills
`cynic.ses-hardening`) and `--allow=eval` (kills `cynic.eval-gate`).
The remaining classes **cannot** be neutralized on Cynic's side — they
are the engine's identity:

- **`cynic.strict-only`** — Cynic has no sloppy parser. A
  production-engine reference run sloppy diverges on `this`-binding,
  `arguments` aliasing, undeclared-assignment `ReferenceError`, etc.
  Mitigable only by forcing the reference strict (qjs can wrap samples
  in `"use strict"`).
- **Annex B** — `cynic.annex-b-regex`, `cynic.proto-accessor`,
  `cynic.legacy-octal`, `cynic.html-comment`,
  `cynic.labelled-function-declaration`, `cynic.for-in-initializer`,
  `cynic.removed-intrinsics`, `cynic.legacy-regexp-globals`. QuickJS
  has no flag to disable Annex B, so these can only be filtered by
  porting the carve-out detection regexes into a Swift pre-filter —
  re-implementing `pragmatist`'s `src/fuzz/carveouts.ts` inside
  Fuzzilli.

On top of carve-outs, cross-engine printed-output comparison has a
large *intrinsic* false-positive surface unrelated to Cynic's posture:
error-message text, `Error.prototype.stack` format, enumeration-order
edge cases, `Number`→`String` rounding, `Symbol` description rendering,
`NaN` canonicalization, and `Date`/`Math.random` non-determinism (the
V8 Dumpling profile needs a determinism shim for the latter *even
within one engine*). Each is a divergence the oracle must canonicalize
away or drown in.

That is the "don't ship a half-working differential that produces
noise" failure mode. The filtering and canonicalization that make
cross-engine diff usable already exist, debugged, in `pragmatist`'s
post-hoc lane — duplicating them in Swift to gain in-loop steering is a
poor trade until the steering is proven necessary (§5).

---

## 4. Implemented: the Cynic-interpreter-vs-Cynic-JIT differential

This is the one variant that fits the native mode structurally *and*
avoids the noise problem entirely, so it is the one that was built:

- **Structural fit:** one binary (`cynic-fuzz`), two arg sets — exactly
  the V8 Dumpling shape. No second-binary `main.swift` surgery.
- **Zero carve-out noise:** both halves are the same engine at the same
  posture (strict-only, no Annex B, `--unhardened`, `--allow=eval`),
  so every Cynic-intentional divergence is identical on both sides and
  cancels.
- **Zero format noise:** both halves emit byte-identical output; the
  `--diff` host installs one shared `Date`/`Math.random` determinism
  prelude before either sample runs.
- **Real correctness class:** it catches **JIT (Bistromath / Spasm)
  miscompiles** — the JIT-compiled path returning a different value
  than Lantern the interpreter.

What it does **not** catch: interpreter conformance bugs (Cynic's
interpreter wrong vs the spec). Both tiers agree on a wrong-but-
consistent interpreter result; for that class an external oracle is
unavoidable (§2/§3). It also overlaps, in *kind*, the test262 `--jit`
differential gate (docs/jit.md §10) — but extends it from a pass/fail
gate over fixtures into value-level comparison over generated
programs, which is strictly more inputs.

### 4.1 The three pieces

**(a) `cynic-fuzz` flags** (`tools/fuzz/fuzz_main.zig`,
`tools/fuzz/fuzz_reprl.zig`). Parsed from argv — not env — because
Fuzzilli shares one `processEnv` across both halves of a differential
pair, so only `processArgs` vs `processArgsReference` can differ:

- `--jit` — set `realm.jit_enabled = true` and
  `realm.jit_threshold_override = 1`, so even a function called once is
  Bistromath-compiled. The target half uses it; the reference half
  stays on Lantern.
- `--ohaimark` — set both tier enables and both threshold overrides to 1,
  attempting Ohaimark before Bistromath, including default-on loop-header OSR.
  It can augment the target half to isolate T2 without changing the T1-only
  base profile.
- `--no-ohaimark-osr` — isolate function-entry T2 in a forced-Ohaimark target.
  `--ohaimark-osr` remains an explicit compatibility no-op.
- `--diff` — install the host's deterministic `Date` / `Math.random`
  prelude, then after each sample write a canonical **completion-value
  digest** to fd 103 (Fuzzilli's fuzzout sink). The prelude pins both
  `Date.now()` and zero-argument `new Date()` (the latter reads the host
  clock directly), while explicit Date arguments preserve normal
  behavior. The digest is computed with no JS re-entry (no user
  `toString`) so it can't perturb GC state or introduce non-determinism:
  primitives serialize exactly
  (`i42`, `d<ieee-bits>`, `s<len>:<fnv>`, `b1`, `u`, `n`), with a
  tag byte for returned/thrown/yielded; heap objects collapse to a
  `o` type tag (their identity is a non-deterministic heap address).
  This is the comparison signal — a JIT arithmetic / comparison /
  string-length miscompile surfaces as a differing primitive digest.
- `--diff-self-test` — perturb the digest with a `#ST` sentinel so the
  two halves disagree on every sample. Pure harness validation (proves
  the oracle fires without needing a real miscompile); never used in a
  real run.

The base crash-finding profile passes none of these and is unaffected.

**(b) A fuzzout-comparison oracle in Fuzzilli** (local fork only;
captured as `docs/fuzzilli/cynic-diff-oracle.patch`). A new
`Profile.differentialMode` (`.dumplingFrames` default / `.fuzzout`)
threads a `Configuration.differentialCompareFuzzout` flag through to
`Fuzzer.execute`, which branches to a new
`executeFuzzoutDifferential`: re-run the (already-succeeded) target
sample on the reference runner, compare the two `fuzzout` strings, and
return `.differential` on mismatch. When `.fuzzout` is selected,
`dumplingEnabled` is false, so no V8 dump-filename arg is injected into
`cynic-fuzz` and no dump files are written.

**(c) The `cynicDiff` profile** (`docs/fuzzilli/CynicDiffProfile.swift`)
— SEPARATE from the upstream-bound `CynicProfile.swift`, which stays
non-differential:

```
target    : cynic-fuzz --jit --diff      (Bistromath, threshold 1)
reference : cynic-fuzz      --diff       (Lantern interpreter)
differentialMode = .fuzzout
codePrefix = empty (cynic-fuzz --diff installs the shared determinism prelude)
```

### 4.2 Setup and run

On top of the base setup in [fuzzing.md](fuzzing.md) (build
`cynic-fuzz`; clone Fuzzilli; register `CynicProfile.swift`):

```sh
# In the local Fuzzilli clone: drop in the diff profile and apply the
# oracle patch (these stay LOCAL — they are not part of the
# upstream-bound base profile).
cp <cynic>/docs/fuzzilli/CynicDiffProfile.swift Sources/Fuzzilli/Profiles/
git apply <cynic>/docs/fuzzilli/cynic-diff-oracle.patch   # adds "cynicDiff" to the profiles dict too
swift build -c release

# Real interpreter-vs-JIT differential:
.build/release/FuzzilliCli --profile=cynicDiff \
  --storagePath=/tmp/fzcd <cynic>/zig-out/bin/cynic-fuzz

# Force Ohaimark at threshold 1 in the TARGET; reference remains Lantern:
.build/release/FuzzilliCli --profile=cynicDiff \
  --storagePath=/tmp/fzcd-t2 --additionalArguments=--ohaimark \
  <cynic>/zig-out/bin/cynic-fuzz

# Isolate function-entry T2 from the default Ohaimark+OSR target; the
# reference remains Lantern:
.build/release/FuzzilliCli --profile=cynicDiff \
  --storagePath=/tmp/fzcd-t2-entry \
  --additionalArguments=--ohaimark \
  --additionalArguments=--no-ohaimark-osr \
  <cynic>/zig-out/bin/cynic-fuzz

# Validate the oracle end-to-end (forces a divergence on every sample;
# --additionalArguments reaches the TARGET only):
.build/release/FuzzilliCli --profile=cynicDiff \
  --storagePath=/tmp/fzcd-st --additionalArguments=--diff-self-test \
  <cynic>/zig-out/bin/cynic-fuzz
```

Differential mode requires `--storagePath`. Divergences are logged as
`[CYNIC-DIFF] OUTPUT DIVERGENCE` and stored (minimized) under
`<storagePath>/differentials/`.

Loop-header OSR is part of the default Ohaimark target. The focused graduation
campaign completed with no crash or differential artifacts; use
`--no-ohaimark-osr` only for entry-only diagnosis.

### 4.3 Demonstrated results

A matched pair on this host (arm64 macOS, Bistromath active):

| Run | Args | Differentials |
|---|---|---|
| **Self-test** (perturbed) | target `--jit --diff --diff-self-test` vs ref `--diff` | **77** found and minimized into `differentials/` — proves the oracle fires |
| **Real** | target `--jit --diff` vs ref `--diff` | **0** over ~7,400 execs (Correctness ~79%, Timeout ~1.2%) — proves no noise |
| **Ohaimark OSR graduation** | target `--jit --diff --ohaimark` vs ref `--diff` | **0** after minimized-artifact replay plus 250 fresh samples / 11,388 executions in 6m30s |

The self-test divergence blocks read exactly as designed, e.g.
`TARGET fuzzout: Vo#ST` vs `REFERENCE fuzzout: Vo`. The real run's zero
false positives is the key result: the determinism shim plus identical
posture mean the JIT and interpreter agree on every completion-value
digest, so any future non-zero count is a real candidate miscompile.

### 4.4 Observations and limitations

- **`@panic`/FUZZILLI_CRASH is slow under `--jit`, not hung.** With
  `--jit` the intentional-crash startup test aborts in ~190ms
  (Fuzzilli's own recommended timeout came out at ~380ms), but its
  first cold-start invocation once spiked past a 750ms bound. The
  `cynicDiff` profile therefore uses a 1500ms timeout. Whether the
  panic-time cost is the unwinder traversing Bistromath frames is a
  question for the JIT track; it does not affect divergence detection
  (miscompiles surface as wrong *values*, not panics).
- **Completion-value granularity.** The digest is the script's
  completion value, so a divergence buried in intermediate state that
  never reaches the completion value is missed. A future
  `additionalCodeGenerator` emitting `fuzzilli('FUZZILLI_PRINT', v)`
  for live values would widen coverage; the completion-value digest
  was chosen first because it needs no code generator and produces a
  comparable signal for every sample.
- **Object divergences collapse to `o`.** Deliberate — heap addresses
  are non-deterministic and deep structural compare is out of scope.
  Primitive miscompiles (the high-value JIT-bug case) are exact.
- **Reference failure is treated conservatively.** If the reference
  run does not also succeed, the sample is returned unflagged rather
  than reported as a divergence, keeping the lane low-noise.

---

## 5. Cross-engine: still deferred, and the trigger to revisit

The §4 PoC covers **JIT** correctness. Cross-engine **interpreter
conformance** differential — the larger class — remains deferred,
because §1–§3 stand: the native mode is single-binary and dump-file
based, a cross-engine reference needs Fuzzilli surgery (second binary +
the fuzzout oracle, which now exists) *plus* strict-forcing, a
carve-out pre-filter, and output canonicalization, and the post-hoc
`pragmatist` `engines.diff` already does cross-engine conformance with
engine262 as authority and carve-out filtering built in.

Revisit cross-engine native differential when **any** of:

1. **Upstream Fuzzilli generalizes the differential oracle** beyond V8
   Dumpling and/or gains second-binary support — then the cross-engine
   wiring collapses to a profile + a reference REPRL wrapper, and the
   `.fuzzout` oracle here is a head start.
2. **A REPRL-capable, fast, strict, Annex-B-free reference appears**
   (e.g. an engine262 REPRL build that is fast enough in-loop).
3. **The post-hoc `pragmatist` differential proves insufficient at
   *steering*** — i.e. the coverage-grown corpus rarely reaches
   divergence-prone paths and you want generation pressure toward them.
   In-loop steering is the unique value native differential adds; that
   observation is the signal it is worth the cross-engine
   noise-handling cost.

The concrete next step toward cross-engine, when a reference is chosen:
reuse `executeFuzzoutDifferential` (already engine-agnostic), add a
second-binary path to `makeFuzzer`, force the reference strict, and
port the carve-out detection regexes from [fuzz-carveouts.md](fuzz-carveouts.md)
as a Swift pre/post filter.
