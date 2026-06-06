//! Tests for the recursive-descent parser — extracted from
//! `parser.zig` to keep the parser module focused on
//! production code (the host file dropped from ~5,450 to
//! ~1,730 lines after this split). All tests build a parse,
//! dump the AST via `ast.printer`, and assert against a
//! golden S-expression form.

const std = @import("std");
const testing = std.testing;

const parser = @import("parser.zig");
const parseScript = parser.parseScript;
const parseModule = parser.parseModule;
const tagDirectivePrologue = parser.tagDirectivePrologue;
const isSimpleParameterList = parser.isSimpleParameterList;
const containsUseStrict = parser.containsUseStrict;
const enforceStrictDirectiveSimplicity = parser.enforceStrictDirectiveSimplicity;
const isPropertyNameStart = parser.isPropertyNameStart;
const Parser = parser.Parser;
const ParseError = parser.ParseError;

const ast = @import("../ast.zig");
const stmt_mod = @import("../ast/statement.zig");
const Statement = ast.Statement;
const Expression = ast.Expression;
const Program = ast.Program;

const cynic_diag = @import("../diagnostic.zig");
const Diagnostic = cynic_diag.Diagnostic;
const Diagnostics = cynic_diag.Diagnostics;
const Code = cynic_diag.Code;

const token_mod = @import("../lexer/token.zig");
const TokenKind = token_mod.TokenKind;

fn expectAst(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parseScript(arena.allocator(), source, null);
    const dumped = try ast.printer.dump(arena.allocator(), &program, source);
    try testing.expectEqualStrings(expected, dumped);
}

fn expectParseError(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    const result = parseScript(arena.allocator(), source, &diags);
    if (result) |_| {
        // Parser may have recovered without error.ParseError, but
        // a diagnostic is still required for the test to pass.
        if (!hasErr(diags.items)) return error.ExpectedParseError;
    } else |err| switch (err) {
        error.ParseError => return,
        else => return err,
    }
}

fn hasErr(items: []const cynic_diag.Diagnostic) bool {
    for (items) |d| if (d.severity == .err) return true;
    return false;
}

test "Parser: empty source -> empty program" {
    try expectAst("", "(program script [0..0])");
}

test "Parser: single empty statement" {
    try expectAst(";",
        \\(program script [0..1]
        \\  (empty [0..1]))
    );
}

test "Parser: multiple empty statements" {
    try expectAst(";;",
        \\(program script [0..2]
        \\  (empty [0..1])
        \\  (empty [1..2]))
    );
}

test "Parser: ExpressionStatement with null literal" {
    try expectAst("null;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (null [0..4])))
    );
}

test "Parser: ExpressionStatement with true" {
    try expectAst("true;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (bool true [0..4])))
    );
}

test "Parser: ExpressionStatement with false" {
    try expectAst("false;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (bool false [0..5])))
    );
}

test "Parser: ExpressionStatement with numeric literal" {
    try expectAst("42;",
        \\(program script [0..3]
        \\  (expr-stmt [0..3]
        \\    (numeric "42" [0..2])))
    );
}

test "Parser: ExpressionStatement with string literal" {
    // A bare string literal at script start IS a Directive Prologue per
    // §11.10 — the parser tags the ExpressionStatement with the literal
    // content span. Any subsequent non-string-literal statement closes
    // the prologue.
    try expectAst("\"hello\";",
        \\(program script [0..8]
        \\  (expr-stmt directive="hello" [0..8]
        \\    (string "hello" [0..7])))
    );
}

test "Parser: ExpressionStatement with identifier" {
    try expectAst("foo;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (ident "foo" [0..3])))
    );
}

test "Parser: ASI at EOF" {
    try expectAst("null",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (null [0..4])))
    );
}

test "Parser: ASI before line terminator" {
    try expectAst("a\nb",
        \\(program script [0..3]
        \\  (expr-stmt [0..1]
        \\    (ident "a" [0..1]))
        \\  (expr-stmt [2..3]
        \\    (ident "b" [2..3])))
    );
}

test "Parser: parenthesized expression" {
    try expectAst("(a);",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (paren [0..3]
        \\      (ident "a" [1..2]))))
    );
}

test "Parser: nested parentheses" {
    try expectAst("((1));",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (paren [0..5]
        \\      (paren [1..4]
        \\        (numeric "1" [2..3])))))
    );
}

test "Parser: unary not" {
    try expectAst("!a;",
        \\(program script [0..3]
        \\  (expr-stmt [0..3]
        \\    (unary op=! [0..2]
        \\      (ident "a" [1..2]))))
    );
}

test "Parser: unary minus on numeric" {
    try expectAst("-1;",
        \\(program script [0..3]
        \\  (expr-stmt [0..3]
        \\    (unary op=- [0..2]
        \\      (numeric "1" [1..2]))))
    );
}

test "Parser: unary plus" {
    try expectAst("+a;",
        \\(program script [0..3]
        \\  (expr-stmt [0..3]
        \\    (unary op=+ [0..2]
        \\      (ident "a" [1..2]))))
    );
}

test "Parser: unary tilde" {
    try expectAst("~0;",
        \\(program script [0..3]
        \\  (expr-stmt [0..3]
        \\    (unary op=~ [0..2]
        \\      (numeric "0" [1..2]))))
    );
}

test "Parser: typeof" {
    try expectAst("typeof x;",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (unary op=typeof [0..8]
        \\      (ident "x" [7..8]))))
    );
}

test "Parser: void" {
    try expectAst("void 0;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (unary op=void [0..6]
        \\      (numeric "0" [5..6]))))
    );
}

test "Parser: nested unary" {
    try expectAst("!!x;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (unary op=! [0..3]
        \\      (unary op=! [1..3]
        \\        (ident "x" [2..3])))))
    );
}

test "Parser: unary on parenthesized" {
    try expectAst("-(a);",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (unary op=- [0..4]
        \\      (paren [1..4]
        \\        (ident "a" [2..3])))))
    );
}

test "Parser: addition" {
    try expectAst("1 + 2;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (binary op=+ [0..5]
        \\      (numeric "1" [0..1])
        \\      (numeric "2" [4..5]))))
    );
}

test "Parser: addition is left-associative" {
    try expectAst("1 + 2 + 3;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (binary op=+ [0..9]
        \\      (binary op=+ [0..5]
        \\        (numeric "1" [0..1])
        \\        (numeric "2" [4..5]))
        \\      (numeric "3" [8..9]))))
    );
}

test "Parser: multiplication binds tighter than addition" {
    try expectAst("1 + 2 * 3;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (binary op=+ [0..9]
        \\      (numeric "1" [0..1])
        \\      (binary op=* [4..9]
        \\        (numeric "2" [4..5])
        \\        (numeric "3" [8..9])))))
    );
}

test "Parser: exponent is right-associative" {
    try expectAst("2 ** 3 ** 2;",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (binary op=** [0..11]
        \\      (numeric "2" [0..1])
        \\      (binary op=** [5..11]
        \\        (numeric "3" [5..6])
        \\        (numeric "2" [10..11])))))
    );
}

test "Parser: equality is left-associative" {
    try expectAst("a == b == c;",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (binary op=== [0..11]
        \\      (binary op=== [0..6]
        \\        (ident "a" [0..1])
        \\        (ident "b" [5..6]))
        \\      (ident "c" [10..11]))))
    );
}

test "Parser: comparison and equality precedence" {
    try expectAst("a < b == c;",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (binary op=== [0..10]
        \\      (binary op=< [0..5]
        \\        (ident "a" [0..1])
        \\        (ident "b" [4..5]))
        \\      (ident "c" [9..10]))))
    );
}

test "Parser: bitwise operators precedence" {
    // & binds tighter than ^ which binds tighter than |.
    try expectAst("a | b ^ c & d;",
        \\(program script [0..14]
        \\  (expr-stmt [0..14]
        \\    (binary op=| [0..13]
        \\      (ident "a" [0..1])
        \\      (binary op=^ [4..13]
        \\        (ident "b" [4..5])
        \\        (binary op=& [8..13]
        \\          (ident "c" [8..9])
        \\          (ident "d" [12..13]))))))
    );
}

test "Parser: shift binds tighter than addition? no, additive binds tighter" {
    // `1 + 2 << 3` parses as `(1 + 2) << 3` because additive (12) >
    // shift (11).
    try expectAst("1 + 2 << 3;",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (binary op=<< [0..10]
        \\      (binary op=+ [0..5]
        \\        (numeric "1" [0..1])
        \\        (numeric "2" [4..5]))
        \\      (numeric "3" [9..10]))))
    );
}

test "Parser: instanceof is a relational operator" {
    try expectAst("x instanceof Y;",
        \\(program script [0..15]
        \\  (expr-stmt [0..15]
        \\    (binary op=instanceof [0..14]
        \\      (ident "x" [0..1])
        \\      (ident "Y" [13..14]))))
    );
}

test "Parser: in is a relational operator" {
    try expectAst("k in obj;",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (binary op=in [0..8]
        \\      (ident "k" [0..1])
        \\      (ident "obj" [5..8]))))
    );
}

test "Parser: unary binds tighter than binary" {
    try expectAst("-1 + 2;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (binary op=+ [0..6]
        \\      (unary op=- [0..2]
        \\        (numeric "1" [1..2]))
        \\      (numeric "2" [5..6]))))
    );
}

test "Parser: parens override precedence" {
    try expectAst("(1 + 2) * 3;",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (binary op=* [0..11]
        \\      (paren [0..7]
        \\        (binary op=+ [1..6]
        \\          (numeric "1" [1..2])
        \\          (numeric "2" [5..6])))
        \\      (numeric "3" [10..11]))))
    );
}

test "Parser: logical and" {
    try expectAst("a && b;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (logical op=&& [0..6]
        \\      (ident "a" [0..1])
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: logical or" {
    try expectAst("a || b;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (logical op=|| [0..6]
        \\      (ident "a" [0..1])
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: nullish coalescing" {
    try expectAst("a ?? b;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (logical op=?? [0..6]
        \\      (ident "a" [0..1])
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: && binds tighter than ||" {
    try expectAst("a || b && c;",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (logical op=|| [0..11]
        \\      (ident "a" [0..1])
        \\      (logical op=&& [5..11]
        \\        (ident "b" [5..6])
        \\        (ident "c" [10..11])))))
    );
}

test "Parser: && ?? mixing without parens is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "a && b ?? c;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.mixed_logical_operators, diags.items[0].code);
}

test "Parser: || ?? mixing without parens is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "a ?? b || c;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.mixed_logical_operators, diags.items[0].code);
}

test "Parser: parens disambiguate logical mixing" {
    try expectAst("(a && b) ?? c;",
        \\(program script [0..14]
        \\  (expr-stmt [0..14]
        \\    (logical op=?? [0..13]
        \\      (paren [0..8]
        \\        (logical op=&& [1..7]
        \\          (ident "a" [1..2])
        \\          (ident "b" [6..7])))
        \\      (ident "c" [12..13]))))
    );
}

test "Parser: conditional simple" {
    try expectAst("a ? b : c;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (cond [0..9]
        \\      (ident "a" [0..1])
        \\      (ident "b" [4..5])
        \\      (ident "c" [8..9]))))
    );
}

test "Parser: conditional is right-associative" {
    try expectAst("a ? b : c ? d : e;",
        \\(program script [0..18]
        \\  (expr-stmt [0..18]
        \\    (cond [0..17]
        \\      (ident "a" [0..1])
        \\      (ident "b" [4..5])
        \\      (cond [8..17]
        \\        (ident "c" [8..9])
        \\        (ident "d" [12..13])
        \\        (ident "e" [16..17])))))
    );
}

test "Parser: assignment" {
    try expectAst("a = 1;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (assign op== [0..5]
        \\      (ident "a" [0..1])
        \\      (numeric "1" [4..5]))))
    );
}

test "Parser: assignment is right-associative" {
    try expectAst("a = b = 1;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (assign op== [0..9]
        \\      (ident "a" [0..1])
        \\      (assign op== [4..9]
        \\        (ident "b" [4..5])
        \\        (numeric "1" [8..9])))))
    );
}

test "Parser: invalid LHS of assignment emits diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "1 = 2;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.assignment_target_invalid, diags.items[0].code);
}

test "Parser: comma operator" {
    try expectAst("a, b, c;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (seq [0..7]
        \\      (ident "a" [0..1])
        \\      (ident "b" [3..4])
        \\      (ident "c" [6..7]))))
    );
}

test "Parser: comma binds looser than ternary" {
    try expectAst("a, b ? c : d;",
        \\(program script [0..13]
        \\  (expr-stmt [0..13]
        \\    (seq [0..12]
        \\      (ident "a" [0..1])
        \\      (cond [3..12]
        \\        (ident "b" [3..4])
        \\        (ident "c" [7..8])
        \\        (ident "d" [11..12])))))
    );
}

test "Parser: empty block" {
    try expectAst("{}",
        \\(program script [0..2]
        \\  (block [0..2]))
    );
}

test "Parser: block with statements" {
    try expectAst("{ a; b; }",
        \\(program script [0..9]
        \\  (block [0..9]
        \\    (expr-stmt [2..4]
        \\      (ident "a" [2..3]))
        \\    (expr-stmt [5..7]
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: nested blocks" {
    try expectAst("{{}}",
        \\(program script [0..4]
        \\  (block [0..4]
        \\    (block [1..3])))
    );
}

test "Parser: ASI before } in block" {
    try expectAst("{ a }",
        \\(program script [0..5]
        \\  (block [0..5]
        \\    (expr-stmt [2..3]
        \\      (ident "a" [2..3]))))
    );
}

test "Parser: let with initializer" {
    try expectAst("let x = 1;",
        \\(program script [0..10]
        \\  (lexical kind=let_ [0..10]
        \\    (declarator [4..9]
        \\      (binding "x" [4..5])
        \\      (numeric "1" [8..9]))))
    );
}

test "Parser: let without initializer" {
    try expectAst("let x;",
        \\(program script [0..6]
        \\  (lexical kind=let_ [0..6]
        \\    (declarator [4..5]
        \\      (binding "x" [4..5]))))
    );
}

test "Parser: let with multiple declarators" {
    try expectAst("let x = 1, y = 2;",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..9]
        \\      (binding "x" [4..5])
        \\      (numeric "1" [8..9]))
        \\    (declarator [11..16]
        \\      (binding "y" [11..12])
        \\      (numeric "2" [15..16]))))
    );
}

