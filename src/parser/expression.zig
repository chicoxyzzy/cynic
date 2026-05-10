//! Expression parsing for Cynic. Pratt-style precedence climbing for binary
//! ops; recursive descent for unary, primary, and the special-shape
//! productions (parenthesized, conditional, assignment, sequence).
//!
//! Public entry: `parseExpression(p)` parses an Expression (§13.16, the
//! Expression production — which includes the comma operator at the top).

const std = @import("std");

const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const ParseError = parser_mod.ParseError;

const ast_expr = @import("../ast/expression.zig");
const Expression = ast_expr.Expression;

const token_mod = @import("../lexer/token.zig");
const TokenKind = token_mod.TokenKind;

const Span = @import("../source.zig").Span;

/// §13.16 Expression — the comma-operator production.
pub fn parseExpression(p: *Parser) ParseError!Expression {
    const first = try parseAssignment(p);
    if (p.peek().kind != .comma) return first;
    var items: std.ArrayListUnmanaged(Expression) = .empty;
    try items.append(p.arena, first);
    while (p.peek().kind == .comma) {
        _ = try p.bump();
        const next = try parseAssignment(p);
        try items.append(p.arena, next);
    }
    const slice = try items.toOwnedSlice(p.arena);
    return .{ .sequence = .{
        .span = .{ .start = slice[0].span().start, .end = slice[slice.len - 1].span().end },
        .expressions = slice,
    } };
}

/// Public entry to AssignmentExpression. Used by the parser when consuming
/// a context that excludes the comma operator (e.g. function arguments,
/// VariableDeclarator initializers, ConditionalExpression branches).
pub fn parseAssignmentEntry(p: *Parser) ParseError!Expression {
    return parseAssignment(p);
}

/// Public entry to LeftHandSideExpression. Used in `class A extends X`
/// where the heritage clause is a LeftHandSideExpression (no comma, no
/// assignment, no conditional).
pub fn parseLeftHandSideEntry(p: *Parser) ParseError!Expression {
    return parseLeftHandSide(p);
}

/// §13.15 AssignmentExpression. Right-associative. Includes plain `=`,
/// all compound assignments, and §15.3 ArrowFunction at the top.
///
/// Arrow detection uses two strategies:
/// • Simple lookahead: `Identifier =>` or `() =>` are unambiguous.
/// • Reinterpretation: parse the prefix as a regular expression first;
/// if `=>` follows immediately (no LineTerminator), reshape the
/// parenthesized-or-identifier head into ArrowParameters. This is
/// the spec's `CoverParenthesizedExpressionAndArrowParameterList`
/// trick implemented post hoc.
fn parseAssignment(p: *Parser) ParseError!Expression {
    // §15.5.4: `yield` is a YieldExpression at AssignmentExpression level
    // when inside a generator body. Cynic is strict-only so `yield` is
    // always tokenized as `kw_yield`.
    if (p.in_generator and p.peek().kind == .kw_yield) {
        return parseYieldExpression(p);
    }

    // §15.9: `async` followed (no LineTerminator) by an identifier
    // and then `=>` opens an async arrow. This must be handled here
    // because arrows are AssignmentExpressions, not LeftHandSide. The
    // `async (... ) =>` case is handled post-hoc by reinterpreting a
    // Call whose callee is `async` once the following `=>` is observed.
    // (The `async function` form is recognised inside parsePrimary so
    // that the resulting expression can flow through the LeftHandSide
    // chain — calls, member access, tagged templates.)
    if (p.peek().kind == .identifier and std.mem.eql(u8, p.peek().slice(p.source), "async")) {
        const second = try p.peek2();
        if (!second.line_terminator_before and second.kind == .identifier) {
            return parseAsyncBareIdentArrow(p);
        }
    }

    // Fast path 1: bare-identifier arrow `x => …`.
    if (p.peek().kind == .identifier) {
        const second = try p.peek2();
        if (second.kind == .arrow and !second.line_terminator_before) {
            return parseArrowFromBareIdent(p);
        }
    }
    // Fast path 2: empty-parameter arrow `() => …`.
    if (p.peek().kind == .lparen) {
        const second = try p.peek2();
        if (second.kind == .rparen) {
            return parseArrowFromEmptyParens(p);
        }
    }

    const lhs = try parseConditional(p);

    // Reinterpretation path: `(...) =>` where the parenthesized expression
    // turns out to be an arrow parameter list. Async-prefixed: `async(...)`
    // parsed as a call to `async` is reinterpreted as an async arrow.
    if (p.peek().kind == .arrow and !p.peek().line_terminator_before) {
        if (asyncCallToReinterpret(p, lhs)) |c| {
            return reinterpretCallAsAsyncArrow(p, c);
        }
        return reinterpretLhsAsArrow(p, lhs);
    }

    if (ast_expr.AssignmentOp.fromToken(p.peek().kind)) |op| {
        const op_tok = try p.bump();
        if (op == .eq) {
            // §13.15.2: LHS of `=` may be a DestructuringAssignmentTarget
            // (array/object pattern, parsed as a literal and reinterpreted
            // at runtime/codegen) in addition to a SimpleAssignmentTarget.
            if (!isSimpleAssignmentTarget(lhs) and !isAssignmentPattern(lhs)) {
                try p.report(.assignment_target_invalid, lhs.span());
            }
        } else {
            // §13.15.3: compound assignments allow only SimpleAssignmentTarget.
            if (!isSimpleAssignmentTarget(lhs)) {
                try p.report(.assignment_target_invalid, lhs.span());
            }
        }
        // §13.15.1 Early Error: in strict mode, the LeftHandSideExpression of
        // an Assignment / CompoundAssignment may not be the IdentifierReference
        // `eval` or `arguments`. Cynic is strict-only, so the rule always fires.
        if (isEvalOrArgumentsRef(lhs, p.source)) {
            try p.report(.assignment_target_invalid, lhs.span());
        }
        const rhs = try parseAssignment(p);
        const lhs_ptr = try p.arena.create(Expression);
        lhs_ptr.* = lhs;
        const rhs_ptr = try p.arena.create(Expression);
        rhs_ptr.* = rhs;
        _ = op_tok;
        return .{ .assignment = .{
            .span = .{ .start = lhs_ptr.span().start, .end = rhs_ptr.span().end },
            .op = op,
            .target = lhs_ptr,
            .value = rhs_ptr,
        } };
    }
    return lhs;
}

fn parseArrowFromBareIdent(p: *Parser) ParseError!Expression {
    const ident_tok = try p.bump();
    _ = try p.bump(); // `=>`
    var params: std.ArrayListUnmanaged(@import("../ast/statement.zig").FunctionParam) = .empty;
    try params.append(p.arena, .{ .simple = .{
        .span = ident_tok.span,
        .target = .{ .identifier = .{ .span = ident_tok.span } },
        .default = null,
    } });
    const body = try parseConciseBody(p, false);
    return buildArrow(p, ident_tok.span.start, params.items, body, false);
}

/// `async name => body` — async arrow with a single bare-identifier
/// parameter. The caller has verified `peek=async`, `peek2=identifier`,
/// no LF before the identifier.
fn parseAsyncBareIdentArrow(p: *Parser) ParseError!Expression {
    const async_tok = try p.bump(); // `async`
    const name_tok = try p.bump(); // the identifier
    if (p.peek().kind != .arrow or p.peek().line_terminator_before) {
        try p.report(.unexpected_token, p.peek().span);
        return error.ParseError;
    }
    _ = try p.bump(); // `=>`
    var params: std.ArrayListUnmanaged(@import("../ast/statement.zig").FunctionParam) = .empty;
    try params.append(p.arena, .{ .simple = .{
        .span = name_tok.span,
        .target = .{ .identifier = .{ .span = name_tok.span } },
        .default = null,
    } });
    const body = try parseConciseBody(p, true);
    return buildArrow(p, async_tok.span.start, params.items, body, true);
}

