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
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build gen-unicode` regenerates src/unicode/ident_tables.zig from
    // vendor/unicode/DerivedCoreProperties.txt. Run manually when bumping the
    // Unicode target — the generated file is committed and is what the lexer
    // compiles against, so the default build does NOT depend on this step.
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
    const gen_step = b.step("gen-unicode", "Regenerate src/unicode/ident_tables.zig from UCD");
    gen_step.dependOn(&run_gen.step);

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
        .name = "test262",
        .root_module = t262_mod,
    });
    const run_t262 = b.addRunArtifact(t262_exe);
    if (b.args) |args| run_t262.addArgs(args);
    const t262_step = b.step("test262", "Run the test262 conformance suite (parser-only)");
    t262_step.dependOn(&run_t262.step);

    // The frontmatter / skip helper modules under tools/test262/ get
    // their inline `test` blocks picked up via the t262 module's test
    // walk.
    const t262_tests = b.addTest(.{ .root_module = t262_mod });
    const run_t262_tests = b.addRunArtifact(t262_tests);
    test_step.dependOn(&run_t262_tests.step);

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
    const bench_step = b.step("bench", "Run the micro-bench suite (medians of 5)");
    bench_step.dependOn(&run_bench.step);
}
