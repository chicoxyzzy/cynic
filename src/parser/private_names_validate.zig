//! §15.8.1 AllPrivateNamesValid early-error pass.
//!
//! Walks the program after parsing and reports a SyntaxError for every
//! `MemberExpression . PrivateIdentifier` / `CallExpression .
//! PrivateIdentifier` whose StringValue is not declared as a
//! PrivateBoundIdentifier in any enclosing ClassBody.
//!
//! The scope stack mirrors the spec's `names` List: entering a class
//! pushes the PrivateBoundIdentifiers of its ClassBody onto the stack;
//! leaving pops them. The ClassHeritage expression is checked against
//! the *outer* names — pushes happen after the heritage walk.

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
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

const Scope = std.ArrayListUnmanaged([]const u8);

/// Decode `\u…` escapes inside an identifier slice. Returns the
/// arena-allocated decoded form, or the input slice unchanged when
/// no escapes are present. Used to compare PrivateBoundIdentifier
/// names by StringValue: `#℘` and `#℘` are the same private
/// name even though their source bytes differ.
fn decodeIdent(arena: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, src, '\\') == null) return src;
    var out = try std.ArrayListUnmanaged(u8).initCapacity(arena, src.len);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\') {
            i += 2; // skip '\u'
            var cp: u21 = 0;
            if (i < src.len and src[i] == '{') {
                i += 1;
                while (i < src.len and src[i] != '}') : (i += 1) {
                    cp = (cp << 4) | hexNibble(src[i]);
                }
                if (i < src.len) i += 1; // consume '}'
            } else {
                var n: usize = 0;
                while (n < 4 and i + n < src.len) : (n += 1) {
                    cp = (cp << 4) | hexNibble(src[i + n]);
                }
                i += 4;
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch 0;
            try out.appendSlice(arena, buf[0..len]);
        } else {
            try out.append(arena, src[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn hexNibble(c: u8) u21 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => 0,
    };
}

pub const Validator = struct {
    arena: std.mem.Allocator,
    diagnostics: ?*Diagnostics,
    source: []const u8,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,

    pub fn run(self: *Validator, program: *const Program) !void {
        defer {
            for (self.scopes.items) |*s| s.deinit(self.arena);
            self.scopes.deinit(self.arena);
        }
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

    fn inScope(self: *Validator, name: []const u8) bool {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
        }
        return false;
    }

    fn enterClass(self: *Validator, body: []const stmt_mod.ClassMember) !void {
        var scope: Scope = .empty;
        for (body) |m| {
            const key_span: ?Span = switch (m) {
                .method => |md| if (md.key == .private) md.key.private else null,
                .field => |fd| if (fd.key == .private) fd.key.private else null,
                .static_block => null,
            };
            if (key_span) |sp| {
                // §13.1 — PrivateBoundIdentifiers compare by
                // StringValue. The lexer keeps `\u`-escapes raw, so
                // we decode here before stashing the name. `#℘` and
                // `#℘` resolve to the same private name.
                const raw = self.source[sp.start..sp.end];
                try scope.append(self.arena, try decodeIdent(self.arena, raw));
            }
        }
        try self.scopes.append(self.arena, scope);
    }

    fn leaveClass(self: *Validator) void {
        var top = self.scopes.pop().?;
        top.deinit(self.arena);
    }

    fn visitClass(
        self: *Validator,
        superclass: ?*const Expression,
        body: []const stmt_mod.ClassMember,
    ) std.mem.Allocator.Error!void {
        if (superclass) |sc| try self.visitExpr(sc);
        try self.enterClass(body);
        defer self.leaveClass();
        for (body) |m| switch (m) {
            .method => |md| {
                switch (md.key) {
                    .computed => |c| try self.visitExpr(c),
                    else => {},
                }
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
                if (fd.init) |ie| try self.visitExpr(&ie);
            },
            .static_block => |sb| {
                for (sb.body) |*s| try self.visitStmt(s);
            },
        };
    }

    // ── Statement walker ────────────────────────────────────────────────

    fn visitStmt(self: *Validator, s: *const Statement) std.mem.Allocator.Error!void {
        switch (s.*) {
            .expression => |*es| try self.visitExpr(&es.expression),
            .block => |b| for (b.body) |*c| try self.visitStmt(c),
            .empty, .debugger_, .break_, .continue_ => {},
            .labeled => |lb| try self.visitStmt(lb.body),
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
                switch (f.left) {
                    .expression => |x| try self.visitExpr(&x),
                    .lexical => |ld| {
                        for (ld.declarators) |*d| {
                            if (d.init) |ie| try self.visitExpr(&ie);
                        }
                    },
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
                for (fd.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                for (fd.body.body) |*c| try self.visitStmt(c);
            },
            .class_decl => |cd| {
                const sc_ptr: ?*const Expression = if (cd.superclass) |*sc| sc else null;
                try self.visitClass(sc_ptr, cd.body);
            },
            .import_decl => {},
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| try self.visitStmt(inner),
                .default_value => |x| try self.visitExpr(&x),
                .named, .all => {},
            },
        }
    }

    // ── Expression walker ───────────────────────────────────────────────

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
                    .ident => |sp| {
                        const raw = self.source[sp.start..sp.end];
                        if (raw.len > 0 and raw[0] == '#') {
                            const text = try decodeIdent(self.arena, raw);
                            if (!self.inScope(text)) {
                                try self.report(.undeclared_private_name, sp);
                            }
                        }
                    },
                    .computed => |c| try self.visitExpr(c),
                }
            },
            // §13.10.2 — `#name in obj` cover form. The LHS of `in` is a
            // PrivateIdentifier with the same scope rule as a member
            // PrivateName reference.
            .private_identifier => |pi| {
                const raw = self.source[pi.span.start..pi.span.end];
                const text = try decodeIdent(self.arena, raw);
                if (!self.inScope(text)) {
                    try self.report(.undeclared_private_name, pi.span);
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
                        for (mt.params) |p| switch (p) {
                            .simple => |spr| if (spr.default) |d| try self.visitExpr(&d),
                            .rest => {},
                        };
                        for (mt.body.body) |*c| try self.visitStmt(c);
                    },
                };
            },
            .arrow_function => |af| {
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
                for (fe.params) |p| switch (p) {
                    .simple => |sp| if (sp.default) |d| try self.visitExpr(&d),
                    .rest => {},
                };
                for (fe.body.body) |*c| try self.visitStmt(c);
            },
            .class_expr => |ce| {
                try self.visitClass(ce.superclass, ce.body);
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