test "Parser: const with initializer" {
    try expectAst("const z = 42;",
        \\(program script [0..13]
        \\  (lexical kind=const_ [0..13]
        \\    (declarator [6..12]
        \\      (binding "z" [6..7])
        \\      (numeric "42" [10..12]))))
    );
}

test "Parser: const without initializer is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "const w;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.const_without_initializer, diags.items[0].code);
}

test "Parser: recovery after malformed statement" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // First statement is malformed (`)` unexpected); parser should recover
    // and still parse the second statement.
    const program = parseScript(arena.allocator(), ");\nlet x = 1;", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    // Second statement should be the LexicalDeclaration.
    try testing.expect(program.body.len >= 1);
    const last = program.body[program.body.len - 1];
    try testing.expectEqual(@as(std.meta.Tag(Statement), .lexical), std.meta.activeTag(last));
}

test "Parser: let eval = 1 emits restricted_identifier_in_strict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "let eval = 1;", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.restricted_identifier_in_strict, diags.items[0].code);
}

test "Parser: arrow (x, {x}) duplicate BoundNames emits SyntaxError" {
    // §15.3.1: BoundNames of ArrowParameters must contain no duplicates.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "var af = (x, {x}) => 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.restricted_identifier_in_strict, diags.items[0].code);
}

test "Parser: arrow (x, ...x) duplicate BoundNames emits SyntaxError" {
    // §15.3.1: rest parameter target collides with prior simple param.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "var af = (x, ...x) => 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.restricted_identifier_in_strict, diags.items[0].code);
}

test "Parser: invalid regex /{2}/ emits invalid_regex_literal" {
    // §22.2.3.4: an InvalidBracedQuantifier in Atom position fails the
    // RegExpInitialize syntax (and the §22.2.1 grammar before that).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/{2}/;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.invalid_regex_literal, diags.items[0].code);
}

test "Parser: regex with invalid flag /abc/qq emits SyntaxError" {
    // §22.2.3.4 step 6: each RegExpFlag must be in `dgimsuvy`.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/abc/qq;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.invalid_regex_literal, diags.items[0].code);
}

test "Parser: regex with duplicate flag /abc/gg emits SyntaxError" {
    // §22.2.3.4: RegExpFlag values must be unique.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/abc/gg;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.invalid_regex_literal, diags.items[0].code);
}

test "Parser: regex with conflicting u and v flags emits SyntaxError" {
    // §22.2.3.4: `u` and `v` are mutually exclusive.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/abc/uv;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.invalid_regex_literal, diags.items[0].code);
}

test "Parser: valid regex /abc/g produces no diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/abc/g;", &diags) catch unreachable;
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "Parser: \\p{Script=Unknown} property escapes parse without diagnostic" {
    // §22.2.1.1: `Script=Unknown` (alias `sc=Zzzz`) is the @missing
    // complement — a valid property value Cynic's tables model. The
    // parse-time validator must inject the same `\p{…}` resolver the
    // runtime bridge uses (`unicode/perlex_props.zig`); a null resolver
    // would defer to the vendored libregexp, which rejects this value
    // and false-rejects the literal at parse phase.
    const srcs = [_][]const u8{
        "/\\p{Script=Unknown}/u;",
        "/\\P{Script=Unknown}/u;",
        "/\\p{sc=Zzzz}/u;",
        "/\\p{Script_Extensions=Unknown}/u;",
        "/\\p{scx=Zzzz}/u;",
    };
    for (srcs) |src| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diags: Diagnostics = .empty;
        defer diags.deinit(arena.allocator());
        _ = parseScript(arena.allocator(), src, &diags) catch unreachable;
        testing.expectEqual(@as(usize, 0), diags.items.len) catch |e| {
            std.debug.print("unexpected diagnostic for {s}\n", .{src});
            return e;
        };
    }
}

test "Parser: \\p{NotAProperty} still rejects as invalid_regex_literal" {
    // The resolver must not whitelist genuinely-unknown names: a value
    // neither Cynic's tables nor libregexp recognise stays an early
    // SyntaxError (§22.2.3.4 RegExpInitialize).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "/\\p{NotAProperty}/u;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.invalid_regex_literal, diags.items[0].code);
}

test "Parser: for (var x in {}) let y; rejects Declaration as body" {
    // §14.7.5: substatement position accepts Statement, not Declaration.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "for (var x in {}) let y;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

test "Parser: for (var x in {}) function f() {} rejects FunctionDeclaration" {
    // §14.7.5: substatement position accepts Statement, not Declaration.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "for (var x in {}) function f() {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: for (this in {}) rejects non-assignment-target LHS" {
    // §13.7.5.1: LHS of for-in/of must be a valid assignment target.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "for (this in {}) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.assignment_target_invalid, diags.items[0].code);
}

test "Parser: for (let [x, x] in {}) rejects duplicate BoundNames" {
    // §14.7.5.1 / §14.3.1: BoundNames of ForDeclaration must be unique.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "for (let [x, x] in {}) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: let [x, x] = [1,2] rejects duplicate BoundNames" {
    // §14.3.1: BoundNames of LexicalDeclaration must be unique.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "let [x, x] = [1,2];", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: for (let x in {}) { var x; } rejects let/var overlap" {
    // §14.7.5.1: BoundNames of ForDeclaration ∩ VarDeclaredNames empty.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "for (let x in {}) { var x; }", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: arrow ({y: x}, ...x) duplicate BoundNames emits SyntaxError" {
    // §15.3.1: ObjectBindingPattern element collides with later rest.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "var af = ({y: x}, ...x) => 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.restricted_identifier_in_strict, diags.items[0].code);
}

test "Parser: const arguments = 1 emits restricted_identifier_in_strict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "const arguments = 1;", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.restricted_identifier_in_strict, diags.items[0].code);
}

test "Parser: delete x emits delete_of_unqualified_identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "delete x;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.delete_of_unqualified_identifier, diags.items[0].code);
}

test "Parser: delete (a) is also a bare identifier delete" {
    // Per §13.5.1.1, `delete (Identifier)` is still a SyntaxError in strict
    // mode because the parenthesized expression's content is just an
    // identifier reference. Member expressions inside parens — e.g.
    // `delete (a.b)` — are NOT this slice; that test will land with member
    // expressions.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "delete (x);", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.delete_of_unqualified_identifier, diags.items[0].code);
}

test "Parser: NoSubstitutionTemplate" {
    try expectAst("`hello`;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (template [0..7]
        \\      (quasi "hello" [1..6]))))
    );
}

test "Parser: TemplateLiteral with one substitution" {
    try expectAst("`a${b}c`;",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (template [0..8]
        \\      (quasi "a" [1..2])
        \\      (ident "b" [4..5])
        \\      (quasi "c" [6..7]))))
    );
}

test "Parser: TemplateLiteral with two substitutions" {
    try expectAst("`a${1}b${2}c`;",
        \\(program script [0..14]
        \\  (expr-stmt [0..14]
        \\    (template [0..13]
        \\      (quasi "a" [1..2])
        \\      (numeric "1" [4..5])
        \\      (quasi "b" [6..7])
        \\      (numeric "2" [9..10])
        \\      (quasi "c" [11..12]))))
    );
}

test "Parser: TemplateLiteral with empty quasis" {
    try expectAst("`${x}`;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (template [0..6]
        \\      (quasi "" [1..1])
        \\      (ident "x" [3..4])
        \\      (quasi "" [5..5]))))
    );
}

test "Parser: TemplateLiteral as initializer" {
    try expectAst("let s = `hi`;",
        \\(program script [0..13]
        \\  (lexical kind=let_ [0..13]
        \\    (declarator [4..12]
        \\      (binding "s" [4..5])
        \\      (template [8..12]
        \\        (quasi "hi" [9..11])))))
    );
}

// ── §13.3 Member access ─────────────────────────────────────────────────

test "Parser: simple member access" {
    try expectAst("a.b;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (member [0..3]
        \\      (ident "a" [0..1])
        \\      (prop "b" [2..3]))))
    );
}

test "Parser: chained member access" {
    try expectAst("a.b.c;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (member [0..5]
        \\      (member [0..3]
        \\        (ident "a" [0..1])
        \\        (prop "b" [2..3]))
        \\      (prop "c" [4..5]))))
    );
}

test "Parser: computed member access" {
    try expectAst("a[b];",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (member computed [0..4]
        \\      (ident "a" [0..1])
        \\      (ident "b" [2..3]))))
    );
}

test "Parser: computed member access with expression key" {
    try expectAst("a[1 + 2];",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (member computed [0..8]
        \\      (ident "a" [0..1])
        \\      (binary op=+ [2..7]
        \\        (numeric "1" [2..3])
        \\        (numeric "2" [6..7])))))
    );
}

test "Parser: mixed member access" {
    try expectAst("a.b[c].d;",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (member [0..8]
        \\      (member computed [0..6]
        \\        (member [0..3]
        \\          (ident "a" [0..1])
        \\          (prop "b" [2..3]))
        \\        (ident "c" [4..5]))
        \\      (prop "d" [7..8]))))
    );
}

test "Parser: private field access" {
    try expectAst("a.#x;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (member [0..4]
        \\      (ident "a" [0..1])
        \\      (prop "#x" [2..4]))))
    );
}

test "Parser: member access on parenthesized" {
    try expectAst("(a).b;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (member [0..5]
        \\      (paren [0..3]
        \\        (ident "a" [1..2]))
        \\      (prop "b" [4..5]))))
    );
}

test "Parser: keyword-named property is allowed (a.if)" {
    // §12.7: IdentifierName allows reserved words after `.`.
    try expectAst("a.if;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (member [0..4]
        \\      (ident "a" [0..1])
        \\      (prop "if" [2..4]))))
    );
}

// ── §13.3 Calls ─────────────────────────────────────────────────────────

test "Parser: empty call" {
    try expectAst("f();",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (call [0..3]
        \\      (ident "f" [0..1]))))
    );
}

test "Parser: call with one argument" {
    try expectAst("f(a);",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (call [0..4]
        \\      (ident "f" [0..1])
        \\      (ident "a" [2..3]))))
    );
}

test "Parser: call with multiple arguments" {
    try expectAst("f(a, b);",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (call [0..7]
        \\      (ident "f" [0..1])
        \\      (ident "a" [2..3])
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: call with trailing comma" {
    try expectAst("f(a,);",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (call [0..5]
        \\      (ident "f" [0..1])
        \\      (ident "a" [2..3]))))
    );
}

test "Parser: call with spread" {
    try expectAst("f(...args);",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (call [0..10]
        \\      (ident "f" [0..1])
        \\      (spread [2..9]
        \\        (ident "args" [5..9])))))
    );
}

test "Parser: call with mixed args and spread" {
    try expectAst("f(a, ...rest);",
        \\(program script [0..14]
        \\  (expr-stmt [0..14]
        \\    (call [0..13]
        \\      (ident "f" [0..1])
        \\      (ident "a" [2..3])
        \\      (spread [5..12]
        \\        (ident "rest" [8..12])))))
    );
}

test "Parser: chained calls" {
    try expectAst("f().g();",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (call [0..7]
        \\      (member [0..5]
        \\        (call [0..3]
        \\          (ident "f" [0..1]))
        \\        (prop "g" [4..5])))))
    );
}

test "Parser: method call" {
    try expectAst("obj.method(arg);",
        \\(program script [0..16]
        \\  (expr-stmt [0..16]
        \\    (call [0..15]
        \\      (member [0..10]
        \\        (ident "obj" [0..3])
        \\        (prop "method" [4..10]))
        \\      (ident "arg" [11..14]))))
    );
}

test "Parser: arguments use AssignmentExpression (not Expression)" {
    // Comma in args is the separator, not the comma operator.
    try expectAst("f(a, b);",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (call [0..7]
        \\      (ident "f" [0..1])
        \\      (ident "a" [2..3])
        \\      (ident "b" [5..6]))))
    );
}

test "Parser: call with assignment as argument" {
    try expectAst("f(a = 1);",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (call [0..8]
        \\      (ident "f" [0..1])
        \\      (assign op== [2..7]
        \\        (ident "a" [2..3])
        \\        (numeric "1" [6..7])))))
    );
}

// ── §13.3 `new` ─────────────────────────────────────────────────────────

test "Parser: new without parens" {
    try expectAst("new X;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (new [0..5]
        \\      (ident "X" [4..5]))))
    );
}

test "Parser: new with empty parens" {
    try expectAst("new X();",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (new [0..7]
        \\      (ident "X" [4..5]))))
    );
}

test "Parser: new with arguments" {
    try expectAst("new X(a, b);",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (new [0..11]
        \\      (ident "X" [4..5])
        \\      (ident "a" [6..7])
        \\      (ident "b" [9..10]))))
    );
}

test "Parser: new with member callee" {
    try expectAst("new X.Y(a);",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (new [0..10]
        \\      (member [4..7]
        \\        (ident "X" [4..5])
        \\        (prop "Y" [6..7]))
        \\      (ident "a" [8..9]))))
    );
}

test "Parser: new with computed member callee" {
    try expectAst("new X[k]();",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (new [0..10]
        \\      (member computed [4..8]
        \\        (ident "X" [4..5])
        \\        (ident "k" [6..7])))))
    );
}

