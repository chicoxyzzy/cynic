//! Top-level AST node — `Program` covers both Script (§16.1) and Module
//! (§16.2). Module support is deferred; the discriminator exists so future
//! parser work can flip on it without re-shaping everything below.

const Span = @import("../source.zig").Span;
const stmt = @import("statement.zig");

pub const Program = struct {
    span: Span,
    source_kind: SourceKind,
    body: []stmt.Statement,

    pub const SourceKind = enum { script, module };
};
