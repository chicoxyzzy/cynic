//! Perlex — Cynic's native regular-expression engine, written in Zig.
//!
//! (The name is "perplex" with a letter knocked out: regular
//! expressions confound everyone, this one included. It also reads as
//! Perl + ex, a nod to the language that made regex a lingua franca.)
//!
//! Perlex is the primary matcher for the patterns it understands. Its
//! grammar is grown deliberately; any construct it doesn't yet handle
//! is reported as `.unsupported` so the RegExp bridge can route the
//! pattern to the vendored fallback matcher. As the grammar widens,
//! the fallback's role shrinks.
//!
//! Pipeline: `parser` (source → AST) → `compiler` (AST → instruction
//! program) → `vm` (backtracking executor over UTF-16 code units).

const std = @import("std");

pub const parser = @import("parser.zig");
pub const compiler = @import("compiler.zig");
pub const vm = @import("vm.zig");

pub const Node = parser.Node;
pub const Program = compiler.Program;
pub const Inst = compiler.Inst;
pub const Flags = compiler.Flags;
pub const PropertyResolver = compiler.PropertyResolver;
pub const ResolvedProperty = compiler.ResolvedProperty;
pub const CaseFoldFn = compiler.CaseFoldFn;
pub const Match = vm.Match;
/// Sentinel for a capture slot that did not participate.
pub const none = vm.none;

/// Outcome of asking Perlex to compile a pattern.
pub const CompileResult = union(enum) {
    /// Perlex owns this pattern; the caller takes ownership of the
    /// `Program` and must `deinit` it.
    ok: Program,
    /// The pattern uses a construct outside Perlex's current grammar;
    /// the caller should compile it with the fallback matcher.
    unsupported,
    /// The pattern is invalid and Perlex is authoritative about it —
    /// e.g. a group name reused within one Alternative (§22.2.1.1).
    /// The caller raises a SyntaxError.
    syntax_error,
};

/// Injected Unicode data Perlex needs but does not carry itself: the
/// `\p{…}` property `resolver` and the `/iu`/`/iv` case-folding
/// `case_folder`. The RegExp bridge backs both with Cynic's generated
/// tables; a null field defers the patterns that need it to the
/// fallback matcher.
pub const Hooks = struct {
    resolver: ?PropertyResolver = null,
    case_folder: ?CaseFoldFn = null,
};

/// Attempt to compile `pattern` (a regex source string, without the
/// delimiting slashes) under `flags`. Never throws a syntax verdict
/// for constructs it doesn't model — those return `.unsupported` so
/// the fallback matcher renders the authoritative verdict.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, flags: Flags) error{OutOfMemory}!CompileResult {
    return compileWithHooks(gpa, pattern, flags, .{});
}

/// As `compile`, but with an injected `\p{…}` property resolver. The
/// RegExp bridge passes one backed by Cynic's Unicode tables so property
/// escapes match natively; a null resolver defers every `\p{…}` pattern
/// to the fallback.
pub fn compileWithResolver(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    flags: Flags,
    resolver: ?PropertyResolver,
) error{OutOfMemory}!CompileResult {
    return compileWithHooks(gpa, pattern, flags, .{ .resolver = resolver });
}

/// As `compile`, but with the full set of injected Unicode `hooks` (the
/// `\p{…}` resolver and the `/iu`/`/iv` case folder). The RegExp bridge
/// uses this entry point so both escapes and case folding match natively.
pub fn compileWithHooks(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    flags: Flags,
    hooks: Hooks,
) error{OutOfMemory}!CompileResult {
    // `/u` and `/v` match over code points. Combined with `i` they need
    // §22.2.2.9 Canonicalize's full case-folding orbits: handled when a
    // case folder is injected, deferred to the fallback otherwise.
    // `g`/`y`/`d` affect the driver not the match; `m`/`s` and ASCII-`i`
    // are handled directly.
    if ((flags.unicode or flags.unicode_sets) and flags.ignore_case and hooks.case_folder == null) return .unsupported;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = parser.parse(a, pattern, flags.unicode, flags.unicode_sets) catch |e| switch (e) {
        error.Unsupported => return .unsupported,
        error.SyntaxError => return .syntax_error,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // An inline `(?i:…)` group (§22.2.1) turns `i` on for a subpattern
    // even when the program-level flag is off. It needs the same orbit
    // folder under `/u`/`/v`: the pre-parse gate above can't see it
    // (the flag is only known after parsing), so re-check post-parse.
    // Removing `i` (`(?-i:…)`) or adding only `m`/`s` needs no folder.
    if ((flags.unicode or flags.unicode_sets) and parsed.has_ignore_case_modifier and hooks.case_folder == null) return .unsupported;

    // §22.2.2.7.1 — non-Unicode Canonicalize never folds a non-ASCII
    // unit to ASCII, so ASCII folding is exact for an all-ASCII
    // pattern. A pattern with an explicit non-ASCII unit could fold to
    // another non-ASCII unit (e.g. à↔À), which the ASCII fold misses —
    // defer those non-Unicode `i` patterns to the fallback. An inline
    // `(?i:…)` group counts too. Under `/iu`/`/iv` the injected folder
    // handles non-ASCII orbits, so the gate is limited to non-Unicode.
    if ((flags.ignore_case or parsed.has_ignore_case_modifier) and !(flags.unicode or flags.unicode_sets) and parsed.non_ascii) return .unsupported;

    parser.checkDuplicateNames(a, parsed.root) catch |e| switch (e) {
        error.SyntaxError => return .syntax_error,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var program = compiler.compile(gpa, parsed, flags, hooks.resolver) catch |e| switch (e) {
        error.Unsupported => return .unsupported,
        error.SyntaxError => return .syntax_error,
        error.OutOfMemory => return error.OutOfMemory,
    };
    program.case_folder = hooks.case_folder;
    return .{ .ok = program };
}

/// Run a compiled program against `input`, scanning forward from
/// `start` (or anchored at `start` when sticky). `Unit` is `u8` for
/// Latin1/ASCII subjects — matched directly on Cynic's WTF-8 bytes
/// with no transcode — or `u16` otherwise; capture offsets come back
/// in those units.
pub fn exec(
    comptime Unit: type,
    gpa: std.mem.Allocator,
    program: *const Program,
    input: []const Unit,
    start: usize,
) error{OutOfMemory}!?Match {
    return vm.exec(Unit, gpa, program, input, start);
}

test {
    _ = @import("tests.zig");
}
