//! `JSGenerator` — runtime state for a `function*` instance.
//!
//! A generator carries its entire frame state across `yield`
//! suspensions. On `gen.next(arg)`:
//! 1. The runtime pushes a frame whose `chunk`, `ip`,
//! `accumulator`, `registers`, `env`, `this_value`,
//! `home_object`, and `argc` are restored from the
//! generator's slots.
//! 2. `accumulator` is overwritten with `arg` so the user's
//! `let x = yield e` reads the sent value.
//! 3. The dispatch loop runs until either a `gen_yield` op
//! (suspends and returns `{value, done: false}`) or a
//! `Return` (completes and returns `{value, done: true}`).
//!
//! Spec anchor: §27.5 GeneratorObjects.

const std = @import("std");

const Value = @import("value.zig").Value;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const Environment = @import("environment.zig").Environment;
const JSObject = @import("object.zig").JSObject;

pub const GeneratorState = enum(u8) {
    /// Newly allocated; body hasn't run.
    initial,
    /// Yielded; ready to resume.
    suspended,
    /// Currently running (re-entrancy guard for `gen.next()`
    /// called inside the generator's own body).
    executing,
    /// `Return` reached or the body threw uncaught.
    completed,
};

/// Per-generator saved frame. Allocated by the runtime when a
/// `function*` instance is called; freed by mark-sweep when no
/// longer reachable.
///
/// As of later the same shape backs `async function` suspension —
/// `is_async = true` distinguishes the path. On a pending
/// `await`, the runtime saves the frame into the gen, registers
/// the gen as a "waiter" on the awaited Promise, and unwinds.
/// When the Promise settles, a microtask resumes the gen and
/// either continues or settles `result_promise` accordingly.
pub const JSGenerator = struct {
    /// Body's compiled bytecode. Borrowed from the function
    /// template's chunk.
    chunk: *const Chunk,
    /// Resume point. 0 on first call (start of body).
    ip: usize = 0,
    /// Accumulator at last suspension (or the arg sent in via
    /// `gen.next(arg)` just before resume).
    accumulator: Value = Value.undefined_,
    /// Owned register file. Allocated once at `function*` call
    /// time; freed in `deinit`.
    registers: []Value,
    /// Lexical env at last suspension.
    env: ?*Environment,
    this_value: Value = Value.undefined_,
    home_object: ?*JSObject = null,
    argc: u8 = 0,
    state: GeneratorState = .initial,
    marked: bool = false,
    /// True when this generator backs an `async function`'s
    /// frame rather than a `function*`. Drives the await /
    /// return / throw paths to settle `result_promise` instead
    /// of yielding `{value, done}` records.
    is_async: bool = false,
    /// For async functions only: the Promise the function
    /// returned to its caller. Settled fulfilled when the body
    /// returns normally, rejected when it throws uncaught. The
    /// caller observes settlement either synchronously (body
    /// completed before returning) or via a microtask drain
    /// (body suspended on a pending await).
    result_promise: ?Value = null,

    pub fn init(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        register_count: u8,
        captured_env: ?*Environment,
        this_value: Value,
    ) !*JSGenerator {
        const regs = try allocator.alloc(Value, register_count);
        @memset(regs, Value.undefined_);
        const g = try allocator.create(JSGenerator);
        g.* = .{
            .chunk = chunk,
            .registers = regs,
            .env = captured_env,
            .this_value = this_value,
        };
        return g;
    }

    pub fn deinit(self: *JSGenerator, allocator: std.mem.Allocator) void {
        allocator.free(self.registers);
        allocator.destroy(self);
    }
};
