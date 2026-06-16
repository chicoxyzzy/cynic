# Should Cynic apply to OSS-Fuzz?

An assessment, written alongside the nightly Fuzzilli CI gate
([`.github/workflows/fuzz-nightly.yml`](../.github/workflows/fuzz-nightly.yml),
[`docs/fuzzing.md`](fuzzing.md) → "Continuous fuzzing"). OSS-Fuzz is
Google's free continuous-fuzzing service — far more compute than a
nightly runner, professional crash triage, managed corpora, sanitizer
builds, coordinated disclosure. It is the gold-standard long-term home
for a fuzzing target. The question: is it a home for *Cynic's* fuzzing,
and is it worth pursuing now?

**Bottom line.** No — not as a home for the Fuzzilli pipeline, and not
yet by any route. The single fact that decides it: **OSS-Fuzz does not
run Fuzzilli for any project.** The only realistic OSS-Fuzz path for
Cynic is a *separate* libFuzzer harness, which is materially weaker for
a JS engine, is blocked by an unsolved Zig-toolchain integration, and
faces an uncertain eligibility bar for a pre-production engine. The
nightly Fuzzilli gate is the right near-term investment; OSS-Fuzz is a
"revisit if Cynic gains production users *and* someone wants to do the
libFuzzer-harness work" item, not a substitute for it.

## The load-bearing finding: OSS-Fuzz runs no Fuzzilli

A full recursive scan of the `google/oss-fuzz` repository returns
**zero** files matching `fuzzilli` or `reprl` — not in `projects/`, not
in `infra/base-images/`. There is no `fuzzing_engines: [fuzzilli]`, no
REPRL plumbing, no base-image support. The JS *engines* OSS-Fuzz fuzzes
fall into exactly two buckets, neither of which is Fuzzilli:

| Engine | OSS-Fuzz `language` | `fuzzing_engines` | Mechanism |
|---|---|---|---|
| `v8` | c++ | `none` | Google-internal **`js_fuzzer`** driving a blackbox `d8` |
| `spidermonkey` | c++ | `none` + `blackbox: true` | `js_fuzzer`; Mozilla-run via `vendor_ccs` |
| `quickjs` | c | `libfuzzer, afl, honggfuzz` | libFuzzer `LLVMFuzzerTestOneInput` harness |
| `xs` (Moddable) | c | `libfuzzer, afl, honggfuzz` | libFuzzer harness |
| `njs` | c++ | `libfuzzer, afl, honggfuzz` | libFuzzer harness |
| `hermes` | c++ | (default) | libFuzzer harness |

The `fuzzing_engines: [none]` + `blackbox` path that V8/SpiderMonkey
use is **not** a generic "bring your own fuzzer like Fuzzilli" hook. It
means OSS-Fuzz links no standard harness and drives a plain binary with
Google's **internal, closed-source** JS mutation fuzzer (`js_fuzzer`, a
differential JS-mutation tool distinct from Fuzzilli's FuzzIL + REPRL
model). It is undocumented as a user-facing extension point, and
V8/SpiderMonkey were onboarded into it by Google/Mozilla insiders, not
via the normal PR path.