fn parseArrowFromEmptyParens(p: *Parser) ParseError!Expression {
    const lparen = try p.bump();
    _ = try p.bump(); // `)`
    if (p.peek().kind != .arrow or p.peek().line_terminator_before) {
        try p.report(.unexpected_token, p.peek().span);
        return error.ParseError;
    }
    _ = try p.bump(); // `=>`
    const body = try parseConciseBody(p, false);
    return buildArrow(p, lparen.span.start, &.{}, body, false);
}

fn reinterpretLhsAsArrow(p: *Parser, lhs: Expression) ParseError!Expression {
    _ = try p.bump(); // `=>`
    var params: std.ArrayListUnmanaged(@import("../ast/statement.zig").FunctionParam) = .empty;
    try collectArrowParams(p, lhs, &params);
    const body = try parseConciseBody(p, false);
    return buildArrow(p, lhs.span().start, try params.toOwnedSlice(p.arena), body, false);
}

/// True if `lhs` is `async(...)` (a Call whose callee is the
/// IdentifierReference `async`) — the cover form for async arrows with
/// parenthesized parameter lists.
fn asyncCallToReinterpret(p: *Parser, lhs: Expression) ?ast_expr.CallExpr {
    if (lhs != .call) return null;
    const c = lhs.call;
    if (c.optional) return null;
    if (c.callee.* != .identifier_reference) return null;
    const ref = c.callee.identifier_reference;
    const text = p.source[ref.span.start..ref.span.end];
    if (!std.mem.eql(u8, text, "async")) return null;
    return c;
}

fn reinterpretCallAsAsyncArrow(p: *Parser, c: ast_expr.CallExpr) ParseError!Expression {
    _ = try p.bump(); // `=>`
    var params: std.ArrayListUnmanaged(@import("../ast/statement.zig").FunctionParam) = .empty;
    for (c.arguments) |arg| {
        try collectArrowParams(p, arg, &params);
    }
    const body = try parseConciseBody(p, true);
    return buildArrow(p, c.callee.span().start, try params.toOwnedSlice(p.arena), body, true);
}

fn buildArrow(
    p: *Parser,
    start: u32,
    params: []@import("../ast/statement.zig").FunctionParam,
    body: ast_expr.ArrowBody,
    is_async: bool,
) ParseError!Expression {
    const owned = if (@TypeOf(params) == []const @import("../ast/statement.zig").FunctionParam)
        try p.arena.dupe(@import("../ast/statement.zig").FunctionParam, params)
    else
        params;
    const end = switch (body) {
        .block => |b| b.span.end,
        .expression => |e| e.span().end,
    };
    // §15.3.1: an arrow with non-simple params may not have a
    // `"use strict"` directive in its body. Only block-bodied arrows
    // can have a directive prologue at all.
    if (body == .block) {
        try parser_mod.enforceStrictDirectiveSimplicity(p, owned, body.block.body, body.block.span);
    }
    return .{ .arrow_function = .{
        .span = .{ .start = start, .end = end },
        .params = owned,
        .body = body,
        .is_async = is_async,
    } };
}

fn parseConciseBody(p: *Parser, is_async: bool) ParseError!ast_expr.ArrowBody {
    // §15.3: arrow function bodies have `[~Yield]` and `[Await]` set per
    // the arrow's own asyncness — not inherited from the enclosing scope.
    const saved_gen = p.in_generator;
    const saved_async = p.in_async;
    const saved_in_function = p.in_function;
    p.in_generator = false;
    p.in_async = is_async;
    p.in_function = true;
    defer {
        p.in_generator = saved_gen;
        p.in_async = saved_async;
        p.in_function = saved_in_function;
    }
    if (p.peek().kind == .lbrace) {
        const block = try p.parseBlockStatementInner();
        parser_mod.tagDirectivePrologue(block.body);
        return .{ .block = block };
    }
    const e = try parseAssignment(p);
    const e_ptr = try p.arena.create(Expression);
    e_ptr.* = e;
    return .{ .expression = e_ptr };
}

/// §15.5.4 YieldExpression. Restricted production: `yield [no LF] expr`.
/// `yield` alone (no operand) is permitted before any token that cannot
/// start an AssignmentExpression — terminators, closing brackets, comma,
/// or a LineTerminator.
fn parseYieldExpression(p: *Parser) ParseError!Expression {
    const yield_tok = try p.bump();
    std.debug.assert(yield_tok.kind == .kw_yield);

    // Check for an immediate operand. `yield` followed by `;`, `}`, `)`,
    // `]`, `,`, `:`, EOF, or a LineTerminator has no operand.
    const next = p.peek();
    if (next.line_terminator_before or isYieldOperandTerminator(next.kind)) {
        return .{ .yield = .{
            .span = yield_tok.span,
            .argument = null,
            .delegate = false,
        } };
    }

    const delegate = try p.eat(.star);
    const arg = try parseAssignment(p);
    const arg_ptr = try p.arena.create(Expression);
    arg_ptr.* = arg;
    return .{ .yield = .{
        .span = .{ .start = yield_tok.span.start, .end = arg.span().end },
        .argument = arg_ptr,
        .delegate = delegate,
    } };
}

fn isYieldOperandTerminator(kind: TokenKind) bool {
    return switch (kind) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace, .colon, .eof => true,
        else => false,
    };
}

fn collectArrowParams(
    p: *Parser,
    e: Expression,
    out: *std.ArrayListUnmanaged(@import("../ast/statement.zig").FunctionParam),
) ParseError!void {
    const stmt_mod = @import("../ast/statement.zig");
    switch (e) {
        .parenthesized => |paren| try collectArrowParams(p, paren.expression.*, out),
        .sequence => |seq| {
            for (seq.expressions) |item| {
                try collectArrowParams(p, item, out);
            }
        },
        .identifier_reference => |ir| {
            try out.append(p.arena, .{ .simple = .{
                .span = ir.span,
                .target = .{ .identifier = .{ .span = ir.span } },
                .default = null,
            } });
        },
        .assignment => |a| {
            if (a.op != .eq) {
                try p.report(.unexpected_token, a.span);
                return error.ParseError;
            }
            const target = try expressionAsBindingTarget(p, a.target.*);
            try out.append(p.arena, .{ .simple = .{
                .span = a.span,
                .target = target,
                .default = a.value.*,
            } });
        },
        .array_literal, .object_literal => {
            // Reinterpret an array/object literal that turned out to be an
            // arrow parameter pattern.
            const target = try expressionAsBindingTarget(p, e);
            try out.append(p.arena, .{ .simple = .{
                .span = e.span(),
                .target = target,
                .default = null,
            } });
        },
        .spread => |sp| {
            // `(...rest) =>` — the parenthesized expression contained a
            // top-level spread element.
            const target = try expressionAsBindingTarget(p, sp.argument.*);
            try out.append(p.arena, .{ .rest = .{
                .span = sp.span,
                .target = target,
            } });
        },
        else => {
            try p.report(.unexpected_token, e.span());
            return error.ParseError;
        },
    }
    _ = stmt_mod;
}

