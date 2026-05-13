//! Post-parse validator for AssignmentExpression destructuring patterns.
//!
//! The cover-grammar reinterpretation in expression.zig only checks the
//! top-level shape of an AssignmentExpression's LHS. Several spec early
//! errors fire deeper in the pattern tree:
//!
//!   §13.15.5 AssignmentPattern early errors —
//!   • ArrayAssignmentPattern : AssignmentRestElement must be the last
//!     element, with no following AssignmentElement or Elision.
//!   • AssignmentRestElement does not accept an Initializer.
//!   • ObjectAssignmentPattern : AssignmentRestProperty must be the last
//!     property.
//!   • Each nested DestructuringAssignmentTarget must itself be a valid
//!     SimpleAssignmentTarget or AssignmentPattern. A SequenceExpression
//!     `(x, y)` is neither; nor is a property accessor (`get x() {}`).
//!
//! This pass walks the AST after parsing and emits diagnostics for each
//! violation. Because `tools/test262.zig` treats any error-severity
//! diagnostic as a parse failure, that's enough for negative-parse
//! fixtures to score as `pass_negative`.

const std = @import("std");

const ast = @import("../ast.zig");
const Expression = ast.Expression;
const Statement = ast.Statement;
const Program = ast.Program;
const stmt_mod = @import("../ast/statement.zig");
const expr_mod_ast = @import("../ast/expression.zig");

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

