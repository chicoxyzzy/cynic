//! Cynic build script. Requires the Zig dev build pinned in build.zig.zon.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: everything except the CLI. Links libc on hosted
    // targets — `std.c.clock_gettime` backs GC pause timing (heap.zig) and
    // `Date.now` (date/temporal); the freestanding WASM build guards those
    // off. (libc used to come transitively via the vendored QuickJS lib,
    // which is gone now.)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Embedded only by the normalization unit test (`@embedFile` inside a
    // `test` block, so no cost to non-test builds): the full UAX #15
    // conformance suite, asserted against the native normalizer.
    lib_mod.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });

    // `-Dexhaustive-tests=true` flips on the two whole-range Unicode
    // invariant tests (case_conv whole-range + NormalizationTest.txt
    // UAX #15 conformance). Off by default because under Debug +
    // `testing.allocator` they dominate `zig build test` wall-time
    // (~15 min on Apple Silicon); CI runs them on Linux only, where
    // the same code paths are POSIX-clean and the allocator penalty
    // is half as bad.
    const exhaustive_tests = b.option(
        bool,
        "exhaustive-tests",
        "Enable the whole-range Unicode invariant tests (slow under Debug+testing.allocator). Default: false.",
    ) orelse false;
    // Dynamic opcode tracing is a dedicated instrumentation build. The
    // compile-time gate removes every dispatch counter access from normal
    // binaries; `cynic run --bytecode-stats` requires this option.
    const bytecode_stats = b.option(
        bool,
        "bytecode-stats",
        "Compile opcode/pair/trigram dispatch instrumentation (default false).",
    ) orelse false;
    // ECMA-402 build flavour (ROADMAP: separate from default edge/server
    // build — not a CLI `--enable`/`--allow` verb). `off` = no `Intl`
    // global, Temporal ISO+UTC/offset only; `stub` = structural Intl +
    // structural Temporal calendars/IANA; `full` = stub + embedded tzdata
    // (`vendor/tzdata/cynic_tzdb.bin`, refresh via `zig build pack-tzdata`).
    const IntlTier = enum { off, stub, full };
    const intl_tier_opt = b.option(
        IntlTier,
        "intl",
        "ECMA-402 build tier: off (default; no Intl), stub (structural Intl), full (tzdata + structural Intl). The test262 harness defaults to `full` so intl402 is scored against real CLDR/tzdata.",
    );
    const intl_tier = intl_tier_opt orelse .off;
    // The test262 conformance harness scores intl402 in-scope, so it
    // builds `full` by default (real CLDR/tzdata) while the `cynic`
    // binary stays `off`. An explicit `-Dintl=` overrides both.
    const t262_intl_tier = intl_tier_opt orelse .full;
    const lib_build_options = b.addOptions();
    lib_build_options.addOption(bool, "exhaustive_tests", exhaustive_tests);
    lib_build_options.addOption(bool, "bytecode_stats", bytecode_stats);
    lib_build_options.addOption(IntlTier, "intl", intl_tier);
    lib_mod.addOptions("build_options", lib_build_options);
    // Separate options for the test262 harness lib modules — same
    // `exhaustive_tests`, but the test262 intl tier (`full` default).
    const t262_build_options = b.addOptions();
    t262_build_options.addOption(bool, "exhaustive_tests", exhaustive_tests);
    t262_build_options.addOption(bool, "bytecode_stats", bytecode_stats);
    t262_build_options.addOption(IntlTier, "intl", t262_intl_tier);
    // Embed the locale data blobs (CYTZ tzdb + CYCL CLDR) only for `full`, so
    // off/stub binaries stay lean. Both are gated on `intl_config.has_locale_data`.
    const addLocaleData = struct {
        fn apply(mod: *std.Build.Module, bld: *std.Build, tier: IntlTier) void {
            if (tier == .full) {
                mod.addAnonymousImport("cynic_tzdb.bin", .{
                    .root_source_file = bld.path("vendor/tzdata/cynic_tzdb.bin"),
                });
                mod.addAnonymousImport("cynic_cldr.bin", .{
                    .root_source_file = bld.path("vendor/cldr/cynic_cldr.bin"),
                });
            }
        }
    }.apply;
    const addTzdb = addLocaleData;
    addLocaleData(lib_mod, b, intl_tier);

    // Executable module: the `cynic` CLI. Imports the library as `cynic`.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("cynic", lib_mod);

    const exe = b.addExecutable(.{
        .name = "cynic",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // `zig build fuzz` — the Fuzzilli REPRL host binary. Built with
    // `-fsanitize-coverage=trace-pc-guard` so every basic block calls
    // into `tools/fuzz/fuzz_coverage.zig`'s edge-tracking hooks (LLVM
    // emits the calls; Zig's `sanitize_coverage_trace_pc_guard` flag
    // wires it on). Kept separate from `cynic` because the
    // instrumentation imposes a per-edge function-call overhead that
    // production embedders shouldn't pay; cynic-fuzz is the sole
    // target Fuzzilli's profile points at.
    //
    // ReleaseSafe matches `cynic-test262-safe`'s posture: GC verifiers
    // (`verifyRememberedSet` / `verifyShapeInvariant`) and 0xaa
    // free-poison stay armed via `runtime_safety`, so a fuzz-found
    // use-after-free panics on the poisoned read instead of returning
    // garbage. Same reason `/gc-stress` reaches for the safe binary.
    //
    // `-Dfuzz-debug-alloc=true` is an opt-in posture knob (default
    // off, so the upstream-PR'd ReleaseSafe binary is unchanged): it
    // wraps the engine allocator in `std.heap.DebugAllocator(.{})`,
    // whose large-allocation path mmaps each payload on its own pages
    // and munmaps on free. That turns an overrun or use-after-free on
    // a non-GC byte payload — `JSString.bytes` (WTF-8) and ArrayBuffer
    // / TypedArray backing stores, both routed through the realm
    // allocator the fuzz host passes in — into a SIGSEGV at the exact
    // access, which ReleaseSafe's slice bounds checks don't cover for
    // raw computed-offset reads/writes. See docs/fuzzing.md
    // "Guard-page byte-payload campaign". GC-managed slab headers are
    // free-list-pooled (heap.zig) and stay invisible to this — that
    // class is the `FUZZ_GC_THRESHOLD` knob's job.
    const fuzz_debug_alloc = b.option(
        bool,
        "fuzz-debug-alloc",
        "Wrap the cynic-fuzz engine allocator in DebugAllocator for guard-page byte-payload detection (opt-in; default false).",
    ) orelse false;
    const fuzz_build_options = b.addOptions();
    fuzz_build_options.addOption(bool, "fuzz_debug_alloc", fuzz_debug_alloc);
    const cynic_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz/fuzz_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // Re-import the lib at ReleaseSafe so the fuzz binary is also
    // ReleaseSafe end-to-end (matches the test262-safe pattern).
    const lib_mod_fuzz = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    lib_mod_fuzz.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    lib_mod_fuzz.addOptions("build_options", lib_build_options);
    addTzdb(lib_mod_fuzz, b, intl_tier);
    cynic_fuzz_mod.addImport("cynic", lib_mod_fuzz);
    // The fuzz host reads its own `build_options` (the `fuzz_debug_alloc`
    // flag) — kept separate from the lib's options so the engine never
    // sees a fuzz-only knob.
    cynic_fuzz_mod.addOptions("build_options", fuzz_build_options);
    const cynic_fuzz = b.addExecutable(.{
        .name = "cynic-fuzz",
        .root_module = cynic_fuzz_mod,
    });
    // The flag Fuzzilli's coverage hooks need. LLVM emits a call
    // to `__sanitizer_cov_trace_pc_guard(*u32)` at every edge,
    // plus a one-time `__sanitizer_cov_trace_pc_guard_init` over
    // the `__sancov_guards` section — both defined in
    // `tools/fuzz/fuzz_coverage.zig`.
    cynic_fuzz.sanitize_coverage_trace_pc_guard = true;
    // LLVM's stack-depth probe destination (`__sancov_lowest_stack`)
    // is defined as a C `__thread` global — Zig's TLS layout on
    // macOS doesn't quite line up with the symbol shape LLVM's
    // sancov pass emits. See `tools/fuzz/fuzz_coverage_sancov.c`.
    cynic_fuzz_mod.addCSourceFile(.{
        .file = b.path("tools/fuzz/fuzz_coverage_sancov.c"),
        .flags = &.{},
    });
    const install_cynic_fuzz = b.addInstallArtifact(cynic_fuzz, .{});
    const fuzz_step = b.step("fuzz", "Build cynic-fuzz — the Fuzzilli REPRL host (ReleaseSafe + sanitize-coverage)");
    fuzz_step.dependOn(&install_cynic_fuzz.step);

    // `zig build run -- ...` runs the CLI with forwarded args.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the cynic executable");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs lib + exe unit tests.
    const test_filter = b.option([]const u8, "test-filter", "Filter unit tests by name");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const lib_tests = b.addTest(.{ .root_module = lib_mod, .filters = test_filters });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe_mod, .filters = test_filters });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build test-fuzz` runs the Fuzzilli REPRL host unit tests
    // (the REPRL protocol encoder + the coverage-hook arithmetic).
    // These live in `tools/fuzz/`, outside `src/`, so the production
    // `cynic` binary carries no fuzzing code; they gate separately
    // from `zig build test`. A plain (uninstrumented) optimize mode
    // is deliberate — the tests cover the protocol/arithmetic logic,
    // not the sancov instrumentation, and `fuzz_coverage.zig`'s
    // `export fn` sancov hooks compile fine without the `.c` shim in
    // a non-instrumented build.
    const fuzz_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuzz_tests_mod.addImport("cynic", lib_mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_tests_mod, .filters = test_filters });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const test_fuzz_step = b.step("test-fuzz", "Run the Fuzzilli REPRL host unit tests");
    test_fuzz_step.dependOn(&run_fuzz_tests.step);

    // `zig build test-ses` — hand-written SES positive-coverage
    // tests in `tests/ses/`. Each fixture is a standalone JS file
    // that throws on assertion failure; the runner
    // (`tools/test-ses.sh`) executes each via the installed cynic
    // CLI (hardened by default) and reports pass / fail by exit
    // code. Proves SES *enables* what it should (override-mistake
    // shadowing, `harden()` traversal, frozen-globalThis carve-outs).
    const ses_runner = b.addSystemCommand(&.{ "bash", "tools/test-ses.sh" });
    ses_runner.step.dependOn(b.getInstallStep());
    const ses_step = b.step("test-ses", "Run the Cynic-authored SES positive-coverage tests");
    ses_step.dependOn(&ses_runner.step);

    // `zig build gen-unicode` regenerates the committed Unicode tables from
    // the vendored UCD files: src/unicode/ident_tables.zig (lexer identifier
    // predicates) and src/unicode/property_tables.zig (RegExp `\p{…}`). Run
    // manually when bumping the Unicode target — the generated files are
    // committed and are what the engine compiles against, so the default
    // build does NOT depend on this step.
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_unicode_idents.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_exe = b.addExecutable(.{
        .name = "gen_unicode_idents",
        .root_module = gen_mod,
    });
    const run_gen = b.addRunArtifact(gen_exe);
    run_gen.addFileArg(b.path("vendor/unicode/DerivedCoreProperties.txt"));
    run_gen.addArg(sourceRootPath(b, "src/unicode/ident_tables.zig"));
    const gen_step = b.step("gen-unicode", "Regenerate src/unicode/{ident,property,case_fold,case_conv,normalization}_tables.zig from UCD");
    gen_step.dependOn(&run_gen.step);

    // `zig build pack-tzdata` compiles vendored IANA tzdata *sources*
    // (`vendor/tzdata/iana/`, refreshed via `tools/fetch-tzdata.sh` from
    // data.iana.org — same role as dropping UCD files into `vendor/unicode/`)
    // with system `zic`, then runs `tools/pack_tzdata.zig` to emit the
    // committed CYTZ blob. Only `-Dintl=full` embeds the blob.
    const pack_tz_mod = b.createModule(.{
        .root_source_file = b.path("tools/pack_tzdata.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pack_tz_exe = b.addExecutable(.{
        .name = "pack_tzdata",
        .root_module = pack_tz_mod,
    });
    const run_compile_iana = b.addSystemCommand(&.{ "bash", "tools/compile-iana-tzdata.sh" });
    run_compile_iana.addArtifactArg(pack_tz_exe);
    run_compile_iana.addArg(sourceRootPath(b, ""));
    // Re-run when IANA sources change (not every build — only this step).
    run_compile_iana.addFileInput(b.path("vendor/tzdata/iana/version"));
    run_compile_iana.addFileInput(b.path("tools/compile-iana-tzdata.sh"));
    const pack_tz_step = b.step("pack-tzdata", "Compile vendor/tzdata/iana/ (IANA sources) via zic + pack cynic_tzdb.bin (refresh sources: tools/fetch-tzdata.sh)");
    pack_tz_step.dependOn(&run_compile_iana.step);

    const fetch_tz = b.addSystemCommand(&.{ "bash", "tools/fetch-tzdata.sh" });
    const fetch_tz_step = b.step("fetch-tzdata", "Download latest IANA tzdata sources into vendor/tzdata/iana/ and repack cynic_tzdb.bin");
    fetch_tz_step.dependOn(&fetch_tz.step);

    // `zig build pack-cldr` reads vendored CLDR-JSON sources
    // (`vendor/cldr/json/`, refreshed via `tools/fetch-cldr.sh` from the npm
    // registry) and emits the committed CYCL blob. Only `-Dintl=full` embeds
    // it (see addLocaleData). The raw JSON is gitignored; the blob is tracked.
    const pack_cldr_mod = b.createModule(.{
        .root_source_file = b.path("tools/pack_cldr.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pack_cldr_exe = b.addExecutable(.{
        .name = "pack_cldr",
        .root_module = pack_cldr_mod,
    });
    const run_pack_cldr = b.addRunArtifact(pack_cldr_exe);
    run_pack_cldr.addArg("--cldr-json");
    run_pack_cldr.addArg(sourceRootPath(b, "vendor/cldr/json"));
    run_pack_cldr.addArg("-o");
    run_pack_cldr.addArg(sourceRootPath(b, "vendor/cldr/cynic_cldr.bin"));
    const pack_cldr_step = b.step("pack-cldr", "Pack vendor/cldr/json/ (CLDR-JSON sources) into cynic_cldr.bin (refresh sources: tools/fetch-cldr.sh)");
    pack_cldr_step.dependOn(&run_pack_cldr.step);

    const fetch_cldr = b.addSystemCommand(&.{ "bash", "tools/fetch-cldr.sh" });
    const fetch_cldr_step = b.step("fetch-cldr", "Download CLDR-JSON sources into vendor/cldr/json/ and repack cynic_cldr.bin");
    fetch_cldr_step.dependOn(&fetch_cldr.step);

    const gen_props_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_unicode_props.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_props_exe = b.addExecutable(.{
        .name = "gen_unicode_props",
        .root_module = gen_props_mod,
    });
    const run_gen_props = b.addRunArtifact(gen_props_exe);
    run_gen_props.addArg(sourceRootPath(b, "src/unicode/property_tables.zig"));
    run_gen_props.addFileArg(b.path("vendor/unicode/DerivedGeneralCategory.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/DerivedCoreProperties.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/PropList.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/emoji-data.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/DerivedBinaryProperties.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/DerivedNormalizationProps.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/PropertyValueAliases.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/Scripts.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/ScriptExtensions.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/emoji-sequences.txt"));
    run_gen_props.addFileArg(b.path("vendor/unicode/emoji-zwj-sequences.txt"));
    gen_step.dependOn(&run_gen_props.step);

    // src/unicode/case_fold_tables.zig (RegExp `/iu`/`/iv` case folding,
    // §22.2.2.9) from the vendored CaseFolding.txt — same on-demand model.
    const gen_cf_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_case_fold.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_cf_exe = b.addExecutable(.{
        .name = "gen_case_fold",
        .root_module = gen_cf_mod,
    });
    const run_gen_cf = b.addRunArtifact(gen_cf_exe);
    run_gen_cf.addArg(sourceRootPath(b, "src/unicode/case_fold_tables.zig"));
    run_gen_cf.addFileArg(b.path("vendor/unicode/CaseFolding.txt"));
    gen_step.dependOn(&run_gen_cf.step);

    // src/unicode/case_conv_tables.zig (String.prototype.to{Lower,Upper}Case
    // §22.1.3.26/27 + the non-/u RegExp Canonicalize §22.2.2.7.3) from
    // UnicodeData.txt (simple mappings) + SpecialCasing.txt (unconditional
    // full mappings) + DerivedCoreProperties.txt (Cased / Case_Ignorable).
    const gen_cc_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_case_conv.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_cc_exe = b.addExecutable(.{
        .name = "gen_case_conv",
        .root_module = gen_cc_mod,
    });
    const run_gen_cc = b.addRunArtifact(gen_cc_exe);
    run_gen_cc.addArg(sourceRootPath(b, "src/unicode/case_conv_tables.zig"));
    run_gen_cc.addFileArg(b.path("vendor/unicode/UnicodeData.txt"));
    run_gen_cc.addFileArg(b.path("vendor/unicode/SpecialCasing.txt"));
    run_gen_cc.addFileArg(b.path("vendor/unicode/DerivedCoreProperties.txt"));
    gen_step.dependOn(&run_gen_cc.step);

    // src/unicode/normalization_tables.zig (String.prototype.normalize
    // §22.1.3.16 NFC/NFD/NFKC/NFKD + the localeCompare NFD path) from
    // UnicodeData.txt (combining class + decomposition) and
    // DerivedNormalizationProps.txt (Full_Composition_Exclusion).
    const gen_nf_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_normalization.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_nf_exe = b.addExecutable(.{
        .name = "gen_normalization",
        .root_module = gen_nf_mod,
    });
    const run_gen_nf = b.addRunArtifact(gen_nf_exe);
    run_gen_nf.addArg(sourceRootPath(b, "src/unicode/normalization_tables.zig"));
    run_gen_nf.addFileArg(b.path("vendor/unicode/UnicodeData.txt"));
    run_gen_nf.addFileArg(b.path("vendor/unicode/DerivedNormalizationProps.txt"));
    gen_step.dependOn(&run_gen_nf.step);

    // `zig build fmt-check` runs `zig fmt --check` over `src/` and
    // `tools/`. Advisory in CI (non-gating) — flags drift on PR
    // review without blocking merges when an agent's Edit-tool
    // shape doesn't quite match `zig fmt`. Local `zig fmt src
    // tools` rewrites in place. Add new top-level dirs here as
    // they appear.
    const fmt_check = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "tools" }),
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Verify src/ + tools/ are zig-fmt clean");
    fmt_check_step.dependOn(&fmt_check.step);

    const fmt_fix = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "tools" }),
        .check = false,
    });
    const fmt_step = b.step("fmt", "Apply zig fmt to src/ + tools/ in place");
    fmt_step.dependOn(&fmt_fix.step);

    // `zig build test262` runs the parser-only conformance harness over
    // the corpus at vendor/test262/test (or `--corpus=<path>`). Imports
    // the library as `cynic`. Forward args after `--`.
    //
    // Always built ReleaseFast — the harness churns through ~50k tests
    // and Debug-mode JS execution is 5-10× slower. `-Dtest262-debug=true`
    // forces Debug for stack-traces-on-panic. The cynic library is
    // re-imported under `lib_mod_fast` so it's also ReleaseFast.
    const test262_debug = b.option(bool, "test262-debug", "Build the test262 harness in Debug for stack traces") orelse false;
    const t262_optimize: std.builtin.OptimizeMode = if (test262_debug) .Debug else .ReleaseFast;
    const lib_mod_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = t262_optimize,
        .link_libc = true,
    });
    lib_mod_fast.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    lib_mod_fast.addOptions("build_options", lib_build_options);
    addTzdb(lib_mod_fast, b, intl_tier);
    // Dedicated lib module for the test262 harness at the test262 intl
    // tier (`full` by default) so intl402 runs against real CLDR/tzdata.
    // wasm-testsuite / wasm-bench / bench keep `lib_mod_fast` at the
    // global tier — they don't touch Intl and shouldn't embed the blob.
    const lib_mod_t262 = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = t262_optimize,
        .link_libc = true,
    });
    lib_mod_t262.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    lib_mod_t262.addOptions("build_options", t262_build_options);
    addLocaleData(lib_mod_t262, b, t262_intl_tier);
    const t262_mod = b.createModule(.{
        .root_source_file = b.path("tools/test262.zig"),
        .target = target,
        .optimize = t262_optimize,
    });
    t262_mod.addImport("cynic", lib_mod_t262);

    // Note: the cynic / test262 SHAs stamped into `--write-results`
    // rows are captured at *write time* by `tools/test262.zig`, not
    // here. Capturing at build time looked tidier but the Zig build
    // cache reuses the previous configure when nothing in the build
    // graph changes, so commits made between two `zig build test262`
    // invocations would not invalidate a build-time `git rev-parse`
    // and the row would land with a stale SHA. See `currentShortSha`
    // in tools/test262.zig.

    const t262_exe = b.addExecutable(.{
        .name = "cynic-test262",
        .root_module = t262_mod,
    });
    // Install the harness binary so it can be invoked directly —
    // `./zig-out/bin/cynic-test262 --filter=…` — without paying the
    // `zig build` graph cost (and its flakiness) on every filtered
    // iteration. `zig build test262` still builds + runs as before.
    const install_t262 = b.addInstallArtifact(t262_exe, .{});
    const run_t262 = b.addRunArtifact(t262_exe);
    run_t262.step.dependOn(&install_t262.step);
    run_t262.addPassthruArgs();
    const t262_step = b.step("test262", "Run the test262 conformance suite (parser-only)");
    t262_step.dependOn(&run_t262.step);

    // `zig build wasm-testsuite` — Sarcasm conformance against the
    // official WebAssembly spec testsuite. The `.wast` corpus is
    // preprocessed to JSON + `.wasm` by wast2json
    // (tools/wasm-testsuite-gen.sh); the harness then replays the
    // assertions. Defaults to the in-tree smoke corpus; point
    // `-Dwasm-corpus=` at `vendor/wasm-testsuite` once vendored.
    const wts_mod = b.createModule(.{
        .root_source_file = b.path("tools/wasm_testsuite.zig"),
        .target = target,
        .optimize = t262_optimize,
    });
    wts_mod.addImport("cynic", lib_mod_fast);
    const wts_exe = b.addExecutable(.{
        .name = "cynic-wasm-testsuite",
        .root_module = wts_mod,
    });
    const install_wts = b.addInstallArtifact(wts_exe, .{});
    const wts_corpus = b.option([]const u8, "wasm-corpus", "Directory of .wast spec tests (default: tools/wasm-testsuite-smoke)") orelse "tools/wasm-testsuite-smoke";
    const wts_gendir = ".zig-cache/wasm-testsuite";
    const wts_gen = b.addSystemCommand(&.{ "sh", "tools/wasm-testsuite-gen.sh" });
    wts_gen.addArg(wts_corpus);
    wts_gen.addArg(wts_gendir);
    wts_gen.has_side_effects = true; // always re-convert; output isn't graph-tracked
    const run_wts = b.addRunArtifact(wts_exe);
    run_wts.step.dependOn(&install_wts.step);
    run_wts.step.dependOn(&wts_gen.step);
    run_wts.addArg(b.fmt("--gen-dir={s}", .{wts_gendir}));
    run_wts.addPassthruArgs();
    const wts_step = b.step("wasm-testsuite", "Run the WebAssembly spec testsuite conformance harness");
    wts_step.dependOn(&run_wts.step);

    // `zig build wasm-bench` — standalone ReleaseFast micro-benchmark
    // for the Sarcasm interpreter (dispatch-bound workloads), so a
    // hot-loop change can be measured against a fixed baseline.
    const wbench_mod = b.createModule(.{
        .root_source_file = b.path("tools/wasm_bench.zig"),
        .target = target,
        .optimize = t262_optimize,
    });
    wbench_mod.addImport("cynic", lib_mod_fast);
    const wbench_exe = b.addExecutable(.{
        .name = "cynic-wasm-bench",
        .root_module = wbench_mod,
    });
    const run_wbench = b.addRunArtifact(wbench_exe);
    run_wbench.addPassthruArgs();
    const wbench_step = b.step("wasm-bench", "Run the WebAssembly interpreter micro-benchmark");
    wbench_step.dependOn(&run_wbench.step);

    // The frontmatter / skip helper modules under tools/test262/ get
    // their inline `test` blocks picked up via the t262 module's test
    // walk.
    const t262_tests = b.addTest(.{ .root_module = t262_mod });
    const run_t262_tests = b.addRunArtifact(t262_tests);
    test_step.dependOn(&run_t262_tests.step);

    // `zig build test-fast` — the same unit tests as `test`, but the
    // lib + exe binaries are built ReleaseSafe instead of Debug. Most
    // of the unit suite eval's JS through the engine, and Debug-mode
    // JS execution is 5-10× slower (the same reason the test262 harness
    // is never Debug) — so a full Debug `test` run is run-bound and can
    // exceed ten minutes, while ReleaseSafe finishes in ~3. ReleaseSafe
    // keeps every safety check, arms the GC verifiers
    // (`verifyRememberedSet` / `verifyShapeInvariant`) + the 0xaa
    // free-poison (all gated on `runtime_safety`, hence no-ops in
    // ReleaseFast), and `std.testing.allocator` leak detection still
    // fires — so it is a faithful gate, not a weaker one. `test`
    // (Debug) stays the canonical stack-trace-on-panic path. Both
    // honour `-Dtest-filter=<name>`.
    const lib_mod_test_safe = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    lib_mod_test_safe.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    lib_mod_test_safe.addOptions("build_options", lib_build_options);
    addTzdb(lib_mod_test_safe, b, intl_tier);
    const exe_mod_test_safe = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    exe_mod_test_safe.addImport("cynic", lib_mod_test_safe);
    const safe_lib_tests = b.addTest(.{ .root_module = lib_mod_test_safe, .filters = test_filters });
    const safe_exe_tests = b.addTest(.{ .root_module = exe_mod_test_safe, .filters = test_filters });
    const test_fast_step = b.step("test-fast", "Run all unit tests built ReleaseSafe — finishes in ~3 min vs the Debug `test` step's 10+; keeps safety checks, GC verifiers, leak detection");
    test_fast_step.dependOn(&b.addRunArtifact(safe_lib_tests).step);
    test_fast_step.dependOn(&b.addRunArtifact(safe_exe_tests).step);
    test_fast_step.dependOn(&run_t262_tests.step);

    // A second harness binary, built ReleaseSafe and installed under
    // a DISTINCT name (`cynic-test262-safe`) so it coexists with the
    // ReleaseFast `cynic-test262` — build each once and invoke either
    // directly, no recompile-and-clobber when switching between fast
    // sweeps and GC diagnosis. ReleaseSafe keeps the GC verifiers
    // (`verifyRememberedSet` / `verifyShapeInvariant`) and the 0xaa
    // free-poison live — all gated on `runtime_safety`, hence no-ops
    // in ReleaseFast — while running ~2-3× faster than Debug. That
    // makes it the right binary for the `/gc-stress` workflow: a
    // use-after-free derefs poison deterministically and panics with
    // a stack trace. `-Dtest262-debug=true` still flips the primary
    // binary to Debug for the rare zero-inlining full-trace case.
    const lib_mod_safe = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    lib_mod_safe.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    lib_mod_safe.addOptions("build_options", t262_build_options);
    addTzdb(lib_mod_safe, b, t262_intl_tier);
    const t262_mod_safe = b.createModule(.{
        .root_source_file = b.path("tools/test262.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    t262_mod_safe.addImport("cynic", lib_mod_safe);
    const t262_exe_safe = b.addExecutable(.{
        .name = "cynic-test262-safe",
        .root_module = t262_mod_safe,
    });
    const install_t262_safe = b.addInstallArtifact(t262_exe_safe, .{});
    const run_t262_safe = b.addRunArtifact(t262_exe_safe);
    run_t262_safe.step.dependOn(&install_t262_safe.step);
    run_t262_safe.addPassthruArgs();
    const t262_safe_step = b.step("test262-safe", "Build + run the test262 harness in ReleaseSafe (GC verifiers + 0xaa poison live; for /gc-stress)");
    t262_safe_step.dependOn(&run_t262_safe.step);

    // `zig build bench` — Phase 1 micro-bench driver from
    // docs/benchmarking.md. Spawns a ReleaseFast cynic CLI per
    // fixture in `bench/micros/`, captures wall time + peak RSS,
    // prints medians.
    //
    // The default `zig build` builds cynic in the user-selected
    // optimize mode (Debug by default), which is 5-10× slower
    // and useless for perf signal. `bench` instead builds a
    // dedicated `cynic-bench` binary in ReleaseFast and writes
    // it next to the regular install. The harness driver spawns
    // *that* binary.
    const cynic_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    cynic_fast_mod.addImport("cynic", lib_mod_fast);
    const cynic_fast = b.addExecutable(.{
        .name = "cynic-bench",
        .root_module = cynic_fast_mod,
    });
    const install_cynic_fast = b.addInstallArtifact(cynic_fast, .{});

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(&install_cynic_fast.step);
    // Forward args after `--` so `zig build bench -- --runs=40`
    // reaches the driver (tail-percentile sample-budget knob).
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run the micro-bench suite (p50 + spread + outliers; --runs=N for tail percentiles)");
    bench_step.dependOn(&run_bench.step);

    // (The `bench-regex` Perlex-vs-libregexp matcher benchmark — the
    // decision gate for retiring the vendored fallback — was removed
    // with libregexp itself; there is no second engine to compare
    // against. Its final numbers live in docs/ROADMAP.md under "Regex".)

    // -----------------------------------------------------------------
    // `zig build wasm` — the browser-playground WebAssembly module.
    //
    // Builds `playground/wasm.zig` into a single `wasm32-freestanding`
    // `ReleaseSmall` module (download size matters for a playground).
    // Pure Zig now that Perlex + the native Unicode tables replaced the
    // vendored QuickJS C — no libc shim, no C sources to link.
    //
    // The artifact is installed to `zig-out/bin/cynic.wasm`. The
    // step then copies it next to the front-end into
    // `zig-out/playground/` so the directory is directly servable.
    // -----------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Cynic library, built for WASM. Pure Zig — no C to link.
    const wasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_lib_mod.addAnonymousImport("NormalizationTest.txt", .{
        .root_source_file = b.path("vendor/unicode/NormalizationTest.txt"),
    });
    wasm_lib_mod.addOptions("build_options", lib_build_options);
    addTzdb(wasm_lib_mod, b, intl_tier);

    // The WASM entry module — C-ABI exports for the JS front-end.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("playground/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_mod.addImport("cynic", wasm_lib_mod);

    // Stamp the build's git short-SHA into the module so the
    // playground footer names the exact commit. `build.zig`'s
    // configure phase re-runs on every `zig build`, so the SHA is
    // re-read each invocation; if it changed, the option value
    // changes and the wasm step recompiles. (Unlike the test262
    // score rows — see the note above — a configure-time capture
    // is correct here: the value flows through a compile step, so
    // a changed SHA invalidates the cache on its own.)
    const wasm_opts = b.addOptions();
    wasm_opts.addOption([]const u8, "wasm_version", b.fmt("cynic-wasm {s}", .{gitShortSha(b)}));
    wasm_mod.addOptions("build_options", wasm_opts);

    const wasm_exe = b.addExecutable(.{
        .name = "cynic",
        .root_module = wasm_mod,
    });
    // A reactor-style module: no `main`, just exports the JS side
    // imports. `rdynamic` keeps every `export fn` in the symbol
    // table; `entry = .disabled` because there is no process start.
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    // Grow linear memory on demand — the engine allocates per eval.
    wasm_exe.import_memory = false;
    wasm_exe.max_memory = 256 * 1024 * 1024;

    // Optionally post-process with `wasm-opt -Oz` (Binaryen) when it's
    // on PATH. Zig emits no target-features section, so every feature
    // the module actually uses must be named explicitly — otherwise
    // wasm-opt rejects the bulk-memory ops the engine relies on. When
    // wasm-opt is absent (most dev machines), fall back to the raw
    // ReleaseSmall binary so `zig build wasm` still works offline. CI
    // installs Binaryen, so the published artifact is normally optimized
    // (~13% smaller than ReleaseSmall alone).
    //
    // `-Dno-wasm-opt` forces the raw module even when wasm-opt is present.
    // The playground deploy uses it as a fallback: `wasm-opt -Oz` has
    // SIGSEGV'd on the constrained CI runner while optimizing the engine's
    // ~1 MB interpreter-dispatch function (it succeeds on a dev box), and
    // a crashing optimizer must not block the deploy — a valid unoptimized
    // module beats none. See .github/workflows/playground.yml.
    const skip_wasm_opt = b.option(
        bool,
        "no-wasm-opt",
        "Skip the wasm-opt -Oz post-pass; ship the raw ReleaseSmall playground module",
    ) orelse false;

    const raw_wasm = wasm_exe.getEmittedBin();
    const wasm_bin: std.Build.LazyPath = blk: {
        if (skip_wasm_opt) break :blk raw_wasm;
        if (b.findProgram(.{ .names = &.{"wasm-opt"} })) |wasm_opt_path| {
            const opt = b.addSystemCommand(&.{
                wasm_opt_path,
                "-Oz",
                "--enable-bulk-memory",
                "--enable-bulk-memory-opt",
                "--enable-sign-ext",
                "--enable-nontrapping-float-to-int",
                "--enable-mutable-globals",
                "--enable-multivalue",
            });
            opt.addFileArg(raw_wasm);
            opt.addArg("-o");
            break :blk opt.addOutputFileArg("cynic.wasm");
        }
        break :blk raw_wasm;
    };

    const install_wasm = b.addInstallFileWithDir(
        wasm_bin,
        .{ .custom = "bin" },
        "cynic.wasm",
    );

    // Assemble the *engine half* of the playground into
    // zig-out/playground/{cynic.wasm, cynic-engine.js}. These are the
    // two artifacts the engine owns and CI publishes to
    // `gh-pages:/playground/`; the website half (index.html, app.js,
    // codemirror.bundle.js) lives on the `gh-pages` branch and imports
    // `cynic-engine.js` — the stable ABI binding that tracks
    // `playground/wasm.zig`. See docs/playground.md.
    const wasm_into_playground = b.addInstallFileWithDir(
        wasm_bin,
        .{ .custom = "playground" },
        "cynic.wasm",
    );
    const engine_js_into_playground = b.addInstallFileWithDir(
        b.path("playground/cynic-engine.js"),
        .{ .custom = "playground" },
        "cynic-engine.js",
    );

    const wasm_step = b.step("wasm", "Build the playground WASM module + glue into zig-out/playground/");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&wasm_into_playground.step);
    wasm_step.dependOn(&engine_js_into_playground.step);
}

/// `git rev-parse --short HEAD` at configure time. Returns
/// `"unknown"` when git is absent or the command fails (a source
/// tarball, a detached build environment) so the build never hard-
/// fails on a missing VCS.
fn gitShortSha(b: *std.Build) []const u8 {
    // `runAllowFail` only writes `out_code` on a failure term; a
    // non-zero git exit surfaces as `error.ExitCodeFailure`, so the
    // `catch` covers every failure path and `code` is never read.
    var code: u8 = undefined;
    const stdout = b.runAllowFail(
        &.{ "git", "-C", sourceRootPath(b, ""), "rev-parse", "--short", "HEAD" },
        &code,
        .ignore,
    ) catch return "unknown";
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    return if (trimmed.len == 0) "unknown" else trimmed;
}

fn sourceRootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.graph.arena, sub_path) catch @panic("OOM");
}
