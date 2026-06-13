//! Bytecode barrel module — opcode set, chunk format, disassembler,
//! and (later) compiler entry point. The runtime/interpreter
//! consumes a `Chunk` produced from this layer.

pub const op = @import("bytecode/op.zig");
pub const Op = op.Op;

pub const chunk = @import("bytecode/chunk.zig");
pub const Chunk = chunk.Chunk;
pub const Builder = chunk.Builder;
pub const SourcePos = chunk.SourcePos;

pub const disasm = @import("bytecode/disasm.zig");

pub const liveness = @import("bytecode/liveness.zig");

pub const regalloc = @import("bytecode/regalloc.zig");

pub const scope = @import("bytecode/scope.zig");

pub const compiler = @import("bytecode/compiler.zig");
pub const compileExpressionAsChunk = compiler.compileExpressionAsChunk;