test "Parser: recursive new" {
    try expectAst("new new X;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (new [0..9]
        \\      (new [4..9]
        \\        (ident "X" [8..9])))))
    );
}

test "Parser: new followed by call on result" {
    // `new X()` is the constructor; the second `()` calls the resulting
    // instance.
    try expectAst("new X()();",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (call [0..9]
        \\      (new [0..7]
        \\        (ident "X" [4..5])))))
    );
}

// ── §13.3.10 Optional chaining ──────────────────────────────────────────

test "Parser: optional member" {
    try expectAst("a?.b;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (chain [0..4]
        \\      (member optional [0..4]
        \\        (ident "a" [0..1])
        \\        (prop "b" [3..4])))))
    );
}

test "Parser: optional computed member" {
    try expectAst("a?.[b];",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (chain [0..6]
        \\      (member computed optional [0..6]
        \\        (ident "a" [0..1])
        \\        (ident "b" [4..5])))))
    );
}

test "Parser: optional call" {
    try expectAst("f?.();",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (chain [0..5]
        \\      (call optional [0..5]
        \\        (ident "f" [0..1])))))
    );
}

test "Parser: optional then non-optional in same chain" {
    // `a?.b.c` — the second `.c` is still inside the chain (no parens broke
    // it), so it's a non-optional member but the whole thing is wrapped in
    // a single ChainExpression.
    try expectAst("a?.b.c;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (chain [0..6]
        \\      (member [0..6]
        \\        (member optional [0..4]
        \\          (ident "a" [0..1])
        \\          (prop "b" [3..4]))
        \\        (prop "c" [5..6])))))
    );
}

test "Parser: parens break the optional chain" {
    // `(a?.b).c` — the `.c` is OUTSIDE the chain because the parentheses
    // close it; only the inner `?.b` is the chain.
    try expectAst("(a?.b).c;",
        \\(program script [0..9]
        \\  (expr-stmt [0..9]
        \\    (member [0..8]
        \\      (paren [0..6]
        \\        (chain [1..5]
        \\          (member optional [1..5]
        \\            (ident "a" [1..2])
        \\            (prop "b" [4..5]))))
        \\      (prop "c" [7..8]))))
    );
}

test "Parser: optional call followed by member" {
    try expectAst("f?.().g;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (chain [0..7]
        \\      (member [0..7]
        \\        (call optional [0..5]
        \\          (ident "f" [0..1]))
        \\        (prop "g" [6..7])))))
    );
}

// ── §13.3.11 Tagged templates ───────────────────────────────────────────

test "Parser: tagged NoSubstitutionTemplate" {
    try expectAst("tag`hi`;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (tagged-template [0..7]
        \\      (ident "tag" [0..3])
        \\      (template [3..7]
        \\        (quasi "hi" [4..6])))))
    );
}

test "Parser: tagged template with substitution" {
    try expectAst("tag`hi ${x}!`;",
        \\(program script [0..14]
        \\  (expr-stmt [0..14]
        \\    (tagged-template [0..13]
        \\      (ident "tag" [0..3])
        \\      (template [3..13]
        \\        (quasi "hi " [4..7])
        \\        (ident "x" [9..10])
        \\        (quasi "!" [11..12])))))
    );
}

test "Parser: tagged template on member" {
    try expectAst("a.tag`hi`;",
        \\(program script [0..10]
        \\  (expr-stmt [0..10]
        \\    (tagged-template [0..9]
        \\      (member [0..5]
        \\        (ident "a" [0..1])
        \\        (prop "tag" [2..5]))
        \\      (template [5..9]
        \\        (quasi "hi" [6..8])))))
    );
}

test "Parser: tagged template after call" {
    try expectAst("f()`hi`;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (tagged-template [0..7]
        \\      (call [0..3]
        \\        (ident "f" [0..1]))
        \\      (template [3..7]
        \\        (quasi "hi" [4..6])))))
    );
}

test "Parser: delete a.b is allowed (member is not bare identifier)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "delete a.b;", &diags) catch unreachable;
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

// ── §13.4 Update expressions + ASI rule 2 ───────────────────────────────

test "Parser: prefix increment" {
    try expectAst("++x;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (update op=++ prefix [0..3]
        \\      (ident "x" [2..3]))))
    );
}

test "Parser: prefix decrement" {
    try expectAst("--y;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (update op=-- prefix [0..3]
        \\      (ident "y" [2..3]))))
    );
}

test "Parser: postfix increment" {
    try expectAst("x++;",
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (update op=++ postfix [0..3]
        \\      (ident "x" [0..1]))))
    );
}

test "Parser: postfix decrement on member" {
    try expectAst("a.b--;",
        \\(program script [0..6]
        \\  (expr-stmt [0..6]
        \\    (update op=-- postfix [0..5]
        \\      (member [0..3]
        \\        (ident "a" [0..1])
        \\        (prop "b" [2..3])))))
    );
}

test "Parser: postfix update is rejected after a LineTerminator" {
    // §12.10.1 Restricted production: `LeftHandSideExpression [no LF] ++`.
    // With a LF before `++`, ASI inserts before `++`, leaving it as the next
    // statement's prefix update. So `x\n++y` parses as `x;` then `++y;`.
    try expectAst("x\n++y;",
        \\(program script [0..6]
        \\  (expr-stmt [0..1]
        \\    (ident "x" [0..1]))
        \\  (expr-stmt [2..6]
        \\    (update op=++ prefix [2..5]
        \\      (ident "y" [4..5]))))
    );
}

test "Parser: postfix on call result is rejected (invalid LHS)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "f()++;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.assignment_target_invalid, diags.items[0].code);
}

// ── §13.15 Compound assignments ─────────────────────────────────────────

test "Parser: plus-assign" {
    try expectAst("a += 1;",
        \\(program script [0..7]
        \\  (expr-stmt [0..7]
        \\    (assign op=+= [0..6]
        \\      (ident "a" [0..1])
        \\      (numeric "1" [5..6]))))
    );
}

test "Parser: nullish coalescing assign" {
    try expectAst("a ??= b;",
        \\(program script [0..8]
        \\  (expr-stmt [0..8]
        \\    (assign op=??= [0..7]
        \\      (ident "a" [0..1])
        \\      (ident "b" [6..7]))))
    );
}

test "Parser: compound assign on member" {
    try expectAst("obj.x *= 2;",
        \\(program script [0..11]
        \\  (expr-stmt [0..11]
        \\    (assign op=*= [0..10]
        \\      (member [0..5]
        \\        (ident "obj" [0..3])
        \\        (prop "x" [4..5]))
        \\      (numeric "2" [9..10]))))
    );
}

test "Parser: compound assign is right-associative" {
    try expectAst("a += b -= 1;",
        \\(program script [0..12]
        \\  (expr-stmt [0..12]
        \\    (assign op=+= [0..11]
        \\      (ident "a" [0..1])
        \\      (assign op=-= [5..11]
        \\        (ident "b" [5..6])
        \\        (numeric "1" [10..11])))))
    );
}

// ── §14.6 if statement ──────────────────────────────────────────────────

test "Parser: if without else" {
    try expectAst("if (x) y;",
        \\(program script [0..9]
        \\  (if [0..9]
        \\    (ident "x" [4..5])
        \\    (expr-stmt [7..9]
        \\      (ident "y" [7..8]))))
    );
}

test "Parser: if/else" {
    try expectAst("if (x) y; else z;",
        \\(program script [0..17]
        \\  (if [0..17]
        \\    (ident "x" [4..5])
        \\    (expr-stmt [7..9]
        \\      (ident "y" [7..8]))
        \\    (expr-stmt [15..17]
        \\      (ident "z" [15..16]))))
    );
}

test "Parser: if with block" {
    try expectAst("if (x) { y; }",
        \\(program script [0..13]
        \\  (if [0..13]
        \\    (ident "x" [4..5])
        \\    (block [7..13]
        \\      (expr-stmt [9..11]
        \\        (ident "y" [9..10])))))
    );
}

test "Parser: chained if-else if" {
    try expectAst("if (a) p; else if (b) q; else r;",
        \\(program script [0..32]
        \\  (if [0..32]
        \\    (ident "a" [4..5])
        \\    (expr-stmt [7..9]
        \\      (ident "p" [7..8]))
        \\    (if [15..32]
        \\      (ident "b" [19..20])
        \\      (expr-stmt [22..24]
        \\        (ident "q" [22..23]))
        \\      (expr-stmt [30..32]
        \\        (ident "r" [30..31])))))
    );
}

// ── §14.7 while / do-while ──────────────────────────────────────────────

test "Parser: while statement" {
    try expectAst("while (x) y;",
        \\(program script [0..12]
        \\  (while [0..12]
        \\    (ident "x" [7..8])
        \\    (expr-stmt [10..12]
        \\      (ident "y" [10..11]))))
    );
}

test "Parser: while with block" {
    try expectAst("while (true) { f(); }",
        \\(program script [0..21]
        \\  (while [0..21]
        \\    (bool true [7..11])
        \\    (block [13..21]
        \\      (expr-stmt [15..19]
        \\        (call [15..18]
        \\          (ident "f" [15..16]))))))
    );
}

test "Parser: do-while statement" {
    try expectAst("do f(); while (cond);",
        \\(program script [0..21]
        \\  (do-while [0..21]
        \\    (expr-stmt [3..7]
        \\      (call [3..6]
        \\        (ident "f" [3..4])))
        \\    (ident "cond" [15..19])))
    );
}

test "Parser: do-while with block" {
    try expectAst("do { f(); } while (x);",
        \\(program script [0..22]
        \\  (do-while [0..22]
        \\    (block [3..11]
        \\      (expr-stmt [5..9]
        \\        (call [5..8]
        \\          (ident "f" [5..6]))))
        \\    (ident "x" [19..20])))
    );
}

// ── §14.10 / §14.14 / §14.13 / §14.15 return / throw / break / continue ─

test "Parser: return without argument" {
    // §14.10.1 — `return` is a SyntaxError at script top-level;
    // wrap in a function so the production is well-formed.
    try expectAst("function f() { return; }",
        \\(program script [0..24]
        \\  (function-decl "f" [0..24]
        \\    (block [13..24]
        \\      (return [15..22]))))
    );
}

test "Parser: return with argument" {
    try expectAst("function f() { return x; }",
        \\(program script [0..26]
        \\  (function-decl "f" [0..26]
        \\    (block [13..26]
        \\      (return [15..24]
        \\        (ident "x" [22..23])))))
    );
}

test "Parser: return ASI rule 2 — line terminator inserts before expression" {
    try expectAst("function f() { return\nx; }",
        \\(program script [0..26]
        \\  (function-decl "f" [0..26]
        \\    (block [13..26]
        \\      (return [15..21])
        \\      (expr-stmt [22..24]
        \\        (ident "x" [22..23])))))
    );
}

test "Parser: bare return at script top-level is a SyntaxError" {
    try expectParseError("return;");
}

test "Parser: throw with argument" {
    try expectAst("throw err;",
        \\(program script [0..10]
        \\  (throw [0..10]
        \\    (ident "err" [6..9])))
    );
}

test "Parser: throw with no argument and no LF is a SyntaxError" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "throw;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

