//! Cynic CLI — `lex`, `parse`, `eval`, and `run` subcommands.
//! `repl` follows when later's function machinery is in place.

const std = @import("std");
const cynic = @import("cynic");
const eval_cmd = @import("cli/eval.zig");
const run_cmd = @import("cli/run.zig");

const FeatureFlag = cynic.runtime.FeatureFlag;
const FeatureSet = cynic.runtime.FeatureSet;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Collect every argument up front so the top-level flag loop
    // can peek and the subcommand can scan the remainder by index.
    // `std.process.Args.Iterator` is one-shot — there's no put-back.
    var raw: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw.deinit(allocator);
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // skip the binary path
    while (args_iter.next()) |a| try raw.append(allocator, a);
    var args: []const []const u8 = raw.items;

    // Top-level flags — feature toggles for pre-Stage-4 proposals
    // Cynic ships ahead of the published edition, plus the
    // `--gc-threshold=<n>` allocation-pressure GC knob. See
    // `parseTopLevelFlags` for the option struct.
    const parsed = parseTopLevelFlags(args);
    if (parsed.err) |err| switch (err) {
        .unknown_feature => {
            try unknownFeature(io, parsed.bad_token.?);
            std.process.exit(1);
        },
        .invalid_gc_threshold => {
            try invalidGcThreshold(io, parsed.bad_token.?);
            std.process.exit(1);
        },
    };
    if (parsed.list_features) {
        try listFeatures(io);
        return;
    }
    args = parsed.remaining;
    const feature_flags = parsed.feature_flags;
    const gc_threshold = parsed.gc_threshold;

    if (args.len == 0) {
        try printUsage(io);
        return;
    }
    const sub = args[0];
    args = args[1..];

    if (std.mem.eql(u8, sub, "lex")) {
        if (args.len != 1) {
            try printUsage(io);
            return error.MissingArgument;
        }
        try cmdLex(allocator, io, args[0]);
    } else if (std.mem.eql(u8, sub, "parse")) {
        // `parse [--module|-m] <file>`. Mode precedence: explicit
        // flag wins; otherwise `.mjs` extension forces module mode
        // (matching V8/d8, SpiderMonkey, Node convention); otherwise
        // script.
        var explicit_mode: ?ParseMode = null;
        var path: ?[]const u8 = null;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--module") or std.mem.eql(u8, a, "-m")) {
                explicit_mode = .module;
            } else if (std.mem.eql(u8, a, "--script") or std.mem.eql(u8, a, "-s")) {
                explicit_mode = .script;
            } else if (std.mem.startsWith(u8, a, "-")) {
                try printUsage(io);
                return error.UnknownOption;
            } else {
                if (path != null) {
                    try printUsage(io);
                    return error.TooManyArguments;
                }
                path = a;
            }
        }
        const file = path orelse {
            try printUsage(io);
            return error.MissingArgument;
        };
        const mode = explicit_mode orelse if (std.mem.endsWith(u8, file, ".mjs"))
            ParseMode.module
        else
            ParseMode.script;
        try cmdParse(allocator, io, file, mode);
    } else if (std.mem.eql(u8, sub, "eval")) {
        if (args.len != 1) {
            try printUsage(io);
            return error.MissingArgument;
        }
        try eval_cmd.run(allocator, io, args[0], feature_flags, gc_threshold);
    } else if (std.mem.eql(u8, sub, "run")) {
        // `cynic run a.js b.js c.js` evaluates each file in order
        // against one realm — the same shape every other engine's
        // CLI uses (`d8 a.js b.js`, `jsc a.js b.js`).
        // `--dump-bytecode` (before the paths) skips execution and
        // emits the compiled chunk's disassembly — same intent as
        // V8's `d8 --print-bytecode`.
        var dump_bytecode = false;
        var debug_globals = false;
        var run_args = args;
        while (run_args.len > 0 and std.mem.startsWith(u8, run_args[0], "--")) {
            if (std.mem.eql(u8, run_args[0], "--dump-bytecode")) {
                dump_bytecode = true;
                run_args = run_args[1..];
            } else if (std.mem.eql(u8, run_args[0], "--debug-globals")) {
                debug_globals = true;
                run_args = run_args[1..];
            } else {
                try printUsage(io);
                return error.UnknownArgument;
            }
        }
        if (run_args.len == 0) {
            try printUsage(io);
            return error.MissingArgument;
        }
        try run_cmd.run(allocator, io, run_args, feature_flags, gc_threshold, dump_bytecode, debug_globals);
    } else if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try printUsage(io);
    } else {
        try printUsage(io);
        return error.UnknownCommand;
    }
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(io,
        \\cynic — a strict-only ECMAScript engine
        \\
        \\Usage:
        \\  cynic [options] <subcommand> [args]
        \\
        \\Subcommands:
        \\  lex <file>                       Tokenize <file> and print each token.
        \\  parse [--module|-m] <file>       Parse <file> and print the AST as
        \\                                   S-expressions. Files ending in `.mjs`
        \\                                   default to module mode; the flag
        \\                                   overrides. `--script` / `-s` forces
        \\                                   script mode against a `.mjs` path.
        \\  eval <expr>                      Compile and execute a single
        \\                                   expression; print the result.
        \\  run [--dump-bytecode] [--debug-globals] <file>...
        \\                                   Compile and execute each <file> as a
        \\                                   script against one realm; print the
        \\                                   final completion value.
        \\                                   `--dump-bytecode` prints the compiled
        \\                                   chunk and exits without executing.
        \\                                   `--debug-globals` installs
        \\                                   `__collectGarbage` / `__clearKeptObjects` /
        \\                                   `__drainMicrotasks` for debugging. Off
        \\                                   by default — these are attack surfaces
        \\                                   on production embeddings.
        \\  help                             Show this help.
        \\
        \\Top-level options (consumed before the subcommand):
        \\  --enable=<name>                  Enable a pre-Stage-4 TC39 proposal.
        \\                                   Repeatable. See --list-features.
        \\  --disable=<name>                 Disable a pre-Stage-4 TC39 proposal.
        \\                                   Repeatable.
        \\  --enable-experimental            Enable every tracked pre-Stage-4
        \\                                   proposal (group toggle).
        \\  --disable-experimental           Disable every tracked pre-Stage-4
        \\                                   proposal (the default).
        \\  --list-features                  Print available pre-Stage-4 proposals
        \\                                   and exit.
        \\  --gc-threshold=<n>               Allocation-pressure GC threshold.
        \\                                   Default 16384; `=1` collects on every
        \\                                   allocation (stress mode).
        \\
    );
}

