//! x86_64 Spasm backend.
//!
//! This first backend slice keeps scalar operands in the existing trailing
//! `Cell` scratch area rather than trying to project AArch64's seven-register
//! cache onto the smaller SysV register file. The validated-bytecode compiler
//! remains one pass, constants still fold, and unsupported instructions refuse
//! transactionally so Sarcasm remains the semantic fallback.

const std = @import("std");

const x64 = @import("../jit/asm_x86_64.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const CompiledFunc = @import("code.zig").CompiledFunc;
const Module = @import("module.zig").Module;
const FuncType = @import("types.zig").FuncType;
const ValType = @import("types.zig").ValType;

pub const operand_stack_capacity = 7;

pub const Error = error{
    OutOfMemory,
    LabelAlreadyBound,
    InvalidLabel,
    BranchOutOfRange,
};

/// Why one x86_64 compilation attempt degraded to Sarcasm. The compiler
/// records one terminal reason before returning null; executable code is never
/// published for a refused body.
pub const RefusalStage = enum(u8) {
    none,
    limits,
    signature,
    bytecode,
    unsupported_opcode,
    emission,
    install,
    count,
};

pub const refusal_stage_count: usize = @intFromEnum(RefusalStage.count) - 1;

pub const Diagnostics = struct {
    stage: RefusalStage = .none,
    opcode: u8 = 0,
    has_opcode: bool = false,
};

pub const Config = struct {
    execution_poll_helper: usize,
    call_helper: ?usize,
    call_gate_stub: ?usize,
    call_gates_base: ?usize,
    call_gates_len: usize,
    call_gate_stride: usize,
    wake_flag_offset: i32,
    trap_divide_by_zero: u32,
    trap_int_overflow: u32,
    trap_out_of_bounds: u32,
    trap_call_stack_exhausted: u32,
    mem_view_helper: ?usize,
    mem_grow_helper: ?usize,
    diagnostics: ?*Diagnostics = null,
};

const frame_size: u32 = 56;
const saved_r12_off: i32 = 8;
const saved_r13_off: i32 = 16;
const saved_r14_off: i32 = 24;
const saved_r15_off: i32 = 32;
const saved_rbx_off: i32 = 40;
const saved_rbp_off: i32 = 48;
const entry_stack_limit_off: i32 = frame_size + 8;
const entry_execution_control_off: i32 = frame_size + 16;
const native_entry_stack_bytes: u32 = frame_size + 8; // return address + target prologue
// stack_limit, execution_control, private CallGate*, then 8 bytes of padding
// so the Cell buffer remains 16-byte aligned.
const call_stack_args_size: usize = 32;
const max_call_frame_bytes: usize = 64 * 1024;

const op_nop: u8 = 0x01;
const op_block: u8 = 0x02;
const op_loop: u8 = 0x03;
const op_if: u8 = 0x04;
const op_else: u8 = 0x05;
const op_end: u8 = 0x0b;
const op_br: u8 = 0x0c;
const op_br_if: u8 = 0x0d;
const op_call: u8 = 0x10;
const op_drop: u8 = 0x1a;
const op_local_get: u8 = 0x20;
const op_local_set: u8 = 0x21;
const op_local_tee: u8 = 0x22;
const op_global_get: u8 = 0x23;
const op_global_set: u8 = 0x24;
const op_i32_load: u8 = 0x28;
const op_i64_load: u8 = 0x29;
const op_i32_load8_s: u8 = 0x2c;
const op_i32_load8_u: u8 = 0x2d;
const op_i32_load16_s: u8 = 0x2e;
const op_i32_load16_u: u8 = 0x2f;
const op_i64_load8_s: u8 = 0x30;
const op_i64_load8_u: u8 = 0x31;
const op_i64_load16_s: u8 = 0x32;
const op_i64_load16_u: u8 = 0x33;
const op_i64_load32_s: u8 = 0x34;
const op_i64_load32_u: u8 = 0x35;
const op_i32_store: u8 = 0x36;
const op_i64_store: u8 = 0x37;
const op_i32_store8: u8 = 0x3a;
const op_i32_store16: u8 = 0x3b;
const op_i64_store8: u8 = 0x3c;
const op_i64_store16: u8 = 0x3d;
const op_i64_store32: u8 = 0x3e;
const op_memory_size: u8 = 0x3f;
const op_memory_grow: u8 = 0x40;
const op_i32_const: u8 = 0x41;
const op_i64_const: u8 = 0x42;
const op_i32_eqz: u8 = 0x45;
const op_i32_eq: u8 = 0x46;
const op_i32_ne: u8 = 0x47;
const op_i32_lt_s: u8 = 0x48;
const op_i32_lt_u: u8 = 0x49;
const op_i32_gt_s: u8 = 0x4a;
const op_i32_gt_u: u8 = 0x4b;
const op_i32_le_s: u8 = 0x4c;
const op_i32_le_u: u8 = 0x4d;
const op_i32_ge_s: u8 = 0x4e;
const op_i32_ge_u: u8 = 0x4f;
const op_i32_add: u8 = 0x6a;
const op_i32_sub: u8 = 0x6b;
const op_i32_mul: u8 = 0x6c;
const op_i32_div_s: u8 = 0x6d;
const op_i32_div_u: u8 = 0x6e;
const op_i32_rem_s: u8 = 0x6f;
const op_i32_rem_u: u8 = 0x70;
const op_i32_and: u8 = 0x71;
const op_i32_or: u8 = 0x72;
const op_i32_xor: u8 = 0x73;
const op_i32_shl: u8 = 0x74;
const op_i32_shr_s: u8 = 0x75;
const op_i32_shr_u: u8 = 0x76;
const op_i32_rotl: u8 = 0x77;
const op_i32_rotr: u8 = 0x78;
const op_i64_eqz: u8 = 0x50;
const op_i64_eq: u8 = 0x51;
const op_i64_ne: u8 = 0x52;
const op_i64_lt_s: u8 = 0x53;
const op_i64_lt_u: u8 = 0x54;
const op_i64_gt_s: u8 = 0x55;
const op_i64_gt_u: u8 = 0x56;
const op_i64_le_s: u8 = 0x57;
const op_i64_le_u: u8 = 0x58;
const op_i64_ge_s: u8 = 0x59;
const op_i64_ge_u: u8 = 0x5a;
const op_i64_add: u8 = 0x7c;
const op_i64_sub: u8 = 0x7d;
const op_i64_mul: u8 = 0x7e;
const op_i64_div_s: u8 = 0x7f;
const op_i64_div_u: u8 = 0x80;
const op_i64_rem_s: u8 = 0x81;
const op_i64_rem_u: u8 = 0x82;
const op_i64_and: u8 = 0x83;
const op_i64_or: u8 = 0x84;
const op_i64_xor: u8 = 0x85;
const op_i64_shl: u8 = 0x86;
const op_i64_shr_s: u8 = 0x87;
const op_i64_shr_u: u8 = 0x88;
const op_i64_rotl: u8 = 0x89;
const op_i64_rotr: u8 = 0x8a;
const op_i32_wrap_i64: u8 = 0xa7;
const op_i64_extend_i32_s: u8 = 0xac;
const op_i64_extend_i32_u: u8 = 0xad;
const op_misc_prefix: u8 = 0xfc;

const Loc = union(enum) {
    const_i32: i32,
    const_i64: i64,
    runtime,
};

const Ctrl = struct {
    label: x64.Masm.Label = .{},
    else_label: x64.Masm.Label = .{},
    height: usize,
    branch_arity: u32,
    result_arity: u32,
    kind: Kind,

    const Kind = enum { block, loop, if_then, if_else };
};

const max_ctrl_depth = 64;

/// Install the SysV half of Spasm's stable call gate. Generated callers pass
/// the gate as a private ninth argument; the hot path tail-jumps to its current
/// EntryFn, while the cold path tail-jumps to the existing checked resolver.
pub fn compileCallGateStub(
    gpa: std.mem.Allocator,
    ca: *code_alloc.CodeAllocator,
    slow_helper: usize,
    gate_entry_offset: i32,
) Error!?[]const u8 {
    var m = x64.Masm.init(gpa);
    defer m.deinit();
    var cold: x64.Masm.Label = .{};
    defer cold.deinit(gpa);

    try m.load64Disp32(.r10, .rsp, 24); // private ninth argument: CallGate*
    try m.load64Disp32(.r11, .r10, gate_entry_offset);
    try m.testReg64(.r11, .r11);
    try m.jumpCond(.equal, &cold);
    try m.jumpReg(.r11);

    try m.bind(&cold);
    // Slow helper ABI: rdi already carries the Cell buffer.
    try m.movReg64(.rsi, .r10);
    try m.load64Disp32(.rdx, .rsp, 16); // EntryFn execution controller
    try m.movImm64(.r11, slow_helper);
    try m.jumpReg(.r11);

    return m.install(ca) catch null;
}

/// Compile the x86_64 scalar/control core, returning null for every body
/// outside this backend's current surface. The ordinary wake-flag load is
/// acquire under TSO, matching the AArch64 backend's LDARB contract.
pub fn compile(
    gpa: std.mem.Allocator,
    ca: *code_alloc.CodeAllocator,
    func: *const CompiledFunc,
    ftype: *const FuncType,
    module: *const Module,
    funcs: []const CompiledFunc,
    function_index: u32,
    config: Config,
) Error!?[]const u8 {
    if (config.diagnostics) |diagnostics| diagnostics.* = .{};
    if (func.max_stack > operand_stack_capacity) return refuse(config, .limits, 0);
    const num_locals = func.local_types.len;
    const highest_slot = std.math.add(usize, num_locals, operand_stack_capacity) catch return refuse(config, .limits, 0);
    if (highest_slot > @as(usize, std.math.maxInt(i32)) / 16) return refuse(config, .limits, 0);

    // Integer Cells share the same low-64-bit representation at this boundary.
    // Float, vector, and reference signatures stay transactional refusals.
    for (func.local_types) |local_type| if (!isIntegerScalar(local_type)) return refuse(config, .signature, 0);
    for (ftype.params) |param_type| if (!isIntegerScalar(param_type)) return refuse(config, .signature, 0);
    for (ftype.results) |result_type| if (!isIntegerScalar(result_type)) return refuse(config, .signature, 0);

    var m = x64.Masm.init(gpa);
    defer m.deinit();

    var entry: x64.Masm.Label = .{};
    var epilogue: x64.Masm.Label = .{};
    var trap_div0: x64.Masm.Label = .{};
    var trap_overflow: x64.Masm.Label = .{};
    var trap_oob: x64.Masm.Label = .{};
    var trap_stack_exhausted: x64.Masm.Label = .{};
    defer entry.deinit(gpa);
    defer epilogue.deinit(gpa);
    defer trap_div0.deinit(gpa);
    defer trap_overflow.deinit(gpa);
    defer trap_oob.deinit(gpa);
    defer trap_stack_exhausted.deinit(gpa);
    var trap_div0_used = false;
    var trap_overflow_used = false;
    var trap_oob_used = false;
    var trap_stack_exhausted_used = false;

    try m.bind(&entry);
    try emitPrologue(&m);
    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);

    var stack: [operand_stack_capacity]Loc = undefined;
    var sp: usize = 0;
    var ctrl: [max_ctrl_depth]Ctrl = undefined;
    var ctrl_len: usize = 0;
    defer for (ctrl[0..ctrl_len]) |*c| {
        c.label.deinit(gpa);
        c.else_label.deinit(gpa);
    };

    const body = func.body;
    var i: usize = 0;
    var function_ended = false;
    body_loop: while (i < body.len) {
        const op = body[i];
        i += 1;
        if (config.diagnostics) |diagnostics| {
            diagnostics.stage = .bytecode;
            diagnostics.opcode = op;
            diagnostics.has_opcode = true;
        }
        switch (op) {
            op_nop => {},
            op_i32_const => {
                const value = readSleb32(body, &i) orelse return null;
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .{ .const_i32 = value };
                sp += 1;
            },
            op_i64_const => {
                const value = readSleb64(body, &i) orelse return null;
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .{ .const_i64 = value };
                sp += 1;
            },
            op_drop => {
                if (sp == 0) return null;
                sp -= 1;
            },
            op_call => {
                const callee_index = readUleb32(body, &i) orelse return null;
                const callee = calleeFuncType(module, callee_index) orelse return null;
                for (callee.params) |param_type| if (!isIntegerScalar(param_type)) return null;
                for (callee.results) |result_type| if (!isIntegerScalar(result_type)) return null;

                const param_count = callee.params.len;
                const result_count = callee.results.len;
                const refresh_memory = memoryIs64(module, 0) != null;
                if (refresh_memory and config.mem_view_helper == null) return null;
                if (sp < param_count) return null;
                const below = sp - param_count;
                if (below + result_count > operand_stack_capacity) return null;
                const direct_self = callee_index == function_index and func.local_types.len == ftype.params.len;
                const base_capacity = @max(param_count, result_count);
                const defined_callee = definedCallee(module, funcs, callee_index);
                const buffer_capacity = if (defined_callee) |defined| defined.frame_cells else base_capacity;
                const call_frame_bytes = callFrameBytes(buffer_capacity) orelse return null;
                const gate_address = if (!direct_self and defined_callee != null)
                    callGateAddress(config, defined_callee.?)
                else
                    null;
                if (!direct_self and gate_address == null and config.call_helper == null) return null;

                var param_index: usize = 0;
                while (param_index < param_count) : (param_index += 1) {
                    const depth = below + param_index;
                    try materialize(&m, stack[depth], num_locals, depth);
                }

                if (!(try emitCallStackGuard(&m, &trap_stack_exhausted, call_frame_bytes))) return null;
                trap_stack_exhausted_used = true;
                try m.load64Disp32(.r11, .rsp, entry_stack_limit_off);
                try m.subRegImm32(.rsp, call_frame_bytes);
                try m.store64Disp32(.rsp, 0, .r11);
                try m.store64Disp32(.rsp, 8, .rbx);

                param_index = 0;
                while (param_index < param_count) : (param_index += 1) {
                    const depth = below + param_index;
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    try m.store64Disp32(.rsp, callBufferOffset(param_index), .rax);
                    try m.movImm64(.rax, 0);
                    try m.store64Disp32(.rsp, callBufferOffset(param_index) + 8, .rax);
                }

                if (gate_address) |gate| {
                    const defined = defined_callee.?;
                    var local_index = defined.ftype.params.len;
                    while (local_index < defined.func.local_types.len) : (local_index += 1) {
                        try m.movImm64(.rax, 0);
                        try m.store64Disp32(.rsp, callBufferOffset(local_index), .rax);
                        try m.store64Disp32(.rsp, callBufferOffset(local_index) + 8, .rax);
                    }
                    try m.movImm64(.r11, gate);
                    try m.store64Disp32(.rsp, 16, .r11);
                    try m.leaDisp32(.rdi, .rsp, @intCast(call_stack_args_size));
                    try m.movReg64(.rsi, .rdi);
                    try m.movReg64(.rdx, .r14);
                    try m.movReg64(.rcx, .r15);
                    try m.movReg64(.r8, .rbp);
                    try m.load64Disp32(.r9, .rsp, @intCast(call_frame_bytes));
                    try m.movImm64(.r11, config.call_gate_stub.?);
                    try m.callReg(.r11);
                } else if (direct_self) {
                    try m.leaDisp32(.rdi, .rsp, @intCast(call_stack_args_size));
                    try m.movReg64(.rsi, .rdi);
                    try m.movReg64(.rdx, .r14);
                    try m.movReg64(.rcx, .r15);
                    try m.movReg64(.r8, .rbp);
                    try m.load64Disp32(.r9, .rsp, @intCast(call_frame_bytes));
                    try m.call(&entry);
                } else {
                    try m.load64Disp32(.rdi, .rsp, @intCast(call_frame_bytes));
                    try m.movImm64(.rsi, callee_index);
                    try m.leaDisp32(.rdx, .rsp, @intCast(call_stack_args_size));
                    try m.movImm64(.rcx, buffer_capacity);
                    try m.movReg64(.r8, .rbx);
                    try m.movImm64(.r11, config.call_helper.?);
                    try m.callReg(.r11);
                }
                try m.cmpReg32Imm32(.rax, 0);
                var call_ok: x64.Masm.Label = .{};
                defer call_ok.deinit(gpa);
                try m.jumpCond(.equal, &call_ok);
                try m.addRegImm32(.rsp, call_frame_bytes);
                try m.jump(&epilogue);
                try m.bind(&call_ok);

                if (refresh_memory) {
                    // Any callee may grow a memory shared with this instance.
                    // Reuse the dead outgoing stack-argument slots as the
                    // helper's [base,len] out-region before touching memory
                    // again; the instance pointer lives in the parent frame.
                    try m.load64Disp32(.rdi, .rsp, @intCast(call_frame_bytes));
                    try m.movImm64(.rsi, 0);
                    try m.leaDisp32(.rdx, .rsp, 16);
                    try m.movImm64(.r11, config.mem_view_helper.?);
                    try m.callReg(.r11);
                    try m.load64Disp32(.r14, .rsp, 16);
                    try m.load64Disp32(.r15, .rsp, 24);
                }

                var result_index: usize = 0;
                while (result_index < result_count) : (result_index += 1) {
                    try m.load64Disp32(.rax, .rsp, callBufferOffset(result_index));
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + result_index), .rax);
                    stack[below + result_index] = .runtime;
                }
                try m.addRegImm32(.rsp, call_frame_bytes);
                sp = below + result_count;
            },
            op_local_get => {
                const index = readUleb32(body, &i) orelse return null;
                if (index >= num_locals or sp >= operand_stack_capacity) return null;
                switch (func.local_types[index]) {
                    .i32 => try m.load32Disp32(.rax, .r12, localOffset(index)),
                    .i64 => try m.load64Disp32(.rax, .r12, localOffset(index)),
                    else => return null,
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                stack[sp] = .runtime;
                sp += 1;
            },
            op_local_set, op_local_tee => {
                const index = readUleb32(body, &i) orelse return null;
                if (index >= num_locals or sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                try m.store64Disp32(.r12, localOffset(index), .rax);
                if (op == op_local_set) {
                    sp -= 1;
                } else {
                    stack[depth] = .runtime;
                }
            },
            op_global_get => {
                // §4.4.5: rbp is the global-index-space array of `*Global`;
                // the scalar payload starts at offset zero in each Global.
                const index = readUleb32(body, &i) orelse return null;
                const global_type = globalValType(module, index) orelse return null;
                if (!isIntegerScalar(global_type) or sp >= operand_stack_capacity) return null;
                const pointer_offset = std.math.mul(u32, index, 8) catch return null;
                if (pointer_offset > std.math.maxInt(i32)) return null;
                try m.load64Disp32(.r10, .rbp, @intCast(pointer_offset));
                if (global_type == .i32)
                    try m.load32Disp32(.rax, .r10, 0)
                else
                    try m.load64Disp32(.rax, .r10, 0);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                stack[sp] = .runtime;
                sp += 1;
            },
            op_global_set => {
                // §4.4.6: validation already established mutability and type
                // agreement. Keep the pointer and payload in separate scratch
                // registers so a folded constant cannot clobber either.
                const index = readUleb32(body, &i) orelse return null;
                const global_type = globalValType(module, index) orelse return null;
                if (!isIntegerScalar(global_type) or sp == 0) return null;
                const pointer_offset = std.math.mul(u32, index, 8) catch return null;
                if (pointer_offset > std.math.maxInt(i32)) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                try m.load64Disp32(.r10, .rbp, @intCast(pointer_offset));
                try m.store64Disp32(.r10, 0, .rax);
                sp -= 1;
            },
            op_i32_eqz => {
                if (sp == 0) return null;
                const depth = sp - 1;
                switch (stack[depth]) {
                    .const_i32 => |value| stack[depth] = .{ .const_i32 = @intFromBool(value == 0) },
                    .const_i64 => return null,
                    .runtime => {
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.cmpRegImm32(.rax, 0);
                        try m.setCond32(.rax, .equal);
                        try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                    },
                }
            },
            op_i32_eq,
            op_i32_ne,
            op_i32_lt_s,
            op_i32_lt_u,
            op_i32_gt_s,
            op_i32_gt_u,
            op_i32_le_s,
            op_i32_le_u,
            op_i32_ge_s,
            op_i32_ge_u,
            => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                if (left == .const_i32 and right == .const_i32) {
                    const a = left.const_i32;
                    const b = right.const_i32;
                    const au: u32 = @bitCast(a);
                    const bu: u32 = @bitCast(b);
                    stack[sp - 1] = .{ .const_i32 = @intFromBool(switch (op) {
                        op_i32_eq => a == b,
                        op_i32_ne => a != b,
                        op_i32_lt_s => a < b,
                        op_i32_lt_u => au < bu,
                        op_i32_gt_s => a > b,
                        op_i32_gt_u => au > bu,
                        op_i32_le_s => a <= b,
                        op_i32_le_u => au <= bu,
                        op_i32_ge_s => a >= b,
                        else => au >= bu,
                    }) };
                    continue;
                }
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                try m.cmpReg32(.rax, .rcx);
                try m.setCond32(.rax, compareCondition(op));
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i32_add, op_i32_sub, op_i32_mul, op_i32_and, op_i32_or, op_i32_xor => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                if (left == .const_i32 and right == .const_i32) {
                    const a = left.const_i32;
                    const b = right.const_i32;
                    stack[sp - 1] = .{ .const_i32 = switch (op) {
                        op_i32_add => a +% b,
                        op_i32_sub => a -% b,
                        op_i32_mul => a *% b,
                        op_i32_and => a & b,
                        op_i32_or => a | b,
                        else => a ^ b,
                    } };
                    continue;
                }
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                switch (op) {
                    op_i32_add => try m.addReg32(.rax, .rcx),
                    op_i32_sub => try m.subReg32(.rax, .rcx),
                    op_i32_mul => try m.imulReg32(.rax, .rcx),
                    op_i32_and => try m.andReg32(.rax, .rcx),
                    op_i32_or => try m.orReg32(.rax, .rcx),
                    else => try m.xorReg32(.rax, .rcx),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i32_shl, op_i32_shr_s, op_i32_shr_u, op_i32_rotl, op_i32_rotr => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                // x86 masks CL to five bits for 32-bit shifts and rotates,
                // exactly Wasm's count modulo 32 semantics (§4.3.2).
                switch (op) {
                    op_i32_shl => try m.shlReg32Cl(.rax),
                    op_i32_shr_s => try m.sarReg32Cl(.rax),
                    op_i32_shr_u => try m.shrReg32Cl(.rax),
                    op_i32_rotl => try m.rolReg32Cl(.rax),
                    else => try m.rorReg32Cl(.rax),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i32_div_s, op_i32_div_u, op_i32_rem_s, op_i32_rem_u => {
                if (sp < 2) return null;
                const divisor = stack[sp - 1];
                const dividend = stack[sp - 2];
                sp -= 1;
                try materialize(&m, dividend, num_locals, sp - 1);
                try materialize(&m, divisor, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));

                try m.cmpReg32Imm32(.rcx, 0);
                try m.jumpCond(.equal, &trap_div0);
                trap_div0_used = true;

                if (op == op_i32_div_s or op == op_i32_rem_s) {
                    var ordinary: x64.Masm.Label = .{};
                    var done: x64.Masm.Label = .{};
                    defer ordinary.deinit(gpa);
                    defer done.deinit(gpa);

                    try m.cmpReg32Imm32(.rcx, 0xffff_ffff);
                    try m.jumpCond(.not_equal, &ordinary);
                    try m.cmpReg32Imm32(.rax, 0x8000_0000);
                    try m.jumpCond(.not_equal, &ordinary);
                    if (op == op_i32_div_s) {
                        try m.jump(&trap_overflow);
                        trap_overflow_used = true;
                    } else {
                        try m.movImm64(.rax, 0);
                        try m.jump(&done);
                    }

                    try m.bind(&ordinary);
                    try m.signExtendAccumulator32();
                    try m.idivReg32(.rcx);
                    if (op == op_i32_rem_s) try m.movReg32(.rax, .rdx);
                    try m.bind(&done);
                } else {
                    try m.xorReg32(.rdx, .rdx);
                    try m.divReg32(.rcx);
                    if (op == op_i32_rem_u) try m.movReg32(.rax, .rdx);
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i64_eqz => {
                if (sp == 0) return null;
                const depth = sp - 1;
                switch (stack[depth]) {
                    .const_i64 => |value| stack[depth] = .{ .const_i32 = @intFromBool(value == 0) },
                    else => {
                        try materialize(&m, stack[depth], num_locals, depth);
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.cmpRegImm32(.rax, 0);
                        try m.setCond32(.rax, .equal);
                        try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                        stack[depth] = .runtime;
                    },
                }
            },
            op_i64_eq,
            op_i64_ne,
            op_i64_lt_s,
            op_i64_lt_u,
            op_i64_gt_s,
            op_i64_gt_u,
            op_i64_le_s,
            op_i64_le_u,
            op_i64_ge_s,
            op_i64_ge_u,
            => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                if (left == .const_i64 and right == .const_i64) {
                    const a = left.const_i64;
                    const b = right.const_i64;
                    const au: u64 = @bitCast(a);
                    const bu: u64 = @bitCast(b);
                    stack[sp - 1] = .{ .const_i32 = @intFromBool(switch (op) {
                        op_i64_eq => a == b,
                        op_i64_ne => a != b,
                        op_i64_lt_s => a < b,
                        op_i64_lt_u => au < bu,
                        op_i64_gt_s => a > b,
                        op_i64_gt_u => au > bu,
                        op_i64_le_s => a <= b,
                        op_i64_le_u => au <= bu,
                        op_i64_ge_s => a >= b,
                        else => au >= bu,
                    }) };
                    continue;
                }
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                try m.cmpReg64(.rax, .rcx);
                try m.setCond32(.rax, compareCondition64(op));
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i64_add, op_i64_sub, op_i64_mul, op_i64_and, op_i64_or, op_i64_xor => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                if (left == .const_i64 and right == .const_i64) {
                    const a = left.const_i64;
                    const b = right.const_i64;
                    stack[sp - 1] = .{ .const_i64 = switch (op) {
                        op_i64_add => a +% b,
                        op_i64_sub => a -% b,
                        op_i64_mul => a *% b,
                        op_i64_and => a & b,
                        op_i64_or => a | b,
                        else => a ^ b,
                    } };
                    continue;
                }
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                switch (op) {
                    op_i64_add => try m.addReg64(.rax, .rcx),
                    op_i64_sub => try m.subReg64(.rax, .rcx),
                    op_i64_mul => try m.imulReg64(.rax, .rcx),
                    op_i64_and => try m.andReg64(.rax, .rcx),
                    op_i64_or => try m.orReg64(.rax, .rcx),
                    else => try m.xorReg64(.rax, .rcx),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i64_shl, op_i64_shr_s, op_i64_shr_u, op_i64_rotl, op_i64_rotr => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                // The architectural six-bit mask on CL is Wasm's modulo-64
                // shift/rotate count, with no explicit mask instruction.
                switch (op) {
                    op_i64_shl => try m.shlReg64Cl(.rax),
                    op_i64_shr_s => try m.sarReg64Cl(.rax),
                    op_i64_shr_u => try m.shrReg64Cl(.rax),
                    op_i64_rotl => try m.rolReg64Cl(.rax),
                    else => try m.rorReg64Cl(.rax),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i64_div_s, op_i64_div_u, op_i64_rem_s, op_i64_rem_u => {
                if (sp < 2) return null;
                const divisor = stack[sp - 1];
                const dividend = stack[sp - 2];
                sp -= 1;
                try materialize(&m, dividend, num_locals, sp - 1);
                try materialize(&m, divisor, num_locals, sp);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                try m.cmpRegImm32(.rcx, 0);
                try m.jumpCond(.equal, &trap_div0);
                trap_div0_used = true;

                if (op == op_i64_div_s or op == op_i64_rem_s) {
                    var ordinary: x64.Masm.Label = .{};
                    var done: x64.Masm.Label = .{};
                    defer ordinary.deinit(gpa);
                    defer done.deinit(gpa);
                    try m.cmpRegImm32(.rcx, 0xffff_ffff); // sign-extended -1
                    try m.jumpCond(.not_equal, &ordinary);
                    try m.movImm64(.r10, 0x8000_0000_0000_0000);
                    try m.cmpReg64(.rax, .r10);
                    try m.jumpCond(.not_equal, &ordinary);
                    if (op == op_i64_div_s) {
                        try m.jump(&trap_overflow);
                        trap_overflow_used = true;
                    } else {
                        try m.movImm64(.rax, 0);
                        try m.jump(&done);
                    }
                    try m.bind(&ordinary);
                    try m.signExtendAccumulator64();
                    try m.idivReg64(.rcx);
                    if (op == op_i64_rem_s) try m.movReg64(.rax, .rdx);
                    try m.bind(&done);
                } else {
                    try m.xorReg64(.rdx, .rdx);
                    try m.divReg64(.rcx);
                    if (op == op_i64_rem_u) try m.movReg64(.rax, .rdx);
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i32_wrap_i64, op_i64_extend_i32_s, op_i64_extend_i32_u => {
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                if (op == op_i64_extend_i32_s) try m.signExtendReg32To64(.rax, .rax);
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_i32_load,
            op_i32_load8_s,
            op_i32_load8_u,
            op_i32_load16_s,
            op_i32_load16_u,
            op_i64_load,
            op_i64_load8_s,
            op_i64_load8_u,
            op_i64_load16_s,
            op_i64_load16_u,
            op_i64_load32_s,
            op_i64_load32_u,
            => {
                const offset = readMemArg(body, &i) orelse return null;
                if (memoryIs64(module, 0) != false or sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load32Disp32(.r10, .r12, scratchOffset(num_locals, depth));
                const width: u32 = switch (op) {
                    op_i32_load8_s, op_i32_load8_u, op_i64_load8_s, op_i64_load8_u => 1,
                    op_i32_load16_s, op_i32_load16_u, op_i64_load16_s, op_i64_load16_u => 2,
                    op_i32_load, op_i64_load32_s, op_i64_load32_u => 4,
                    else => 8,
                };
                try emitMemAddress(&m, offset, width, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i32_load => try m.load32Disp32(.rax, .r11, 0),
                    op_i32_load8_s => try m.load8Signed32Disp32(.rax, .r11, 0),
                    op_i32_load8_u => try m.load8Disp32(.rax, .r11, 0),
                    op_i32_load16_s => try m.load16Signed32Disp32(.rax, .r11, 0),
                    op_i32_load16_u => try m.load16Disp32(.rax, .r11, 0),
                    op_i64_load => try m.load64Disp32(.rax, .r11, 0),
                    op_i64_load8_s => try m.load8Signed64Disp32(.rax, .r11, 0),
                    op_i64_load8_u => try m.load8Disp32(.rax, .r11, 0),
                    op_i64_load16_s => try m.load16Signed64Disp32(.rax, .r11, 0),
                    op_i64_load16_u => try m.load16Disp32(.rax, .r11, 0),
                    op_i64_load32_s => try m.load32Signed64Disp32(.rax, .r11, 0),
                    else => try m.load32Disp32(.rax, .r11, 0),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_i32_store,
            op_i32_store8,
            op_i32_store16,
            op_i64_store,
            op_i64_store8,
            op_i64_store16,
            op_i64_store32,
            => {
                const offset = readMemArg(body, &i) orelse return null;
                if (memoryIs64(module, 0) != false or sp < 2) return null;
                const addr_depth = sp - 2;
                const value_depth = sp - 1;
                try materialize(&m, stack[addr_depth], num_locals, addr_depth);
                try materialize(&m, stack[value_depth], num_locals, value_depth);
                try m.load32Disp32(.r10, .r12, scratchOffset(num_locals, addr_depth));
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, value_depth));
                const width: u32 = switch (op) {
                    op_i32_store8, op_i64_store8 => 1,
                    op_i32_store16, op_i64_store16 => 2,
                    op_i32_store, op_i64_store32 => 4,
                    else => 8,
                };
                try emitMemAddress(&m, offset, width, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i32_store8, op_i64_store8 => try m.store8Disp32(.r11, 0, .rax),
                    op_i32_store16, op_i64_store16 => try m.store16Disp32(.r11, 0, .rax),
                    op_i32_store, op_i64_store32 => try m.store32Disp32(.r11, 0, .rax),
                    else => try m.store64Disp32(.r11, 0, .rax),
                }
                sp -= 2;
            },
            op_memory_size => {
                const memory_index = readUleb32(body, &i) orelse return null;
                if (memory_index != 0 or memoryIs64(module, memory_index) == null or sp >= operand_stack_capacity) return null;
                try m.movReg64(.rax, .r15);
                try m.shrImm8(.rax, 16);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                stack[sp] = .runtime;
                sp += 1;
            },
            op_memory_grow => {
                const memory_index = readUleb32(body, &i) orelse return null;
                if (memory_index != 0 or memoryIs64(module, memory_index) != false or config.mem_grow_helper == null or sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rdi, .rsp, 0); // Instance*, before rsp moves
                try m.movImm64(.rsi, memory_index);
                try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, depth));
                // A 16-byte out-region keeps the helper call aligned. The
                // helper always writes the live base/length, on success or
                // failure, so the cached callee-saved pair is refreshed.
                try m.subRegImm32(.rsp, 16);
                try m.movReg64(.rcx, .rsp);
                try m.movImm64(.r11, config.mem_grow_helper.?);
                try m.callReg(.r11);
                try m.load64Disp32(.r14, .rsp, 0);
                try m.load64Disp32(.r15, .rsp, 8);
                try m.addRegImm32(.rsp, 16);
                try m.movReg32(.rax, .rax);
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_misc_prefix => {
                const sub = readUleb32(body, &i) orelse return null;
                if (sub == 11) {
                    const memory_index = readUleb32(body, &i) orelse return null;
                    if (memory_index != 0 or memoryIs64(module, memory_index) != false or sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, below)); // dst
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1)); // value
                    try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2)); // count
                    try emitRangeBounds(&m, .rax, .rdx, &trap_oob);
                    trap_oob_used = true;
                    try m.movReg64(.r11, .r14);
                    try m.addReg64(.r11, .rax);
                    var fill_loop: x64.Masm.Label = .{};
                    var fill_done: x64.Masm.Label = .{};
                    defer fill_loop.deinit(gpa);
                    defer fill_done.deinit(gpa);
                    try m.bind(&fill_loop);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &fill_done);
                    try m.store8Disp32(.r11, 0, .rcx);
                    try m.addRegImm32(.r11, 1);
                    try m.subRegImm32(.rdx, 1);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &fill_done);
                    var fill_continue: x64.Masm.Label = .{};
                    defer fill_continue.deinit(gpa);
                    try m.testReg32Imm32(.rdx, 0x0fff);
                    try m.jumpCond(.not_equal, &fill_continue);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below), .r11);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 1), .rcx);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 2), .rdx);
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                    try m.load64Disp32(.r11, .r12, scratchOffset(num_locals, below));
                    try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1));
                    try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2));
                    try m.bind(&fill_continue);
                    try m.jump(&fill_loop);
                    try m.bind(&fill_done);
                    sp = below;
                } else if (sub == 10) {
                    const destination_memory = readUleb32(body, &i) orelse return null;
                    const source_memory = readUleb32(body, &i) orelse return null;
                    if (destination_memory != 0 or source_memory != 0 or memoryIs64(module, 0) != false or sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, below)); // dst
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1)); // src
                    try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2)); // count
                    try emitRangeBounds(&m, .rcx, .rdx, &trap_oob);
                    try emitRangeBounds(&m, .rax, .rdx, &trap_oob);
                    trap_oob_used = true;
                    try m.movReg64(.r8, .r14);
                    try m.addReg64(.r8, .rax);
                    try m.movReg64(.r9, .r14);
                    try m.addReg64(.r9, .rcx);
                    var forward: x64.Masm.Label = .{};
                    var forward_loop: x64.Masm.Label = .{};
                    var backward_loop: x64.Masm.Label = .{};
                    var copy_done: x64.Masm.Label = .{};
                    defer forward.deinit(gpa);
                    defer forward_loop.deinit(gpa);
                    defer backward_loop.deinit(gpa);
                    defer copy_done.deinit(gpa);
                    try m.cmpReg64(.rax, .rcx);
                    try m.jumpCond(.below_or_equal, &forward);
                    try m.addReg64(.r8, .rdx);
                    try m.addReg64(.r9, .rdx);
                    try m.bind(&backward_loop);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &copy_done);
                    try m.subRegImm32(.r8, 1);
                    try m.subRegImm32(.r9, 1);
                    try m.load8Disp32(.r11, .r9, 0);
                    try m.store8Disp32(.r8, 0, .r11);
                    try m.subRegImm32(.rdx, 1);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &copy_done);
                    var backward_continue: x64.Masm.Label = .{};
                    defer backward_continue.deinit(gpa);
                    try m.testReg32Imm32(.rdx, 0x0fff);
                    try m.jumpCond(.not_equal, &backward_continue);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below), .r8);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 1), .r9);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 2), .rdx);
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                    try m.load64Disp32(.r8, .r12, scratchOffset(num_locals, below));
                    try m.load64Disp32(.r9, .r12, scratchOffset(num_locals, below + 1));
                    try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2));
                    try m.bind(&backward_continue);
                    try m.jump(&backward_loop);
                    try m.bind(&forward);
                    try m.bind(&forward_loop);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &copy_done);
                    try m.load8Disp32(.r11, .r9, 0);
                    try m.store8Disp32(.r8, 0, .r11);
                    try m.addRegImm32(.r8, 1);
                    try m.addRegImm32(.r9, 1);
                    try m.subRegImm32(.rdx, 1);
                    try m.cmpRegImm32(.rdx, 0);
                    try m.jumpCond(.equal, &copy_done);
                    var forward_continue: x64.Masm.Label = .{};
                    defer forward_continue.deinit(gpa);
                    try m.testReg32Imm32(.rdx, 0x0fff);
                    try m.jumpCond(.not_equal, &forward_continue);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below), .r8);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 1), .r9);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 2), .rdx);
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                    try m.load64Disp32(.r8, .r12, scratchOffset(num_locals, below));
                    try m.load64Disp32(.r9, .r12, scratchOffset(num_locals, below + 1));
                    try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2));
                    try m.bind(&forward_continue);
                    try m.jump(&forward_loop);
                    try m.bind(&copy_done);
                    sp = below;
                } else {
                    return refuse(config, .unsupported_opcode, op_misc_prefix);
                }
            },
            op_block => {
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = arity, .result_arity = arity, .kind = .block };
                ctrl_len += 1;
            },
            op_loop => {
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = 0, .result_arity = arity, .kind = .loop };
                try m.bind(&ctrl[ctrl_len].label);
                ctrl_len += 1;
            },
            op_if => {
                if (sp == 0) return null;
                sp -= 1;
                const condition = stack[sp];
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                try materialize(&m, condition, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp));
                try m.cmpRegImm32(.rax, 0);
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = arity, .result_arity = arity, .kind = .if_then };
                try m.jumpCond(.equal, &ctrl[ctrl_len].else_label);
                ctrl_len += 1;
            },
            op_else => {
                if (ctrl_len == 0) return null;
                const current = &ctrl[ctrl_len - 1];
                if (current.kind != .if_then or sp != current.height + current.result_arity) return null;
                if (!(try materializeRange(&m, stack[0..], num_locals, current.height, current.result_arity))) return null;
                try m.jump(&current.label);
                try m.bind(&current.else_label);
                current.kind = .if_else;
                sp = current.height;
            },
            op_br => {
                const depth = readUleb32(body, &i) orelse return null;
                if (depth >= ctrl_len) return null;
                const target = &ctrl[ctrl_len - 1 - depth];
                if (sp != target.height + target.branch_arity) return null;
                if (!(try materializeRange(&m, stack[0..], num_locals, target.height, target.branch_arity))) return null;
                if (target.kind == .loop) {
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                }
                try m.jump(&target.label);

                // The first x86 slice accepts an unconditional terminator only
                // when it is immediately followed by the current frame's end.
                // This covers canonical loop backedges without duplicating the
                // mature AArch64 dead-code skipper.
                if (ctrl_len == 0 or i >= body.len or body[i] != op_end) return null;
                i += 1;
                const current = &ctrl[ctrl_len - 1];
                if (current.kind == .if_then or current.kind == .if_else) return null;
                if (current.kind == .block) try m.bind(&current.label);
                current.label.deinit(gpa);
                current.else_label.deinit(gpa);
                sp = current.height + current.result_arity;
                var result_depth = current.height;
                while (result_depth < sp) : (result_depth += 1) stack[result_depth] = .runtime;
                ctrl_len -= 1;
            },
            op_br_if => {
                const depth = readUleb32(body, &i) orelse return null;
                if (sp == 0 or depth >= ctrl_len) return null;
                sp -= 1;
                const condition = stack[sp];
                const target = &ctrl[ctrl_len - 1 - depth];
                if (sp != target.height + target.branch_arity) return null;
                if (!(try materializeRange(&m, stack[0..], num_locals, target.height, target.branch_arity))) return null;
                try materialize(&m, condition, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp));
                try m.cmpRegImm32(.rax, 0);
                if (target.kind == .loop) {
                    var not_taken: x64.Masm.Label = .{};
                    defer not_taken.deinit(gpa);
                    try m.jumpCond(.equal, &not_taken);
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                    try m.jump(&target.label);
                    try m.bind(&not_taken);
                } else {
                    try m.jumpCond(.not_equal, &target.label);
                }
            },
            op_end => {
                if (ctrl_len == 0) {
                    function_ended = true;
                    break :body_loop;
                }
                ctrl_len -= 1;
                const current = &ctrl[ctrl_len];
                if (sp != current.height + current.result_arity) return null;
                if (!(try materializeRange(&m, stack[0..], num_locals, current.height, current.result_arity))) return null;
                switch (current.kind) {
                    .block, .if_else => try m.bind(&current.label),
                    .loop => {},
                    .if_then => {
                        try m.bind(&current.label);
                        try m.bind(&current.else_label);
                    },
                }
                current.label.deinit(gpa);
                current.else_label.deinit(gpa);
            },
            else => return refuse(config, .unsupported_opcode, op),
        }
    }

    if (!function_ended or ctrl_len != 0 or sp != ftype.results.len) return null;
    for (ftype.results, 0..) |_, result_index| {
        try materialize(&m, stack[result_index], num_locals, result_index);
        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, result_index));
        try m.store64Disp32(.r13, resultOffset(result_index), .rax);
        try m.movImm64(.rcx, 0);
        try m.store64Disp32(.r13, resultOffset(result_index) + 8, .rcx);
    }

    try m.movImm64(.rax, 0);
    try m.jump(&epilogue);
    if (trap_div0_used) {
        try m.bind(&trap_div0);
        try m.movImm64(.rax, config.trap_divide_by_zero);
        try m.jump(&epilogue);
    }
    if (trap_overflow_used) {
        try m.bind(&trap_overflow);
        try m.movImm64(.rax, config.trap_int_overflow);
        try m.jump(&epilogue);
    }
    if (trap_oob_used) {
        try m.bind(&trap_oob);
        try m.movImm64(.rax, config.trap_out_of_bounds);
        try m.jump(&epilogue);
    }
    if (trap_stack_exhausted_used) {
        try m.bind(&trap_stack_exhausted);
        try m.movImm64(.rax, config.trap_call_stack_exhausted);
        try m.jump(&epilogue);
    }
    try m.bind(&epilogue);
    try emitEpilogue(&m);

    const installed = m.install(ca) catch return refuse(config, .install, 0);
    if (config.diagnostics) |diagnostics| diagnostics.* = .{};
    return installed;
}