test "Parser: throw with LineTerminator before expression is also a SyntaxError" {
    // §12.10.1: `throw [no LF here] Expression`. A LineTerminator immediately
    // after `throw` makes the throw operand-less, which is invalid.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "throw\nerr;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

test "Parser: break statement" {
    try expectAst("break;",
        \\(program script [0..6]
        \\  (break [0..6]))
    );
}

test "Parser: continue statement" {
    try expectAst("continue;",
        \\(program script [0..9]
        \\  (continue [0..9]))
    );
}

// ── §14.7.4 / §14.7.5 for / for-in / for-of ─────────────────────────────

test "Parser: empty C-style for" {
    try expectAst("for (;;) {}",
        \\(program script [0..11]
        \\  (for [0..11]
        \\    (init)
        \\    (test)
        \\    (update)
        \\    (block [9..11])))
    );
}

test "Parser: C-style for with let init" {
    try expectAst("for (let i = 0; i < n; i++) {}",
        \\(program script [0..30]
        \\  (for [0..30]
        \\    (init
        \\      (lexical kind=let_ [5..14]
        \\        (declarator [9..14]
        \\          (binding "i" [9..10])
        \\          (numeric "0" [13..14]))))
        \\    (test
        \\      (binary op=< [16..21]
        \\        (ident "i" [16..17])
        \\        (ident "n" [20..21])))
        \\    (update
        \\      (update op=++ postfix [23..26]
        \\        (ident "i" [23..24])))
        \\    (block [28..30])))
    );
}

test "Parser: C-style for with expression init" {
    try expectAst("for (i = 0; i < n; i++) {}",
        \\(program script [0..26]
        \\  (for [0..26]
        \\    (init
        \\      (assign op== [5..10]
        \\        (ident "i" [5..6])
        \\        (numeric "0" [9..10])))
        \\    (test
        \\      (binary op=< [12..17]
        \\        (ident "i" [12..13])
        \\        (ident "n" [16..17])))
        \\    (update
        \\      (update op=++ postfix [19..22]
        \\        (ident "i" [19..20])))
        \\    (block [24..26])))
    );
}

test "Parser: for-in with let" {
    try expectAst("for (let k in obj) body;",
        \\(program script [0..24]
        \\  (for-in [0..24]
        \\    (lexical kind=let_ [5..10]
        \\      (declarator [9..10]
        \\        (binding "k" [9..10])))
        \\    (ident "obj" [14..17])
        \\    (expr-stmt [19..24]
        \\      (ident "body" [19..23]))))
    );
}

test "Parser: for-in with bare LHS" {
    try expectAst("for (k in obj) body;",
        \\(program script [0..20]
        \\  (for-in [0..20]
        \\    (ident "k" [5..6])
        \\    (ident "obj" [10..13])
        \\    (expr-stmt [15..20]
        \\      (ident "body" [15..19]))))
    );
}

test "Parser: for-of with let" {
    try expectAst("for (let x of arr) f(x);",
        \\(program script [0..24]
        \\  (for-of [0..24]
        \\    (lexical kind=let_ [5..10]
        \\      (declarator [9..10]
        \\        (binding "x" [9..10])))
        \\    (ident "arr" [14..17])
        \\    (expr-stmt [19..24]
        \\      (call [19..23]
        \\        (ident "f" [19..20])
        \\        (ident "x" [21..22])))))
    );
}

test "Parser: for-of with bare LHS" {
    try expectAst("for (x of arr) body;",
        \\(program script [0..20]
        \\  (for-of [0..20]
        \\    (ident "x" [5..6])
        \\    (ident "arr" [10..13])
        \\    (expr-stmt [15..20]
        \\      (ident "body" [15..19]))))
    );
}

// ── §14.15 try / catch / finally ────────────────────────────────────────

test "Parser: try / catch with parameter" {
    try expectAst("try { f(); } catch (e) { g(e); }",
        \\(program script [0..32]
        \\  (try [0..32]
        \\    (block [4..12]
        \\      (expr-stmt [6..10]
        \\        (call [6..9]
        \\          (ident "f" [6..7]))))
        \\    (catch [13..32]
        \\      (binding "e" [20..21])
        \\      (block [23..32]
        \\        (expr-stmt [25..30]
        \\          (call [25..29]
        \\            (ident "g" [25..26])
        \\            (ident "e" [27..28])))))))
    );
}

test "Parser: try / catch without parameter (ES2019)" {
    try expectAst("try {} catch {}",
        \\(program script [0..15]
        \\  (try [0..15]
        \\    (block [4..6])
        \\    (catch [7..15]
        \\      (block [13..15]))))
    );
}

test "Parser: try / finally" {
    try expectAst("try {} finally {}",
        \\(program script [0..17]
        \\  (try [0..17]
        \\    (block [4..6])
        \\    (finally
        \\      (block [15..17]))))
    );
}

test "Parser: try / catch / finally" {
    try expectAst("try {} catch (e) {} finally {}",
        \\(program script [0..30]
        \\  (try [0..30]
        \\    (block [4..6])
        \\    (catch [7..19]
        \\      (binding "e" [14..15])
        \\      (block [17..19]))
        \\    (finally
        \\      (block [28..30]))))
    );
}

// ── §14.12 switch ───────────────────────────────────────────────────────

test "Parser: switch with cases and default" {
    try expectAst("switch (x) { case 1: a; break; case 2: b; default: c; }",
        \\(program script [0..55]
        \\  (switch [0..55]
        \\    (ident "x" [8..9])
        \\    (case [13..30]
        \\      (numeric "1" [18..19])
        \\      (expr-stmt [21..23]
        \\        (ident "a" [21..22]))
        \\      (break [24..30]))
        \\    (case [31..41]
        \\      (numeric "2" [36..37])
        \\      (expr-stmt [39..41]
        \\        (ident "b" [39..40])))
        \\    (default [42..53]
        \\      (expr-stmt [51..53]
        \\        (ident "c" [51..52])))))
    );
}

test "Parser: empty switch" {
    try expectAst("switch (x) {}",
        \\(program script [0..13]
        \\  (switch [0..13]
        \\    (ident "x" [8..9])))
    );
}

// ── §14.16 debugger ─────────────────────────────────────────────────────

test "Parser: debugger statement" {
    try expectAst("debugger;",
        \\(program script [0..9]
        \\  (debugger [0..9]))
    );
}

// ── §15.2 Functions ─────────────────────────────────────────────────────

test "Parser: empty function declaration" {
    try expectAst("function f() {}",
        \\(program script [0..15]
        \\  (function-decl "f" [0..15]
        \\    (block [13..15])))
    );
}

test "Parser: function with one parameter" {
    try expectAst("function f(a) { return a; }",
        \\(program script [0..27]
        \\  (function-decl "f" [0..27]
        \\    (param "a" [11..12])
        \\    (block [14..27]
        \\      (return [16..25]
        \\        (ident "a" [23..24])))))
    );
}

test "Parser: function with multiple parameters" {
    try expectAst("function add(a, b) { return a + b; }",
        \\(program script [0..36]
        \\  (function-decl "add" [0..36]
        \\    (param "a" [13..14])
        \\    (param "b" [16..17])
        \\    (block [19..36]
        \\      (return [21..34]
        \\        (binary op=+ [28..33]
        \\          (ident "a" [28..29])
        \\          (ident "b" [32..33]))))))
    );
}

test "Parser: function with default parameter" {
    try expectAst("function f(a = 1) {}",
        \\(program script [0..20]
        \\  (function-decl "f" [0..20]
        \\    (param "a" [11..16]
        \\      (numeric "1" [15..16]))
        \\    (block [18..20])))
    );
}

test "Parser: function with rest parameter" {
    try expectAst("function f(...args) {}",
        \\(program script [0..22]
        \\  (function-decl "f" [0..22]
        \\    (rest "args" [11..18])
        \\    (block [20..22])))
    );
}

test "Parser: function with mixed and rest parameters" {
    try expectAst("function f(a, b, ...rest) {}",
        \\(program script [0..28]
        \\  (function-decl "f" [0..28]
        \\    (param "a" [11..12])
        \\    (param "b" [14..15])
        \\    (rest "rest" [17..24])
        \\    (block [26..28])))
    );
}

test "Parser: function with trailing comma in parameters" {
    try expectAst("function f(a, b,) {}",
        \\(program script [0..20]
        \\  (function-decl "f" [0..20]
        \\    (param "a" [11..12])
        \\    (param "b" [14..15])
        \\    (block [18..20])))
    );
}

test "Parser: anonymous function expression" {
    try expectAst("let f = function() {};",
        \\(program script [0..22]
        \\  (lexical kind=let_ [0..22]
        \\    (declarator [4..21]
        \\      (binding "f" [4..5])
        \\      (function-expr [8..21]
        \\        (block [19..21])))))
    );
}

test "Parser: named function expression" {
    try expectAst("let f = function named() {};",
        \\(program script [0..28]
        \\  (lexical kind=let_ [0..28]
        \\    (declarator [4..27]
        \\      (binding "f" [4..5])
        \\      (function-expr "named" [8..27]
        \\        (block [25..27])))))
    );
}

test "Parser: IIFE — immediately invoked function expression" {
    try expectAst("(function() { return 1; })();",
        \\(program script [0..29]
        \\  (expr-stmt [0..29]
        \\    (call [0..28]
        \\      (paren [0..26]
        \\        (function-expr [1..25]
        \\          (block [12..25]
        \\            (return [14..23]
        \\              (numeric "1" [21..22]))))))))
    );
}

test "Parser: function declaration before use parses cleanly" {
    try expectAst("f(); function f() {}",
        \\(program script [0..20]
        \\  (expr-stmt [0..4]
        \\    (call [0..3]
        \\      (ident "f" [0..1])))
        \\  (function-decl "f" [5..20]
        \\    (block [18..20])))
    );
}

// ── §13.2.4 Array literals ──────────────────────────────────────────────

test "Parser: empty array" {
    try expectAst("let a = [];",
        \\(program script [0..11]
        \\  (lexical kind=let_ [0..11]
        \\    (declarator [4..10]
        \\      (binding "a" [4..5])
        \\      (array [8..10]))))
    );
}

test "Parser: array with elements" {
    try expectAst("let a = [1, 2, 3];",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (binding "a" [4..5])
        \\      (array [8..17]
        \\        (numeric "1" [9..10])
        \\        (numeric "2" [12..13])
        \\        (numeric "3" [15..16])))))
    );
}

test "Parser: array with elision" {
    try expectAst("let a = [1, , 3];",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (binding "a" [4..5])
        \\      (array [8..16]
        \\        (numeric "1" [9..10])
        \\        (elision)
        \\        (numeric "3" [14..15])))))
    );
}

test "Parser: array with trailing comma" {
    try expectAst("let a = [1, 2,];",
        \\(program script [0..16]
        \\  (lexical kind=let_ [0..16]
        \\    (declarator [4..15]
        \\      (binding "a" [4..5])
        \\      (array [8..15]
        \\        (numeric "1" [9..10])
        \\        (numeric "2" [12..13])))))
    );
}

test "Parser: array with spread" {
    try expectAst("let a = [...rest];",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (binding "a" [4..5])
        \\      (array [8..17]
        \\        (spread [9..16]
        \\          (ident "rest" [12..16]))))))
    );
}

// ── §13.2.5 Object literals ─────────────────────────────────────────────

test "Parser: empty object" {
    try expectAst("let o = {};",
        \\(program script [0..11]
        \\  (lexical kind=let_ [0..11]
        \\    (declarator [4..10]
        \\      (binding "o" [4..5])
        \\      (object [8..10]))))
    );
}

test "Parser: object with ident keys" {
    try expectAst("let o = { a: 1, b: 2 };",
        \\(program script [0..23]
        \\  (lexical kind=let_ [0..23]
        \\    (declarator [4..22]
        \\      (binding "o" [4..5])
        \\      (object [8..22]
        \\        (prop [10..14]
        \\          (key ident "a" [10..11])
        \\          (numeric "1" [13..14]))
        \\        (prop [16..20]
        \\          (key ident "b" [16..17])
        \\          (numeric "2" [19..20]))))))
    );
}

test "Parser: object shorthand" {
    try expectAst("let o = { a, b };",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (binding "o" [4..5])
        \\      (object [8..16]
        \\        (prop shorthand [10..11]
        \\          (key ident "a" [10..11]))
        \\        (prop shorthand [13..14]
        \\          (key ident "b" [13..14]))))))
    );
}

test "Parser: object with string and numeric keys" {
    try expectAst("let o = { \"x\": 1, 0: 2 };",
        \\(program script [0..25]
        \\  (lexical kind=let_ [0..25]
        \\    (declarator [4..24]
        \\      (binding "o" [4..5])
        \\      (object [8..24]
        \\        (prop [10..16]
        \\          (key string "x" [10..13])
        \\          (numeric "1" [15..16]))
        \\        (prop [18..22]
        \\          (key numeric "0" [18..19])
        \\          (numeric "2" [21..22]))))))
    );
}

test "Parser: object with computed key" {
    try expectAst("let o = { [k]: 1 };",
        \\(program script [0..19]
        \\  (lexical kind=let_ [0..19]
        \\    (declarator [4..18]
        \\      (binding "o" [4..5])
        \\      (object [8..18]
        \\        (prop [10..16]
        \\          (key computed
        \\            (ident "k" [11..12]))
        \\          (numeric "1" [15..16]))))))
    );
}

test "Parser: object with spread" {
    try expectAst("let o = { ...rest };",
        \\(program script [0..20]
        \\  (lexical kind=let_ [0..20]
        \\    (declarator [4..19]
        \\      (binding "o" [4..5])
        \\      (object [8..19]
        \\        (spread [10..17]
        \\          (ident "rest" [13..17]))))))
    );
}

test "Parser: object with reserved-word key" {
    // §12.7 IdentifierName allows reserved words as property keys.
    try expectAst("let o = { if: 1 };",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (binding "o" [4..5])
        \\      (object [8..17]
        \\        (prop [10..15]
        \\          (key ident "if" [10..12])
        \\          (numeric "1" [14..15]))))))
    );
}

// ── §15.3 Arrow functions ───────────────────────────────────────────────

test "Parser: arrow with single bare param + concise body" {
    try expectAst("let f = x => x;",
        \\(program script [0..15]
        \\  (lexical kind=let_ [0..15]
        \\    (declarator [4..14]
        \\      (binding "f" [4..5])
        \\      (arrow [8..14]
        \\        (param "x" [8..9])
        \\        (ident "x" [13..14])))))
    );
}

test "Parser: arrow with empty params + concise body" {
    try expectAst("let f = () => 1;",
        \\(program script [0..16]
        \\  (lexical kind=let_ [0..16]
        \\    (declarator [4..15]
        \\      (binding "f" [4..5])
        \\      (arrow [8..15]
        \\        (numeric "1" [14..15])))))
    );
}

test "Parser: arrow with single parenthesized param" {
    try expectAst("let f = (x) => x;",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (binding "f" [4..5])
        \\      (arrow [8..16]
        \\        (param "x" [9..10])
        \\        (ident "x" [15..16])))))
    );
}

test "Parser: arrow with multiple params" {
    try expectAst("let add = (x, y) => x + y;",
        \\(program script [0..26]
        \\  (lexical kind=let_ [0..26]
        \\    (declarator [4..25]
        \\      (binding "add" [4..7])
        \\      (arrow [10..25]
        \\        (param "x" [11..12])
        \\        (param "y" [14..15])
        \\        (binary op=+ [20..25]
        \\          (ident "x" [20..21])
        \\          (ident "y" [24..25]))))))
    );
}

test "Parser: arrow with default param" {
    try expectAst("let f = (x = 1) => x;",
        \\(program script [0..21]
        \\  (lexical kind=let_ [0..21]
        \\    (declarator [4..20]
        \\      (binding "f" [4..5])
        \\      (arrow [8..20]
        \\        (param "x" [9..14]
        \\          (numeric "1" [13..14]))
        \\        (ident "x" [19..20])))))
    );
}

test "Parser: arrow with block body" {
    try expectAst("let f = x => { return x; };",
        \\(program script [0..27]
        \\  (lexical kind=let_ [0..27]
        \\    (declarator [4..26]
        \\      (binding "f" [4..5])
        \\      (arrow [8..26]
        \\        (param "x" [8..9])
        \\        (block [13..26]
        \\          (return [15..24]
        \\            (ident "x" [22..23])))))))
    );
}

