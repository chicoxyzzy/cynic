//! Cynic build script. Requires Zig 0.14 or newer.

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
    const lib_build_options = b.addOptions();
    lib_build_options.addOption(bool, "exhaustive_tests", exhaustive_tests);
    lib_mod.addOptions("build_options", lib_build_options);

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

    // `zig build run -- ...` runs the CLI with forwarded args.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
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
    run_gen.addArg(b.pathFromRoot("src/unicode/ident_tables.zig"));
    const gen_step = b.step("gen-unicode", "Regenerate src/unicode/{ident,property,case_fold,case_conv,normalization}_tables.zig from UCD");
    gen_step.dependOn(&run_gen.step);

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
    run_gen_props.addArg(b.pathFromRoot("src/unicode/property_tables.zig"));
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
    run_gen_cf.addArg(b.pathFromRoot("src/unicode/case_fold_tables.zig"));
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
    run_gen_cc.addArg(b.pathFromRoot("src/unicode/case_conv_tables.zig"));
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
    run_gen_nf.addArg(b.pathFromRoot("src/unicode/normalization_tables.zig"));
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
        .paths = &.{ "src", "tools" },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Verify src/ + tools/ are zig-fmt clean");
    fmt_check_step.dependOn(&fmt_check.step);

    const fmt_fix = b.addFmt(.{
        .paths = &.{ "src", "tools" },
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
    const t262_mod = b.createModule(.{
        .root_source_file = b.path("tools/test262.zig"),
        .target = target,
        .optimize = t262_optimize,
    });
    t262_mod.addImport("cynic", lib_mod_fast);

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
    if (b.args) |args| run_t262.addArgs(args);
    const t262_step = b.step("test262", "Run the test262 conformance suite (parser-only)");
    t262_step.dependOn(&run_t262.step);

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
    if (b.args) |args| run_t262_safe.addArgs(args);
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
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the micro-bench suite (p50 + spread + outliers; --runs=N for tail percentiles)");
    bench_step.dependOn(&run_bench.step);

    // (The `bench-regex` Perlex-vs-libregexp matcher benchmark — the
    // decision gate for retiring the vendored fallback — was removed
    // with libregexp itself; there is no second engine to compare
    // against. Its final numbers live in docs/ROADMAP.md under "Regex".)

    // -----------------------------------------------------------------
    // `zig build wasm` — the browser-playground WebAssembly module.
    //
    // Builds `src/wasm.zig` into a single `wasm32-freestanding`
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

    // The WASM entry module — C-ABI exports for the JS front-end.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
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
    // installs Binaryen, so the published artifact is always optimized
    // (~13% smaller than ReleaseSmall alone).
    const raw_wasm = wasm_exe.getEmittedBin();
    const wasm_bin: std.Build.LazyPath = if (b.findProgram(&.{"wasm-opt"}, &.{})) |wasm_opt_path| blk: {
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
    } else |_| raw_wasm;

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
    // `src/wasm.zig`. See docs/playground.md.
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
        &.{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--short", "HEAD" },
        &code,
        .ignore,
    ) catch return "unknown";
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    return if (trimmed.len == 0) "unknown" else trimmed;
}