fn emitPrologue(m: *x64.Masm) Error!void {
    // SysV enters with rsp % 16 == 8. Reserving 56 bytes aligns every helper
    // call while leaving one outgoing stack-argument slot at [rsp+0].
    try m.subRegImm32(.rsp, frame_size);
    try m.store64Disp32(.rsp, saved_r12_off, .r12);
    try m.store64Disp32(.rsp, saved_r13_off, .r13);
    try m.store64Disp32(.rsp, saved_r14_off, .r14);
    try m.store64Disp32(.rsp, saved_r15_off, .r15);
    try m.store64Disp32(.rsp, saved_rbx_off, .rbx);
    try m.store64Disp32(.rsp, saved_rbp_off, .rbp);
    try m.movReg64(.r12, .rdi); // locals + operand scratch cells
    try m.movReg64(.r13, .rsi); // results
    try m.movReg64(.r14, .rdx); // memory base
    try m.movReg64(.r15, .rcx); // memory length
    try m.movReg64(.rbp, .r8); // globals base
    try m.store64Disp32(.rsp, 0, .r9); // instance for checked call helpers
    try m.load64Disp32(.rbx, .rsp, entry_execution_control_off);
}

fn emitEpilogue(m: *x64.Masm) Error!void {
    try m.load64Disp32(.r12, .rsp, saved_r12_off);
    try m.load64Disp32(.r13, .rsp, saved_r13_off);
    try m.load64Disp32(.r14, .rsp, saved_r14_off);
    try m.load64Disp32(.r15, .rsp, saved_r15_off);
    try m.load64Disp32(.rbx, .rsp, saved_rbx_off);
    try m.load64Disp32(.rbp, .rsp, saved_rbp_off);
    try m.addRegImm32(.rsp, frame_size);
    try m.ret();
}