test "Parser: arrow with no params + block body" {
    try expectAst("let f = () => { return 1; };",
        \\(program script [0..28]
        \\  (lexical kind=let_ [0..28]
        \\    (declarator [4..27]
        \\      (binding "f" [4..5])
        \\      (arrow [8..27]
        \\        (block [14..27]
        \\          (return [16..25]
        \\            (numeric "1" [23..24])))))))
    );
}

test "Parser: arrow chained — currying" {
    try expectAst("let curry = a => b => a + b;",
        \\(program script [0..28]
        \\  (lexical kind=let_ [0..28]
        \\    (declarator [4..27]
        \\      (binding "curry" [4..9])
        \\      (arrow [12..27]
        \\        (param "a" [12..13])
        \\        (arrow [17..27]
        \\          (param "b" [17..18])
        \\          (binary op=+ [22..27]
        \\            (ident "a" [22..23])
        \\            (ident "b" [26..27])))))))
    );
}

test "Parser: parenthesized expression that's not an arrow stays as paren" {
    try expectAst("let v = (1 + 2);",
        \\(program script [0..16]
        \\  (lexical kind=let_ [0..16]
        \\    (declarator [4..15]
        \\      (binding "v" [4..5])
        \\      (paren [8..15]
        \\        (binary op=+ [9..14]
        \\          (numeric "1" [9..10])
        \\          (numeric "2" [13..14]))))))
    );
}

test "Parser: arrow as call argument" {
    try expectAst("xs.map(x => x);",
        \\(program script [0..15]
        \\  (expr-stmt [0..15]
        \\    (call [0..14]
        \\      (member [0..6]
        \\        (ident "xs" [0..2])
        \\        (prop "map" [3..6]))
        \\      (arrow [7..13]
        \\        (param "x" [7..8])
        \\        (ident "x" [12..13])))))
    );
}

// ── §15.7 Classes ───────────────────────────────────────────────────────

test "Parser: empty class declaration" {
    try expectAst("class A {}",
        \\(program script [0..10]
        \\  (class-decl "A" [0..10]))
    );
}

test "Parser: class extends" {
    try expectAst("class A extends B {}",
        \\(program script [0..20]
        \\  (class-decl "A" [0..20]
        \\    (extends
        \\      (ident "B" [16..17]))))
    );
}

test "Parser: class with constructor" {
    try expectAst("class A { constructor() {} }",
        \\(program script [0..28]
        \\  (class-decl "A" [0..28]
        \\    (method [10..26]
        \\      (key ident "constructor" [10..21])
        \\      (block [24..26]))))
    );
}

test "Parser: class with multiple methods" {
    try expectAst("class A { foo() {} bar(x) { return x; } }",
        \\(program script [0..41]
        \\  (class-decl "A" [0..41]
        \\    (method [10..18]
        \\      (key ident "foo" [10..13])
        \\      (block [16..18]))
        \\    (method [19..39]
        \\      (key ident "bar" [19..22])
        \\      (param "x" [23..24])
        \\      (block [26..39]
        \\        (return [28..37]
        \\          (ident "x" [35..36]))))))
    );
}

test "Parser: class with static method" {
    try expectAst("class A { static foo() {} }",
        \\(program script [0..27]
        \\  (class-decl "A" [0..27]
        \\    (method static [10..25]
        \\      (key ident "foo" [17..20])
        \\      (block [23..25]))))
    );
}

test "Parser: class with field" {
    try expectAst("class A { x = 1; }",
        \\(program script [0..18]
        \\  (class-decl "A" [0..18]
        \\    (field [10..15]
        \\      (key ident "x" [10..11])
        \\      (numeric "1" [14..15]))))
    );
}

test "Parser: class with field without initializer" {
    try expectAst("class A { x; }",
        \\(program script [0..14]
        \\  (class-decl "A" [0..14]
        \\    (field [10..11]
        \\      (key ident "x" [10..11]))))
    );
}

test "Parser: class with static field" {
    try expectAst("class A { static x = 1; }",
        \\(program script [0..25]
        \\  (class-decl "A" [0..25]
        \\    (field static [10..22]
        \\      (key ident "x" [17..18])
        \\      (numeric "1" [21..22]))))
    );
}

test "Parser: class with private field and method" {
    try expectAst("class A { #x = 1; #priv() {} }",
        \\(program script [0..30]
        \\  (class-decl "A" [0..30]
        \\    (field [10..16]
        \\      (key private "#x" [10..12])
        \\      (numeric "1" [15..16]))
        \\    (method [18..28]
        \\      (key private "#priv" [18..23])
        \\      (block [26..28]))))
    );
}

test "Parser: anonymous class expression" {
    try expectAst("let C = class {};",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (binding "C" [4..5])
        \\      (class-expr [8..16]))))
    );
}

test "Parser: named class expression" {
    try expectAst("let C = class Named {};",
        \\(program script [0..23]
        \\  (lexical kind=let_ [0..23]
        \\    (declarator [4..22]
        \\      (binding "C" [4..5])
        \\      (class-expr "Named" [8..22]))))
    );
}

test "Parser: this expression" {
    try expectAst("this;",
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (this [0..4])))
    );
}

test "Parser: this.x = y in a class method" {
    try expectAst("class A { f() { this.x = 1; } }",
        \\(program script [0..31]
        \\  (class-decl "A" [0..31]
        \\    (method [10..29]
        \\      (key ident "f" [10..11])
        \\      (block [14..29]
        \\        (expr-stmt [16..27]
        \\          (assign op== [16..26]
        \\            (member [16..22]
        \\              (this [16..20])
        \\              (prop "x" [21..22]))
        \\            (numeric "1" [25..26])))))))
    );
}

test "Parser: top-level recovery doesn't infinite-loop on stray }" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // §14: a stray `}` at top level is malformed. The parser must report
    // and advance past it without spinning.
    _ = parseScript(arena.allocator(), "}\nlet x = 1;", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

// ── §14.3.3 Destructuring in declarators ────────────────────────────────

test "Parser: object pattern shorthand" {
    try expectAst("let { a } = obj;",
        \\(program script [0..16]
        \\  (lexical kind=let_ [0..16]
        \\    (declarator [4..15]
        \\      (object-pat [4..9]
        \\        (prop shorthand [6..7]
        \\          (key ident "a" [6..7])
        \\          (binding "a" [6..7])))
        \\      (ident "obj" [12..15]))))
    );
}

test "Parser: object pattern multi-prop with rename" {
    try expectAst("let { a, b: x } = obj;",
        \\(program script [0..22]
        \\  (lexical kind=let_ [0..22]
        \\    (declarator [4..21]
        \\      (object-pat [4..15]
        \\        (prop shorthand [6..7]
        \\          (key ident "a" [6..7])
        \\          (binding "a" [6..7]))
        \\        (prop [9..13]
        \\          (key ident "b" [9..10])
        \\          (binding "x" [12..13])))
        \\      (ident "obj" [18..21]))))
    );
}

test "Parser: object pattern shorthand with default" {
    try expectAst("let { a = 1 } = obj;",
        \\(program script [0..20]
        \\  (lexical kind=let_ [0..20]
        \\    (declarator [4..19]
        \\      (object-pat [4..13]
        \\        (prop shorthand [6..11]
        \\          (key ident "a" [6..7])
        \\          (default [6..11]
        \\            (binding "a" [6..7])
        \\            (numeric "1" [10..11]))))
        \\      (ident "obj" [16..19]))))
    );
}

test "Parser: object pattern with rename + default" {
    try expectAst("let { a: x = 1 } = obj;",
        \\(program script [0..23]
        \\  (lexical kind=let_ [0..23]
        \\    (declarator [4..22]
        \\      (object-pat [4..16]
        \\        (prop [6..14]
        \\          (key ident "a" [6..7])
        \\          (default [9..14]
        \\            (binding "x" [9..10])
        \\            (numeric "1" [13..14]))))
        \\      (ident "obj" [19..22]))))
    );
}

test "Parser: object pattern with rest" {
    try expectAst("let { a, ...rest } = obj;",
        \\(program script [0..25]
        \\  (lexical kind=let_ [0..25]
        \\    (declarator [4..24]
        \\      (object-pat [4..18]
        \\        (prop shorthand [6..7]
        \\          (key ident "a" [6..7])
        \\          (binding "a" [6..7]))
        \\        (rest "rest" [12..16]))
        \\      (ident "obj" [21..24]))))
    );
}

test "Parser: array pattern" {
    try expectAst("let [x, y] = arr;",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (array-pat [4..10]
        \\        (binding "x" [5..6])
        \\        (binding "y" [8..9]))
        \\      (ident "arr" [13..16]))))
    );
}

test "Parser: array pattern with default" {
    try expectAst("let [x = 1] = arr;",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (array-pat [4..11]
        \\        (default [5..10]
        \\          (binding "x" [5..6])
        \\          (numeric "1" [9..10])))
        \\      (ident "arr" [14..17]))))
    );
}

test "Parser: array pattern with elision" {
    try expectAst("let [, , x] = arr;",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (array-pat [4..11]
        \\        (elision)
        \\        (elision)
        \\        (binding "x" [9..10]))
        \\      (ident "arr" [14..17]))))
    );
}

test "Parser: array pattern with rest" {
    try expectAst("let [x, ...rest] = arr;",
        \\(program script [0..23]
        \\  (lexical kind=let_ [0..23]
        \\    (declarator [4..22]
        \\      (array-pat [4..16]
        \\        (binding "x" [5..6])
        \\        (rest
        \\          (binding "rest" [11..15])))
        \\      (ident "arr" [19..22]))))
    );
}

test "Parser: nested object inside array pattern" {
    try expectAst("let [{ a }] = xs;",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (array-pat [4..11]
        \\        (object-pat [5..10]
        \\          (prop shorthand [7..8]
        \\            (key ident "a" [7..8])
        \\            (binding "a" [7..8]))))
        \\      (ident "xs" [14..16]))))
    );
}

test "Parser: nested array inside object pattern" {
    try expectAst("let { a: [x, y] } = obj;",
        \\(program script [0..24]
        \\  (lexical kind=let_ [0..24]
        \\    (declarator [4..23]
        \\      (object-pat [4..17]
        \\        (prop [6..15]
        \\          (key ident "a" [6..7])
        \\          (array-pat [9..15]
        \\            (binding "x" [10..11])
        \\            (binding "y" [13..14]))))
        \\      (ident "obj" [20..23]))))
    );
}

test "Parser: catch with object destructuring" {
    try expectAst("try {} catch ({ message }) {}",
        \\(program script [0..29]
        \\  (try [0..29]
        \\    (block [4..6])
        \\    (catch [7..29]
        \\      (object-pat [14..25]
        \\        (prop shorthand [16..23]
        \\          (key ident "message" [16..23])
        \\          (binding "message" [16..23])))
        \\      (block [27..29]))))
    );
}

test "Parser: for-of with array destructuring" {
    try expectAst("for (let [k, v] of pairs) f(k, v);",
        \\(program script [0..34]
        \\  (for-of [0..34]
        \\    (lexical kind=let_ [5..15]
        \\      (declarator [9..15]
        \\        (array-pat [9..15]
        \\          (binding "k" [10..11])
        \\          (binding "v" [13..14]))))
        \\    (ident "pairs" [19..24])
        \\    (expr-stmt [26..34]
        \\      (call [26..33]
        \\        (ident "f" [26..27])
        \\        (ident "k" [28..29])
        \\        (ident "v" [31..32])))))
    );
}

test "Parser: const requires initializer for patterns too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "let { a };", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.const_without_initializer, diags.items[0].code);
}

// ── §15.1.5 Destructuring in function params ────────────────────────────

test "Parser: function with object pattern param" {
    try expectAst("function f({ a, b }) {}",
        \\(program script [0..23]
        \\  (function-decl "f" [0..23]
        \\    (param [11..19]
        \\      (object-pat [11..19]
        \\        (prop shorthand [13..14]
        \\          (key ident "a" [13..14])
        \\          (binding "a" [13..14]))
        \\        (prop shorthand [16..17]
        \\          (key ident "b" [16..17])
        \\          (binding "b" [16..17]))))
        \\    (block [21..23])))
    );
}

test "Parser: function with array pattern param" {
    try expectAst("function f([x, y]) {}",
        \\(program script [0..21]
        \\  (function-decl "f" [0..21]
        \\    (param [11..17]
        \\      (array-pat [11..17]
        \\        (binding "x" [12..13])
        \\        (binding "y" [15..16])))
        \\    (block [19..21])))
    );
}

test "Parser: function with pattern param + default" {
    try expectAst("function f({ a } = {}) {}",
        \\(program script [0..25]
        \\  (function-decl "f" [0..25]
        \\    (param [11..21]
        \\      (object-pat [11..16]
        \\        (prop shorthand [13..14]
        \\          (key ident "a" [13..14])
        \\          (binding "a" [13..14])))
        \\      (object [19..21]))
        \\    (block [23..25])))
    );
}

// ── §15.3 Destructuring in arrow params (cover-grammar reinterpretation) ─

test "Parser: arrow with object pattern param" {
    try expectAst("let f = ({ a }) => a;",
        \\(program script [0..21]
        \\  (lexical kind=let_ [0..21]
        \\    (declarator [4..20]
        \\      (binding "f" [4..5])
        \\      (arrow [8..20]
        \\        (param [9..14]
        \\          (object-pat [9..14]
        \\            (prop shorthand [11..12]
        \\              (key ident "a" [11..12])
        \\              (binding "a" [11..12]))))
        \\        (ident "a" [19..20])))))
    );
}

test "Parser: arrow with array pattern param" {
    try expectAst("let f = ([x, y]) => x + y;",
        \\(program script [0..26]
        \\  (lexical kind=let_ [0..26]
        \\    (declarator [4..25]
        \\      (binding "f" [4..5])
        \\      (arrow [8..25]
        \\        (param [9..15]
        \\          (array-pat [9..15]
        \\            (binding "x" [10..11])
        \\            (binding "y" [13..14])))
        \\        (binary op=+ [20..25]
        \\          (ident "x" [20..21])
        \\          (ident "y" [24..25]))))))
    );
}

