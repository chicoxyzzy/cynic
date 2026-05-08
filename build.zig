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

    // Library module: everything except the CLI.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkLibrary(qjs_regex);
    lib_mod.addIncludePath(b.path("vendor/quickjs"));

    // Executable module: the `cynic` CLI. Imports the library as `cynic`.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("cynic", lib_mod);
    exe_mod.linkLibrary(qjs_regex);
    exe_mod.addIncludePath(b.path("vendor/quickjs"));

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

    // `zig build test262` runs the parser-only conformance harness over
    // the corpus at vendor/test262/test (or `--corpus=<path>`). Imports
    // the library as `cynic`. Forward args after `--`.
    const t262_mod = b.createModule(.{
        .root_source_file = b.path("tools/test262.zig"),
        .target = target,
        .optimize = optimize,
    });
    t262_mod.addImport("cynic", lib_mod);

    // Inject the working-tree git SHA and the test262 submodule SHA as
    // build-time strings so `--write-results` can record them in the
    // score history. Build-time (vs runtime) keeps the harness free of
    // any subprocess dependency at run time, and the SHA is pinned to
    // the binary that produced the row. Falls back to "unknown" if git
    // isn't available, the lookup fails, or the working tree has no
    // commits yet (e.g. before the first commit).
    const t262_options = b.addOptions();
    t262_options.addOption([]const u8, "cynic_sha", gitShortSha(b, ".") orelse "unknown");
    t262_options.addOption([]const u8, "test262_sha", gitShortSha(b, "vendor/test262") orelse "unknown");
    t262_mod.addOptions("build_options", t262_options);

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
}

/// Best-effort short git SHA for the repo (or submodule) at `dir`.
/// Returns null if git isn't available, the path isn't a working
/// tree, the working tree has no commits yet, or the lookup
/// otherwise fails — the build keeps going with a fallback string.
fn gitShortSha(b: *std.Build, dir: []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const stdout = b.runAllowFail(
        &.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" },
        &code,
        .ignore,
    ) catch return null;
    const trimmed = std.mem.trim(u8, stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}
