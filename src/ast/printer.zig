//! S-expression dumper for AST nodes. Used by both the `cynic parse` CLI
//! subcommand and inline parser tests for golden-string assertions.
//!
//! Format conventions:
//! • One node per line; indent two spaces per depth.
//! • Each node opens with `(<head> <attrs?>` then the node's span as
//! `[start..end]`; children follow on subsequent indented lines.
//! • Terminal-ish nodes (literals, identifiers, binding names) carry a
//! quoted slice of the source as the first attribute.

const std = @import("std");
const ast_expr = @import("expression.zig");
const ast_stmt = @import("statement.zig");
const ast_prog = @import("program.zig");
const Span = @import("../source.zig").Span;

const Expression = ast_expr.Expression;
const Statement = ast_stmt.Statement;
const Program = ast_prog.Program;

/// Render `program` as an S-expression string. Result is allocated from
/// `arena` and is owned by the caller (typically freed by the arena's
/// `deinit`).
pub fn dump(arena: std.mem.Allocator, program: *const Program, source: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(arena);

    var ctx: Ctx = .{ .source = source, .buf = &buf, .arena = arena };
    try writeProgram(&ctx, program, 0);
    return buf.toOwnedSlice(arena);
}

const Ctx = struct {
    source: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    arena: std.mem.Allocator,
};

const WriterError = std.mem.Allocator.Error;

