//! Parameter-to-register optimization — AST predicate.
//!
//! When a function's body doesn't capture any of its parameters in
//! an inner closure, doesn't reference `arguments`, and the
//! parameter list is all simple identifiers (no destructuring, no
//! defaults, no rest), the params can stay in their caller-
//! supplied registers without ever being copied into an
//! `Environment` slot. Reads emit `Ldar r{i}`, writes emit
//! `Star r{i}`, and the function-entry `MakeEnvironment` is
//! elided alongside its `StaEnv`-per-param prologue.
//!
//! Cynic's calling convention places parameter values in
//! `callee_regs[0..argc]` at call entry (see the `.call_method` /
//! `.call` / `.new_call` handlers' `callee_regs[ai] = registers[…]`
//! loop). The body's compilation can then read them directly.
//!
//! Conservative; over-rejects rather than over-accepts:
//!   * Any inner function expression / arrow / class expression /
//!     class declaration / function declaration inside the body
//!     ⇒ reject (the inner scope MIGHT capture a param).
//!   * Any non-simple param (destructuring, default, rest) ⇒
//!     reject (those need real scope semantics).
//!   * `arguments` reference anywhere ⇒ reject (binding required).
//!   * Generator / async functions ⇒ reject (suspension reifies
//!     the env into the JSGenerator state).
//!
//! The hot wins are simple-param non-closing methods: class
//! constructors (`class P { constructor(x, y) { this.x = x; this.y
//! = y; } }`), short helpers (`function add(a, b) { return a + b }`),
//! recursive numerics (`function fact(n) { return n<2?1:n*fact(n-1) }`).
//! Anything more elaborate falls back to the existing env path.

const std = @import("std");
const ast = @import("../ast.zig");
const arguments_scan = @import("arguments_scan.zig");
const Expression = ast.Expression;

/// Returns true when every parameter can be kept in its caller-
/// supplied register slot. `is_generator` / `is_async` callers
/// must pass `false` (handled here so generator/async stay on the
/// env path uniformly).
pub fn paramsCanBeRegisters(
    source: []const u8,
    params: []const ast.statement.FunctionParam,
    body_stmts: ?[]ast.statement.Statement,
    is_arrow: bool,
    is_generator: bool,
    is_async: bool,
) bool {
    if (is_generator or is_async) return false;
    if (params.len == 0) return false; // nothing to optimize
    // All simple, no defaults, no destructuring, no rest. The
    // prologue path for those does meaningful per-param work
    // (default expression evaluation, destructure binding, rest
    // arg collection) that the register-only fast path can't
    // express.
    for (params) |p| switch (p) {
        .simple => |sp| {
            if (sp.target != .identifier) return false;
            if (sp.default != null) return false;
        },
        .rest => return false,
    };
    // `arguments` install reifies an arguments object into env
    // slot 0 — incompatible with skipping the env.
    if (!is_arrow and arguments_scan.paramsReferenceArguments(source, params)) return false;
    const stmts = body_stmts orelse return false;
    if (!is_arrow and arguments_scan.referencesArguments(source, stmts)) return false;
    // Body must not contain any nested function-shape construct.
    // The conservative version below catches every common closure
    // shape: function expression, function declaration, arrow,
    // class declaration (constructor + methods), class expression.
    // A nested anything ⇒ a chance the inner reads one of our
    // param names through scope walk; the optimization would
    // serve a stale register copy. Cheap to reject; precise
    // capture analysis is a follow-up.
    for (stmts) |*s| if (statementHasNestedFunctionShape(s)) return false;
    return true;
}