/// Convert an Expression-shape into the corresponding BindingTarget.
/// Used by the arrow-function reinterpretation path. Bails to a
/// SyntaxError on anything not a valid pattern.
fn expressionAsBindingTarget(
    p: *Parser,
    e: Expression,
) ParseError!@import("../ast/statement.zig").BindingTarget {
    const stmt_mod = @import("../ast/statement.zig");
    switch (e) {
        .identifier_reference => |ir| return .{ .identifier = .{ .span = ir.span } },
        .parenthesized => |paren| return expressionAsBindingTarget(p, paren.expression.*),
        .array_literal => |al| {
            var elements: std.ArrayListUnmanaged(?stmt_mod.BindingElement) = .empty;
            var rest: ?*stmt_mod.BindingTarget = null;
            for (al.elements) |maybe_elt| {
                if (maybe_elt) |elt| {
                    switch (elt) {
                        .spread => |sp| {
                            const r = try expressionAsBindingTarget(p, sp.argument.*);
                            const ptr = try p.arena.create(stmt_mod.BindingTarget);
                            ptr.* = r;
                            rest = ptr;
                        },
                        else => {
                            const be = try expressionAsBindingElement(p, elt);
                            try elements.append(p.arena, be);
                        },
                    }
                } else {
                    try elements.append(p.arena, null);
                }
            }
            return .{ .array = .{
                .span = al.span,
                .elements = try elements.toOwnedSlice(p.arena),
                .rest = rest,
            } };
        },
        .object_literal => |ol| {
            var props: std.ArrayListUnmanaged(stmt_mod.ObjectPatternProperty) = .empty;
            var rest: ?stmt_mod.BindingIdentifier = null;
            for (ol.properties) |m| {
                switch (m) {
                    .property => |op| {
                        const value: stmt_mod.BindingElement = if (op.shorthand)
                            // Shorthand: value is identifier_reference;
                            // becomes the same name as the key.
                            switch (op.value) {
                                .identifier_reference => |ir| .{
                                    .span = ir.span,
                                    .target = .{ .identifier = .{ .span = ir.span } },
                                    .default = null,
                                },
                                .assignment => |a| if (a.op == .eq) .{
                                    .span = a.span,
                                    .target = try expressionAsBindingTarget(p, a.target.*),
                                    .default = a.value.*,
                                } else {
                                    try p.report(.unexpected_token, a.span);
                                    return error.ParseError;
                                },
                                else => {
                                    try p.report(.unexpected_token, op.value.span());
                                    return error.ParseError;
                                },
                            }
                        else
                            try expressionAsBindingElement(p, op.value);
                        try props.append(p.arena, .{
                            .span = op.span,
                            .key = op.key,
                            .value = value,
                            .shorthand = op.shorthand,
                        });
                    },
                    .spread => |sp| {
                        switch (sp.argument.*) {
                            .identifier_reference => |ir| {
                                rest = .{ .span = ir.span };
                            },
                            else => {
                                try p.report(.unexpected_token, sp.span);
                                return error.ParseError;
                            },
                        }
                    },
                    .method => |md| {
                        // A method definition is not a valid pattern element.
                        try p.report(.unexpected_token, md.span);
                        return error.ParseError;
                    },
                }
            }
            return .{ .object = .{
                .span = ol.span,
                .properties = try props.toOwnedSlice(p.arena),
                .rest = rest,
            } };
        },
        else => {
            try p.report(.unexpected_token, e.span());
            return error.ParseError;
        },
    }
}

fn expressionAsBindingElement(
    p: *Parser,
    e: Expression,
) ParseError!@import("../ast/statement.zig").BindingElement {
    switch (e) {
        .assignment => |a| if (a.op == .eq) return .{
            .span = a.span,
            .target = try expressionAsBindingTarget(p, a.target.*),
            .default = a.value.*,
        } else {
            try p.report(.unexpected_token, a.span);
            return error.ParseError;
        },
        else => {
            const target = try expressionAsBindingTarget(p, e);
            return .{
                .span = target.span(),
                .target = target,
                .default = null,
            };
        },
    }
}

/// §13.15.1 SimpleAssignmentTarget. IdentifierReference and MemberExpression
/// (including computed and optional-chained property access — though the
/// optional form is rejected at runtime for assignment) qualify. A
/// ParenthesizedExpression around a SimpleAssignmentTarget is also valid
/// (transparent unwrap).
fn isSimpleAssignmentTarget(e: Expression) bool {
    return switch (e) {
        .identifier_reference => true,
        .member => true,
        .parenthesized => |p| isSimpleAssignmentTarget(p.expression.*),
        else => false,
    };
}

/// §13.15.5 DestructuringAssignmentTarget. The LHS of `=` may be an
/// ArrayLiteral or ObjectLiteral; the parser leaves them as their
/// expression shape and downstream consumers reinterpret as patterns.
fn isAssignmentPattern(e: Expression) bool {
    return switch (e) {
        .array_literal, .object_literal => true,
        .parenthesized => |p| isAssignmentPattern(p.expression.*),
        else => false,
    };
}

/// §13.14 ConditionalExpression. Right-associative.
fn parseConditional(p: *Parser) ParseError!Expression {
    const test_expr = try parseShortCircuit(p, lowest_logical_prec);
    if (p.peek().kind != .question) return test_expr;
    _ = try p.bump();
    const consequent = try parseAssignment(p);
    _ = try p.expect(.colon);
    const alternate = try parseAssignment(p);
    const test_ptr = try p.arena.create(Expression);
    test_ptr.* = test_expr;
    const cons_ptr = try p.arena.create(Expression);
    cons_ptr.* = consequent;
    const alt_ptr = try p.arena.create(Expression);
    alt_ptr.* = alternate;
    return .{ .conditional = .{
        .span = .{ .start = test_ptr.span().start, .end = alt_ptr.span().end },
        .test_ = test_ptr,
        .consequent = cons_ptr,
        .alternate = alt_ptr,
    } };
}

/// §13.13 ShortCircuitExpression — Pratt-style for `&&`, `||`, `??`. The
/// "no mixing without parens" rule (`a && b ?? c` SyntaxError) is enforced
/// at node-construction time by inspecting whether either child is a
/// non-parenthesized Logical with an incompatible operator.
fn parseShortCircuit(p: *Parser, min_prec: u8) ParseError!Expression {
    var lhs = try parseBinary(p, lowest_binary_prec);
    while (true) {
        const tok = p.peek();
        const info = logicalPrec(tok.kind) orelse break;
        if (info.prec < min_prec) break;
        const op_tok = try p.bump();
        const op = ast_expr.LogicalOp.fromToken(op_tok.kind).?;
        const rhs = try parseShortCircuit(p, info.prec + 1);
        try checkLogicalMixing(p, op, lhs);
        try checkLogicalMixing(p, op, rhs);
        const lhs_ptr = try p.arena.create(Expression);
        lhs_ptr.* = lhs;
        const rhs_ptr = try p.arena.create(Expression);
        rhs_ptr.* = rhs;
        lhs = .{ .logical = .{
            .span = .{ .start = lhs_ptr.span().start, .end = rhs_ptr.span().end },
            .op = op,
            .lhs = lhs_ptr,
            .rhs = rhs_ptr,
        } };
    }
    return lhs;
}

const lowest_logical_prec: u8 = 4;

fn logicalPrec(kind: TokenKind) ?BinaryInfo {
    return switch (kind) {
        .pipe_pipe, .question_question => .{ .prec = 4, .right_assoc = false },
        .amp_amp => .{ .prec = 5, .right_assoc = false },
        else => null,
    };
}

fn checkLogicalMixing(p: *Parser, outer: ast_expr.LogicalOp, child: Expression) ParseError!void {
    const inner = switch (child) {
        .logical => |l| l.op,
        else => return,
    };
    const incompatible = switch (outer) {
        .nullish => inner == .and_and or inner == .or_or,
        .and_and, .or_or => inner == .nullish,
    };
    if (incompatible) {
        try p.report(.mixed_logical_operators, child.span());
    }
}

/// Pratt-style precedence climber for the binary-operator productions
/// §13.6–§13.12 (exponentiation through bitwise OR). Logical operators are
/// handled at a higher level (a different production) to enforce the §13.13
/// "no mixing without parens" rule.
fn parseBinary(p: *Parser, min_prec: u8) ParseError!Expression {
    var lhs = try parseUnary(p);
    while (true) {
        const tok = p.peek();
        const info = binaryPrec(tok.kind, p.allow_in) orelse break;
        if (info.prec < min_prec) break;
        _ = try p.bump();
        const next_min: u8 = if (info.right_assoc) info.prec else info.prec + 1;
        const rhs = try parseBinary(p, next_min);
        const op = ast_expr.BinaryOp.fromToken(tok.kind).?;
        const lhs_ptr = try p.arena.create(Expression);
        lhs_ptr.* = lhs;
        const rhs_ptr = try p.arena.create(Expression);
        rhs_ptr.* = rhs;
        lhs = .{ .binary = .{
            .span = .{ .start = lhs_ptr.span().start, .end = rhs_ptr.span().end },
            .op = op,
            .lhs = lhs_ptr,
            .rhs = rhs_ptr,
        } };
    }
    return lhs;
}