fn emitExecutionPoll(
    m: *x64.Masm,
    epilogue: *x64.Masm.Label,
    poll_helper: usize,
    wake_flag_offset: i32,
) Error!void {
    var done: x64.Masm.Label = .{};
    defer done.deinit(m.gpa);

    try m.testReg64(.rbx, .rbx);
    try m.jumpCond(.equal, &done);
    try m.load64Disp32(.r11, .rbx, wake_flag_offset);
    try m.load8Disp32(.rax, .r11, 0);
    try m.cmpReg32Imm32(.rax, 0);
    try m.jumpCond(.equal, &done);

    try m.movReg64(.rdi, .rbx);
    try m.movImm64(.r11, poll_helper);
    try m.callReg(.r11);
    try m.cmpReg32Imm32(.rax, 0);
    try m.jumpCond(.not_equal, epilogue);
    try m.bind(&done);
}

fn materialize(m: *x64.Masm, loc: Loc, num_locals: usize, depth: usize) Error!void {
    switch (loc) {
        .runtime => {},
        .const_i32 => |value| {
            try m.movImm64(.rax, @as(u32, @bitCast(value)));
            try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
        },
        .const_i64 => |value| {
            try m.movImm64(.rax, @bitCast(value));
            try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
        },
    }
}

fn materializeRange(
    m: *x64.Masm,
    stack: []Loc,
    num_locals: usize,
    start: usize,
    count: u32,
) Error!bool {
    if (start > stack.len) return false;
    var depth = start;
    const end = std.math.add(usize, start, count) catch return false;
    if (end > stack.len) return false;
    while (depth < end) : (depth += 1) {
        try materialize(m, stack[depth], num_locals, depth);
        stack[depth] = .runtime;
    }
    return true;
}

