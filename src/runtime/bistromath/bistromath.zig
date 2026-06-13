//! Bistromath — the T1 baseline JIT (docs/jit.md §4). A single
//! forward pass over Lantern bytecode emitting machine code per
//! opcode: inline fast paths for Smi arithmetic and moves, and a
//! tier-down to the interpreter for everything the fast path can't
//! prove. No IR, no register allocation, no speculation, no deopt
//! metadata — the frame-identity rule (docs/jit.md §4.2) makes
//! "give up" a synced store and a return.
//!
//! Execution contract: a compiled activation drives the SAME
//! `CallFrame` Lantern would (registers in the same pooled slice,
//! accumulator flushed on every exit), so the GC, the watchdog,
//! and the unwinder cannot tell which tier is running. The entry
//! returns either `done` (function completed; result in
//! `frame.accumulator`; caller pops, mirroring the interpreter's
//! plain `return_` path) or `resume_interp` (`frame.ip` set to a
//! bytecode offset; the frame stays pushed and `reEnterDispatch`
//! resumes it in Lantern mid-chunk).
//!
//! MVP scope (docs/jit.md §12 step 2): moves, constants, int32
//! arithmetic/bitwise/compares, branches, `loop_inc_lt`, and
//! `return_`. A chunk containing anything else is `dont_compile`
//! — function-granularity fallback means no mid-function bailout
//! machinery exists or is needed. Calls, property ICs, and OSR
//! arrive with step 3.

const std = @import("std");
const builtin = @import("builtin");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const op_mod = @import("../../bytecode/op.zig");
const Op = op_mod.Op;
const Value = @import("../value.zig").Value;
const Realm = @import("../realm.zig").Realm;
const interpreter = @import("../lantern/interpreter.zig");
const CallFrame = interpreter.CallFrame;
const RunError = interpreter.RunError;
const code_alloc = @import("../jit/code_alloc.zig");
const masm_mod = @import("../jit/masm.zig");
const Masm = masm_mod.Masm;
const a64 = @import("../jit/asm_aarch64.zig");
const layout = @import("../jit/layout.zig");
const JSObject = @import("../object.zig").JSObject;
const heap_mod = @import("../heap.zig");

/// Bistromath needs both an executable-memory target and an
/// emitter for the host ISA. x86_64 hosts run the engine fine but
/// stay interpreter-only until the second encoder lands
/// (docs/jit.md §14).
pub const supported = code_alloc.supported and builtin.cpu.arch == .aarch64;

/// What compiled code reports back to the dispatcher.
pub const EntryResult = enum(u32) {
    /// `frame.ip` / `frame.accumulator` are synced; resume the
    /// frame in Lantern (tier-down — docs/jit.md §4.5/§4.6).
    resume_interp = 0,
    /// The function ran to completion; the return value is in
    /// `frame.accumulator` and the caller pops the frame.
    done = 1,
    /// A callee (or a nested call) threw: `realm.pending_exception`
    /// holds the value and `frame.ip` sits at the faulting call op,
    /// so `unwindThrow` checks this frame's own handlers first —
    /// catching tiers the frame down at the handler (docs/jit.md
    /// §4.5), and an unhandled throw keeps unwinding the caller
    /// stack. The frame stays pushed.
    threw = 2,
    /// The host ran out of memory inside a call — propagated as
    /// `error.OutOfMemory` (never re-executed: the callee may have
    /// had side effects).
    host_oom = 3,
};

/// What the dispatcher hook tells its caller.
pub const EnterOutcome = union(enum) {
    /// The tier didn't take the frame — proceed into Lantern as if
    /// no JIT existed (also the tier-down case: the frame stays
    /// pushed mid-chunk and `reEnterDispatch` resumes it).
    not_entered,
    /// The callee ran to completion and its frame was popped; hand
    /// the value to the caller exactly as `return_` would.
    completed: Value,
    /// The frame (still pushed) has a pending exception at
    /// `frame.ip` — dispatch `unwindThrow` against the frame stack.
    threw: Value,
};

/// Entry ABI: `(realm, frame, registers_base)`. The register-file
/// base rides as its own argument so machine code never assumes
/// Zig's slice layout.
pub const EntryFn = *const fn (*Realm, *CallFrame, [*]Value) callconv(.c) u32;

/// Size-scaled tier-up threshold (docs/jit.md §4.7): a tiny helper
/// compiles after ~30 calls, a big function waits for real heat.
/// Starting constants, tuned against the bench suite — not gospel.
/// The size-independent floor of `tierUpThreshold` — the back-edge
/// precheck uses it to skip the OSR call while a chunk is plainly
/// still heating.
pub const tier_up_base: u32 = 512;

/// One immediate tier-down after an OSR entry is a strike; at this
/// limit the back-edge precheck stops entering (the enter-and-bail
/// ping-pong would tax every loop iteration).
pub const osr_strike_limit: u8 = 8;

pub fn tierUpThreshold(code_len: usize) u32 {
    const len: u32 = @intCast(@min(code_len, 1 << 20));
    return tier_up_base +| (8 *| len);
}

/// The dispatcher hook: called right after a frame push, before
/// dispatch enters it. Self-gating — returns null (and the caller
/// proceeds into Lantern as if no JIT existed) unless the realm
/// has the tier enabled, the frame is a plain call, and the chunk
/// is (or just became) compiled. On `.done` the callee frame is
/// popped here and the return value handed back; on tier-down the
/// frame stays pushed mid-chunk and `reEnterDispatch` picks it up.
pub fn tryEnterTop(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
) RunError!EnterOutcome {
    if (comptime !supported) return .not_entered;
    if (!realm.jit_enabled) return .not_entered;
    const fr = &frames.items[frames.items.len - 1];
    // Plain calls only: constructor return verdicts (§10.2.2 steps
    // 7-11), generator resumes, and async Promise wrapping all stay
    // Lantern's business (docs/jit.md §4.5).
    if (fr.is_construct or fr.generator != null or fr.wrap_return_in_promise) return .not_entered;
    const js = fr.chunk.jit_state orelse return .not_entered;
    if (js.entry == null) {
        if (js.tier != .cold) return .not_entered;
        const threshold = realm.jit_threshold_override orelse
            tierUpThreshold(fr.chunk.code.len);
        if (js.warmth < threshold) return .not_entered;
        compile(realm, fr.chunk, js);
        if (js.entry == null) return .not_entered;
    }
    const entry: EntryFn = @ptrCast(@alignCast(js.entry.?));
    switch (@as(EntryResult, @enumFromInt(entry(realm, fr, fr.registers.ptr)))) {
        .done => {
            const ret = fr.accumulator;
            fr.releaseRegisters(realm, allocator);
            _ = frames.pop();
            return .{ .completed = ret };
        },
        .resume_interp => return .not_entered,
        .threw => {
            const ex = realm.pending_exception orelse Value.undefined_;
            realm.pending_exception = null;
            return .{ .threw = ex };
        },
        .host_oom => return error.OutOfMemory,
    }
}

/// Compile `chunk` synchronously (Sparkplug-class cost —
/// docs/jit.md §4.7).
/// Every failure path — unsupported opcode, allocator exhaustion,
/// emit OOM — leaves the chunk `dont_compile` and the engine
/// interpreted: degrading is the contract, aborting never is.
fn compile(realm: *Realm, chunk: *const Chunk, js: *Chunk.JitState) void {
    js.tier = .dont_compile;
    if (comptime !supported) return;
    const ca = realm.heap.jitCodeAllocator() orelse return;
    var c = Compiler.init(realm.heap.allocator, chunk);
    defer c.deinit();
    c.run() catch return;
    const code = ca.install(c.m.code.items) catch return;
    js.entry = @ptrCast(code.ptr);
    // The OSR table rides in the code region (same wholesale
    // lifetime as the code). If its install fails the chunk still
    // works — entry-time tier-up only, no mid-loop entries.
    if (c.osr_entries.items.len != 0) {
        if (ca.install(std.mem.sliceAsBytes(c.osr_entries.items))) |blob| {
            js.osr_ptr = @ptrCast(@alignCast(blob.ptr));
            js.osr_len = @intCast(c.osr_entries.items.len);
        } else |_| {}
    }
    js.tier = .compiled;
}

pub const OsrOutcome = union(enum) { not_entered, resumed, completed: Value, threw: Value };

/// docs/jit.md §12 3f — on-stack replacement at a loop back-edge.
/// The caller (a Lantern back-edge that just ran `loopSafePoint`,
/// so `frame.ip` / `frame.accumulator` are synced at the loop
/// header) hands the top frame to compiled code mid-activation.
/// Tier-up here counts back-edge warmth, so a single-call hot loop
/// compiles from inside its own run — the arith_loop shape.
pub fn tryOsrEnterTop(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
) RunError!OsrOutcome {
    if (comptime !supported) return .not_entered;
    if (!realm.jit_enabled) return .not_entered;
    const fr = &frames.items[frames.items.len - 1];
    if (fr.is_construct or fr.generator != null or fr.wrap_return_in_promise) return .not_entered;
    const js = fr.chunk.jit_state orelse return .not_entered;
    if (js.entry == null) {
        if (js.tier != .cold) return .not_entered;
        const threshold = realm.jit_threshold_override orelse
            tierUpThreshold(fr.chunk.code.len);
        if (js.warmth < threshold) return .not_entered;
        compile(realm, fr.chunk, js);
        if (js.entry == null) return .not_entered;
    }
    if (js.osr_strikes >= osr_strike_limit) return .not_entered;
    const tbl = js.osr_ptr orelse return .not_entered;
    const target: u32 = @intCast(fr.ip);
    const code_off: u32 = blk: {
        for (tbl[0..js.osr_len]) |e| {
            if (e.bc == target) break :blk e.code_off;
        }
        return .not_entered;
    };
    const base: [*]const u8 = @ptrCast(js.entry.?);
    const stub: EntryFn = @ptrCast(@alignCast(base + code_off));
    switch (@as(EntryResult, @enumFromInt(stub(realm, fr, fr.registers.ptr)))) {
        .done => {
            const ret = fr.accumulator;
            fr.releaseRegisters(realm, allocator);
            _ = frames.pop();
            return .{ .completed = ret };
        },
        .resume_interp => return .resumed,
        .threw => {
            const ex = realm.pending_exception orelse Value.undefined_;
            realm.pending_exception = null;
            return .{ .threw = ex };
        },
        .host_oom => return error.OutOfMemory,
    }
}

const CompileError = error{ OutOfMemory, UnsupportedOp };

// Pinned registers inside compiled code (docs/jit.md §4.2). x19-x24
// are callee-saved per AAPCS64 and restored in the epilogue;
// x9-x13 are scratch.
const realm_reg: a64.Reg = .x19;
const frame_reg: a64.Reg = .x20;
const regs_reg: a64.Reg = .x21;
const acc_reg: a64.Reg = .x22;
/// Pinned `Value.fromInt32(0).bits` — the int32 tag in the high
/// half-word. `eor` against it + `lsr #48` is the tag test.
const int32_tag_reg: a64.Reg = .x23;
/// Pinned `Value.false_.bits` — the bool tag for compare results
/// and `jmp_if_*` truthiness.
const bool_tag_reg: a64.Reg = .x24;

// Struct offsets come from the layout contract (docs/jit.md §12
// step 3a) — never derived locally.
const acc_off: u15 = layout.frame.accumulator;
const ip_off: u15 = layout.frame.ip;
const step_budget_off: usize = layout.realm.step_budget;
const interrupt_off: usize = layout.realm.interrupt_raw;

const int32_tag_bits: u64 = @as(u64, Value.tag_int32) << 48;
const bool_tag_bits: u64 = Value.false_.bits;