const BinaryInfo = struct { prec: u8, right_assoc: bool };

const lowest_binary_prec: u8 = 6;

fn binaryPrec(kind: TokenKind, allow_in: bool) ?BinaryInfo {
    return switch (kind) {
        .pipe => .{ .prec = 6, .right_assoc = false },
        .caret => .{ .prec = 7, .right_assoc = false },
        .amp => .{ .prec = 8, .right_assoc = false },
        .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => .{ .prec = 9, .right_assoc = false },
        .lt, .le, .gt, .ge, .kw_instanceof => .{ .prec = 10, .right_assoc = false },
        .kw_in => if (allow_in) .{ .prec = 10, .right_assoc = false } else null,
        .lt_lt, .gt_gt, .gt_gt_gt => .{ .prec = 11, .right_assoc = false },
        .plus, .minus => .{ .prec = 12, .right_assoc = false },
        .star, .slash, .percent => .{ .prec = 13, .right_assoc = false },
        .star_star => .{ .prec = 14, .right_assoc = true },
        else => null,
    };
}

/// §13.5 UnaryExpression. Right-recursive: the operand of a unary is itself
/// a UnaryExpression, so `!!x` and `typeof void 0` parse cleanly. §13.4
/// UpdateExpression's prefix forms (`++x`, `--x`) sit at this level too.
/// §15.8.2 AwaitExpression also lives at this level when `[+Await]`.
fn parseUnary(p: *Parser) ParseError!Expression {
    const tok = p.peek();
    if (p.in_async and tok.kind == .kw_await) {
        _ = try p.bump();
        const operand = try parseUnary(p);
        const operand_ptr = try p.arena.create(Expression);
        operand_ptr.* = operand;
        return .{ .await_ = .{
            .span = .{ .start = tok.span.start, .end = operand.span().end },
            .argument = operand_ptr,
        } };
    }
    if (ast_expr.UpdateOp.fromToken(tok.kind)) |op| {
        _ = try p.bump();
        const operand = try parseUnary(p);
        if (!isSimpleAssignmentTarget(operand)) {
            try p.report(.assignment_target_invalid, operand.span());
        }
        // §13.4.1 Early Error: in strict mode, the operand of a prefix
        // UpdateExpression may not be the IdentifierReference `eval` or
        // `arguments`. Cynic is strict-only.
        if (isEvalOrArgumentsRef(operand, p.source)) {
            try p.report(.assignment_target_invalid, operand.span());
        }
        const operand_ptr = try p.arena.create(Expression);
        operand_ptr.* = operand;
        return .{ .update = .{
            .span = .{ .start = tok.span.start, .end = operand.span().end },
            .op = op,
            .operand = operand_ptr,
            .prefix = true,
        } };
    }
    if (ast_expr.UnaryOp.fromToken(tok.kind)) |op| {
        _ = try p.bump();
        const operand = try parseUnary(p);
        // §13.5.1.1 Early Error: in strict mode, `delete` of a bare
        // IdentifierReference is a SyntaxError. The check looks through
        // any redundant parentheses.
        if (op == .delete_ and isBareIdentifierReference(operand)) {
            try p.report(.delete_of_unqualified_identifier, .{
                .start = tok.span.start,
                .end = operand.span().end,
            });
        }
        // §13.5.1.1 Early Error: delete of `MemberExpression.PrivateName`
        // or `CallExpression.PrivateName` is a SyntaxError. Through
        // CoverParenthesizedExpressionAndArrowParameterList the rule
        // applies recursively, so peel parens (and the optional-chain
        // wrapper) before testing the property kind.
        if (op == .delete_ and deleteOperandIsPrivateName(operand, p.source)) {
            try p.report(.delete_of_private_name, .{
                .start = tok.span.start,
                .end = operand.span().end,
            });
        }
        const operand_ptr = try p.arena.create(Expression);
        operand_ptr.* = operand;
        return .{ .unary = .{
            .span = .{ .start = tok.span.start, .end = operand.span().end },
            .op = op,
            .operand = operand_ptr,
        } };
    }
    // Postfix `x++` / `x--` (§13.4) attaches at the LeftHandSide level,
    // gated by ASI rule 2 (no LineTerminator between LHS and `++`/`--`).
    const lhs = try parseLeftHandSide(p);
    const next = p.peek();
    if (!next.line_terminator_before) {
        if (ast_expr.UpdateOp.fromToken(next.kind)) |op| {
            const op_tok = try p.bump();
            if (!isSimpleAssignmentTarget(lhs)) {
                try p.report(.assignment_target_invalid, lhs.span());
            }
            // §13.4.1 Early Error: postfix `eval++` / `arguments--` etc. are
            // strict-mode SyntaxErrors. Cynic is strict-only.
            if (isEvalOrArgumentsRef(lhs, p.source)) {
                try p.report(.assignment_target_invalid, lhs.span());
            }
            const operand_ptr = try p.arena.create(Expression);
            operand_ptr.* = lhs;
            return .{ .update = .{
                .span = .{ .start = lhs.span().start, .end = op_tok.span.end },
                .op = op,
                .operand = operand_ptr,
                .prefix = false,
            } };
        }
    }
    return lhs;
}

/// §13.3 LeftHandSideExpression — extends a PrimaryExpression with
/// member access (`.ident`, `[expr]`, `.#priv`), function/method calls,
/// `new`, optional chaining, and tagged templates. If any `?.` was seen,
/// the result is wrapped in a `chain` node — that wrapper bounds the
/// short-circuit at the closing of the chain (parentheses end it).
fn parseLeftHandSide(p: *Parser) ParseError!Expression {
    var base = if (p.peek().kind == .kw_new)
        try parseNewExpression(p)
    else
        try parsePrimary(p);
    var saw_optional = false;
    while (true) {
        const kind = p.peek().kind;
        switch (kind) {
            .dot => base = try parseDotMember(p, base, false),
            .lbracket => base = try parseComputedMember(p, base, false),
            .lparen => base = try parseCallTail(p, base, false),
            .no_substitution_template, .template_head => base = try parseTaggedTemplate(p, base),
            .optional_chain => {
                _ = try p.bump();
                saw_optional = true;
                switch (p.peek().kind) {
                    .lparen => base = try parseCallTail(p, base, true),
                    .lbracket => base = try parseComputedMember(p, base, true),
                    else => base = try parseMemberPropertyOnly(p, base, true),
                }
            },
            else => break,
        }
    }
    if (saw_optional) {
        const inner = try p.arena.create(Expression);
        inner.* = base;
        return .{ .chain = .{
            .span = inner.span(),
            .expression = inner,
        } };
    }
    return base;
}

/// §13.3.11 TaggedTemplate. The tag is the LeftHandSideExpression on the
/// left; immediately following template tokens (no_substitution_template
/// or template_head) form the quasi.
fn parseTaggedTemplate(p: *Parser, tag: Expression) ParseError!Expression {
    const quasi = try parseTemplateLiteral(p);
    const tag_ptr = try p.arena.create(Expression);
    tag_ptr.* = tag;
    const quasi_ptr = try p.arena.create(Expression);
    quasi_ptr.* = quasi;
    return .{ .tagged_template = .{
        .span = .{ .start = tag_ptr.span().start, .end = quasi.span().end },
        .tag = tag_ptr,
        .quasi = quasi_ptr,
    } };
}

