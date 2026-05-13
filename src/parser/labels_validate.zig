//! §13.13 / §14.13 / §14.15 — labelled-statement / break / continue
//! early errors. Walks the program after parsing and reports:
//!
//!   • Duplicate label name shadowing an enclosing label still active
//!     for the current statement (§13.13.1 — labels nest, but a label
//!     can't appear twice on the path from this label to the
//!     enclosing function/script/module boundary).
//!   • Unlabelled `break` outside of an iteration or switch.
//!   • Unlabelled `continue` outside of an iteration.
//!   • `break LABEL` whose LABEL is not in the active label set.
//!   • `continue LABEL` whose LABEL is not in scope or does not label
//!     an IterationStatement.
//!
//! "Active label set" follows the spec semantics: a `LABEL : stmt`
//! adds LABEL to the body's set; entering a function / class / arrow
//! body resets the set to empty. The `iteration depth` counter and
//! `switch depth` counter track whether we're inside something that
//! lets an unlabelled break / continue fire.

const std = @import("std");

const ast = @import("../ast.zig");
const Statement = ast.Statement;
const Program = ast.Program;
const Expression = ast.Expression;
const stmt_mod = @import("../ast/statement.zig");

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

const LabelEntry = struct {
    name: []const u8,
    /// True if the labelled statement *immediately* wraps an
    /// IterationStatement — required for `continue LABEL` to be legal.
    /// Per §14.15.1, only iteration-labels are valid continue targets.
    is_iteration: bool,
};

