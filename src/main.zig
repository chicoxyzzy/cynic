//! Cynic CLI — `lex`, `parse`, `eval`, and `run` subcommands.
//! `repl` follows when later's function machinery is in place.

const std = @import("std");
const cynic = @import("cynic");
const eval_cmd = @import("cli/eval.zig");
const run_cmd = @import("cli/run.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // skip the binary path

    const sub = args_iter.next() orelse {
        try printUsage(io);
        return;
    };

    if (std.mem.eql(u8, sub, "lex")) {
        const path = args_iter.next() orelse {
            try printUsage(io);
            return error.MissingArgument;
        };
        try cmdLex(allocator, io, path);
    } else if (std.mem.eql(u8, sub, "parse")) {
        // `parse [--module|-m] <file>`. Mode precedence: explicit
        // flag wins; otherwise `.mjs` extension forces module mode
        // (matching V8/d8, SpiderMonkey, Node convention); otherwise
        // script.
        var explicit_mode: ?ParseMode = null;
        var path: ?[]const u8 = null;
        while (args_iter.next()) |a| {
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
        const expr = args_iter.next() orelse {
            try printUsage(io);
            return error.MissingArgument;
        };
        try eval_cmd.run(allocator, io, expr);
    } else if (std.mem.eql(u8, sub, "run")) {
        // `cynic run a.js b.js c.js` evaluates each file in
        // order against one realm — the same shape every other
        // engine's CLI uses (`d8 a.js b.js`, `jsc a.js b.js`).
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(allocator);
        while (args_iter.next()) |p| {
            try paths.append(allocator, p);
        }
        if (paths.items.len == 0) {
            try printUsage(io);
            return error.MissingArgument;
        }
        try run_cmd.run(allocator, io, paths.items);
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
        \\  cynic lex <file>                 Tokenize <file> and print each token.
        \\  cynic parse [--module|-m] <file> Parse <file> and print the AST as
        \\                                   S-expressions. Files ending in `.mjs`
        \\                                   default to module mode; the flag
        \\                                   overrides. `--script` / `-s` forces
        \\                                   script mode against a `.mjs` path.
        \\  cynic eval <expr>                Compile and execute a single
        \\                                   expression; print the result.
        \\  cynic run <file>                 Compile and execute <file> as a
        \\                                   script; print the final completion
        \\                                   value.
        \\  cynic help                       Show this help.
        \\
    );
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