pub const Validator = struct {
    arena: std.mem.Allocator,
    diagnostics: ?*Diagnostics,
    source: []const u8,

    pub fn run(self: *Validator, program: *const Program) !void {
        for (program.body) |*s| try self.visitStmt(s);
    }

    fn report(self: *Validator, code: Code, span: Span) !void {
        if (self.diagnostics) |list| {
            try list.append(self.arena, .{
                .severity = .err,
                .code = code,
                .span = span,
            });
        }
    }

    // ── Statement walker ────────────────────────────────────────────────

    fn visitStmt(self: *Validator, s: *const Statement) !void {
        switch (s.*) {
            .expression => |*es| try self.visitExpr(&es.expression),
            .block => |b| for (b.body) |*c| try self.visitStmt(c),
            .empty, .debugger_, .break_, .continue_ => {},
            .lexical => |l| {
                for (l.declarators) |d| {
                    if (d.init) |ie| try self.visitExpr(&ie);
                }
            },
            .if_ => |i| {
                try self.visitExpr(&i.test_);
                try self.visitStmt(i.consequent);
                if (i.alternate) |a| try self.visitStmt(a);
            },
            .while_ => |w| {
                try self.visitExpr(&w.test_);
                try self.visitStmt(w.body);
            },
            .do_while => |w| {
                try self.visitExpr(&w.test_);
                try self.visitStmt(w.body);
            },
            .return_ => |r| if (r.argument) |a| try self.visitExpr(&a),
            .throw_ => |t| try self.visitExpr(&t.argument),
            .for_ => |f| {
                if (f.init) |fi| switch (fi) {
                    .expression => |x| try self.visitExpr(&x),
                    .lexical => |ld| for (ld.declarators) |*d| {
                        if (d.init) |ie| try self.visitExpr(&ie);
                    },
                };
                if (f.test_) |x| try self.visitExpr(&x);
                if (f.update) |x| try self.visitExpr(&x);
                try self.visitStmt(f.body);
            },
            .for_in_of => |f| {
                // §13.7.5.1 ForInOfStatement early errors:
                // • The LeftHandSideExpression must be a valid assignment
                //   target — IsValidSimpleAssignmentTarget true, or an
                //   ObjectLiteral / ArrayLiteral that re-parses as an
                //   AssignmentPattern. `this`, `(this)`, sequence-wrapped
                //   patterns, ObjectLiteral methods, etc. are all invalid.
                if (f.left == .expression) {
                    try self.validateForInOfLhs(&f.left.expression);
                }
                try self.visitExpr(&f.right);
                try self.visitStmt(f.body);
            },
            .try_ => |t| {
                for (t.block.body) |*c| try self.visitStmt(c);
                if (t.handler) |h| for (h.body.body) |*c| try self.visitStmt(c);
                if (t.finalizer) |fz| for (fz.body) |*c| try self.visitStmt(c);
            },
            .switch_ => |sw| {
                try self.visitExpr(&sw.discriminant);
                for (sw.cases) |c| {
                    if (c.test_) |x| try self.visitExpr(&x);
                    for (c.body) |*cs| try self.visitStmt(cs);
                }
            },
            .function_decl => |fd| {
                for (fd.body.body) |*c| try self.visitStmt(c);
            },
            .class_decl => |cd| {
                if (cd.superclass) |sc| try self.visitExpr(&sc);
            },
            .import_decl, .export_decl => {},
        }
    }

    // ── Expression walker ───────────────────────────────────────────────

    fn visitExpr(self: *Validator, e: *const Expression) std.mem.Allocator.Error!void {
        switch (e.*) {
            .assignment => |a| {
                // Only `=` (plain assignment) is allowed for destructuring
                // patterns. Compound ops with array/object targets are
                // already rejected at top level by expression.zig.
                const target_is_pattern = a.op == .eq and switch (a.target.*) {
                    .array_literal, .object_literal => true,
                    .parenthesized => |p| p.expression.* == .array_literal or
                        p.expression.* == .object_literal,
                    else => false,
                };
                if (a.op == .eq) {
                    switch (a.target.*) {
                        .array_literal => |al| try self.validateArrayPattern(al),
                        .object_literal => |ol| try self.validateObjectPattern(ol),
                        .parenthesized => |p| switch (p.expression.*) {
                            .array_literal => |al| try self.validateArrayPattern(al),
                            .object_literal => |ol| try self.validateObjectPattern(ol),
                            else => {},
                        },
                        else => {},
                    }
                }
                // When the LHS is reinterpreted as a destructuring
                // pattern, the §13.2.5.1 `__proto__` duplicate rule
                // is suppressed (the spec's exemption keys on the
                // grammar position, not source shape). Skip
                // visitExpr's pattern-only checks for that subtree.
                if (!target_is_pattern) try self.visitExpr(a.target);
                try self.visitExpr(a.value);
            },
            .parenthesized => |p| try self.visitExpr(p.expression),
            .unary => |u| try self.visitExpr(u.operand),
            .binary => |b| {
                try self.visitExpr(b.lhs);
                try self.visitExpr(b.rhs);
            },
            .logical => |l| {
                try self.visitExpr(l.lhs);
                try self.visitExpr(l.rhs);
            },
            .conditional => |c| {
                try self.visitExpr(c.test_);
                try self.visitExpr(c.consequent);
                try self.visitExpr(c.alternate);
            },
            .sequence => |sq| {
                for (sq.expressions) |*x| try self.visitExpr(x);
            },
            .member => |m| {
                try self.visitExpr(m.object);
                switch (m.property) {
                    .computed => |c| try self.visitExpr(c),
                    else => {},
                }
            },
            .call => |c| {
                try self.visitExpr(c.callee);
                for (c.arguments) |*x| try self.visitExpr(x);
            },
            .new_expr => |n| {
                try self.visitExpr(n.callee);
                for (n.arguments) |*x| try self.visitExpr(x);
            },
            .chain => |c| try self.visitExpr(c.expression),
            .tagged_template => |t| {
                try self.visitExpr(t.tag);
                try self.visitExpr(t.quasi);
            },
            .template_literal => |tl| {
                for (tl.expressions) |*x| try self.visitExpr(x);
            },
            .spread => |sp| try self.visitExpr(sp.argument),
            .update => |u| try self.visitExpr(u.operand),
            .array_literal => |al| {
                for (al.elements) |maybe_el| {
                    if (maybe_el) |el| try self.visitExpr(&el);
                }
            },
            .object_literal => |ol| {
                // §13.2.5.1 — an ObjectLiteral used as a regular
                // expression (not destructured) may not contain more
                // than one `__proto__:` property. The pattern path
                // (`validateObjectPattern`) skips this rule, so we
                // anchor it on the visitExpr walker, which only fires
                // for object literals in genuine expression position.
                var proto_seen = false;
                for (ol.properties) |m| {
                    if (m != .property) continue;
                    const prop = m.property;
                    // §13.2.5.1 CoverInitializedName — a shorthand
                    // property with an initializer (`{ a = 1 }`) is
                    // only legal as the cover form of an
                    // AssignmentPattern. In a plain expression
                    // position it's a SyntaxError. We get here only
                    // when the object literal is *not* a destructuring
                    // target (the assignment branch skips this walk
                    // for pattern LHS objects).
                    if (prop.shorthand and prop.value == .assignment) {
                        try self.report(.assignment_target_invalid, prop.span);
                    }
                    if (prop.shorthand) continue;
                    const text: []const u8 = switch (prop.key) {
                        .ident => |sp| self.source[sp.start..sp.end],
                        .string => |sp| if (sp.end > sp.start + 1)
                            self.source[sp.start + 1 .. sp.end - 1]
                        else
                            "",
                        else => continue,
                    };
                    if (!std.mem.eql(u8, text, "__proto__")) continue;
                    if (proto_seen) {
                        try self.report(.duplicate_lexical_binding, prop.span);
                    } else {
                        proto_seen = true;
                    }
                }
                for (ol.properties) |m| switch (m) {
                    .property => |p| {
                        switch (p.key) {
                            .computed => |c| try self.visitExpr(c),
                            else => {},
                        }
                        try self.visitExpr(&p.value);
                    },
                    .spread => |sp| try self.visitExpr(sp.argument),
                    .method => |mt| {
                        switch (mt.key) {
                            .computed => |c| try self.visitExpr(c),
                            else => {},
                        }
                        for (mt.body.body) |*c| try self.visitStmt(c);
                    },
                };
            },
            .arrow_function => |af| {
                switch (af.body) {
                    .expression => |xe| try self.visitExpr(xe),
                    .block => |bl| for (bl.body) |*c| try self.visitStmt(c),
                }
            },
            .function_expr => |fe| {
                for (fe.body.body) |*c| try self.visitStmt(c);
            },
            .class_expr => |ce| {
                if (ce.superclass) |sc| try self.visitExpr(sc);
            },
            .yield => |y| {
                if (y.argument) |a| try self.visitExpr(a);
            },
            .await_ => |a| try self.visitExpr(a.argument),
            .import_call => |ic| try self.visitExpr(ic.source),
            else => {},
        }
    }

    // ── Pattern validation ──────────────────────────────────────────────

    fn validateArrayPattern(self: *Validator, al: expr_mod_ast.ArrayLit) std.mem.Allocator.Error!void {
        // §13.15.5 ArrayAssignmentPattern early errors:
        // • At most one AssignmentRestElement, in final position.
        // • No elision after the rest. (`[...x,]` and `[...x, y]` are
        //   both wrong: the first because of the trailing elision, the
        //   second because of a following element.)
        // • AssignmentRestElement does not take an Initializer.
        var i: usize = 0;
        while (i < al.elements.len) : (i += 1) {
            const maybe_el = al.elements[i];
            if (maybe_el == null) continue;
            const el = maybe_el.?;
            if (el == .spread) {
                const sp = el.spread;
                // Anything after the rest is illegal — including a
                // bare trailing comma. The array literal parser
                // swallows the trailing comma so `[...x,]` parses
                // with one element; scan the source between the
                // spread's end and the closing `]` for a `,` to
                // distinguish `[...x]` (legal rest) from `[...x,]`
                // (rest with disallowed trailing comma).
                if (i + 1 < al.elements.len) {
                    try self.report(.assignment_target_invalid, sp.span);
                } else if (i + 1 == al.elements.len and
                    sourceHasComma(self.source, sp.span.end, al.span.end))
                {
                    try self.report(.assignment_target_invalid, sp.span);
                }
                // RestElement target itself can't carry an initializer
                // (`[...x = 1]`). The Initializer ends up wrapped as an
                // AssignExpr inside the spread argument.
                if (sp.argument.* == .assignment and sp.argument.assignment.op == .eq) {
                    try self.report(.assignment_target_invalid, sp.span);
                }
                // Validate nested destructuring inside the rest target.
                try self.validateAssignmentTarget(sp.argument);
                continue;
            }
            try self.validateAssignmentTarget(&el);
        }
    }

    /// Scan `[from, to)` of source for a `,`, skipping ASCII
    /// whitespace and line terminators. Used by the trailing-comma-
    /// after-rest check in `validateArrayPattern` since the parser
    /// throws the comma away.
    fn sourceHasComma(src: []const u8, from: u32, to: u32) bool {
        var i: usize = from;
        const end: usize = @min(to, @as(u32, @intCast(src.len)));
        while (i < end) : (i += 1) {
            if (src[i] == ',') return true;
        }
        return false;
    }

    fn validateObjectPattern(self: *Validator, ol: expr_mod_ast.ObjectLit) std.mem.Allocator.Error!void {
        // §13.15.5 ObjectAssignmentPattern early errors:
        // • AssignmentRestProperty (object spread) must be last.
        // • Object pattern cannot contain a method definition.
        // • Each property value must be a valid destructuring target.
        var i: usize = 0;
        while (i < ol.properties.len) : (i += 1) {
            const m = ol.properties[i];
            switch (m) {
                .spread => |sp| {
                    if (i + 1 < ol.properties.len) {
                        try self.report(.assignment_target_invalid, sp.span);
                    }
                    // Object rest target also rejects an initializer.
                    if (sp.argument.* == .assignment and sp.argument.assignment.op == .eq) {
                        try self.report(.assignment_target_invalid, sp.span);
                    }
                    try self.validateAssignmentTarget(sp.argument);
                },
                .method => |mt| {
                    // `{ get x() {} } = …` — accessor / method definitions
                    // never form a valid destructuring property.
                    try self.report(.assignment_target_invalid, mt.span);
                },
                .property => |p| {
                    try self.validateAssignmentTarget(&p.value);
                },
            }
        }
    }

    /// §13.7.5.1 ForInOfStatement early error: the LeftHandSideExpression
    /// must be a valid assignment target. The for-in/of head's `left.expression`
    /// is parsed as a generic Expression (since the head also legitimately
    /// accepts assignment patterns built from array/object literals). After
    /// parsing we mirror the §13.15.1 / §13.15.5 rules used at the `=`
    /// site: simple targets (IdentifierReference, MemberExpression) and
    /// assignment patterns (ArrayLiteral / ObjectLiteral, recursively
    /// validated) are accepted; everything else is rejected.
    fn validateForInOfLhs(self: *Validator, e: *const Expression) std.mem.Allocator.Error!void {
        switch (e.*) {
            .identifier_reference, .member => {},
            .parenthesized => |p| {
                // `(this)` / `(x = 1)` and similar — the parenthesised
                // expression itself must be a valid LHS. Object / array
                // literals inside parens are NOT valid for-in/of LHS per
                // the §13.7.5.1 grammar: the cover form admits only
                // `LeftHandSideExpression`, which is a SimpleAssignmentTarget
                // or pattern at the top level, not under a parenthesis.
                switch (p.expression.*) {
                    .identifier_reference, .member => {},
                    else => try self.report(.assignment_target_invalid, e.span()),
                }
            },
            .array_literal => |al| try self.validateArrayPattern(al),
            .object_literal => |ol| try self.validateObjectPattern(ol),
            else => try self.report(.assignment_target_invalid, e.span()),
        }
    }

    /// Validate that `e` is a legal DestructuringAssignmentTarget.
    /// Handles the cases NOT already caught at the outer assignment level:
    /// nested patterns and disallowed shapes (sequences, comma exprs).
    fn validateAssignmentTarget(self: *Validator, e: *const Expression) std.mem.Allocator.Error!void {
        switch (e.*) {
            .identifier_reference => |ir| {
                // §13.15.5.1 — in strict mode, `eval` and `arguments`
                // are restricted identifiers and cannot appear as a
                // SimpleAssignmentTarget. Reinterpret-from-cover paths
                // need the explicit check; direct LHS positions get it
                // via expression.zig.
                const name = self.source[ir.span.start..ir.span.end];
                if (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments")) {
                    try self.report(.restricted_identifier_in_strict, ir.span);
                }
            },
            .array_literal => |al| try self.validateArrayPattern(al),
            .object_literal => |ol| try self.validateObjectPattern(ol),
            .parenthesized => |p| {
                // `([a]) = b` — paren-wrapped destructuring is legal in
                // arrow-param cover, but at the AssignmentPattern level
                // §13.15.5 forbids it as a *target*.
                // Specifically `( … )` whose contents is a SequenceExpr
                // `(x, y)` is never a valid target.
                if (p.expression.* == .sequence) {
                    try self.report(.assignment_target_invalid, p.span);
                    return;
                }
                try self.validateAssignmentTarget(p.expression);
            },
            .sequence => {
                try self.report(.assignment_target_invalid, e.span());
            },
            .assignment => |a| {
                // `[x = init]` shows up as element with default — legal.
                // The wrapping ast shape is AssignExpr inside the array
                // literal element. The value side of that AssignExpr is
                // the initializer; the target side recurses.
                if (a.op == .eq) {
                    try self.validateAssignmentTarget(a.target);
                } else {
                    try self.report(.assignment_target_invalid, e.span());
                }
            },
            // Member access (`obj.x`, `obj[x]`, `obj?.x`) and call
            // results that read as references (`f()[x]`) yield valid
            // SimpleAssignmentTargets — leave them alone. Likewise
            // bare identifier_reference falls through to the eval/
            // arguments branch above. Everything else (literals,
            // function/class expressions, meta properties, this,
            // super, etc.) is not a valid destructuring target.
            .member, .call => {},
            .new_expr,
            .null_literal,
            .boolean_literal,
            .numeric_literal,
            .bigint_literal,
            .string_literal,
            .template_literal,
            .regex_literal,
            .tagged_template,
            .unary,
            .binary,
            .logical,
            .conditional,
            .update,
            .await_,
            .yield,
            .spread,
            .chain,
            .this_expr,
            .super_,
            .import_meta,
            .import_call,
            .new_target,
            .private_identifier,
            .function_expr,
            .arrow_function,
            .class_expr,
            => try self.report(.assignment_target_invalid, e.span()),
        }
    }
};