/// The §9 barrier rule: the compiled `sta_property` hit emits
/// exactly what the interpreter's hit path does — the slot store
/// inline, then this call, which is `Heap.storeInternalSlot`
/// behind a C ABI. Infallible (the interpreter calls it without
/// `try`) and never ticks the GC counters, so it is safe to call
/// while the accumulator lives unsynced in its pinned register.
/// docs/ctor-array-build-gap.md L2 — the fused dense-literal builder,
/// shared with the interpreter via `Heap.makeDenseArray` so the
/// compiled path produces a byte-identical object. `regs` is the
/// (GC-rooted) register file; the n source values live at
/// `regs[r_base .. r_base + n]`. Writes the new array into `out` (the
/// frame's accumulator slot, so it is rooted the instant it exists);
/// returns 0 on success, 1 on host OOM.
/// docs/ctor-array-build-gap.md L1 — the int32-keyed dense read,
/// shared with the interpreter via `Heap.denseElementFastGet`. Pure
/// (no allocation), so the compiled site needs no rooting. Returns 1
/// and writes the element to `out` on a hit; 0 on any miss (the
/// caller tiers down to re-run the full `lda_computed`).
fn denseGetShim(recv_bits: u64, key_bits: u64, out: *Value) callconv(.c) u32 {
    if (heap_mod.Heap.denseElementFastGet(.{ .bits = recv_bits }, .{ .bits = key_bits })) |v| {
        out.* = v;
        return 1;
    }
    return 0;
}

fn makeArrayShim(r: *Realm, regs: [*]const Value, r_base: u64, n: u64, out: *Value) callconv(.c) u32 {
    const lo: usize = @intCast(r_base);
    const obj = r.heap.makeDenseArray(r.intrinsics.array_prototype, regs[lo .. lo + @as(usize, @intCast(n))]) catch return 1;
    out.* = heap_mod.taggedObject(obj);
    return 0;
}

fn storeBarrier(r: *Realm, obj: *JSObject, bits: u64) callconv(.c) void {
    r.heap.storeInternalSlot(.{ .object = obj }, .{ .bits = bits });
}

const call_mod = @import("../lantern/call.zig");
const Environment = @import("../environment.zig").Environment;
const JSFunction = @import("../function.zig").JSFunction;

/// The §9 rule for env-resident bindings: compiled sta_env runs
/// exactly the interpreter's `storeEnvSlot` — barrier plus store —
/// through this shim. No allocation, no GC, no JS re-entry.
fn envStoreBarrier(r: *Realm, env: *Environment, slot: u64, bits: u64) callconv(.c) void {
    r.heap.storeEnvSlot(env, @intCast(slot), .{ .bits = bits });
}

/// What `helperCall` reports back to the emitted call sequence.
const HelperCallStatus = enum(u32) { value = 0, threw = 1, host_oom = 2 };

/// The docs/jit.md §4.5 helper-mediated call: compiled code syncs
/// its accumulator (the callee may allocate and GC; the frame is
/// the root — §4.2), marshals the args window straight off the
/// register file, and re-enters the engine through the same generic
/// dispatcher every native uses. `callValue` handles every callee
/// kind — plain functions (including compiled ones, recursively,
/// via the `callJSFunction` hook), natives, bound functions,
/// proxies — and the nested `runFrames` carries the native-re-entry
/// stack guard, so deep compiled recursion throws the catchable
/// RangeError instead of faulting the host.
/// The CallICCell-hit fast path (docs/jit.md §12 3e follow-up):
/// the cell only ever holds a vetted, directly-callable plain
/// JSFunction, so a pointer match skips callValue's whole §7.3
/// dispatch chain (proxy probe, bound unwrap, class-ctor check)
/// and enters callJSFunction — which still runs the compiled
/// callee through its own hook, recursively.
fn helperCallDirect(
    realm: *Realm,
    frame: *CallFrame,
    callee_fn: *JSFunction,
    this_bits: u64,
    args_ptr: [*]const Value,
    argc: u64,
    result_out: *Value,
) callconv(.c) u32 {
    _ = frame;
    const res = call_mod.callJSFunction(
        realm.heap.allocator,
        realm,
        callee_fn,
        .{ .bits = this_bits },
        args_ptr[0..@intCast(argc)],
    ) catch |err| switch (err) {
        error.OutOfMemory => return @intFromEnum(HelperCallStatus.host_oom),
        error.InvalidOpcode => return @intFromEnum(HelperCallStatus.host_oom),
    };
    switch (res) {
        .value, .yielded => |v| {
            result_out.* = v;
            return @intFromEnum(HelperCallStatus.value);
        },
        .thrown => |ex| {
            realm.pending_exception = ex;
            return @intFromEnum(HelperCallStatus.threw);
        },
    }
}

fn helperCall(
    realm: *Realm,
    frame: *CallFrame,
    callee_bits: u64,
    this_bits: u64,
    args_ptr: [*]const Value,
    argc: u64,
    result_out: *Value,
) callconv(.c) u32 {
    // §9.4 — attribute cross-realm-observable throws to the
    // executing function's realm (ShadowRealm children).
    const running = frame.running_realm orelse realm;
    const res = call_mod.callValue(
        realm.heap.allocator,
        realm,
        running,
        .{ .bits = callee_bits },
        // Plain `call` passes undefined (§10.2.1.2 strict); the
        // method forms pass the receiver (§13.3.6).
        .{ .bits = this_bits },
        args_ptr[0..@intCast(argc)],
    ) catch |err| switch (err) {
        error.OutOfMemory => return @intFromEnum(HelperCallStatus.host_oom),
        // Corrupted-chunk class — should never happen; surface as
        // the host-abort path rather than a JS value.
        error.InvalidOpcode => return @intFromEnum(HelperCallStatus.host_oom),
    };
    switch (res) {
        .value, .yielded => |v| {
            result_out.* = v;
            return @intFromEnum(HelperCallStatus.value);
        },
        .thrown => |ex| {
            realm.pending_exception = ex;
            return @intFromEnum(HelperCallStatus.threw);
        },
    }
}