test "Parser: arrow with multiple pattern params" {
    try expectAst("let f = ({ a }, [b]) => a + b;",
        \\(program script [0..30]
        \\  (lexical kind=let_ [0..30]
        \\    (declarator [4..29]
        \\      (binding "f" [4..5])
        \\      (arrow [8..29]
        \\        (param [9..14]
        \\          (object-pat [9..14]
        \\            (prop shorthand [11..12]
        \\              (key ident "a" [11..12])
        \\              (binding "a" [11..12]))))
        \\        (param [16..19]
        \\          (array-pat [16..19]
        \\            (binding "b" [17..18])))
        \\        (binary op=+ [24..29]
        \\          (ident "a" [24..25])
        \\          (ident "b" [28..29]))))))
    );
}

// ── §13.15.5 Destructuring assignment expressions ───────────────────────

test "Parser: array destructuring assignment" {
    try expectAst("[x, y] = arr;",
        \\(program script [0..13]
        \\  (expr-stmt [0..13]
        \\    (assign op== [0..12]
        \\      (array [0..6]
        \\        (ident "x" [1..2])
        \\        (ident "y" [4..5]))
        \\      (ident "arr" [9..12]))))
    );
}

test "Parser: object destructuring assignment in parens" {
    // §14.5: ExpressionStatement may not start with `{`, so the parens are
    // required at statement position.
    try expectAst("({ a, b } = obj);",
        \\(program script [0..17]
        \\  (expr-stmt [0..17]
        \\    (paren [0..16]
        \\      (assign op== [1..15]
        \\        (object [1..9]
        \\          (prop shorthand [3..4]
        \\            (key ident "a" [3..4]))
        \\          (prop shorthand [6..7]
        \\            (key ident "b" [6..7])))
        \\        (ident "obj" [12..15])))))
    );
}

test "Parser: array destructuring assignment with rest" {
    try expectAst("[a, ...rest] = arr;",
        \\(program script [0..19]
        \\  (expr-stmt [0..19]
        \\    (assign op== [0..18]
        \\      (array [0..12]
        \\        (ident "a" [1..2])
        \\        (spread [4..11]
        \\          (ident "rest" [7..11])))
        \\      (ident "arr" [15..18]))))
    );
}

test "Parser: literal assignment target with compound op is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // §13.15.3: compound assignments (`+=` etc.) require SimpleAssignmentTarget.
    // `[a] += 1` mixes destructuring with compound assignment — invalid.
    _ = parseScript(arena.allocator(), "[a] += 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.assignment_target_invalid, diags.items[0].code);
}

// ── §15.7 / §13.2.5 Getters, setters, static blocks, object methods ─────

test "Parser: class getter" {
    try expectAst("class A { get x() { return 1; } }",
        \\(program script [0..33]
        \\  (class-decl "A" [0..33]
        \\    (method getter [10..31]
        \\      (key ident "x" [14..15])
        \\      (block [18..31]
        \\        (return [20..29]
        \\          (numeric "1" [27..28]))))))
    );
}

test "Parser: class setter" {
    try expectAst("class A { set x(v) {} }",
        \\(program script [0..23]
        \\  (class-decl "A" [0..23]
        \\    (method setter [10..21]
        \\      (key ident "x" [14..15])
        \\      (param "v" [16..17])
        \\      (block [19..21]))))
    );
}

test "Parser: class static getter" {
    try expectAst("class A { static get x() {} }",
        \\(program script [0..29]
        \\  (class-decl "A" [0..29]
        \\    (method static getter [10..27]
        \\      (key ident "x" [21..22])
        \\      (block [25..27]))))
    );
}

test "Parser: class static block" {
    try expectAst("class A { static { count++; } }",
        \\(program script [0..31]
        \\  (class-decl "A" [0..31]
        \\    (static-block [10..29]
        \\      (expr-stmt [19..27]
        \\        (update op=++ postfix [19..26]
        \\          (ident "count" [19..24]))))))
    );
}

test "Parser: class with `get` as a method name" {
    // §15.7: `get(x)` is a method literally named "get", not an accessor,
    // because `(` follows immediately.
    try expectAst("class A { get(x) {} }",
        \\(program script [0..21]
        \\  (class-decl "A" [0..21]
        \\    (method [10..19]
        \\      (key ident "get" [10..13])
        \\      (param "x" [14..15])
        \\      (block [17..19]))))
    );
}

test "Parser: object method shorthand" {
    try expectAst("let o = { method(x) { return x; } };",
        \\(program script [0..36]
        \\  (lexical kind=let_ [0..36]
        \\    (declarator [4..35]
        \\      (binding "o" [4..5])
        \\      (object [8..35]
        \\        (method [10..33]
        \\          (key ident "method" [10..16])
        \\          (param "x" [17..18])
        \\          (block [20..33]
        \\            (return [22..31]
        \\              (ident "x" [29..30]))))))))
    );
}

test "Parser: object getter and setter" {
    try expectAst("let o = { get x() { return 1; }, set x(v) {} };",
        \\(program script [0..47]
        \\  (lexical kind=let_ [0..47]
        \\    (declarator [4..46]
        \\      (binding "o" [4..5])
        \\      (object [8..46]
        \\        (method getter [10..31]
        \\          (key ident "x" [14..15])
        \\          (block [18..31]
        \\            (return [20..29]
        \\              (numeric "1" [27..28]))))
        \\        (method setter [33..44]
        \\          (key ident "x" [37..38])
        \\          (param "v" [39..40])
        \\          (block [42..44]))))))
    );
}

// ── §15.5 Generators + yield ────────────────────────────────────────────

test "Parser: generator function declaration with yield" {
    try expectAst("function* gen() { yield 1; yield* other; }",
        \\(program script [0..42]
        \\  (function-decl * "gen" [0..42]
        \\    (block [16..42]
        \\      (expr-stmt [18..26]
        \\        (yield [18..25]
        \\          (numeric "1" [24..25])))
        \\      (expr-stmt [27..40]
        \\        (yield * [27..39]
        \\          (ident "other" [34..39]))))))
    );
}

test "Parser: yield with no operand" {
    try expectAst("function* gen() { yield; }",
        \\(program script [0..26]
        \\  (function-decl * "gen" [0..26]
        \\    (block [16..26]
        \\      (expr-stmt [18..24]
        \\        (yield [18..23])))))
    );
}

test "Parser: generator function expression" {
    try expectAst("let g = function*() { yield 1; };",
        \\(program script [0..33]
        \\  (lexical kind=let_ [0..33]
        \\    (declarator [4..32]
        \\      (binding "g" [4..5])
        \\      (function-expr * [8..32]
        \\        (block [20..32]
        \\          (expr-stmt [22..30]
        \\            (yield [22..29]
        \\              (numeric "1" [28..29]))))))))
    );
}

test "Parser: generator method in class" {
    try expectAst("class A { *foo() { yield 1; } }",
        \\(program script [0..31]
        \\  (class-decl "A" [0..31]
        \\    (method generator [10..29]
        \\      (key ident "foo" [11..14])
        \\      (block [17..29]
        \\        (expr-stmt [19..27]
        \\          (yield [19..26]
        \\            (numeric "1" [25..26])))))))
    );
}

test "Parser: static generator method in class" {
    try expectAst("class A { static *foo() {} }",
        \\(program script [0..28]
        \\  (class-decl "A" [0..28]
        \\    (method static generator [10..26]
        \\      (key ident "foo" [18..21])
        \\      (block [24..26]))))
    );
}

test "Parser: generator method in object literal" {
    try expectAst("let o = { *foo() { yield 1; } };",
        \\(program script [0..32]
        \\  (lexical kind=let_ [0..32]
        \\    (declarator [4..31]
        \\      (binding "o" [4..5])
        \\      (object [8..31]
        \\        (method generator [10..29]
        \\          (key ident "foo" [11..14])
        \\          (block [17..29]
        \\            (expr-stmt [19..27]
        \\              (yield [19..26]
        \\                (numeric "1" [25..26])))))))))
    );
}