/// §13.3 NewExpression / `new MemberExpression Arguments`. The trailing
/// argument list, when present, belongs to this `new`; subsequent `(args)`
/// in the broader chain are calls on the constructed value.
fn parseNewExpression(p: *Parser) ParseError!Expression {
    const new_tok = try p.bump();
    std.debug.assert(new_tok.kind == .kw_new);

    // §13.3.1 NewTarget MetaProperty: `new. target`. Detected immediately
    // after the `new` keyword. Anything else continues as a NewExpression.
    if (p.peek().kind == .dot) {
        const next = try p.peek2();
        if (next.kind == .identifier and std.mem.eql(u8, next.slice(p.source), "target")) {
            _ = try p.bump(); // `.`
            const target_tok = try p.bump(); // `target`
            // §15.7.1 early error: `new.target` is only allowed
            // inside a function body (any flavour) or a class
            // body. Top-level Script / Module use is a SyntaxError.
            if (!p.in_function) {
                try p.report(.unexpected_token, .{ .start = new_tok.span.start, .end = target_tok.span.end });
                return error.ParseError;
            }
            return .{ .new_target = .{
                .span = .{ .start = new_tok.span.start, .end = target_tok.span.end },
            } };
        }
    }

    // Callee: `new` (recursively) or a PrimaryExpression, then extended
    // with `.ident` / `[expr]` only — calls bind to *this* `new`, not the
    // callee.
    var callee = if (p.peek().kind == .kw_new)
        try parseNewExpression(p)
    else
        try parsePrimary(p);
    while (true) {
        switch (p.peek().kind) {
            .dot => callee = try parseDotMember(p, callee, false),
            .lbracket => callee = try parseComputedMember(p, callee, false),
            else => break,
        }
    }

    var args: []Expression = &.{};
    var end = callee.span().end;
    if (p.peek().kind == .lparen) {
        const result = try parseArguments(p);
        args = result.args;
        end = result.end;
    }

    const callee_ptr = try p.arena.create(Expression);
    callee_ptr.* = callee;
    return .{ .new_expr = .{
        .span = .{ .start = new_tok.span.start, .end = end },
        .callee = callee_ptr,
        .arguments = args,
    } };
}

fn parseCallTail(p: *Parser, callee: Expression, optional: bool) ParseError!Expression {
    const callee_ptr = try p.arena.create(Expression);
    callee_ptr.* = callee;
    const args_end = try parseArguments(p);
    return .{ .call = .{
        .span = .{ .start = callee_ptr.span().start, .end = args_end.end },
        .callee = callee_ptr,
        .arguments = args_end.args,
        .optional = optional,
    } };
}

const ArgsResult = struct { args: []Expression, end: u32 };

/// §13.3 Arguments. Caller is positioned at `(`. Trailing comma is allowed.
fn parseArguments(p: *Parser) ParseError!ArgsResult {
    _ = try p.expect(.lparen);
    var items: std.ArrayListUnmanaged(Expression) = .empty;
    while (p.peek().kind != .rparen and p.peek().kind != .eof) {
        if (p.peek().kind == .ellipsis) {
            const dots = try p.bump();
            const arg = try parseAssignment(p);
            const arg_ptr = try p.arena.create(Expression);
            arg_ptr.* = arg;
            try items.append(p.arena, .{ .spread = .{
                .span = .{ .start = dots.span.start, .end = arg.span().end },
                .argument = arg_ptr,
            } });
        } else {
            const arg = try parseAssignment(p);
            try items.append(p.arena, arg);
        }
        if (p.peek().kind != .comma) break;
        _ = try p.bump();
    }
    const rparen = try p.expect(.rparen);
    return .{
        .args = try items.toOwnedSlice(p.arena),
        .end = rparen.span.end,
    };
}

fn parseDotMember(p: *Parser, base: Expression, optional: bool) ParseError!Expression {
    _ = try p.bump(); // `.`
    return parseMemberPropertyOnly(p, base, optional);
}

/// Like `parseDotMember` but assumes the leading punctuator (`.` or `?.`)
/// has already been consumed. Used by the optional-chain dispatcher.
fn parseMemberPropertyOnly(p: *Parser, base: Expression, optional: bool) ParseError!Expression {
    const prop = try expectPropertyName(p);
    const obj_ptr = try p.arena.create(Expression);
    obj_ptr.* = base;
    return .{ .member = .{
        .span = .{ .start = obj_ptr.span().start, .end = prop.span.end },
        .object = obj_ptr,
        .property = .{ .ident = prop.span },
        .optional = optional,
    } };
}

fn parseComputedMember(p: *Parser, base: Expression, optional: bool) ParseError!Expression {
    _ = try p.bump(); // `[`
    const key = try parseExpression(p);
    const rbracket = try p.expect(.rbracket);
    const obj_ptr = try p.arena.create(Expression);
    obj_ptr.* = base;
    const key_ptr = try p.arena.create(Expression);
    key_ptr.* = key;
    return .{ .member = .{
        .span = .{ .start = obj_ptr.span().start, .end = rbracket.span.end },
        .object = obj_ptr,
        .property = .{ .computed = key_ptr },
        .optional = optional,
    } };
}

/// Consume an `IdentifierName` (any identifier-shaped token, *including*
/// reserved words) or a `PrivateIdentifier`. Used in property-name
/// position after `.` per §12.7 / §13.3.
fn expectPropertyName(p: *Parser) ParseError!token_mod.Token {
    const tok = p.peek();
    if (isIdentifierNameOrPrivate(tok.kind)) {
        return try p.bump();
    }
    try p.report(.unexpected_token, tok.span);
    return error.ParseError;
}

fn isIdentifierNameOrPrivate(kind: TokenKind) bool {
    return switch (kind) {
        .identifier, .private_identifier => true,
        else => @intFromEnum(kind) >= @intFromEnum(TokenKind.kw_await),
    };
}

fn isBareIdentifierReference(e: Expression) bool {
    return switch (e) {
        .identifier_reference => true,
        .parenthesized => |p| isBareIdentifierReference(p.expression.*),
        else => false,
    };
}

/// §13.15.1, §13.4.1 Early Error helper: returns true when `e` is the bare
/// IdentifierReference `eval` or `arguments` (peeling redundant parens via
/// CoverParenthesizedExpressionAndArrowParameterList). Cynic is strict-only,
/// so callers don't gate on a strict flag.
fn isEvalOrArgumentsRef(e: Expression, source: []const u8) bool {
    return switch (e) {
        .identifier_reference => |id| blk: {
            if (id.span.end > source.len) break :blk false;
            const name = source[id.span.start..id.span.end];
            break :blk std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
        },
        .parenthesized => |p| isEvalOrArgumentsRef(p.expression.*, source),
        else => false,
    };
}

/// §13.5.1.1: returns true if `e`, after peeling
/// CoverParenthesizedExpressionAndArrowParameterList wrappers and the
/// optional-chain wrapper, is a MemberExpression whose final property is
/// a PrivateName (its source span starts with `#`). The same shape covers
/// `CallExpression.PrivateName` since that's an AST `member` node whose
/// `object` happens to be a `call`.
fn deleteOperandIsPrivateName(e: Expression, source: []const u8) bool {
    return switch (e) {
        .parenthesized => |paren| deleteOperandIsPrivateName(paren.expression.*, source),
        .chain => |ch| deleteOperandIsPrivateName(ch.expression.*, source),
        .member => |m| switch (m.property) {
            .ident => |id_span| id_span.start < source.len and source[id_span.start] == '#',
            .computed => false,
        },
        else => false,
    };
}

