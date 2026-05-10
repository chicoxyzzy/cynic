//! Recursive-descent parser for Cynic. Mirrors ECMA-262 production names:
//! `parseScript`, `parseStatement`, `parseExpression`, etc.
//!
//! State and lifetime model (per ARCHITECTURE.md "single allocator threading"):
//! • The parser takes a `std.mem.Allocator` (typically a per-parse arena)
//! and uses it for *every* AST allocation, list growth, scratch.
//! • It owns a `Lexer` and pulls tokens lazily, with a single-token
//! `lookahead` buffer.
//! • Diagnostics are accumulated through a caller-provided `*Diagnostics`
//! sink, identical to the lexer's pattern.
//!
//! Recovery strategy:
//! • Lex errors are converted to `error.ParseError` after the lexer has
//! already reported a diagnostic. The parser keeps going.
//! • Statement-level errors `synchronize()` to the next likely boundary
//! (`;`, `}`, EOF, or a token at the start of a new line that can begin
//! a Statement).
//! • Expression-level errors propagate to the enclosing statement and let
//! `synchronize()` handle the skip. Test262 expects roughly one
//! diagnostic per malformed statement.

const std = @import("std");

const lexer_mod = @import("../lexer/lexer.zig");
const Lexer = lexer_mod.Lexer;
const LexError = lexer_mod.LexError;