test "Parser: yield outside generator is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // `yield` is a reserved word in strict mode (Cynic is strict-only).
    // Outside a generator, it cannot start a statement.
    _ = parseScript(arena.allocator(), "yield 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

test "Parser: nested generator preserves outer in_generator on exit" {
    // Outer is non-generator; inner generator uses yield; after inner
    // exits, outer should still reject yield. Verifies save/restore.
    try expectAst("function outer() { let g = function*() { yield 1; }; }",
        \\(program script [0..54]
        \\  (function-decl "outer" [0..54]
        \\    (block [17..54]
        \\      (lexical kind=let_ [19..52]
        \\        (declarator [23..51]
        \\          (binding "g" [23..24])
        \\          (function-expr * [27..51]
        \\            (block [39..51]
        \\              (expr-stmt [41..49]
        \\                (yield [41..48]
        \\                  (numeric "1" [47..48]))))))))))
    );
}

// ── §15.8 Async functions + await ───────────────────────────────────────

test "Parser: async function declaration with await" {
    try expectAst("async function fetch() { await network; }",
        \\(program script [0..41]
        \\  (function-decl async "fetch" [0..41]
        \\    (block [23..41]
        \\      (expr-stmt [25..39]
        \\        (await [25..38]
        \\          (ident "network" [31..38]))))))
    );
}

test "Parser: async function expression" {
    try expectAst("let f = async function() { await x; };",
        \\(program script [0..38]
        \\  (lexical kind=let_ [0..38]
        \\    (declarator [4..37]
        \\      (binding "f" [4..5])
        \\      (function-expr async [8..37]
        \\        (block [25..37]
        \\          (expr-stmt [27..35]
        \\            (await [27..34]
        \\              (ident "x" [33..34]))))))))
    );
}

test "Parser: new.target meta-property" {
    // §13.3.1 NewTarget — `new.target` is a MetaProperty, not a
    // NewExpression. Parser must recognise the `.` immediately after
    // `new` (with `target` as the property name) before falling back
    // to MemberExpression.
    try expectAst("function f() { return new.target; }",
        \\(program script [0..35]
        \\  (function-decl "f" [0..35]
        \\    (block [13..35]
        \\      (return [15..33]
        \\        (new-target [22..32])))))
    );
}

test "Parser: new MemberExpression still works" {
    // Make sure the meta-property path didn't break ordinary `new`.
    try expectAst("let x = new Foo();",
        \\(program script [0..18]
        \\  (lexical kind=let_ [0..18]
        \\    (declarator [4..17]
        \\      (binding "x" [4..5])
        \\      (new [8..17]
        \\        (ident "Foo" [12..15])))))
    );
}

test "Parser: async function expression with member access" {
    // §13.3 LeftHandSideExpression — `async function () {}.constructor`
    // is a function expression followed by a member access. This used
    // to false-reject because the `async function` path returned
    // directly from parseAssignment, bypassing parseLeftHandSide's
    // `.dot` loop.
    try expectAst("let A = async function foo() {}.constructor;",
        \\(program script [0..44]
        \\  (lexical kind=let_ [0..44]
        \\    (declarator [4..43]
        \\      (binding "A" [4..5])
        \\      (member [8..43]
        \\        (function-expr async "foo" [8..31]
        \\          (block [29..31]))
        \\        (prop "constructor" [32..43])))))
    );
}

test "Parser: async function expression invoked" {
    // Call applied to an async function expression. Same regression
    // class as the member-access test; the `.lparen` branch of
    // parseLeftHandSide must run after parsePrimary returns.
    // (Parenthesised so that `async function` is unambiguously in
    // expression position — at statement start it would be parsed as
    // an AsyncFunctionDeclaration.)
    try expectAst("let x = (async function() { return 1; })();",
        \\(program script [0..43]
        \\  (lexical kind=let_ [0..43]
        \\    (declarator [4..42]
        \\      (binding "x" [4..5])
        \\      (call [8..42]
        \\        (paren [8..40]
        \\          (function-expr async [9..39]
        \\            (block [26..39]
        \\              (return [28..37]
        \\                (numeric "1" [35..36])))))))))
    );
}

test "Parser: async generator function" {
    try expectAst("async function* gen() { yield await x; }",
        \\(program script [0..40]
        \\  (function-decl async * "gen" [0..40]
        \\    (block [22..40]
        \\      (expr-stmt [24..38]
        \\        (yield [24..37]
        \\          (await [30..37]
        \\            (ident "x" [36..37])))))))
    );
}

test "Parser: async arrow with bare ident" {
    try expectAst("let f = async x => await x;",
        \\(program script [0..27]
        \\  (lexical kind=let_ [0..27]
        \\    (declarator [4..26]
        \\      (binding "f" [4..5])
        \\      (arrow async [8..26]
        \\        (param "x" [14..15])
        \\        (await [19..26]
        \\          (ident "x" [25..26]))))))
    );
}

test "Parser: async arrow with parens" {
    try expectAst("let f = async (x, y) => x + y;",
        \\(program script [0..30]
        \\  (lexical kind=let_ [0..30]
        \\    (declarator [4..29]
        \\      (binding "f" [4..5])
        \\      (arrow async [8..29]
        \\        (param "x" [15..16])
        \\        (param "y" [18..19])
        \\        (binary op=+ [24..29]
        \\          (ident "x" [24..25])
        \\          (ident "y" [28..29]))))))
    );
}

test "Parser: async method in class" {
    try expectAst("class A { async run() { await this.work(); } }",
        \\(program script [0..46]
        \\  (class-decl "A" [0..46]
        \\    (method async [10..44]
        \\      (key ident "run" [16..19])
        \\      (block [22..44]
        \\        (expr-stmt [24..42]
        \\          (await [24..41]
        \\            (call [30..41]
        \\              (member [30..39]
        \\                (this [30..34])
        \\                (prop "work" [35..39])))))))))
    );
}

test "Parser: async method in object literal" {
    try expectAst("let o = { async run() { await x; } };",
        \\(program script [0..37]
        \\  (lexical kind=let_ [0..37]
        \\    (declarator [4..36]
        \\      (binding "o" [4..5])
        \\      (object [8..36]
        \\        (method async [10..34]
        \\          (key ident "run" [16..19])
        \\          (block [22..34]
        \\            (expr-stmt [24..32]
        \\              (await [24..31]
        \\                (ident "x" [30..31])))))))))
    );
}

test "Parser: await outside async is just unexpected_token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // `await` is a reserved word in strict mode (Cynic is strict-only).
    // Outside an async context, statements starting with `await` aren't
    // valid since it's not a unary operator we accept here.
    _ = parseScript(arena.allocator(), "await x;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

// ── §16.2 Modules ───────────────────────────────────────────────────────

fn expectModuleAst(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parseModule(arena.allocator(), source, null);
    const dumped = try ast.printer.dump(arena.allocator(), &program, source);
    try testing.expectEqualStrings(expected, dumped);
}

test "Parser: side-effect import" {
    try expectModuleAst("import \"./mod.js\";",
        \\(program module [0..18]
        \\  (import [0..18]
        \\    (source "./mod.js" [7..17])))
    );
}

test "Parser: default import" {
    try expectModuleAst("import name from \"x\";",
        \\(program module [0..21]
        \\  (import [0..21]
        \\    (source "x" [17..20])
        \\    (default "name" [7..11])))
    );
}

test "Parser: named imports with rename" {
    try expectModuleAst("import { a, b as c } from \"m\";",
        \\(program module [0..30]
        \\  (import [0..30]
        \\    (source "m" [26..29])
        \\    (named imported="a" local="a" [9..10])
        \\    (named imported="b" local="c" [12..18])))
    );
}

test "Parser: namespace import" {
    try expectModuleAst("import * as ns from \"m\";",
        \\(program module [0..24]
        \\  (import [0..24]
        \\    (source "m" [20..23])
        \\    (namespace "ns" [12..14])))
    );
}

test "Parser: default + named import" {
    try expectModuleAst("import name, { a } from \"m\";",
        \\(program module [0..28]
        \\  (import [0..28]
        \\    (source "m" [24..27])
        \\    (default "name" [7..11])
        \\    (named imported="a" local="a" [15..16])))
    );
}

test "Parser: export named with rename" {
    try expectModuleAst("export { a, b as c };",
        \\(program module [0..21]
        \\  (export [0..21]
        \\    (named
        \\      (spec local="a" exported="a" [9..10])
        \\      (spec local="b" exported="c" [12..18]))))
    );
}

test "Parser: export from re-export" {
    try expectModuleAst("export { a } from \"m\";",
        \\(program module [0..22]
        \\  (export [0..22]
        \\    (named source="m"
        \\      (spec local="a" exported="a" [9..10]))))
    );
}

test "Parser: export *" {
    try expectModuleAst("export * from \"m\";",
        \\(program module [0..18]
        \\  (export [0..18]
        \\    (all source="m")))
    );
}

test "Parser: export * as ns" {
    try expectModuleAst("export * as ns from \"m\";",
        \\(program module [0..24]
        \\  (export [0..24]
        \\    (all as="ns" source="m")))
    );
}

test "Parser: export default expression" {
    try expectModuleAst("export default 42;",
        \\(program module [0..18]
        \\  (export [0..18]
        \\    (default
        \\      (numeric "42" [15..17]))))
    );
}

test "Parser: export default function" {
    try expectModuleAst("export default function () {}",
        \\(program module [0..29]
        \\  (export [0..29]
        \\    (default
        \\      (function-expr [15..29]
        \\        (block [27..29])))))
    );
}

// §15.1.1: It is a Syntax Error if ContainsUseStrict of FunctionBody is
// true and IsSimpleParameterList of FormalParameters is false. The
// rule is repeated in §15.3 (arrow), §15.7 (method), §15.8 (async),
// §15.9 (generator) — same shape every time. Cynic is always strict,
// so a literal `"use strict"` directive is redundant; the rule still
// applies because `non-simple params + "use strict"` is forbidden by
// the grammar regardless of mode.

fn expectStrictBodyError(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), source, &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: object pattern param + 'use strict' body rejected" {
    try expectStrictBodyError("function f({a}) { \"use strict\"; }");
}

test "Parser: array pattern param + 'use strict' body rejected" {
    try expectStrictBodyError("function f([a]) { \"use strict\"; }");
}

test "Parser: rest param + 'use strict' body rejected" {
    try expectStrictBodyError("function f(...x) { \"use strict\"; }");
}

test "Parser: default param + 'use strict' body rejected" {
    try expectStrictBodyError("function f(x = 1) { \"use strict\"; }");
}

test "Parser: simple params + 'use strict' body still parses" {
    try expectAst("function f(x) { \"use strict\"; }",
        \\(program script [0..31]
        \\  (function-decl "f" [0..31]
        \\    (param "x" [11..12])
        \\    (block [14..31]
        \\      (expr-stmt directive="use strict" [16..29]
        \\        (string "use strict" [16..28])))))
    );
}

test "Parser: non-simple params without 'use strict' parses" {
    try expectAst("function f({a}) { return a; }",
        \\(program script [0..29]
        \\  (function-decl "f" [0..29]
        \\    (param [11..14]
        \\      (object-pat [11..14]
        \\        (prop shorthand [12..13]
        \\          (key ident "a" [12..13])
        \\          (binding "a" [12..13]))))
        \\    (block [16..29]
        \\      (return [18..27]
        \\        (ident "a" [25..26])))))
    );
}

test "Parser: arrow with object pattern + 'use strict' body rejected" {
    try expectStrictBodyError("let f = ({a}) => { \"use strict\"; };");
}

test "Parser: class method with object pattern + 'use strict' body rejected" {
    try expectStrictBodyError("class C { m({a}) { \"use strict\"; } }");
}

test "Parser: class generator method with object pattern + 'use strict' rejected" {
    try expectStrictBodyError("class C { *m({a}) { \"use strict\"; } }");
}

test "Parser: trailing comma after rest parameter rejected" {
    // §15.1 FormalParameters — the production `FormalParameterList,
    // FunctionRestParameter` does NOT allow a trailing comma after
    // the rest. `function(...a,) {}` is a SyntaxError.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "function f(...a,) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: rest parameter with no trailing comma still works" {
    try expectAst("function f(a, ...rest) {}",
        \\(program script [0..25]
        \\  (function-decl "f" [0..25]
        \\    (param "a" [11..12])
        \\    (rest "rest" [14..21])
        \\    (block [23..25])))
    );
}

test "Parser: duplicate simple parameter names rejected (strict)" {
    // §15.1 / §11.10: in strict mode (Cynic is always strict),
    // FormalParameterList must not contain duplicate BoundNames.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "function f(x, x) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: duplicate parameter names with default rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "function f(x = 0, x) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: duplicate name across rest still rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "function f(x, ...x) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: distinct parameter names parse cleanly" {
    try expectAst("function f(a, b, c) {}",
        \\(program script [0..22]
        \\  (function-decl "f" [0..22]
        \\    (param "a" [11..12])
        \\    (param "b" [14..15])
        \\    (param "c" [17..18])
        \\    (block [20..22])))
    );
}

test "Parser: escaped reserved word as method name is accepted" {
    // §12.7.1: an IdentifierName containing `\u` escapes whose
    // StringValue is a ReservedWord (e.g. "let") is rejected ONLY in
    // Identifier (BindingIdentifier / IdentifierReference) positions.
    // PropertyName is an IdentifierName, so a method named via the
    // escape form is fine. The printer keeps the raw source slice;
    // runtime cooking maps it to the StringValue "let".
    try expectAst("class C { l\\u0065t() {} }",
        \\(program script [0..25]
        \\  (class-decl "C" [0..25]
        \\    (method [10..23]
        \\      (key ident "l\u0065t" [10..18])
        \\      (block [21..23]))))
    );
}

test "Parser: escaped reserved word as member-access name is accepted" {
    try expectAst("obj.l\\u0065t;",
        \\(program script [0..13]
        \\  (expr-stmt [0..13]
        \\    (member [0..12]
        \\      (ident "obj" [0..3])
        \\      (prop "l\u0065t" [4..12]))))
    );
}

test "Parser: escaped reserved word as binding identifier rejected" {
    // `var let = 1;` — `let` via escapes used as a
    // BindingIdentifier is an early SyntaxError per §12.7.1.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "var l\\u0065t = 1;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.escape_in_reserved_word, diags.items[0].code);
}

test "Parser: escaped reserved word as identifier reference rejected" {
    // `if;` — `if` via escapes used as an IdentifierReference.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "i\\u0066;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.escape_in_reserved_word, diags.items[0].code);
}

test "Parser: for-await-of inside async function" {
    // §14.7.5 ES2018 async iteration — `for await (x of iter) {}`
    // legal in any [+Await] context.
    try expectAst("async function f() { for await (const x of obj) {} }",
        \\(program script [0..52]
        \\  (function-decl async "f" [0..52]
        \\    (block [19..52]
        \\      (for-await-of [21..50]
        \\        (lexical kind=const_ [32..39]
        \\          (declarator [38..39]
        \\            (binding "x" [38..39])))
        \\        (ident "obj" [43..46])
        \\        (block [48..50])))))
    );
}

test "Parser: for-await-of at module top-level" {
    // ES2022 top-level await context — `for await` is also legal at
    // the module's top-level statement list.
    try expectModuleAst("for await (const x of obj) {}",
        \\(program module [0..29]
        \\  (for-await-of [0..29]
        \\    (lexical kind=const_ [11..18]
        \\      (declarator [17..18]
        \\        (binding "x" [17..18])))
        \\    (ident "obj" [22..25])
        \\    (block [27..29])))
    );
}

test "Parser: for-await in non-async function rejected" {
    // Without [+Await] (non-async function in script), `for await`
    // must not parse.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "function f() { for await (const x of obj) {} }", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: for-await-of with for-in is rejected" {
    // `for await (… in …)` is not a valid production — only `of`.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseModule(arena.allocator(), "for await (const x in obj) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: top-level await in module" {
    // §16.2.2 ModuleItem: StatementListItem[~Yield, +Await, ~Return].
    // ES2022 top-level await — `await expr` is valid at the module's
    // top-level statement list. Inside a Module, `in_async` must be
    // true at the top-level scope.
    try expectModuleAst("await x;",
        \\(program module [0..8]
        \\  (expr-stmt [0..8]
        \\    (await [0..7]
        \\      (ident "x" [6..7]))))
    );
}

test "Parser: top-level await before regex" {
    // The regex-vs-division dispatch must follow the AwaitExpression's
    // operand position correctly: `await /x/g;` is `await(/x/g)`.
    try expectModuleAst("await /x/g;",
        \\(program module [0..11]
        \\  (expr-stmt [0..11]
        \\    (await [0..10]
        \\      (regex /x/g [6..10]))))
    );
}

test "Parser: await inside non-async function in module is rejected" {
    // Setting `in_async = true` at module top must NOT leak into
    // a non-async function body — the function's own asyncness wins.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseModule(arena.allocator(), "function f() { await x; }", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: top-level await still rejected in scripts" {
    // Scripts have [~Await] at the top — `await x;` at script-top is
    // a parse error (or `await` is treated as an identifier and the
    // following expression mis-parses).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "await x;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: export default class without trailing semicolon" {
    // §16.2.3.1 `ExportDeclaration : export default ClassDeclaration` —
    // no terminating `;`. The class body's closing `}` ends the
    // declaration; the next token may immediately begin another item.
    try expectModuleAst("export default class {} if (true) {}",
        \\(program module [0..36]
        \\  (export [0..23]
        \\    (default
        \\      (class-expr [15..23])))
        \\  (if [24..36]
        \\    (bool true [28..32])
        \\    (block [34..36])))
    );
}

test "Parser: export default function without trailing semicolon" {
    // §16.2.3.1 `ExportDeclaration : export default HoistableDeclaration` —
    // no terminating `;` for the function form.
    try expectModuleAst("export default function () {} let x = 1;",
        \\(program module [0..40]
        \\  (export [0..29]
        \\    (default
        \\      (function-expr [15..29]
        \\        (block [27..29]))))
        \\  (lexical kind=let_ [30..40]
        \\    (declarator [34..39]
        \\      (binding "x" [34..35])
        \\      (numeric "1" [38..39]))))
    );
}

test "Parser: export default expression still requires semicolon" {
    // The `AssignmentExpression`-form export DOES need a semicolon
    // (or ASI). `export default 42` followed by a statement on the
    // same line without `;` is a parse error.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseModule(arena.allocator(), "export default 42 if (true) {}", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: export declaration (let)" {
    try expectModuleAst("export let x = 1;",
        \\(program module [0..17]
        \\  (export [0..17]
        \\    (lexical kind=let_ [7..17]
        \\      (declarator [11..16]
        \\        (binding "x" [11..12])
        \\        (numeric "1" [15..16])))))
    );
}

test "Parser: import outside module is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "import x from \"m\";", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

// §16.2.2 Module — `ImportDeclaration` and `ExportDeclaration` are
// `ModuleItem`s, not `StatementListItem`s. They appear ONLY at the
// module's top-level item list and never nested in any block, body,
// case clause, or function body. The tests below pin that.

fn expectModuleParseError(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseModule(arena.allocator(), source, &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

test "Parser: export inside if-body is rejected" {
    try expectModuleParseError("if (true) export default null;");
}

test "Parser: export inside while-body is rejected" {
    try expectModuleParseError("while (false) export default null;");
}

test "Parser: export inside block is rejected" {
    try expectModuleParseError("{ export default null; }");
}

test "Parser: export inside function body is rejected" {
    try expectModuleParseError("function f() { export default null; }");
}

test "Parser: export inside try block is rejected" {
    try expectModuleParseError("try { export default null; } catch (e) {}");
}

test "Parser: export inside catch block is rejected" {
    try expectModuleParseError("try {} catch (e) { export default null; }");
}

test "Parser: export inside switch case is rejected" {
    try expectModuleParseError("switch (0) { case 1: export default null; }");
}

test "Parser: import inside block is rejected" {
    try expectModuleParseError("{ import \"x\"; }");
}

test "Parser: import inside if-body is rejected" {
    try expectModuleParseError("if (true) import \"x\";");
}

// ── §12.9.5 Regex literals ──────────────────────────────────────────────

test "Parser: simple regex literal" {
    try expectAst("let r = /abc/;",
        \\(program script [0..14]
        \\  (lexical kind=let_ [0..14]
        \\    (declarator [4..13]
        \\      (binding "r" [4..5])
        \\      (regex /abc/ [8..13]))))
    );
}

test "Parser: regex with flags" {
    try expectAst("let r = /abc/gim;",
        \\(program script [0..17]
        \\  (lexical kind=let_ [0..17]
        \\    (declarator [4..16]
        \\      (binding "r" [4..5])
        \\      (regex /abc/gim [8..16]))))
    );
}

test "Parser: regex with character class containing /" {
    try expectAst("let r = /[/]/;",
        \\(program script [0..14]
        \\  (lexical kind=let_ [0..14]
        \\    (declarator [4..13]
        \\      (binding "r" [4..5])
        \\      (regex /[/]/ [8..13]))))
    );
}

test "Parser: regex with escaped slash" {
    try expectAst("let r = /\\//;",
        \\(program script [0..13]
        \\  (lexical kind=let_ [0..13]
        \\    (declarator [4..12]
        \\      (binding "r" [4..5])
        \\      (regex /\// [8..12]))))
    );
}

test "Parser: division still works in operator position" {
    // After an expression, `/` is division — NOT a regex.
    try expectAst("let q = a / b;",
        \\(program script [0..14]
        \\  (lexical kind=let_ [0..14]
        \\    (declarator [4..13]
        \\      (binding "q" [4..5])
        \\      (binary op=/ [8..13]
        \\        (ident "a" [8..9])
        \\        (ident "b" [12..13])))))
    );
}

test "Parser: regex with /= initial char" {
    // `/=` in expression-start position is the start of a regex like /=foo/.
    try expectAst("let r = /=abc/;",
        \\(program script [0..15]
        \\  (lexical kind=let_ [0..15]
        \\    (declarator [4..14]
        \\      (binding "r" [4..5])
        \\      (regex /=abc/ [8..14]))))
    );
}

// ── §14.3.2 VariableStatement (`var`) ───────────────────────────────────

test "Parser: var with single binding" {
    try expectAst("var x = 1;",
        \\(program script [0..10]
        \\  (lexical kind=var_ [0..10]
        \\    (declarator [4..9]
        \\      (binding "x" [4..5])
        \\      (numeric "1" [8..9]))))
    );
}

test "Parser: var without initializer" {
    try expectAst("var x;",
        \\(program script [0..6]
        \\  (lexical kind=var_ [0..6]
        \\    (declarator [4..5]
        \\      (binding "x" [4..5]))))
    );
}

test "Parser: var with multiple declarators" {
    try expectAst("var a = 1, b, c = 3;",
        \\(program script [0..20]
        \\  (lexical kind=var_ [0..20]
        \\    (declarator [4..9]
        \\      (binding "a" [4..5])
        \\      (numeric "1" [8..9]))
        \\    (declarator [11..12]
        \\      (binding "b" [11..12]))
        \\    (declarator [14..19]
        \\      (binding "c" [14..15])
        \\      (numeric "3" [18..19]))))
    );
}

test "Parser: var with destructuring pattern" {
    try expectAst("var [a, b] = arr;",
        \\(program script [0..17]
        \\  (lexical kind=var_ [0..17]
        \\    (declarator [4..16]
        \\      (array-pat [4..10]
        \\        (binding "a" [5..6])
        \\        (binding "b" [8..9]))
        \\      (ident "arr" [13..16]))))
    );
}

test "Parser: var pattern still requires initializer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "var [a];", &diags) catch unreachable;
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.const_without_initializer, diags.items[0].code);
}

test "Parser: var in C-style for" {
    try expectAst("for (var i = 0; i < n; i++) {}",
        \\(program script [0..30]
        \\  (for [0..30]
        \\    (init
        \\      (lexical kind=var_ [5..14]
        \\        (declarator [9..14]
        \\          (binding "i" [9..10])
        \\          (numeric "0" [13..14]))))
        \\    (test
        \\      (binary op=< [16..21]
        \\        (ident "i" [16..17])
        \\        (ident "n" [20..21])))
        \\    (update
        \\      (update op=++ postfix [23..26]
        \\        (ident "i" [23..24])))
        \\    (block [28..30])))
    );
}

test "Parser: var in for-in" {
    try expectAst("for (var k in obj) body;",
        \\(program script [0..24]
        \\  (for-in [0..24]
        \\    (lexical kind=var_ [5..10]
        \\      (declarator [9..10]
        \\        (binding "k" [9..10])))
        \\    (ident "obj" [14..17])
        \\    (expr-stmt [19..24]
        \\      (ident "body" [19..23]))))
    );
}

test "Parser: var in for-of" {
    try expectAst("for (var x of arr) body;",
        \\(program script [0..24]
        \\  (for-of [0..24]
        \\    (lexical kind=var_ [5..10]
        \\      (declarator [9..10]
        \\        (binding "x" [9..10])))
        \\    (ident "arr" [14..17])
        \\    (expr-stmt [19..24]
        \\      (ident "body" [19..23]))))
    );
}

// ── §13.3.10 / §13.3.12.1 Dynamic import + import.meta ──────────────────

test "Parser: dynamic import in declaration" {
    try expectAst("let mod = import(\"./foo.js\");",
        \\(program script [0..29]
        \\  (lexical kind=let_ [0..29]
        \\    (declarator [4..28]
        \\      (binding "mod" [4..7])
        \\      (import-call [10..28]
        \\        (string "./foo.js" [17..27])))))
    );
}

test "Parser: dynamic import as expression statement" {
    try expectAst("import(\"./foo\").then(handle);",
        \\(program script [0..29]
        \\  (expr-stmt [0..29]
        \\    (call [0..28]
        \\      (member [0..20]
        \\        (import-call [0..15]
        \\          (string "./foo" [7..14]))
        \\        (prop "then" [16..20]))
        \\      (ident "handle" [21..27]))))
    );
}

test "Parser: dynamic import with trailing comma" {
    try expectAst("import(\"x\",);",
        \\(program script [0..13]
        \\  (expr-stmt [0..13]
        \\    (import-call [0..12]
        \\      (string "x" [7..10]))))
    );
}

test "Parser: import.meta in module" {
    try expectModuleAst("let url = import.meta.url;",
        \\(program module [0..26]
        \\  (lexical kind=let_ [0..26]
        \\    (declarator [4..25]
        \\      (binding "url" [4..7])
        \\      (member [10..25]
        \\        (import-meta [10..21])
        \\        (prop "url" [22..25])))))
    );
}

test "Parser: bare `import` followed by garbage is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    // `import x` (no `(` and no `.meta`) at expression position is invalid.
    _ = parseScript(arena.allocator(), "let x = import x;", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
}

// ── §11.10 / §16.1.1 Directive Prologue ─────────────────────────────────

test "Parser: use strict directive at script top level" {
    try expectAst("\"use strict\"; let x = 1;",
        \\(program script [0..24]
        \\  (expr-stmt directive="use strict" [0..13]
        \\    (string "use strict" [0..12]))
        \\  (lexical kind=let_ [14..24]
        \\    (declarator [18..23]
        \\      (binding "x" [18..19])
        \\      (numeric "1" [22..23]))))
    );
}

test "Parser: directive prologue ends at first non-string-literal" {
    try expectAst("\"a\"; \"b\"; foo(); \"c\";",
        \\(program script [0..21]
        \\  (expr-stmt directive="a" [0..4]
        \\    (string "a" [0..3]))
        \\  (expr-stmt directive="b" [5..9]
        \\    (string "b" [5..8]))
        \\  (expr-stmt [10..16]
        \\    (call [10..15]
        \\      (ident "foo" [10..13])))
        \\  (expr-stmt [17..21]
        \\    (string "c" [17..20])))
    );
}

test "Parser: directive in function body" {
    try expectAst("function f() { \"use strict\"; return 1; }",
        \\(program script [0..40]
        \\  (function-decl "f" [0..40]
        \\    (block [13..40]
        \\      (expr-stmt directive="use strict" [15..28]
        \\        (string "use strict" [15..27]))
        \\      (return [29..38]
        \\        (numeric "1" [36..37])))))
    );
}

test "Parser: nested string after non-string is not a directive" {
    try expectAst("function f() { let x = 1; \"not-a-directive\"; }",
        \\(program script [0..46]
        \\  (function-decl "f" [0..46]
        \\    (block [13..46]
        \\      (lexical kind=let_ [15..25]
        \\        (declarator [19..24]
        \\          (binding "x" [19..20])
        \\          (numeric "1" [23..24])))
        \\      (expr-stmt [26..44]
        \\        (string "not-a-directive" [26..43])))))
    );
}

test "Parser: missing semicolon (no LF) emits unexpected_token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    defer diags.deinit(arena.allocator());
    _ = parseScript(arena.allocator(), "a b", &diags) catch {};
    try testing.expect(diags.items.len >= 1);
    try testing.expectEqual(Code.unexpected_token, diags.items[0].code);
}

// ── Native-stack guard (deeply nested source) ───────────────────────
//
// The recursive-descent parser is bounded by the shared
// `stack_guard.nearLimit` check at `parseUnary` (expressions) and
// `parseStatement` (statements). Deeply nested source that would
// have overflowed the host stack and crashed the process now
// reports a `too_deeply_nested` diagnostic (RangeError-class) and
// returns `error.ParseError`. These build the nested source
// programmatically and assert no crash + the right diagnostic; a
// moderate-depth control confirms the guard does not false-trip.

fn repeatAlloc(a: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const buf = try a.alloc(u8, unit.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * unit.len ..][0..unit.len], unit);
    return buf;
}

fn expectTooDeeplyNested(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    // Must not crash; must surface the depth-limit diagnostic.
    _ = parseScript(arena.allocator(), source, &diags) catch {};
    var saw = false;
    for (diags.items) |d| {
        if (d.code == .too_deeply_nested) saw = true;
    }
    try testing.expect(saw);
    // §spec — the depth limit is a resource error, not a grammar
    // violation: it maps to RangeError (matching V8 / JSC).
    try testing.expectEqual(cynic_diag.ErrorClass.range_error, Code.too_deeply_nested.errorClass());
}

test "Parser: deeply nested array literal hits the stack guard" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const open = try repeatAlloc(arena.allocator(), "[", depth);
    const close = try repeatAlloc(arena.allocator(), "]", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ open, close, ";" });
    try expectTooDeeplyNested(src);
}

test "Parser: deeply nested parentheses hit the stack guard" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const open = try repeatAlloc(arena.allocator(), "(", depth);
    const close = try repeatAlloc(arena.allocator(), ")", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ open, "1", close, ";" });
    try expectTooDeeplyNested(src);
}