const Compiler = struct {
    m: Masm,
    chunk: *const Chunk,
    /// One label per bytecode offset that is a branch target.
    target_labels: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    labels: std.ArrayListUnmanaged(Masm.Label) = .empty,
    /// Tier-down stubs, deduplicated by resume offset; emitted
    /// out-of-line after the body so the fast path stays straight.
    td_by_off: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    tds: std.ArrayListUnmanaged(Td) = .empty,
    /// Per-call-site throw stubs (EntryResult.threw with `ip` at
    /// the faulting call op — docs/jit.md §4.5), same out-of-line
    /// shape as the tier-down stubs.
    threws: std.ArrayListUnmanaged(Td) = .empty,
    /// Loop headers (backward-branch targets) — each gets an OSR
    /// entry stub; insertion-ordered for a deterministic table.
    osr_headers: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    osr_entries: std.ArrayListUnmanaged(Chunk.JitState.OsrEntry) = .empty,
    body_start: Masm.Label = .{},
    done_label: Masm.Label = .{},
    tier_down_label: Masm.Label = .{},
    threw_label: Masm.Label = .{},
    oom_label: Masm.Label = .{},

    const Td = struct { label: Masm.Label, resume_off: u32 };

    fn init(gpa: std.mem.Allocator, chunk: *const Chunk) Compiler {
        return .{ .m = Masm.init(gpa), .chunk = chunk };
    }

    fn deinit(self: *Compiler) void {
        const gpa = self.m.gpa;
        self.target_labels.deinit(gpa);
        self.td_by_off.deinit(gpa);
        for (self.labels.items) |*l| l.fixups.deinit(gpa);
        self.labels.deinit(gpa);
        for (self.tds.items) |*t| t.label.fixups.deinit(gpa);
        self.tds.deinit(gpa);
        for (self.threws.items) |*t| t.label.fixups.deinit(gpa);
        self.threws.deinit(gpa);
        self.osr_headers.deinit(gpa);
        self.osr_entries.deinit(gpa);
        self.body_start.fixups.deinit(gpa);
        self.done_label.fixups.deinit(gpa);
        self.tier_down_label.fixups.deinit(gpa);
        self.threw_label.fixups.deinit(gpa);
        self.oom_label.fixups.deinit(gpa);
        self.m.deinit();
    }

    /// Branch-target label for a bytecode offset (created by the
    /// pre-pass; pass 2 binds it when emission reaches the offset).
    fn labelFor(self: *Compiler, bc_off: u32) !*Masm.Label {
        const gop = try self.target_labels.getOrPut(self.m.gpa, bc_off);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.labels.items.len);
            try self.labels.append(self.m.gpa, .{});
        }
        return &self.labels.items[gop.value_ptr.*];
    }

    /// Tier-down stub label for a resume offset (shared across
    /// every check that resumes at the same opcode).
    fn tdFor(self: *Compiler, resume_off: u32) !*Masm.Label {
        const gop = try self.td_by_off.getOrPut(self.m.gpa, resume_off);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.tds.items.len);
            try self.tds.append(self.m.gpa, .{ .label = .{}, .resume_off = resume_off });
        }
        return &self.tds.items[gop.value_ptr.*].label;
    }

    /// Throw stub label for a call site. The returned pointer is
    /// only valid until the next `threws` append — use it within
    /// the same opcode's emit, like `tdFor`.
    fn threwFor(self: *Compiler, call_off: u32) !*Masm.Label {
        try self.threws.append(self.m.gpa, .{ .label = .{}, .resume_off = call_off });
        return &self.threws.items[self.threws.items.len - 1].label;
    }

    fn run(self: *Compiler) CompileError!void {
        try self.scanTargets();
        try self.prologue();
        try self.body();
        try self.tail();
    }

    /// Pass 1 — reject unsupported opcodes before any emission and
    /// collect branch targets so pass 2 can bind labels in order.
    fn scanTargets(self: *Compiler) CompileError!void {
        const code = self.chunk.code;
        var i: usize = 0;
        // A `make_environment 0` is emitted into the same chunk as the
        // env reads it scopes — the elision below is only sound when
        // there are none. Track both and reject the combination after
        // the scan (the `make_environment` can lexically precede or
        // follow the `lda_env`/`sta_env`).
        var has_make_env = false;
        var has_env_access = false;
        while (i < code.len) {
            const op: Op = @enumFromInt(code[i]);
            const after = i + 1 + Op.operandSize(op);
            switch (op) {
                // zig fmt: off
                .lda_undefined, .lda_null, .lda_true, .lda_false,
                .lda_hole, .lda_smi, .lda_constant, .ldar, .star,
                .mov, .add, .sub, .mul, .add_smi, .to_int32,
                .bit_and, .bit_or, .bit_xor,
                .lt, .gt, .le, .ge, .eq, .neq, .strict_eq, .strict_neq,
                .lda_property, .lda_property_reg, .sta_property,
                .lda_global, .lda_global_or_undef,
                .lda_this, .call, .call0, .call1, .call2, .call3,
                .call_method, .call_property,
                .tail_call, .tail_call_method,
                .lda_global_slot, .sta_global_slot, .sta_global_slot_init,
                .negate, .bit_not, .logical_not,
                .make_array_n, .lda_computed,
                .throw_if_hole, .return_ => {},
                .lda_env, .sta_env => {
                    // Fixed-depth walks unroll; cap the unroll.
                    if (code[i + 1] > 8) return error.UnsupportedOp;
                    has_env_access = true;
                },
                // zig fmt: on
                .make_environment => {
                    // Compiled code elides a zero-slot env allocation
                    // (no own bindings to store). Any real slot count
                    // means env-resident bindings: dont_compile. The
                    // elision is only sound when the chunk has NO
                    // `lda_env`/`sta_env` — those opcodes' depth
                    // operands are computed relative to the pushed
                    // env, so dropping it shifts every env read/write
                    // one scope too shallow (the await-using getter
                    // regression: a `make_environment 0` for an empty
                    // block scope sat in the same chunk as `lda_env ^1`
                    // reads of an outer closure var). The cross-check
                    // is done after the scan.
                    if (code[i + 1] != 0) return error.UnsupportedOp;
                    has_make_env = true;
                },
                .jmp, .jmp_if_true, .jmp_if_false => {
                    const off = readI16(code, i + 1);
                    _ = try self.labelFor(targetOf(after, off));
                    // A backward branch's target is a loop header —
                    // an OSR entry point (docs/jit.md §12 3f).
                    if (off < 0) try self.osr_headers.put(self.m.gpa, targetOf(after, off), {});
                },
                .loop_inc_lt => {
                    const off = readI16(code, i + 3);
                    _ = try self.labelFor(targetOf(after, off));
                    if (off < 0) try self.osr_headers.put(self.m.gpa, targetOf(after, off), {});
                },
                else => return error.UnsupportedOp,
            }
            i = after;
        }
        // The elided `make_environment 0` would leave `frame.env` one
        // scope shallower than the bytecode's `lda_env`/`sta_env`
        // depths assume — dont_compile rather than read the wrong slot.
        if (has_make_env and has_env_access) return error.UnsupportedOp;
    }

    fn prologue(self: *Compiler) CompileError!void {
        const m = &self.m;
        try m.emit(a64.stpPreIdxSp(.fp, .lr, -16));
        try m.emit(a64.stpPreIdxSp(.x19, .x20, -16));
        try m.emit(a64.stpPreIdxSp(.x21, .x22, -16));
        try m.emit(a64.stpPreIdxSp(.x23, .x24, -16));
        try m.emit(a64.movReg(realm_reg, .x0));
        try m.emit(a64.movReg(frame_reg, .x1));
        try m.emit(a64.movReg(regs_reg, .x2));
        try m.emit(a64.ldrImm(acc_reg, frame_reg, acc_off));
        try m.movImm64(int32_tag_reg, int32_tag_bits);
        try m.movImm64(bool_tag_reg, bool_tag_bits);
    }

    fn body(self: *Compiler) CompileError!void {
        const m = &self.m;
        m.bind(&self.body_start);
        const code = self.chunk.code;
        var i: usize = 0;
        while (i < code.len) {
            const bc: u32 = @intCast(i);
            if (self.target_labels.get(bc)) |idx| m.bind(&self.labels.items[idx]);
            const op: Op = @enumFromInt(code[i]);
            const after = i + 1 + Op.operandSize(op);
            switch (op) {
                .lda_undefined => try m.movImm64(acc_reg, Value.undefined_.bits),
                .lda_null => try m.movImm64(acc_reg, Value.null_.bits),
                .lda_true => try m.movImm64(acc_reg, Value.true_.bits),
                .lda_false => try m.movImm64(acc_reg, Value.false_.bits),
                .lda_hole => try m.movImm64(acc_reg, Value.hole_.bits),
                .lda_smi => {
                    const imm = readI32(code, i + 1);
                    try m.movImm64(acc_reg, Value.fromInt32(imm).bits);
                },
                .lda_constant => {
                    // Constants are chunk-owned, GC-rooted via
                    // markChunk, and the heap never moves — the
                    // Value bits are bakeable (docs/jit.md §9).
                    const k = readU16(code, i + 1);
                    try m.movImm64(acc_reg, self.chunk.constants[k].bits);
                },
                .ldar => try m.emit(a64.ldrImm(acc_reg, regs_reg, regSlot(code[i + 1]))),
                .star => try m.emit(a64.strImm(acc_reg, regs_reg, regSlot(code[i + 1]))),
                .mov => {
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try m.emit(a64.strImm(.x9, regs_reg, regSlot(code[i + 2])));
                },

                .add, .sub => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(if (op == .add)
                        a64.addsRegW(.x11, .x9, acc_reg)
                    else
                        a64.subsRegW(.x11, .x9, acc_reg));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .mul => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    // 64-bit product of the 32-bit payloads; the
                    // result is i32-representable iff it sign-
                    // extends to itself.
                    try m.emit(a64.smull(.x11, .x9, acc_reg));
                    try m.emit(a64.sxtw(.x12, .x11));
                    try m.emit(a64.cmpReg(.x12, .x11));
                    try m.jumpCond(.ne, td);
                    try m.emit(a64.movRegW(.x11, .x11));
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .add_smi => {
                    const td = try self.tdFor(bc);
                    const imm = readI32(code, i + 2);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try m.movImm64(.x10, @as(u32, @bitCast(imm)));
                    try m.emit(a64.addsRegW(.x11, .x9, .x10));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .to_int32 => {
                    // §7.1.6 fast path: an int32 is its own ToInt32.
                    const td = try self.tdFor(bc);
                    try self.checkInt32(acc_reg, td);
                },
                .bit_and, .bit_or, .bit_xor => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(switch (op) {
                        .bit_and => a64.andRegW(.x11, .x9, acc_reg),
                        .bit_or => a64.orrRegW(.x11, .x9, acc_reg),
                        else => a64.eorRegW(.x11, .x9, acc_reg),
                    });
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },

                .lt, .gt, .le, .ge, .eq, .neq, .strict_eq, .strict_neq => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    // acc = reg CMP acc, on the int32 payloads.
                    try m.emit(a64.cmpRegW(.x9, acc_reg));
                    try m.emit(a64.csetW(.x11, switch (op) {
                        .lt => a64.Cond.lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                        .eq, .strict_eq => .eq,
                        else => .ne,
                    }));
                    try m.emit(a64.orrReg(acc_reg, .x11, bool_tag_reg));
                },

                .make_environment => {
                    // Zero-slot env (scan-enforced) — unobservable
                    // from this chunk; elided.
                },
                .call, .call0, .call1, .call2, .call3 => {
                    // docs/jit.md §4.5 — helper-mediated: the helper
                    // runs the whole §7.3 call dance (every exotic
                    // callee kind included) through callValue, so
                    // this site only marshals the args window from
                    // the register file. The CallICCell inline
                    // compare is the recorded follow-up
                    // optimization.
                    const r_callee = code[i + 1];
                    // `call0..3` fold argc into the opcode (ic at i+2);
                    // generic `call` reads argc:u8 then ic at i+3.
                    const op_byte = code[i];
                    const is_generic = op_byte == @intFromEnum(Op.call);
                    const argc: u8 = if (is_generic) code[i + 2] else op_byte - @intFromEnum(Op.call0);
                    const ic_call = if (is_generic) readU16(code, i + 3) else readU16(code, i + 2);
                    const threw = try self.threwFor(bc);
                    // Root the live accumulator through the frame —
                    // the callee may allocate and GC (§4.2).
                    try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_callee)));
                    try self.emitCallDispatch(.x9, null, r_callee + 1, argc, ic_call, threw);
                },
                .call_method => {
                    // §13.3.6 — like `call` with `this` bound to the
                    // receiver register. The callee was loaded by
                    // preceding ops (the GET-before-arguments
                    // evaluation order), so this site only marshals.
                    const r_recv = code[i + 1];
                    const r_callee = code[i + 2];
                    const argc = code[i + 3];
                    const ic_call = readU16(code, i + 4);
                    const threw = try self.threwFor(bc);
                    try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_callee)));
                    try self.emitCallDispatch(.x9, r_recv, r_callee + 1, argc, ic_call, threw);
                },
                .call_property => {
                    // The fused load+call (`obj.method(args)`): the
                    // §4.4 property-IC read into a scratch the call
                    // marshal then consumes, `this` = the receiver.
                    // Any load miss tiers down at the op — Lantern
                    // re-runs the whole fused sequence.
                    const r_recv = code[i + 3];
                    const argc = code[i + 4];
                    const ic_load = readU16(code, i + 5);
                    const ic_call = readU16(code, i + 7);
                    const td = try self.tdFor(bc);
                    const threw = try self.threwFor(bc);
                    // Sync the PRE-op accumulator before any
                    // clobber: a later tier-down stub re-stores
                    // acc_reg, so acc_reg must stay the pre-op value
                    // until the call commits (x14 carries the
                    // callee instead).
                    try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
                    try m.emit(a64.ldrImm(.x14, regs_reg, regSlot(r_recv)));
                    try self.emitPropertyIcLoad(.x14, .x14, ic_load, td);
                    try self.emitCallDispatch(.x14, r_recv, r_recv + 1, argc, ic_call, threw);
                },
                .tail_call => {
                    // §15.10 jump-to-entry for the self-recursive
                    // case: a plain (non-arrow) callee over THIS
                    // chunk rebuilds the frame in place — the
                    // callee's capture set replaces ours, the args
                    // window shifts down, and control branches to
                    // the body. Constant native stack by
                    // construction. Any other callee tiers down to
                    // Lantern's general PTC reframe; the pre-check
                    // safepoint mirrors the interpreter's
                    // runSafePoint poll at the reframe.
                    const r_callee = code[i + 1];
                    const argc = code[i + 2];
                    const td = try self.tdFor(bc);
                    if (argc > 8) {
                        try m.jump(td);
                    } else {
                        // Budget / interrupt poll FIRST — it shares
                        // the x9-x13 scratch set, so it must run
                        // before the callee pointer is computed. A
                        // trip re-runs this tail_call in Lantern.
                        try self.backEdgeSafePoint(bc);
                        try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_callee)));
                        // Function-kind heap pointer (kind bits 0).
                        try m.movImm64(.x13, layout.value_bits.tag_object_shifted);
                        try m.emit(a64.eorReg(.x13, .x9, .x13));
                        try m.emit(a64.lsrImm(.x12, .x13, 48));
                        try m.jumpCbnz(.x12, td);
                        try m.emit(a64.lslImm(.x12, .x13, 62));
                        try m.emit(a64.lsrImm(.x12, .x12, 62));
                        try m.jumpCbnz(.x12, td);
                        try m.emit(a64.lsrImm(.x10, .x13, 2));
                        try m.emit(a64.lslImm(.x10, .x10, 2));
                        // Same chunk, not an arrow.
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.chunk));
                        try m.movImm64(.x12, @intFromPtr(self.chunk));
                        try m.emit(a64.cmpReg(.x11, .x12));
                        try m.jumpCond(.ne, td);
                        try m.emit(a64.ldrbImm(.x11, .x10, layout.function.is_arrow));
                        try m.jumpCbnz(.x11, td);
                        // Args window down to r0..argc-1 (dest is
                        // always below source — forward copy safe).
                        var k: u8 = 0;
                        while (k < argc) : (k += 1) {
                            try m.emit(a64.ldrImm(.x11, regs_reg, regSlot(r_callee + 1 + k)));
                            try m.emit(a64.strImm(.x11, regs_reg, regSlot(k)));
                        }
                        // Frame rebuild from the callee's capture
                        // set — the interpreter's reframe store set,
                        // minus the fields a plain compiled frame
                        // already holds (is_construct, generator,
                        // wrap flags) and argc (only the arguments
                        // machinery reads it, which register-safe
                        // bodies cannot contain).
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.captured_env));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.env));
                        try m.movImm64(.x12, Value.undefined_.bits);
                        try m.emit(a64.strImm(.x12, frame_reg, layout.frame.this_value));
                        try m.emit(a64.strImm(.x12, frame_reg, layout.frame.new_target));
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.home_object));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.home_object));
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.home_function));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.home_function));
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.super_called_cell));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.super_called_cell));
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.owning_module));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.owning_module));
                        try m.emit(a64.ldrImm(.x11, .x10, layout.function.realm));
                        try m.emit(a64.strImm(.x11, frame_reg, layout.frame.running_realm));
                        // A fresh activation's accumulator.
                        try m.movImm64(acc_reg, Value.undefined_.bits);
                        try m.jump(&self.body_start);
                    }
                },
                .tail_call_method => {
                    // §15.10 — the method form keeps the
                    // unconditional tier-down (rare, and `this`
                    // re-binding adds a receiver path the plain
                    // form doesn't need).
                    try m.jump(try self.tdFor(bc));
                },
                .negate => {
                    // §13.5.5 — int32 negate; 0 (the result is -0,
                    // a double) and INT32_MIN (out of range) tier
                    // down.
                    const td = try self.tdFor(bc);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(a64.movRegW(.x11, acc_reg));
                    try m.jumpCbz(.x11, td);
                    try m.emit(a64.movz(.x13, 0, 0));
                    try m.emit(a64.subsRegW(.x11, .x13, .x11));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .bit_not => {
                    // §13.5.6 — ~int32 stays int32 always.
                    const td = try self.tdFor(bc);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(a64.movn(.x13, 0, 0));
                    try m.emit(a64.eorRegW(.x11, acc_reg, .x13));
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .logical_not => {
                    // §13.5.7 on an already-Boolean acc — payload
                    // bit 0 flips and the tag bits are untouched, so
                    // no retag. Non-bool acc tiers down to ToBoolean.
                    const td = try self.tdFor(bc);
                    try m.emit(a64.eorReg(.x13, acc_reg, bool_tag_reg));
                    try m.emit(a64.cmpImm(.x13, 1, false));
                    try m.jumpCond(.hi, td);
                    try m.emit(a64.movz(.x13, 1, 0));
                    try m.emit(a64.eorReg(acc_reg, acc_reg, .x13));
                },
                .lda_env => {
                    // Fixed-depth chain walk (the compiler
                    // guarantees the chain is long enough; a broken
                    // chain or short slot array tiers down and
                    // Lantern surfaces its own error).
                    const depth = code[i + 1];
                    const slot = code[i + 2];
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.env));
                    try m.jumpCbz(.x9, td);
                    var d = depth;
                    while (d > 0) : (d -= 1) {
                        try m.emit(a64.ldrImm(.x9, .x9, layout.env.parent));
                        try m.jumpCbz(.x9, td);
                    }
                    try m.emit(a64.ldrImm(.x11, .x9, layout.env.slots + 8));
                    try m.emit(a64.cmpImm(.x11, slot, false));
                    try m.jumpCond(.ls, td);
                    try m.emit(a64.ldrImm(.x10, .x9, layout.env.slots));
                    try m.emit(a64.ldrImm(acc_reg, .x10, @as(u15, slot) * 8));
                },
                .sta_env => {
                    // Same walk; the store runs the interpreter's
                    // storeEnvSlot (barrier + store) through the C
                    // shim — the §9 rule verbatim.
                    const depth = code[i + 1];
                    const slot = code[i + 2];
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.env));
                    try m.jumpCbz(.x9, td);
                    var d = depth;
                    while (d > 0) : (d -= 1) {
                        try m.emit(a64.ldrImm(.x9, .x9, layout.env.parent));
                        try m.jumpCbz(.x9, td);
                    }
                    try m.emit(a64.ldrImm(.x11, .x9, layout.env.slots + 8));
                    try m.emit(a64.cmpImm(.x11, slot, false));
                    try m.jumpCond(.ls, td);
                    try m.emit(a64.movReg(.x0, realm_reg));
                    try m.emit(a64.movReg(.x1, .x9));
                    try m.movImm64(.x2, slot);
                    try m.emit(a64.movReg(.x3, acc_reg));
                    try m.callAbs(.x16, @intFromPtr(&envStoreBarrier));
                },
                .lda_global_slot => {
                    // §9.1.1.4 declarative-record slot read through
                    // the executing frame's realm; the absolute
                    // index (chunk base + slot) is compile-time.
                    // TDZ is the compiler-emitted throw_if_hole
                    // that follows.
                    const abs_idx: usize = @as(usize, self.chunk.global_lexical_base) + readU32(code, i + 1);
                    var have_gr = Masm.Label{};
                    defer have_gr.fixups.deinit(m.gpa);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.running_realm));
                    try m.jumpCbnz(.x9, &have_gr);
                    try m.emit(a64.movReg(.x9, realm_reg));
                    m.bind(&have_gr);
                    try self.loadFieldU64(.x10, .x9, layout.realm.globals_decl_slots_ptr);
                    try self.loadFieldU64(acc_reg, .x10, abs_idx * 8);
                },
                .sta_global_slot_init => {
                    // §9.1.1.4 InitializeBinding — fills the TDZ
                    // hole; no checks by construction.
                    const abs_idx: usize = @as(usize, self.chunk.global_lexical_base) + readU32(code, i + 1);
                    var have_gr = Masm.Label{};
                    defer have_gr.fixups.deinit(m.gpa);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.running_realm));
                    try m.jumpCbnz(.x9, &have_gr);
                    try m.emit(a64.movReg(.x9, realm_reg));
                    m.bind(&have_gr);
                    try self.loadFieldU64(.x10, .x9, layout.realm.globals_decl_slots_ptr);
                    try self.storeFieldU64(acc_reg, .x10, abs_idx * 8);
                },
                .sta_global_slot => {
                    // §9.1.1.4 SetMutableBinding: hole (§13.3.1
                    // TDZ) and const (§13.15.2) both tier down —
                    // Lantern re-runs the op and raises the right
                    // error; the hit path is a plain slot store
                    // (the record is a GC root, no barrier).
                    const abs_idx: usize = @as(usize, self.chunk.global_lexical_base) + readU32(code, i + 1);
                    if (abs_idx > 4095) return error.UnsupportedOp; // ldrb imm12 ceiling
                    const td = try self.tdFor(bc);
                    var have_gr = Masm.Label{};
                    defer have_gr.fixups.deinit(m.gpa);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.running_realm));
                    try m.jumpCbnz(.x9, &have_gr);
                    try m.emit(a64.movReg(.x9, realm_reg));
                    m.bind(&have_gr);
                    try self.loadFieldU64(.x10, .x9, layout.realm.globals_decl_slots_ptr);
                    try self.loadFieldU64(.x11, .x10, abs_idx * 8);
                    try m.movImm64(.x12, Value.hole_.bits);
                    try m.emit(a64.cmpReg(.x11, .x12));
                    try m.jumpCond(.eq, td);
                    try self.loadFieldU64(.x12, .x9, layout.realm.globals_decl_const_flags_ptr);
                    try m.emit(a64.ldrbImm(.x13, .x12, @intCast(abs_idx)));
                    try m.jumpCbnz(.x13, td);
                    try self.storeFieldU64(acc_reg, .x10, abs_idx * 8);
                },
                .lda_this => {
                    // §9.1.1.3.4 GetThisBinding — the only abrupt
                    // case is the derived-constructor TDZ, and
                    // construct frames never enter compiled code
                    // (tryEnterTop refuses them). What CAN enter is
                    // an arrow whose lexical `this` belongs to a
                    // derived ctor — those frames carry
                    // `super_called_cell`, so tier down on its
                    // presence and read the (always-initialised)
                    // `this_value` otherwise.
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.super_called_cell));
                    try m.jumpCbnz(.x9, td);
                    try m.emit(a64.ldrImm(acc_reg, frame_reg, layout.frame.this_value));
                },
                .lda_property => {
                    const td = try self.tdFor(bc);
                    const ic_idx = readU16(code, i + 3);
                    try self.emitPropertyIcLoad(acc_reg, acc_reg, ic_idx, td);
                },
                .lda_property_reg => {
                    // Register-receiver form: load the receiver from
                    // its frame slot (a GC-rooted register — only read
                    // here, never stored to, so it survives for a
                    // following call's `this`), then run the same IC
                    // load into the accumulator. `x9` mirrors the
                    // `sta_property` pattern: `emitPropertyIcLoad`'s
                    // first act is `emitPlainObject(src, .x9, …)`,
                    // which reads `src` before writing `.x9`, so
                    // sourcing from `.x9` is safe.
                    const td = try self.tdFor(bc);
                    const r_obj = code[i + 3];
                    const ic_idx = readU16(code, i + 4);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_obj)));
                    try self.emitPropertyIcLoad(.x9, acc_reg, ic_idx, td);
                },
                .sta_property => {
                    // Same-shape hit only; the transition mode
                    // resizes slots and tiers down. The §9 rule:
                    // emit exactly what the interpreter's hit path
                    // does — the slot store, then the same
                    // storeInternalSlot barrier through a C shim.
                    const td = try self.tdFor(bc);
                    const r_obj = code[i + 3];
                    const ic_idx = readU16(code, i + 4);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_obj)));
                    try self.emitPlainObject(.x9, .x9, td);
                    try self.emitCellAddr(.x10, ic_idx);
                    try m.emit(a64.ldrImm(.x11, .x10, layout.ic_cell.shape));
                    try m.jumpCbz(.x11, td);
                    try m.emit(a64.ldrImm(.x12, .x9, layout.object.shape));
                    try m.emit(a64.cmpReg(.x11, .x12));
                    try m.jumpCond(.ne, td);
                    try m.emit(a64.ldrImmW(.x11, .x10, layout.ic_cell.slot));
                    try self.emitSlotWrite(acc_reg, .x9, .x11);
                    try m.emit(a64.movReg(.x0, realm_reg));
                    try m.emit(a64.movReg(.x1, .x9));
                    try m.emit(a64.movReg(.x2, acc_reg));
                    try m.callAbs(.x16, @intFromPtr(&storeBarrier));
                },
                .lda_global, .lda_global_or_undef => {
                    // The interpreter's predicate verbatim: resolve
                    // the global env through the executing frame's
                    // realm (§8.3 — ShadowRealm children differ from
                    // the dispatch realm), then shape + decl_revision
                    // + proto==null on the cell. The two opcodes
                    // differ only on the miss path, which tiers down
                    // either way.
                    const td = try self.tdFor(bc);
                    const ic_idx = readU16(code, i + 3);
                    var have_gr = Masm.Label{};
                    defer have_gr.fixups.deinit(m.gpa);
                    try m.emit(a64.ldrImm(.x9, frame_reg, layout.frame.running_realm));
                    try m.jumpCbnz(.x9, &have_gr);
                    try m.emit(a64.movReg(.x9, realm_reg));
                    m.bind(&have_gr);
                    try self.emitCellAddr(.x10, ic_idx);
                    try self.loadFieldU64(.x12, .x9, layout.realm.globals_target);
                    try m.jumpCbz(.x12, td);
                    try m.emit(a64.ldrImm(.x11, .x10, layout.ic_cell.shape));
                    try m.jumpCbz(.x11, td);
                    try m.emit(a64.ldrImm(.x13, .x12, layout.object.shape));
                    try m.emit(a64.cmpReg(.x11, .x13));
                    try m.jumpCond(.ne, td);
                    try m.emit(a64.ldrImm(.x11, .x10, layout.ic_cell.proto));
                    try m.jumpCbnz(.x11, td);
                    try self.loadFieldU64(.x13, .x9, layout.realm.globals_decl_revision);
                    try m.emit(a64.ldrImm(.x9, .x10, layout.ic_cell.proto_rev));
                    try m.emit(a64.cmpReg(.x13, .x9));
                    try m.jumpCond(.ne, td);
                    try m.emit(a64.ldrImmW(.x11, .x10, layout.ic_cell.slot));
                    try self.emitSlotRead(acc_reg, .x12, .x11);
                },

                .jmp => {
                    const off = readI16(code, i + 1);
                    const target = targetOf(after, off);
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                },
                .jmp_if_true, .jmp_if_false => {
                    const td = try self.tdFor(bc);
                    const off = readI16(code, i + 1);
                    const target = targetOf(after, off);
                    // Bool-tagged accumulators only; anything else
                    // (numbers, strings, objects in a condition)
                    // tiers down to ToBoolean in Lantern.
                    try m.emit(a64.eorReg(.x11, acc_reg, bool_tag_reg));
                    try m.emit(a64.lsrImm(.x11, .x11, 48));
                    try m.jumpCbnz(.x11, td);
                    var skip = Masm.Label{};
                    defer skip.fixups.deinit(m.gpa);
                    // Invert: hop over the (possibly safepointed)
                    // taken path when the condition doesn't hold.
                    if (op == .jmp_if_true) {
                        try m.jumpTbz(acc_reg, 0, &skip);
                    } else {
                        try m.jumpTbnz(acc_reg, 0, &skip);
                    }
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                    m.bind(&skip);
                },
                .loop_inc_lt => {
                    const td = try self.tdFor(bc);
                    const r_counter = code[i + 1];
                    const r_bound = code[i + 2];
                    const off = readI16(code, i + 3);
                    const target = targetOf(after, off);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_counter)));
                    try m.emit(a64.ldrImm(.x10, regs_reg, regSlot(r_bound)));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(.x10, td);
                    try m.emit(a64.addsImmW(.x11, .x9, 1));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(.x12, .x11, int32_tag_reg));
                    try m.emit(a64.strImm(.x12, regs_reg, regSlot(r_counter)));
                    try m.emit(a64.cmpRegW(.x11, .x10));
                    var skip = Masm.Label{};
                    defer skip.fixups.deinit(m.gpa);
                    try m.jumpCond(.ge, &skip);
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                    m.bind(&skip);
                },

                .throw_if_hole => {
                    // §13.3.1 — a Hole in the accumulator is a TDZ
                    // read; tier down and let Lantern raise the
                    // ReferenceError with its proper message.
                    const td = try self.tdFor(bc);
                    try m.movImm64(.x9, Value.hole_.bits);
                    try m.emit(a64.cmpReg(acc_reg, .x9));
                    try m.jumpCond(.eq, td);
                },

                .lda_computed => {
                    // docs/ctor-array-build-gap.md L1 — the int32-keyed
                    // dense read. recv is in r_obj, the key is in acc.
                    // The shared check is pure (no alloc), so no
                    // rooting: a hit writes the element to the frame
                    // accumulator slot and we reload acc; any miss
                    // (non-int / negative key, non-dense receiver, OOB,
                    // hole) tiers down to re-run the full op in Lantern.
                    const r_obj = code[i + 1];
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x0, regs_reg, regSlot(r_obj)));
                    try m.emit(a64.movReg(.x1, acc_reg));
                    try m.emit(a64.addImm(.x2, frame_reg, acc_off, false));
                    try m.callAbs(.x16, @intFromPtr(&denseGetShim));
                    try m.emit(a64.movRegW(.x0, .x0));
                    try m.jumpCbz(.x0, td);
                    try m.emit(a64.ldrImm(acc_reg, frame_reg, acc_off));
                },
                .make_array_n => {
                    // docs/ctor-array-build-gap.md L2 — helper-mediated
                    // dense literal. Sync the live accumulator so the
                    // frame slot holds a valid Value during the
                    // helper's allocation-GC (the helper then
                    // overwrites it with the new array, rooting it);
                    // the n source values are already in the GC-rooted
                    // register file (regs_reg == f.registers).
                    const r_base = code[i + 1];
                    const n = code[i + 2];
                    try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
                    try m.emit(a64.movReg(.x0, realm_reg));
                    try m.emit(a64.movReg(.x1, regs_reg));
                    try m.movImm64(.x2, r_base);
                    try m.movImm64(.x3, n);
                    try m.emit(a64.addImm(.x4, frame_reg, acc_off, false));
                    try m.callAbs(.x16, @intFromPtr(&makeArrayShim));
                    try m.emit(a64.movRegW(.x0, .x0));
                    try m.jumpCbnz(.x0, &self.oom_label);
                    try m.emit(a64.ldrImm(acc_reg, frame_reg, acc_off));
                },

                .return_ => try m.jump(&self.done_label),

                else => return error.UnsupportedOp,
            }
            i = after;
        }
        // Bytecode always ends in an explicit `return_`; if a chunk
        // ever falls off the end, complete with `undefined` rather
        // than running into the stubs.
        try m.movImm64(acc_reg, Value.undefined_.bits);
        try m.jump(&self.done_label);
    }

    /// The shared exits: per-resume-offset tier-down stubs (cold,
    /// out-of-line), then the done/tier-down tails and the one
    /// epilogue.
    fn tail(self: *Compiler) CompileError!void {
        const m = &self.m;
        for (self.tds.items) |*t| {
            m.bind(&t.label);
            try m.movImm64(.x9, t.resume_off);
            try m.jump(&self.tier_down_label);
        }
        for (self.threws.items) |*t| {
            m.bind(&t.label);
            try m.movImm64(.x9, t.resume_off);
            try m.jump(&self.threw_label);
        }
        m.bind(&self.done_label);
        try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
        try m.emit(a64.movz(.x0, 1, 0)); // EntryResult.done
        var epilogue = Masm.Label{};
        defer epilogue.fixups.deinit(m.gpa);
        try m.jump(&epilogue);
        // x9 = the faulting call op's offset; the accumulator was
        // synced before the call, so only ip needs the store.
        m.bind(&self.threw_label);
        try m.emit(a64.strImm(.x9, frame_reg, ip_off));
        try m.emit(a64.movz(.x0, 2, 0)); // EntryResult.threw
        try m.jump(&epilogue);
        m.bind(&self.oom_label);
        try m.emit(a64.movz(.x0, 3, 0)); // EntryResult.host_oom
        try m.jump(&epilogue);
        // x9 = bytecode offset to resume at.
        m.bind(&self.tier_down_label);
        try m.emit(a64.strImm(.x9, frame_reg, ip_off));
        try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
        try m.emit(a64.movz(.x0, 0, 0)); // EntryResult.resume_interp
        m.bind(&epilogue);
        try m.emit(a64.ldpPostIdxSp(.x23, .x24, 16));
        try m.emit(a64.ldpPostIdxSp(.x21, .x22, 16));
        try m.emit(a64.ldpPostIdxSp(.x19, .x20, 16));
        try m.emit(a64.ldpPostIdxSp(.fp, .lr, 16));
        try m.emit(a64.ret());
        // OSR entry stubs (docs/jit.md §12 3f): one per loop
        // header — the same prologue, then a jump into the body at
        // the header. The dispatcher enters here from a Lantern
        // back-edge whose loopSafePoint already synced ip and
        // accumulator; frame identity makes the switch a jump.
        for (self.osr_headers.keys()) |hdr| {
            try self.osr_entries.append(m.gpa, .{
                .bc = hdr,
                .code_off = @intCast(m.code.items.len),
            });
            try self.prologue();
            const idx = self.target_labels.get(hdr).?;
            try m.jump(&self.labels.items[idx]);
        }
    }

    /// docs/jit.md §4.6 — every loop back-edge re-checks the step
    /// budget and the host interrupt, exactly like Lantern's
    /// `loopSafePoint`. On either trigger the code tiers down to
    /// the BRANCH TARGET (state is fully committed there); Lantern
    /// then surfaces the RangeError through its own safe point.
    /// Compiled code allocates nothing, so the GC counters can't
    /// move mid-run and aren't checked here.
    fn backEdgeSafePoint(self: *Compiler, target: u32) CompileError!void {
        const m = &self.m;
        const td = try self.tdFor(target);
        try self.loadRealmU64(.x9, step_budget_off);
        try m.jumpCbz(.x9, td);
        try m.emit(a64.subImm(.x9, .x9, 1, false));
        try self.storeRealmU64(.x9, step_budget_off);
        try self.loadRealmU8(.x10, interrupt_off);
        try m.jumpCbnz(.x10, td);
    }

    /// `eor` against the pinned tag, shift the payload away, and
    /// tier down unless the high half-word matched int32.
    fn checkInt32(self: *Compiler, src: a64.Reg, td: *Masm.Label) CompileError!void {
        const m = &self.m;
        try m.emit(a64.eorReg(.x13, src, int32_tag_reg));
        try m.emit(a64.lsrImm(.x13, .x13, 48));
        try m.jumpCbnz(.x13, td);
    }

    fn labelForExisting(self: *Compiler, bc_off: u32) CompileError!*Masm.Label {
        const idx = self.target_labels.get(bc_off) orelse return error.UnsupportedOp;
        return &self.labels.items[idx];
    }

    /// 64-bit field load from `base + off`; the big-offset path
    /// stages through `dst`, so no scratch is clobbered.
    fn loadFieldU64(self: *Compiler, dst: a64.Reg, base: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 32760) {
            try m.emit(a64.ldrImm(dst, base, @intCast(off)));
        } else {
            try m.emit(a64.addImm(dst, base, @intCast(off >> 12), true));
            try m.emit(a64.ldrImm(dst, dst, @intCast(off & 0xFFF)));
        }
    }

    fn loadRealmU64(self: *Compiler, dst: a64.Reg, off: usize) CompileError!void {
        try self.loadFieldU64(dst, realm_reg, off);
    }

    /// Clobbers x13 on the big-offset path (the source register
    /// must be preserved, unlike `loadFieldU64`'s dst-staging).
    fn storeFieldU64(self: *Compiler, src: a64.Reg, base: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 32760) {
            try m.emit(a64.strImm(src, base, @intCast(off)));
        } else {
            try m.emit(a64.addImm(.x13, base, @intCast(off >> 12), true));
            try m.emit(a64.strImm(src, .x13, @intCast(off & 0xFFF)));
        }
    }

    /// Clobbers x13 on the big-offset path.
    fn storeRealmU64(self: *Compiler, src: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 32760) {
            try m.emit(a64.strImm(src, realm_reg, @intCast(off)));
        } else {
            try m.emit(a64.addImm(.x13, realm_reg, @intCast(off >> 12), true));
            try m.emit(a64.strImm(src, .x13, @intCast(off & 0xFFF)));
        }
    }

    fn loadRealmU8(self: *Compiler, dst: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 4095) {
            try m.emit(a64.ldrbImm(dst, realm_reg, @intCast(off)));
        } else {
            try m.emit(a64.addImm(dst, realm_reg, @intCast(off >> 12), true));
            try m.emit(a64.ldrbImm(dst, dst, @intCast(off & 0xFFF)));
        }
    }

    /// Decode a plain-`JSObject` value (the `valueAsPlainObject`
    /// predicate): object NaN-box tag AND kind bits == object —
    /// functions, symbols, and BigInts share the tag and tier
    /// down. On success `dst` holds the object pointer (kind bits
    /// cleared). `src` survives; x12/x13 are clobbered.
    fn emitPlainObject(self: *Compiler, src: a64.Reg, dst: a64.Reg, td: *Masm.Label) CompileError!void {
        const m = &self.m;
        try m.movImm64(.x13, layout.value_bits.tag_object_shifted);
        try m.emit(a64.eorReg(.x13, src, .x13));
        try m.emit(a64.lsrImm(.x12, .x13, 48));
        try m.jumpCbnz(.x12, td);
        // Kind bits live in the pointer's alignment slack (low 2).
        try m.emit(a64.lslImm(.x12, .x13, 62));
        try m.emit(a64.lsrImm(.x12, .x12, 62));
        try m.emit(a64.cmpImm(.x12, @intCast(layout.value_bits.kind_object), false));
        try m.jumpCond(.ne, td);
        try m.emit(a64.lsrImm(dst, .x13, 2));
        try m.emit(a64.lslImm(dst, dst, 2));
    }

    /// `JSObject.slotAt` in machine code: inline slot when
    /// `slot < inline_slot_cap`, overflow buffer otherwise (the
    /// layout-contract slice witness covers the latter). `obj` and
    /// `slot` survive; x12/x13 are clobbered; `dst` may be the
    /// accumulator.
    fn emitSlotRead(self: *Compiler, dst: a64.Reg, obj: a64.Reg, slot: a64.Reg) CompileError!void {
        const m = &self.m;
        var ovf = Masm.Label{};
        defer ovf.fixups.deinit(m.gpa);
        var done = Masm.Label{};
        defer done.fixups.deinit(m.gpa);
        try m.emit(a64.cmpImm(slot, @intCast(layout.object.inline_slot_cap), false));
        try m.jumpCond(.cs, &ovf);
        try m.emit(a64.lslImm(.x13, slot, 3));
        try m.emit(a64.addReg(.x13, .x13, obj));
        try m.emit(a64.ldrImm(dst, .x13, layout.object.inline_slots));
        try m.jump(&done);
        m.bind(&ovf);
        try m.emit(a64.ldrImm(.x12, obj, layout.object.overflow_items_ptr));
        try m.emit(a64.subImm(.x13, slot, @intCast(layout.object.inline_slot_cap), false));
        try m.emit(a64.lslImm(.x13, .x13, 3));
        try m.emit(a64.addReg(.x13, .x13, .x12));
        try m.emit(a64.ldrImm(dst, .x13, 0));
        m.bind(&done);
    }

    /// `JSObject.setSlot` in machine code — the mirror of
    /// `emitSlotRead` with stores.
    fn emitSlotWrite(self: *Compiler, src: a64.Reg, obj: a64.Reg, slot: a64.Reg) CompileError!void {
        const m = &self.m;
        var ovf = Masm.Label{};
        defer ovf.fixups.deinit(m.gpa);
        var done = Masm.Label{};
        defer done.fixups.deinit(m.gpa);
        try m.emit(a64.cmpImm(slot, @intCast(layout.object.inline_slot_cap), false));
        try m.jumpCond(.cs, &ovf);
        try m.emit(a64.lslImm(.x13, slot, 3));
        try m.emit(a64.addReg(.x13, .x13, obj));
        try m.emit(a64.strImm(src, .x13, layout.object.inline_slots));
        try m.jump(&done);
        m.bind(&ovf);
        try m.emit(a64.ldrImm(.x12, obj, layout.object.overflow_items_ptr));
        try m.emit(a64.subImm(.x13, slot, @intCast(layout.object.inline_slot_cap), false));
        try m.emit(a64.lslImm(.x13, .x13, 3));
        try m.emit(a64.addReg(.x13, .x13, .x12));
        try m.emit(a64.strImm(src, .x13, 0));
        m.bind(&done);
    }

    /// The named-property IC read — mirrors the interpreter's two
    /// hit modes exactly, own-data and proto-load, reading the cell
    /// as data (docs/jit.md §4.4); any miss (cold cell, shape
    /// change, proto swap, exotic receiver) jumps to `td` and
    /// Lantern refills. `src_val` holds the receiver Value (read
    /// first; must not be x9-x13); `dst` receives the loaded Value
    /// (written last; may equal `src_val`). Clobbers x9-x13.
    fn emitPropertyIcLoad(
        self: *Compiler,
        src_val: a64.Reg,
        dst: a64.Reg,
        ic_idx: u16,
        td: *Masm.Label,
    ) CompileError!void {
        const m = &self.m;
        try self.emitPlainObject(src_val, .x9, td);
        try self.emitCellAddr(.x10, ic_idx);
        try m.emit(a64.ldrImm(.x11, .x10, layout.ic_cell.shape));
        try m.jumpCbz(.x11, td);
        try m.emit(a64.ldrImm(.x12, .x9, layout.object.shape));
        try m.emit(a64.cmpReg(.x11, .x12));
        try m.jumpCond(.ne, td);
        var proto_path = Masm.Label{};
        defer proto_path.fixups.deinit(m.gpa);
        var next = Masm.Label{};
        defer next.fixups.deinit(m.gpa);
        try m.emit(a64.ldrImm(.x11, .x10, layout.ic_cell.proto));
        try m.jumpCbnz(.x11, &proto_path);
        // Own-data hit: dst = recv.slots[cell.slot].
        try m.emit(a64.ldrImmW(.x11, .x10, layout.ic_cell.slot));
        try self.emitSlotRead(dst, .x9, .x11);
        try m.jump(&next);
        // Proto-load hit: identity of the cached proto, the proto's
        // own shape, AND the realm-wide §10.1.1-mutation counter,
        // exactly per the interpreter's predicate.
        m.bind(&proto_path);
        try m.emit(a64.ldrImm(.x12, .x9, layout.object.prototype));
        try m.emit(a64.cmpReg(.x12, .x11));
        try m.jumpCond(.ne, td);
        try m.emit(a64.ldrImm(.x9, .x10, layout.ic_cell.proto_shape));
        try m.emit(a64.ldrImm(.x13, .x12, layout.object.shape));
        try m.emit(a64.cmpReg(.x9, .x13));
        try m.jumpCond(.ne, td);
        try self.loadRealmU64(.x9, layout.realm.proto_revision_counter);
        try m.emit(a64.ldrImm(.x13, .x10, layout.ic_cell.proto_rev));
        try m.emit(a64.cmpReg(.x9, .x13));
        try m.jumpCond(.ne, td);
        try m.emit(a64.ldrImmW(.x11, .x10, layout.ic_cell.slot));
        try self.emitSlotRead(dst, .x12, .x11);
        m.bind(&next);
    }

    /// The shared helperCall result dispatch: zero-extend the u32
    /// status (AAPCS64 leaves x0's upper half unspecified), then
    /// route value/threw/oom, reloading the accumulator from the
    /// frame on success.
    fn emitCallStatus(self: *Compiler, threw: *Masm.Label) CompileError!void {
        const m = &self.m;
        try m.emit(a64.movRegW(.x0, .x0));
        var ok = Masm.Label{};
        defer ok.fixups.deinit(m.gpa);
        try m.jumpCbz(.x0, &ok);
        try m.emit(a64.cmpImm(.x0, @intFromEnum(HelperCallStatus.threw), false));
        try m.jumpCond(.eq, threw);
        try m.jump(&self.oom_label);
        m.bind(&ok);
        try m.emit(a64.ldrImm(acc_reg, frame_reg, acc_off));
    }

    /// Bake the address of this site's IC cell into `dst`. Cells
    /// are chunk-owned mutable side-state; the chunk outlives the
    /// code, and compiled code only loads through the pointer, so
    /// the GC weak-clear protocol is untouched (docs/jit.md §4.4).
    fn emitCellAddr(self: *Compiler, dst: a64.Reg, ic_idx: u16) CompileError!void {
        if (ic_idx >= self.chunk.inline_caches.len) return error.UnsupportedOp;
        const addr: u64 = @intFromPtr(&self.chunk.inline_caches[ic_idx]);
        try self.m.movImm64(dst, addr);
    }

    /// Like `emitCellAddr` for the call-IC table.
    fn emitCallCellAddr(self: *Compiler, dst: a64.Reg, ic_idx: u16) CompileError!void {
        if (ic_idx >= self.chunk.inline_call_caches.len) return error.UnsupportedOp;
        const addr: u64 = @intFromPtr(&self.chunk.inline_call_caches[ic_idx]);
        try self.m.movImm64(dst, addr);
    }

    /// The shared compiled-call tail (docs/jit.md §4.5 + the
    /// CallICCell fast path): callee Value in `callee_val`, `this`
    /// from a register or undefined, args window at
    /// `args_base..+argc`. A cell hit (vetted plain JSFunction,
    /// pointer match) dispatches through helperCallDirect; any
    /// miss — cold cell, different callee, non-function — takes
    /// the generic helperCall, which handles every callee kind.
    /// Clobbers x9-x13 and the argument registers.
    fn emitCallDispatch(
        self: *Compiler,
        callee_val: a64.Reg,
        this_from: ?u8,
        args_base: u8,
        argc: u8,
        ic_call: u16,
        threw: *Masm.Label,
    ) CompileError!void {
        const m = &self.m;
        var generic = Masm.Label{};
        defer generic.fixups.deinit(m.gpa);
        var joined = Masm.Label{};
        defer joined.fixups.deinit(m.gpa);
        // Function-kind heap pointer? (kind bits 0) — else generic.
        try m.movImm64(.x13, layout.value_bits.tag_object_shifted);
        try m.emit(a64.eorReg(.x13, callee_val, .x13));
        try m.emit(a64.lsrImm(.x12, .x13, 48));
        try m.jumpCbnz(.x12, &generic);
        try m.emit(a64.lslImm(.x12, .x13, 62));
        try m.emit(a64.lsrImm(.x12, .x12, 62));
        try m.jumpCbnz(.x12, &generic);
        try m.emit(a64.lsrImm(.x10, .x13, 2));
        try m.emit(a64.lslImm(.x10, .x10, 2));
        // Cell compare.
        try self.emitCallCellAddr(.x11, ic_call);
        try m.emit(a64.ldrImm(.x12, .x11, layout.call_ic_cell.callee));
        try m.jumpCbz(.x12, &generic);
        try m.emit(a64.cmpReg(.x10, .x12));
        try m.jumpCond(.ne, &generic);
        // Hit: the vetted-function direct path.
        try m.emit(a64.movReg(.x2, .x10));
        try m.emit(a64.movReg(.x0, realm_reg));
        try m.emit(a64.movReg(.x1, frame_reg));
        if (this_from) |r_this| {
            try m.emit(a64.ldrImm(.x3, regs_reg, regSlot(r_this)));
        } else {
            try m.movImm64(.x3, Value.undefined_.bits);
        }
        try m.emit(a64.addImm(.x4, regs_reg, @intCast(@as(u32, regSlot(args_base))), false));
        try m.movImm64(.x5, argc);
        try m.emit(a64.addImm(.x6, frame_reg, acc_off, false));
        try m.callAbs(.x16, @intFromPtr(&helperCallDirect));
        try m.jump(&joined);
        // Miss: generic dispatch on the raw Value.
        m.bind(&generic);
        try m.emit(a64.movReg(.x2, callee_val));
        try m.emit(a64.movReg(.x0, realm_reg));
        try m.emit(a64.movReg(.x1, frame_reg));
        if (this_from) |r_this| {
            try m.emit(a64.ldrImm(.x3, regs_reg, regSlot(r_this)));
        } else {
            try m.movImm64(.x3, Value.undefined_.bits);
        }
        try m.emit(a64.addImm(.x4, regs_reg, @intCast(@as(u32, regSlot(args_base))), false));
        try m.movImm64(.x5, argc);
        try m.emit(a64.addImm(.x6, frame_reg, acc_off, false));
        try m.callAbs(.x16, @intFromPtr(&helperCall));
        m.bind(&joined);
        try self.emitCallStatus(threw);
    }
};

