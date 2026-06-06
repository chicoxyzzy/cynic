//! WebAssembly execution engine.
//!
//! Native Zig implementation of the WebAssembly Core specification
//! (https://webassembly.github.io/spec/core/). Strictly distinct
//! from `src/playground_wasm.zig`, which is Cynic compiled *as* a
//! wasm32-freestanding module for the in-browser playground:
//!
//!   src/playground_wasm.zig    Cynic ➜ WASM   (an output target)
//!   src/runtime/wasm/          WASM ➜ Cynic   (an execution surface)
//!
//! The decoder + validator + interpreter live here; the JS-visible
//! API surface (`WebAssembly.Module`, `.Instance`, `.Memory`, …) is
//! installed from `src/runtime/builtins/webassembly.zig` once that
//! step lands.
//!
//! Architecture — see `docs/wasm-engine.md` for the full design and
//! the prior art behind it (Titzer, OOPSLA 2022). In short: the
//! bytecode is interpreted *in place* — never rewritten to an
//! internal IR. Validation emits a compact O(1) side-table of branch
//! metadata as a side-effect; the interpreter is a threaded-dispatch
//! loop (Lantern's `continue :dispatch` idiom) over the original
//! bytecode plus that side-table, against an unboxed value stack
//! whose reference slots carry lazy type tags for precise GC. This
//! gives best-in-class startup and memory — the metrics Cynic's edge
//! target rewards — at throughput on par with rewriting interpreters.
//!
//! Scope is the standardized baseline used by every modern toolchain:
//! MVP plus the universally-shipped post-MVP features
//! (`mutable-globals`, `sign-extension-ops`,
//! `non-trapping-float-to-int`, `multi-value`, `bulk-memory`,
//! `reference-types`, `simd`). Phased: integer + control first, then
//! memory, then JS API, then refs, then floats, then SIMD; spec
//! testsuite harness scores progress in `wasm-results.md`.

pub const reader = @import("reader.zig");
pub const types = @import("types.zig");
pub const module = @import("module.zig");
pub const decoder = @import("decoder.zig");

pub const Reader = reader.Reader;
pub const Module = module.Module;
pub const ValType = types.ValType;
pub const RefType = types.RefType;
pub const FuncType = types.FuncType;
pub const DecodeError = decoder.DecodeError;
pub const decode = decoder.decode;

test {
    _ = @import("reader.zig");
    _ = @import("types.zig");
    _ = @import("module.zig");
    _ = @import("decoder.zig");
    _ = @import("tests.zig");
}