fn statementHasNestedFunctionShape(s: *const ast.statement.Statement) bool {
    return switch (s.*) {
        .function_decl, .class_decl => true,
        .expression => |es| expressionHasNestedFunctionShape(&es.expression),
        .lexical => |ld| blk: {
            for (ld.declarators) |d| {
                if (d.init) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
            }
            break :blk false;
        },
        .block => |b| blk: {
            for (b.body) |*inner| if (statementHasNestedFunctionShape(inner)) break :blk true;
            break :blk false;
        },
        .if_ => |i| blk: {
            if (expressionHasNestedFunctionShape(&i.test_)) break :blk true;
            if (statementHasNestedFunctionShape(i.consequent)) break :blk true;
            if (i.alternate) |alt| if (statementHasNestedFunctionShape(alt)) break :blk true;
            break :blk false;
        },
        .while_ => |w| expressionHasNestedFunctionShape(&w.test_) or statementHasNestedFunctionShape(w.body),
        .do_while => |dw| expressionHasNestedFunctionShape(&dw.test_) or statementHasNestedFunctionShape(dw.body),
        .for_ => |f| blk: {
            if (f.init) |head| switch (head) {
                .expression => |*e| if (expressionHasNestedFunctionShape(e)) break :blk true,
                .lexical => |ld| for (ld.declarators) |d| {
                    if (d.init) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
                },
            };
            if (f.test_) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
            if (f.update) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
            if (statementHasNestedFunctionShape(f.body)) break :blk true;
            break :blk false;
        },
        .for_in_of => |f| blk: {
            switch (f.left) {
                .expression => |*e| if (expressionHasNestedFunctionShape(e)) break :blk true,
                .lexical => |ld| for (ld.declarators) |d| {
                    if (d.init) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
                },
            }
            if (expressionHasNestedFunctionShape(&f.right)) break :blk true;
            if (statementHasNestedFunctionShape(f.body)) break :blk true;
            break :blk false;
        },
        .labeled => |lb| statementHasNestedFunctionShape(lb.body),
        .return_ => |r| if (r.argument) |*e| expressionHasNestedFunctionShape(e) else false,
        .throw_ => |t| expressionHasNestedFunctionShape(&t.argument),
        .try_ => |t| blk: {
            for (t.block.body) |*inner| if (statementHasNestedFunctionShape(inner)) break :blk true;
            if (t.handler) |h| {
                for (h.body.body) |*inner| if (statementHasNestedFunctionShape(inner)) break :blk true;
            }
            if (t.finalizer) |fb| {
                for (fb.body) |*inner| if (statementHasNestedFunctionShape(inner)) break :blk true;
            }
            break :blk false;
        },
        .switch_ => |sw| blk: {
            if (expressionHasNestedFunctionShape(&sw.discriminant)) break :blk true;
            for (sw.cases) |c| {
                if (c.test_) |*e| if (expressionHasNestedFunctionShape(e)) break :blk true;
                for (c.body) |*inner| if (statementHasNestedFunctionShape(inner)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn expressionHasNestedFunctionShape(e: *const Expression) bool {
    return switch (e.*) {
        .function_expr, .arrow_function, .class_expr => true,
        .parenthesized => |p| expressionHasNestedFunctionShape(p.expression),
        .unary => |u| expressionHasNestedFunctionShape(u.operand),
        .binary => |b| expressionHasNestedFunctionShape(b.lhs) or expressionHasNestedFunctionShape(b.rhs),
        .logical => |l| expressionHasNestedFunctionShape(l.lhs) or expressionHasNestedFunctionShape(l.rhs),
        .conditional => |c| expressionHasNestedFunctionShape(c.test_) or expressionHasNestedFunctionShape(c.consequent) or expressionHasNestedFunctionShape(c.alternate),
        .assignment => |a| expressionHasNestedFunctionShape(a.target) or expressionHasNestedFunctionShape(a.value),
        .sequence => |s| blk: {
            for (s.expressions) |*ex| if (expressionHasNestedFunctionShape(ex)) break :blk true;
            break :blk false;
        },
        .member => |m| expressionHasNestedFunctionShape(m.object) or switch (m.property) {
            .computed => |k| expressionHasNestedFunctionShape(k),
            else => false,
        },
        .call => |c| blk: {
            if (expressionHasNestedFunctionShape(c.callee)) break :blk true;
            for (c.arguments) |*a| if (expressionHasNestedFunctionShape(a)) break :blk true;
            break :blk false;
        },
        .new_expr => |n| blk: {
            if (expressionHasNestedFunctionShape(n.callee)) break :blk true;
            for (n.arguments) |*a| if (expressionHasNestedFunctionShape(a)) break :blk true;
            break :blk false;
        },
        .array_literal => |al| blk: {
            for (al.elements) |maybe_elem| {
                if (maybe_elem) |*ex| if (expressionHasNestedFunctionShape(ex)) break :blk true;
            }
            break :blk false;
        },
        .object_literal => |o| blk: {
            for (o.properties) |p| switch (p) {
                .property => |prop| if (expressionHasNestedFunctionShape(&prop.value)) break :blk true,
                else => {},
            };
            break :blk false;
        },
        .template_literal => |t| blk: {
            for (t.expressions) |*ex| if (expressionHasNestedFunctionShape(ex)) break :blk true;
            break :blk false;
        },
        .update => |u| expressionHasNestedFunctionShape(u.operand),
        .spread => |s| expressionHasNestedFunctionShape(s.argument),
        .yield => |y| if (y.argument) |a| expressionHasNestedFunctionShape(a) else false,
        .await_ => |a| expressionHasNestedFunctionShape(a.argument),
        .chain => |c| expressionHasNestedFunctionShape(c.expression),
        .tagged_template => |t| expressionHasNestedFunctionShape(t.tag) or expressionHasNestedFunctionShape(t.quasi),
        else => false,
    };
}
