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
    // Cynic ships ahead of the published edition. Default is empty;
    // flags below are processed in argument order so a later flag
    // wins (e.g. `--enable-experimental --disable=upsert` enables
    // every tracked feature *except* upsert). See
    // `src/runtime/features.zig`.
    var feature_flags: FeatureSet = FeatureSet.initEmpty();

    while (args.len > 0) {
        const a = args[0];
        if (std.mem.eql(u8, a, "--list-features")) {
            args = args[1..];
            try listFeatures(io);
            return;
        } else if (std.mem.eql(u8, a, "--enable-experimental")) {
            args = args[1..];
            feature_flags = FeatureSet.initFull();
        } else if (std.mem.eql(u8, a, "--disable-experimental")) {
            args = args[1..];
            feature_flags = FeatureSet.initEmpty();
        } else if (std.mem.startsWith(u8, a, "--enable=")) {
            args = args[1..];
            const name = a["--enable=".len..];
            const flag = FeatureFlag.fromName(name) orelse {
                try unknownFeature(io, name);
                std.process.exit(1);
            };
            feature_flags.insert(flag);
        } else if (std.mem.startsWith(u8, a, "--disable=")) {
            args = args[1..];
            const name = a["--disable=".len..];
            const flag = FeatureFlag.fromName(name) orelse {
                try unknownFeature(io, name);
                std.process.exit(1);
            };
            feature_flags.remove(flag);
        } else {
            break;
        }
    }

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
        try eval_cmd.run(allocator, io, args[0], feature_flags);
    } else if (std.mem.eql(u8, sub, "run")) {
        // `cynic run a.js b.js c.js` evaluates each file in order
        // against one realm — the same shape every other engine's
        // CLI uses (`d8 a.js b.js`, `jsc a.js b.js`).
        if (args.len == 0) {
            try printUsage(io);
            return error.MissingArgument;
        }
        try run_cmd.run(allocator, io, args, feature_flags);
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
        \\  run <file>...                    Compile and execute each <file> as a
        \\                                   script against one realm; print the
        \\                                   final completion value.
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