fn listFeatures(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Pre-Stage-4 TC39 proposals Cynic ships ahead of the published edition.
        \\All disabled by default; opt in with --enable=<name> or
        \\--enable-experimental (group). See docs/ROADMAP.md for details.
        \\
        \\
    );
    var buf: [256]u8 = undefined;
    inline for (@typeInfo(FeatureFlag).@"enum".fields) |f| {
        const tag: FeatureFlag = @enumFromInt(f.value);
        const line = try std.fmt.bufPrint(&buf, "  {s:<24}  {s}\n", .{ tag.name(), tag.description() });
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn unknownFeature(io: std.Io, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "error: unknown feature '{s}'. Run `cynic --list-features` for the available set.\n",
        .{name},
    );
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

fn invalidGcThreshold(io: std.Io, raw: []const u8) !void {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "error: invalid --gc-threshold value '{s}'. Expected a positive integer (default 16384, =1 collects on every allocation).\n",
        .{raw},
    );
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

fn cmdLex(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);

    var line_buf: [512]u8 = undefined;
    var lex = cynic.lexer.Lexer.init(allocator, bytes);
    while (true) {
        const tok = lex.next() catch |err| {
            const msg = try std.fmt.bufPrint(&line_buf, "error: {t}\n", .{err});
            try std.Io.File.stdout().writeStreamingAll(io, msg);
            return;
        };
        const text = bytes[tok.span.start..tok.span.end];
        const msg = try std.fmt.bufPrint(&line_buf, "{t} [{d}..{d}] {s}\n", .{
            tok.kind,
            tok.span.start,
            tok.span.end,
            text,
        });
        try std.Io.File.stdout().writeStreamingAll(io, msg);
        if (tok.kind == .eof) break;
    }
}