test "Parser: deeply nested blocks hit the stack guard" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const open = try repeatAlloc(arena.allocator(), "{", depth);
    const close = try repeatAlloc(arena.allocator(), "}", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ open, close });
    try expectTooDeeplyNested(src);
}

test "Parser: long prefix-operator chain hits the stack guard" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const ops = try repeatAlloc(arena.allocator(), "!", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ops, "true;" });
    try expectTooDeeplyNested(src);
}

test "Parser: moderate nesting parses without false-tripping the guard" {
    // 500 levels is deep for real source yet far within the native
    // stack budget — must parse cleanly with no diagnostic.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 500;
    const open = try repeatAlloc(arena.allocator(), "[", depth);
    const close = try repeatAlloc(arena.allocator(), "]", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ open, close, ";" });
    var diags: Diagnostics = .empty;
    _ = try parseScript(arena.allocator(), src, &diags);
    try testing.expect(!hasErr(diags.items));
}

test "Parser: deeply nested arrow chain hits the stack guard" {
    // `() => () => … => 1` — arrows recurse through `parseAssignment`
    // (each concise body re-enters it) without descending to
    // `parseUnary`, so the AssignmentExpression-entry guard catches
    // them.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const arrows = try repeatAlloc(arena.allocator(), "()=>", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ arrows, "1;" });
    try expectTooDeeplyNested(src);
}

test "Parser: deeply nested destructuring pattern hits the stack guard" {
    // `var [[[[x]]]] = 0` — binding patterns parse through their own
    // recursion (`parseBindingTarget` → `parseArrayPattern` →
    // `parseBindingElement` → `parseBindingTarget`), separate from the
    // expression choke points, so they need their own guard.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 200_000;
    const open = try repeatAlloc(arena.allocator(), "[", depth);
    const close = try repeatAlloc(arena.allocator(), "]", depth);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ "var ", open, "x", close, "=0;" });
    try expectTooDeeplyNested(src);
}

test "Parser: moderate arrow + destructuring nesting parses cleanly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .empty;
    const arrows = try repeatAlloc(arena.allocator(), "()=>", 300);
    const src = try std.mem.concat(arena.allocator(), u8, &.{ arrows, "1;" });
    _ = try parseScript(arena.allocator(), src, &diags);
    try testing.expect(!hasErr(diags.items));
}