/// §13.2 PrimaryExpression — atoms and grouped expressions.
fn parsePrimary(p: *Parser) ParseError!Expression {
    const tok = p.peek();
    return switch (tok.kind) {
        .kw_null => blk: {
            _ = try p.bump();
            break :blk .{ .null_literal = .{ .span = tok.span } };
        },
        .kw_this => blk: {
            _ = try p.bump();
            break :blk .{ .this_expr = .{ .span = tok.span } };
        },
        .kw_true => blk: {
            _ = try p.bump();
            break :blk .{ .boolean_literal = .{ .span = tok.span, .value = true } };
        },
        .kw_false => blk: {
            _ = try p.bump();
            break :blk .{ .boolean_literal = .{ .span = tok.span, .value = false } };
        },
        .numeric_literal => blk: {
            _ = try p.bump();
            break :blk .{ .numeric_literal = .{ .span = tok.span } };
        },
        .bigint_literal => blk: {
            _ = try p.bump();
            break :blk .{ .bigint_literal = .{ .span = tok.span } };
        },
        .string_literal => blk: {
            _ = try p.bump();
            break :blk .{ .string_literal = .{ .span = tok.span } };
        },
        .identifier => blk: {
            // §15.8 AsyncFunctionExpression — `async function …`. The
            // `async` token here is a contextual keyword (lexed as a
            // plain identifier); `function` must follow on the same
            // line. Recognising it at PrimaryExpression level lets the
            // result flow through parseLeftHandSide for calls, member
            // access, and tagged templates.
            if (std.mem.eql(u8, tok.slice(p.source), "async")) {
                const second = try p.peek2();
                if (!second.line_terminator_before and second.kind == .kw_function) {
                    const start = tok.span.start;
                    _ = try p.bump(); // consume `async`
                    break :blk try parseFunctionExpressionAt(p, start, true);
                }
            }
            _ = try p.bump();
            // §12.7.1: an IdentifierReference whose source contains
            // `\u` escapes and whose StringValue is a ReservedWord is
            // an early SyntaxError. (Property names are read elsewhere
            // and are unaffected.)
            if (tok.had_escape) {
                try p.report(.escape_in_reserved_word, tok.span);
            }
            break :blk .{ .identifier_reference = .{ .span = tok.span } };
        },
        .lparen => parseParenthesized(p),
        .no_substitution_template, .template_head => parseTemplateLiteral(p),
        .kw_function => parseFunctionExpression(p),
        .lbracket => parseArrayLiteral(p),
        .lbrace => parseObjectLiteral(p),
        .kw_class => parseClassExpression(p),
        .kw_super => blk: {
            // §13.3.7 early error: `super` (whether `super.x`,
            // `super(...)`, or `super[k]`) is only valid inside
            // a method body. Plain functions and top-level use
            // are SyntaxErrors. Cynic's `in_method` flag is set
            // by class-method / object-method body parsing.
            if (!p.in_method) {
                try p.report(.unexpected_token, p.peek().span);
                return error.ParseError;
            }
            const sup = try p.bump();
            break :blk .{ .super_ = .{ .span = sup.span } };
        },
        .slash, .slash_eq => parseRegexLiteralFromSlash(p),
        .kw_import => parseImportExpression(p),
        else => {
            try p.report(.unexpected_token, tok.span);
            return error.ParseError;
        },
    };
}

/// §13.2.8 TemplateLiteral. The lexer emits four token kinds;
/// `nextTemplateContinuationAfterBrace` is the parser-driven hook that
/// re-enters template scanning after a `${…}` substitution closes.
fn parseTemplateLiteral(p: *Parser) ParseError!Expression {
    const head = try p.bump();
    var quasis: std.ArrayListUnmanaged(ast_expr.TemplateQuasi) = .empty;
    var expressions: std.ArrayListUnmanaged(Expression) = .empty;

    if (head.kind == .no_substitution_template) {
        // `…` — the entire body is one quasi, no substitutions.
        try quasis.append(p.arena, .{ .span = innerQuasiSpan(head) });
        return .{ .template_literal = .{
            .span = head.span,
            .quasis = try quasis.toOwnedSlice(p.arena),
            .expressions = try expressions.toOwnedSlice(p.arena),
        } };
    }

    std.debug.assert(head.kind == .template_head);
    try quasis.append(p.arena, .{ .span = innerQuasiSpan(head) });

    while (true) {
        const expr = try parseExpression(p);
        try expressions.append(p.arena, expr);

        if (p.peek().kind != .rbrace) {
            try p.report(.unexpected_token, p.peek().span);
            return error.ParseError;
        }
        // Don't bump `}` as a regular token. Instead, hand its span start
        // to the lexer's template-continuation hook; the resulting
        // template_middle / template_tail token covers `} … ${` or
        // `} … ` ` ``.
        const brace_tok = p.current;
        const part = p.lexer.nextTemplateContinuationAfterBrace(brace_tok.span.start) catch |err| {
            // `nextTemplateContinuationAfterBrace` already reported the
            // diagnostic on unterminated.
            return mapLexError(err);
        };
        // Replace `current` with the template part. The lexer has advanced
        // past it; the next call to `bump()` will fetch a fresh token from
        // the lexer.
        p.current = part;
        try quasis.append(p.arena, .{ .span = innerQuasiSpan(part) });

        if (part.kind == .template_tail) {
            const last = try p.bump();
            return .{ .template_literal = .{
                .span = .{ .start = head.span.start, .end = last.span.end },
                .quasis = try quasis.toOwnedSlice(p.arena),
                .expressions = try expressions.toOwnedSlice(p.arena),
            } };
        }
        std.debug.assert(part.kind == .template_middle);
        // Consume the middle so the next iteration's parseExpression starts
        // on a fresh token.
        _ = try p.bump();
    }
}

fn mapLexError(err: anytype) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ParseError,
    };
}

/// Span over the *contents* of a template token, excluding the surrounding
/// `` ` ``, `${`, or `}` delimiters.
fn innerQuasiSpan(tok: token_mod.Token) Span {
    const start = tok.span.start + 1; // skip leading ` or }
    var end = tok.span.end - 1; // strip trailing ` (NoSubstitutionTemplate, TemplateTail)
    switch (tok.kind) {
        .template_head, .template_middle => end = tok.span.end - 2, // strip `${`
        else => {},
    }
    return .{ .start = start, .end = end };
}

/// §15.7 ClassExpression.
fn parseClassExpression(p: *Parser) ParseError!Expression {
    const start = p.peek().span.start;
    _ = try p.bump(); // `class`
    var name: ?@import("../ast/statement.zig").BindingIdentifier = null;
    if (p.peek().kind == .identifier) {
        name = try p.parseBindingIdentifier();
    }
    var superclass: ?*Expression = null;
    if (try p.eat(.kw_extends)) {
        const sup = try parseLeftHandSide(p);
        const ptr = try p.arena.create(Expression);
        ptr.* = sup;
        superclass = ptr;
    }
    const body_end = try p.parseClassBody();
    return .{ .class_expr = .{
        .span = .{ .start = start, .end = body_end.end },
        .name = name,
        .superclass = superclass,
        .body = body_end.members,
    } };
}

/// §13.3.10 dynamic `import(specifier)` and §13.3.12.1 `import.meta`.
/// The lexer always tokenizes `import` as `kw_import`; the parser
/// distinguishes the two forms by the token that follows.
fn parseImportExpression(p: *Parser) ParseError!Expression {
    const import_tok = try p.bump();
    if (p.peek().kind == .lparen) {
        _ = try p.bump();
        const arg = try parseAssignment(p);
        // Permit a trailing comma per the import-attributes grammar
        // shape, even though we don't yet model the attribute object.
        _ = try p.eat(.comma);
        const rparen = try p.expect(.rparen);
        const arg_ptr = try p.arena.create(Expression);
        arg_ptr.* = arg;
        return .{ .import_call = .{
            .span = .{ .start = import_tok.span.start, .end = rparen.span.end },
            .source = arg_ptr,
        } };
    }
    if (p.peek().kind == .dot) {
        _ = try p.bump();
        if (p.peek().kind == .identifier and
            std.mem.eql(u8, p.peek().slice(p.source), "meta"))
        {
            const meta_tok = try p.bump();
            return .{ .import_meta = .{
                .span = .{ .start = import_tok.span.start, .end = meta_tok.span.end },
            } };
        }
        try p.report(.unexpected_token, p.peek().span);
        return error.ParseError;
    }
    try p.report(.unexpected_token, p.peek().span);
    return error.ParseError;
}

/// §12.9.5 RegularExpressionLiteral. The parser arrives here when the
/// dispatcher sees `/` or `/=` in PrimaryExpression position — the lexer
/// initially tokenised those as `slash` / `slash_eq`. We instruct the
/// lexer to rewind to the slash and rescan in `InputElementRegExp` mode.
fn parseRegexLiteralFromSlash(p: *Parser) ParseError!Expression {
    const slash_start = p.peek().span.start;
    // Drop the buffered lookahead since rewinding the lexer invalidates it.
    p.lookahead = null;
    const re_tok = p.lexer.rescanAsRegex(slash_start) catch |err| return mapLexError(err);
    p.current = re_tok;
    _ = try p.bump();
    return .{ .regex_literal = .{ .span = re_tok.span } };
}