const ParseMode = enum { script, module };

fn cmdParse(allocator: std.mem.Allocator, io: std.Io, path: []const u8, mode: ParseMode) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var diags: cynic.diagnostic.Diagnostics = .empty;
    const program_or_err = switch (mode) {
        .script => cynic.parser.parseScript(arena_alloc, bytes, &diags),
        .module => cynic.parser.parseModule(arena_alloc, bytes, &diags),
    };

    var line_buf: [512]u8 = undefined;
    for (diags.items) |d| {
        const msg = try std.fmt.bufPrint(&line_buf, "{s}: {t} [{d}..{d}]\n", .{
            @tagName(d.severity),
            d.code,
            d.span.start,
            d.span.end,
        });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
    }

    const program = program_or_err catch {
        std.process.exit(1);
    };

    const dumped = try cynic.ast.printer.dump(arena_alloc, &program, bytes);
    try std.Io.File.stdout().writeStreamingAll(io, dumped);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");

    var has_errors = false;
    for (diags.items) |d| if (d.severity == .err) {
        has_errors = true;
        break;
    };
    if (has_errors) std.process.exit(1);
}

// ── Top-level flag parser ──────────────────────────────────────────
// The parsing pulled out of `main` so it's unit-testable. Returns
// the parsed options plus the remaining args (the subcommand and
// its own args), or — on a parse failure — the partial state with
// `err` set and the offending token recorded. Returning the result
// rather than an `error.X` lets the caller print a focused
// "couldn't parse '--gc-threshold=abc'" message without re-walking
// the argv to find the offender.

pub const FlagError = enum {
    unknown_feature,
    invalid_gc_threshold,
};

pub const ParsedFlags = struct {
    feature_flags: FeatureSet,
    /// `--gc-threshold=<n>` — when non-null, overrides
    /// `heap.gc_threshold` (and via `setGcThreshold` the paired
    /// young threshold) before the realm sees its first
    /// allocation. `null` ⇒ keep the heap default. The test262
    /// harness already exposes the same flag; threading it through
    /// here lets the runtime CLI run a `--gc-threshold=1` stress
    /// pass without going through the harness binary.
    gc_threshold: ?u32,
    /// The unconsumed tail of the argv slice (subcommand + its
    /// arguments). Empty when no subcommand was supplied — the
    /// caller prints usage in that case.
    remaining: []const []const u8,
    /// On parse failure: which check tripped. `null` on success.
    err: ?FlagError = null,
    /// On parse failure: the literal offending token (the
    /// `<bad>` from `--enable=<bad>` / `--gc-threshold=<bad>`).
    /// `null` on success.
    bad_token: ?[]const u8 = null,
    /// Set when the user asked for `--list-features`. `main`
    /// honours this short-circuit before checking `remaining`.
    list_features: bool = false,
};

pub fn parseTopLevelFlags(args: []const []const u8) ParsedFlags {
    var out: ParsedFlags = .{
        .feature_flags = FeatureSet.initEmpty(),
        .gc_threshold = null,
        .remaining = args,
    };
    var rest = args;
    while (rest.len > 0) {
        const a = rest[0];
        if (std.mem.eql(u8, a, "--list-features")) {
            out.list_features = true;
            rest = rest[1..];
            out.remaining = rest;
            return out;
        } else if (std.mem.eql(u8, a, "--enable-experimental")) {
            rest = rest[1..];
            out.feature_flags = FeatureSet.initFull();
        } else if (std.mem.eql(u8, a, "--disable-experimental")) {
            rest = rest[1..];
            out.feature_flags = FeatureSet.initEmpty();
        } else if (std.mem.startsWith(u8, a, "--enable=")) {
            const name = a["--enable=".len..];
            const flag = FeatureFlag.fromName(name) orelse {
                out.err = .unknown_feature;
                out.bad_token = name;
                out.remaining = rest;
                return out;
            };
            out.feature_flags.insert(flag);
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, a, "--disable=")) {
            const name = a["--disable=".len..];
            const flag = FeatureFlag.fromName(name) orelse {
                out.err = .unknown_feature;
                out.bad_token = name;
                out.remaining = rest;
                return out;
            };
            out.feature_flags.remove(flag);
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, a, "--gc-threshold=")) {
            const raw = a["--gc-threshold=".len..];
            const n = std.fmt.parseInt(u32, raw, 10) catch {
                out.err = .invalid_gc_threshold;
                out.bad_token = raw;
                out.remaining = rest;
                return out;
            };
            // `0` is a valid value for the *internal* setter (the
            // test262 harness uses it as "fall through to the engine
            // default"), but a user typing `--gc-threshold=0` on the
            // CLI almost certainly meant `1` (stress) or `16384`
            // (default). Reject explicitly so a typo doesn't
            // silently keep the heap default.
            if (n == 0) {
                out.err = .invalid_gc_threshold;
                out.bad_token = raw;
                out.remaining = rest;
                return out;
            }
            out.gc_threshold = n;
            rest = rest[1..];
        } else {
            break;
        }
    }
    out.remaining = rest;
    return out;
}

