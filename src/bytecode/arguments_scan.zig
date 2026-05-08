//! `arguments` reference detection — extracted from
//! `compiler.zig`. The compiler's function-prologue logic
//! pre-walks the body to decide whether to emit
//! `lda_arguments` (only on functions that actually mention
//! `arguments`). These are pure recursive walkers over the
//! AST — no `Compiler` state needed.
//!
//! `arguments` is bound by the caller of a non-arrow function
//! body (§10.4.4). Arrow functions inherit the enclosing
//! frame's binding, so they don't need their own
//! `lda_arguments`.

const std = @import("std");
const ast = @import("../ast.zig");
const Expression = ast.Expression;

pub fn referencesArguments(source: []const u8, body: []ast.statement.Statement) bool {
    for (body) |*s| {
        if (statementReferencesArguments(source, s)) return true;
    }
    return false;
}

pub fn statementReferencesArguments(source: []const u8, s: *const ast.statement.Statement) bool {
    return switch (s.*) {
        .expression => |es| expressionReferencesArguments(source, &es.expression),
        .block => |b| referencesArguments(source, b.body),
        .lexical => |ld| blk: {
            for (ld.declarators) |d| {
                if (d.init) |*e| if (expressionReferencesArguments(source, e)) break :blk true;
            }
            break :blk false;
        },
        .if_ => |s2| blk: {
            if (expressionReferencesArguments(source, &s2.test_)) break :blk true;
            if (statementReferencesArguments(source, s2.consequent)) break :blk true;
            if (s2.alternate) |a| if (statementReferencesArguments(source, a)) break :blk true;
            break :blk false;
        },
        .while_ => |s2| expressionReferencesArguments(source, &s2.test_) or statementReferencesArguments(source, s2.body),
        .do_while => |s2| expressionReferencesArguments(source, &s2.test_) or statementReferencesArguments(source, s2.body),
        .for_ => |s2| blk: {
            if (s2.init) |head| switch (head) {
                .expression => |*e| if (expressionReferencesArguments(source, e)) break :blk true,
                .lexical => |ld| for (ld.declarators) |d| {
                    if (d.init) |*e| if (expressionReferencesArguments(source, e)) break :blk true;
                },
            };
            if (s2.test_) |*e| if (expressionReferencesArguments(source, e)) break :blk true;
            if (s2.update) |*e| if (expressionReferencesArguments(source, e)) break :blk true;
            if (statementReferencesArguments(source, s2.body)) break :blk true;
            break :blk false;
        },
        .return_ => |s2| if (s2.argument) |*e| expressionReferencesArguments(source, e) else false,
        .throw_ => |s2| expressionReferencesArguments(source, &s2.argument),
        .try_ => |s2| blk: {
            for (s2.block.body) |*inner| if (statementReferencesArguments(source, inner)) break :blk true;
            if (s2.handler) |h| {
                for (h.body.body) |*inner| if (statementReferencesArguments(source, inner)) break :blk true;
            }
            if (s2.finalizer) |fb| {
                for (fb.body) |*inner| if (statementReferencesArguments(source, inner)) break :blk true;
            }
            break :blk false;
        },
        .switch_ => |s2| blk: {
            if (expressionReferencesArguments(source, &s2.discriminant)) break :blk true;
            for (s2.cases) |c| {
                if (c.test_) |*e| if (expressionReferencesArguments(source, e)) break :blk true;
                for (c.body) |*inner| if (statementReferencesArguments(source, inner)) break :blk true;
            }
            break :blk false;
        },
        // Function / class declarations create their own scope —
        // any `arguments` inside them belongs to that inner
        // function, not us. Skip them entirely.
        .function_decl, .class_decl => false,
        else => false,
    };
}

pub fn expressionReferencesArguments(source: []const u8, e: *const Expression) bool {
    return switch (e.*) {
        .identifier_reference => |id| std.mem.eql(u8, source[id.span.start..id.span.end], "arguments"),
        .parenthesized => |p| expressionReferencesArguments(source, p.expression),
        .unary => |u| expressionReferencesArguments(source, u.operand),
        .binary => |b| expressionReferencesArguments(source, b.lhs) or expressionReferencesArguments(source, b.rhs),
        .logical => |l| expressionReferencesArguments(source, l.lhs) or expressionReferencesArguments(source, l.rhs),
        .conditional => |c| expressionReferencesArguments(source, c.test_) or expressionReferencesArguments(source, c.consequent) or expressionReferencesArguments(source, c.alternate),
        .assignment => |a| expressionReferencesArguments(source, a.target) or expressionReferencesArguments(source, a.value),
        .sequence => |s| blk: {
            for (s.expressions) |*ex| if (expressionReferencesArguments(source, ex)) break :blk true;
            break :blk false;
        },
        .member => |m| expressionReferencesArguments(source, m.object) or switch (m.property) {
            .computed => |k| expressionReferencesArguments(source, k),
            else => false,
        },
        .call => |c| blk: {
            if (expressionReferencesArguments(source, c.callee)) break :blk true;
            for (c.arguments) |*a| if (expressionReferencesArguments(source, a)) break :blk true;
            break :blk false;
        },
        .new_expr => |n| blk: {
            if (expressionReferencesArguments(source, n.callee)) break :blk true;
            for (n.arguments) |*a| if (expressionReferencesArguments(source, a)) break :blk true;
            break :blk false;
        },
        .array_literal => |al| blk: {
            for (al.elements) |maybe_elem| {
                if (maybe_elem) |*ex| if (expressionReferencesArguments(source, ex)) break :blk true;
            }
            break :blk false;
        },
        .object_literal => |o| blk: {
            for (o.properties) |p| switch (p) {
                .property => |prop| if (expressionReferencesArguments(source, &prop.value)) break :blk true,
                else => {},
            };
            break :blk false;
        },
        .template_literal => |t| blk: {
            for (t.expressions) |*ex| if (expressionReferencesArguments(source, ex)) break :blk true;
            break :blk false;
        },
        .update => |u| expressionReferencesArguments(source, u.operand),
        .spread => |s| expressionReferencesArguments(source, s.argument),
        // Function / arrow / class expressions have their own scope.
        .function_expr, .arrow_function, .class_expr => false,
        else => false,
    };
}