fn compareCondition(op: u8) x64.Cond {
    return switch (op) {
        op_i32_eq => .equal,
        op_i32_ne => .not_equal,
        op_i32_lt_s => .less,
        op_i32_lt_u => .below,
        op_i32_gt_s => .greater,
        op_i32_gt_u => .above,
        op_i32_le_s => .less_or_equal,
        op_i32_le_u => .below_or_equal,
        op_i32_ge_s => .greater_or_equal,
        else => .above_or_equal,
    };
}

fn compareCondition64(op: u8) x64.Cond {
    return switch (op) {
        op_i64_eq => .equal,
        op_i64_ne => .not_equal,
        op_i64_lt_s => .less,
        op_i64_lt_u => .below,
        op_i64_gt_s => .greater,
        op_i64_gt_u => .above,
        op_i64_le_s => .less_or_equal,
        op_i64_le_u => .below_or_equal,
        op_i64_ge_s => .greater_or_equal,
        else => .above_or_equal,
    };
}

fn refuse(config: Config, stage: RefusalStage, opcode: u8) ?[]const u8 {
    if (config.diagnostics) |diagnostics| diagnostics.* = .{
        .stage = stage,
        .opcode = opcode,
        .has_opcode = stage == .bytecode or stage == .unsupported_opcode,
    };
    return null;
}