const testing = std.testing;

test "parseTopLevelFlags: no flags returns empty feature set and null gc_threshold" {
    const args = [_][]const u8{ "run", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, null), parsed.err);
    try testing.expect(parsed.feature_flags.eql(FeatureSet.initEmpty()));
    try testing.expectEqual(@as(?u32, null), parsed.gc_threshold);
    try testing.expectEqual(@as(usize, 2), parsed.remaining.len);
    try testing.expectEqualStrings("run", parsed.remaining[0]);
}

test "parseTopLevelFlags: --gc-threshold=N is parsed into options" {
    const args = [_][]const u8{ "--gc-threshold=1", "run", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, null), parsed.err);
    try testing.expectEqual(@as(?u32, 1), parsed.gc_threshold);
    try testing.expectEqual(@as(usize, 2), parsed.remaining.len);
    try testing.expectEqualStrings("run", parsed.remaining[0]);
}

test "parseTopLevelFlags: --gc-threshold accepts the documented default" {
    const args = [_][]const u8{ "--gc-threshold=16384", "run", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?u32, 16384), parsed.gc_threshold);
}

test "parseTopLevelFlags: --gc-threshold=0 is rejected" {
    const args = [_][]const u8{"--gc-threshold=0"};
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, .invalid_gc_threshold), parsed.err);
    try testing.expectEqualStrings("0", parsed.bad_token.?);
}

test "parseTopLevelFlags: --gc-threshold=abc is rejected as non-numeric" {
    const args = [_][]const u8{"--gc-threshold=abc"};
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, .invalid_gc_threshold), parsed.err);
    try testing.expectEqualStrings("abc", parsed.bad_token.?);
}

test "parseTopLevelFlags: --gc-threshold composes with other flags in any order" {
    const args = [_][]const u8{ "--enable-experimental", "--gc-threshold=42", "run", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, null), parsed.err);
    try testing.expect(parsed.feature_flags.eql(FeatureSet.initFull()));
    try testing.expectEqual(@as(?u32, 42), parsed.gc_threshold);
    try testing.expectEqualStrings("run", parsed.remaining[0]);
}

test "parseTopLevelFlags: stops at the first non-flag token" {
    // A flag *after* the subcommand belongs to the subcommand, not
    // to the top-level parser. (The subcommand's own arg parser
    // sees `--gc-threshold=…` here and decides what to do with it
    // — for `run` / `eval` / `parse` today: nothing, since they
    // own no flags by that name.)
    const args = [_][]const u8{ "run", "--gc-threshold=99", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?u32, null), parsed.gc_threshold);
    try testing.expectEqual(@as(usize, 3), parsed.remaining.len);
}

test "parseTopLevelFlags: an unknown --enable=<feature> is rejected" {
    const args = [_][]const u8{"--enable=bogus-feature-name"};
    const parsed = parseTopLevelFlags(&args);
    try testing.expectEqual(@as(?FlagError, .unknown_feature), parsed.err);
    try testing.expectEqualStrings("bogus-feature-name", parsed.bad_token.?);
}

test "parseTopLevelFlags: --list-features short-circuits and signals via list_features" {
    const args = [_][]const u8{ "--list-features", "run", "foo.js" };
    const parsed = parseTopLevelFlags(&args);
    try testing.expect(parsed.list_features);
}