/// §13.2.4 ArrayLiteral.
fn parseArrayLiteral(p: *Parser) ParseError!Expression {
    const lbracket = try p.bump();
    std.debug.assert(lbracket.kind == .lbracket);
    var elements: std.ArrayListUnmanaged(?Expression) = .empty;
    while (p.peek().kind != .rbracket and p.peek().kind != .eof) {
        if (p.peek().kind == .comma) {
            // Elision: a `,` not preceded by an element.
            try elements.append(p.arena, null);
            _ = try p.bump();
            continue;
        }
        if (p.peek().kind == .ellipsis) {
            const dots = try p.bump();
            const arg = try parseAssignment(p);
            const arg_ptr = try p.arena.create(Expression);
            arg_ptr.* = arg;
            try elements.append(p.arena, .{ .spread = .{
                .span = .{ .start = dots.span.start, .end = arg.span().end },
                .argument = arg_ptr,
            } });
        } else {
            const v = try parseAssignment(p);
            try elements.append(p.arena, v);
        }
        if (p.peek().kind != .comma) break;
        _ = try p.bump();
    }
    const rbracket = try p.expect(.rbracket);
    return .{ .array_literal = .{
        .span = .{ .start = lbracket.span.start, .end = rbracket.span.end },
        .elements = try elements.toOwnedSlice(p.arena),
    } };
}

/// §13.2.5 ObjectLiteral. Supports basic properties (`a: 1`), shorthand
/// (`a`), string/numeric/computed keys, spread (`...rest`), method
/// definitions (`m() {}`), and accessors (`get x() {}`, `set x(v) {}`).
/// Async/generator methods are deferred to subsequent rounds.
fn parseObjectLiteral(p: *Parser) ParseError!Expression {
    const stmt_mod = @import("../ast/statement.zig");
    const lbrace = try p.bump();
    std.debug.assert(lbrace.kind == .lbrace);
    var members: std.ArrayListUnmanaged(ast_expr.ObjectMember) = .empty;
    while (p.peek().kind != .rbrace and p.peek().kind != .eof) {
        if (p.peek().kind == .ellipsis) {
            const dots = try p.bump();
            const arg = try parseAssignment(p);
            const arg_ptr = try p.arena.create(Expression);
            arg_ptr.* = arg;
            try members.append(p.arena, .{ .spread = .{
                .span = .{ .start = dots.span.start, .end = arg.span().end },
                .argument = arg_ptr,
            } });
        } else {
            try parseObjectMember(p, &members, stmt_mod);
        }
        if (p.peek().kind != .comma) break;
        _ = try p.bump();
    }
    const rbrace = try p.expect(.rbrace);
    return .{ .object_literal = .{
        .span = .{ .start = lbrace.span.start, .end = rbrace.span.end },
        .properties = try members.toOwnedSlice(p.arena),
    } };
}

fn parseObjectMember(
    p: *Parser,
    members: *std.ArrayListUnmanaged(ast_expr.ObjectMember),
    comptime stmt_mod: type,
) ParseError!void {
    const start = p.peek().span.start;

    // Detect `async` modifier — `async name() {}` is an async method.
    var is_async = false;
    if (p.peek().kind == .identifier and
        std.mem.eql(u8, p.peek().slice(p.source), "async"))
    {
        const second = try p.peek2();
        if (!second.line_terminator_before and second.kind != .lparen and
            second.kind != .colon and second.kind != .comma and
            second.kind != .rbrace and
            (parser_mod.isPropertyNameStart(second.kind) or second.kind == .star))
        {
            is_async = true;
            _ = try p.bump();
        }
    }

    // Detect generator method shorthand `*method() {}` or `async *foo() {}`.
    const is_generator = try p.eat(.star);

    // Detect getter/setter contextual keywords. Not allowed with async
    // or generator.
    var method_kind: stmt_mod.MethodKind = .method;
    if (!is_async and !is_generator and p.peek().kind == .identifier) {
        const slice_text = p.peek().slice(p.source);
        if (std.mem.eql(u8, slice_text, "get") or std.mem.eql(u8, slice_text, "set")) {
            const second = try p.peek2();
            if (parser_mod.isPropertyNameStart(second.kind)) {
                method_kind = if (slice_text[0] == 'g') .getter else .setter;
                _ = try p.bump();
            }
        }
    }

    const key_tok = p.peek();
    const key_kind = key_tok.kind;
    const key = try parseObjectKey(p);
    const key_is_plain_ident = key_kind == .identifier;

    // Method shorthand: `key(params) { body }`.
    if (p.peek().kind == .lparen) {
        const params = try p.parseFunctionParameters();

        const saved_gen = p.in_generator;
        const saved_async = p.in_async;
        const saved_in_function = p.in_function;
        const saved_in_method = p.in_method;
        p.in_generator = is_generator;
        p.in_async = is_async;
        p.in_function = true;
        p.in_method = true;
        const body = blk: {
            defer {
                p.in_generator = saved_gen;
                p.in_async = saved_async;
                p.in_function = saved_in_function;
                p.in_method = saved_in_method;
            }
            break :blk try p.parseBlockStatementInner();
        };
        parser_mod.tagDirectivePrologue(body.body);
        try members.append(p.arena, .{ .method = .{
            .span = .{ .start = start, .end = body.span.end },
            .kind = method_kind,
            .key = key,
            .params = params,
            .body = body,
            .is_generator = is_generator,
            .is_async = is_async,
        } });
        return;
    }

    if (method_kind != .method or is_generator or is_async) {
        try p.report(.unexpected_token, p.peek().span);
        return error.ParseError;
    }

    // Shorthand: `{ a }` or `{ a = default }` (covered for assignment
    // patterns in cover-grammar contexts). Only for plain identifier keys.
    if (p.peek().kind != .colon) {
        if (!key_is_plain_ident) {
            try p.report(.unexpected_token, p.peek().span);
            return error.ParseError;
        }
        const ident_span = key.ident;
        var value: Expression = .{ .identifier_reference = .{ .span = ident_span } };
        if (try p.eat(.eq)) {
            // `{ a = default }` — only valid as an assignment pattern
            // target. Build a CoverInitializedName as an Assignment node;
            // the cover-grammar reinterpretation later turns it into a
            // pattern with default.
            const default = try parseAssignment(p);
            const lhs_ptr = try p.arena.create(Expression);
            lhs_ptr.* = value;
            const rhs_ptr = try p.arena.create(Expression);
            rhs_ptr.* = default;
            value = .{ .assignment = .{
                .span = .{ .start = ident_span.start, .end = default.span().end },
                .op = .eq,
                .target = lhs_ptr,
                .value = rhs_ptr,
            } };
        }
        try members.append(p.arena, .{ .property = .{
            .span = .{ .start = start, .end = value.span().end },
            .key = key,
            .value = value,
            .shorthand = true,
        } });
        return;
    }

    _ = try p.bump(); // `:`
    const value = try parseAssignment(p);
    try members.append(p.arena, .{ .property = .{
        .span = .{ .start = start, .end = value.span().end },
        .key = key,
        .value = value,
        .shorthand = false,
    } });
}

/// Parse an ObjectLiteral / ClassBody PropertyName. Returns just the key;
/// caller handles what follows (`:`, `(`, etc).
fn parseObjectKey(p: *Parser) ParseError!ast_expr.PropertyKey {
    const tok = p.peek();
    if (tok.kind == .lbracket) {
        _ = try p.bump();
        const inner = try parseAssignment(p);
        _ = try p.expect(.rbracket);
        const ptr = try p.arena.create(Expression);
        ptr.* = inner;
        return .{ .computed = ptr };
    }
    if (tok.kind == .string_literal) {
        _ = try p.bump();
        return .{ .string = tok.span };
    }
    if (tok.kind == .numeric_literal) {
        _ = try p.bump();
        return .{ .numeric = tok.span };
    }
    if (tok.kind == .identifier or @intFromEnum(tok.kind) >= @intFromEnum(TokenKind.kw_await)) {
        _ = try p.bump();
        return .{ .ident = tok.span };
    }
    try p.report(.unexpected_token, tok.span);
    return error.ParseError;
}

