//! Public AST surface. Imported by the parser, the printer, and consumers.

pub const expression = @import("ast/expression.zig");
pub const statement = @import("ast/statement.zig");
pub const program = @import("ast/program.zig");
pub const printer = @import("ast/printer.zig");

pub const Expression = expression.Expression;
pub const Statement = statement.Statement;
pub const Program = program.Program;

test {
    _ = expression;
    _ = statement;
    _ = program;
    _ = printer;
}