fn regSlot(r: u8) u15 {
    return @as(u15, r) * 8;
}

fn targetOf(after_operand: usize, off: i16) u32 {
    return @intCast(@as(i64, @intCast(after_operand)) + off);
}

fn readI16(code: []const u8, at: usize) i16 {
    return std.mem.readInt(i16, code[at..][0..2], .little);
}

fn readU32(code: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, code[at..][0..4], .little);
}

fn readU16(code: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, code[at..][0..2], .little);
}

fn readI32(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, code[at..][0..4], .little);
}

// ── Tests ──────────────────────────────────────────────────────────
// End-to-end through the real pipeline: parse → compile → heat in
// Lantern → tier up → execute compiled → assert identical results.

const testing = std.testing;
const parser_mod = @import("../../parser/parser.zig");
const bc_compiler = @import("../../bytecode/compiler.zig");

/// Look a function template up by its declared name — template
/// indices mix hoisted declarations and source-order expressions,
/// so positional asserts lie.
fn templateNamed(chunk: *const Chunk, name: []const u8) *const Chunk {
    for (chunk.function_templates) |*t| {
        if (t.name) |n| {
            if (std.mem.eql(u8, n, name)) return &t.chunk;
        }
    }
    unreachable;
}

test "jit bistromath: hot int function compiles and computes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    const src =
        \\function f(a, b) { return (a * b + a - b) | 0; }
        \\let r = 0;
        \\let i = 0;
        \\while (i < 200) { r = f(i, 3); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 199 * 3 + 199 - 3), v.asInt32());
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);
    try testing.expect(js.entry != null);
}