const token_mod = @import("../lexer/token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

const ast = @import("../ast.zig");
const Expression = ast.Expression;
const Statement = ast.Statement;
const Program = ast.Program;
const stmt_mod = @import("../ast/statement.zig");

const expr_mod = @import("expression.zig");
const pattern_validate = @import("pattern_validate.zig");

pub const ParseError = error{
    ParseError,
    OutOfMemory,
};

pub const Parser = struct {
    /// Arena-style allocator for all AST allocations.
    arena: std.mem.Allocator,
    /// Source text. Borrowed; lifetime is the caller's responsibility.
    source: []const u8,
    lexer: Lexer,
    /// `current` is the next token to inspect. `bump()` consumes it and
    /// advances. `lookahead` caches the token after `current` once `peek2`
    /// has been called.
    current: Token,
    lookahead: ?Token = null,
    diagnostics: ?*Diagnostics,
    /// §13.10 [+In] / [-In] grammar parameter. Always `true` in this slice;
    /// `for (let in …)` and friends will flip it off when added.
    allow_in: bool = true,
    /// §15.5 — true when parsing inside a generator function body.
    /// Enables `yield` as a YieldExpression keyword. Saved and restored
    /// at function boundaries; arrow bodies do NOT inherit (per §15.3
    /// arrows force `[~Yield]`).
    in_generator: bool = false,
    /// §15.8 — true when parsing inside an async function body. Enables
    /// `await` as an AwaitExpression keyword. Inherits the same boundary
    /// rules as `in_generator`.
    in_async: bool = false,
    /// §16.2 — true when parsing a Module (vs a Script). Allows
    /// `ImportDeclaration` and `ExportDeclaration` at top level.
    is_module: bool = false,
    /// True when parsing inside a Function / Method / Constructor
    /// body (any of the four function flavours: regular, generator,
    /// async, async-generator) or an arrow body. Drives the
    /// §14.10.1 `return` early error (`return` at top-level Script
    /// or Module body is a SyntaxError). Saved/restored at the
    /// same boundaries as `in_async` / `in_generator`.
    in_function: bool = false,
    /// True when parsing inside a method / class body. Drives the
    /// §13.3.7 `super.x` and `super()` early errors — those are
    /// only allowed in MethodDefinitions (regular methods see
    /// `super.x`; constructors of derived classes see `super()`
    /// too). Top-level / plain-function references to `super` are
    /// SyntaxErrors. Cynic uses one flag for both forms today; a
    /// finer split (`allow_super_call` vs `allow_super_property`)
    /// is later.
    in_method: bool = false,

    pub fn init(arena: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics) ParseError!Parser {
        return Parser.initWith(arena, source, diagnostics, false);
    }

    pub fn initWith(arena: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics, is_module: bool) ParseError!Parser {
        var lex = Lexer.init(arena, source);
        if (diagnostics) |d| lex.diagnostics = d;
        const first = lex.next() catch |err| return mapLexError(err);
        return .{
            .arena = arena,
            .source = source,
            .lexer = lex,
            .current = first,
            .diagnostics = diagnostics,
            .is_module = is_module,
        };
    }

    // ── Token-stream helpers ────────────────────────────────────────────

    pub fn peek(self: *const Parser) Token {
        return self.current;
    }

    pub fn peek2(self: *Parser) ParseError!Token {
        if (self.lookahead) |t| return t;
        const t = self.lexer.next() catch |err| return mapLexError(err);
        self.lookahead = t;
        return t;
    }

    /// Advance past `current` and return it. Pulls the next token (possibly
    /// from the lookahead buffer).
    pub fn bump(self: *Parser) ParseError!Token {
        const consumed = self.current;
        if (self.lookahead) |t| {
            self.current = t;
            self.lookahead = null;
        } else {
            self.current = self.lexer.next() catch |err| return mapLexError(err);
        }
        return consumed;
    }

    pub fn eat(self: *Parser, kind: TokenKind) ParseError!bool {
        if (self.current.kind != kind) return false;
        _ = try self.bump();
        return true;
    }

    pub fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.current.kind == kind) return try self.bump();
        try self.report(.unexpected_token, self.current.span);
        return error.ParseError;
    }

    pub fn report(self: *Parser, code: Code, span: Span) ParseError!void {
        if (self.diagnostics) |list| {
            try list.append(self.arena, .{
                .severity = .err,
                .code = code,
                .span = span,
            });
        }
    }

    // ── Entry points ────────────────────────────────────────────────────

    /// §16.1 ParseScript.
    pub fn parseScript(self: *Parser) ParseError!Program {
        return self.parseProgramBody(.script);
    }

    /// §16.2 ParseModule. Same statement-list shape as ParseScript but
    /// permits `ImportDeclaration` and `ExportDeclaration` at top level
    /// and runs the body with `[+Await]` (ES2022 top-level await,
    /// §16.2.2 — `ModuleItem : StatementListItem[~Yield, +Await, ~Return]`).
    /// Function and arrow bodies override `in_async` with their own
    /// asyncness on entry, so this flag does not leak into nested
    /// non-async function bodies.
    pub fn parseModule(self: *Parser) ParseError!Program {
        self.is_module = true;
        self.in_async = true;
        return self.parseProgramBody(.module);
    }

    fn parseProgramBody(self: *Parser, source_kind: ast.program.Program.SourceKind) ParseError!Program {
        const start = self.current.span.start;
        var body: std.ArrayListUnmanaged(Statement) = .empty;
        errdefer body.deinit(self.arena);

        var in_prologue = true;
        while (self.current.kind != .eof) {
            const before = self.current.span.start;
            // §16.2.2: `ModuleItem ::= ImportDeclaration | ExportDeclaration |
            // StatementListItem`. Only the top-level loop dispatches to
            // parseModuleItem; nested statement contexts call parseStatement
            // directly, which rejects `import` / `export` declarations
            // (their `(` / `.` expression forms still parse anywhere).
            var stmt = (if (source_kind == .module)
                self.parseModuleItem()
            else
                self.parseStatement()) catch |err| switch (err) {
                error.ParseError => {
                    self.synchronize();
                    // §14: at the top level there is no enclosing block,
                    // so if `synchronize` saw a stray `}` it returns
                    // without advancing. Force one bump to keep the loop
                    // from spinning on garbage like `}`/`)` / `]`.
                    if (self.current.span.start == before and self.current.kind != .eof) {
                        _ = self.bump() catch break;
                    }
                    in_prologue = false;
                    continue;
                },
                else => return err,
            };
            if (in_prologue) {
                if (markIfDirective(&stmt)) |_| {} else in_prologue = false;
            }
            try body.append(self.arena, stmt);
        }
        const end: u32 = self.current.span.end;
        const program: Program = .{
            .span = .{ .start = start, .end = end },
            .source_kind = source_kind,
            .body = try body.toOwnedSlice(self.arena),
        };
        // Post-parse early-error pass for AssignmentPattern shapes the
        // expression-cover reinterpretation only checks at the top level
        // (§13.15.5 nested-target / RestElement-position rules).
        var validator: pattern_validate.Validator = .{
            .arena = self.arena,
            .diagnostics = self.diagnostics,
        };
        try validator.run(&program);
        return program;
    }

    /// §16.2.2 ModuleItem — top-level only. Recognises ImportDeclaration
    /// and ExportDeclaration; otherwise delegates to parseStatement so
    /// the StatementListItem branch covers everything else (declarations,
    /// statements). Called only from parseProgramBody when source_kind
    /// is module — never from nested-statement contexts.
    fn parseModuleItem(self: *Parser) ParseError!Statement {
        switch (self.current.kind) {
            .kw_import => {
                // `import(` / `import.meta` are still expressions.
                const second = try self.peek2();
                if (second.kind == .lparen or second.kind == .dot) {
                    return self.parseExpressionStatement();
                }
                return self.parseImportDeclaration();
            },
            .kw_export => return self.parseExportDeclaration(),
            else => return self.parseStatement(),
        }
    }


    // ── Statements (§14) ────────────────────────────────────────────────

    fn parseStatement(self: *Parser) ParseError!Statement {
        const kind = self.current.kind;
        switch (kind) {
            .semicolon => return self.parseEmptyStatement(),
            .lbrace => return self.parseBlockStatement(),
            .kw_let => return self.parseLexicalDeclaration(.let_),
            .kw_const => return self.parseLexicalDeclaration(.const_),
            .kw_var => return self.parseLexicalDeclaration(.var_),
            .kw_if => return self.parseIfStatement(),
            .kw_while => return self.parseWhileStatement(),
            .kw_do => return self.parseDoWhileStatement(),
            .kw_return => return self.parseReturnStatement(),
            .kw_throw => return self.parseThrowStatement(),
            .kw_break => return self.parseBreakOrContinueStatement(true),
            .kw_continue => return self.parseBreakOrContinueStatement(false),
            .kw_for => return self.parseForStatement(),
            .kw_try => return self.parseTryStatement(),
            .kw_switch => return self.parseSwitchStatement(),
            .kw_debugger => return self.parseDebuggerStatement(),
            .kw_function => return self.parseFunctionDeclaration(),
            .kw_class => return self.parseClassDeclaration(),
            .kw_import => {
                // §13.3.10 / §13.3.12.1: `import(` / `import.meta` are
                // expressions and are valid in both scripts and modules,
                // including any nested context. The bare ImportDeclaration
                // form (`import x from "m";`) is a ModuleItem (§16.2.2)
                // and is rejected here at every nested level — and in
                // scripts. parseModuleItem handles the top-level Module
                // case before falling through to this dispatch.
                const second = try self.peek2();
                if (second.kind == .lparen or second.kind == .dot) {
                    return self.parseExpressionStatement();
                }
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            },
            .kw_export => {
                // §16.2.3 ExportDeclaration is a ModuleItem; never a
                // StatementListItem. Always rejected from parseStatement;
                // parseModuleItem accepts it only at the module's
                // top-level item list.
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            },
            else => {
                // §15.8 AsyncFunctionDeclaration: `async [no LF] function`
                // at statement start.
                if (kind == .identifier and std.mem.eql(u8, self.current.slice(self.source), "async")) {
                    const second = try self.peek2();
                    if (second.kind == .kw_function and !second.line_terminator_before) {
                        const start = self.current.span.start;
                        _ = try self.bump(); // `async`
                        return self.parseFunctionDeclarationAt(start, true);
                    }
                }
                if (expr_mod.canStartExpression(kind)) return self.parseExpressionStatement();
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            },
        }
    }

    fn parseEmptyStatement(self: *Parser) ParseError!Statement {
        const tok = try self.bump();
        std.debug.assert(tok.kind == .semicolon);
        return .{ .empty = .{ .span = tok.span } };
    }

    /// §14.2 BlockStatement.
    fn parseBlockStatement(self: *Parser) ParseError!Statement {
        const block = try self.parseBlockStatementInner();
        return .{ .block = block };
    }

    /// §14.3.1 LexicalDeclaration. `let` / `const` followed by one or more
    /// `BindingIdentifier (= AssignmentExpression)?` separated by `,`. In
    /// this slice destructuring patterns are deferred — only single-name
    /// bindings are recognised.
    fn parseLexicalDeclaration(self: *Parser, kind: stmt_mod.LexicalDecl.Kind) ParseError!Statement {
        const keyword = try self.bump();
        var declarators: std.ArrayListUnmanaged(stmt_mod.VariableDeclarator) = .empty;
        while (true) {
            const decl = try self.parseVariableDeclarator(kind);
            try declarators.append(self.arena, decl);
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        const slice = try declarators.toOwnedSlice(self.arena);
        const last_end = slice[slice.len - 1].span.end;
        const stmt_end = try self.consumeSemicolon(last_end);
        return .{ .lexical = .{
            .span = .{ .start = keyword.span.start, .end = stmt_end },
            .kind = kind,
            .declarators = slice,
        } };
    }

    fn parseVariableDeclarator(self: *Parser, kind: stmt_mod.LexicalDecl.Kind) ParseError!stmt_mod.VariableDeclarator {
        return self.parseVariableDeclaratorOptions(kind, true);
    }

    fn parseVariableDeclaratorOptions(
        self: *Parser,
        kind: stmt_mod.LexicalDecl.Kind,
        require_initializer: bool,
    ) ParseError!stmt_mod.VariableDeclarator {
        const target = try self.parseBindingTarget();
        const target_span = target.span();
        var end = target_span.end;
        var init_expr: ?Expression = null;
        const target_is_pattern = target != .identifier;
        if (try self.eat(.eq)) {
            const value = try expr_mod.parseAssignmentEntry(self);
            end = value.span().end;
            init_expr = value;
        } else if (require_initializer and (kind == .const_ or target_is_pattern)) {
            // §14.3.1: `const` requires an initializer. Patterns also do
            // (per §14.3.3 LexicalBinding production), since destructuring
            // without a value to destructure is meaningless. Skipped when
            // the declarator is the head of a for-in/of loop, where the
            // iteration supplies the value.
            try self.report(.const_without_initializer, target_span);
        }
        return .{
            .span = .{ .start = target_span.start, .end = end },
            .name = target,
            .init = init_expr,
        };
    }

    /// §14.3.3 BindingPattern. Dispatches on the leading token: `{` opens
    /// an ObjectBindingPattern, `[` an ArrayBindingPattern, an identifier
    /// is a plain BindingIdentifier.
    pub fn parseBindingTarget(self: *Parser) ParseError!stmt_mod.BindingTarget {
        switch (self.current.kind) {
            .lbrace => return .{ .object = try self.parseObjectPattern() },
            .lbracket => return .{ .array = try self.parseArrayPattern() },
            else => {
                const id = try self.parseBindingIdentifier();
                return .{ .identifier = id };
            },
        }
    }

    fn parseObjectPattern(self: *Parser) ParseError!stmt_mod.ObjectPattern {
        const lbrace = try self.bump();
        std.debug.assert(lbrace.kind == .lbrace);
        var properties: std.ArrayListUnmanaged(stmt_mod.ObjectPatternProperty) = .empty;
        var rest: ?stmt_mod.BindingIdentifier = null;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .ellipsis) {
                _ = try self.bump();
                rest = try self.parseBindingIdentifier();
                // Rest must be last and have no default.
                if (self.current.kind == .comma) {
                    try self.report(.unexpected_token, self.current.span);
                    return error.ParseError;
                }
                break;
            }
            const prop = try self.parseObjectPatternProperty();
            try properties.append(self.arena, prop);
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        const rbrace = try self.expect(.rbrace);
        return .{
            .span = .{ .start = lbrace.span.start, .end = rbrace.span.end },
            .properties = try properties.toOwnedSlice(self.arena),
            .rest = rest,
        };
    }

    fn parseObjectPatternProperty(self: *Parser) ParseError!stmt_mod.ObjectPatternProperty {
        const start = self.current.span.start;
        const key_tok = self.current;
        var key: ast.expression.PropertyKey = undefined;
        var key_is_plain_ident = false;
        if (key_tok.kind == .lbracket) {
            _ = try self.bump();
            const inner = try expr_mod.parseAssignmentEntry(self);
            _ = try self.expect(.rbracket);
            const ptr = try self.arena.create(Expression);
            ptr.* = inner;
            key = .{ .computed = ptr };
        } else if (key_tok.kind == .string_literal) {
            _ = try self.bump();
            key = .{ .string = key_tok.span };
        } else if (key_tok.kind == .numeric_literal) {
            _ = try self.bump();
            key = .{ .numeric = key_tok.span };
        } else if (key_tok.kind == .identifier or @intFromEnum(key_tok.kind) >= @intFromEnum(TokenKind.kw_await)) {
            _ = try self.bump();
            key = .{ .ident = key_tok.span };
            key_is_plain_ident = (key_tok.kind == .identifier);
        } else {
            try self.report(.unexpected_token, key_tok.span);
            return error.ParseError;
        }

        // Shorthand: no `:` → key is also the binding name. Only valid
        // when the key is a plain Identifier (not a reserved word, not a
        // string/numeric/computed key).
        if (self.current.kind != .colon) {
            if (!key_is_plain_ident) {
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            }
            const ident_span = key.ident;
            var element_end = ident_span.end;
            var default: ?Expression = null;
            if (try self.eat(.eq)) {
                const def = try expr_mod.parseAssignmentEntry(self);
                element_end = def.span().end;
                default = def;
            }
            const value: stmt_mod.BindingElement = .{
                .span = .{ .start = ident_span.start, .end = element_end },
                .target = .{ .identifier = .{ .span = ident_span } },
                .default = default,
            };
            return .{
                .span = .{ .start = start, .end = element_end },
                .key = key,
                .value = value,
                .shorthand = true,
            };
        }

        _ = try self.bump(); // `:`
        const value = try self.parseBindingElement();
        return .{
            .span = .{ .start = start, .end = value.span.end },
            .key = key,
            .value = value,
            .shorthand = false,
        };
    }

    fn parseArrayPattern(self: *Parser) ParseError!stmt_mod.ArrayPattern {
        const lbracket = try self.bump();
        std.debug.assert(lbracket.kind == .lbracket);
        var elements: std.ArrayListUnmanaged(?stmt_mod.BindingElement) = .empty;
        var rest: ?*stmt_mod.BindingTarget = null;
        while (self.current.kind != .rbracket and self.current.kind != .eof) {
            if (self.current.kind == .comma) {
                try elements.append(self.arena, null);
                _ = try self.bump();
                continue;
            }
            if (self.current.kind == .ellipsis) {
                _ = try self.bump();
                const r = try self.parseBindingTarget();
                const ptr = try self.arena.create(stmt_mod.BindingTarget);
                ptr.* = r;
                rest = ptr;
                break;
            }
            const be = try self.parseBindingElement();
            try elements.append(self.arena, be);
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        const rbracket = try self.expect(.rbracket);
        return .{
            .span = .{ .start = lbracket.span.start, .end = rbracket.span.end },
            .elements = try elements.toOwnedSlice(self.arena),
            .rest = rest,
        };
    }

    fn parseBindingElement(self: *Parser) ParseError!stmt_mod.BindingElement {
        const target = try self.parseBindingTarget();
        const target_span = target.span();
        var end = target_span.end;
        var default: ?Expression = null;
        if (try self.eat(.eq)) {
            const def = try expr_mod.parseAssignmentEntry(self);
            end = def.span().end;
            default = def;
        }
        return .{
            .span = .{ .start = target_span.start, .end = end },
            .target = target,
            .default = default,
        };
    }

    /// §14.6 IfStatement.
    fn parseIfStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `if`
        _ = try self.expect(.lparen);
        const test_expr = try expr_mod.parseExpression(self);
        _ = try self.expect(.rparen);
        const consequent = try self.arena.create(Statement);
        consequent.* = try self.parseStatement();
        var alternate: ?*Statement = null;
        var end = consequent.span().end;
        if (try self.eat(.kw_else)) {
            const alt = try self.arena.create(Statement);
            alt.* = try self.parseStatement();
            alternate = alt;
            end = alt.span().end;
        }
        return .{ .if_ = .{
            .span = .{ .start = start, .end = end },
            .test_ = test_expr,
            .consequent = consequent,
            .alternate = alternate,
        } };
    }

    /// §14.7.3 WhileStatement.
    fn parseWhileStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `while`
        _ = try self.expect(.lparen);
        const test_expr = try expr_mod.parseExpression(self);
        _ = try self.expect(.rparen);
        const body = try self.arena.create(Statement);
        body.* = try self.parseStatement();
        return .{ .while_ = .{
            .span = .{ .start = start, .end = body.span().end },
            .test_ = test_expr,
            .body = body,
        } };
    }

    /// §14.7.2 DoWhileStatement. The trailing `;` after `while (cond)` is
    /// optional per §14.7.2 (a special ASI rule grants the semicolon
    /// regardless of preceding LineTerminator).
    fn parseDoWhileStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `do`
        const body = try self.arena.create(Statement);
        body.* = try self.parseStatement();
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const test_expr = try expr_mod.parseExpression(self);
        const rparen = try self.expect(.rparen);
        // §14.7.2 grants ASI here unconditionally — consume an optional `;`.
        var end = rparen.span.end;
        if (self.current.kind == .semicolon) {
            const semi = try self.bump();
            end = semi.span.end;
        }
        return .{ .do_while = .{
            .span = .{ .start = start, .end = end },
            .body = body,
            .test_ = test_expr,
        } };
    }

    /// §14.10 ReturnStatement. Restricted production (§12.10.1):
    /// `return [no LineTerminator here] Expression?`. If a LineTerminator
    /// follows `return`, ASI fires before any expression.
    ///
    /// §14.10.1 early error: a `return` outside any function body
    /// (i.e. at top-level Script or Module) is a SyntaxError.
    /// `[~Return]` in the §16.1.1 / §16.2.2 grammar parameter
    /// captures this; `in_function` is the runtime form of that
    /// flag.
    fn parseReturnStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        const keyword = try self.bump(); // `return`
        if (!self.in_function) {
            try self.report(.unexpected_token, keyword.span);
            return error.ParseError;
        }
        var argument: ?Expression = null;
        var arg_end = keyword.span.end;
        if (!self.current.line_terminator_before and
            self.current.kind != .semicolon and
            self.current.kind != .rbrace and
            self.current.kind != .eof)
        {
            const arg = try expr_mod.parseExpression(self);
            arg_end = arg.span().end;
            argument = arg;
        }
        const stmt_end = try self.consumeSemicolon(arg_end);
        return .{ .return_ = .{
            .span = .{ .start = start, .end = stmt_end },
            .argument = argument,
        } };
    }

    /// §14.14 ThrowStatement. Restricted production: `throw [no LF] Expression`.
    /// Unlike `return`, the operand is mandatory — a LineTerminator after
    /// `throw` is a SyntaxError.
    fn parseThrowStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        const keyword = try self.bump(); // `throw`
        if (self.current.line_terminator_before or
            self.current.kind == .semicolon or
            self.current.kind == .rbrace or
            self.current.kind == .eof)
        {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        const arg = try expr_mod.parseExpression(self);
        const stmt_end = try self.consumeSemicolon(arg.span().end);
        _ = keyword;
        return .{ .throw_ = .{
            .span = .{ .start = start, .end = stmt_end },
            .argument = arg,
        } };
    }

    /// §14.13 BreakStatement / §14.15 ContinueStatement. Both share a
    /// restricted-production rule: `break [no LF] LabelIdentifier?`.
    /// Labels are not yet implemented; the optional LabelIdentifier is
    /// always parsed as null.
    fn parseBreakOrContinueStatement(self: *Parser, is_break: bool) ParseError!Statement {
        const start = self.current.span.start;
        const keyword = try self.bump();
        var label: ?Span = null;
        var label_end = keyword.span.end;
        if (!self.current.line_terminator_before and
            self.current.kind == .identifier)
        {
            const tok = try self.bump();
            label = tok.span;
            label_end = tok.span.end;
        }
        const stmt_end = try self.consumeSemicolon(label_end);
        if (is_break) {
            return .{ .break_ = .{
                .span = .{ .start = start, .end = stmt_end },
                .label = label,
            } };
        }
        return .{ .continue_ = .{
            .span = .{ .start = start, .end = stmt_end },
            .label = label,
        } };
    }

    /// §14.7.4 / §14.7.5 ForStatement / ForInOfStatement. Distinguishing
    /// the C-style and for-in/of forms requires a small look-ahead trick:
    /// parse the init in `[~In]` mode, then peek the following token —
    /// `in` (or contextual `of`) means for-in/of, `;` means C-style.
    fn parseForStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `for`

        // §14.7.5 `for await (…)` — async iteration. Only valid in
        // [+Await] contexts (in_async); only as a for-of (not for-in
        // or C-style). Detected here so the rest of the header parse
        // is shared with the non-await forms.
        var is_await = false;
        if (self.current.kind == .kw_await) {
            if (!self.in_async) {
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            }
            _ = try self.bump();
            is_await = true;
        }

        _ = try self.expect(.lparen);

        const saved_allow_in = self.allow_in;
        self.allow_in = false;
        defer self.allow_in = saved_allow_in;

        var init_head: ?stmt_mod.ForHead = null;
        if (self.current.kind == .semicolon) {
            // No init — empty C-style head.
        } else if (self.current.kind == .kw_let or self.current.kind == .kw_const or self.current.kind == .kw_var) {
            // Lexical / var declaration. Single declarator if for-in/of
            // follows; otherwise full declaration without the trailing `;`.
            const decl = try self.parseForLexicalDecl();
            init_head = .{ .lexical = decl };
        } else {
            const e = try expr_mod.parseExpression(self);
            init_head = .{ .expression = e };
        }

        // Decide whether this is for-in / for-of / C-style.
        const for_kind: ?stmt_mod.ForInOfStmt.Kind = blk: {
            if (self.current.kind == .kw_in) break :blk .in_;
            if (self.current.kind == .identifier and
                std.mem.eql(u8, self.current.slice(self.source), "of"))
            {
                break :blk .of_;
            }
            break :blk null;
        };

        if (for_kind) |kind| {
            // §14.7.5: only `for await (… of …)` is valid; `for await
            // (… in …)` is a parse error.
            if (is_await and kind == .in_) {
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            }
            // for-in / for-of: validate left, parse `in`/`of`, RHS, `)`, body.
            const left = init_head orelse {
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            };
            if (left == .lexical) {
                const ld = left.lexical;
                if (ld.declarators.len != 1 or ld.declarators[0].init != null) {
                    try self.report(.unexpected_token, ld.span);
                    return error.ParseError;
                }
            }
            _ = try self.bump(); // `in` / `of`
            // Re-enable [+In] for the RHS and body — only the for-init/left
            // is parsed in [~In].
            self.allow_in = true;
            const right = if (kind == .of_)
                try expr_mod.parseAssignmentEntry(self)
            else
                try expr_mod.parseExpression(self);
            _ = try self.expect(.rparen);
            const body = try self.arena.create(Statement);
            body.* = try self.parseStatement();
            return .{ .for_in_of = .{
                .span = .{ .start = start, .end = body.span().end },
                .kind = kind,
                .is_await = is_await,
                .left = left,
                .right = right,
                .body = body,
            } };
        }

        // §14.7.5: `for await` MUST be followed by an `of` head — a
        // C-style head after `for await` is a parse error.
        if (is_await) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        // C-style.
        _ = try self.expect(.semicolon);
        self.allow_in = true;
        var test_expr: ?Expression = null;
        if (self.current.kind != .semicolon) {
            test_expr = try expr_mod.parseExpression(self);
        }
        _ = try self.expect(.semicolon);
        var update_expr: ?Expression = null;
        if (self.current.kind != .rparen) {
            update_expr = try expr_mod.parseExpression(self);
        }
        _ = try self.expect(.rparen);
        const body = try self.arena.create(Statement);
        body.* = try self.parseStatement();
        return .{ .for_ = .{
            .span = .{ .start = start, .end = body.span().end },
            .init = init_head,
            .test_ = test_expr,
            .update = update_expr,
            .body = body,
        } };
    }

    /// LexicalDeclaration body without the trailing `;` — used inside the
    /// for-loop init slot, where the surrounding header consumes the `;`.
    /// Initializer-required validation is deferred to the caller, since
    /// for-in/of loops bind via iteration rather than `=`.
    fn parseForLexicalDecl(self: *Parser) ParseError!stmt_mod.LexicalDecl {
        const kind: stmt_mod.LexicalDecl.Kind = switch (self.current.kind) {
            .kw_let => .let_,
            .kw_const => .const_,
            .kw_var => .var_,
            else => unreachable,
        };
        const keyword = try self.bump();
        var declarators: std.ArrayListUnmanaged(stmt_mod.VariableDeclarator) = .empty;
        while (true) {
            const decl = try self.parseVariableDeclaratorOptions(kind, false);
            try declarators.append(self.arena, decl);
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        const slice = try declarators.toOwnedSlice(self.arena);
        const last_end = slice[slice.len - 1].span.end;
        return .{
            .span = .{ .start = keyword.span.start, .end = last_end },
            .kind = kind,
            .declarators = slice,
        };
    }

    /// §14.15 TryStatement.
    fn parseTryStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `try`
        const block = try self.parseBlockStatementInner();
        var handler: ?stmt_mod.CatchClause = null;
        var finalizer: ?stmt_mod.BlockStmt = null;
        if (self.current.kind == .kw_catch) {
            handler = try self.parseCatchClause();
        }
        if (self.current.kind == .kw_finally) {
            _ = try self.bump();
            finalizer = try self.parseBlockStatementInner();
        }
        if (handler == null and finalizer == null) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        const end = if (finalizer) |f| f.span.end else if (handler) |h| h.span.end else block.span.end;
        return .{ .try_ = .{
            .span = .{ .start = start, .end = end },
            .block = block,
            .handler = handler,
            .finalizer = finalizer,
        } };
    }

    fn parseCatchClause(self: *Parser) ParseError!stmt_mod.CatchClause {
        const catch_tok = try self.bump(); // `catch`
        var param: ?stmt_mod.BindingTarget = null;
        if (self.current.kind == .lparen) {
            _ = try self.bump();
            param = try self.parseBindingTarget();
            _ = try self.expect(.rparen);
        }
        const body = try self.parseBlockStatementInner();
        return .{
            .span = .{ .start = catch_tok.span.start, .end = body.span.end },
            .param = param,
            .body = body,
        };
    }

    /// Parse a `{ … }` block and return the BlockStmt payload directly,
    /// not wrapped in a Statement. Used by `try`/`catch`/`finally` where
    /// the AST stores blocks as fields rather than child statements.
    pub fn parseBlockStatementInner(self: *Parser) ParseError!stmt_mod.BlockStmt {
        const lbrace = try self.expect(.lbrace);
        var body: std.ArrayListUnmanaged(Statement) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            const stmt = self.parseStatement() catch |err| switch (err) {
                error.ParseError => {
                    self.synchronize();
                    continue;
                },
                else => return err,
            };
            try body.append(self.arena, stmt);
        }
        const rbrace = try self.expect(.rbrace);
        const slice = try body.toOwnedSlice(self.arena);
        try self.validateBlockBindings(slice);
        return .{
            .span = .{ .start = lbrace.span.start, .end = rbrace.span.end },
            .body = slice,
        };
    }

    /// §14.12 SwitchStatement.
    fn parseSwitchStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `switch`
        _ = try self.expect(.lparen);
        const discriminant = try expr_mod.parseExpression(self);
        _ = try self.expect(.rparen);
        _ = try self.expect(.lbrace);
        var cases: std.ArrayListUnmanaged(stmt_mod.SwitchCase) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            const case = try self.parseSwitchCase();
            try cases.append(self.arena, case);
        }
        const rbrace = try self.expect(.rbrace);
        const cases_slice = try cases.toOwnedSlice(self.arena);
        // §14.12.1 CaseBlock early errors: LDN of the entire switch body
        // must have no duplicates and must not intersect VDN. Validate
        // against the concatenation of every case's StatementList.
        {
            var combined: std.ArrayListUnmanaged(Statement) = .empty;
            defer combined.deinit(self.arena);
            for (cases_slice) |case|
                for (case.body) |stmt|
                    try combined.append(self.arena, stmt);
            try self.validateBlockBindings(combined.items);
        }
        return .{ .switch_ = .{
            .span = .{ .start = start, .end = rbrace.span.end },
            .discriminant = discriminant,
            .cases = cases_slice,
        } };
    }

    fn parseSwitchCase(self: *Parser) ParseError!stmt_mod.SwitchCase {
        const start = self.current.span.start;
        var test_expr: ?Expression = null;
        if (try self.eat(.kw_case)) {
            test_expr = try expr_mod.parseExpression(self);
        } else {
            _ = try self.expect(.kw_default);
        }
        _ = try self.expect(.colon);
        var body: std.ArrayListUnmanaged(Statement) = .empty;
        while (self.current.kind != .kw_case and
            self.current.kind != .kw_default and
            self.current.kind != .rbrace and
            self.current.kind != .eof)
        {
            const stmt = self.parseStatement() catch |err| switch (err) {
                error.ParseError => {
                    self.synchronize();
                    continue;
                },
                else => return err,
            };
            try body.append(self.arena, stmt);
        }
        const slice = try body.toOwnedSlice(self.arena);
        const end = if (slice.len > 0) slice[slice.len - 1].span().end else self.current.span.start;
        return .{
            .span = .{ .start = start, .end = end },
            .test_ = test_expr,
            .body = slice,
        };
    }

    /// §15.2 FunctionDeclaration: `function name(params) { body }`.
    /// `function*` opens a generator; `async function` opens an async
    /// function (§15.5, §15.8). The async-prefix is consumed by the
    /// statement dispatcher; this entry point begins at `function`.
    fn parseFunctionDeclaration(self: *Parser) ParseError!Statement {
        return self.parseFunctionDeclarationAt(self.current.span.start, false);
    }

    pub fn parseFunctionDeclarationAt(self: *Parser, start: u32, is_async: bool) ParseError!Statement {
        _ = try self.bump(); // `function`
        const is_generator = try self.eat(.star);
        const name = try self.parseBindingIdentifier();
        const params = try self.parseFunctionParameters();

        const saved_gen = self.in_generator;
        const saved_async = self.in_async;
        const saved_in_function = self.in_function;
        self.in_generator = is_generator;
        self.in_async = is_async;
        self.in_function = true;
        defer {
            self.in_generator = saved_gen;
            self.in_async = saved_async;
            self.in_function = saved_in_function;
        }

        const body = try self.parseBlockStatementInner();
        tagDirectivePrologue(body.body);
        try enforceStrictDirectiveSimplicity(self, params, body.body, body.span);
        return .{ .function_decl = .{
            .span = .{ .start = start, .end = body.span.end },
            .name = name,
            .params = params,
            .body = body,
            .is_generator = is_generator,
            .is_async = is_async,
        } };
    }

    /// §15.7 ClassDeclaration. Generators / async / get / set / static
    /// blocks are deferred — methods and fields with simple keys (or
    /// PrivateIdentifier) are in scope.
    fn parseClassDeclaration(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `class`
        const name = try self.parseBindingIdentifier();
        var superclass: ?Expression = null;
        if (try self.eat(.kw_extends)) {
            superclass = try expr_mod.parseLeftHandSideEntry(self);
        }
        const body_end = try self.parseClassBody();
        return .{ .class_decl = .{
            .span = .{ .start = start, .end = body_end.end },
            .name = name,
            .superclass = superclass,
            .body = body_end.members,
        } };
    }

    pub const ClassBodyResult = struct {
        members: []stmt_mod.ClassMember,
        end: u32,
    };

    pub fn parseClassBody(self: *Parser) ParseError!ClassBodyResult {
        _ = try self.expect(.lbrace);
        var members: std.ArrayListUnmanaged(stmt_mod.ClassMember) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            // Skip `;` empty class elements (§15.7.1 ClassElement : ;).
            if (try self.eat(.semicolon)) continue;
            const m = try self.parseClassMember();
            try members.append(self.arena, m);
        }
        const rbrace = try self.expect(.rbrace);
        const member_slice = try members.toOwnedSlice(self.arena);
        try self.validateClassBodyEarlyErrors(member_slice);
        return .{
            .members = member_slice,
            .end = rbrace.span.end,
        };
    }

    const PrivKind = enum { field, method, getter, setter };
    const PrivEntry = struct {
        name: []const u8,
        is_static: bool,
        kind: PrivKind,
        span: Span,
    };

    /// §15.7.1 ClassBody : ClassElementList — Static Semantics: Early Errors.
    ///
    /// Per-element rules:
    ///   • It is a Syntax Error if PropName of MethodDefinition is
    ///     "prototype" and IsStatic is true.
    ///   • It is a Syntax Error if PropName of MethodDefinition is
    ///     "constructor" and SpecialMethod (generator / async /
    ///     async-generator / getter / setter) of MethodDefinition is true,
    ///     **except** when IsStatic is true — `static get constructor()` /
    ///     `static *constructor()` etc. are legal: a static method named
    ///     "constructor" is just an own property of the constructor
    ///     function, not the [[Construct]] body.
    ///   • PrivateBoundIdentifier "#constructor" is forbidden for any
    ///     class element (field or method, static or not).
    ///
    /// Cross-element rules:
    ///   • At most one non-static non-special MethodDefinition with
    ///     PropName "constructor" — duplicates are SyntaxError.
    ///   • PrivateBoundIdentifiers must be unique, with the standard
    ///     exception that exactly one `get` paired with exactly one `set`
    ///     on the same IsStatic is allowed.
    fn validateClassBodyEarlyErrors(
        self: *Parser,
        members: []const stmt_mod.ClassMember,
    ) ParseError!void {
        // Track non-static non-special "constructor" methods so we can
        // diagnose duplicates (the second-and-later occurrences flag).
        var ctor_seen = false;

        // Track PrivateBoundIdentifiers so we can apply the get+set
        // pairing exception. A duplicate is allowed *only* when it pairs
        // (getter, setter) on the same is_static.
        var privs: std.ArrayListUnmanaged(PrivEntry) = .empty;
        defer privs.deinit(self.arena);

        for (members) |m| {
            switch (m) {
                .static_block => continue,
                .method => |md| {
                    const prop = self.classKeyName(md.key);
                    const key_span = self.classKeySpan(md.key);
                    const is_special = md.kind == .getter or md.kind == .setter or
                        md.is_generator or md.is_async;

                    // §15.7.1 — static MethodDefinition with PropName "prototype".
                    if (md.is_static) {
                        if (prop) |name| {
                            if (std.mem.eql(u8, name, "prototype")) {
                                try self.report(.invalid_class_element, key_span);
                            }
                        }
                    }

                    // §15.7.1 — non-static SpecialMethod with PropName "constructor".
                    if (!md.is_static and is_special) {
                        if (prop) |name| {
                            if (std.mem.eql(u8, name, "constructor")) {
                                try self.report(.invalid_class_element, key_span);
                            }
                        }
                    }

                    // §15.7.1 — PrivateBoundIdentifier "#constructor".
                    if (md.key == .private) {
                        const text = self.privateNameText(md.key.private);
                        if (std.mem.eql(u8, text, "#constructor")) {
                            try self.report(.invalid_class_element, key_span);
                        }
                        const k: PrivKind = switch (md.kind) {
                            .method => PrivKind.method,
                            .getter => PrivKind.getter,
                            .setter => PrivKind.setter,
                        };
                        try self.checkPrivateUniqueness(&privs, .{
                            .name = text,
                            .is_static = md.is_static,
                            .kind = k,
                            .span = key_span,
                        });
                    }

                    // Cross-element: duplicate non-static non-special "constructor".
                    if (!md.is_static and !is_special) {
                        if (prop) |name| {
                            if (std.mem.eql(u8, name, "constructor")) {
                                if (ctor_seen) {
                                    try self.report(.invalid_class_element, key_span);
                                } else {
                                    ctor_seen = true;
                                }
                            }
                        }
                    }
                },
                .field => |fd| {
                    const key_span = self.classKeySpan(fd.key);
                    if (fd.key == .private) {
                        const text = self.privateNameText(fd.key.private);
                        if (std.mem.eql(u8, text, "#constructor")) {
                            try self.report(.invalid_class_element, key_span);
                        }
                        try self.checkPrivateUniqueness(&privs, .{
                            .name = text,
                            .is_static = fd.is_static,
                            .kind = .field,
                            .span = key_span,
                        });
                    }
                },
            }
        }
    }

    /// PropName for a MethodDefinition / FieldDefinition key, when
    /// statically determinable. Returns the StringValue of the key
    /// (decoded from the source slice) for `ident` / `string` / numeric
    /// keys; returns null for `computed` and `private` (private isn't
    /// a PropName per spec). Numeric keys aren't decoded — they can't
    /// equal "constructor"/"prototype" so we just return null.
    fn classKeyName(self: *Parser, key: ast.expression.PropertyKey) ?[]const u8 {
        return switch (key) {
            .ident => |span| self.source[span.start..span.end],
            .string => |span| blk: {
                // Strip the surrounding quotes. We don't decode escapes
                // here — a string key with `prototype` is rare and
                // would need full StringValue decoding; we accept the
                // false-negative and only match the literal slice. This
                // is enough for every real-world test262 fixture.
                if (span.end <= span.start + 1) break :blk null;
                break :blk self.source[span.start + 1 .. span.end - 1];
            },
            .numeric => null,
            .computed => null,
            .private => null,
        };
    }

    fn classKeySpan(self: *Parser, key: ast.expression.PropertyKey) Span {
        _ = self;
        return switch (key) {
            .ident => |span| span,
            .string => |span| span,
            .numeric => |span| span,
            .private => |span| span,
            .computed => |ptr| ptr.span(),
        };
    }

    /// Source text of a PrivateIdentifier key, including the leading `#`.
    fn privateNameText(self: *Parser, span: Span) []const u8 {
        return self.source[span.start..span.end];
    }

    fn checkPrivateUniqueness(
        self: *Parser,
        privs: *std.ArrayListUnmanaged(PrivEntry),
        entry: PrivEntry,
    ) ParseError!void {
        for (privs.items) |existing| {
            if (existing.is_static != entry.is_static) continue;
            if (!std.mem.eql(u8, existing.name, entry.name)) continue;
            // Pairing exception: getter + setter on the same is_static.
            const is_pair =
                (existing.kind == .getter and entry.kind == .setter) or
                (existing.kind == .setter and entry.kind == .getter);
            if (is_pair) {
                // Still a violation if a third occurrence appears — i.e.
                // a get/set already pairs and this is another get or set
                // or a method/field. We detect "already paired" by
                // looking for a second matching entry.
                var pair_count: usize = 0;
                for (privs.items) |e2| {
                    if (e2.is_static == entry.is_static and
                        std.mem.eql(u8, e2.name, entry.name))
                    {
                        pair_count += 1;
                    }
                }
                if (pair_count >= 2) {
                    try self.report(.invalid_class_element, entry.span);
                    try privs.append(self.arena, entry);
                    return;
                }
                try privs.append(self.arena, entry);
                return;
            }
            try self.report(.invalid_class_element, entry.span);
            try privs.append(self.arena, entry);
            return;
        }
        try privs.append(self.arena, entry);
    }

    fn parseClassMember(self: *Parser) ParseError!stmt_mod.ClassMember {
        const start = self.current.span.start;
        var is_static = false;
        // Detect `static` modifier vs `static` as method name. If `static`
        // is immediately followed by `(`, `=`, `;` or `}`, it's the name.
        if (self.current.kind == .kw_static) {
            const second = try self.peek2();
            if (second.kind == .lbrace) {
                // §15.7.13 ClassStaticBlock — `static { … }`.
                _ = try self.bump(); // `static`
                const body_block = try self.parseBlockStatementInner();
                return .{ .static_block = .{
                    .span = .{ .start = start, .end = body_block.span.end },
                    .body = body_block.body,
                } };
            }
            if (second.kind != .lparen and second.kind != .eq and second.kind != .semicolon and second.kind != .rbrace) {
                is_static = true;
                _ = try self.bump();
            }
        }

        // Detect `async` modifier on a method (§15.8.4). `async` followed
        // by `(` would be a method literally named `async`; otherwise
        // (and with no LF), it's the async modifier.
        var is_async = false;
        if (self.current.kind == .identifier and
            std.mem.eql(u8, self.current.slice(self.source), "async"))
        {
            const second = try self.peek2();
            if (!second.line_terminator_before and second.kind != .lparen and
                (isPropertyNameStart(second.kind) or second.kind == .star))
            {
                is_async = true;
                _ = try self.bump();
            }
        }

        // Detect `*` for generator methods — `async *foo()` is an async
        // generator method (§15.9.4).
        const is_generator = try self.eat(.star);

        // Detect `get` / `set` accessor — contextual; not allowed with
        // async or generator modifiers.
        var method_kind: stmt_mod.MethodKind = .method;
        if (!is_async and !is_generator and self.current.kind == .identifier) {
            const slice_text = self.current.slice(self.source);
            if (std.mem.eql(u8, slice_text, "get") or std.mem.eql(u8, slice_text, "set")) {
                const second = try self.peek2();
                if (isPropertyNameStart(second.kind) and second.kind != .lparen) {
                    method_kind = if (slice_text[0] == 'g') .getter else .setter;
                    _ = try self.bump();
                }
            }
        }

        const key_with_end = try self.parseClassMemberKey();
        const key = key_with_end.key;
        const key_end = key_with_end.end;
        if (self.current.kind == .lparen) {
            const params = try self.parseFunctionParameters();

            const saved_gen = self.in_generator;
            const saved_async = self.in_async;
            const saved_in_function = self.in_function;
            const saved_in_method = self.in_method;
            self.in_generator = is_generator;
            self.in_async = is_async;
            self.in_function = true;
            self.in_method = true;
            const body = blk: {
                defer {
                    self.in_generator = saved_gen;
                    self.in_async = saved_async;
                    self.in_function = saved_in_function;
                    self.in_method = saved_in_method;
                }
                break :blk try self.parseBlockStatementInner();
            };
            tagDirectivePrologue(body.body);
            try enforceStrictDirectiveSimplicity(self, params, body.body, body.span);
            return .{ .method = .{
                .span = .{ .start = start, .end = body.span.end },
                .is_static = is_static,
                .kind = method_kind,
                .key = key,
                .params = params,
                .body = body,
                .is_generator = is_generator,
                .is_async = is_async,
            } };
        }
        if (method_kind != .method or is_generator or is_async) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        // Field: optional `= initializer`, then `;` (with ASI).
        var init_expr: ?Expression = null;
        var end = key_end;
        if (try self.eat(.eq)) {
            const v = try expr_mod.parseAssignmentEntry(self);
            init_expr = v;
            end = v.span().end;
        }
        _ = try self.consumeSemicolon(end);
        return .{ .field = .{
            .span = .{ .start = start, .end = end },
            .is_static = is_static,
            .key = key,
            .init = init_expr,
        } };
    }


    const KeyAndEnd = struct {
        key: ast.expression.PropertyKey,
        end: u32,
    };

    fn parseClassMemberKey(self: *Parser) ParseError!KeyAndEnd {
        const tok = self.current;
        if (tok.kind == .lbracket) {
            _ = try self.bump();
            const inner = try expr_mod.parseAssignmentEntry(self);
            const rbracket = try self.expect(.rbracket);
            const ptr = try self.arena.create(Expression);
            ptr.* = inner;
            return .{ .key = .{ .computed = ptr }, .end = rbracket.span.end };
        }
        if (tok.kind == .private_identifier) {
            _ = try self.bump();
            return .{ .key = .{ .private = tok.span }, .end = tok.span.end };
        }
        if (tok.kind == .string_literal) {
            _ = try self.bump();
            return .{ .key = .{ .string = tok.span }, .end = tok.span.end };
        }
        if (tok.kind == .numeric_literal) {
            _ = try self.bump();
            return .{ .key = .{ .numeric = tok.span }, .end = tok.span.end };
        }
        if (tok.kind == .identifier or @intFromEnum(tok.kind) >= @intFromEnum(TokenKind.kw_await)) {
            _ = try self.bump();
            return .{ .key = .{ .ident = tok.span }, .end = tok.span.end };
        }
        try self.report(.unexpected_token, tok.span);
        return error.ParseError;
    }

    /// `( FormalParameters )` per §15.2. Trailing comma allowed; `...rest`
    /// must be last (no validation here yet — diagnose in a future pass).
    pub fn parseFunctionParameters(self: *Parser) ParseError![]stmt_mod.FunctionParam {
        _ = try self.expect(.lparen);
        var params: std.ArrayListUnmanaged(stmt_mod.FunctionParam) = .empty;
        // §15.1.1 / §11.10: in strict mode (always, in Cynic) the
        // BoundNames of FormalParameters must not contain duplicates.
        // We accumulate every name introduced by each parameter
        // (recursing into destructuring patterns) and check before
        // adding a new one.
        var bound_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer bound_names.deinit(self.arena);
        while (self.current.kind != .rparen and self.current.kind != .eof) {
            const is_rest = self.current.kind == .ellipsis;
            if (is_rest) {
                const dots = try self.bump();
                const target = try self.parseBindingTarget();
                try self.collectBoundNames(target, &bound_names);
                const target_span = target.span();
                try params.append(self.arena, .{ .rest = .{
                    .span = .{ .start = dots.span.start, .end = target_span.end },
                    .target = target,
                } });
                // §15.1: `FunctionRestParameter` cannot be followed by
                // anything except `)`. A trailing `,` after `...x` is a
                // SyntaxError. We don't consume it; just break and let
                // `expect(rparen)` report.
                break;
            } else {
                const target = try self.parseBindingTarget();
                try self.collectBoundNames(target, &bound_names);
                const target_span = target.span();
                var end = target_span.end;
                var default: ?Expression = null;
                if (try self.eat(.eq)) {
                    const def = try expr_mod.parseAssignmentEntry(self);
                    end = def.span().end;
                    default = def;
                }
                try params.append(self.arena, .{ .simple = .{
                    .span = .{ .start = target_span.start, .end = end },
                    .target = target,
                    .default = default,
                } });
            }
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        _ = try self.expect(.rparen);
        return params.toOwnedSlice(self.arena);
    }

    /// Walk a BindingTarget collecting BoundNames (§8.5). Each
    /// identifier seen is appended to `names` in source order. If a
    /// duplicate is found we report `restricted_identifier_in_strict`
    /// at the offending span. (We reuse that code rather than
    /// introducing a new one — the user-visible message is "duplicate
    /// parameter name in strict mode".) Errors are reported but do not
    /// abort parsing — recovery continues so we can flag multiple
    /// problems in one pass.
    fn collectBoundNames(
        self: *Parser,
        target: stmt_mod.BindingTarget,
        names: *std.ArrayListUnmanaged([]const u8),
    ) ParseError!void {
        switch (target) {
            .identifier => |id| try self.appendBoundName(id, names),
            .object => |obj| {
                for (obj.properties) |prop| {
                    try self.collectBoundNames(prop.value.target, names);
                }
                if (obj.rest) |rest_id| try self.appendBoundName(rest_id, names);
            },
            .array => |arr| {
                for (arr.elements) |maybe_elem| {
                    if (maybe_elem) |elem| try self.collectBoundNames(elem.target, names);
                }
                if (arr.rest) |rest_target| try self.collectBoundNames(rest_target.*, names);
            },
        }
    }

    fn appendBoundName(
        self: *Parser,
        id: stmt_mod.BindingIdentifier,
        names: *std.ArrayListUnmanaged([]const u8),
    ) ParseError!void {
        const name = self.source[id.span.start..id.span.end];
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                try self.report(.restricted_identifier_in_strict, id.span);
                break;
            }
        }
        try names.append(self.arena, name);
    }

    /// §14.2.1 / §14.12.1 early errors for a Block / SwitchBody
    /// StatementList:
    ///
    /// • LexicallyDeclaredNames must not contain duplicates.
    /// • LexicallyDeclaredNames ∩ VarDeclaredNames must be empty.
    ///
    /// LDN at this scope = `let`/`const`/`class`/`function` BoundNames
    /// declared *directly* in the StatementList (not inside nested
    /// blocks). VDN = `var` BoundNames recursively reachable through
    /// non-function statements.
    fn validateBlockBindings(self: *Parser, body: []const Statement) ParseError!void {
        var lex_names: std.ArrayListUnmanaged(NameSpan) = .empty;
        defer lex_names.deinit(self.arena);
        var var_names: std.ArrayListUnmanaged(NameSpan) = .empty;
        defer var_names.deinit(self.arena);

        for (body) |stmt| try self.collectBlockLDN(stmt, &lex_names);
        for (body) |stmt| try self.collectVDN(stmt, &var_names);

        // Duplicates within LDN.
        var i: usize = 0;
        while (i < lex_names.items.len) : (i += 1) {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (std.mem.eql(u8, lex_names.items[i].name, lex_names.items[j].name)) {
                    try self.report(.duplicate_lexical_binding, lex_names.items[i].span);
                    break;
                }
            }
        }
        // LDN ∩ VDN.
        for (lex_names.items) |ln| {
            for (var_names.items) |vn| {
                if (std.mem.eql(u8, ln.name, vn.name)) {
                    try self.report(.duplicate_lexical_binding, ln.span);
                    break;
                }
            }
        }
    }

    const NameSpan = struct { name: []const u8, span: Span };

    /// LexicallyDeclaredNames of a single Block-level Statement: only
    /// the top-level lexical declarations (let/const/class/function)
    /// contribute. Other statements (including nested blocks) contribute
    /// nothing — their LDNs belong to *their* inner scope.
    fn collectBlockLDN(
        self: *Parser,
        stmt: Statement,
        out: *std.ArrayListUnmanaged(NameSpan),
    ) ParseError!void {
        switch (stmt) {
            .lexical => |lex| {
                if (lex.kind == .var_) return; // var is VDN, not LDN
                for (lex.declarators) |decl| try self.collectTargetNames(decl.name, out);
            },
            .class_decl => |cd| {
                try out.append(self.arena, .{
                    .name = self.source[cd.name.span.start..cd.name.span.end],
                    .span = cd.name.span,
                });
            },
            .function_decl => |fd| {
                try out.append(self.arena, .{
                    .name = self.source[fd.name.span.start..fd.name.span.end],
                    .span = fd.name.span,
                });
            },
            else => {},
        }
    }

    /// VarDeclaredNames of a Block-level Statement: every `var`
    /// declaration reachable through non-function statements. Recurses
    /// into nested blocks, control-flow bodies, try/catch/finally,
    /// switch cases. Does NOT descend into FunctionDeclaration /
    /// ClassDeclaration / FunctionExpression bodies.
    fn collectVDN(
        self: *Parser,
        stmt: Statement,
        out: *std.ArrayListUnmanaged(NameSpan),
    ) ParseError!void {
        switch (stmt) {
            .lexical => |lex| {
                if (lex.kind != .var_) return;
                for (lex.declarators) |decl| try self.collectTargetNames(decl.name, out);
            },
            .block => |b| for (b.body) |inner| try self.collectVDN(inner, out),
            .if_ => |i| {
                try self.collectVDN(i.consequent.*, out);
                if (i.alternate) |alt| try self.collectVDN(alt.*, out);
            },
            .while_ => |w| try self.collectVDN(w.body.*, out),
            .do_while => |d| try self.collectVDN(d.body.*, out),
            .for_ => |f| {
                if (f.init) |init_head| switch (init_head) {
                    .lexical => |lex| {
                        if (lex.kind == .var_)
                            for (lex.declarators) |decl|
                                try self.collectTargetNames(decl.name, out);
                    },
                    .expression => {},
                };
                try self.collectVDN(f.body.*, out);
            },
            .for_in_of => |f| {
                switch (f.left) {
                    .lexical => |lex| {
                        if (lex.kind == .var_)
                            for (lex.declarators) |decl|
                                try self.collectTargetNames(decl.name, out);
                    },
                    .expression => {},
                }
                try self.collectVDN(f.body.*, out);
            },
            .try_ => |t| {
                for (t.block.body) |inner| try self.collectVDN(inner, out);
                if (t.handler) |h| for (h.body.body) |inner| try self.collectVDN(inner, out);
                if (t.finalizer) |fin| for (fin.body) |inner| try self.collectVDN(inner, out);
            },
            .switch_ => |sw| {
                for (sw.cases) |case| for (case.body) |inner| try self.collectVDN(inner, out);
            },
            else => {},
        }
    }

    fn collectTargetNames(
        self: *Parser,
        target: stmt_mod.BindingTarget,
        out: *std.ArrayListUnmanaged(NameSpan),
    ) ParseError!void {
        switch (target) {
            .identifier => |id| try out.append(self.arena, .{
                .name = self.source[id.span.start..id.span.end],
                .span = id.span,
            }),
            .object => |obj| {
                for (obj.properties) |prop|
                    try self.collectTargetNames(prop.value.target, out);
                if (obj.rest) |rest_id| try out.append(self.arena, .{
                    .name = self.source[rest_id.span.start..rest_id.span.end],
                    .span = rest_id.span,
                });
            },
            .array => |arr| {
                for (arr.elements) |maybe_elem|
                    if (maybe_elem) |elem| try self.collectTargetNames(elem.target, out);
                if (arr.rest) |rest_target| try self.collectTargetNames(rest_target.*, out);
            },
        }
    }

    /// §14.16 DebuggerStatement.
    fn parseDebuggerStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        const keyword = try self.bump();
        const stmt_end = try self.consumeSemicolon(keyword.span.end);
        return .{ .debugger_ = .{ .span = .{ .start = start, .end = stmt_end } } };
    }

    /// §16.2.2 ImportDeclaration. Forms supported:
    /// import "x";
    /// import name from "x";
    /// import { a, b as c } from "x";
    /// import * as ns from "x";
    /// import name, { a, b } from "x";
    /// import name, * as ns from "x";
    fn parseImportDeclaration(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `import`

        var default: ?stmt_mod.BindingIdentifier = null;
        var namespace: ?stmt_mod.BindingIdentifier = null;
        var named: []stmt_mod.NamedSpecifier = &.{};

        if (self.current.kind == .string_literal) {
            // Side-effect import: `import "x";` — no clause.
            const source_tok = try self.bump();
            const stmt_end = try self.consumeSemicolon(source_tok.span.end);
            return .{ .import_decl = .{
                .span = .{ .start = start, .end = stmt_end },
                .default = null,
                .namespace = null,
                .named = &.{},
                .source = source_tok.span,
            } };
        }

        // Default-import binding: `import name [,...] from "x"`.
        if (self.current.kind == .identifier) {
            default = try self.parseBindingIdentifier();
            if (try self.eat(.comma)) {
                if (self.current.kind == .star) {
                    namespace = try self.parseNamespaceImport();
                } else if (self.current.kind == .lbrace) {
                    named = try self.parseNamedImportList();
                } else {
                    try self.report(.unexpected_token, self.current.span);
                    return error.ParseError;
                }
            }
        } else if (self.current.kind == .star) {
            namespace = try self.parseNamespaceImport();
        } else if (self.current.kind == .lbrace) {
            named = try self.parseNamedImportList();
        } else {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }

        try self.expectContextualKeyword("from");
        if (self.current.kind != .string_literal) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        const source_tok = try self.bump();
        const stmt_end = try self.consumeSemicolon(source_tok.span.end);

        return .{ .import_decl = .{
            .span = .{ .start = start, .end = stmt_end },
            .default = default,
            .namespace = namespace,
            .named = named,
            .source = source_tok.span,
        } };
    }

    fn parseNamespaceImport(self: *Parser) ParseError!stmt_mod.BindingIdentifier {
        _ = try self.expect(.star);
        try self.expectContextualKeyword("as");
        return self.parseBindingIdentifier();
    }

    fn parseNamedImportList(self: *Parser) ParseError![]stmt_mod.NamedSpecifier {
        _ = try self.expect(.lbrace);
        var items: std.ArrayListUnmanaged(stmt_mod.NamedSpecifier) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            const start = self.current.span.start;
            const imported_tok = try self.parseModuleExportName();
            var local_span = imported_tok.span;
            // `imported as local`. `as` is contextual.
            if (self.current.kind == .identifier and
                std.mem.eql(u8, self.current.slice(self.source), "as"))
            {
                _ = try self.bump();
                const local_tok = try self.parseBindingIdentifier();
                local_span = local_tok.span;
            }
            try items.append(self.arena, .{
                .span = .{ .start = start, .end = local_span.end },
                .imported_span = imported_tok.span,
                .local = .{ .span = local_span },
            });
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        _ = try self.expect(.rbrace);
        return items.toOwnedSlice(self.arena);
    }

    /// §16.2.2 ModuleExportName: IdentifierName or StringLiteral.
    fn parseModuleExportName(self: *Parser) ParseError!Token {
        const tok = self.current;
        if (tok.kind == .identifier or tok.kind == .string_literal or
            @intFromEnum(tok.kind) >= @intFromEnum(TokenKind.kw_await))
        {
            return try self.bump();
        }
        try self.report(.unexpected_token, tok.span);
        return error.ParseError;
    }

    fn expectContextualKeyword(self: *Parser, name: []const u8) ParseError!void {
        if (self.current.kind == .identifier and
            std.mem.eql(u8, self.current.slice(self.source), name))
        {
            _ = try self.bump();
            return;
        }
        try self.report(.unexpected_token, self.current.span);
        return error.ParseError;
    }

    /// §16.2.3 ExportDeclaration.
    fn parseExportDeclaration(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        _ = try self.bump(); // `export`

        // `export *` / `export * as ns from "..."`.
        if (self.current.kind == .star) {
            return self.parseExportAll(start);
        }
        // `export {... }` (with optional `from "..."`).
        if (self.current.kind == .lbrace) {
            return self.parseExportNamed(start);
        }
        // `export default...`.
        if (self.current.kind == .kw_default) {
            return self.parseExportDefault(start);
        }
        // Declaration export: `export let/const/function/class/async function`.
        return self.parseExportDeclarationStatement(start);
    }

    fn parseExportAll(self: *Parser, start: u32) ParseError!Statement {
        _ = try self.bump(); // `*`
        var namespace_local: ?Span = null;
        if (self.current.kind == .identifier and
            std.mem.eql(u8, self.current.slice(self.source), "as"))
        {
            _ = try self.bump();
            const ns_tok = try self.parseModuleExportName();
            namespace_local = ns_tok.span;
        }
        try self.expectContextualKeyword("from");
        if (self.current.kind != .string_literal) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        const source_tok = try self.bump();
        const stmt_end = try self.consumeSemicolon(source_tok.span.end);
        return .{ .export_decl = .{
            .span = .{ .start = start, .end = stmt_end },
            .body = .{ .all = .{
                .namespace_local = namespace_local,
                .source = source_tok.span,
            } },
        } };
    }

    fn parseExportNamed(self: *Parser, start: u32) ParseError!Statement {
        _ = try self.expect(.lbrace);
        var specs: std.ArrayListUnmanaged(stmt_mod.ExportSpecifier) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            const spec_start = self.current.span.start;
            const local_tok = try self.parseModuleExportName();
            var exported_span = local_tok.span;
            if (self.current.kind == .identifier and
                std.mem.eql(u8, self.current.slice(self.source), "as"))
            {
                _ = try self.bump();
                const ex_tok = try self.parseModuleExportName();
                exported_span = ex_tok.span;
            }
            try specs.append(self.arena, .{
                .span = .{ .start = spec_start, .end = exported_span.end },
                .local_span = local_tok.span,
                .exported_span = exported_span,
            });
            if (self.current.kind != .comma) break;
            _ = try self.bump();
        }
        _ = try self.expect(.rbrace);
        var source: ?Span = null;
        if (self.current.kind == .identifier and
            std.mem.eql(u8, self.current.slice(self.source), "from"))
        {
            _ = try self.bump();
            if (self.current.kind != .string_literal) {
                try self.report(.unexpected_token, self.current.span);
                return error.ParseError;
            }
            const source_tok = try self.bump();
            source = source_tok.span;
        }
        const last_end: u32 = if (source) |s| s.end else self.current.span.start;
        const stmt_end = try self.consumeSemicolon(last_end);
        return .{ .export_decl = .{
            .span = .{ .start = start, .end = stmt_end },
            .body = .{ .named = .{
                .specifiers = try specs.toOwnedSlice(self.arena),
                .source = source,
            } },
        } };
    }

    fn parseExportDefault(self: *Parser, start: u32) ParseError!Statement {
        _ = try self.bump(); // `default`
        // §16.2.3.1 ExportDeclaration:
        // export default HoistableDeclaration (function / function* /
        // async function / async
        // function*) — no `;`
        // export default ClassDeclaration — no `;`
        // export default [lookahead ∉ { function, async [no LF] function,
        // class }] AssignmentExpression `;`
        //
        // We always parse the body via `parseAssignmentEntry` so that the
        // anonymous-default forms (`function () {}`, `class {}`) work
        // through the existing expression grammar. The lookahead check
        // only decides whether a trailing semicolon is required.
        const lookahead_kind = self.current.kind;
        const requires_semi: bool = blk: {
            if (lookahead_kind == .kw_function or lookahead_kind == .kw_class) {
                break :blk false;
            }
            if (lookahead_kind == .identifier and
                std.mem.eql(u8, self.current.slice(self.source), "async"))
            {
                const second = try self.peek2();
                if (second.kind == .kw_function and !second.line_terminator_before) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        const e = try expr_mod.parseAssignmentEntry(self);
        const stmt_end = if (requires_semi)
            try self.consumeSemicolon(e.span().end)
        else
            e.span().end;
        return .{ .export_decl = .{
            .span = .{ .start = start, .end = stmt_end },
            .body = .{ .default_value = e },
        } };
    }

    fn parseExportDeclarationStatement(self: *Parser, start: u32) ParseError!Statement {
        // The inner declaration is a normal statement.
        const inner = try self.parseStatement();
        const inner_ptr = try self.arena.create(Statement);
        inner_ptr.* = inner;
        return .{ .export_decl = .{
            .span = .{ .start = start, .end = inner.span().end },
            .body = .{ .declaration = inner_ptr },
        } };
    }

    pub fn parseBindingIdentifier(self: *Parser) ParseError!stmt_mod.BindingIdentifier {
        if (self.current.kind != .identifier) {
            try self.report(.unexpected_token, self.current.span);
            return error.ParseError;
        }
        const tok = try self.bump();
        const name = tok.slice(self.source);
        if (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments")) {
            try self.report(.restricted_identifier_in_strict, tok.span);
        }
        // §12.7.1: a BindingIdentifier whose source contains `\u`
        // escapes and whose StringValue is a ReservedWord is an early
        // SyntaxError. The lexer set `had_escape = true` on such a
        // token; enforce it here.
        if (tok.had_escape) {
            try self.report(.escape_in_reserved_word, tok.span);
        }
        return .{ .span = tok.span };
    }

    fn parseExpressionStatement(self: *Parser) ParseError!Statement {
        const start = self.current.span.start;
        const expression = try expr_mod.parseExpression(self);
        const expr_end = expression.span().end;
        const stmt_end = try self.consumeSemicolon(expr_end);
        return .{ .expression = .{
            .span = .{ .start = start, .end = stmt_end },
            .expression = expression,
        } };
    }

    /// §12.10 Automatic Semicolon Insertion (rule 1 only — restricted
    /// productions get ASI rule 2 wired in later). Returns the end offset
    /// for the enclosing statement's span: the consumed `;` end, or
    /// `prev_end` if ASI fires.
    fn consumeSemicolon(self: *Parser, prev_end: u32) ParseError!u32 {
        if (self.current.kind == .semicolon) {
            const tok = try self.bump();
            return tok.span.end;
        }
        if (self.current.kind == .eof or self.current.kind == .rbrace) return prev_end;
        if (self.current.line_terminator_before) return prev_end;
        try self.report(.unexpected_token, self.current.span);
        return error.ParseError;
    }

    // ── Recovery ────────────────────────────────────────────────────────

    /// Skip tokens until we land on a likely statement boundary so the next
    /// `parseStatement` call has a chance of succeeding without cascading.
    fn synchronize(self: *Parser) void {
        while (self.current.kind != .eof) {
            switch (self.current.kind) {
                .semicolon => {
                    _ = self.bump() catch return;
                    return;
                },
                .rbrace => return,
                else => {},
            }
            if (self.current.line_terminator_before) {
                switch (self.current.kind) {
                    .kw_let, .kw_const, .lbrace => return,
                    else => {},
                }
            }
            _ = self.bump() catch return;
        }
    }
};

/// Top-level convenience wrapper. The caller supplies the arena; on success
/// the returned `Program` is owned by it.
pub fn parseScript(arena: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics) ParseError!Program {
    var parser = try Parser.init(arena, source, diagnostics);
    return parser.parseScript();
}

/// Top-level convenience wrapper for §16.2 Module.
pub fn parseModule(arena: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics) ParseError!Program {
    var parser = try Parser.initWith(arena, source, diagnostics, true);
    return parser.parseModule();
}

/// If `stmt` is an ExpressionStatement whose expression is a single
/// StringLiteral, set its `directive` field to the literal content span
/// (between the quotes) and return that span. Otherwise return null.
/// Used by callers walking a §11.10 / §16.1.1 Directive Prologue.
fn markIfDirective(stmt: *Statement) ?Span {
    if (stmt.* != .expression) return null;
    const es = &stmt.expression;
    if (es.expression != .string_literal) return null;
    const lit = es.expression.string_literal.span;
    if (lit.end <= lit.start + 1) return null;
    const content: Span = .{ .start = lit.start + 1, .end = lit.end - 1 };
    es.directive = content;
    return content;
}

/// Walk a freshly-parsed statement list and tag the leading run of bare
/// StringLiteral ExpressionStatements as directives. Per §11.10 the
/// prologue ends at the first non-string-literal statement. Called by
/// every FunctionBody parse site. Script and Module bodies handle the
/// scan inline because they interleave it with recovery.
pub fn tagDirectivePrologue(stmts: []Statement) void {
    for (stmts) |*s| {
        if (markIfDirective(s) == null) break;
    }
}

/// §15.1.1 IsSimpleParameterList — true iff `params` is a sequence of
/// bare-identifier BindingIdentifier parameters with no defaults and
/// no rest. The "non-simple params + `use strict` body" early error
/// (§15.1.1, §15.3.1, §15.7.1, §15.8.1, §15.9.1) keys on this — the
/// rule is identical for every callable form.
pub fn isSimpleParameterList(params: []const stmt_mod.FunctionParam) bool {
    for (params) |p| switch (p) {
        .rest => return false,
        .simple => |sp| {
            if (sp.target != .identifier) return false;
            if (sp.default != null) return false;
        },
    };
    return true;
}

/// True if any directive in `body`'s tagged prologue is `"use strict"`.
/// The directive span (set by `markIfDirective`) covers the StringLiteral
/// content between its quotes — compare bytes directly.
pub fn containsUseStrict(body: []const Statement, source: []const u8) bool {
    for (body) |stmt| switch (stmt) {
        .expression => |es| if (es.directive) |span| {
            if (std.mem.eql(u8, source[span.start..span.end], "use strict")) return true;
        },
        else => return false, // Prologue ends at the first non-directive statement.
    };
    return false;
}

/// Apply the §15.1.1 / §15.3.1 / §15.7.1 / §15.8.1 / §15.9.1 early
/// error: a callable's body may not contain a `"use strict"` directive
/// when its parameter list is non-simple. Every callable-body parse
/// site (function decl/expr, arrow concise body, class method) calls
/// this after parsing the body and tagging its directive prologue.
pub fn enforceStrictDirectiveSimplicity(
    p: *Parser,
    params: []const stmt_mod.FunctionParam,
    body: []const Statement,
    span: Span,
) ParseError!void {
    if (isSimpleParameterList(params)) return;
    if (!containsUseStrict(body, p.source)) return;
    try p.report(.unexpected_token, span);
}

/// True when `kind` can begin an ObjectLiteral / ClassBody PropertyName.
/// Identifier (and any reserved-word identifier-name), string, numeric,
/// computed (`[`), and PrivateIdentifier (class only) are valid starts.
pub fn isPropertyNameStart(kind: TokenKind) bool {
    if (kind == .identifier or kind == .private_identifier) return true;
    if (kind == .string_literal or kind == .numeric_literal) return true;
    if (kind == .lbracket) return true;
    return @intFromEnum(kind) >= @intFromEnum(TokenKind.kw_await);
}

fn mapLexError(err: LexError) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ParseError,
    };
}

// ---------------------------------------------------------------------------