fn parseObjectProperty(p: *Parser) ParseError!ast_expr.ObjectProperty {
    const start = p.peek().span.start;
    const key_tok = p.peek();
    var key: ast_expr.PropertyKey = undefined;
    var key_end: u32 = undefined;

    if (key_tok.kind == .lbracket) {
        _ = try p.bump();
        const inner = try parseAssignment(p);
        const rbracket = try p.expect(.rbracket);
        const key_ptr = try p.arena.create(Expression);
        key_ptr.* = inner;
        key = .{ .computed = key_ptr };
        key_end = rbracket.span.end;
    } else if (key_tok.kind == .string_literal) {
        _ = try p.bump();
        key = .{ .string = key_tok.span };
        key_end = key_tok.span.end;
    } else if (key_tok.kind == .numeric_literal) {
        _ = try p.bump();
        key = .{ .numeric = key_tok.span };
        key_end = key_tok.span.end;
    } else if (isIdentifierNameOrPrivate(key_tok.kind) and key_tok.kind != .private_identifier) {
        // IdentifierName key: identifier or any keyword.
        _ = try p.bump();
        key = .{ .ident = key_tok.span };
        key_end = key_tok.span.end;
    } else {
        try p.report(.unexpected_token, key_tok.span);
        return error.ParseError;
    }

    // Shorthand: `{ a }` — only valid when key is an `.ident` whose span
    // matches an Identifier (not a keyword), and no `:` follows.
    if (p.peek().kind != .colon and key == .ident and key_tok.kind == .identifier) {
        const name_span = key.ident;
        return .{
            .span = .{ .start = start, .end = key_end },
            .key = key,
            .value = .{ .identifier_reference = .{ .span = name_span } },
            .shorthand = true,
        };
    }

    _ = try p.expect(.colon);
    const value = try parseAssignment(p);
    return .{
        .span = .{ .start = start, .end = value.span().end },
        .key = key,
        .value = value,
        .shorthand = false,
    };
}

/// §15.2 FunctionExpression — anonymous or optionally named. The `function`
/// keyword is the leading token. `function*` opens a generator;
/// `async function` opens an async function (the async-prefix is
/// consumed by the caller, which passes `start` and `is_async`).
fn parseFunctionExpression(p: *Parser) ParseError!Expression {
    return parseFunctionExpressionAt(p, p.peek().span.start, false);
}

fn parseFunctionExpressionAt(p: *Parser, start: u32, is_async: bool) ParseError!Expression {
    _ = try p.bump(); // `function`
    const is_generator = try p.eat(.star);
    var name: ?@import("../ast/statement.zig").BindingIdentifier = null;
    if (p.peek().kind == .identifier) {
        name = try p.parseBindingIdentifier();
    }
    const params = try p.parseFunctionParameters();

    const saved_gen = p.in_generator;
    const saved_async = p.in_async;
    const saved_in_function = p.in_function;
    p.in_generator = is_generator;
    p.in_async = is_async;
    p.in_function = true;
    defer {
        p.in_generator = saved_gen;
        p.in_async = saved_async;
        p.in_function = saved_in_function;
    }

    const body = try p.parseBlockStatementInner();
    parser_mod.tagDirectivePrologue(body.body);
    try parser_mod.enforceStrictDirectiveSimplicity(p, params, body.body, body.span);
    return .{ .function_expr = .{
        .span = .{ .start = start, .end = body.span.end },
        .name = name,
        .params = params,
        .body = body,
        .is_generator = is_generator,
        .is_async = is_async,
    } };
}

/// §13.2.5 CoverParenthesizedExpressionAndArrowParameterList — a
/// parenthesized expression that may also be the head of an arrow
/// function. Items are comma-separated AssignmentExpressions, each
/// of which can additionally be a `...rest` SpreadElement (only
/// valid as an arrow-parameter rest, but the cover grammar
/// accepts it here and the arrow-reinterpret path picks it up via
/// `collectArrowParams`). When the form turns out to be a real
/// expression, `(a, ...rest)` is a SyntaxError surfaced when
/// `reinterpretLhsAsArrow` doesn't see `=>` next.
fn parseParenthesized(p: *Parser) ParseError!Expression {
    const lparen = try p.bump();
    std.debug.assert(lparen.kind == .lparen);
    var items: std.ArrayListUnmanaged(Expression) = .empty;
    while (p.peek().kind != .rparen and p.peek().kind != .eof) {
        if (p.peek().kind == .ellipsis) {
            const dots = try p.bump();
            const arg = try parseAssignment(p);
            const arg_ptr = try p.arena.create(Expression);
            arg_ptr.* = arg;
            try items.append(p.arena, .{ .spread = .{
                .span = .{ .start = dots.span.start, .end = arg.span().end },
                .argument = arg_ptr,
            } });
        } else {
            const item = try parseAssignment(p);
            try items.append(p.arena, item);
        }
        if (p.peek().kind != .comma) break;
        _ = try p.bump();
    }
    const rparen = try p.expect(.rparen);
    const inner_ptr = try p.arena.create(Expression);
    if (items.items.len == 1) {
        inner_ptr.* = items.items[0];
    } else {
        // Multiple items — fold into a sequence, mirroring what the
        // expression parser produces for `(a, b, c)`. Arrow
        // reinterpretation walks the sequence one item at a time.
        const owned = try items.toOwnedSlice(p.arena);
        inner_ptr.* = .{ .sequence = .{
            .span = .{ .start = lparen.span.start, .end = rparen.span.end },
            .expressions = owned,
        } };
    }
    return .{ .parenthesized = .{
        .span = .{ .start = lparen.span.start, .end = rparen.span.end },
        .expression = inner_ptr,
    } };
}

/// True if `kind` can begin a Statement that is parsed as an
/// ExpressionStatement (§14.5). Used by the dispatcher to decide whether to
/// fall through to expression parsing.
pub fn canStartExpression(kind: TokenKind) bool {
    return switch (kind) {
        .kw_null, .kw_true, .kw_false, .kw_this => true,
        .numeric_literal, .bigint_literal, .string_literal => true,
        .no_substitution_template, .template_head => true,
        .identifier => true,
        .lparen => true,
        // Unary operators (§13.5).
        .bang, .tilde, .plus, .minus, .kw_typeof, .kw_void, .kw_delete => true,
        // Prefix update (§13.4).
        .plus_plus, .minus_minus => true,
        // `new` opens a NewExpression at the LeftHandSideExpression level.
        .kw_new => true,
        // `function` as PrimaryExpression (FunctionExpression). At the
        // statement level, `kw_function` is intercepted by `parseStatement`
        // and routed to `FunctionDeclaration` first per §14.5 — so this
        // arm only fires inside an expression context.
        .kw_function => true,
        // §15.7 ClassExpression — at statement level, `kw_class` is
        // intercepted by `parseStatement` first.
        .kw_class => true,
        // §13.2.4 ArrayLiteral. (`{` is intentionally absent here because
        // `lbrace` at statement start is a BlockStatement per §14.5.)
        .lbracket => true,
        // YieldExpression / AwaitExpression — only valid inside the
        // appropriate function context. The parser routes the token to
        // the keyword form when in_generator / in_async is set; otherwise
        // these flow through and surface as `unexpected_token` somewhere
        // useful.
        .kw_yield, .kw_await => true,
        // `/` and `/=` in expression-start position open a
        // RegularExpressionLiteral (§12.9.5). The parser switches the
        // lexer into `InputElementRegExp` mode by re-scanning.
        .slash, .slash_eq => true,
        // §13.3.10 / §13.3.12.1 — `import(...)` and `import.meta`.
        .kw_import => true,
        // §13.3.7 — `super.x`, `super[x]`, `super(...)`.
        .kw_super => true,
        else => false,
    };
}