test "jit bistromath: non-int operands tier down and stay correct" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Heat `f` on ints until compiled, then hand it strings: the
    // `mul` tag check tiers down mid-function and Lantern finishes
    // with the spec answer ("x" * "y" → NaN).
    const src =
        \\function f(a, b) { return a * b; }
        \\let i = 0;
        \\while (i < 200) { f(3, 4); i = i + 1; }
        \\f("x", "y");
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);
    try testing.expect(v.isDouble());
    try testing.expect(std.math.isNan(v.asDouble()));
}

test "jit bistromath: the step budget interrupts a compiled loop" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Heat + tier up: the first call's 2000 back-edges alone clear
    // the threshold; the second call runs compiled. The `let` local
    // is register-promoted (body-locals promotion), so the chunk
    // carries no env opcodes and compiles whole.
    const src1 =
        \\function spin(n) { let i = 0; while (i < n) { i = i + 1; } return i; }
        \\spin(2000); spin(10);
    ;
    const program1 = try parser_mod.parseScript(arena.allocator(), src1, null);
    var chunk1 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program1, src1, null);
    defer chunk1.deinit(testing.allocator);
    const out1 = try interpreter.run(testing.allocator, &realm, &chunk1);
    const v1 = switch (out1) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 10), v1.asInt32());
    const js = chunk1.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);

    // A compiled unbounded loop must still honour the host's step
    // budget (docs/jit.md §4.6): the back-edge safepoint tiers
    // down and Lantern raises the catchable RangeError.
    realm.step_budget = 1_000;
    const src2 = "spin(1000000000);";
    const program2 = try parser_mod.parseScript(arena.allocator(), src2, null);
    var chunk2 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program2, src2, null);
    defer chunk2.deinit(testing.allocator);
    const out2 = try interpreter.run(testing.allocator, &realm, &chunk2);
    try testing.expect(out2 == .thrown);
}