fn writeProgram(ctx: *Ctx, p: *const Program, depth: usize) WriterError!void {
    try indent(ctx, depth);
    try ctx.buf.print(ctx.arena, "(program {s} ", .{@tagName(p.source_kind)});
    try writeSpan(ctx, p.span);
    for (p.body) |stmt| {
        try ctx.buf.append(ctx.arena, '\n');
        try writeStatement(ctx, &stmt, depth + 1);
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeForHead(ctx: *Ctx, head: ast_stmt.ForHead, depth: usize) WriterError!void {
    switch (head) {
        .lexical => |ld| {
            try writeLexicalDecl(ctx, ld, depth);
        },
        .expression => |e| {
            try writeExpression(ctx, &e, depth);
        },
    }
}

fn writeLexicalDecl(ctx: *Ctx, ld: ast_stmt.LexicalDecl, depth: usize) WriterError!void {
    try indent(ctx, depth);
    try ctx.buf.print(ctx.arena, "(lexical kind={s} ", .{@tagName(ld.kind)});
    try writeSpan(ctx, ld.span);
    for (ld.declarators) |d| {
        try ctx.buf.append(ctx.arena, '\n');
        try indent(ctx, depth + 1);
        try ctx.buf.appendSlice(ctx.arena, "(declarator ");
        try writeSpan(ctx, d.span);
        try ctx.buf.append(ctx.arena, '\n');
        try writeBindingTarget(ctx, d.name, depth + 2);
        if (d.init) |init_expr| {
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &init_expr, depth + 2);
        }
        try ctx.buf.append(ctx.arena, ')');
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeBindingTarget(ctx: *Ctx, t: ast_stmt.BindingTarget, depth: usize) WriterError!void {
    try indent(ctx, depth);
    switch (t) {
        .identifier => |id| {
            try ctx.buf.print(ctx.arena, "(binding \"{s}\" ", .{slice(ctx.source, id.span)});
            try writeSpan(ctx, id.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .object => |op| try writeObjectPatternBody(ctx, op, depth),
        .array => |ap| try writeArrayPatternBody(ctx, ap, depth),
    }
}

fn writeObjectPatternBody(ctx: *Ctx, op: ast_stmt.ObjectPattern, depth: usize) WriterError!void {
    try ctx.buf.appendSlice(ctx.arena, "(object-pat ");
    try writeSpan(ctx, op.span);
    for (op.properties) |prop| {
        try ctx.buf.append(ctx.arena, '\n');
        try indent(ctx, depth + 1);
        if (prop.shorthand) {
            try ctx.buf.appendSlice(ctx.arena, "(prop shorthand ");
        } else {
            try ctx.buf.appendSlice(ctx.arena, "(prop ");
        }
        try writeSpan(ctx, prop.span);
        try ctx.buf.append(ctx.arena, '\n');
        try writePropertyKey(ctx, prop.key, depth + 2);
        try ctx.buf.append(ctx.arena, '\n');
        try writeBindingElement(ctx, prop.value, depth + 2);
        try ctx.buf.append(ctx.arena, ')');
    }
    if (op.rest) |r| {
        try ctx.buf.append(ctx.arena, '\n');
        try indent(ctx, depth + 1);
        try ctx.buf.print(ctx.arena, "(rest \"{s}\" ", .{slice(ctx.source, r.span)});
        try writeSpan(ctx, r.span);
        try ctx.buf.append(ctx.arena, ')');
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeArrayPatternBody(ctx: *Ctx, ap: ast_stmt.ArrayPattern, depth: usize) WriterError!void {
    try ctx.buf.appendSlice(ctx.arena, "(array-pat ");
    try writeSpan(ctx, ap.span);
    for (ap.elements) |elt| {
        try ctx.buf.append(ctx.arena, '\n');
        if (elt) |be| {
            try writeBindingElement(ctx, be, depth + 1);
        } else {
            try indent(ctx, depth + 1);
            try ctx.buf.appendSlice(ctx.arena, "(elision)");
        }
    }
    if (ap.rest) |r| {
        try ctx.buf.append(ctx.arena, '\n');
        try indent(ctx, depth + 1);
        try ctx.buf.appendSlice(ctx.arena, "(rest\n");
        try writeBindingTarget(ctx, r.*, depth + 2);
        try ctx.buf.append(ctx.arena, ')');
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeBindingElement(ctx: *Ctx, be: ast_stmt.BindingElement, depth: usize) WriterError!void {
    if (be.default == null) {
        try writeBindingTarget(ctx, be.target, depth);
        return;
    }
    try indent(ctx, depth);
    try ctx.buf.appendSlice(ctx.arena, "(default ");
    try writeSpan(ctx, be.span);
    try ctx.buf.append(ctx.arena, '\n');
    try writeBindingTarget(ctx, be.target, depth + 1);
    try ctx.buf.append(ctx.arena, '\n');
    try writeExpression(ctx, &be.default.?, depth + 1);
    try ctx.buf.append(ctx.arena, ')');
}

fn writeStatement(ctx: *Ctx, s: *const Statement, depth: usize) WriterError!void {
    switch (s.*) {
        .expression => |es| {
            try indent(ctx, depth);
            if (es.directive) |dir| {
                try ctx.buf.print(ctx.arena, "(expr-stmt directive=\"{s}\" ", .{slice(ctx.source, dir)});
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(expr-stmt ");
            }
            try writeSpan(ctx, es.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &es.expression, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .block => |bs| try writeBlock(ctx, bs, depth),
        .empty => |e| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(empty ");
            try writeSpan(ctx, e.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .if_ => |is| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(if ");
            try writeSpan(ctx, is.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &is.test_, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, is.consequent, depth + 1);
            if (is.alternate) |alt| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeStatement(ctx, alt, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .while_ => |ws| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(while ");
            try writeSpan(ctx, ws.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &ws.test_, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, ws.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .do_while => |dw| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(do-while ");
            try writeSpan(ctx, dw.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, dw.body, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &dw.test_, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .return_ => |rs| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(return ");
            try writeSpan(ctx, rs.span);
            if (rs.argument) |arg| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, &arg, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .throw_ => |ts| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(throw ");
            try writeSpan(ctx, ts.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &ts.argument, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .break_ => |bs| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(break ");
            try writeSpan(ctx, bs.span);
            if (bs.label) |lbl| {
                try ctx.buf.print(ctx.arena, " \"{s}\" ", .{slice(ctx.source, lbl)});
                try writeSpan(ctx, lbl);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .continue_ => |cs| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(continue ");
            try writeSpan(ctx, cs.span);
            if (cs.label) |lbl| {
                try ctx.buf.print(ctx.arena, " \"{s}\" ", .{slice(ctx.source, lbl)});
                try writeSpan(ctx, lbl);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .for_ => |fs| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(for ");
            try writeSpan(ctx, fs.span);
            try ctx.buf.append(ctx.arena, '\n');
            try indent(ctx, depth + 1);
            if (fs.init) |init| {
                try ctx.buf.appendSlice(ctx.arena, "(init\n");
                try writeForHead(ctx, init, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(init)");
            }
            try ctx.buf.append(ctx.arena, '\n');
            try indent(ctx, depth + 1);
            if (fs.test_) |t| {
                try ctx.buf.appendSlice(ctx.arena, "(test\n");
                try writeExpression(ctx, &t, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(test)");
            }
            try ctx.buf.append(ctx.arena, '\n');
            try indent(ctx, depth + 1);
            if (fs.update) |u| {
                try ctx.buf.appendSlice(ctx.arena, "(update\n");
                try writeExpression(ctx, &u, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(update)");
            }
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, fs.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .for_in_of => |fio| {
            try indent(ctx, depth);
            const kw: []const u8 = switch (fio.kind) {
                .in_ => "for-in",
                .of_ => if (fio.is_await) "for-await-of" else "for-of",
            };
            try ctx.buf.print(ctx.arena, "({s} ", .{kw});
            try writeSpan(ctx, fio.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeForHead(ctx, fio.left, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &fio.right, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, fio.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .lexical => |ld| try writeLexicalDecl(ctx, ld, depth),
        .try_ => |ts| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(try ");
            try writeSpan(ctx, ts.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeBlock(ctx, ts.block, depth + 1);
            if (ts.handler) |h| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.appendSlice(ctx.arena, "(catch ");
                try writeSpan(ctx, h.span);
                if (h.param) |p| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeBindingTarget(ctx, p, depth + 2);
                }
                try ctx.buf.append(ctx.arena, '\n');
                try writeBlock(ctx, h.body, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            }
            if (ts.finalizer) |f| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.appendSlice(ctx.arena, "(finally\n");
                try writeBlock(ctx, f, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .switch_ => |sw| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(switch ");
            try writeSpan(ctx, sw.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, &sw.discriminant, depth + 1);
            for (sw.cases) |c| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                if (c.test_) |t| {
                    try ctx.buf.appendSlice(ctx.arena, "(case ");
                    try writeSpan(ctx, c.span);
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeExpression(ctx, &t, depth + 2);
                } else {
                    try ctx.buf.appendSlice(ctx.arena, "(default ");
                    try writeSpan(ctx, c.span);
                }
                for (c.body) |stmt| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeStatement(ctx, &stmt, depth + 2);
                }
                try ctx.buf.append(ctx.arena, ')');
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .debugger_ => |d| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(debugger ");
            try writeSpan(ctx, d.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .labeled => |lb| {
            try indent(ctx, depth);
            try ctx.buf.print(ctx.arena, "(labeled \"{s}\" ", .{slice(ctx.source, lb.label)});
            try writeSpan(ctx, lb.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeStatement(ctx, lb.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .import_decl => |id| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(import ");
            try writeSpan(ctx, id.span);
            try ctx.buf.append(ctx.arena, '\n');
            try indent(ctx, depth + 1);
            try ctx.buf.print(ctx.arena, "(source {s} ", .{slice(ctx.source, id.source)});
            try writeSpan(ctx, id.source);
            try ctx.buf.append(ctx.arena, ')');
            if (id.default) |d| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.print(ctx.arena, "(default \"{s}\" ", .{slice(ctx.source, d.span)});
                try writeSpan(ctx, d.span);
                try ctx.buf.append(ctx.arena, ')');
            }
            if (id.namespace) |n| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.print(ctx.arena, "(namespace \"{s}\" ", .{slice(ctx.source, n.span)});
                try writeSpan(ctx, n.span);
                try ctx.buf.append(ctx.arena, ')');
            }
            for (id.named) |n| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.print(ctx.arena, "(named imported=\"{s}\" local=\"{s}\" ", .{
                    slice(ctx.source, n.imported_span),
                    slice(ctx.source, n.local.span),
                });
                try writeSpan(ctx, n.span);
                try ctx.buf.append(ctx.arena, ')');
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .export_decl => |ed| {
            try indent(ctx, depth);
            try ctx.buf.appendSlice(ctx.arena, "(export ");
            try writeSpan(ctx, ed.span);
            try ctx.buf.append(ctx.arena, '\n');
            switch (ed.body) {
                .named => |nb| {
                    try indent(ctx, depth + 1);
                    try ctx.buf.appendSlice(ctx.arena, "(named");
                    if (nb.source) |src| {
                        try ctx.buf.print(ctx.arena, " source={s}", .{slice(ctx.source, src)});
                    }
                    for (nb.specifiers) |spec| {
                        try ctx.buf.append(ctx.arena, '\n');
                        try indent(ctx, depth + 2);
                        try ctx.buf.print(ctx.arena, "(spec local=\"{s}\" exported=\"{s}\" ", .{
                            slice(ctx.source, spec.local_span),
                            slice(ctx.source, spec.exported_span),
                        });
                        try writeSpan(ctx, spec.span);
                        try ctx.buf.append(ctx.arena, ')');
                    }
                    try ctx.buf.append(ctx.arena, ')');
                },
                .all => |ab| {
                    try indent(ctx, depth + 1);
                    try ctx.buf.appendSlice(ctx.arena, "(all");
                    if (ab.namespace_local) |ns| {
                        try ctx.buf.print(ctx.arena, " as=\"{s}\"", .{slice(ctx.source, ns)});
                    }
                    try ctx.buf.print(ctx.arena, " source={s})", .{slice(ctx.source, ab.source)});
                },
                .declaration => |stmt_ptr| {
                    try writeStatement(ctx, stmt_ptr, depth + 1);
                },
                .default_value => |e| {
                    try indent(ctx, depth + 1);
                    try ctx.buf.appendSlice(ctx.arena, "(default\n");
                    try writeExpression(ctx, &e, depth + 2);
                    try ctx.buf.append(ctx.arena, ')');
                },
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .class_decl => |cd| {
            try indent(ctx, depth);
            try ctx.buf.print(ctx.arena, "(class-decl \"{s}\" ", .{slice(ctx.source, cd.name.span)});
            try writeSpan(ctx, cd.span);
            if (cd.superclass) |sup| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.appendSlice(ctx.arena, "(extends\n");
                try writeExpression(ctx, &sup, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            }
            for (cd.body) |m| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeClassMember(ctx, m, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .function_decl => |fd| {
            try indent(ctx, depth);
            const async_attr: []const u8 = if (fd.is_async) "async " else "";
            const gen: []const u8 = if (fd.is_generator) "* " else "";
            try ctx.buf.print(ctx.arena, "(function-decl {s}{s}\"{s}\" ", .{ async_attr, gen, slice(ctx.source, fd.name.span) });
            try writeSpan(ctx, fd.span);
            for (fd.params) |param| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeFunctionParam(ctx, param, depth + 1);
            }
            try ctx.buf.append(ctx.arena, '\n');
            try writeBlock(ctx, fd.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
    }
}

fn writeObjectProperty(ctx: *Ctx, prop: ast_expr.ObjectProperty, depth: usize) WriterError!void {
    try indent(ctx, depth);
    if (prop.shorthand) {
        try ctx.buf.appendSlice(ctx.arena, "(prop shorthand ");
    } else {
        try ctx.buf.appendSlice(ctx.arena, "(prop ");
    }
    try writeSpan(ctx, prop.span);
    try ctx.buf.append(ctx.arena, '\n');
    try indent(ctx, depth + 1);
    switch (prop.key) {
        .ident => |s| {
            try ctx.buf.print(ctx.arena, "(key ident \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .string => |s| {
            try ctx.buf.print(ctx.arena, "(key string {s} ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .numeric => |s| {
            try ctx.buf.print(ctx.arena, "(key numeric \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .computed => |e| {
            try ctx.buf.appendSlice(ctx.arena, "(key computed\n");
            try writeExpression(ctx, e, depth + 2);
            try ctx.buf.append(ctx.arena, ')');
        },
        .private => |s| {
            try ctx.buf.print(ctx.arena, "(key private \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
    }
    if (!prop.shorthand) {
        try ctx.buf.append(ctx.arena, '\n');
        try writeExpression(ctx, &prop.value, depth + 1);
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeClassMember(ctx: *Ctx, m: ast_stmt.ClassMember, depth: usize) WriterError!void {
    try indent(ctx, depth);
    switch (m) {
        .method => |md| {
            const static_attr: []const u8 = if (md.is_static) "static " else "";
            const async_attr: []const u8 = if (md.is_async) "async " else "";
            const gen_attr: []const u8 = if (md.is_generator) "generator " else "";
            const kind_attr: []const u8 = switch (md.kind) {
                .method => "",
                .getter => "getter ",
                .setter => "setter ",
            };
            try ctx.buf.print(ctx.arena, "(method {s}{s}{s}{s}", .{ static_attr, async_attr, gen_attr, kind_attr });
            try writeSpan(ctx, md.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writePropertyKey(ctx, md.key, depth + 1);
            for (md.params) |param| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeFunctionParam(ctx, param, depth + 1);
            }
            try ctx.buf.append(ctx.arena, '\n');
            try writeBlock(ctx, md.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .field => |fd| {
            const static_attr: []const u8 = if (fd.is_static) "static " else "";
            try ctx.buf.print(ctx.arena, "(field {s}", .{static_attr});
            try writeSpan(ctx, fd.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writePropertyKey(ctx, fd.key, depth + 1);
            if (fd.init) |init_expr| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, &init_expr, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .static_block => |sb| {
            try ctx.buf.appendSlice(ctx.arena, "(static-block ");
            try writeSpan(ctx, sb.span);
            for (sb.body) |child| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeStatement(ctx, &child, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
    }
}

fn writePropertyKey(ctx: *Ctx, key: ast_expr.PropertyKey, depth: usize) WriterError!void {
    try indent(ctx, depth);
    switch (key) {
        .ident => |s| {
            try ctx.buf.print(ctx.arena, "(key ident \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .string => |s| {
            try ctx.buf.print(ctx.arena, "(key string {s} ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .numeric => |s| {
            try ctx.buf.print(ctx.arena, "(key numeric \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
        .computed => |e| {
            try ctx.buf.appendSlice(ctx.arena, "(key computed\n");
            try writeExpression(ctx, e, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .private => |s| {
            try ctx.buf.print(ctx.arena, "(key private \"{s}\" ", .{slice(ctx.source, s)});
            try writeSpan(ctx, s);
            try ctx.buf.append(ctx.arena, ')');
        },
    }
}

fn writeFunctionParam(ctx: *Ctx, param: ast_stmt.FunctionParam, depth: usize) WriterError!void {
    try indent(ctx, depth);
    switch (param) {
        .simple => |s| {
            // Inline form for the common identifier-target case keeps the
            // common output compact: `(param "x" [span])`. Pattern targets
            // use a nested form.
            if (s.target == .identifier) {
                try ctx.buf.print(ctx.arena, "(param \"{s}\" ", .{slice(ctx.source, s.target.identifier.span)});
                try writeSpan(ctx, s.span);
                if (s.default) |def| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeExpression(ctx, &def, depth + 1);
                }
                try ctx.buf.append(ctx.arena, ')');
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(param ");
                try writeSpan(ctx, s.span);
                try ctx.buf.append(ctx.arena, '\n');
                try writeBindingTarget(ctx, s.target, depth + 1);
                if (s.default) |def| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeExpression(ctx, &def, depth + 1);
                }
                try ctx.buf.append(ctx.arena, ')');
            }
        },
        .rest => |r| {
            if (r.target == .identifier) {
                try ctx.buf.print(ctx.arena, "(rest \"{s}\" ", .{slice(ctx.source, r.target.identifier.span)});
                try writeSpan(ctx, r.span);
                try ctx.buf.append(ctx.arena, ')');
            } else {
                try ctx.buf.appendSlice(ctx.arena, "(rest ");
                try writeSpan(ctx, r.span);
                try ctx.buf.append(ctx.arena, '\n');
                try writeBindingTarget(ctx, r.target, depth + 1);
                try ctx.buf.append(ctx.arena, ')');
            }
        },
    }
}

fn writeBlock(ctx: *Ctx, b: ast_stmt.BlockStmt, depth: usize) WriterError!void {
    try indent(ctx, depth);
    try ctx.buf.appendSlice(ctx.arena, "(block ");
    try writeSpan(ctx, b.span);
    for (b.body) |child| {
        try ctx.buf.append(ctx.arena, '\n');
        try writeStatement(ctx, &child, depth + 1);
    }
    try ctx.buf.append(ctx.arena, ')');
}

fn writeExpression(ctx: *Ctx, e: *const Expression, depth: usize) WriterError!void {
    try indent(ctx, depth);
    switch (e.*) {
        .null_literal => |n| {
            try ctx.buf.appendSlice(ctx.arena, "(null ");
            try writeSpan(ctx, n.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .boolean_literal => |b| {
            try ctx.buf.print(ctx.arena, "(bool {} ", .{b.value});
            try writeSpan(ctx, b.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .numeric_literal => |n| {
            try ctx.buf.print(ctx.arena, "(numeric \"{s}\" ", .{slice(ctx.source, n.span)});
            try writeSpan(ctx, n.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .bigint_literal => |n| {
            try ctx.buf.print(ctx.arena, "(bigint \"{s}\" ", .{slice(ctx.source, n.span)});
            try writeSpan(ctx, n.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .string_literal => |n| {
            try ctx.buf.print(ctx.arena, "(string {s} ", .{slice(ctx.source, n.span)});
            try writeSpan(ctx, n.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .template_literal => |t| {
            try ctx.buf.appendSlice(ctx.arena, "(template ");
            try writeSpan(ctx, t.span);
            for (t.quasis, 0..) |q, i| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.print(ctx.arena, "(quasi \"{s}\" ", .{slice(ctx.source, q.span)});
                try writeSpan(ctx, q.span);
                try ctx.buf.append(ctx.arena, ')');
                if (i < t.expressions.len) {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeExpression(ctx, &t.expressions[i], depth + 1);
                }
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .identifier_reference => |ir| {
            try ctx.buf.print(ctx.arena, "(ident \"{s}\" ", .{slice(ctx.source, ir.span)});
            try writeSpan(ctx, ir.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .parenthesized => |p| {
            try ctx.buf.appendSlice(ctx.arena, "(paren ");
            try writeSpan(ctx, p.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, p.expression, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .unary => |u| {
            try ctx.buf.print(ctx.arena, "(unary op={s} ", .{u.op.lexeme()});
            try writeSpan(ctx, u.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, u.operand, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .binary => |b| {
            try ctx.buf.print(ctx.arena, "(binary op={s} ", .{b.op.lexeme()});
            try writeSpan(ctx, b.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, b.lhs, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, b.rhs, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .logical => |l| {
            try ctx.buf.print(ctx.arena, "(logical op={s} ", .{l.op.lexeme()});
            try writeSpan(ctx, l.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, l.lhs, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, l.rhs, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .conditional => |c| {
            try ctx.buf.appendSlice(ctx.arena, "(cond ");
            try writeSpan(ctx, c.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, c.test_, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, c.consequent, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, c.alternate, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .assignment => |a| {
            try ctx.buf.print(ctx.arena, "(assign op={s} ", .{a.op.lexeme()});
            try writeSpan(ctx, a.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, a.target, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, a.value, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .sequence => |seq| {
            try ctx.buf.appendSlice(ctx.arena, "(seq ");
            try writeSpan(ctx, seq.span);
            for (seq.expressions) |child| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, &child, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .member => |m| {
            const computed_attr: []const u8 = if (m.property == .computed) "computed " else "";
            const optional_attr: []const u8 = if (m.optional) "optional " else "";
            try ctx.buf.print(ctx.arena, "(member {s}{s}", .{ computed_attr, optional_attr });
            try writeSpan(ctx, m.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, m.object, depth + 1);
            switch (m.property) {
                .ident => |s| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try indent(ctx, depth + 1);
                    try ctx.buf.print(ctx.arena, "(prop \"{s}\" ", .{slice(ctx.source, s)});
                    try writeSpan(ctx, s);
                    try ctx.buf.append(ctx.arena, ')');
                },
                .computed => |key| {
                    try ctx.buf.append(ctx.arena, '\n');
                    try writeExpression(ctx, key, depth + 1);
                },
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .call => |c| {
            const optional_attr: []const u8 = if (c.optional) "optional " else "";
            try ctx.buf.print(ctx.arena, "(call {s}", .{optional_attr});
            try writeSpan(ctx, c.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, c.callee, depth + 1);
            for (c.arguments) |arg| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, &arg, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .new_expr => |n| {
            try ctx.buf.appendSlice(ctx.arena, "(new ");
            try writeSpan(ctx, n.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, n.callee, depth + 1);
            for (n.arguments) |arg| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, &arg, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .chain => |ch| {
            try ctx.buf.appendSlice(ctx.arena, "(chain ");
            try writeSpan(ctx, ch.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, ch.expression, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .tagged_template => |tt| {
            try ctx.buf.appendSlice(ctx.arena, "(tagged-template ");
            try writeSpan(ctx, tt.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, tt.tag, depth + 1);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, tt.quasi, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .spread => |sp| {
            try ctx.buf.appendSlice(ctx.arena, "(spread ");
            try writeSpan(ctx, sp.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, sp.argument, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .update => |u| {
            const pos: []const u8 = if (u.prefix) "prefix" else "postfix";
            try ctx.buf.print(ctx.arena, "(update op={s} {s} ", .{ u.op.lexeme(), pos });
            try writeSpan(ctx, u.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, u.operand, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .array_literal => |a| {
            try ctx.buf.appendSlice(ctx.arena, "(array ");
            try writeSpan(ctx, a.span);
            for (a.elements) |elt| {
                try ctx.buf.append(ctx.arena, '\n');
                if (elt) |v| {
                    try writeExpression(ctx, &v, depth + 1);
                } else {
                    try indent(ctx, depth + 1);
                    try ctx.buf.appendSlice(ctx.arena, "(elision)");
                }
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .object_literal => |o| {
            try ctx.buf.appendSlice(ctx.arena, "(object ");
            try writeSpan(ctx, o.span);
            for (o.properties) |m| {
                try ctx.buf.append(ctx.arena, '\n');
                switch (m) {
                    .property => |prop| try writeObjectProperty(ctx, prop, depth + 1),
                    .spread => |sp| {
                        try indent(ctx, depth + 1);
                        try ctx.buf.appendSlice(ctx.arena, "(spread ");
                        try writeSpan(ctx, sp.span);
                        try ctx.buf.append(ctx.arena, '\n');
                        try writeExpression(ctx, sp.argument, depth + 2);
                        try ctx.buf.append(ctx.arena, ')');
                    },
                    .method => |md| {
                        try indent(ctx, depth + 1);
                        const async_attr: []const u8 = if (md.is_async) "async " else "";
                        const gen_attr: []const u8 = if (md.is_generator) "generator " else "";
                        const kind_attr: []const u8 = switch (md.kind) {
                            .method => "",
                            .getter => "getter ",
                            .setter => "setter ",
                        };
                        try ctx.buf.print(ctx.arena, "(method {s}{s}{s}", .{ async_attr, gen_attr, kind_attr });
                        try writeSpan(ctx, md.span);
                        try ctx.buf.append(ctx.arena, '\n');
                        try writePropertyKey(ctx, md.key, depth + 2);
                        for (md.params) |param| {
                            try ctx.buf.append(ctx.arena, '\n');
                            try writeFunctionParam(ctx, param, depth + 2);
                        }
                        try ctx.buf.append(ctx.arena, '\n');
                        try writeBlock(ctx, md.body, depth + 2);
                        try ctx.buf.append(ctx.arena, ')');
                    },
                }
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .this_expr => |t| {
            try ctx.buf.appendSlice(ctx.arena, "(this ");
            try writeSpan(ctx, t.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .super_ => |s| {
            try ctx.buf.appendSlice(ctx.arena, "(super ");
            try writeSpan(ctx, s.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .yield => |y| {
            const star: []const u8 = if (y.delegate) "* " else "";
            try ctx.buf.print(ctx.arena, "(yield {s}", .{star});
            try writeSpan(ctx, y.span);
            if (y.argument) |arg| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeExpression(ctx, arg, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .await_ => |a| {
            try ctx.buf.appendSlice(ctx.arena, "(await ");
            try writeSpan(ctx, a.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, a.argument, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .regex_literal => |r| {
            try ctx.buf.print(ctx.arena, "(regex {s} ", .{slice(ctx.source, r.span)});
            try writeSpan(ctx, r.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .import_call => |ic| {
            try ctx.buf.appendSlice(ctx.arena, "(import-call ");
            try writeSpan(ctx, ic.span);
            try ctx.buf.append(ctx.arena, '\n');
            try writeExpression(ctx, ic.source, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
        .import_meta => |im| {
            try ctx.buf.appendSlice(ctx.arena, "(import-meta ");
            try writeSpan(ctx, im.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .new_target => |nt| {
            try ctx.buf.appendSlice(ctx.arena, "(new-target ");
            try writeSpan(ctx, nt.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .private_identifier => |pi| {
            try ctx.buf.print(ctx.arena, "(private-ident \"{s}\" ", .{slice(ctx.source, pi.span)});
            try writeSpan(ctx, pi.span);
            try ctx.buf.append(ctx.arena, ')');
        },
        .class_expr => |ce| {
            try ctx.buf.appendSlice(ctx.arena, "(class-expr ");
            if (ce.name) |n| {
                try ctx.buf.print(ctx.arena, "\"{s}\" ", .{slice(ctx.source, n.span)});
            }
            try writeSpan(ctx, ce.span);
            if (ce.superclass) |sup| {
                try ctx.buf.append(ctx.arena, '\n');
                try indent(ctx, depth + 1);
                try ctx.buf.appendSlice(ctx.arena, "(extends\n");
                try writeExpression(ctx, sup, depth + 2);
                try ctx.buf.append(ctx.arena, ')');
            }
            for (ce.body) |m| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeClassMember(ctx, m, depth + 1);
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .arrow_function => |arr| {
            try ctx.buf.appendSlice(ctx.arena, "(arrow ");
            if (arr.is_async) try ctx.buf.appendSlice(ctx.arena, "async ");
            try writeSpan(ctx, arr.span);
            for (arr.params) |param| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeFunctionParam(ctx, param, depth + 1);
            }
            try ctx.buf.append(ctx.arena, '\n');
            switch (arr.body) {
                .block => |b| try writeBlock(ctx, b, depth + 1),
                .expression => |body_expr| try writeExpression(ctx, body_expr, depth + 1),
            }
            try ctx.buf.append(ctx.arena, ')');
        },
        .function_expr => |fe| {
            try ctx.buf.appendSlice(ctx.arena, "(function-expr ");
            if (fe.is_async) try ctx.buf.appendSlice(ctx.arena, "async ");
            if (fe.is_generator) try ctx.buf.appendSlice(ctx.arena, "* ");
            if (fe.name) |n| {
                try ctx.buf.print(ctx.arena, "\"{s}\" ", .{slice(ctx.source, n.span)});
            }
            try writeSpan(ctx, fe.span);
            for (fe.params) |param| {
                try ctx.buf.append(ctx.arena, '\n');
                try writeFunctionParam(ctx, param, depth + 1);
            }
            try ctx.buf.append(ctx.arena, '\n');
            try writeBlock(ctx, fe.body, depth + 1);
            try ctx.buf.append(ctx.arena, ')');
        },
    }
}

fn writeSpan(ctx: *Ctx, s: Span) WriterError!void {
    try ctx.buf.print(ctx.arena, "[{d}..{d}]", .{ s.start, s.end });
}

fn indent(ctx: *Ctx, depth: usize) WriterError!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try ctx.buf.appendSlice(ctx.arena, "  ");
}

fn slice(source: []const u8, s: Span) []const u8 {
    return source[s.start..s.end];
}

// ---------------------------------------------------------------------------
// Tests — printer is exercised against hand-built ASTs so failures here
// indicate dumper regressions independent of the parser.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn dumpProgram(arena: std.mem.Allocator, body: []ast_stmt.Statement, source: []const u8) ![]u8 {
    const program: Program = .{
        .span = .{ .start = 0, .end = @intCast(source.len) },
        .source_kind = .script,
        .body = body,
    };
    return dump(arena, &program, source);
}

test "printer: empty program" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try dumpProgram(arena.allocator(), &.{}, "");
    try testing.expectEqualStrings("(program script [0..0])", out);
}

test "printer: null literal expression statement" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = "null;";
    var body = [_]ast_stmt.Statement{
        .{ .expression = .{
            .span = .{ .start = 0, .end = 5 },
            .expression = .{ .null_literal = .{ .span = .{ .start = 0, .end = 4 } } },
        } },
    };
    const out = try dumpProgram(arena.allocator(), &body, src);
    try testing.expectEqualStrings(
        "(program script [0..5]\n  (expr-stmt [0..5]\n    (null [0..4])))",
        out,
    );
}

test "printer: numeric and binary expression" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = "1 + 2";
    const a = arena.allocator();
    const lhs = try a.create(Expression);
    lhs.* = .{ .numeric_literal = .{ .span = .{ .start = 0, .end = 1 } } };
    const rhs = try a.create(Expression);
    rhs.* = .{ .numeric_literal = .{ .span = .{ .start = 4, .end = 5 } } };
    var body = [_]ast_stmt.Statement{
        .{ .expression = .{
            .span = .{ .start = 0, .end = 5 },
            .expression = .{ .binary = .{
                .span = .{ .start = 0, .end = 5 },
                .op = .plus,
                .lhs = lhs,
                .rhs = rhs,
            } },
        } },
    };
    const out = try dumpProgram(a, &body, src);
    try testing.expectEqualStrings(
        \\(program script [0..5]
        \\  (expr-stmt [0..5]
        \\    (binary op=+ [0..5]
        \\      (numeric "1" [0..1])
        \\      (numeric "2" [4..5]))))
    , out);
}

test "printer: lexical declaration with initializer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = "let x = 1;";
    var declarators = [_]ast_stmt.VariableDeclarator{
        .{
            .span = .{ .start = 4, .end = 9 },
            .name = .{ .identifier = .{ .span = .{ .start = 4, .end = 5 } } },
            .init = .{ .numeric_literal = .{ .span = .{ .start = 8, .end = 9 } } },
        },
    };
    var body = [_]ast_stmt.Statement{
        .{ .lexical = .{
            .span = .{ .start = 0, .end = 10 },
            .kind = .let_,
            .declarators = &declarators,
        } },
    };
    const out = try dumpProgram(arena.allocator(), &body, src);
    try testing.expectEqualStrings(
        \\(program script [0..10]
        \\  (lexical kind=let_ [0..10]
        \\    (declarator [4..9]
        \\      (binding "x" [4..5])
        \\      (numeric "1" [8..9]))))
    , out);
}

test "printer: ident, paren, unary nested" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = "!(a)";
    const a_alloc = arena.allocator();
    const ident_e = try a_alloc.create(Expression);
    ident_e.* = .{ .identifier_reference = .{ .span = .{ .start = 2, .end = 3 } } };
    const paren_e = try a_alloc.create(Expression);
    paren_e.* = .{ .parenthesized = .{
        .span = .{ .start = 1, .end = 4 },
        .expression = ident_e,
    } };
    var body = [_]ast_stmt.Statement{
        .{ .expression = .{
            .span = .{ .start = 0, .end = 4 },
            .expression = .{ .unary = .{
                .span = .{ .start = 0, .end = 4 },
                .op = .bang,
                .operand = paren_e,
            } },
        } },
    };
    const out = try dumpProgram(a_alloc, &body, src);
    try testing.expectEqualStrings(
        \\(program script [0..4]
        \\  (expr-stmt [0..4]
        \\    (unary op=! [0..4]
        \\      (paren [1..4]
        \\        (ident "a" [2..3])))))
    , out);
}