fn isIntegerScalar(value_type: ValType) bool {
    return value_type == .i32 or value_type == .i64;
}

/// Resolve the global index space (imports first, then definitions) without
/// borrowing interpreter state into the compiler.
fn globalValType(module: *const Module, index: u32) ?ValType {
    var seen: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .global) continue;
        if (seen == index) return import.desc.global.val;
        seen += 1;
    }
    if (index < seen) return null;
    const local: usize = index - seen;
    if (local >= module.globals.len) return null;
    return module.globals[local].type.val;
}

/// Resolve one memory's address width in the memory index space. This x86
/// increment emits memory32 accesses only; a memory64 body refuses before any
/// machine code is installed.
fn memoryIs64(module: *const Module, index: u32) ?bool {
    var seen: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .mem) continue;
        if (seen == index) return import.desc.mem.limits.is_64;
        seen += 1;
    }
    if (index < seen) return null;
    const local: usize = index - seen;
    if (local >= module.mems.len) return null;
    return module.mems[local].limits.is_64;
}

/// §4.4.7 effective address and explicit software bounds check. The address
/// arrives zero-extended from an i32 Cell, so adding the u32 static offset in
/// u64 cannot wrap. r10 enters as the dynamic address; r11 returns as the host
/// pointer. r9 is scratch. Host faults are never part of the trap contract.
fn emitMemAddress(
    m: *x64.Masm,
    offset: u32,
    width: u32,
    trap_oob: *x64.Masm.Label,
) Error!void {
    try m.movImm64(.r11, offset);
    try m.addReg64(.r10, .r11);
    try m.cmpReg64(.r10, .r15);
    try m.jumpCond(.above, trap_oob);
    try m.movReg64(.r9, .r15);
    try m.subReg64(.r9, .r10);
    try m.cmpRegImm32(.r9, width);
    try m.jumpCond(.below, trap_oob);
    try m.movReg64(.r11, .r14);
    try m.addReg64(.r11, .r10);
}

