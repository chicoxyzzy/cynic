//! The compiled artifact Sarcasm executes — the original bytecode plus
//! the O(1) branch side-table emitted by validation. No internal IR:
//! the interpreter runs the wasm bytes in place (see docs/wasm-engine.md).

const std = @import("std");
const types = @import("types.zig");
const ValType = types.ValType;

/// One side-table entry per reachable branch-consulting instruction
/// (`if` / `else` / `br` / `br_if`), in bytecode order. When a branch
/// is taken, the interpreter relocates the instruction pointer and the
/// side-table pointer by these deltas and shuffles the operand stack.
///
/// The side-table pointer (`stp`) is kept in lockstep with execution:
/// it indexes the entry of the next branch to run. Falling through a
/// not-taken `if` / `br_if` advances `stp` by one; a taken branch adds
/// `delta_stp`, computed by validation so `stp` lands on the entry of
/// the first branch at or after the target.
pub const BranchEntry = struct {
    /// Added to the instruction pointer when the branch is taken.
    delta_ip: i32,
    /// Added to the side-table pointer when the branch is taken.
    delta_stp: i32,
    /// Number of values carried to the target (the label's arity).
    val_count: u32,
    /// Number of values discarded beneath the carried ones.
    pop_count: u32,
};

/// A validated, executable function: the original body bytes (run in
/// place) plus the metadata the interpreter needs to set up a frame
/// and resolve branches.
pub const CompiledFunc = struct {
    type_index: u32,
    /// All local slot types — parameters first, then declared locals.
    /// The frame seeds parameter slots from the caller and zero-inits
    /// the rest by type.
    local_types: []const ValType,
    /// Bytecode for the body's expression — the locals header is
    /// stripped, so `body[0]` is the first instruction. Borrowed from
    /// the module's input buffer.
    body: []const u8,
    /// Branch metadata, indexed by the running side-table pointer.
    side_table: []const BranchEntry,
    /// Peak operand-stack depth (above the locals), from validation —
    /// lets the interpreter size the value stack once.
    max_stack: u32,
};