This is confirmed directly by OSS-Fuzz maintainers. In the Moddable XS
onboarding PR ([#7675](https://github.com/google/oss-fuzz/pull/7675)) a
contributor asked about adding Fuzzilli; OSS-Fuzz lead Jonathan Metzman
clarified that OSS-Fuzz's JS-engine fuzzing **"is not Fuzzilli, it's
this [js_fuzzer]."** XS — an engine that *already runs Fuzzilli* — still
integrated with OSS-Fuzz via a plain libFuzzer harness, explicitly
deferring Fuzzilli ("if there is a way to also add Fuzzilli down the
road, that would be cool"). The broader ecosystem of OSS-Fuzz-style
Fuzzilli builds (research CRSes, JIT-Picker, etc.) all live in
third-party repos with their own Docker/build infra, never in upstream
OSS-Fuzz.

So "apply to OSS-Fuzz using Fuzzilli" is, as of mid-2026, **not a path
OSS-Fuzz supports.** Fuzzilli stays a self-hosted effort regardless.

## The realistic OSS-Fuzz path, and why it's costly

The only route that exists for Cynic is bucket #2: a **libFuzzer
harness**, the same shape as QuickJS / XS. An OSS-Fuzz project is a
`projects/<name>/` directory with three files:

- **`project.yaml`** — `homepage`, `language`, `primary_contact`,
  `main_repo`, plus optional `sanitizers` (address / undefined / memory),
  `fuzzing_engines`, `architectures`, `auto_ccs`.
- **`Dockerfile`** — `FROM gcr.io/oss-fuzz-base/base-builder`, then
  `git clone` the target.
- **`build.sh`** — compile a static lib, then for each fuzzer link
  against `$LIB_FUZZING_ENGINE` and drop the binary in `$OUT`. OSS-Fuzz
  injects a sanitizer-instrumented `$CC/$CXX/$CFLAGS` (coverage via
  `-fsanitize=fuzzer-no-link`).

For a C engine that already builds with clang and a Makefile (QuickJS),
this is roughly a day's work. For Cynic it is not, for three reasons:

1. **Zig is not a supported OSS-Fuzz language.** The `language:` field
   accepts `c, c++, go, rust, python, jvm, swift, javascript, lua` —
   not `zig`. (And `language: javascript` is a trap: it means *fuzzing
   JS libraries with Jazzer.js on Node*, not "a JavaScript engine.")
   The native engines all declare `c`/`c++`. You'd declare `c++` and
   shoehorn `zig build` into the base image, making it honor the
   injected sanitizer/coverage flags and link `$LIB_FUZZING_ENGINE`, or
   expose a C-ABI `LLVMFuzzerTestOneInput` entry point that hands the
   byte blob to the engine. **There is no in-repo precedent for a Zig
   project to copy** — this is the bulk of the effort and the part most
   likely to stall.

2. **A libFuzzer harness is much weaker for a JS engine.** It is
   `bytes → parse/eval`: it finds parser, coercion, and some GC crashes,
   but it has no grammar awareness, so it explores the language surface
   far less deeply than Fuzzilli's FuzzIL mutation. This is *exactly why*
   V8 and SpiderMonkey use `js_fuzzer` instead of a libFuzzer harness.
   So the OSS-Fuzz harness would be a strictly shallower complement to
   the Fuzzilli gate, not a replacement.

3. **Eligibility is uncertain.** OSS-Fuzz's stated bar: *"an open-source
   project must have a significant user base and/or be critical to the
   global IT infrastructure."* A JS engine scores well on attack-surface
   grounds (it processes untrusted input), but Cynic today has no
   production users and an explicit "don't ship to prod, frankly"
   posture. Acceptance is discretionary, decided per-project when you
   open the PR; nothing in the criteria suggests a brand-new,
   low-adoption engine clears the bar on its own. *(This is a read of
   the stated bar applied to Cynic, not a sourced rejection rule — but
   it is the honest read.)*

## What OSS-Fuzz would provide (if accepted, via the libFuzzer route)

All of these are real and valuable, and all apply to a libFuzzer
project — **not** to a Fuzzilli one, which OSS-Fuzz can't host:

- Continuous distributed fuzzing on ClusterFuzz (free, Google-run).
- Automated crash dedup/triage with downloadable reproducers.
- ASan / UBSan / MSan builds (MSan needs all deps instrumented).
- Coordinated disclosure: bugs open to the public after 90 days or on
  fix, whichever is first.
- **CIFuzz** — a GitHub Action that runs your OSS-Fuzz fuzzers at PR
  time. Notably, this is the per-PR crash gate OSS-Fuzz offers — but it
  requires an existing OSS-Fuzz integration, so it inherits every
  blocker above and would still be the *libFuzzer* harness, not Fuzzilli.
- Managed corpus + periodic coverage reports.

## Recommendation

1. **Ship and rely on the nightly Fuzzilli gate** (done). It gives the
   thing that matters most — grammar-aware, coverage-guided fuzzing of
   the real engine with automated regression detection — on infra we
   fully control, today.
2. **Do not pursue OSS-Fuzz as a Fuzzilli home.** It cannot host
   Fuzzilli; there is nothing to apply for.
3. **Treat an OSS-Fuzz libFuzzer harness as a separate, later, optional
   item**, justified only if (a) Cynic gains a production user base that
   plausibly clears the eligibility bar, and (b) someone is willing to
   solve the Zig-in-`base-builder` integration. Even then it
   *complements* (shallow parser/coercion coverage + ClusterFuzz scale +
   coordinated disclosure) rather than replaces the Fuzzilli gate.
4. **The harness work is reusable off-OSS-Fuzz.** If anyone builds the
   C-ABI `LLVMFuzzerTestOneInput` entry point, it can drive a local
   `libFuzzer`/AFL++ target (`cynic-libfuzz`) in our own CI immediately,
   capturing most of the bug-finding value of the OSS-Fuzz harness
   without the eligibility question or the upstream PR — a lower-risk
   first step than an OSS-Fuzz application, if we ever want the
   byte-blob coverage angle that Fuzzilli doesn't emphasize.

## Sources

Primary, accessed 2026-06-16:

- OSS-Fuzz docs — [Accepting new projects](https://google.github.io/oss-fuzz/getting-started/accepting-new-projects/),
  [New project guide](https://google.github.io/oss-fuzz/getting-started/new-project-guide/),
  [JavaScript (Jazzer.js)](https://google.github.io/oss-fuzz/getting-started/new-project-guide/javascript-lang/),
  [FAQ](https://google.github.io/oss-fuzz/faq/),
  [Bug disclosure](https://google.github.io/oss-fuzz/getting-started/bug-disclosure-guidelines/),
  [CIFuzz](https://google.github.io/oss-fuzz/getting-started/continuous-integration/),
  [ClusterFuzz](https://google.github.io/oss-fuzz/further-reading/clusterfuzz/).
- `google/oss-fuzz` project files: [v8](https://github.com/google/oss-fuzz/tree/master/projects/v8),
  [spidermonkey](https://github.com/google/oss-fuzz/tree/master/projects/spidermonkey),
  [quickjs](https://github.com/google/oss-fuzz/tree/master/projects/quickjs),
  [xs](https://github.com/google/oss-fuzz/tree/master/projects/xs).
- Maintainer confirmation that OSS-Fuzz JS fuzzing is not Fuzzilli:
  [PR #7675](https://github.com/google/oss-fuzz/pull/7675),
  [issue #925](https://github.com/google/oss-fuzz/issues/925).
- [Fuzzilli](https://github.com/googleprojectzero/fuzzilli) (README +
  `Targets/`; no OSS-Fuzz integration mentioned).
