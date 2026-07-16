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
    pub const properties = @import("unicode/properties.zig");
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

/// Perlex — Cynic's native regex engine. Self-contained (std only);
/// the RegExp bridge routes supported patterns here and falls back to
/// the vendored matcher for the rest.
pub const perlex = @import("perlex/perlex.zig");

/// Value → display-string formatter used by the playground panel.
/// Lives at the library boundary (not under `runtime/`) because it
/// is a display concern — the engine itself does not need it, but
/// surfacing it here lets both `playground/wasm.zig` and host
/// unit tests reach the same code.
pub const wasm_format = @import("wasm_format.zig");

/// Diagnostics → playground-frame error text. Same rationale as
/// `wasm_format`: extracted from `playground/wasm.zig` so
/// `zig build test` can exercise the helpers (the playground entry
/// is wasm32-only).
pub const wasm_diag = @import("wasm_diag.zig");

/// WebAssembly module → WAT text, for the playground's "wasm" inspector
/// tab (the structure + disassembly analog of the JS AST / bytecode
/// views). Library-boundary like `wasm_format` so `zig build test` can
/// exercise the printer; the playground entry that drives it is
/// wasm32-only.
pub const wasm_inspect = @import("wasm_inspect.zig");

/// WebAssembly execution engine — decoder, validator, interpreter.
/// Implements §1-§5 of the WebAssembly Core specification natively;
/// the JS API surface (`WebAssembly.Module/Instance/Memory/...`)
/// lives in `src/runtime/builtins/webassembly.zig`. Strictly distinct
/// from `wasm.zig`, which is Cynic compiled *as* a wasm
/// module for the in-browser playground.
pub const wasm = @import("runtime/wasm/wasm.zig");

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
    _ = perlex;
    _ = @import("perlex/perlex.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("lexer/token.zig");
    _ = @import("unicode/idents.zig");
    _ = @import("unicode/properties.zig");
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
    _ = @import("runtime/realm.zig");
    _ = @import("runtime/temporal.zig");
    _ = @import("runtime/intl_config.zig");
    _ = @import("runtime/tzdata.zig");
    _ = @import("runtime/cldr.zig");
    _ = @import("runtime/lantern/interpreter.zig");
    _ = @import("runtime/lantern/arith.zig");
    _ = @import("runtime/lantern/tests.zig");
    _ = @import("runtime/surface_audit_test.zig");
    _ = @import("runtime/annex_b_rejection_test.zig");
    _ = @import("runtime/intl_test.zig");
    _ = @import("runtime/uax29.zig");
    _ = @import("runtime/eval_policy_test.zig");
    _ = @import("runtime/eval_test.zig");
    _ = @import("runtime/wasm_js_test.zig");
    _ = @import("runtime/shared_array_buffer_test.zig");
    _ = @import("runtime/atomics_test.zig");
    _ = @import("runtime/multi_agent_test.zig");
    _ = @import("runtime/realm_test.zig");
    _ = @import("runtime/snapshot.zig");
    _ = @import("runtime/module_test.zig");
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
    _ = @import("runtime/builtins/temporal.zig");
    _ = @import("runtime/builtins/fuzzilli.zig");
    _ = @import("runtime/builtins/webassembly.zig");
    _ = @import("bytecode/op.zig");
    _ = @import("bytecode/chunk.zig");
    _ = @import("bytecode/disasm.zig");
    _ = @import("bytecode/stats.zig");
    _ = @import("bytecode/scope.zig");
    _ = @import("bytecode/compiler.zig");
    _ = @import("bytecode/literals.zig");
    _ = @import("bytecode/arguments_scan.zig");
    _ = @import("wasm_format.zig");
    _ = @import("wasm_diag.zig");
    _ = @import("wasm_inspect.zig");
    _ = wasm;
    _ = @import("runtime/wasm/wasm.zig");
    _ = @import("runtime/wasm/reader.zig");
    _ = @import("runtime/wasm/types.zig");
    _ = @import("runtime/wasm/module.zig");
    _ = @import("runtime/wasm/decoder.zig");
    _ = @import("runtime/wasm/opcodes.zig");
    _ = @import("runtime/wasm/code.zig");
    _ = @import("runtime/wasm/validator.zig");
    _ = @import("runtime/wasm/interpreter.zig");
    _ = @import("runtime/wasm/spasm.zig");
    _ = @import("runtime/wasm/tests.zig");
    _ = @import("runtime/jit/code_alloc.zig");
    _ = @import("runtime/jit/asm_aarch64.zig");
    _ = @import("runtime/jit/masm.zig");
    _ = @import("runtime/jit/layout.zig");
    _ = @import("runtime/bistromath/bistromath.zig");
    _ = @import("runtime/ohaimark/ohaimark.zig");
    _ = @import("runtime/ohaimark/tests.zig");
    _ = @import("runtime/ohaimark/allocation_test.zig");
    _ = @import("runtime/ohaimark/lowering_aarch64_test.zig");
    _ = @import("runtime/ohaimark/emitter_aarch64_test.zig");
    _ = @import("runtime/ohaimark/emitter_graph_test.zig");
}