pub const Validator = struct {
    arena: std.mem.Allocator,
    diagnostics: ?*Diagnostics,
    source: []const u8,
    labels: std.ArrayListUnmanaged(LabelEntry) = .empty,
    /// Iteration-depth counter — incremented on `for`, `for-in/of`,
    /// `while`, `do-while`. `continue` (unlabelled) is legal iff > 0.
    iter_depth: u32 = 0,
    /// Iteration- or switch-depth — `break` (unlabelled) is legal iff > 0.
    break_depth: u32 = 0,
    /// Index into `labels` below which entries are invisible — set
    /// when we cross a function/method/arrow boundary so labels in
    /// outer scopes can't be reached by labelled break/continue
    /// inside the inner function body.
    label_floor: u32 = 0,
    saved_state: std.ArrayListUnmanaged(SavedState) = .empty,

    const SavedState = struct {
        label_floor: u32,
        iter_depth: u32,
        break_depth: u32,
    };

    pub fn run(self: *Validator, program: *const Program) !void {
        defer self.labels.deinit(self.arena);
        defer self.saved_state.deinit(self.arena);
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

    fn labelInScope(self: *Validator, name: []const u8) ?LabelEntry {
        var i: usize = self.labels.items.len;
        while (i > @as(usize, self.label_floor)) {
            i -= 1;
            const e = self.labels.items[i];
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    fn isIterationStmt(s: *const Statement) bool {
        return switch (s.*) {
            .for_, .for_in_of, .while_, .do_while => true,
            // A label on top of another label inherits its body's
            // iteration-ness — `OUTER: INNER: for (...) {}` lets
            // `continue OUTER;` target the loop.
            .labeled => |lb| isIterationStmt(lb.body),
            else => false,
        };
    }

    fn visitStmt(self: *Validator, s: *const Statement) std.mem.Allocator.Error!void {
        switch (s.*) {
            .labeled => |lb| {
                const name = self.source[lb.label.start..lb.label.end];
                // §13.13.1 — a label may not appear twice on the path
                // from this LabelledStatement back to the enclosing
                // function / script / module boundary (i.e. duplicate
                // within the *active* label set).
                if (self.labelInScope(name) != null) {
                    try self.report(.duplicate_lexical_binding, lb.label);
                }
                const is_iter = isIterationStmt(lb.body);
                try self.labels.append(self.arena, .{
                    .name = name,
                    .is_iteration = is_iter,
                });
                try self.visitStmt(lb.body);
                _ = self.labels.pop();
            },
            .break_ => |bs| {
                if (bs.label) |lsp| {
                    const name = self.source[lsp.start..lsp.end];
                    if (self.labelInScope(name) == null) {
                        try self.report(.undefined_label, lsp);
                    }
                } else if (self.break_depth == 0) {
                    try self.report(.break_outside_loop_or_switch, bs.span);
                }
            },
            .continue_ => |cs| {
                if (cs.label) |lsp| {
                    const name = self.source[lsp.start..lsp.end];
                    if (self.labelInScope(name)) |entry| {
                        if (!entry.is_iteration) {
                            try self.report(.continue_target_not_iteration, lsp);
                        }
                    } else {
                        try self.report(.undefined_label, lsp);
                    }
                    // Per §14.15.1 a labelled `continue` is only legal
                    // when the target label encloses the continue — and
                    // when *some* iteration sits between the continue and
                    // the label. The "encloses" half is the `labelInScope`
                    // check; the "iteration between" half is a stricter
                    // test we defer (rare and only catches contrived
                    // forms like `L: { for(;;) continue L; }` which is
                    // actually legal anyway — L's body is a Block, not
                    // a loop, but the continue lands inside the loop).
                } else if (self.iter_depth == 0) {
                    try self.report(.continue_outside_loop, cs.span);
                }
            },
            .expression => |*es| try self.visitExpr(&es.expression),
            .block => |b| for (b.body) |*c| try self.visitStmt(c),
            .empty, .debugger_ => {},
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
                try self.enterLoop();
                defer self.leaveLoop();
                try self.visitStmt(w.body);
            },
            .do_while => |w| {
                try self.enterLoop();
                {
                    defer self.leaveLoop();
                    try self.visitStmt(w.body);
                }
                try self.visitExpr(&w.test_);
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
                try self.enterLoop();
                defer self.leaveLoop();
                try self.visitStmt(f.body);
            },
            .for_in_of => |f| {
                switch (f.left) {
                    .expression => |x| try self.visitExpr(&x),
                    .lexical => |ld| for (ld.declarators) |*d| {
                        if (d.init) |ie| try self.visitExpr(&ie);
                    },
                }
                try self.visitExpr(&f.right);
                try self.enterLoop();
                defer self.leaveLoop();
                try self.visitStmt(f.body);
            },
            .try_ => |t| {
                for (t.block.body) |*c| try self.visitStmt(c);
                if (t.handler) |h| for (h.body.body) |*c| try self.visitStmt(c);
                if (t.finalizer) |fz| for (fz.body) |*c| try self.visitStmt(c);
            },
            .switch_ => |sw| {
                try self.visitExpr(&sw.discriminant);
                self.break_depth += 1;
                defer self.break_depth -= 1;
                for (sw.cases) |c| {
                    if (c.test_) |x| try self.visitExpr(&x);
                    for (c.body) |*cs| try self.visitStmt(cs);
                }
            },
            .function_decl => |fd| {
                try self.enterFunctionLike();
                defer self.leaveFunctionLike();
                for (fd.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                for (fd.body.body) |*c| try self.visitStmt(c);
            },
            .class_decl => |cd| {
                if (cd.superclass) |sc| try self.visitExpr(&sc);
                try self.visitClassBody(cd.body);
            },
            .import_decl => {},
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| try self.visitStmt(inner),
                .default_value => |x| try self.visitExpr(&x),
                .named, .all => {},
            },
        }
    }

    fn enterLoop(self: *Validator) std.mem.Allocator.Error!void {
        self.iter_depth += 1;
        self.break_depth += 1;
    }

    fn leaveLoop(self: *Validator) void {
        self.iter_depth -= 1;
        self.break_depth -= 1;
    }

    /// Crossing a function/method/arrow boundary resets the label
    /// scope and the unlabelled break/continue counters — a nested
    /// `function() { break OUTER; }` can't see OUTER, nor can it
    /// `break` to a loop in the outer scope.
    fn enterFunctionLike(self: *Validator) std.mem.Allocator.Error!void {
        try self.saved_state.append(self.arena, .{
            .label_floor = self.label_floor,
            .iter_depth = self.iter_depth,
            .break_depth = self.break_depth,
        });
        // Raise the floor so labels declared in the outer scope are
        // invisible to labelled break/continue inside this body. We
        // don't truncate the list itself — the inner body's
        // push/pop pairs balance out by the time we leave.
        self.label_floor = @intCast(self.labels.items.len);
        self.iter_depth = 0;
        self.break_depth = 0;
    }

    fn leaveFunctionLike(self: *Validator) void {
        const saved = self.saved_state.pop().?;
        self.label_floor = saved.label_floor;
        self.iter_depth = saved.iter_depth;
        self.break_depth = saved.break_depth;
    }

    fn visitClassBody(self: *Validator, body: []const stmt_mod.ClassMember) std.mem.Allocator.Error!void {
        for (body) |m| switch (m) {
            .method => |md| {
                switch (md.key) {
                    .computed => |c| try self.visitExpr(c),
                    else => {},
                }
                try self.enterFunctionLike();
                defer self.leaveFunctionLike();
                for (md.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                for (md.body.body) |*s| try self.visitStmt(s);
            },
            .field => |fd| {
                switch (fd.key) {
                    .computed => |c| try self.visitExpr(c),
                    else => {},
                }
                if (fd.init) |ie| {
                    try self.enterFunctionLike();
                    defer self.leaveFunctionLike();
                    try self.visitExpr(&ie);
                }
            },
            .static_block => |sb| {
                try self.enterFunctionLike();
                defer self.leaveFunctionLike();
                for (sb.body) |*s| try self.visitStmt(s);
            },
        };
    }

    fn visitExpr(self: *Validator, e: *const Expression) std.mem.Allocator.Error!void {
        switch (e.*) {
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
            .assignment => |a| {
                try self.visitExpr(a.target);
                try self.visitExpr(a.value);
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
                        try self.enterFunctionLike();
                        defer self.leaveFunctionLike();
                        for (mt.params) |p| switch (p) {
                            .simple => |spr| if (spr.default) |d| try self.visitExpr(&d),
                            .rest => {},
                        };
                        for (mt.body.body) |*c| try self.visitStmt(c);
                    },
                };
            },
            .arrow_function => |af| {
                try self.enterFunctionLike();
                defer self.leaveFunctionLike();
                for (af.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                switch (af.body) {
                    .expression => |xe| try self.visitExpr(xe),
                    .block => |bl| for (bl.body) |*c| try self.visitStmt(c),
                }
            },
            .function_expr => |fe| {
                try self.enterFunctionLike();
                defer self.leaveFunctionLike();
                for (fe.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                for (fe.body.body) |*c| try self.visitStmt(c);
            },
            .class_expr => |ce| {
                if (ce.superclass) |sc| try self.visitExpr(sc);
                try self.visitClassBody(ce.body);
            },
            .yield => |y| {
                if (y.argument) |a| try self.visitExpr(a);
            },
            .await_ => |a| try self.visitExpr(a.argument),
            .import_call => |ic| try self.visitExpr(ic.source),
            else => {},
        }
    }
};
