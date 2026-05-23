//! Library root. Re-exports the public API and aggregates `test` blocks
//! for `zig build test`.

const std = @import("std");

pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");

pub const lexer = struct {
    pub const Lexer = @import("lexer/lexer.zig").Lexer;
    pub const LexError = @import("lexer/lexer.zig").LexError;
    pub const Token = @import("lexer/token.zig").Token;
    pub const TokenKind = @import("lexer/token.zig").TokenKind;
    pub const keywordKind = @import("lexer/token.zig").keywordKind;
};

pub const unicode = struct {
    pub const idents = @import("unicode/idents.zig");
};

pub const ast = @import("ast.zig");

pub const parser = struct {
    pub const Parser = @import("parser/parser.zig").Parser;
    pub const ParseError = @import("parser/parser.zig").ParseError;
    pub const parseScript = @import("parser/parser.zig").parseScript;
    pub const parseModule = @import("parser/parser.zig").parseModule;
};

pub const runtime = @import("runtime.zig");
pub const bytecode = @import("bytecode.zig");

test {
    // Force the compiler to walk every reachable module so that every file's
    // `test` blocks are picked up by `zig build test`.
    _ = source;
    _ = diagnostic;
    _ = lexer;
    _ = unicode;
    _ = ast;
    _ = parser;
    _ = runtime;
    _ = bytecode;
    _ = @import("lexer/lexer.zig");
    _ = @import("lexer/token.zig");
    _ = @import("unicode/idents.zig");
    _ = @import("ast/printer.zig");
    _ = @import("parser/parser.zig");
    _ = @import("parser/parser_test.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/dtoa.zig");
    _ = @import("runtime/string.zig");
    _ = @import("runtime/utf16.zig");
    _ = @import("runtime/function.zig");
    _ = @import("runtime/environment.zig");
    _ = @import("runtime/object.zig");
    _ = @import("runtime/heap.zig");
    _ = @import("runtime/c_alloc.zig");
    _ = @import("runtime/realm.zig");
    _ = @import("runtime/lantern/lantern.zig");
    _ = @import("runtime/lantern/arith.zig");
    _ = @import("runtime/lantern/tests.zig");
    _ = @import("runtime/surface_audit_test.zig");
    _ = @import("runtime/builtins/iterator.zig");
    _ = @import("runtime/builtins/date.zig");
    _ = @import("runtime/builtins/typed_array.zig");
    _ = @import("runtime/builtins/math.zig");
    _ = @import("runtime/builtins/json.zig");
    _ = @import("runtime/builtins/reflect.zig");
    _ = @import("runtime/builtins/symbol.zig");
    _ = @import("runtime/builtins/proxy.zig");
    _ = @import("runtime/builtins/bigint.zig");
    _ = @import("runtime/builtins/regexp.zig");
    _ = @import("runtime/builtins/promise.zig");
    _ = @import("runtime/builtins/collections.zig");
    _ = @import("runtime/builtins/object.zig");
    _ = @import("runtime/builtins/array.zig");
    _ = @import("runtime/builtins/string.zig");
    _ = @import("runtime/builtins/number.zig");
    _ = @import("runtime/builtins/uri.zig");
    _ = @import("runtime/builtins/function.zig");
    _ = @import("runtime/builtins/error.zig");
    _ = @import("bytecode/op.zig");
    _ = @import("bytecode/chunk.zig");
    _ = @import("bytecode/disasm.zig");
    _ = @import("bytecode/scope.zig");
    _ = @import("bytecode/compiler.zig");
    _ = @import("bytecode/literals.zig");
    _ = @import("bytecode/arguments_scan.zig");
}
