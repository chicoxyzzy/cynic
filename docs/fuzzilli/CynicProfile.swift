// Copyright 2025 Cynic contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0

let cynicProfile = Profile(
    // `cynic-fuzz` is a fixed-posture binary: it always runs in REPRL
    // mode against the inherited control/data fds. No per-run args
    // are needed (the SES posture, --allow=eval, and installTestGlobals
    // are hardcoded inside fuzz_main.zig). Compare with qjs which
    // takes ["--reprl"] because its main binary supports more modes.
    processArgs: { randomize in
        []
    },

    processArgsReference: nil,

    // No special env. UBSAN_OPTIONS lives in the qjs / xs profiles
    // because those builds use UBSan; cynic-fuzz is ReleaseSafe with
    // Zig's runtime safety checks (which arm via panic, not UBSan),
    // so no override needed.
    processEnv: [:],

    maxExecsBeforeRespawn: 1000,

    // 500ms per sample — Fuzzilli's first-run diagnostic flagged 250
    // as too tight (recommended floor was 460ms; observed timeout
    // rate was 11%). Cynic's tree-walking-ish bytecode interpreter
    // is meaningfully slower than V8/JSC and even QJS for deeply
    // nested generated samples; the headroom keeps the timeout
    // bucket under ~3%.
    timeout: Timeout.value(500),

    codePrefix: "",

    codeSuffix: "",

    // Cynic targets ES2025. Fuzzilli's ECMAScriptVersion enum tops
    // out at es6 in the public API; the actual generator targets
    // newer features regardless, so es6 here just gates the
    // engine-feature-detection startup tests.
    ecmaVersion: ECMAScriptVersion.es6,

    startupTests: [
        // Verify the fuzzilli host hook is wired up.
        ("fuzzilli('FUZZILLI_PRINT', 'test')", .shouldSucceed),

        // Verify the crash channel works. Cynic's FUZZILLI_CRASH op
        // is single-flavor (`@panic("FUZZILLI_CRASH")` regardless of
        // the integer arg), so codes 0/1/2 all trigger the same
        // abort path. Listing all three matches the qjs profile and
        // confirms the parent's crash-detection works for each one.
        ("fuzzilli('FUZZILLI_CRASH', 0)", .shouldCrash),
        ("fuzzilli('FUZZILLI_CRASH', 1)", .shouldCrash),
        ("fuzzilli('FUZZILLI_CRASH', 2)", .shouldCrash),
    ],

    additionalCodeGenerators: [],

    additionalProgramTemplates: WeightedList<ProgramTemplate>([]),

    // No JIT, no Wasm — but Fuzzilli's default generators handle that
    // gracefully (samples that reference unsupported intrinsics
    // surface as normal throws). Empty disables list keeps the
    // profile minimal until we see what trips up cynic in practice.
    disabledCodeGenerators: [],

    disabledMutators: [],

    // `placeholder()` — matches the qjs convention; some generated
    // samples reference an unknown global, and a typed stub keeps
    // the type-inference engine happy without changing semantics.
    additionalBuiltins: [
        "placeholder": .function([] => .undefined)
    ],

    additionalObjectGroups: [],

    additionalEnumerations: [],

    additionalOptionsBags: [],

    optionalPostProcessor: nil
)