/// Bounds-check `[offset, offset + count)` without overflow by comparing the
/// count against `mem_len - offset` only after proving offset <= mem_len.
fn emitRangeBounds(
    m: *x64.Masm,
    offset: x64.Reg,
    count: x64.Reg,
    trap_oob: *x64.Masm.Label,
) Error!void {
    try m.cmpReg64(offset, .r15);
    try m.jumpCond(.above, trap_oob);
    try m.movReg64(.r10, .r15);
    try m.subReg64(.r10, offset);
    try m.cmpReg64(count, .r10);
    try m.jumpCond(.above, trap_oob);
}

fn localOffset(index: usize) i32 {
    return @intCast(index * 16);
}

fn scratchOffset(num_locals: usize, depth: usize) i32 {
    return @intCast((num_locals + depth) * 16);
}

fn resultOffset(index: usize) i32 {
    return @intCast(index * 16);
}

fn callBufferOffset(index: usize) i32 {
    return @intCast(call_stack_args_size + index * 16);
}

fn callFrameBytes(buffer_cells: usize) ?u32 {
    const buffer_bytes = std.math.mul(usize, buffer_cells, 16) catch return null;
    const total = std.math.add(usize, call_stack_args_size, buffer_bytes) catch return null;
    if (total > max_call_frame_bytes) return null;
    return @intCast(total);
}