test "jit bistromath: unsupported opcodes mark the chunk dont_compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    const src =
        \\function g(a, b) { return a / b; }
        \\let i = 0;
        \\let r = 0;
        \\while (i < 200) { r = g(i, 2); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isDouble());
    try testing.expectEqual(@as(f64, 99.5), v.asDouble());
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.dont_compile, js.tier);
    try testing.expect(js.entry == null);
}

test "jit bistromath: make_environment(0) with env reads dont_compiles" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    // Force-compile every eligible chunk on its first call (the §10
    // differential posture) so `inner` reaches the compiler.
    realm.jit_threshold_override = 1;

    // `inner` pushes a 0-slot lexical env for the empty block scope AND
    // reads `a` from `outer` through it via `lda_env ^1`. Eliding the
    // 0-slot env would leave `frame.env` one scope too shallow, so that
    // read would resolve to the wrong slot — the chunk must dont_compile
    // instead. Regression for the await-using force-compile divergence
    // (docs/jit.md §10): the shared `assert.deepEqual` helper carried
    // exactly this shape and, compiled, read an outer var as garbage and
    // unwound as a spurious `throw undefined`, rejecting the async test.
    const src =
        \\function outer(a) {
        \\  function inner() { { let z = 0; z; } return a; }
        \\  return inner;
        \\}
        \\let f = outer(42);
        \\let i = 0;
        \\let r = 0;
        \\while (i < 10) { r = f(); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    // `inner` keeps reading `a` correctly (served by Lantern).
    try testing.expectEqual(@as(i32, 42), v.asInt32());
    // And it refused compilation rather than emitting the wrong env read.
    const inner_js = chunk.function_templates[0].chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.dont_compile, inner_js.tier);
}

