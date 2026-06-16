// Copyright 2026 Cynic contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0

// Native differential profile for Cynic — an interpreter-vs-JIT
// correctness differential against ONE cynic-fuzz binary, invoked two
// ways. This is deliberately SEPARATE from `cynicProfile` (the clean
// crash-finding profile being upstreamed) so the base profile stays
// non-differential. See docs/fuzz-differential.md in the Cynic repo.
//
// How it works:
//   - target    runs `cynic-fuzz --jit --diff`  (Bistromath, threshold 1)
//   - reference runs `cynic-fuzz --diff`         (Lantern interpreter)
// Both halves run the SAME binary (Fuzzilli's reference runner reuses
// the single positional shell path) — only the args differ, which is
// the only shape Fuzzilli's differential mode supports.
//
// `--diff` makes cynic-fuzz write a canonical completion-value digest
// to fd 103 (fuzzout) after each sample. `differentialMode = .fuzzout`
// tells Fuzzilli to compare those two fuzzout strings instead of the
// V8-specific on-disk frame dumps; a mismatch is a candidate JIT
// miscompile (Fuzzer.executeFuzzoutDifferential).
//
// Carve-outs are a non-issue here: both halves are the same engine at
// the same posture (strict-only, no Annex B, --unhardened, --allow=eval
// — all fixed inside fuzz_main.zig), so every Cynic-intentional
// divergence is identical on both sides and cancels. The only residual
// noise source is run-to-run non-determinism, handled by the codePrefix
// shim below.
//
// To validate the oracle end-to-end without a real miscompile, pass
//   --additionalArguments=--diff-self-test
// which Fuzzilli appends to the TARGET args only — cynic-fuzz then
// perturbs the target's digest so every printing sample diverges.
let cynicDiffProfile = Profile(
    // Target: tier up to Bistromath and emit the differential digest.
    processArgs: { randomize in
        ["--jit", "--diff"]
    },

    // Reference: the Lantern interpreter, same digest. Non-nil makes
    // this an `isDifferential` profile.
    processArgsReference: [
        "--diff"
    ],

    // Compare fd-103 fuzzout, not V8 frame dumps.
    differentialMode: .fuzzout,

    processEnv: [:],

    maxExecsBeforeRespawn: 1000,

    // Looser than the base cynic profile's 500ms. A differential
    // sample executes twice (target + reference), the JIT half pays a
    // one-time compile on first call of every chunk (threshold forced
    // to 1), and an intentional `@panic` (FUZZILLI_CRASH) abort is
    // measurably slower under JIT — its first cold-start invocation
    // can spike past a tight bound. Fuzzilli's own measurement
    // recommends ~380ms here; 1500ms leaves comfortable headroom so a
    // cold start can't false-timeout the crash-detection startup test.
    timeout: Timeout.value(1500),

    // Determinism shim: a differential pair is two sequential REPRL
    // runs in two child processes, so any `Date.now()` / `Math.random()`
    // that leaks into a completion value would diverge spuriously. Pin
    // both to fixed, deterministic implementations. cynic-fuzz runs
    // `--unhardened`, so reassigning these primordials is allowed.
    // Kept minimal (no Proxy / Temporal) to avoid the shim itself
    // throwing on any sample.
    codePrefix: """
        (function () {
            var FIXED = 1767225600000;
            Date.now = function () { return FIXED; };
            var s = 305419896;
            Math.random = function () {
                s ^= s << 13; s ^= s >> 17; s ^= s << 5;
                return (s >>> 0) / 4294967296;
            };
        })();
        """,

    codeSuffix: "",

    ecmaVersion: ECMAScriptVersion.es6,

    startupTests: [
        // Same wiring checks as the base profile. Startup tests run
        // target-only (purpose .startup does not support a differential
        // run), so the --jit/--diff target validates the hooks.
        ("fuzzilli('FUZZILLI_PRINT', 'test')", .shouldSucceed),
        ("fuzzilli('FUZZILLI_CRASH', 0)", .shouldCrash),
        ("fuzzilli('FUZZILLI_CRASH', 1)", .shouldCrash),
        ("fuzzilli('FUZZILLI_CRASH', 2)", .shouldCrash),
    ],

    additionalCodeGenerators: [],

    additionalProgramTemplates: WeightedList<ProgramTemplate>([]),

    disabledCodeGenerators: [],

    disabledMutators: [],

    additionalBuiltins: [
        "placeholder": .function([] => .undefined)
    ],

    additionalObjectGroups: [],

    additionalEnumerations: [],

    additionalOptionsBags: [],

    optionalPostProcessor: nil
)