fn emitCallStackGuard(
    m: *x64.Masm,
    trap: *x64.Masm.Label,
    call_frame_bytes: u32,
) Error!bool {
    const projected_bytes = std.math.add(u32, call_frame_bytes, native_entry_stack_bytes) catch
        return false;
    try m.leaDisp32(.r10, .rsp, -@as(i32, @intCast(projected_bytes)));
    try m.load64Disp32(.r11, .rsp, entry_stack_limit_off);
    try m.cmpReg64(.r10, .r11);
    try m.jumpCond(.below_or_equal, trap);
    return true;
}

fn calleeFuncType(module: *const Module, func_index: u32) ?*const FuncType {
    var seen: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .func) continue;
        if (seen == func_index) {
            const type_index = import.desc.func;
            if (type_index >= module.types.len) return null;
            return &module.types[type_index];
        }
        seen += 1;
    }
    if (func_index < seen) return null;
    const local_index: usize = func_index - seen;
    if (local_index >= module.funcs.len) return null;
    const type_index = module.funcs[local_index];
    if (type_index >= module.types.len) return null;
    return &module.types[type_index];
}

const DefinedCallee = struct {
    func: *const CompiledFunc,
    ftype: *const FuncType,
    local_index: usize,
    frame_cells: usize,
};

fn definedCallee(
    module: *const Module,
    funcs: []const CompiledFunc,
    func_index: u32,
) ?DefinedCallee {
    var imported_count: u32 = 0;
    for (module.imports) |import| {
        if (import.desc == .func) imported_count += 1;
    }
    if (func_index < imported_count) return null;
    const local_index: usize = @intCast(func_index - imported_count);
    if (local_index >= funcs.len) return null;
    const callee = &funcs[local_index];
    if (callee.type_index >= module.types.len) return null;
    const callee_type = &module.types[callee.type_index];
    const locals_and_scratch = std.math.add(usize, callee.local_types.len, operand_stack_capacity) catch return null;
    return .{
        .func = callee,
        .ftype = callee_type,
        .local_index = local_index,
        .frame_cells = @max(locals_and_scratch, callee_type.results.len),
    };
}