test "jit bistromath ic: own-property reads compile; shape miss tiers down" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Same-shape receivers heat `get` into compiled code reading
    // through the own-data IC; the final differently-shaped
    // receiver misses the shape compare, tiers down, and Lantern
    // serves (and refills) — the answer must be right either way.
    const src =
        \\function get(o) { return o.x; }
        \\let i = 0;
        \\let r = 0;
        \\while (i < 200) { r = r + get({ x: 1 }); i = i + 1; }
        \\r + get({ y: 0, x: 42 });
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 242), v.asInt32());
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);
}

test "jit bistromath ic: proto-load reads serve through the chain" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // `m` lives on C.prototype — the IC fills in proto-load mode,
    // and the compiled fast path must verify proto identity, the
    // proto's shape, and the realm revision counter, then read the
    // PROTO's slots.
    const src =
        \\function C() {}
        \\C.prototype.m = 42;
        \\function getm(o) { return o.m; }
        \\let i = 0;
        \\let r = 0;
        \\while (i < 200) { r = getm(new C()); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 42), v.asInt32());
    const getm_js = chunk.function_templates[1].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, getm_js.tier);
}

test "jit bistromath ic: global reads compile and respect decl_revision" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    const src1 =
        \\var G = 7;
        \\function g() { return G; }
        \\let i = 0;
        \\let r = 0;
        \\while (i < 200) { r = g(); i = i + 1; }
        \\r;
    ;
    const program1 = try parser_mod.parseScript(arena.allocator(), src1, null);
    var chunk1 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program1, src1, null);
    defer chunk1.deinit(testing.allocator);
    const out1 = try interpreter.run(testing.allocator, &realm, &chunk1);
    const v1 = switch (out1) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 7), v1.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk1.function_templates[0].chunk.jit_state.?.tier,
    );

    // A fresh global `let` bumps decl_revision — the compiled fast
    // path must miss, tier down, and still answer correctly after
    // Lantern refills against the new revision.
    const src2 =
        \\let H = 1;
        \\g();
    ;
    const program2 = try parser_mod.parseScript(arena.allocator(), src2, null);
    var chunk2 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program2, src2, null);
    defer chunk2.deinit(testing.allocator);
    const out2 = try interpreter.run(testing.allocator, &realm, &chunk2);
    const v2 = switch (out2) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 7), v2.asInt32());
}

test "jit bistromath ic: compiled writes hit the same barrier as Lantern" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Heat `put` into compiled code, mature the receiver, then have
    // COMPILED code store freshly-allocated (young) strings into it
    // and collect. The §9 barrier mirror is what keeps the
    // mature→young edge remembered; under ReleaseSafe the
    // remembered-set verifier audits exactly this, and the read-back
    // proves the value survived.
    const src1 =
        \\var target = { x: 0 };
        \\function put(o, v) { o.x = v; }
        \\let i = 0;
        \\while (i < 200) { put(target, i); i = i + 1; }
        \\target.x;
    ;
    const program1 = try parser_mod.parseScript(arena.allocator(), src1, null);
    var chunk1 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program1, src1, null);
    defer chunk1.deinit(testing.allocator);
    const out1 = try interpreter.run(testing.allocator, &realm, &chunk1);
    const v1 = switch (out1) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 199), v1.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk1.function_templates[0].chunk.jit_state.?.tier,
    );

    // Promote `target` to the mature generation.
    realm.collectGarbage();

    // Compiled writes of young heap values into the mature object,
    // then a minor collection: a missed barrier would sweep the
    // string (ReleaseSafe poisons it 0xaa) before the read.
    const src2 =
        \\put(target, "young-" + 1234);
        \\target.x;
    ;
    const program2 = try parser_mod.parseScript(arena.allocator(), src2, null);
    var chunk2 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program2, src2, null);
    defer chunk2.deinit(testing.allocator);
    const out2 = try interpreter.run(testing.allocator, &realm, &chunk2);
    _ = switch (out2) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    realm.collectGarbageYoung();
    const src3 = "target.x;";
    const program3 = try parser_mod.parseScript(arena.allocator(), src3, null);
    var chunk3 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program3, src3, null);
    defer chunk3.deinit(testing.allocator);
    const out3 = try interpreter.run(testing.allocator, &realm, &chunk3);
    const v3 = switch (out3) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v3.isString());
    const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(v3.asString()));
    try testing.expectEqualStrings("young-1234", s.flatBytes());
}

test "jit bistromath: loop_inc_lt compiles; int32 overflow tiers down" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // `lp` exercises the fused counter loop in compiled form — the
    // fusion (and the counter's register promotion) requires the
    // literal-bound `for (let i = 0; i < INT; i++)` shape; a
    // variable bound keeps the header `let` env-resident and the
    // chunk honestly dont_compiles. `ovf` and `movf` push add/mul
    // past i32 — the overflow checks must tier down and Lantern's
    // double math must produce the spec answers.
    const src =
        \\function lp() { let s = 0; for (let i = 0; i < 100; i++) { s = (s + i) | 0; } return s; }
        \\function ovf(a) { return a + 1; }
        \\function movf(a) { return a * a; }
        \\let i = 0;
        \\while (i < 200) { lp(); ovf(1); movf(2); i = i + 1; }
        \\"" + lp() + "," + ovf(2147483647) + "," + movf(65536);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings("4950,2147483648,4294967296", s.flatBytes());
    for (0..3) |t| {
        try testing.expectEqual(
            Chunk.JitState.Tier.compiled,
            chunk.function_templates[t].chunk.jit_state.?.tier,
        );
    }
}

test "jit bistromath ic: overflow-slot property reads and writes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Six properties push `f` past the inline_slot_cap — the
    // compiled slot accessor's overflow branch (the slice-layout
    // witness's consumer) serves both directions.
    const src =
        \\var o = { a: 0, b: 1, c: 2, d: 3, e: 4, f: 5 };
        \\function rd(x) { return x.f; }
        \\function wr(x, v) { x.f = v; }
        \\let i = 0;
        \\while (i < 200) { wr(o, i); rd(o); i = i + 1; }
        \\wr(o, 4242);
        \\rd(o);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 4242), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[1].chunk.jit_state.?.tier,
    );
}

test "jit bistromath: a TDZ read in compiled code tiers down and throws" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // §13.3.1 — `y` is a promoted register seeded with the Hole;
    // the b=true path reads it before the declaration. Compiled
    // code's throw_if_hole tiers down and Lantern raises the
    // ReferenceError.
    const src =
        \\function f(b) { if (b) { return y; } let y = 1; return y; }
        \\let i = 0;
        \\while (i < 300) { f(false); i = i + 1; }
        \\f(true);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    try testing.expect(out == .thrown);
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}

test "jit bistromath: a hot function stays correct under `new`" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // tryEnterTop refuses construct frames — `new F()` must run the
    // §10.2.2 verdict path in Lantern and yield the fresh `this`
    // even while plain calls of F run compiled.
    const src =
        \\function F(x) { return x + 1; }
        \\let i = 0;
        \\while (i < 200) { F(i); i = i + 1; }
        \\typeof new F(1);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings("object", s.flatBytes());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}

test "jit bistromath: baked heap constants survive a full GC" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The string constant's Value bits are baked into the code as
    // an immediate (docs/jit.md §9) — legal because the chunk roots
    // its constants and the heap never moves. A full collection
    // between activations is the audit.
    const src1 =
        \\function s() { return "lit-const"; }
        \\let i = 0;
        \\while (i < 300) { s(); i = i + 1; }
        \\s();
    ;
    const program1 = try parser_mod.parseScript(arena.allocator(), src1, null);
    var chunk1 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program1, src1, null);
    defer chunk1.deinit(testing.allocator);
    _ = switch (try interpreter.run(testing.allocator, &realm, &chunk1)) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk1.function_templates[0].chunk.jit_state.?.tier,
    );

    realm.collectGarbage();

    const src2 = "s();";
    const program2 = try parser_mod.parseScript(arena.allocator(), src2, null);
    var chunk2 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program2, src2, null);
    defer chunk2.deinit(testing.allocator);
    const out2 = try interpreter.run(testing.allocator, &realm, &chunk2);
    const v2 = switch (out2) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v2.isString());
    const s2: *@import("../string.zig").JSString = @ptrCast(@alignCast(v2.asString()));
    try testing.expectEqualStrings("lit-const", s2.flatBytes());
}

test "jit bistromath: a non-bool branch condition tiers down correctly" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // `if (n)` puts an int32 in the condition — the compiled
    // bool-tag check tiers down every time and §7.1.2 ToBoolean
    // runs in Lantern; both arms must stay right.
    const src =
        \\function c(n) { if (n) { return 1; } return 2; }
        \\let i = 0;
        \\while (i < 300) { c(5); i = i + 1; }
        \\c(7) * 10 + c(0);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 12), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}

test "jit bistromath calls: a hot caller invokes through the tier" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // docs/jit.md §12 step 3e — the helper-mediated call: a caller
    // containing `call` opcodes must itself compile, marshal the
    // args window, and receive the callee's result in the
    // accumulator. The callee is also hot, so the nested entry
    // exercises compiled→helper→compiled.
    const src =
        \\function add1(x) { return x + 1; }
        \\function caller(n) { return add1(n) + add1(n); }
        \\let i = 0;
        \\while (i < 300) { caller(i); i = i + 1; }
        \\caller(20);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 42), v.asInt32());
    // add1 is template 0, caller is template 1.
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[1].chunk.jit_state.?.tier,
    );
}

test "jit bistromath calls: callee exceptions unwind through compiled callers" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // A TDZ ReferenceError raised two compiled frames down must
    // unwind through the compiled `mid` (EntryResult.threw routing)
    // and land in the top-level catch with the right answer.
    const src =
        \\function boom(b) { if (b) { return zz; } let zz = 1; return zz; }
        \\function mid(b) { return boom(b) + 1; }
        \\let i = 0;
        \\while (i < 300) { mid(false); i = i + 1; }
        \\let r = 0;
        \\try { mid(true); } catch (e) { r = 9; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 9), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[1].chunk.jit_state.?.tier,
    );
}

