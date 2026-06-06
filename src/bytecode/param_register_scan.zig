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
    // §19.2.1 — a direct eval reads bindings through the surrounding
    // env chain. Register-only params skip the env entirely, so
    // `function f(n) { return eval('n + 1'); }` couldn't resolve
    // `n` from inside the eval. Reject when the body contains a
    // bare `eval(…)` call — the env-bound path stays as the
    // fallback. Indirect eval (`(0, eval)(…)`) doesn't see the
    // caller's scope per §19.2.1, but it's cheap to reject both
    // by detecting any call whose callee is the bare identifier
    // `eval`.
    for (stmts) |*s| if (statementHasDirectEvalCall(source, s)) return false;
    return true;
}

/// True when `s` (or any nested expression / statement) contains a
/// call whose callee is the bare identifier `eval`. Used as a
/// rejection condition by `paramsCanBeRegisters` — see the
/// matching call site for the §19.2.1 motivation.
fn statementHasDirectEvalCall(source: []const u8, s: *const ast.statement.Statement) bool {
    return switch (s.*) {
        .expression => |es| expressionHasDirectEvalCall(source, &es.expression),
        .block => |b| blk: {
            for (b.body) |*inner| if (statementHasDirectEvalCall(source, inner)) break :blk true;
            break :blk false;
        },
        .lexical => |ld| blk: {
            for (ld.declarators) |d| {
                if (d.init) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
            }
            break :blk false;
        },
        .if_ => |i| blk: {
            if (expressionHasDirectEvalCall(source, &i.test_)) break :blk true;
            if (statementHasDirectEvalCall(source, i.consequent)) break :blk true;
            if (i.alternate) |alt| if (statementHasDirectEvalCall(source, alt)) break :blk true;
            break :blk false;
        },
        .while_ => |w| expressionHasDirectEvalCall(source, &w.test_) or statementHasDirectEvalCall(source, w.body),
        .do_while => |dw| expressionHasDirectEvalCall(source, &dw.test_) or statementHasDirectEvalCall(source, dw.body),
        .for_ => |f| blk: {
            if (f.init) |head| switch (head) {
                .expression => |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true,
                .lexical => |ld| for (ld.declarators) |d| {
                    if (d.init) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
                },
            };
            if (f.test_) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
            if (f.update) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
            if (statementHasDirectEvalCall(source, f.body)) break :blk true;
            break :blk false;
        },
        .for_in_of => |f| blk: {
            switch (f.left) {
                .expression => |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true,
                .lexical => |ld| for (ld.declarators) |d| {
                    if (d.init) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
                },
            }
            if (expressionHasDirectEvalCall(source, &f.right)) break :blk true;
            if (statementHasDirectEvalCall(source, f.body)) break :blk true;
            break :blk false;
        },
        .labeled => |lb| statementHasDirectEvalCall(source, lb.body),
        .return_ => |r| if (r.argument) |*e| expressionHasDirectEvalCall(source, e) else false,
        .throw_ => |t| expressionHasDirectEvalCall(source, &t.argument),
        .try_ => |t| blk: {
            for (t.block.body) |*inner| if (statementHasDirectEvalCall(source, inner)) break :blk true;
            if (t.handler) |h| {
                for (h.body.body) |*inner| if (statementHasDirectEvalCall(source, inner)) break :blk true;
            }
            if (t.finalizer) |fb| {
                for (fb.body) |*inner| if (statementHasDirectEvalCall(source, inner)) break :blk true;
            }
            break :blk false;
        },
        .switch_ => |sw| blk: {
            if (expressionHasDirectEvalCall(source, &sw.discriminant)) break :blk true;
            for (sw.cases) |c| {
                if (c.test_) |*e| if (expressionHasDirectEvalCall(source, e)) break :blk true;
                for (c.body) |*inner| if (statementHasDirectEvalCall(source, inner)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn expressionHasDirectEvalCall(source: []const u8, e: *const Expression) bool {
    return switch (e.*) {
        .call => |c| blk: {
            // §19.2.1 — direct eval requires the callee to be the
            // bare identifier `eval` (after parenthesis stripping).
            // `obj.eval()` and `(0, eval)(…)` route differently;
            // the latter is technically indirect eval but the
            // identifier check below still flags any `eval(…)` in
            // body so the conservative rejection covers both.
            var callee = c.callee;
            while (callee.* == .parenthesized) callee = callee.parenthesized.expression;
            if (callee.* == .identifier_reference) {
                const id = callee.identifier_reference;
                if (std.mem.eql(u8, source[id.span.start..id.span.end], "eval")) {
                    break :blk true;
                }
            }
            if (expressionHasDirectEvalCall(source, c.callee)) break :blk true;
            for (c.arguments) |*a| if (expressionHasDirectEvalCall(source, a)) break :blk true;
            break :blk false;
        },
        .parenthesized => |p| expressionHasDirectEvalCall(source, p.expression),
        .unary => |u| expressionHasDirectEvalCall(source, u.operand),
        .binary => |b| expressionHasDirectEvalCall(source, b.lhs) or expressionHasDirectEvalCall(source, b.rhs),
        .logical => |l| expressionHasDirectEvalCall(source, l.lhs) or expressionHasDirectEvalCall(source, l.rhs),
        .conditional => |c| expressionHasDirectEvalCall(source, c.test_) or expressionHasDirectEvalCall(source, c.consequent) or expressionHasDirectEvalCall(source, c.alternate),
        .assignment => |a| expressionHasDirectEvalCall(source, a.target) or expressionHasDirectEvalCall(source, a.value),
        .sequence => |s| blk: {
            for (s.expressions) |*ex| if (expressionHasDirectEvalCall(source, ex)) break :blk true;
            break :blk false;
        },
        .member => |m| expressionHasDirectEvalCall(source, m.object) or switch (m.property) {
            .computed => |k| expressionHasDirectEvalCall(source, k),
            else => false,
        },
        .new_expr => |n| blk: {
            if (expressionHasDirectEvalCall(source, n.callee)) break :blk true;
            for (n.arguments) |*a| if (expressionHasDirectEvalCall(source, a)) break :blk true;
            break :blk false;
        },
        .array_literal => |al| blk: {
            for (al.elements) |maybe_elem| {
                if (maybe_elem) |*ex| if (expressionHasDirectEvalCall(source, ex)) break :blk true;
            }
            break :blk false;
        },
        .object_literal => |o| blk: {
            for (o.properties) |p| switch (p) {
                .property => |prop| {
                    if (expressionHasDirectEvalCall(source, &prop.value)) break :blk true;
                    // A computed key is evaluated in the enclosing scope, so a
                    // direct `eval` there reads the outer function's bindings.
                    if (prop.key == .computed and expressionHasDirectEvalCall(source, prop.key.computed)) break :blk true;
                },
                // A method body is the method's own scope; only its computed
                // key is evaluated in the enclosing scope.
                .method => |m| if (m.key == .computed and expressionHasDirectEvalCall(source, m.key.computed)) break :blk true,
                .spread => |sp| if (expressionHasDirectEvalCall(source, sp.argument)) break :blk true,
            };
            break :blk false;
        },
        .template_literal => |t| blk: {
            for (t.expressions) |*ex| if (expressionHasDirectEvalCall(source, ex)) break :blk true;
            break :blk false;
        },
        .update => |u| expressionHasDirectEvalCall(source, u.operand),
        .spread => |s| expressionHasDirectEvalCall(source, s.argument),
        .yield => |y| if (y.argument) |a| expressionHasDirectEvalCall(source, a) else false,
        .await_ => |a| expressionHasDirectEvalCall(source, a.argument),
        .chain => |c| expressionHasDirectEvalCall(source, c.expression),
        .tagged_template => |t| expressionHasDirectEvalCall(source, t.tag) or expressionHasDirectEvalCall(source, t.quasi),
        else => false,
    };
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
                .property => |prop| {
                    if (expressionHasNestedFunctionShape(&prop.value)) break :blk true;
                    // §13.2.5 — a computed key is an arbitrary expression
                    // that can itself hold a nested function: `{ [g()]: 1 }`.
                    if (prop.key == .computed and expressionHasNestedFunctionShape(prop.key.computed)) break :blk true;
                },
                // §13.2.5 — `method(){}`, `get x(){}`, `set x(v){}` ARE
                // nested function definitions; their bodies can capture an
                // enclosing param through the scope chain, so the env must
                // NOT be elided. (Missing this skip wrongly register-promoted
                // a function returning `{ get g(){…a…} }`, then the accessor
                // read an elided env slot — OOB / heap corruption.)
                .method => break :blk true,
                .spread => |sp| if (expressionHasNestedFunctionShape(sp.argument)) break :blk true,
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