fn callGateAddress(config: Config, callee: DefinedCallee) ?usize {
    const stub = config.call_gate_stub orelse return null;
    _ = stub;
    const base = config.call_gates_base orelse return null;
    if (callee.local_index >= config.call_gates_len) return null;
    for (callee.func.local_types) |local_type| if (!isIntegerScalar(local_type)) return null;
    const offset = std.math.mul(usize, callee.local_index, config.call_gate_stride) catch return null;
    return std.math.add(usize, base, offset) catch null;
}

fn readBlockArity(body: []const u8, index: *usize) ?u32 {
    if (index.* >= body.len) return null;
    return switch (body[index.*]) {
        0x40 => blk: {
            index.* += 1;
            break :blk 0;
        },
        0x7f, 0x7e => blk: {
            index.* += 1;
            break :blk 1;
        },
        else => null,
    };
}

fn readUleb32(body: []const u8, index: *usize) ?u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (index.* < body.len) {
        const byte = body[index.*];
        index.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return std.math.cast(u32, result);
        shift += 7;
        if (shift >= 35) return null;
    }
    return null;
}

fn readSleb32(body: []const u8, index: *usize) ?i32 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (index.* < body.len) {
        const byte = body[index.*];
        index.* += 1;
        result |= @as(i64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if (shift < 63 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << (shift + 7);
            }
            if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return null;
            return @intCast(result);
        }
        shift += 7;
        if (shift >= 35) return null;
    }
    return null;
}

fn readSleb64(body: []const u8, index: *usize) ?i64 {
    var result: i64 = 0;
    var shift: u7 = 0;
    while (index.* < body.len) {
        const byte = body[index.*];
        index.* += 1;
        result |= @as(i64, byte & 0x7f) << @as(u6, @intCast(shift));
        if (byte & 0x80 == 0) {
            if (shift < 63 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << @as(u6, @intCast(shift + 7));
            }
            return result;
        }
        shift += 7;
        if (shift >= 70) return null;
    }
    return null;
}

fn readMemArg(body: []const u8, index: *usize) ?u32 {
    const flags = readUleb32(body, index) orelse return null;
    if (flags & 0x40 != 0) return null; // explicit memory index
    return readUleb32(body, index);
}