test "jit bistromath osr: a single-call hot loop enters mid-loop" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The arith_loop shape (docs/jit.md §12 3f): one call, one hot
    // loop. Entry-time tier-up never fires (warmth is 16 at the
    // call); the back-edges heat the chunk mid-run and OSR must
    // compile + enter at the loop header. 60000 iterations keep
    // `s` inside int32 (sum = 1_799_970_000).
    const src =
        \\function big() { let s = 0; for (let i = 0; i < 60000; i++) { s = (s + i) | 0; } return s; }
        \\big();
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 1_799_970_000), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "big").jit_state.?.tier,
    );
}

test "jit bistromath osr: top-level script loops enter the tier" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The arith_loop bench fixture's own shape (docs/jit.md §12
    // 3g): a script-chunk fused loop over a top-level `let`
    // accumulator — `lda/sta_global_slot` against the §9.1.1.4
    // declarative record, OSR-entered mid-run.
    const src =
        \\let sum = 0;
        \\for (let i = 0; i < 60000; i++) { sum = (sum + i) | 0; }
        \\sum;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 1_799_970_000), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.jit_state.?.tier,
    );
}

test "jit bistromath env: closures over captured locals compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The closure-callee shape (docs/jit.md §12 3g): the inner
    // function reads and writes `c` through lda_env / sta_env
    // depth-1 walks; the env store runs the same storeEnvSlot
    // barrier as the interpreter (§9).
    const src =
        \\function make() { let c = 0; return function () { c = c + 1; return c; }; }
        \\var inc = make();
        \\let i = 0;
        \\while (i < 300) { inc(); i = i + 1; }
        \\inc();
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 301), v.asInt32());
    // The inner closure is anonymous — it is make's template 0.
    const make_chunk = templateNamed(&chunk, "make");
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        make_chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}

test "jit bistromath: unary negate/bit_not/logical_not compile with the edge tier-downs" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // §13.5.5 unary minus: -0 is a double and INT32_MIN negates
    // out of range — both tier down; §13.5.6 / §13.5.7 stay int32
    // and bool. The string assembles all four answers.
    const src =
        \\function u(b, x) { if (b) { return !b; } return (-x) + (~x); }
        \\function nz(x) { return -x; }
        \\let i = 0;
        \\while (i < 300) { u(true, 1); u(false, 5); nz(5); i = i + 1; }
        \\"" + u(true, 9) + "," + u(false, 7) + "," + ((1 / nz(0)) < 0) + "," + nz(-2147483648);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const sres: *@import("../string.zig").JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings("false,-15,true,2147483648", sres.flatBytes());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "u").jit_state.?.tier,
    );
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "nz").jit_state.?.tier,
    );
}

test "jit bistromath: class methods with body locals compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Method bodies get the same non-captured let/const register
    // promotion as plain functions (docs/jit.md §12 3g) — without
    // it every method with a local is env-resident and the tier
    // never sees it.
    const src =
        \\class A { step(n) { let t = n + 1; let u = t * 2; return u - n; } }
        \\var a = new A();
        \\let i = 0;
        \\while (i < 300) { a.step(i); i = i + 1; }
        \\a.step(10);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 12), v.asInt32());
    // Method chunks live on the class template, not in
    // function_templates.
    const step_chunk = &chunk.class_templates[0].instance_methods[0].chunk;
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        step_chunk.jit_state.?.tier,
    );
}

test "jit bistromath calls: self-tail-call dispatch follows callee identity" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Guard for the §15.10 jump-to-entry optimization: the tail
    // call dispatches on the VALUE in the callee register, not the
    // textual self-reference — after `swap`, the same hot site
    // must call the replacement. And an arrow's self-recursion
    // (captured `this` / new.target) must stay correct and
    // constant-stack at depth 200000.
    const src =
        \\function make() {
        \\  let self = null;
        \\  function inner(n, acc) { if (n === 0) { return acc; } return self(n - 1, acc + 1); }
        \\  self = inner;
        \\  return { run: inner, swap: function (f) { self = f; } };
        \\}
        \\var m = make();
        \\let i = 0;
        \\while (i < 300) { m.run(3, 0); i = i + 1; }
        \\var deep = m.run(200000, 0);
        \\m.swap(function (n, acc) { return acc * 100; });
        \\var swapped = m.run(3, 0);
        \\const arrow = (n) => n === 0 ? 7 : arrow(n - 1);
        \\"" + deep + "," + swapped + "," + arrow(200000);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    // deep = 200000; swapped: inner(3,0) -> self(2,1) -> 1*100 = 100;
    // arrow = 7.
    try testing.expect(v.isString());
    const sres: *@import("../string.zig").JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings("200000,100,7", sres.flatBytes());
}

test "jit bistromath calls: the call-IC compare misses correctly" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Guard for the CallICCell inline compare (docs/jit.md §12
    // 3e follow-up): the cell warms on `a`, then the same hot
    // site receives a different function (compare miss → generic
    // dispatch) and a non-function (kind miss → the §7.3.x
    // TypeError through the generic path).
    const src =
        \\function a(x) { return x + 1; }
        \\function b(x) { return x * 10; }
        \\function site(g, x) { return g(x) + 0; }
        \\let i = 0;
        \\while (i < 300) { site(a, i); i = i + 1; }
        \\let r = "no-throw";
        \\try { site(7, 1); } catch (e) { r = "threw"; }
        \\"" + site(a, 5) + "," + site(b, 5) + "," + r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isString());
    const sres: *@import("../string.zig").JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings("6,50,threw", sres.flatBytes());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "site").jit_state.?.tier,
    );
}

test "jit bistromath: dense indexed reads compile via lda_computed fast path" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    try realm.installBuiltins();

    // A hot loop summing dense int32-indexed reads (`arr[j]`,
    // `lda_computed`). Before this op was taught to Bistromath the
    // function tiered DOWN at every indexed read
    // (docs/ctor-array-build-gap.md L1). The sum is correct either
    // way; the tier assertion is the red->green signal.
    const src =
        \\function sumArr(arr, n) { let s = 0; let j = 0; while (j < n) { s = s + arr[j]; j = j + 1; } return s; }
        \\var a = [10, 20, 30, 40, 50];
        \\let i = 0;
        \\while (i < 300) { sumArr(a, 5); i = i + 1; }
        \\sumArr(a, 5);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 150), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "sumArr").jit_state.?.tier,
    );
}

test "jit bistromath: dense array literals compile via make_array_n" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    try realm.installBuiltins();

    // A hot function whose body builds a dense 3-element literal from
    // its params (`make_array_n`) and returns it. Before this opcode
    // was taught to Bistromath, the function tiered DOWN — make_array_n
    // was UnsupportedOp, so a hot loop containing any array literal
    // never compiled (docs/ctor-array-build-gap.md L2). The result is
    // correct either way (interpreted or compiled); the tier assertion
    // is the red->green signal, and the element checks pin parity.
    const src =
        \\function build(a, b, c) { return [a, b, c]; }
        \\let i = 0;
        \\while (i < 300) { build(i, i + 1, i + 2); i = i + 1; }
        \\build(10, 20, 30);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    const arr = heap_mod.valueAsPlainObject(v) orelse return error.NotAnArray;
    try testing.expect(arr.is_array_exotic);
    try testing.expectEqual(@as(usize, 3), arr.elements.items.len);
    try testing.expectEqual(@as(i32, 10), arr.elements.items[0].asInt32());
    try testing.expectEqual(@as(i32, 20), arr.elements.items[1].asInt32());
    try testing.expectEqual(@as(i32, 30), arr.elements.items[2].asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "build").jit_state.?.tier,
    );
}

test "jit bistromath: var-local bodies compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The last promotion class (jit.md delivery step 3g): simple
    // function-scoped `var` locals live in registers seeded with
    // undefined (§14.3.2 — vars have no TDZ), so var-style bodies
    // compile like their let/const twins.
    const src =
        \\function v(n) { var s = 0; var i = 0; while (i < n) { s = (s + i) | 0; i = i + 1; } return s; }
        \\let k = 0;
        \\while (k < 300) { v(50); k = k + 1; }
        \\v(100);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 4950), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "v").jit_state.?.tier,
    );
}

test "jit bistromath: hardened realms keep global ICs warm" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    // HARDENED (the default) — installBuiltins freezes globalThis.
    try realm.installBuiltins();

    // Script-declared global functions must stay shape-resident on
    // the frozen global object so `lda_global` cells fill and
    // compiled code reads them without tiering down — while the
    // §20.1.2.5 freeze semantics stay intact (the script asserts
    // both observable halves).
    const src =
        \\function leaf(x) { return x + 1; }
        \\function callr(x) { return leaf(x) + 0; }
        \\let i = 0;
        \\while (i < 300) { callr(i); i = i + 1; }
        \\let frozen_ok = 0;
        \\if (Object.isFrozen(Object) === false) { frozen_ok = 1; }
        \\if (Object.isExtensible(Math)) { frozen_ok = 2; }
        \\callr(5) * 10 + frozen_ok;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    // callr(5) = 6; frozen_ok must stay 0.
    try testing.expectEqual(@as(i32, 60), v.asInt32());
    // The compiled-call gate: callr's global cell for `leaf` must
    // have FILLED during heating (a cold cell means every compiled
    // read tiers down — the hardened-realm IC hole).
    const callr_chunk = templateNamed(&chunk, "callr");
    var any_filled = false;
    for (callr_chunk.inline_caches) |cell| {
        if (cell.shape != null) any_filled = true;
    }
    try testing.expect(any_filled);
}

test "jit bistromath calls: method calls bind `this` through the tier" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The fused `call_property` shape (`o.pm(a)` with a plain
    // identifier name) in compiled callers, for both proto- and
    // own-resolved methods, with `this`-dependent results. The
    // `+ 0` keeps the calls out of tail position (a tail call is
    // its own opcode).
    const src =
        \\function C() { this.v = 10; }
        \\C.prototype.pm = function (x) { return this.v + x; };
        \\var o = new C();
        \\o.om = function (x) { return this.v + x + 100; };
        \\function callsProto(a) { return o.pm(a) + 0; }
        \\function callsOwn(a) { return o.om(a) + 0; }
        \\let i = 0;
        \\while (i < 300) { callsProto(1); callsOwn(1); i = i + 1; }
        \\callsProto(5) * 1000 + callsOwn(5);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    // callsProto(5) = 10+5 = 15; callsOwn(5) = 10+5+100 = 115.
    try testing.expectEqual(@as(i32, 15 * 1000 + 115), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "callsProto").jit_state.?.tier,
    );
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        templateNamed(&chunk, "callsOwn").jit_state.?.tier,
    );
}

test "jit bistromath calls: tail calls tier down and keep constant stack" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // §15.10 — a compiled function containing `tail_call` must
    // still recurse in constant stack: the op tiers down and
    // Lantern's frame-reuse reframe takes over (jump-to-entry for
    // the self-recursive case is the recorded follow-up). The
    // 200000 depth blows any native-stack scheme.
    const src =
        \\function spin(n, a) { if (n === 0) return a; return spin(n - 1, a + 1); }
        \\let i = 0;
        \\while (i < 300) { spin(3, 0); i = i + 1; }
        \\spin(200000, 0);
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 200000), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}

test "jit bistromath: methods reading `this` compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // The method_call-bench shape: a hot method whose body is
    // lda_this + property read/write. A plain frame's `this` is
    // always initialised, so the compiled path is a frame-field
    // load; arrows under derived ctors tier down via
    // super_called_cell (untestable without class builtins here;
    // the differential covers it).
    const src =
        \\function inc() { this.n = this.n + 1; return this.n; }
        \\var o = { n: 0 };
        \\o.inc = inc;
        \\let i = 0;
        \\while (i < 300) { o.inc(); i = i + 1; }
        \\o.inc();
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 301), v.asInt32());
    try testing.expectEqual(
        Chunk.JitState.Tier.compiled,
        chunk.function_templates[0].chunk.jit_state.?.tier,
    );
}
