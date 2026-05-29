//! Cynic build script. Requires Zig 0.14 or newer.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // QuickJS-NG libregexp — the §22.2 RegExp engine. Vendored
    // under `vendor/quickjs/` (MIT). Built as a static library
    // and linked into both the lib and exe modules so unit tests
    // and the CLI can run regex code. The C side calls back into
    // `lre_*` host hooks defined in `src/runtime/builtins/regexp.zig`.
    const qjs_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    qjs_mod.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs/libregexp.c",
            "vendor/quickjs/libunicode.c",
        },
        .flags = &.{
            "-std=c11",
            // _GNU_SOURCE exposes the POSIX symbols cutils.h reaches
            // for (`clock_gettime` / `CLOCK_MONOTONIC`, `readlink`,
            // `pthread_condattr_setclock`, `alloca` via stdlib.h)
            // under glibc's `-std=c11` feature gating. No-op on
            // Darwin/BSD where these are visible by default.
            "-D_GNU_SOURCE",
            "-Wno-unused-parameter",
            "-Wno-implicit-fallthrough",
            "-Wno-sign-compare",
            "-Wno-format-truncation",
            "-fno-sanitize=undefined",
        },
    });
    qjs_mod.addIncludePath(b.path("vendor/quickjs"));
    const qjs_regex = b.addLibrary(.{
        .linkage = .static,
        .name = "qjs_regex",
        .root_module = qjs_mod,
    });

    // Translate libregexp.h once; expose it as the `c` import. Cheaper
    // and forward-compatible vs `@cImport` in source (which Zig 0.17+
    // removed in favor of build-system translate-c).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/quickjs/libregexp.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_mod = translate_c.createModule();

    // Library module: everything except the CLI.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkLibrary(qjs_regex);
    lib_mod.addIncludePath(b.path("vendor/quickjs"));
    lib_mod.addImport("c", c_mod);

    // Executable module: the `cynic` CLI. Imports the library as `cynic`.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("cynic", lib_mod);
    exe_mod.linkLibrary(qjs_regex);
    exe_mod.addIncludePath(b.path("vendor/quickjs"));
    exe_mod.addImport("c", c_mod);

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

    // `zig build test-ses` — Phase 4 of
    // docs/handbook/ses-test262-policy.md. Hand-written SES
    // positive-coverage tests in `tests/ses/`. Each fixture is a
    // standalone JS file that throws on assertion failure; the
    // runner (`tools/test-ses.sh`) executes each via the installed
    // cynic CLI (hardened by default) and reports pass / fail by
    // exit code. The dual of the Phase 3 witness-inversion set
    // in `tools/test262/ses_witnesses.zig` — that one proves SES
    // breaks the spec where it should; this one proves SES
    // *enables* what it should (override-mistake shadowing,
    // `harden()` traversal, frozen-globalThis carve-outs).
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
    const gen_step = b.step("gen-unicode", "Regenerate src/unicode/{ident,property,case_fold}_tables.zig from UCD");
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
    });
    lib_mod_fast.linkLibrary(qjs_regex);
    lib_mod_fast.addIncludePath(b.path("vendor/quickjs"));
    lib_mod_fast.addImport("c", c_mod);
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
    });
    lib_mod_safe.linkLibrary(qjs_regex);
    lib_mod_safe.addIncludePath(b.path("vendor/quickjs"));
    lib_mod_safe.addImport("c", c_mod);
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
    });
    cynic_fast_mod.addImport("cynic", lib_mod_fast);
    cynic_fast_mod.linkLibrary(qjs_regex);
    cynic_fast_mod.addIncludePath(b.path("vendor/quickjs"));
    cynic_fast_mod.addImport("c", c_mod);
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

    // -----------------------------------------------------------------
    // `zig build wasm` — the browser-playground WebAssembly module.
    //
    // Builds `src/wasm.zig` + the vendored QuickJS C into a single
    // `wasm32-freestanding` `ReleaseSmall` module (download size
    // matters for a playground). Freestanding WASM has no libc, so
    // the C is paired with `src/wasm_shim.c`, a hand-written shim
    // routing `malloc` / `free` / `realloc` back into the Zig
    // `WasmAllocator` and providing the `mem*` / `str*` family.
    //
    // The artifact is installed to `zig-out/bin/cynic.wasm`. The
    // step then copies it next to the front-end into
    // `zig-out/playground/` so the directory is directly servable.
    // -----------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // QuickJS C for WASM — compiled with NDEBUG (drop `assert`) and
    // pointed at the freestanding shim's headers via the source
    // tree's own `vendor/quickjs` include path. No `-D_GNU_SOURCE`:
    // there is no glibc to feature-gate.
    const wasm_qjs_mod = b.createModule(.{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        // freestanding: no libc — the shim below supplies the C
        // runtime symbols the QuickJS sources reference.
    });
    wasm_qjs_mod.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs/libregexp.c",
            "vendor/quickjs/libunicode.c",
            "src/wasm_shim.c",
        },
        .flags = &.{
            "-std=c11",
            "-DNDEBUG",
            "-Wno-unused-parameter",
            "-Wno-implicit-fallthrough",
            "-Wno-sign-compare",
            "-Wno-format-truncation",
            "-fno-sanitize=undefined",
        },
    });
    // The libc stub headers must come BEFORE vendor/quickjs so a
    // freestanding `#include <stdlib.h>` resolves to the stub, not
    // a (missing) system header. See vendor/quickjs/wasm-libc/.
    wasm_qjs_mod.addIncludePath(b.path("vendor/quickjs/wasm-libc"));
    wasm_qjs_mod.addIncludePath(b.path("vendor/quickjs"));
    const wasm_qjs = b.addLibrary(.{
        .linkage = .static,
        .name = "qjs_regex_wasm",
        .root_module = wasm_qjs_mod,
    });

    // translate-c for the WASM target — same header, freestanding
    // ABI. Kept separate from the native `c_mod` because the
    // generated bindings are target-specific.
    const wasm_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/quickjs/libregexp.h"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        // freestanding has no libc — `addTranslateC` defaults this
        // to true and would otherwise propagate `-lc` to the final
        // link, which has no libc to provide.
        .link_libc = false,
    });
    // libregexp.h pulls in libunicode.h → <inttypes.h>; point
    // translate-c at the freestanding stub headers, stubs first.
    wasm_translate_c.addIncludePath(b.path("vendor/quickjs/wasm-libc"));
    wasm_translate_c.addIncludePath(b.path("vendor/quickjs"));
    const wasm_c_mod = wasm_translate_c.createModule();

    // Cynic library, built for WASM.
    const wasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_lib_mod.linkLibrary(wasm_qjs);
    wasm_lib_mod.addIncludePath(b.path("vendor/quickjs"));
    wasm_lib_mod.addImport("c", wasm_c_mod);

    // The WASM entry module — C-ABI exports for the JS front-end.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_mod.addImport("cynic", wasm_lib_mod);
    wasm_mod.linkLibrary(wasm_qjs);
    wasm_mod.addIncludePath(b.path("vendor/quickjs"));
    wasm_mod.addImport("c", wasm_c_mod);

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

    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
        .dest_sub_path = "cynic.wasm",
    });

    // Assemble a directly-servable playground directory:
    // zig-out/playground/{playground.html,playground.js,
    //                     codemirror.bundle.js,cynic.wasm}.
    // `codemirror.bundle.js` is the committed, offline-vendored
    // CodeMirror 6 editor bundle — see playground/codemirror.bundle.README.md.
    const wasm_into_playground = b.addInstallFileWithDir(
        wasm_exe.getEmittedBin(),
        .{ .custom = "playground" },
        "cynic.wasm",
    );
    const html_into_playground = b.addInstallFileWithDir(
        b.path("playground/playground.html"),
        .{ .custom = "playground" },
        "playground.html",
    );
    const js_into_playground = b.addInstallFileWithDir(
        b.path("playground/playground.js"),
        .{ .custom = "playground" },
        "playground.js",
    );
    const cm_into_playground = b.addInstallFileWithDir(
        b.path("playground/codemirror.bundle.js"),
        .{ .custom = "playground" },
        "codemirror.bundle.js",
    );

    const wasm_step = b.step("wasm", "Build the playground WASM module + assemble zig-out/playground/");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&wasm_into_playground.step);
    wasm_step.dependOn(&html_into_playground.step);
    wasm_step.dependOn(&js_into_playground.step);
    wasm_step.dependOn(&cm_into_playground.step);
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
