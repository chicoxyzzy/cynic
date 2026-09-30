//! x86_64 Spasm backend.
//!
//! This backend keeps operands in the existing trailing
//! `Cell` scratch area rather than trying to project AArch64's seven-register
//! cache onto the smaller SysV register file. The validated-bytecode compiler
//! remains one pass, constants still fold, and unsupported instructions refuse
//! transactionally so Sarcasm remains the semantic fallback.

const std = @import("std");
const metadata = @import("spasm_metadata.zig");
const simd = @import("spasm_simd.zig");
const globalValType = metadata.globalValType;
const tableIs64 = metadata.tableIs64;
const memoryIs64 = metadata.memoryIs64;

const x64 = @import("../jit/asm_x86_64.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const float_ops = @import("float_ops.zig");
const dead_code = @import("spasm_dead_code.zig");
const CompiledFunc = @import("code.zig").CompiledFunc;
const Module = @import("module.zig").Module;
const FuncType = @import("types.zig").FuncType;
const ValType = @import("types.zig").ValType;
const Reader = @import("reader.zig").Reader;

pub const operand_stack_capacity = 7;

pub const Error = error{
    OutOfMemory,
    LabelAlreadyBound,
    InvalidLabel,
    BranchOutOfRange,
    UnsupportedOp,
};

/// Why one Spasm compilation attempt degraded to Sarcasm. The compiler
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
pub const misc_subopcode_count: usize = 18;

pub const Diagnostics = struct {
    stage: RefusalStage = .none,
    signature_type: ?ValType = null,
    opcode: u8 = 0,
    has_opcode: bool = false,
    subopcode: u32 = 0,
    has_subopcode: bool = false,
};

pub const Config = struct {
    execution_poll_helper: usize,
    call_helper: ?usize,
    call_indirect_helper: ?usize,
    call_gate_stub: ?usize,
    call_gates_base: ?usize,
    call_gates_len: usize,
    call_gate_stride: usize,
    wake_flag_offset: i32,
    trap_divide_by_zero: u32,
    trap_int_overflow: u32,
    trap_invalid_conversion: u32,
    trap_out_of_bounds: u32,
    trap_call_stack_exhausted: u32,
    trap_unreachable: u32,
    mem_view_helper: ?usize,
    mem_grow_helper: ?usize,
    mem_init_helper: ?usize,
    data_drop_helper: ?usize,
    table_size_helper: ?usize,
    table_copy_helper: ?usize,
    table_init_helper: ?usize,
    elem_drop_helper: ?usize,
    table_get_helper: ?usize,
    table_set_helper: ?usize,
    table_grow_helper: ?usize,
    table_fill_helper: ?usize,
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

const op_unreachable: u8 = 0x00;
const op_nop: u8 = 0x01;
const op_block: u8 = 0x02;
const op_loop: u8 = 0x03;
const op_if: u8 = 0x04;
const op_else: u8 = 0x05;
const op_end: u8 = 0x0b;
const op_br: u8 = 0x0c;
const op_br_if: u8 = 0x0d;
const op_br_table: u8 = 0x0e;
const op_return: u8 = 0x0f;
const op_call: u8 = 0x10;
const op_call_indirect: u8 = 0x11;
const op_drop: u8 = 0x1a;
const op_select: u8 = 0x1b;
const op_select_t: u8 = 0x1c;
const op_local_get: u8 = 0x20;
const op_local_set: u8 = 0x21;
const op_local_tee: u8 = 0x22;
const op_global_get: u8 = 0x23;
const op_global_set: u8 = 0x24;
const op_table_get: u8 = 0x25;
const op_table_set: u8 = 0x26;
const op_i32_load: u8 = 0x28;
const op_i64_load: u8 = 0x29;
const op_f32_load: u8 = 0x2a;
const op_f64_load: u8 = 0x2b;
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
const op_f32_store: u8 = 0x38;
const op_f64_store: u8 = 0x39;
const op_i32_store8: u8 = 0x3a;
const op_i32_store16: u8 = 0x3b;
const op_i64_store8: u8 = 0x3c;
const op_i64_store16: u8 = 0x3d;
const op_i64_store32: u8 = 0x3e;
const op_memory_size: u8 = 0x3f;
const op_memory_grow: u8 = 0x40;
const op_i32_const: u8 = 0x41;
const op_i64_const: u8 = 0x42;
const op_f32_const: u8 = 0x43;
const op_f64_const: u8 = 0x44;
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
const op_f32_eq: u8 = 0x5b;
const op_f32_ne: u8 = 0x5c;
const op_f32_lt: u8 = 0x5d;
const op_f32_gt: u8 = 0x5e;
const op_f32_le: u8 = 0x5f;
const op_f32_ge: u8 = 0x60;
const op_f64_eq: u8 = 0x61;
const op_f64_ne: u8 = 0x62;
const op_f64_lt: u8 = 0x63;
const op_f64_gt: u8 = 0x64;
const op_f64_le: u8 = 0x65;
const op_f64_ge: u8 = 0x66;
const op_i32_clz: u8 = 0x67;
const op_i32_ctz: u8 = 0x68;
const op_i32_popcnt: u8 = 0x69;
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
const op_i64_clz: u8 = 0x79;
const op_i64_ctz: u8 = 0x7a;
const op_i64_popcnt: u8 = 0x7b;
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
const op_f32_abs: u8 = 0x8b;
const op_f32_neg: u8 = 0x8c;
const op_f32_ceil: u8 = 0x8d;
const op_f32_floor: u8 = 0x8e;
const op_f32_trunc: u8 = 0x8f;
const op_f32_nearest: u8 = 0x90;
const op_f32_sqrt: u8 = 0x91;
const op_f32_add: u8 = 0x92;
const op_f32_sub: u8 = 0x93;
const op_f32_mul: u8 = 0x94;
const op_f32_div: u8 = 0x95;
const op_f32_min: u8 = 0x96;
const op_f32_max: u8 = 0x97;
const op_f32_copysign: u8 = 0x98;
const op_f64_abs: u8 = 0x99;
const op_f64_neg: u8 = 0x9a;
const op_f64_ceil: u8 = 0x9b;
const op_f64_floor: u8 = 0x9c;
const op_f64_trunc: u8 = 0x9d;
const op_f64_nearest: u8 = 0x9e;
const op_f64_sqrt: u8 = 0x9f;
const op_f64_add: u8 = 0xa0;
const op_f64_sub: u8 = 0xa1;
const op_f64_mul: u8 = 0xa2;
const op_f64_div: u8 = 0xa3;
const op_f64_min: u8 = 0xa4;
const op_f64_max: u8 = 0xa5;
const op_f64_copysign: u8 = 0xa6;
const op_i32_wrap_i64: u8 = 0xa7;
const op_i32_trunc_f32_s: u8 = 0xa8;
const op_i32_trunc_f32_u: u8 = 0xa9;
const op_i32_trunc_f64_s: u8 = 0xaa;
const op_i32_trunc_f64_u: u8 = 0xab;
const op_i64_extend_i32_s: u8 = 0xac;
const op_i64_extend_i32_u: u8 = 0xad;
const op_i64_trunc_f32_s: u8 = 0xae;
const op_i64_trunc_f32_u: u8 = 0xaf;
const op_i64_trunc_f64_s: u8 = 0xb0;
const op_i64_trunc_f64_u: u8 = 0xb1;
const op_f32_convert_i32_s: u8 = 0xb2;
const op_f32_convert_i32_u: u8 = 0xb3;
const op_f32_convert_i64_s: u8 = 0xb4;
const op_f32_convert_i64_u: u8 = 0xb5;
const op_f32_demote_f64: u8 = 0xb6;
const op_f64_convert_i32_s: u8 = 0xb7;
const op_f64_convert_i32_u: u8 = 0xb8;
const op_f64_convert_i64_s: u8 = 0xb9;
const op_f64_convert_i64_u: u8 = 0xba;
const op_f64_promote_f32: u8 = 0xbb;
const op_i32_reinterpret_f32: u8 = 0xbc;
const op_i64_reinterpret_f64: u8 = 0xbd;
const op_f32_reinterpret_i32: u8 = 0xbe;
const op_f64_reinterpret_i64: u8 = 0xbf;
const op_i32_extend8_s: u8 = 0xc0;
const op_i32_extend16_s: u8 = 0xc1;
const op_i64_extend8_s: u8 = 0xc2;
const op_i64_extend16_s: u8 = 0xc3;
const op_i64_extend32_s: u8 = 0xc4;
const op_ref_null: u8 = 0xd0;
const op_ref_is_null: u8 = 0xd1;
const op_ref_func: u8 = 0xd2;
const op_misc_prefix: u8 = 0xfc;
const op_simd_prefix: u8 = 0xfd;

const Loc = union(enum) {
    const_i32: i32,
    const_i64: i64,
    ref_null,
    ref_func: u32,
    ref,
    v128,
    runtime,

    fn isRef(self: Loc) bool {
        return switch (self) {
            .ref_null, .ref_func, .ref => true,
            else => false,
        };
    }

    fn materialized(self: Loc) Loc {
        return if (self.isRef()) .ref else if (self == .v128) .v128 else .runtime;
    }

    fn isWide(self: Loc) bool {
        return self.isRef() or self == .v128;
    }
};

const Ctrl = struct {
    label: x64.Masm.Label = .{},
    else_label: x64.Masm.Label = .{},
    height: usize,
    branch_arity: u32,
    result_arity: u32,
    result_loc: Loc = .runtime,
    kind: Kind,

    const Kind = enum { block, loop, if_then, if_else };
};

const max_ctrl_depth = 64;

const TerminatedArmClose = enum { continue_compilation, function_end };

/// Resume compilation at the first reachable boundary after a terminating
/// instruction. A then-arm may expose a reachable `else`; an `end` closes the
/// current frame and restores its canonical result Cells for any branch that
/// targets the merge. At function depth the closing `end` finishes the body.
fn closeTerminatedArm(
    m: *x64.Masm,
    gpa: std.mem.Allocator,
    body: []const u8,
    index: *usize,
    stack: *[operand_stack_capacity]Loc,
    sp: *usize,
    ctrl: *[max_ctrl_depth]Ctrl,
    ctrl_len: *usize,
) Error!?TerminatedArmClose {
    const boundary = dead_code.skipToFrameBoundary(body, index) orelse return null;
    if (ctrl_len.* == 0) {
        if (boundary != .end) return null;
        return .function_end;
    }

    const current = &ctrl[ctrl_len.* - 1];
    if (boundary == .else_arm) {
        if (current.kind != .if_then) return null;
        try m.bind(&current.else_label);
        current.kind = .if_else;
        sp.* = current.height;
        return .continue_compilation;
    }

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
    sp.* = current.height + current.result_arity;
    var result_depth = current.height;
    while (result_depth < sp.*) : (result_depth += 1) stack[result_depth] = current.result_loc;
    ctrl_len.* -= 1;
    return .continue_compilation;
}

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

    // Scalar numbers use the low 64 bits; references and vectors preserve
    // the complete Cell, including a funcref's defining instance.
    for (func.local_types) |local_type| if (!isSupportedValue(local_type)) return refuseSignature(config, local_type);
    for (ftype.params) |param_type| if (!isSupportedValue(param_type)) return refuseSignature(config, param_type);
    for (ftype.results) |result_type| if (!isSupportedValue(result_type)) return refuseSignature(config, result_type);

    var m = x64.Masm.init(gpa);
    defer m.deinit();

    var entry: x64.Masm.Label = .{};
    var success: x64.Masm.Label = .{};
    var explicit_return: x64.Masm.Label = .{};
    var epilogue: x64.Masm.Label = .{};
    var trap_div0: x64.Masm.Label = .{};
    var trap_overflow: x64.Masm.Label = .{};
    var trap_invalid: x64.Masm.Label = .{};
    var trap_oob: x64.Masm.Label = .{};
    var trap_stack_exhausted: x64.Masm.Label = .{};
    defer entry.deinit(gpa);
    defer success.deinit(gpa);
    defer explicit_return.deinit(gpa);
    defer epilogue.deinit(gpa);
    defer trap_div0.deinit(gpa);
    defer trap_overflow.deinit(gpa);
    defer trap_invalid.deinit(gpa);
    defer trap_oob.deinit(gpa);
    defer trap_stack_exhausted.deinit(gpa);
    var trap_div0_used = false;
    var trap_overflow_used = false;
    var trap_invalid_used = false;
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
            diagnostics.subopcode = 0;
            diagnostics.has_subopcode = false;
        }
        switch (op) {
            op_unreachable => {
                // §4.4.9 unreachable always traps. Continue parsing only at a
                // structured boundary that another machine path can reach.
                try m.movImm64(.rax, config.trap_unreachable);
                try m.jump(&epilogue);
                switch ((try closeTerminatedArm(&m, gpa, body, &i, &stack, &sp, &ctrl, &ctrl_len)) orelse return null) {
                    .continue_compilation => {},
                    .function_end => {
                        sp = ftype.results.len;
                        for (stack[0..sp]) |*loc| loc.* = .runtime;
                        function_ended = true;
                        break :body_loop;
                    },
                }
            },
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
            op_f32_const => {
                const bits = readF32Bits(body, &i) orelse return null;
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .{ .const_i32 = @bitCast(bits) };
                sp += 1;
            },
            op_f64_const => {
                const bits = readF64Bits(body, &i) orelse return null;
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .{ .const_i64 = @bitCast(bits) };
                sp += 1;
            },
            op_drop => {
                if (sp == 0) return null;
                sp -= 1;
            },
            op_select, op_select_t => {
                // §4.2.4: [v1, v2, condition] -> condition ? v1 : v2.
                var result_loc: Loc = .runtime;
                if (op == op_select_t) {
                    const type_count = readUleb32(body, &i) orelse return null;
                    if (type_count != 1) return null;
                    const value_type = readSupportedValType(body, &i) orelse return null;
                    result_loc = runtimeLoc(value_type);
                }
                if (sp < 3) return null;
                const result_depth = sp - 3;
                if (stack[result_depth] == .v128) result_loc = .v128;
                const is_wide = result_loc.isWide();
                try materialize(&m, stack[result_depth], num_locals, result_depth);
                try materialize(&m, stack[result_depth + 1], num_locals, result_depth + 1);
                try materialize(&m, stack[result_depth + 2], num_locals, result_depth + 2);

                var selected: x64.Masm.Label = .{};
                defer selected.deinit(gpa);
                try m.load32Disp32(.r10, .r12, scratchOffset(num_locals, result_depth + 2));
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, result_depth));
                if (is_wide) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, result_depth) + 8);
                try m.cmpReg32Imm32(.r10, 0);
                try m.jumpCond(.not_equal, &selected);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, result_depth + 1));
                if (is_wide) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, result_depth + 1) + 8);
                try m.bind(&selected);
                try m.store64Disp32(.r12, scratchOffset(num_locals, result_depth), .rax);
                if (is_wide) try m.store64Disp32(.r12, scratchOffset(num_locals, result_depth) + 8, .rcx);
                stack[result_depth] = result_loc;
                sp -= 2;
            },
            op_ref_null => {
                // §5.4.2: every reference type shares the all-ones null
                // encoding. Keep the value folded until a consumer needs its
                // full 128-bit Cell.
                _ = readSleb64(body, &i) orelse return null; // heap type: s33
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .ref_null;
                sp += 1;
            },
            op_ref_func => {
                const function_ref = readUleb32(body, &i) orelse return null;
                if (sp >= operand_stack_capacity) return null;
                stack[sp] = .{ .ref_func = function_ref };
                sp += 1;
            },
            op_ref_is_null => {
                if (sp == 0) return null;
                const depth = sp - 1;
                switch (stack[depth]) {
                    .ref_null => stack[depth] = .{ .const_i32 = 1 },
                    .ref_func => stack[depth] = .{ .const_i32 = 0 },
                    .ref => {
                        // REF_NULL is all ones in both halves. Their AND is
                        // all ones iff the complete 128-bit reference is null.
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.load64Disp32(.r10, .r12, scratchOffset(num_locals, depth) + 8);
                        try m.andReg64(.rax, .r10);
                        try m.movImm64(.r10, std.math.maxInt(u64));
                        try m.cmpReg64(.rax, .r10);
                        try m.setCond32(.rax, .equal);
                        try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                        stack[depth] = .runtime;
                    },
                    .const_i32, .const_i64, .runtime, .v128 => return null,
                }
            },
            op_call => {
                const callee_index = readUleb32(body, &i) orelse return null;
                const callee = calleeFuncType(module, callee_index) orelse return null;
                for (callee.params) |param_type| if (!isSupportedValue(param_type)) return null;
                for (callee.results) |result_type| if (!isSupportedValue(result_type)) return null;

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

                try emitCallArguments(&m, num_locals, below, callee.params);

                if (gate_address) |gate| {
                    const defined = defined_callee.?;
                    var local_index = defined.ftype.params.len;
                    while (local_index < defined.func.local_types.len) : (local_index += 1) {
                        try m.movImm64(.rax, if (defined.func.local_types[local_index].isRef()) std.math.maxInt(u64) else 0);
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

                try emitCallResults(&m, &stack, num_locals, below, callee.results);
                try m.addRegImm32(.rsp, call_frame_bytes);
                sp = below + result_count;
            },
            op_call_indirect => {
                // §5.4.1: [below..., args..., element_index] -> results.
                // The shared helper performs table bounds/null/type checks and
                // invokes the resolved function in its defining instance.
                const helper = config.call_indirect_helper orelse return null;
                const type_index = readUleb32(body, &i) orelse return null;
                const table_index = readUleb32(body, &i) orelse return null;
                const table64 = tableIs64(module, table_index) orelse return null;
                if (type_index >= module.types.len) return null;
                const callee = &module.types[type_index];
                for (callee.params) |param_type| if (!isSupportedValue(param_type)) return null;
                for (callee.results) |result_type| if (!isSupportedValue(result_type)) return null;

                const param_count = callee.params.len;
                const result_count = callee.results.len;
                const required = std.math.add(usize, param_count, 1) catch return null;
                if (sp < required) return null;
                const index_depth = sp - 1;
                const below = index_depth - param_count;
                if (below + result_count > operand_stack_capacity) return null;
                const buffer_capacity = @max(param_count, result_count);
                const call_frame_bytes = callFrameBytes(buffer_capacity) orelse return null;
                const refresh_memory = memoryIs64(module, 0) != null;
                if (refresh_memory and config.mem_view_helper == null) return null;

                var param_index: usize = 0;
                while (param_index < param_count) : (param_index += 1) {
                    const depth = below + param_index;
                    try materialize(&m, stack[depth], num_locals, depth);
                }
                try materialize(&m, stack[index_depth], num_locals, index_depth);

                // The helper may recurse through the interpreter. Guard the
                // staging frame itself before moving RSP; the helper retains
                // the generic recursion-depth backstop for its callee.
                if (!(try emitCallStackGuard(&m, &trap_stack_exhausted, call_frame_bytes))) return null;
                trap_stack_exhausted_used = true;
                try m.subRegImm32(.rsp, call_frame_bytes);

                try emitCallArguments(&m, num_locals, below, callee.params);

                // SysV's six register arguments fit this boundary exactly.
                try m.load64Disp32(.rdi, .rsp, @intCast(call_frame_bytes));
                try m.movImm64(.rsi, type_index);
                try m.movImm64(.rdx, table_index);
                if (table64) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, index_depth)) else try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, index_depth));
                try m.leaDisp32(.r8, .rsp, @intCast(call_stack_args_size));
                try m.movReg64(.r9, .rbx);
                try m.movImm64(.r11, helper);
                try m.callReg(.r11);

                try m.cmpReg32Imm32(.rax, 0);
                var call_ok: x64.Masm.Label = .{};
                defer call_ok.deinit(gpa);
                try m.jumpCond(.equal, &call_ok);
                try m.addRegImm32(.rsp, call_frame_bytes);
                try m.jump(&epilogue);
                try m.bind(&call_ok);

                if (refresh_memory) {
                    try m.load64Disp32(.rdi, .rsp, @intCast(call_frame_bytes));
                    try m.movImm64(.rsi, 0);
                    try m.leaDisp32(.rdx, .rsp, 16);
                    try m.movImm64(.r11, config.mem_view_helper.?);
                    try m.callReg(.r11);
                    try m.load64Disp32(.r14, .rsp, 16);
                    try m.load64Disp32(.r15, .rsp, 24);
                }

                try emitCallResults(&m, &stack, num_locals, below, callee.results);
                try m.addRegImm32(.rsp, call_frame_bytes);
                sp = below + result_count;
            },
            op_local_get => {
                const index = readUleb32(body, &i) orelse return null;
                if (index >= num_locals or sp >= operand_stack_capacity) return null;
                switch (func.local_types[index]) {
                    .i32, .f32 => try m.load32Disp32(.rax, .r12, localOffset(index)),
                    .i64, .f64 => try m.load64Disp32(.rax, .r12, localOffset(index)),
                    else => {
                        if (!isWideValue(func.local_types[index])) return null;
                        try m.load64Disp32(.rax, .r12, localOffset(index));
                        try m.load64Disp32(.rcx, .r12, localOffset(index) + 8);
                        try m.store64Disp32(.r12, scratchOffset(num_locals, sp) + 8, .rcx);
                    },
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                stack[sp] = runtimeLoc(func.local_types[index]);
                sp += 1;
            },
            op_local_set, op_local_tee => {
                const index = readUleb32(body, &i) orelse return null;
                if (index >= num_locals or sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                try m.store64Disp32(.r12, localOffset(index), .rax);
                if (isWideValue(func.local_types[index])) {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth) + 8);
                    try m.store64Disp32(.r12, localOffset(index) + 8, .rax);
                }
                if (op == op_local_set) {
                    sp -= 1;
                } else {
                    stack[depth] = runtimeLoc(func.local_types[index]);
                }
            },
            op_global_get => {
                // §4.4.5: rbp is the global-index-space array of `*Global`;
                // the scalar payload starts at offset zero in each Global.
                const index = readUleb32(body, &i) orelse return null;
                const global_type = globalValType(module, index) orelse return null;
                if (!isSupportedValue(global_type) or sp >= operand_stack_capacity) return null;
                const pointer_offset = std.math.mul(u32, index, 8) catch return null;
                if (pointer_offset > std.math.maxInt(i32)) return null;
                try m.load64Disp32(.r10, .rbp, @intCast(pointer_offset));
                if (global_type == .i32 or global_type == .f32)
                    try m.load32Disp32(.rax, .r10, 0)
                else
                    try m.load64Disp32(.rax, .r10, 0);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                if (isWideValue(global_type)) {
                    try m.load64Disp32(.rax, .r10, 8);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, sp) + 8, .rax);
                }
                stack[sp] = runtimeLoc(global_type);
                sp += 1;
            },
            op_global_set => {
                // §4.4.6: validation already established mutability and type
                // agreement. Keep the pointer and payload in separate scratch
                // registers so a folded constant cannot clobber either.
                const index = readUleb32(body, &i) orelse return null;
                const global_type = globalValType(module, index) orelse return null;
                if (!isSupportedValue(global_type) or sp == 0) return null;
                const pointer_offset = std.math.mul(u32, index, 8) catch return null;
                if (pointer_offset > std.math.maxInt(i32)) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                try m.load64Disp32(.r10, .rbp, @intCast(pointer_offset));
                try m.store64Disp32(.r10, 0, .rax);
                if (isWideValue(global_type)) {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth) + 8);
                    try m.store64Disp32(.r10, 8, .rax);
                }
                sp -= 1;
            },
            op_table_get => {
                // §4.4.x: replace the i32/i64 element index with the table's
                // 128-bit reference. The shared helper writes directly into
                // the operand's home Cell and reports an OOB trap via eax.
                const helper = config.table_get_helper orelse return null;
                const table_index = readUleb32(body, &i) orelse return null;
                const table64 = tableIs64(module, table_index) orelse return null;
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);

                try m.load64Disp32(.rdi, .rsp, 0);
                try m.movImm64(.rsi, table_index);
                if (table64) try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, depth)) else try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, depth));
                try m.leaDisp32(.rcx, .r12, scratchOffset(num_locals, depth));
                try m.movImm64(.r11, helper);
                try m.callReg(.r11);

                try m.cmpReg32Imm32(.rax, 0);
                var get_ok: x64.Masm.Label = .{};
                defer get_ok.deinit(gpa);
                try m.jumpCond(.equal, &get_ok);
                try m.jump(&epilogue);
                try m.bind(&get_ok);
                stack[depth] = .ref;
            },
            op_table_set => {
                // §4.4.x: [index, reference] -> []. Normalize either a
                // folded reference or a runtime one into its 128-bit home
                // Cell, then let the shared helper bounds-check and store it.
                const helper = config.table_set_helper orelse return null;
                const table_index = readUleb32(body, &i) orelse return null;
                const table64 = tableIs64(module, table_index) orelse return null;
                if (sp < 2) return null;
                const index_depth = sp - 2;
                const ref_depth = sp - 1;
                try materialize(&m, stack[index_depth], num_locals, index_depth);
                try emitRefIntoSlot(&m, stack[ref_depth], num_locals, ref_depth);

                try m.load64Disp32(.rdi, .rsp, 0);
                try m.movImm64(.rsi, table_index);
                if (table64) try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, index_depth)) else try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, index_depth));
                try m.leaDisp32(.rcx, .r12, scratchOffset(num_locals, ref_depth));
                try m.movImm64(.r11, helper);
                try m.callReg(.r11);

                try m.cmpReg32Imm32(.rax, 0);
                var set_ok: x64.Masm.Label = .{};
                defer set_ok.deinit(gpa);
                try m.jumpCond(.equal, &set_ok);
                try m.jump(&epilogue);
                try m.bind(&set_ok);
                sp -= 2;
            },
            op_i32_eqz => {
                if (sp == 0) return null;
                const depth = sp - 1;
                switch (stack[depth]) {
                    .const_i32 => |value| stack[depth] = .{ .const_i32 = @intFromBool(value == 0) },
                    .const_i64, .ref_null, .ref_func, .ref, .v128 => return null,
                    .runtime => {
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.cmpRegImm32(.rax, 0);
                        try m.setCond32(.rax, .equal);
                        try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                    },
                }
            },
            op_i32_clz, op_i32_ctz, op_i32_popcnt => {
                // WebAssembly Core §4.3.2. BSF/BSR are baseline x86_64, but
                // leave their destination undefined for zero, so the shared
                // lowering handles zero explicitly. POPCNT is optional on
                // x86_64; use a fixed SWAR sequence rather than raising
                // Cynic's minimum CPU feature set.
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                switch (op) {
                    op_i32_clz => try emitBitScanCount(&m, false, true),
                    op_i32_ctz => try emitBitScanCount(&m, false, false),
                    else => try emitPopcnt(&m, false),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
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
            op_i64_clz, op_i64_ctz, op_i64_popcnt => {
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                switch (op) {
                    op_i64_clz => try emitBitScanCount(&m, true, true),
                    op_i64_ctz => try emitBitScanCount(&m, true, false),
                    else => try emitPopcnt(&m, true),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
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
            op_i32_extend8_s,
            op_i32_extend16_s,
            op_i64_extend8_s,
            op_i64_extend16_s,
            op_i64_extend32_s,
            => {
                // §4.3.2 sign-extension operators. Shift pairs keep the
                // lowering on the baseline ISA; MOVSXD handles the i64/i32
                // case directly. A 32-bit destination zeroes the Cell's high
                // word, which is Cynic's canonical i32 representation.
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                if (op == op_i32_extend8_s or op == op_i32_extend16_s) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    const shift: u8 = if (op == op_i32_extend8_s) 24 else 16;
                    try m.movImm64(.rcx, shift);
                    try m.shlReg32Cl(.rax);
                    try m.movImm64(.rcx, shift);
                    try m.sarReg32Cl(.rax);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    if (op == op_i64_extend32_s) {
                        try m.signExtendReg32To64(.rax, .rax);
                    } else {
                        const shift: u8 = if (op == op_i64_extend8_s) 56 else 48;
                        try m.movImm64(.rcx, shift);
                        try m.shlReg64Cl(.rax);
                        try m.movImm64(.rcx, shift);
                        try m.sarReg64Cl(.rax);
                    }
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_f32_add,
            op_f32_sub,
            op_f32_mul,
            op_f32_div,
            op_f64_add,
            op_f64_sub,
            op_f64_mul,
            op_f64_div,
            => {
                // §4.3.3 scalar float arithmetic. Cell slots retain the raw
                // IEEE-754 bits; xmm0/xmm1 are short-lived SSE temporaries.
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                const is_f32 = op >= op_f32_add and op <= op_f32_div;
                if (is_f32) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movDXmmFromReg(.xmm0, .rax);
                    try m.movDXmmFromReg(.xmm1, .rcx);
                    switch (op) {
                        op_f32_add => try m.addFloat(.xmm0, .xmm1),
                        op_f32_sub => try m.subFloat(.xmm0, .xmm1),
                        op_f32_mul => try m.mulFloat(.xmm0, .xmm1),
                        else => try m.divFloat(.xmm0, .xmm1),
                    }
                    try m.movDRegFromXmm(.rax, .xmm0);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movQXmmFromReg(.xmm0, .rax);
                    try m.movQXmmFromReg(.xmm1, .rcx);
                    switch (op) {
                        op_f64_add => try m.addDouble(.xmm0, .xmm1),
                        op_f64_sub => try m.subDouble(.xmm0, .xmm1),
                        op_f64_mul => try m.mulDouble(.xmm0, .xmm1),
                        else => try m.divDouble(.xmm0, .xmm1),
                    }
                    try m.movQRegFromXmm(.rax, .xmm0);
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_f32_min, op_f32_max, op_f64_min, op_f64_max => {
                // SSE MIN/MAX choose the source operand for equal values and
                // NaNs, which disagrees with Wasm for one signed-zero order and
                // for a NaN in the destination. Handle unordered/equal cases
                // explicitly, then select the ordered result by condition.
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                const is_f32 = op == op_f32_min or op == op_f32_max;
                if (is_f32) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movDXmmFromReg(.xmm0, .rax);
                    try m.movDXmmFromReg(.xmm1, .rcx);
                    try m.ucomisFloat(.xmm0, .xmm1);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movQXmmFromReg(.xmm0, .rax);
                    try m.movQXmmFromReg(.xmm1, .rcx);
                    try m.ucomisDouble(.xmm0, .xmm1);
                }

                var unordered: x64.Masm.Label = .{};
                var equal: x64.Masm.Label = .{};
                var minmax_done: x64.Masm.Label = .{};
                defer unordered.deinit(gpa);
                defer equal.deinit(gpa);
                defer minmax_done.deinit(gpa);
                try m.jumpCond(.parity, &unordered);
                try m.jumpCond(.equal, &equal);
                const keep_left: x64.Cond = if (op == op_f32_min or op == op_f64_min) .below else .above;
                try m.jumpCond(keep_left, &minmax_done);
                try m.movReg64(.rax, .rcx);
                try m.jump(&minmax_done);

                try m.bind(&equal);
                if (op == op_f32_min)
                    try m.orReg32(.rax, .rcx)
                else if (op == op_f32_max)
                    try m.andReg32(.rax, .rcx)
                else if (op == op_f64_min)
                    try m.orReg64(.rax, .rcx)
                else
                    try m.andReg64(.rax, .rcx);
                try m.jump(&minmax_done);

                try m.bind(&unordered);
                if (is_f32) {
                    try m.addFloat(.xmm0, .xmm1);
                    try m.movDRegFromXmm(.rax, .xmm0);
                } else {
                    try m.addDouble(.xmm0, .xmm1);
                    try m.movQRegFromXmm(.rax, .xmm0);
                }
                try m.bind(&minmax_done);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_f32_eq,
            op_f32_ne,
            op_f32_lt,
            op_f32_gt,
            op_f32_le,
            op_f32_ge,
            op_f64_eq,
            op_f64_ne,
            op_f64_lt,
            op_f64_gt,
            op_f64_le,
            op_f64_ge,
            => {
                // UCOMIS marks NaN with PF=1 and also sets ZF/CF, so no plain
                // SETcc is sufficient for every Wasm relation. Split the
                // unordered case explicitly: only `ne` is true for NaN.
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                const is_f32 = op >= op_f32_eq and op <= op_f32_ge;
                if (is_f32) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movDXmmFromReg(.xmm0, .rax);
                    try m.movDXmmFromReg(.xmm1, .rcx);
                    try m.ucomisFloat(.xmm0, .xmm1);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movQXmmFromReg(.xmm0, .rax);
                    try m.movQXmmFromReg(.xmm1, .rcx);
                    try m.ucomisDouble(.xmm0, .xmm1);
                }

                var ordered: x64.Masm.Label = .{};
                var compare_done: x64.Masm.Label = .{};
                defer ordered.deinit(gpa);
                defer compare_done.deinit(gpa);
                try m.jumpCond(.not_parity, &ordered);
                const is_ne = op == op_f32_ne or op == op_f64_ne;
                try m.movImm64(.rax, @intFromBool(is_ne));
                try m.jump(&compare_done);
                try m.bind(&ordered);
                const condition: x64.Cond = switch (op) {
                    op_f32_eq, op_f64_eq => .equal,
                    op_f32_ne, op_f64_ne => .not_equal,
                    op_f32_lt, op_f64_lt => .below,
                    op_f32_gt, op_f64_gt => .above,
                    op_f32_le, op_f64_le => .below_or_equal,
                    else => .above_or_equal,
                };
                try m.setCond32(.rax, condition);
                try m.bind(&compare_done);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_f32_ceil,
            op_f32_floor,
            op_f32_trunc,
            op_f32_nearest,
            op_f64_ceil,
            op_f64_floor,
            op_f64_trunc,
            op_f64_nearest,
            => {
                // SSE4.1 ROUNDSS/ROUNDSD are not part of the x86_64 baseline.
                // Keep the whole function native on SSE2-only hosts by calling
                // a small raw-bit helper for the four exact Wasm round modes.
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                const is_f32 = op >= op_f32_ceil and op <= op_f32_nearest;
                if (is_f32) {
                    try m.load32Disp32(.rdi, .r12, scratchOffset(num_locals, depth));
                    try m.movImm64(.rsi, op - op_f32_ceil);
                    try m.movImm64(.r11, @intFromPtr(&roundF32Bits));
                } else {
                    try m.load64Disp32(.rdi, .r12, scratchOffset(num_locals, depth));
                    try m.movImm64(.rsi, op - op_f64_ceil);
                    try m.movImm64(.r11, @intFromPtr(&roundF64Bits));
                }
                try m.callReg(.r11);
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_f32_abs, op_f32_neg, op_f32_sqrt, op_f64_abs, op_f64_neg, op_f64_sqrt => {
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                const is_f32 = op == op_f32_abs or op == op_f32_neg or op == op_f32_sqrt;
                if (is_f32) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    switch (op) {
                        op_f32_abs => {
                            try m.movImm64(.r10, 0x7fff_ffff);
                            try m.andReg32(.rax, .r10);
                        },
                        op_f32_neg => {
                            try m.movImm64(.r10, 0x8000_0000);
                            try m.xorReg32(.rax, .r10);
                        },
                        else => {
                            try m.movDXmmFromReg(.xmm0, .rax);
                            try m.sqrtFloat(.xmm0, .xmm0);
                            try m.movDRegFromXmm(.rax, .xmm0);
                        },
                    }
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    switch (op) {
                        op_f64_abs => {
                            try m.movImm64(.r10, 0x7fff_ffff_ffff_ffff);
                            try m.andReg64(.rax, .r10);
                        },
                        op_f64_neg => {
                            try m.movImm64(.r10, 0x8000_0000_0000_0000);
                            try m.xorReg64(.rax, .r10);
                        },
                        else => {
                            try m.movQXmmFromReg(.xmm0, .rax);
                            try m.sqrtDouble(.xmm0, .xmm0);
                            try m.movQRegFromXmm(.rax, .xmm0);
                        },
                    }
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_f32_copysign, op_f64_copysign => {
                if (sp < 2) return null;
                const right = stack[sp - 1];
                const left = stack[sp - 2];
                sp -= 1;
                try materialize(&m, left, num_locals, sp - 1);
                try materialize(&m, right, num_locals, sp);
                if (op == op_f32_copysign) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movImm64(.r10, 0x8000_0000);
                    try m.andReg32(.rcx, .r10);
                    try m.movImm64(.r10, 0x7fff_ffff);
                    try m.andReg32(.rax, .r10);
                    try m.orReg32(.rax, .rcx);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                    try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, sp));
                    try m.movImm64(.r10, 0x8000_0000_0000_0000);
                    try m.andReg64(.rcx, .r10);
                    try m.movImm64(.r10, 0x7fff_ffff_ffff_ffff);
                    try m.andReg64(.rax, .r10);
                    try m.orReg64(.rax, .rcx);
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp - 1), .rax);
                stack[sp - 1] = .runtime;
            },
            op_i32_reinterpret_f32, op_i64_reinterpret_f64, op_f32_reinterpret_i32, op_f64_reinterpret_i64 => {
                // Cell lanes already hold the exact scalar bit pattern.
                if (sp == 0) return null;
            },
            op_f32_demote_f64, op_f64_promote_f32 => {
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                if (op == op_f32_demote_f64) {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    try m.movQXmmFromReg(.xmm0, .rax);
                    try m.cvtDoubleToFloat(.xmm0, .xmm0);
                    try m.movDRegFromXmm(.rax, .xmm0);
                } else {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    try m.movDXmmFromReg(.xmm0, .rax);
                    try m.cvtFloatToDouble(.xmm0, .xmm0);
                    try m.movQRegFromXmm(.rax, .xmm0);
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_i32_trunc_f32_s,
            op_i32_trunc_f32_u,
            op_i32_trunc_f64_s,
            op_i32_trunc_f64_u,
            op_i64_trunc_f32_s,
            op_i64_trunc_f32_u,
            op_i64_trunc_f64_s,
            op_i64_trunc_f64_u,
            => {
                // §4.3.3 trapping float-to-int truncation. CVTT returns an
                // ambiguous integer-indefinite value for NaN and overflow, so
                // distinguish those traps with explicit half-open range tests
                // before converting an in-range operand.
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                const src_f32 = op == op_i32_trunc_f32_s or op == op_i32_trunc_f32_u or
                    op == op_i64_trunc_f32_s or op == op_i64_trunc_f32_u;
                if (src_f32) {
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    try m.movDXmmFromReg(.xmm0, .rax);
                } else {
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                    try m.movQXmmFromReg(.xmm0, .rax);
                }
                trap_invalid_used = true;
                trap_overflow_used = true;
                switch (op) {
                    op_i32_trunc_f32_s => try emitTruncTrap(&m, true, false, true, -2147483648.0, true, 2147483648.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f32_u => try emitTruncTrap(&m, true, false, false, -1.0, false, 4294967296.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f64_s => try emitTruncTrap(&m, false, false, true, -2147483649.0, false, 2147483648.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f64_u => try emitTruncTrap(&m, false, false, false, -1.0, false, 4294967296.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f32_s => try emitTruncTrap(&m, true, true, true, -9223372036854775808.0, true, 9223372036854775808.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f32_u => try emitTruncTrap(&m, true, true, false, -1.0, false, 18446744073709551616.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f64_s => try emitTruncTrap(&m, false, true, true, -9223372036854775808.0, true, 9223372036854775808.0, &trap_invalid, &trap_overflow),
                    else => try emitTruncTrap(&m, false, true, false, -1.0, false, 18446744073709551616.0, &trap_invalid, &trap_overflow),
                }
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_f32_convert_i32_s,
            op_f32_convert_i32_u,
            op_f32_convert_i64_s,
            op_f32_convert_i64_u,
            op_f64_convert_i32_s,
            op_f64_convert_i32_u,
            op_f64_convert_i64_s,
            op_f64_convert_i64_u,
            => {
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                const source_i32 = op == op_f32_convert_i32_s or op == op_f32_convert_i32_u or
                    op == op_f64_convert_i32_s or op == op_f64_convert_i32_u;
                if (source_i32)
                    try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth))
                else
                    try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));

                switch (op) {
                    op_f32_convert_i32_s => try m.cvtI32ToFloat(.xmm0, .rax),
                    op_f32_convert_i32_u, op_f32_convert_i64_s => try m.cvtI64ToFloat(.xmm0, .rax),
                    op_f32_convert_i64_u => try emitConvertU64ToFloat(&m, true),
                    op_f64_convert_i32_s => try m.cvtI32ToDouble(.xmm0, .rax),
                    op_f64_convert_i32_u, op_f64_convert_i64_s => try m.cvtI64ToDouble(.xmm0, .rax),
                    else => try emitConvertU64ToFloat(&m, false),
                }
                if (op == op_f32_convert_i32_s or op == op_f32_convert_i32_u or
                    op == op_f32_convert_i64_s or op == op_f32_convert_i64_u)
                    try m.movDRegFromXmm(.rax, .xmm0)
                else
                    try m.movQRegFromXmm(.rax, .xmm0);
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
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
            op_f32_load,
            op_f64_load,
            op_i64_load8_s,
            op_i64_load8_u,
            op_i64_load16_s,
            op_i64_load16_u,
            op_i64_load32_s,
            op_i64_load32_u,
            => {
                const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                if (sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                const width: u32 = switch (op) {
                    op_i32_load8_s, op_i32_load8_u, op_i64_load8_s, op_i64_load8_u => 1,
                    op_i32_load16_s, op_i32_load16_u, op_i64_load16_s, op_i64_load16_u => 2,
                    op_i32_load, op_f32_load, op_i64_load32_s, op_i64_load32_u => 4,
                    else => 8,
                };
                if (!try emitIndexedMemAddress(&m, access, width, scratchOffset(num_locals, depth), config.mem_view_helper, &trap_oob)) return null;
                trap_oob_used = true;
                switch (op) {
                    op_i32_load, op_f32_load => try m.load32Disp32(.rax, .r11, 0),
                    op_i32_load8_s => try m.load8Signed32Disp32(.rax, .r11, 0),
                    op_i32_load8_u => try m.load8Disp32(.rax, .r11, 0),
                    op_i32_load16_s => try m.load16Signed32Disp32(.rax, .r11, 0),
                    op_i32_load16_u => try m.load16Disp32(.rax, .r11, 0),
                    op_i64_load, op_f64_load => try m.load64Disp32(.rax, .r11, 0),
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
            op_f32_store,
            op_f64_store,
            op_i64_store8,
            op_i64_store16,
            op_i64_store32,
            => {
                const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                if (sp < 2) return null;
                const addr_depth = sp - 2;
                const value_depth = sp - 1;
                try materialize(&m, stack[addr_depth], num_locals, addr_depth);
                try materialize(&m, stack[value_depth], num_locals, value_depth);
                const width: u32 = switch (op) {
                    op_i32_store8, op_i64_store8 => 1,
                    op_i32_store16, op_i64_store16 => 2,
                    op_i32_store, op_f32_store, op_i64_store32 => 4,
                    else => 8,
                };
                if (!try emitIndexedMemAddress(&m, access, width, scratchOffset(num_locals, addr_depth), config.mem_view_helper, &trap_oob)) return null;
                try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, value_depth));
                trap_oob_used = true;
                switch (op) {
                    op_i32_store8, op_i64_store8 => try m.store8Disp32(.r11, 0, .rax),
                    op_i32_store16, op_i64_store16 => try m.store16Disp32(.r11, 0, .rax),
                    op_i32_store, op_f32_store, op_i64_store32 => try m.store32Disp32(.r11, 0, .rax),
                    else => try m.store64Disp32(.r11, 0, .rax),
                }
                sp -= 2;
            },
            op_memory_size => {
                const memory_index = readUleb32(body, &i) orelse return null;
                if (memoryIs64(module, memory_index) == null or sp >= operand_stack_capacity) return null;
                const view = (try emitMemoryView(&m, memory_index, config.mem_view_helper)) orelse return null;
                try m.movReg64(.rax, view.length);
                try m.shrImm8(.rax, 16);
                try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                stack[sp] = .runtime;
                sp += 1;
            },
            op_memory_grow => {
                const memory_index = readUleb32(body, &i) orelse return null;
                const memory64 = memoryIs64(module, memory_index) orelse return null;
                if (config.mem_grow_helper == null or sp == 0) return null;
                const depth = sp - 1;
                try materialize(&m, stack[depth], num_locals, depth);
                try m.load64Disp32(.rdi, .rsp, 0); // Instance*, before rsp moves
                try m.movImm64(.rsi, memory_index);
                if (memory64)
                    try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, depth))
                else
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
                if (!memory64) try m.movReg32(.rax, .rax);
                try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                stack[depth] = .runtime;
            },
            op_simd_prefix => {
                const sub = readUleb32(body, &i) orelse return null;
                if (config.diagnostics) |diagnostics| {
                    diagnostics.subopcode = sub;
                    diagnostics.has_subopcode = true;
                }
                switch (sub) {
                    12 => {
                        if (body.len - i < 16 or sp >= operand_stack_capacity) return null;
                        const target = scratchOffset(num_locals, sp);
                        try m.movImm64(.rax, std.mem.readInt(u64, body[i..][0..8], .little));
                        try m.store64Disp32(.r12, target, .rax);
                        try m.movImm64(.rax, std.mem.readInt(u64, body[i + 8 ..][0..8], .little));
                        try m.store64Disp32(.r12, target + 8, .rax);
                        i += 16;
                        stack[sp] = .v128;
                        sp += 1;
                    },
                    13, 14, 256 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const selectors: ?*const [16]u8 = if (sub == 13) blk: {
                            if (body.len - i < 16) return null;
                            const lanes = body[i..][0..16];
                            for (lanes) |selector| if (selector >= 32) return null;
                            i += 16;
                            break :blk lanes;
                        } else null;
                        try emitSimdPermutation(&m, scratchOffset(num_locals, sp - 2), selectors);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    0, 11 => {
                        const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                        const store = sub == 11;
                        const consumed: usize = if (store) 2 else 1;
                        if (sp < consumed) return null;
                        if (store and stack[sp - 1] != .v128) return null;
                        const depth = sp - consumed;
                        try materialize(&m, stack[depth], num_locals, depth);
                        if (!try emitIndexedMemAddress(&m, access, 16, scratchOffset(num_locals, depth), config.mem_view_helper, &trap_oob)) return null;
                        trap_oob_used = true;
                        if (store) {
                            try m.loadVector128(.xmm0, .r12, scratchOffset(num_locals, sp - 1));
                            try m.storeVector128(.r11, 0, .xmm0);
                            sp -= 2;
                        } else {
                            try m.loadVector128(.xmm0, .r11, 0);
                            try m.storeVector128(.r12, scratchOffset(num_locals, depth), .xmm0);
                            stack[depth] = .v128;
                        }
                    },
                    1...6 => {
                        const load = simd.wideningLoadOp(sub) orelse return null;
                        const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                        if (sp == 0) return null;
                        const depth = sp - 1;
                        const target = scratchOffset(num_locals, depth);
                        try materialize(&m, stack[depth], num_locals, depth);
                        // A 64-bit load avoids over-reading the checked range.
                        if (!try emitIndexedMemAddress(&m, access, 8, target, config.mem_view_helper, &trap_oob)) return null;
                        trap_oob_used = true;
                        try m.load64Disp32(.rax, .r11, 0);
                        try m.movQXmmFromReg(.xmm0, .rax);
                        try emitSimdExtend(&m, .{ .width = load.width, .signed = load.signed, .high = false });
                        try m.storeVector128(.r12, target, .xmm0);
                        stack[depth] = .v128;
                    },
                    7...10, 92, 93 => {
                        const load = simd.scalarLoadOp(sub) orelse return null;
                        const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                        if (sp == 0) return null;
                        const depth = sp - 1;
                        const target = scratchOffset(num_locals, depth);
                        try materialize(&m, stack[depth], num_locals, depth);
                        if (!try emitIndexedMemAddress(&m, access, load.width, target, config.mem_view_helper, &trap_oob)) return null;
                        trap_oob_used = true;
                        switch (load.width) {
                            1 => try m.load8Disp32(.rax, .r11, 0),
                            2 => try m.load16Disp32(.rax, .r11, 0),
                            4 => try m.load32Disp32(.rax, .r11, 0),
                            8 => try m.load64Disp32(.rax, .r11, 0),
                            else => return null,
                        }
                        if (load.splat) {
                            try emitSimdSplat(&m, load.width, target);
                        } else {
                            try m.movQXmmFromReg(.xmm0, .rax);
                            try m.storeVector128(.r12, target, .xmm0);
                        }
                        stack[depth] = .v128;
                    },
                    15...20 => {
                        if (sp == 0) return null;
                        const width = simd.splatWidth(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try materialize(&m, stack[sp - 1], num_locals, sp - 1);
                        switch (width) {
                            1 => try m.load8Disp32(.rax, .r12, target),
                            2 => try m.load16Disp32(.rax, .r12, target),
                            4 => try m.load32Disp32(.rax, .r12, target),
                            8 => try m.load64Disp32(.rax, .r12, target),
                            else => return null,
                        }
                        try emitSimdSplat(&m, width, target);
                        stack[sp - 1] = .v128;
                    },
                    21...34 => {
                        const lane_op = simd.laneOp(sub) orelse return null;
                        if (i >= body.len or body[i] >= @as(u8, 16) / lane_op.width) return null;
                        const lane = body[i];
                        i += 1;
                        const consumed: usize = if (lane_op.replace) 2 else 1;
                        if (sp < consumed or stack[sp - consumed] != .v128) return null;
                        const depth = sp - consumed;
                        const target = scratchOffset(num_locals, depth);
                        const offset = target + @as(i32, lane) * lane_op.width;
                        if (lane_op.replace) {
                            try materialize(&m, stack[sp - 1], num_locals, sp - 1);
                            try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, sp - 1));
                            switch (lane_op.width) {
                                1 => try m.store8Disp32(.r12, offset, .rax),
                                2 => try m.store16Disp32(.r12, offset, .rax),
                                4 => try m.store32Disp32(.r12, offset, .rax),
                                8 => try m.store64Disp32(.r12, offset, .rax),
                                else => return null,
                            }
                            sp -= 1;
                        } else {
                            switch (lane_op.width) {
                                1 => if (lane_op.signed) try m.load8Signed32Disp32(.rax, .r12, offset) else try m.load8Disp32(.rax, .r12, offset),
                                2 => if (lane_op.signed) try m.load16Signed32Disp32(.rax, .r12, offset) else try m.load16Disp32(.rax, .r12, offset),
                                4 => try m.load32Disp32(.rax, .r12, offset),
                                8 => try m.load64Disp32(.rax, .r12, offset),
                                else => return null,
                            }
                            try m.store64Disp32(.r12, target, .rax);
                            stack[depth] = .runtime;
                        }
                    },
                    35...76, 214...219 => {
                        const comparison = simd.comparisonOp(sub) orelse return null;
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        try emitSimdComparison(&m, comparison, scratchOffset(num_locals, sp - 2), scratchOffset(num_locals, sp - 1));
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    99, 100, 131, 132, 163, 164, 195, 196 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const reduction = simd.reductionOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        if (!reduction.bitmask and reduction.width == 8) {
                            // PCMPEQQ would require SSE4.1. Two whole-lane tests
                            // retain SSE2 and accept nonzero values in either word.
                            try m.load64Disp32(.rax, .r12, target);
                            try m.testReg64(.rax, .rax);
                            try m.setCond32(.rax, .not_equal);
                            try m.load64Disp32(.rcx, .r12, target + 8);
                            try m.testReg64(.rcx, .rcx);
                            try m.setCond32(.rcx, .not_equal);
                            try m.andReg32(.rax, .rcx);
                        } else {
                            try m.loadVector128(.xmm0, .r12, target);
                            if (reduction.bitmask) {
                                switch (reduction.width) {
                                    1 => try m.movByteMask(.rax, .xmm0),
                                    2 => {
                                        // Signed saturation preserves the sign
                                        // and duplicates all eight packed lanes.
                                        try m.packSigned16To8(.xmm0, .xmm0);
                                        try m.movByteMask(.rax, .xmm0);
                                        try m.shrImm8(.rax, 8);
                                    },
                                    4 => try m.movFloatMask(.rax, .xmm0),
                                    8 => try m.movDoubleMask(.rax, .xmm0),
                                    else => return null,
                                }
                            } else {
                                try m.xorPacked128(.xmm1, .xmm1);
                                try m.compareEqualPacked(.xmm0, .xmm1, if (reduction.width == 1) .byte else if (reduction.width == 2) .half else .word);
                                try m.movByteMask(.rax, .xmm0);
                                try m.testReg64(.rax, .rax);
                                try m.setCond32(.rax, .equal);
                            }
                        }
                        try m.store64Disp32(.r12, target, .rax);
                        stack[sp - 1] = .runtime;
                    },
                    96, 97, 128, 129, 160, 161, 192, 193 => {
                        if (sp < 1 or stack[sp - 1] != .v128) return null;
                        const unary = simd.integerUnaryOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try m.loadVector128(.xmm0, .r12, target);
                        const result = try emitSimdIntegerUnary(&m, unary);
                        try m.storeVector128(.r12, target, result);
                    },
                    94, 95, 248...255, 257...260 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        try emitSimdConversion(&m, scratchOffset(num_locals, sp - 1), simd.conversionOp(sub) orelse return null);
                    },
                    101, 102, 133, 134 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const narrow = simd.narrowOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try emitSimdNarrow(&m, narrow);
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= 1;
                    },
                    135...138, 167...170, 199...202 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const extend = simd.extendOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try m.loadVector128(.xmm0, .r12, target);
                        try emitSimdExtend(&m, extend);
                        try m.storeVector128(.r12, target, .xmm0);
                    },
                    124...127 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const pairwise = simd.pairwiseAddOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try m.loadVector128(.xmm0, .r12, target);
                        try emitSimdPairwiseAdd(&m, pairwise);
                        try m.storeVector128(.r12, target, .xmm0);
                    },
                    261...264 => {
                        if (sp < 3) return null;
                        for (stack[sp - 3 .. sp]) |operand| if (operand != .v128) return null;
                        const target = scratchOffset(num_locals, sp - 3);
                        const wide = sub >= 263;
                        try m.loadVector128(.xmm0, .r12, target);
                        if (sub % 2 == 0) try emitSimdFloatArithmetic(&m, .{ .double_precision = wide, .kind = .neg });
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 2));
                        try m.arithmeticPackedFloat128(.xmm0, .xmm1, wide, .mul);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try m.arithmeticPackedFloat128(.xmm0, .xmm1, wide, .add);
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= 2;
                    },
                    274, 275 => {
                        const consumed: usize = if (sub == 275) 3 else 2;
                        if (sp < consumed) return null;
                        for (stack[sp - consumed .. sp]) |operand| if (operand != .v128) return null;
                        const target = scratchOffset(num_locals, sp - consumed);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - consumed + 1));
                        try emitSimdRelaxedDot(&m);
                        if (sub == 275) {
                            try emitSimdPairwiseAdd(&m, .{ .width = 2, .signed = true });
                            try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                            try m.addPackedInteger(.xmm0, .xmm1, .word);
                        }
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= consumed - 1;
                    },
                    130, 156...159, 186, 188...191, 220...223, 273 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const product = simd.productOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try emitSimdProduct(&m, product);
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= 1;
                    },
                    123, 155 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const width = simd.roundingAverageWidth(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try m.roundingAverageUnsigned128(.xmm0, .xmm1, width == 2);
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    118...121, 150...153, 182...185 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const minmax = simd.integerMinMaxOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        const result = try emitSimdMinMax(&m, minmax);
                        try m.storeVector128(.r12, target, result);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    224, 225, 227...231, 236, 237, 239...243 => {
                        const arithmetic = simd.floatArithmeticOp(sub) orelse return null;
                        const consumed: usize = if (arithmetic.isUnary()) 1 else 2;
                        if (sp < consumed) return null;
                        for (stack[sp - consumed .. sp]) |operand| if (operand != .v128) return null;
                        const target = scratchOffset(num_locals, sp - consumed);
                        try m.loadVector128(.xmm0, .r12, target);
                        if (!arithmetic.isUnary()) try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try emitSimdFloatArithmetic(&m, arithmetic);
                        try m.storeVector128(.r12, target, .xmm0);
                        sp -= consumed - 1;
                        stack[sp - 1] = .v128;
                    },
                    103...106, 116, 117, 122, 148 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const round = simd.floatRoundOp(sub) orelse return null;
                        const width: i32 = if (round.double_precision) 8 else 4;
                        const target = scratchOffset(num_locals, sp - 1);
                        // Reuse the scalar raw-bit ABI without requiring SSE4.1.
                        // All live operands stay in Cells across each call.
                        for (0..@as(usize, @intCast(@divExact(16, width)))) |lane| {
                            const offset = target + @as(i32, @intCast(lane)) * width;
                            if (round.double_precision)
                                try m.load64Disp32(.rdi, .r12, offset)
                            else
                                try m.load32Disp32(.rdi, .r12, offset);
                            try m.movImm32(.rsi, @intFromEnum(round.mode));
                            try m.movImm64(.r11, if (round.double_precision) @intFromPtr(&roundF64Bits) else @intFromPtr(&roundF32Bits));
                            try m.callReg(.r11);
                            if (round.double_precision)
                                try m.store64Disp32(.r12, offset, .rax)
                            else
                                try m.store32Disp32(.r12, offset, .rax);
                        }
                    },
                    234, 235, 246, 247 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const minmax = simd.floatPseudoMinMaxOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        // SSE selects its second operand on ties/NaNs; reverse.
                        try m.minMaxPackedFloat128(.xmm1, .xmm0, minmax.double_precision, minmax.maximum);
                        try m.storeVector128(.r12, target, .xmm1);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    232, 233, 244, 245, 269...272 => {
                        if (sp < 2 or stack[sp - 2] != .v128 or stack[sp - 1] != .v128) return null;
                        const minmax = simd.floatMinMaxOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.loadVector128(.xmm0, .r12, target);
                        try m.loadVector128(.xmm1, .r12, scratchOffset(num_locals, sp - 1));
                        try emitSimdFloatMinMax(&m, minmax);
                        try m.storeVector128(.r12, target, .xmm2);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    77...82, 265...268 => {
                        const consumed: usize = if (sub == 77) 1 else if (sub == 82 or sub >= 265) 3 else 2;
                        if (sp < consumed) return null;
                        const depth = sp - consumed;
                        for (stack[depth..sp]) |operand| if (operand != .v128) return null;
                        const target = scratchOffset(num_locals, depth);
                        for ([_]i32{ 0, 8 }) |half| {
                            try m.load64Disp32(.rax, .r12, target + half);
                            if (sub == 77)
                                try m.movImm64(.rcx, std.math.maxInt(u64))
                            else
                                try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, depth + 1) + half);
                            switch (sub) {
                                77, 81 => try m.xorReg64(.rax, .rcx),
                                78 => try m.andReg64(.rax, .rcx),
                                79 => {
                                    try m.movImm64(.rdx, std.math.maxInt(u64));
                                    try m.xorReg64(.rcx, .rdx);
                                    try m.andReg64(.rax, .rcx);
                                },
                                80 => try m.orReg64(.rax, .rcx),
                                82, 265...268 => {
                                    try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, depth + 2) + half);
                                    try m.xorReg64(.rax, .rcx);
                                    try m.andReg64(.rax, .rdx);
                                    try m.xorReg64(.rax, .rcx);
                                },
                                else => return null,
                            }
                            try m.store64Disp32(.r12, target + half, .rax);
                        }
                        sp = depth + 1;
                        stack[depth] = .v128;
                    },
                    84...91 => {
                        const access = metadata.readMemoryAccess(module, body, &i) orelse return null;
                        const size_log2: u2 = @intCast((sub - 84) % 4);
                        const width = @as(u32, 1) << size_log2;
                        if (i >= body.len or body[i] >= 16 / width) return null;
                        const lane = body[i];
                        i += 1;
                        if (sp < 2 or stack[sp - 1] != .v128) return null;
                        const store = sub >= 88;
                        const depth = sp - 2;
                        const target = scratchOffset(num_locals, depth);
                        const source = scratchOffset(num_locals, sp - 1);
                        try materialize(&m, stack[depth], num_locals, depth);
                        if (!try emitIndexedMemAddress(&m, access, width, target, config.mem_view_helper, &trap_oob)) return null;
                        trap_oob_used = true;
                        // Cells already hold the complete vector: MOVDQU plus
                        // a narrow scalar move preserves the SSE2 baseline,
                        // without SSE4.1 PINSR/PEXTR instructions.
                        if (!store) {
                            try m.loadVector128(.xmm0, .r12, source);
                            try m.storeVector128(.r12, target, .xmm0);
                        }
                        const lane_offset = (if (store) source else target) + @as(i32, @intCast(lane * width));
                        const from_base: x64.Reg = if (store) .r12 else .r11;
                        const from_offset: i32 = if (store) lane_offset else 0;
                        const to_base: x64.Reg = if (store) .r11 else .r12;
                        const to_offset: i32 = if (store) 0 else lane_offset;
                        switch (size_log2) {
                            0 => try m.load8Disp32(.rax, from_base, from_offset),
                            1 => try m.load16Disp32(.rax, from_base, from_offset),
                            2 => try m.load32Disp32(.rax, from_base, from_offset),
                            3 => try m.load64Disp32(.rax, from_base, from_offset),
                        }
                        switch (size_log2) {
                            0 => try m.store8Disp32(to_base, to_offset, .rax),
                            1 => try m.store16Disp32(to_base, to_offset, .rax),
                            2 => try m.store32Disp32(to_base, to_offset, .rax),
                            3 => try m.store64Disp32(to_base, to_offset, .rax),
                        }
                        sp -= if (store) @as(usize, 2) else 1;
                        if (!store) stack[depth] = .v128;
                    },
                    83 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try m.load64Disp32(.rax, .r12, target);
                        try m.load64Disp32(.rcx, .r12, target + 8);
                        try m.orReg64(.rax, .rcx);
                        try m.setCond32(.rax, .not_equal);
                        try m.store64Disp32(.r12, target, .rax);
                        stack[sp - 1] = .runtime;
                    },
                    98 => {
                        if (sp == 0 or stack[sp - 1] != .v128) return null;
                        const target = scratchOffset(num_locals, sp - 1);
                        try m.loadVector128(.xmm0, .r12, target);
                        try emitSimdPopcount(&m);
                        try m.storeVector128(.r12, target, .xmm0);
                    },
                    107...109, 139...141, 171...173, 203...205 => {
                        if (sp < 2 or stack[sp - 2] != .v128) return null;
                        const shift = simd.shiftOp(sub) orelse return null;
                        try materialize(&m, stack[sp - 1], num_locals, sp - 1);
                        const target = scratchOffset(num_locals, sp - 2);
                        try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, sp - 1));
                        try emitSimdShift(&m, shift, target);
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    110...115, 142...147, 149, 174, 177, 181, 206, 209, 213 => {
                        if (sp < 2 or stack[sp - 1] != .v128 or stack[sp - 2] != .v128) return null;
                        const binary = simd.integerBinaryOp(sub) orelse return null;
                        const target = scratchOffset(num_locals, sp - 2);
                        const source = scratchOffset(num_locals, sp - 1);
                        if (binary.kind == .mul and binary.width == 8) {
                            for ([_]i32{ 0, 8 }) |half| {
                                try m.load64Disp32(.rax, .r12, target + half);
                                try m.load64Disp32(.rcx, .r12, source + half);
                                try m.imulReg64(.rax, .rcx);
                                try m.store64Disp32(.r12, target + half, .rax);
                            }
                        } else {
                            try m.loadVector128(.xmm0, .r12, target);
                            try m.loadVector128(.xmm1, .r12, source);
                            try emitSimdIntegerBinary(&m, binary);
                            try m.storeVector128(.r12, target, .xmm0);
                        }
                        sp -= 1;
                        stack[sp - 1] = .v128;
                    },
                    else => return refuse(config, .unsupported_opcode, op),
                }
            },
            op_misc_prefix => {
                const sub = readUleb32(body, &i) orelse return null;
                if (config.diagnostics) |diagnostics| {
                    diagnostics.subopcode = sub;
                    diagnostics.has_subopcode = true;
                }
                if (sub <= 7) {
                    // §4.3.3 saturating float-to-int truncations. Explicit
                    // branches implement NaN -> 0 and clamp both bounds;
                    // in-range values share the trapping forms' SSE2 lowering.
                    if (sp == 0) return null;
                    const depth = sp - 1;
                    try materialize(&m, stack[depth], num_locals, depth);
                    const src_f32 = (sub & 0x2) == 0;
                    if (src_f32) {
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.movDXmmFromReg(.xmm0, .rax);
                    } else {
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, depth));
                        try m.movQXmmFromReg(.xmm0, .rax);
                    }
                    switch (sub) {
                        0 => try emitTruncSat(&m, true, false, true),
                        1 => try emitTruncSat(&m, true, false, false),
                        2 => try emitTruncSat(&m, false, false, true),
                        3 => try emitTruncSat(&m, false, false, false),
                        4 => try emitTruncSat(&m, true, true, true),
                        5 => try emitTruncSat(&m, true, true, false),
                        6 => try emitTruncSat(&m, false, true, true),
                        else => try emitTruncSat(&m, false, true, false),
                    }
                    try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
                    stack[depth] = .runtime;
                } else if (sub == 8) {
                    // §4.4.7 memory.init: [dst, src, len] -> []. The shared
                    // helper owns the segment + memory bounds checks and
                    // reports a stashed OutOfBoundsMemoryAccess through the
                    // ordinary native trap-status channel.
                    const helper = config.mem_init_helper orelse return null;
                    const data_index = readUleb32(body, &i) orelse return null;
                    const memory_index = readUleb32(body, &i) orelse return null;
                    const memory64 = memoryIs64(module, memory_index) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);

                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, data_index);
                    try m.movImm64(.rdx, memory_index);
                    if (memory64)
                        try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, below))
                    else
                        try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below));
                    try m.load32Disp32(.r8, .r12, scratchOffset(num_locals, below + 1));
                    try m.load32Disp32(.r9, .r12, scratchOffset(num_locals, below + 2));
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);

                    try m.cmpReg32Imm32(.rax, 0);
                    var init_ok: x64.Masm.Label = .{};
                    defer init_ok.deinit(gpa);
                    try m.jumpCond(.equal, &init_ok);
                    try m.jump(&epilogue);
                    try m.bind(&init_ok);
                    sp = below;
                } else if (sub == 9) {
                    // §4.4.7 data.drop has no stack effect and cannot trap.
                    const helper = config.data_drop_helper orelse return null;
                    const data_index = readUleb32(body, &i) orelse return null;
                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, data_index);
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);
                } else if (sub == 11) {
                    const memory_index = readUleb32(body, &i) orelse return null;
                    const memory64 = memoryIs64(module, memory_index) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);
                    const view = (try emitMemoryView(&m, memory_index, config.mem_view_helper)) orelse return null;
                    if (memory64)
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, below))
                    else
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, below)); // dst
                    if (memory64)
                        try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2))
                    else
                        try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2)); // count
                    try emitRangeBounds(&m, .rax, .rdx, view.length, &trap_oob);
                    trap_oob_used = true;
                    try m.movReg64(.r11, view.base);
                    try m.addReg64(.r11, .rax);
                    try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1)); // value
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
                    const dst64 = memoryIs64(module, destination_memory) orelse return null;
                    const src64 = memoryIs64(module, source_memory) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);
                    const src_view = (try emitMemoryView(&m, source_memory, config.mem_view_helper)) orelse return null;
                    if (src64)
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, below + 1))
                    else
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, below + 1));
                    // Core memory.copy uses min(dst address type, src address type).
                    if (dst64 and src64)
                        try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2))
                    else
                        try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2));
                    try emitRangeBounds(&m, .rax, .rdx, src_view.length, &trap_oob);
                    try m.addReg64(.rax, src_view.base);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below + 1), .rax);
                    const dst_view = (try emitMemoryView(&m, destination_memory, config.mem_view_helper)) orelse return null;
                    if (dst64)
                        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, below))
                    else
                        try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, below));
                    if (dst64 and src64)
                        try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2))
                    else
                        try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below + 2));
                    try emitRangeBounds(&m, .rax, .rdx, dst_view.length, &trap_oob);
                    trap_oob_used = true;
                    try m.movReg64(.r8, dst_view.base);
                    try m.addReg64(.r8, .rax);
                    try m.load64Disp32(.r9, .r12, scratchOffset(num_locals, below + 1));
                    var forward: x64.Masm.Label = .{};
                    var forward_loop: x64.Masm.Label = .{};
                    var backward_loop: x64.Masm.Label = .{};
                    var copy_done: x64.Masm.Label = .{};
                    defer forward.deinit(gpa);
                    defer forward_loop.deinit(gpa);
                    defer backward_loop.deinit(gpa);
                    defer copy_done.deinit(gpa);
                    try m.cmpReg64(.r8, .r9);
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
                } else if (sub == 12) {
                    // §4.4.x table.init: [dst, src, len] -> []. References
                    // remain inside the element segment and table, so all six
                    // helper arguments fit the SysV register ABI directly.
                    const helper = config.table_init_helper orelse return null;
                    const element_index = readUleb32(body, &i) orelse return null;
                    const table_index = readUleb32(body, &i) orelse return null;
                    const table64 = tableIs64(module, table_index) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);

                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, element_index);
                    try m.movImm64(.rdx, table_index);
                    if (table64) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, below)) else try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below));
                    try m.load32Disp32(.r8, .r12, scratchOffset(num_locals, below + 1));
                    try m.load32Disp32(.r9, .r12, scratchOffset(num_locals, below + 2));
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);

                    try m.cmpReg32Imm32(.rax, 0);
                    var init_ok: x64.Masm.Label = .{};
                    defer init_ok.deinit(gpa);
                    try m.jumpCond(.equal, &init_ok);
                    try m.jump(&epilogue);
                    try m.bind(&init_ok);
                    sp = below;
                } else if (sub == 13) {
                    // §4.4.x elem.drop has no stack effect and cannot trap.
                    const helper = config.elem_drop_helper orelse return null;
                    const element_index = readUleb32(body, &i) orelse return null;
                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, element_index);
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);
                } else if (sub == 14) {
                    // §4.4.x table.copy: [dst, src, len] -> []. The helper is
                    // overlap-safe and reports OOB through the shared trap
                    // channel.
                    const helper = config.table_copy_helper orelse return null;
                    const destination_table = readUleb32(body, &i) orelse return null;
                    const source_table = readUleb32(body, &i) orelse return null;
                    const destination64 = tableIs64(module, destination_table) orelse return null;
                    const source64 = tableIs64(module, source_table) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);

                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, destination_table);
                    try m.movImm64(.rdx, source_table);
                    if (destination64) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, below)) else try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below));
                    if (source64) try m.load64Disp32(.r8, .r12, scratchOffset(num_locals, below + 1)) else try m.load32Disp32(.r8, .r12, scratchOffset(num_locals, below + 1));
                    // Core table.copy uses the narrower table's width for len.
                    if (destination64 and source64) try m.load64Disp32(.r9, .r12, scratchOffset(num_locals, below + 2)) else try m.load32Disp32(.r9, .r12, scratchOffset(num_locals, below + 2));
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);

                    try m.cmpReg32Imm32(.rax, 0);
                    var copy_ok: x64.Masm.Label = .{};
                    defer copy_ok.deinit(gpa);
                    try m.jumpCond(.equal, &copy_ok);
                    try m.jump(&epilogue);
                    try m.bind(&copy_ok);
                    sp = below;
                } else if (sub == 15) {
                    // §4.4.x table.grow: [init_ref, delta] -> old_size. The
                    // helper reads the complete reference from its home Cell;
                    // growth failure returns i32/i64 -1 and never traps.
                    const helper = config.table_grow_helper orelse return null;
                    const table_index = readUleb32(body, &i) orelse return null;
                    const table64 = tableIs64(module, table_index) orelse return null;
                    if (sp < 2) return null;
                    const below = sp - 2;
                    if (below + 1 > operand_stack_capacity) return null;
                    try materialize(&m, stack[below + 1], num_locals, below + 1);
                    try emitRefIntoSlot(&m, stack[below], num_locals, below);

                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, table_index);
                    try m.leaDisp32(.rdx, .r12, scratchOffset(num_locals, below));
                    if (table64) try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1)) else try m.load32Disp32(.rcx, .r12, scratchOffset(num_locals, below + 1));
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);
                    if (!table64) try m.movReg32(.rax, .rax);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, below), .rax);
                    stack[below] = .runtime;
                    sp = below + 1;
                } else if (sub == 16) {
                    // §4.4.x table.size: [] -> current element count.
                    const helper = config.table_size_helper orelse return null;
                    const table_index = readUleb32(body, &i) orelse return null;
                    const table64 = tableIs64(module, table_index) orelse return null;
                    if (sp >= operand_stack_capacity) return null;
                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, table_index);
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);
                    if (!table64) try m.movReg32(.rax, .rax);
                    try m.store64Disp32(.r12, scratchOffset(num_locals, sp), .rax);
                    stack[sp] = .runtime;
                    sp += 1;
                } else if (sub == 17) {
                    // §4.4.x table.fill: [index, reference, count] -> [].
                    const helper = config.table_fill_helper orelse return null;
                    const table_index = readUleb32(body, &i) orelse return null;
                    const table64 = tableIs64(module, table_index) orelse return null;
                    if (sp < 3) return null;
                    const below = sp - 3;
                    try materialize(&m, stack[below], num_locals, below);
                    try emitRefIntoSlot(&m, stack[below + 1], num_locals, below + 1);
                    try materialize(&m, stack[below + 2], num_locals, below + 2);

                    try m.load64Disp32(.rdi, .rsp, 0);
                    try m.movImm64(.rsi, table_index);
                    if (table64) try m.load64Disp32(.rdx, .r12, scratchOffset(num_locals, below)) else try m.load32Disp32(.rdx, .r12, scratchOffset(num_locals, below));
                    try m.leaDisp32(.rcx, .r12, scratchOffset(num_locals, below + 1));
                    if (table64) try m.load64Disp32(.r8, .r12, scratchOffset(num_locals, below + 2)) else try m.load32Disp32(.r8, .r12, scratchOffset(num_locals, below + 2));
                    try m.movImm64(.r11, helper);
                    try m.callReg(.r11);

                    try m.cmpReg32Imm32(.rax, 0);
                    var fill_ok: x64.Masm.Label = .{};
                    defer fill_ok.deinit(gpa);
                    try m.jumpCond(.equal, &fill_ok);
                    try m.jump(&epilogue);
                    try m.bind(&fill_ok);
                    sp = below;
                } else {
                    return refuse(config, .unsupported_opcode, op_misc_prefix);
                }
            },
            op_block => {
                const result = readBlockResult(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = result.arity, .result_arity = result.arity, .result_loc = result.loc, .kind = .block };
                ctrl_len += 1;
            },
            op_loop => {
                const result = readBlockResult(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = 0, .result_arity = result.arity, .result_loc = result.loc, .kind = .loop };
                try m.bind(&ctrl[ctrl_len].label);
                ctrl_len += 1;
            },
            op_if => {
                if (sp == 0) return null;
                sp -= 1;
                const condition = stack[sp];
                const result = readBlockResult(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                try materialize(&m, condition, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp));
                try m.cmpRegImm32(.rax, 0);
                ctrl[ctrl_len] = .{ .height = sp, .branch_arity = result.arity, .result_arity = result.arity, .result_loc = result.loc, .kind = .if_then };
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
                if (!(try emitBranchValues(&m, stack[0..], num_locals, sp, target.height, target.branch_arity))) return null;
                if (target.kind == .loop) {
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                }
                try m.jump(&target.label);

                // The remainder of the current frame is unreachable. Parse
                // instruction widths until its matching end; unknown forms
                // refuse rather than desynchronize the bytecode cursor.
                if (ctrl_len == 0) return null;
                dead_code.skipToFrameEnd(body, &i) orelse return null;
                const current = &ctrl[ctrl_len - 1];
                if (current.kind == .if_then or current.kind == .if_else) return null;
                if (current.kind == .block) try m.bind(&current.label);
                current.label.deinit(gpa);
                current.else_label.deinit(gpa);
                sp = current.height + current.result_arity;
                var result_depth = current.height;
                while (result_depth < sp) : (result_depth += 1) stack[result_depth] = current.result_loc;
                ctrl_len -= 1;
            },
            op_br_if => {
                const depth = readUleb32(body, &i) orelse return null;
                if (sp == 0 or depth >= ctrl_len) return null;
                sp -= 1;
                const condition = stack[sp];
                const target = &ctrl[ctrl_len - 1 - depth];
                try materialize(&m, condition, num_locals, sp);
                try m.load32Disp32(.rax, .r12, scratchOffset(num_locals, sp));
                try m.cmpRegImm32(.rax, 0);

                var not_taken: x64.Masm.Label = .{};
                defer not_taken.deinit(gpa);
                try m.jumpCond(.equal, &not_taken);
                if (!(try emitBranchValues(&m, stack[0..], num_locals, sp, target.height, target.branch_arity))) return null;
                if (target.kind == .loop) {
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                }
                try m.jump(&target.label);
                try m.bind(&not_taken);
            },
            op_br_table => {
                // §3.3.8: dispatch to one structured target, carrying the
                // common branch-result arity and unwinding intervening stack
                // operands. A linear chain matches the AArch64 baseline's
                // compact first-tier lowering.
                if (sp == 0) return null;
                sp -= 1;
                try materialize(&m, stack[sp], num_locals, sp);
                try m.load32Disp32(.r10, .r12, scratchOffset(num_locals, sp));

                const count = readUleb32(body, &i) orelse return null;
                var case_index: u32 = 0;
                while (case_index < count) : (case_index += 1) {
                    const depth = readUleb32(body, &i) orelse return null;
                    if (depth >= ctrl_len) return null;
                    const target = &ctrl[ctrl_len - 1 - depth];
                    var next_case: x64.Masm.Label = .{};
                    defer next_case.deinit(gpa);
                    try m.cmpReg32Imm32(.r10, case_index);
                    try m.jumpCond(.not_equal, &next_case);
                    if (!(try emitBranchValues(&m, stack[0..], num_locals, sp, target.height, target.branch_arity))) return null;
                    if (target.kind == .loop) {
                        try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                    }
                    try m.jump(&target.label);
                    try m.bind(&next_case);
                }

                const default_depth = readUleb32(body, &i) orelse return null;
                if (default_depth >= ctrl_len) return null;
                const default_target = &ctrl[ctrl_len - 1 - default_depth];
                if (!(try emitBranchValues(&m, stack[0..], num_locals, sp, default_target.height, default_target.branch_arity))) return null;
                if (default_target.kind == .loop) {
                    try emitExecutionPoll(&m, &epilogue, config.execution_poll_helper, config.wake_flag_offset);
                }
                try m.jump(&default_target.label);

                if (ctrl_len == 0) return null;
                dead_code.skipToFrameEnd(body, &i) orelse return null;
                const current = &ctrl[ctrl_len - 1];
                if (current.kind == .if_then or current.kind == .if_else) return null;
                if (current.kind == .block) try m.bind(&current.label);
                current.label.deinit(gpa);
                current.else_label.deinit(gpa);
                sp = current.height + current.result_arity;
                var result_depth = current.height;
                while (result_depth < sp) : (result_depth += 1) stack[result_depth] = current.result_loc;
                ctrl_len -= 1;
            },
            op_return => {
                // Canonicalize the function results and join the success
                // epilogue. Parsing resumes only where another structured
                // path can reach: an else-arm or a frame merge.
                const result_arity: u32 = @intCast(ftype.results.len);
                if (!(try emitBranchValues(&m, stack[0..], num_locals, sp, 0, result_arity))) return null;
                var result_depth: usize = 0;
                while (result_depth < result_arity) : (result_depth += 1) stack[result_depth] = runtimeLoc(ftype.results[result_depth]);
                try m.jump(&explicit_return);
                switch ((try closeTerminatedArm(&m, gpa, body, &i, &stack, &sp, &ctrl, &ctrl_len)) orelse return null) {
                    .continue_compilation => {},
                    .function_end => {
                        sp = result_arity;
                        function_ended = true;
                        break :body_loop;
                    },
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
    try m.bind(&success);
    for (ftype.results, 0..) |_, result_index| {
        try materialize(&m, stack[result_index], num_locals, result_index);
    }
    try emitResultsFromCells(&m, num_locals, ftype.results);
    try m.movImm64(.rax, 0);
    try m.jump(&epilogue);

    // Explicit returns already canonicalized their values into Cell depths
    // 0..result_count. Copy those runtime Cells directly: the fallthrough
    // path's final Loc metadata may describe different constants.
    try m.bind(&explicit_return);
    try emitResultsFromCells(&m, num_locals, ftype.results);
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
    if (trap_invalid_used) {
        try m.bind(&trap_invalid);
        try m.movImm64(.rax, config.trap_invalid_conversion);
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

fn emitResultsFromCells(m: *x64.Masm, num_locals: usize, results: []const ValType) Error!void {
    for (results, 0..) |value_type, result_index| {
        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, result_index));
        try m.store64Disp32(.r13, resultOffset(result_index), .rax);
        if (isWideValue(value_type))
            try m.load64Disp32(.rcx, .r12, scratchOffset(num_locals, result_index) + 8)
        else
            try m.movImm64(.rcx, 0);
        try m.store64Disp32(.r13, resultOffset(result_index) + 8, .rcx);
    }
}

fn emitCallArguments(m: *x64.Masm, num_locals: usize, below: usize, params: []const ValType) Error!void {
    for (params, 0..) |value_type, index| {
        const source = scratchOffset(num_locals, below + index);
        const target = callBufferOffset(index);
        try m.load64Disp32(.rax, .r12, source);
        try m.store64Disp32(.rsp, target, .rax);
        if (isWideValue(value_type))
            try m.load64Disp32(.rax, .r12, source + 8)
        else
            try m.movImm64(.rax, 0);
        try m.store64Disp32(.rsp, target + 8, .rax);
    }
}

fn emitCallResults(m: *x64.Masm, stack: []Loc, num_locals: usize, below: usize, results: []const ValType) Error!void {
    for (results, 0..) |value_type, index| {
        const source = callBufferOffset(index);
        const target = scratchOffset(num_locals, below + index);
        try m.load64Disp32(.rax, .rsp, source);
        try m.store64Disp32(.r12, target, .rax);
        if (isWideValue(value_type)) {
            try m.load64Disp32(.rax, .rsp, source + 8);
            try m.store64Disp32(.r12, target + 8, .rax);
        }
        stack[below + index] = runtimeLoc(value_type);
    }
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

fn emitSimdComparison(m: *x64.Masm, op: simd.ComparisonOp, target: i32, right_offset: i32) Error!void {
    if (!op.floating and op.width == 8) {
        // SSE2 lacks PCMPGTQ/PCMPEQQ. Scalar comparisons still produce full
        // qword masks and never confuse the signs of the two 32-bit halves.
        for ([_]i32{ 0, 8 }) |half| {
            try m.load64Disp32(.rax, .r12, target + half);
            try m.load64Disp32(.rcx, .r12, right_offset + half);
            try m.cmpReg64(.rax, .rcx);
            try m.setCond32(.rax, switch (op.relation) {
                .eq => .equal,
                .ne => .not_equal,
                .lt => .less,
                .gt => .greater,
                .le => .less_or_equal,
                .ge => .greater_or_equal,
            });
            try m.movImm64(.rcx, 0);
            try m.subReg64(.rcx, .rax);
            try m.store64Disp32(.r12, target + half, .rcx);
        }
        return;
    }
    try m.loadVector128(.xmm0, .r12, target);
    try m.loadVector128(.xmm1, .r12, right_offset);
    var result: x64.Xmm = .xmm0;
    if (op.floating) {
        // Swap operands for gt/ge: negating lt/le would accept unordered
        // lanes. CMPNEQ alone is true for a NaN in either operand.
        const reverse = op.relation == .gt or op.relation == .ge;
        result = if (reverse) .xmm1 else .xmm0;
        try m.comparePackedFloat128(result, if (reverse) .xmm0 else .xmm1, op.width == 8, switch (op.relation) {
            .eq => .eq,
            .ne => .ne,
            .lt, .gt => .lt,
            .le, .ge => .le,
        });
    } else {
        const size: x64.Masm.PackedIntSize = switch (op.width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            else => return error.UnsupportedOp,
        };
        if (op.relation == .eq or op.relation == .ne) {
            try m.compareEqualPacked(.xmm0, .xmm1, size);
        } else {
            if (!op.signed) {
                // Flipping every lane's sign bit maps unsigned ordering to
                // signed ordering for all three SSE2 comparison widths.
                var sign_bits: u64 = 0;
                var bit: u8 = @as(u8, op.width) * 8 - 1;
                while (bit < 64) : (bit += @as(u8, op.width) * 8) sign_bits |= @as(u64, 1) << @as(u6, @intCast(bit));
                try m.movImm64(.rax, sign_bits);
                try m.movQXmmFromReg(.xmm2, .rax);
                try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
                try m.xorPacked128(.xmm0, .xmm2);
                try m.xorPacked128(.xmm1, .xmm2);
            }
            const reverse = op.relation == .lt or op.relation == .ge;
            result = if (reverse) .xmm1 else .xmm0;
            try m.compareGreaterSignedPacked(result, if (reverse) .xmm0 else .xmm1, size);
        }
        if (op.relation == .ne or op.relation == .le or op.relation == .ge) {
            try m.compareEqualPacked(.xmm2, .xmm2, .word);
            try m.xorPacked128(result, .xmm2);
        }
    }
    try m.storeVector128(.r12, target, result);
}

/// Repeat the zero-extended lane in rax without interpreting float bits.
fn emitSimdSplat(m: *x64.Masm, width: u4, target: i32) Error!void {
    var shift: u8 = @as(u8, width) * 8;
    while (shift < 64) : (shift *= 2) {
        try m.movReg64(.rcx, .rax);
        try m.shlImm8(.rcx, shift);
        try m.orReg64(.rax, .rcx);
    }
    try m.store64Disp32(.r12, target, .rax);
    try m.store64Disp32(.r12, target + 8, .rax);
}

fn emitSimdExtend(m: *x64.Masm, op: simd.ExtendOp) Error!void {
    const size: x64.Masm.PackedIntSize = switch (op.width) {
        1 => .byte,
        2 => .half,
        4 => .word,
        else => return error.UnsupportedOp,
    };
    // Zero > signed lane supplies the sign-extension bits for PUNPCK.
    try m.xorPacked128(.xmm1, .xmm1);
    if (op.signed) try m.compareGreaterSignedPacked(.xmm1, .xmm0, size);
    if (op.high)
        try m.unpackHighPackedInteger(.xmm0, .xmm1, size)
    else
        try m.unpackLowPackedInteger(.xmm0, .xmm1, size);
}

fn emitSimdNarrow(m: *x64.Masm, op: simd.NarrowOp) Error!void {
    if (op.width == 1) {
        if (op.signed) try m.packSigned16To8(.xmm0, .xmm1) else try m.packUnsigned16To8(.xmm0, .xmm1);
    } else if (op.signed) {
        try m.packSigned32To16(.xmm0, .xmm1);
    } else {
        // PACKUSDW needs SSE4.1. Clamp negatives first, bias by -32768,
        // PACKSSDW, then flip each output sign bit to recover unsigned lanes.
        try m.movImm64(.rax, 0x0000800000008000);
        try m.movQXmmFromReg(.xmm3, .rax);
        try m.shufflePackedI32(.xmm3, .xmm3, 0x44);
        for ([_]x64.Xmm{ .xmm0, .xmm1 }) |input| {
            try m.xorPacked128(.xmm2, .xmm2);
            try m.compareGreaterSignedPacked(.xmm2, input, .word);
            try m.andNotPacked128(.xmm2, input);
            try m.movVector128(input, .xmm2);
            try m.subtractPackedInteger(input, .xmm3, .word);
        }
        try m.packSigned32To16(.xmm0, .xmm1);
        try m.movImm64(.rax, 0x8000800080008000);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        try m.xorPacked128(.xmm0, .xmm1);
    }
}

fn emitSimdPairwiseAdd(m: *x64.Masm, op: simd.PairwiseAddOp) Error!void {
    if (op.signed and op.width == 2) {
        try m.movImm64(.rax, 0x0001000100010001);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        try m.multiplyAddPackedI16(.xmm0, .xmm1);
        return;
    }
    try m.movVector128(.xmm1, .xmm0);
    if (op.signed) {
        try m.movImm64(.rax, 8);
        try m.movDXmmFromReg(.xmm2, .rax);
        try m.shiftPackedInteger(.xmm0, .xmm2, .shl16);
        try m.shiftPackedInteger(.xmm0, .xmm2, .sar16);
        try m.shiftPackedInteger(.xmm1, .xmm2, .sar16);
    } else {
        try m.shiftRightLogicalPacked128(.xmm1, @as(u8, op.width) * 8, false);
        try m.movImm64(.rax, if (op.width == 1) 0x00ff00ff00ff00ff else 0x0000ffff0000ffff);
        try m.movQXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
        try m.andPacked128(.xmm0, .xmm2);
        if (op.width == 1) try m.andPacked128(.xmm1, .xmm2);
    }
    try m.addPackedInteger(.xmm0, .xmm1, if (op.width == 1) .half else .word);
}

/// ivdotsat: signed bytes -> saturated i16 pair sums, with SSE2 only.
/// xmm0/xmm1 -> xmm0; xmm2..xmm5 are scratch.
fn emitSimdRelaxedDot(m: *x64.Masm) Error!void {
    try m.xorPacked128(.xmm2, .xmm2);
    try m.compareGreaterSignedPacked(.xmm2, .xmm0, .byte);
    try m.xorPacked128(.xmm3, .xmm3);
    try m.compareGreaterSignedPacked(.xmm3, .xmm1, .byte);
    try m.movVector128(.xmm4, .xmm0);
    try m.movVector128(.xmm5, .xmm1);
    try m.unpackLowPackedInteger(.xmm0, .xmm2, .byte);
    try m.unpackHighPackedInteger(.xmm4, .xmm2, .byte);
    try m.unpackLowPackedInteger(.xmm1, .xmm3, .byte);
    try m.unpackHighPackedInteger(.xmm5, .xmm3, .byte);
    try m.multiplyAddPackedI16(.xmm0, .xmm1);
    try m.multiplyAddPackedI16(.xmm4, .xmm5);
    try m.packSigned32To16(.xmm0, .xmm4);
}

/// xmm0/xmm1 -> xmm0, using xmm2/xmm3 scratch and only SSE2.
fn emitSimdProduct(m: *x64.Masm, op: simd.ProductOp) Error!void {
    if (op.kind == .dot) {
        try m.multiplyAddPackedI16(.xmm0, .xmm1);
        return;
    }
    if (op.kind == .q15) {
        // Reconstruct exact signed i32 products, add the rounding bias,
        // shift arithmetically, then saturate the one positive overflow.
        try m.movVector128(.xmm2, .xmm0);
        try m.multiplyHighPacked16(.xmm2, .xmm1, true);
        try m.multiplyLowPackedI16(.xmm0, .xmm1);
        try m.movVector128(.xmm1, .xmm0);
        try m.unpackLowPackedInteger(.xmm0, .xmm2, .half);
        try m.unpackHighPackedInteger(.xmm1, .xmm2, .half);
        try m.movImm64(.rax, 0x0000400000004000);
        try m.movQXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
        try m.addPackedInteger(.xmm0, .xmm2, .word);
        try m.addPackedInteger(.xmm1, .xmm2, .word);
        try m.shiftRightArithmeticPackedI32(.xmm0, 15);
        try m.shiftRightArithmeticPackedI32(.xmm1, 15);
        try m.packSigned32To16(.xmm0, .xmm1);
        return;
    }
    switch (op.width) {
        1 => {
            const extend: simd.ExtendOp = .{ .width = 1, .signed = op.signed, .high = op.high };
            try m.movVector128(.xmm2, .xmm1);
            try emitSimdExtend(m, extend);
            try m.movVector128(.xmm3, .xmm0);
            try m.movVector128(.xmm0, .xmm2);
            try emitSimdExtend(m, extend);
            try m.multiplyLowPackedI16(.xmm0, .xmm3);
        },
        2 => {
            try m.movVector128(.xmm2, .xmm0);
            try m.multiplyHighPacked16(.xmm2, .xmm1, op.signed);
            try m.multiplyLowPackedI16(.xmm0, .xmm1);
            if (op.high)
                try m.unpackHighPackedInteger(.xmm0, .xmm2, .half)
            else
                try m.unpackLowPackedInteger(.xmm0, .xmm2, .half);
        },
        4 => {
            // Put the selected pair in PMULUDQ's even lanes. For signed
            // inputs, subtract each negative operand's 2^32 correction.
            const order: u8 = if (op.high) 0xfa else 0x50;
            try m.shufflePackedI32(.xmm0, .xmm0, order);
            try m.shufflePackedI32(.xmm1, .xmm1, order);
            if (op.signed) {
                try m.movVector128(.xmm2, .xmm0);
                try m.movVector128(.xmm3, .xmm1);
                try m.shiftRightArithmeticPackedI32(.xmm2, 31);
                try m.shiftRightArithmeticPackedI32(.xmm3, 31);
                try m.andPacked128(.xmm2, .xmm1);
                try m.andPacked128(.xmm3, .xmm0);
                try m.addPackedInteger(.xmm2, .xmm3, .word);
                try m.movImm64(.rax, 32);
                try m.movDXmmFromReg(.xmm3, .rax);
                try m.shiftPackedInteger(.xmm2, .xmm3, .shl64);
            }
            try m.multiplyEvenPackedU32(.xmm0, .xmm1);
            if (op.signed) try m.subtractPackedInteger(.xmm0, .xmm2, .double);
        },
        else => return error.UnsupportedOp,
    }
}

/// Adjacent input Cells start at target. Finish both halves before overwriting
/// either input, so duplicate/reversed selectors cannot observe partial output.
fn emitSimdPermutation(m: *x64.Masm, target: i32, selectors: ?*const [16]u8) Error!void {
    try m.xorReg64(.r8, .r8);
    try m.xorReg64(.r9, .r9);
    if (selectors) |indices| {
        for (indices, 0..) |index, lane| {
            try m.load8Disp32(.rax, .r12, target + index);
            if (lane % 8 != 0) try m.shlImm8(.rax, @intCast((lane % 8) * 8));
            try m.orReg64(if (lane < 8) .r8 else .r9, .rax);
        }
    } else {
        try m.movImm64(.r10, 15);
        try m.xorReg64(.rdx, .rdx);
        try m.leaDisp32(.rdi, .r12, target);
        // Two fixed eight-byte loops bound both work and emitted code size.
        // Fully unrolling this path can exceed the module's code reservation.
        for ([_]x64.Reg{ .r8, .r9 }, 0..) |accumulator, half| {
            try m.leaDisp32(.rsi, .r12, target + 23 + @as(i32, @intCast(half)) * 8);
            try m.movImm64(.rcx, 8);
            var next_byte: x64.Masm.Label = .{};
            defer next_byte.deinit(m.gpa);
            try m.bind(&next_byte);
            try m.shlImm8(accumulator, 8);
            try m.load8Disp32(.rax, .rsi, 0);
            try m.movReg64(.r11, .rax);
            // Mask before the load, not merely before selecting the result:
            // every host address stays inside the 16-byte input Cell.
            try m.andReg64(.rax, .r10);
            try m.addReg64(.rax, .rdi);
            try m.load8Disp32(.rax, .rax, 0);
            try m.cmpReg32Imm32(.r11, 16);
            try m.cmovReg64(.rax, .rdx, .above_or_equal);
            try m.orReg64(accumulator, .rax);
            try m.subRegImm32(.rsi, 1);
            try m.subRegImm32(.rcx, 1);
            try m.jumpCond(.not_equal, &next_byte);
        }
    }
    try m.store64Disp32(.r12, target, .r8);
    try m.store64Disp32(.r12, target + 8, .r9);
}

/// Reuse scalar SSE2 conversions without raising the host ISA requirement.
/// A fixed lane loop keeps dense conversion bodies within the code reserve.
fn emitSimdConversion(m: *x64.Masm, target: i32, op: simd.ConversionOp) Error!void {
    const widening = op.output_width > op.input_width;
    const count: u32 = if (op.input_width == 8 or op.output_width == 8) 2 else 4;
    // Walk widening conversions backwards so stores never clobber unread lanes.
    try m.leaDisp32(.rsi, .r12, target + (if (widening) @as(i32, 4) else 0));
    try m.leaDisp32(.rdi, .r12, target + (if (widening) @as(i32, 8) else 0));
    try m.movImm64(.r8, count);
    var next_lane: x64.Masm.Label = .{};
    defer next_lane.deinit(m.gpa);
    try m.bind(&next_lane);
    if (op.input_width == 4) {
        try m.load32Disp32(.rax, .rsi, 0);
        if (op.kind != .convert) try m.movDXmmFromReg(.xmm0, .rax);
    } else {
        try m.load64Disp32(.rax, .rsi, 0);
        try m.movQXmmFromReg(.xmm0, .rax);
    }
    switch (op.kind) {
        .demote => try m.cvtDoubleToFloat(.xmm0, .xmm0),
        .promote => try m.cvtFloatToDouble(.xmm0, .xmm0),
        .convert => {
            // The zero-extended u32 fits i64: one conversion, one rounding.
            if (op.output_width == 4) {
                if (op.signed) try m.cvtI32ToFloat(.xmm0, .rax) else try m.cvtI64ToFloat(.xmm0, .rax);
            } else {
                if (op.signed) try m.cvtI32ToDouble(.xmm0, .rax) else try m.cvtI64ToDouble(.xmm0, .rax);
            }
        },
        .trunc_sat => {
            if (op.input_width == 4) {
                if (op.signed) try emitTruncSat(m, true, false, true) else try emitTruncSat(m, true, false, false);
            } else {
                if (op.signed) try emitTruncSat(m, false, false, true) else try emitTruncSat(m, false, false, false);
            }
        },
    }
    if (op.kind != .trunc_sat) {
        if (op.output_width == 4) try m.movDRegFromXmm(.rax, .xmm0) else try m.movQRegFromXmm(.rax, .xmm0);
    }
    if (op.output_width == 4) try m.store32Disp32(.rdi, 0, .rax) else try m.store64Disp32(.rdi, 0, .rax);
    if (widening) {
        try m.subRegImm32(.rsi, op.input_width);
        try m.subRegImm32(.rdi, op.output_width);
    } else {
        try m.addRegImm32(.rsi, op.input_width);
        try m.addRegImm32(.rdi, op.output_width);
    }
    try m.subRegImm32(.r8, 1);
    try m.jumpCond(.not_equal, &next_lane);
    if (op.input_width > op.output_width) {
        try m.xorReg64(.rax, .rax);
        try m.store64Disp32(.r12, target + 8, .rax);
    }
}

fn emitSimdFloatArithmetic(m: *x64.Masm, op: simd.FloatArithmeticOp) Error!void {
    if (op.kind == .abs or op.kind == .neg) {
        // Unlike arithmetic, these sign-bit operations preserve signaling
        // NaNs and every payload bit. Apply one mask per f32/f64 lane.
        const sign: u64 = if (op.double_precision) 0x8000000000000000 else 0x8000000080000000;
        try m.movImm64(.rax, if (op.kind == .abs) ~sign else sign);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        if (op.kind == .abs) try m.andPacked128(.xmm0, .xmm1) else try m.xorPacked128(.xmm0, .xmm1);
        return;
    }
    try m.arithmeticPackedFloat128(.xmm0, if (op.kind == .sqrt) .xmm0 else .xmm1, op.double_precision, switch (op.kind) {
        .sqrt => .sqrt,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        else => return error.UnsupportedOp,
    });
}

/// Core integer arithmetic wraps at the lane width; saturating forms clamp.
/// Inputs/output are xmm0/xmm1 -> xmm0, with xmm2/xmm3 scratch (SSE2 only).
fn emitSimdIntegerBinary(m: *x64.Masm, op: simd.IntegerBinaryOp) Error!void {
    if (op.saturating) {
        try m.saturatingAddSubtractPacked128(.xmm0, .xmm1, op.width == 2, op.signed, op.kind == .sub);
        return;
    }
    switch (op.kind) {
        .add => try m.addPackedInteger(.xmm0, .xmm1, switch (op.width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            8 => .double,
            else => return error.UnsupportedOp,
        }),
        .sub => try m.subtractPackedInteger(.xmm0, .xmm1, switch (op.width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            8 => .double,
            else => return error.UnsupportedOp,
        }),
        .mul => {
            if (op.width == 2) {
                try m.multiplyLowPackedI16(.xmm0, .xmm1);
            } else if (op.width == 4) {
                // PMULUDQ multiplies even dwords to qwords. Repeat for odd
                // lanes, then interleave only the low dwords of each product.
                try m.shufflePackedI32(.xmm2, .xmm0, 0xb1);
                try m.shufflePackedI32(.xmm3, .xmm1, 0xb1);
                try m.multiplyEvenPackedU32(.xmm0, .xmm1);
                try m.multiplyEvenPackedU32(.xmm2, .xmm3);
                try m.shufflePackedI32(.xmm0, .xmm0, 0x88);
                try m.shufflePackedI32(.xmm2, .xmm2, 0x88);
                try m.unpackLowPackedInteger(.xmm0, .xmm2, .word);
            } else return error.UnsupportedOp;
        },
    }
}

/// SWAR popcount in each byte. Masks discard bits crossing byte boundaries
/// during the wider PSRLD shifts; no SSSE3 shuffle table is required.
fn emitSimdPopcount(m: *x64.Masm) Error!void {
    // Broadcast dword masks instead of embedding duplicate qword halves;
    // unpadded two-byte popcnt chains must fit the per-byte code reserve.
    for ([_]u32{ 0x55555555, 0x33333333, 0x0f0f0f0f }, 0..) |mask, step| {
        try m.movImm32(.rax, mask);
        try m.movDXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0);
        try m.movVector128(.xmm1, .xmm0);
        try m.shiftRightLogicalPacked128(.xmm1, @as(u8, 1) << @as(u3, @intCast(step)), false);
        if (step < 2) try m.andPacked128(.xmm1, .xmm2);
        if (step == 0) {
            try m.subtractPackedInteger(.xmm0, .xmm1, .byte);
        } else {
            if (step == 1) try m.andPacked128(.xmm0, .xmm2);
            try m.addPackedInteger(.xmm0, .xmm1, .byte);
            if (step == 2) try m.andPacked128(.xmm0, .xmm2);
        }
    }
}

/// Count is rcx; Core requires it modulo the lane width, unlike SSE2's
/// saturating counts. The vector stays in its Cell; rax/rdx/xmm0..2 scratch.
fn emitSimdShift(m: *x64.Masm, op: simd.ShiftOp, target: i32) Error!void {
    try m.movImm64(.rax, @as(u8, op.width) * 8 - 1);
    try m.andReg32(.rcx, .rax);
    if (op.width == 8 and op.kind == .shr_s) {
        for ([_]i32{ 0, 8 }) |half| {
            try m.load64Disp32(.rax, .r12, target + half);
            try m.sarReg64Cl(.rax);
            try m.store64Disp32(.r12, target + half, .rax);
        }
        return;
    }
    try m.loadVector128(.xmm0, .r12, target);
    if (op.width == 1 and op.kind == .shr_s) {
        // Duplicate each byte into both halves of a signed word. A further
        // eight-bit arithmetic shift yields a sign-extended byte for packing.
        try m.movVector128(.xmm1, .xmm0);
        try m.unpackLowPackedInteger(.xmm0, .xmm0, .byte);
        try m.unpackHighPackedInteger(.xmm1, .xmm1, .byte);
        try m.addRegImm32(.rcx, 8);
        try m.movDXmmFromReg(.xmm2, .rcx);
        try m.shiftPackedInteger(.xmm0, .xmm2, .sar16);
        try m.shiftPackedInteger(.xmm1, .xmm2, .sar16);
        try m.packSigned16To8(.xmm0, .xmm1);
    } else {
        try m.movDXmmFromReg(.xmm1, .rcx);
        const shift: x64.Masm.PackedShift = switch (op.kind) {
            .shl => switch (op.width) {
                1, 2 => .shl16,
                4 => .shl32,
                8 => .shl64,
                else => return error.UnsupportedOp,
            },
            .shr_u => switch (op.width) {
                1, 2 => .shr16,
                4 => .shr32,
                8 => .shr64,
                else => return error.UnsupportedOp,
            },
            .shr_s => switch (op.width) {
                2 => .sar16,
                4 => .sar32,
                else => return error.UnsupportedOp,
            },
        };
        try m.shiftPackedInteger(.xmm0, .xmm1, shift);
        if (op.width == 1) {
            // Word shifts are valid byte shifts after masking the bits that
            // spilled across each byte boundary. Broadcast the dynamic mask.
            try m.movImm64(.rax, 0xff);
            if (op.kind == .shl) try m.shlReg32Cl(.rax) else try m.shrReg32Cl(.rax);
            try m.movImm64(.rdx, 0xff);
            try m.andReg32(.rax, .rdx);
            try m.movImm64(.rdx, 0x0101010101010101);
            try m.imulReg64(.rax, .rdx);
            try m.movQXmmFromReg(.xmm2, .rax);
            try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
            try m.andPacked128(.xmm0, .xmm2);
        }
    }
    try m.storeVector128(.r12, target, .xmm0);
}

/// Inputs are xmm0/xmm1; xmm2/xmm3 are scratch. Only SSE2 is required.
fn emitSimdMinMax(m: *x64.Masm, op: simd.MinMaxOp) Error!x64.Xmm {
    if (op.width == 1 and !op.signed) {
        try m.minMaxPacked128(.xmm0, .xmm1, if (op.maximum) .max_u8 else .min_u8);
        return .xmm0;
    }
    if (op.width == 2) {
        if (op.signed) {
            try m.minMaxPacked128(.xmm0, .xmm1, if (op.maximum) .max_i16 else .min_i16);
            return .xmm0;
        }
        // d = saturating_unsigned(a - b): min = a - d, max = b + d.
        // Neither final operation can wrap outside the unsigned lane range.
        try m.movVector128(.xmm2, .xmm0);
        try m.subtractSaturatingPackedU16(.xmm2, .xmm1);
        if (op.maximum) {
            try m.addPackedI16(.xmm1, .xmm2);
            return .xmm1;
        }
        try m.subtractPackedI16(.xmm0, .xmm2);
        return .xmm0;
    }
    const size: x64.Masm.PackedIntSize = switch (op.width) {
        1 => .byte,
        4 => .word,
        else => return error.UnsupportedOp,
    };
    // The mask selects b when a > b for min, or when b > a for max.
    try m.movVector128(.xmm2, if (op.maximum) .xmm1 else .xmm0);
    try m.compareGreaterSignedPacked(.xmm2, if (op.maximum) .xmm0 else .xmm1, size);
    if (!op.signed) {
        // Unsigned ordering differs from signed ordering exactly when the
        // sign bits differ. Broadcast that difference and flip the mask.
        try m.movVector128(.xmm3, .xmm0);
        try m.xorPacked128(.xmm3, .xmm1);
        try m.shiftRightArithmeticPackedI32(.xmm3, 31);
        try m.xorPacked128(.xmm2, .xmm3);
    }
    try m.xorPacked128(.xmm1, .xmm0);
    try m.andPacked128(.xmm1, .xmm2);
    try m.xorPacked128(.xmm0, .xmm1); // a ^ ((a ^ b) & mask)
    return .xmm0;
}

/// Input is xmm0; xmm1 is scratch. Core iabs/ineg wrap at the lane width.
fn emitSimdIntegerUnary(m: *x64.Masm, op: simd.IntegerUnaryOp) Error!x64.Xmm {
    const size: x64.Masm.PackedSubtractSize = switch (op.width) {
        1 => .byte,
        2 => .half,
        4 => .word,
        8 => .double,
        else => return error.UnsupportedOp,
    };
    if (op.negate) {
        try m.xorPacked128(.xmm1, .xmm1);
        try m.subtractPackedInteger(.xmm1, .xmm0, size);
        return .xmm1;
    }
    if (op.width == 8) {
        // Duplicate each qword's high dword, then broadcast its sign bit.
        // The low dword's sign must not affect the 64-bit lane's mask.
        try m.shufflePackedI32(.xmm1, .xmm0, 0xf5);
        try m.shiftRightArithmeticPackedI32(.xmm1, 31);
    } else {
        try m.xorPacked128(.xmm1, .xmm1);
        try m.compareGreaterSignedPacked(.xmm1, .xmm0, if (op.width == 1) .byte else if (op.width == 2) .half else .word);
    }
    // (x ^ sign_mask) - sign_mask, including the unchanged signed minimum.
    try m.xorPacked128(.xmm0, .xmm1);
    try m.subtractPackedInteger(.xmm0, .xmm1, size);
    return .xmm0;
}

/// Inputs are xmm0/xmm1; xmm2/xmm3 are scratch; the result is xmm2.
fn emitSimdFloatMinMax(m: *x64.Masm, op: simd.FloatMinMaxOp) Error!void {
    // Core fmin/fmax: SSE picks its second operand on NaN or equal zeros.
    // Save the NaN mask before combining both orders for signed-zero ties.
    try m.movVector128(.xmm2, .xmm0);
    try m.compareUnorderedPackedFloat128(.xmm2, .xmm1, op.double_precision);
    try m.movVector128(.xmm3, .xmm0);
    try m.minMaxPackedFloat128(.xmm3, .xmm1, op.double_precision, op.maximum);
    try m.minMaxPackedFloat128(.xmm1, .xmm0, op.double_precision, op.maximum);
    if (op.maximum)
        try m.andPacked128(.xmm3, .xmm1)
    else
        try m.orPacked128(.xmm3, .xmm1);
    // NaN lanes become all ones, then clear their payload below the quiet
    // bit. Ordered lanes have a zero mask and remain bit-exact, including
    // subnormals. The resulting negative canonical NaN is allowed by Core.
    try m.orPacked128(.xmm3, .xmm2);
    try m.shiftRightLogicalPacked128(.xmm2, if (op.double_precision) 13 else 10, op.double_precision);
    try m.andNotPacked128(.xmm2, .xmm3);
}

fn materialize(m: *x64.Masm, loc: Loc, num_locals: usize, depth: usize) Error!void {
    switch (loc) {
        .runtime, .v128 => {},
        .const_i32 => |value| {
            try m.movImm64(.rax, @as(u32, @bitCast(value)));
            try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
        },
        .const_i64 => |value| {
            try m.movImm64(.rax, @bitCast(value));
            try m.store64Disp32(.r12, scratchOffset(num_locals, depth), .rax);
        },
        .ref_null, .ref_func, .ref => try emitRefIntoSlot(m, loc, num_locals, depth),
    }
}

/// Ensure the reference operand's 16-byte home Cell contains its complete
/// runtime representation. A `table.get` result is already there; folded
/// references are materialized as either all-ones null or the function index
/// paired with this body's defining instance.
fn emitRefIntoSlot(m: *x64.Masm, loc: Loc, num_locals: usize, depth: usize) Error!void {
    const off = scratchOffset(num_locals, depth);
    switch (loc) {
        .ref => {},
        .ref_func => |function_index| {
            try m.movImm64(.rax, function_index);
            try m.store64Disp32(.r12, off, .rax);
            try m.load64Disp32(.rax, .rsp, 0);
            try m.store64Disp32(.r12, off + 8, .rax);
        },
        .ref_null => {
            try m.movImm64(.rax, std.math.maxInt(u64));
            try m.store64Disp32(.r12, off, .rax);
            try m.store64Disp32(.r12, off + 8, .rax);
        },
        .const_i32, .const_i64, .runtime, .v128 => return error.UnsupportedOp,
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
        stack[depth] = stack[depth].materialized();
    }
    return true;
}

/// Copy the top `arity` operands into a structured target's canonical Cell
/// depths, discarding any intervening values. Destination depths are never
/// above their corresponding sources, so the forward copy is overlap-safe.
/// Stack metadata is intentionally unchanged: conditional branches emit this
/// only on the taken machine path, while compilation continues down the
/// not-taken path with its original constants and locations.
fn emitBranchValues(
    m: *x64.Masm,
    stack: []const Loc,
    num_locals: usize,
    sp: usize,
    target_height: usize,
    arity: u32,
) Error!bool {
    const count: usize = arity;
    if (sp > stack.len or sp < count) return false;
    const source_start = sp - count;
    if (target_height > source_start) return false;
    const target_end = std.math.add(usize, target_height, count) catch return false;
    if (target_end > stack.len) return false;

    var value_index: usize = 0;
    while (value_index < count) : (value_index += 1) {
        const source_depth = source_start + value_index;
        const target_depth = target_height + value_index;
        try materialize(m, stack[source_depth], num_locals, source_depth);
        if (source_depth == target_depth) continue;
        try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, source_depth));
        try m.store64Disp32(.r12, scratchOffset(num_locals, target_depth), .rax);
        if (stack[source_depth].isWide()) {
            try m.load64Disp32(.rax, .r12, scratchOffset(num_locals, source_depth) + 8);
            try m.store64Disp32(.r12, scratchOffset(num_locals, target_depth) + 8, .rax);
        }
    }
    return true;
}

fn roundF32Bits(bits: u32, mode: u32) callconv(.c) u32 {
    return @bitCast(float_ops.round(f32, @bitCast(bits), @enumFromInt(mode)));
}

fn roundF64Bits(bits: u64, mode: u32) callconv(.c) u64 {
    return @bitCast(float_ops.round(f64, @bitCast(bits), @enumFromInt(mode)));
}

/// Emit a §4.3.3 trapping float-to-int truncation. The operand enters in
/// xmm0. NaN has its own trap; finite values outside the operation's exact
/// half-open input interval use the integer-overflow trap. Only then is CVTT's
/// otherwise ambiguous integer-indefinite result safe to consume.
fn emitTruncTrap(
    m: *x64.Masm,
    comptime src_f32: bool,
    comptime to_i64: bool,
    comptime signed: bool,
    comptime lo: f64,
    comptime lo_inclusive: bool,
    comptime hi: f64,
    invalid: *x64.Masm.Label,
    overflow: *x64.Masm.Label,
) Error!void {
    const lo_bits: u64 = if (src_f32)
        @as(u32, @bitCast(@as(f32, @floatCast(lo))))
    else
        @bitCast(lo);
    const hi_bits: u64 = if (src_f32)
        @as(u32, @bitCast(@as(f32, @floatCast(hi))))
    else
        @bitCast(hi);

    if (src_f32)
        try m.ucomisFloat(.xmm0, .xmm0)
    else
        try m.ucomisDouble(.xmm0, .xmm0);
    try m.jumpCond(.parity, invalid);

    try m.movImm64(.r10, lo_bits);
    if (src_f32) {
        try m.movDXmmFromReg(.xmm1, .r10);
        try m.ucomisFloat(.xmm0, .xmm1);
    } else {
        try m.movQXmmFromReg(.xmm1, .r10);
        try m.ucomisDouble(.xmm0, .xmm1);
    }
    try m.jumpCond(if (lo_inclusive) .below else .below_or_equal, overflow);

    try m.movImm64(.r10, hi_bits);
    if (src_f32) {
        try m.movDXmmFromReg(.xmm1, .r10);
        try m.ucomisFloat(.xmm0, .xmm1);
    } else {
        try m.movQXmmFromReg(.xmm1, .r10);
        try m.ucomisDouble(.xmm0, .xmm1);
    }
    try m.jumpCond(.above_or_equal, overflow);

    try emitInRangeFloatToInt(m, src_f32, to_i64, signed);
}

/// Emit a non-trapping saturating float-to-int conversion. The source enters
/// in xmm0 and the exact integer bits leave in rax.
fn emitTruncSat(
    m: *x64.Masm,
    comptime src_f32: bool,
    comptime to_i64: bool,
    comptime signed: bool,
) Error!void {
    const lo: f64 = if (signed)
        (if (to_i64) -9223372036854775808.0 else -2147483648.0)
    else
        0.0;
    const hi: f64 = if (to_i64)
        (if (signed) 9223372036854775808.0 else 18446744073709551616.0)
    else
        (if (signed) 2147483648.0 else 4294967296.0);
    const lo_bits: u64 = if (src_f32)
        @as(u32, @bitCast(@as(f32, @floatCast(lo))))
    else
        @bitCast(lo);
    const hi_bits: u64 = if (src_f32)
        @as(u32, @bitCast(@as(f32, @floatCast(hi))))
    else
        @bitCast(hi);
    const min_result: u64 = if (!signed) 0 else if (to_i64) 0x8000_0000_0000_0000 else 0x8000_0000;
    const max_result: u64 = if (to_i64)
        (if (signed) 0x7fff_ffff_ffff_ffff else 0xffff_ffff_ffff_ffff)
    else
        (if (signed) 0x7fff_ffff else 0xffff_ffff);

    var nan: x64.Masm.Label = .{};
    var clamp_low: x64.Masm.Label = .{};
    var clamp_high: x64.Masm.Label = .{};
    var done: x64.Masm.Label = .{};
    defer nan.deinit(m.gpa);
    defer clamp_low.deinit(m.gpa);
    defer clamp_high.deinit(m.gpa);
    defer done.deinit(m.gpa);

    if (src_f32)
        try m.ucomisFloat(.xmm0, .xmm0)
    else
        try m.ucomisDouble(.xmm0, .xmm0);
    try m.jumpCond(.parity, &nan);

    try m.movImm64(.r10, lo_bits);
    if (src_f32) {
        try m.movDXmmFromReg(.xmm1, .r10);
        try m.ucomisFloat(.xmm0, .xmm1);
    } else {
        try m.movQXmmFromReg(.xmm1, .r10);
        try m.ucomisDouble(.xmm0, .xmm1);
    }
    try m.jumpCond(.below_or_equal, &clamp_low);

    try m.movImm64(.r10, hi_bits);
    if (src_f32) {
        try m.movDXmmFromReg(.xmm1, .r10);
        try m.ucomisFloat(.xmm0, .xmm1);
    } else {
        try m.movQXmmFromReg(.xmm1, .r10);
        try m.ucomisDouble(.xmm0, .xmm1);
    }
    try m.jumpCond(.above_or_equal, &clamp_high);

    try emitInRangeFloatToInt(m, src_f32, to_i64, signed);
    try m.jump(&done);

    try m.bind(&nan);
    try m.movImm64(.rax, 0);
    try m.jump(&done);
    try m.bind(&clamp_low);
    try m.movImm64(.rax, min_result);
    try m.jump(&done);
    try m.bind(&clamp_high);
    try m.movImm64(.rax, max_result);
    try m.bind(&done);
}

fn emitInRangeFloatToInt(
    m: *x64.Masm,
    comptime src_f32: bool,
    comptime to_i64: bool,
    comptime signed: bool,
) Error!void {
    if (signed) {
        if (src_f32) {
            if (to_i64)
                try m.cvttFloatToI64(.rax, .xmm0)
            else
                try m.cvttFloatToI32(.rax, .xmm0);
        } else {
            if (to_i64)
                try m.cvttDoubleToI64(.rax, .xmm0)
            else
                try m.cvttDoubleToI32(.rax, .xmm0);
        }
    } else if (to_i64) {
        try emitTruncFloatToU64(m, src_f32);
    } else if (src_f32) {
        // Every valid u32 result fits a signed i64 conversion.
        try m.cvttFloatToI64(.rax, .xmm0);
    } else {
        try m.cvttDoubleToI64(.rax, .xmm0);
    }
}

/// x86_64 has no baseline scalar float-to-u64 conversion. Values below 2^63
/// use CVTT directly; the high half converts `value - 2^63` and restores the
/// top bit. `emitTruncTrap` has already excluded NaN and values outside u64.
fn emitTruncFloatToU64(m: *x64.Masm, comptime src_f32: bool) Error!void {
    const two63_bits: u64 = if (src_f32)
        @as(u32, @bitCast(@as(f32, 9223372036854775808.0)))
    else
        @bitCast(@as(f64, 9223372036854775808.0));
    var low_half: x64.Masm.Label = .{};
    var done: x64.Masm.Label = .{};
    defer low_half.deinit(m.gpa);
    defer done.deinit(m.gpa);

    try m.movImm64(.r10, two63_bits);
    if (src_f32) {
        try m.movDXmmFromReg(.xmm1, .r10);
        try m.ucomisFloat(.xmm0, .xmm1);
    } else {
        try m.movQXmmFromReg(.xmm1, .r10);
        try m.ucomisDouble(.xmm0, .xmm1);
    }
    try m.jumpCond(.below, &low_half);

    if (src_f32) {
        try m.subFloat(.xmm0, .xmm1);
        try m.cvttFloatToI64(.rax, .xmm0);
    } else {
        try m.subDouble(.xmm0, .xmm1);
        try m.cvttDoubleToI64(.rax, .xmm0);
    }
    try m.movImm64(.r10, 0x8000_0000_0000_0000);
    try m.orReg64(.rax, .r10);
    try m.jump(&done);

    try m.bind(&low_half);
    if (src_f32)
        try m.cvttFloatToI64(.rax, .xmm0)
    else
        try m.cvttDoubleToI64(.rax, .xmm0);
    try m.bind(&done);
}

/// SSE2 has signed i64-to-float conversion only. For values in the unsigned
/// high half, convert `(value >> 1) | (value & 1)` and double the result; this
/// is the standard correctly-rounded lowering used by baseline wasm engines.
/// Enters with the u64 in rax and leaves the result in xmm0.
fn emitConvertU64ToFloat(m: *x64.Masm, output_f32: bool) Error!void {
    var low_half: x64.Masm.Label = .{};
    var done: x64.Masm.Label = .{};
    defer low_half.deinit(m.gpa);
    defer done.deinit(m.gpa);

    try m.testReg64(.rax, .rax);
    try m.jumpCond(.not_sign, &low_half);
    try m.movReg64(.rcx, .rax);
    try m.shrImm8(.rax, 1);
    try m.movImm64(.r10, 1);
    try m.andReg64(.rcx, .r10);
    try m.orReg64(.rax, .rcx);
    if (output_f32) {
        try m.cvtI64ToFloat(.xmm0, .rax);
        try m.addFloat(.xmm0, .xmm0);
    } else {
        try m.cvtI64ToDouble(.xmm0, .rax);
        try m.addDouble(.xmm0, .xmm0);
    }
    try m.jump(&done);

    try m.bind(&low_half);
    if (output_f32)
        try m.cvtI64ToFloat(.xmm0, .rax)
    else
        try m.cvtI64ToDouble(.xmm0, .rax);
    try m.bind(&done);
}

/// Lower clz/ctz from baseline BSF/BSR while preserving Wasm's defined zero
/// result. Both x86 instructions leave the destination undefined for zero.
fn emitBitScanCount(
    m: *x64.Masm,
    comptime wide: bool,
    comptime leading: bool,
) Error!void {
    var zero: x64.Masm.Label = .{};
    var done: x64.Masm.Label = .{};
    defer zero.deinit(m.gpa);
    defer done.deinit(m.gpa);

    if (wide)
        try m.cmpRegImm32(.rax, 0)
    else
        try m.cmpReg32Imm32(.rax, 0);
    try m.jumpCond(.equal, &zero);

    if (wide) {
        if (leading)
            try m.bitScanReverse64(.rax, .rax)
        else
            try m.bitScanForward64(.rax, .rax);
    } else {
        if (leading)
            try m.bitScanReverse32(.rax, .rax)
        else
            try m.bitScanForward32(.rax, .rax);
    }
    if (leading) {
        try m.movImm64(.rcx, if (wide) 63 else 31);
        try subScalar(m, wide, .rcx, .rax);
        try moveScalar(m, wide, .rax, .rcx);
    }
    try m.jump(&done);

    try m.bind(&zero);
    try m.movImm64(.rax, if (wide) 64 else 32);
    try m.bind(&done);
}

/// Branch-free SWAR population count. Native POPCNT is not part of Cynic's
/// baseline x86_64 contract, so the JIT must not emit it without a feature
/// guard. Input and output are in rax; rcx/r10/r11 are scratch.
fn emitPopcnt(m: *x64.Masm, comptime wide: bool) Error!void {
    try moveScalar(m, wide, .r10, .rax);
    try shiftRightScalar(m, wide, .r10, 1);
    try m.movImm64(.r11, if (wide) 0x5555_5555_5555_5555 else 0x5555_5555);
    try andScalar(m, wide, .r10, .r11);
    try subScalar(m, wide, .rax, .r10);

    try moveScalar(m, wide, .r10, .rax);
    try shiftRightScalar(m, wide, .r10, 2);
    try m.movImm64(.r11, if (wide) 0x3333_3333_3333_3333 else 0x3333_3333);
    try andScalar(m, wide, .rax, .r11);
    try andScalar(m, wide, .r10, .r11);
    try addScalar(m, wide, .rax, .r10);

    try moveScalar(m, wide, .r10, .rax);
    try shiftRightScalar(m, wide, .r10, 4);
    try addScalar(m, wide, .rax, .r10);
    try m.movImm64(.r11, if (wide) 0x0f0f_0f0f_0f0f_0f0f else 0x0f0f_0f0f);
    try andScalar(m, wide, .rax, .r11);

    try moveScalar(m, wide, .r10, .rax);
    try shiftRightScalar(m, wide, .r10, 8);
    try addScalar(m, wide, .rax, .r10);
    try moveScalar(m, wide, .r10, .rax);
    try shiftRightScalar(m, wide, .r10, 16);
    try addScalar(m, wide, .rax, .r10);
    if (wide) {
        try moveScalar(m, true, .r10, .rax);
        try shiftRightScalar(m, true, .r10, 32);
        try addScalar(m, true, .rax, .r10);
    }

    try m.movImm64(.r11, if (wide) 0x7f else 0x3f);
    try andScalar(m, wide, .rax, .r11);
}

fn moveScalar(m: *x64.Masm, comptime wide: bool, destination: x64.Reg, source: x64.Reg) Error!void {
    if (wide)
        try m.movReg64(destination, source)
    else
        try m.movReg32(destination, source);
}

fn addScalar(m: *x64.Masm, comptime wide: bool, destination: x64.Reg, source: x64.Reg) Error!void {
    if (wide)
        try m.addReg64(destination, source)
    else
        try m.addReg32(destination, source);
}

fn subScalar(m: *x64.Masm, comptime wide: bool, destination: x64.Reg, source: x64.Reg) Error!void {
    if (wide)
        try m.subReg64(destination, source)
    else
        try m.subReg32(destination, source);
}

fn andScalar(m: *x64.Masm, comptime wide: bool, destination: x64.Reg, source: x64.Reg) Error!void {
    if (wide)
        try m.andReg64(destination, source)
    else
        try m.andReg32(destination, source);
}

fn shiftRightScalar(m: *x64.Masm, comptime wide: bool, destination: x64.Reg, amount: u8) Error!void {
    try m.movImm64(.rcx, amount);
    if (wide)
        try m.shrReg64Cl(destination)
    else
        try m.shrReg32Cl(destination);
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
    if (config.diagnostics) |diagnostics| {
        const preserve_subopcode = diagnostics.has_subopcode and diagnostics.opcode == opcode;
        const subopcode = diagnostics.subopcode;
        diagnostics.* = .{
            .stage = stage,
            .opcode = opcode,
            .has_opcode = stage == .bytecode or stage == .unsupported_opcode,
            .subopcode = if (preserve_subopcode) subopcode else 0,
            .has_subopcode = preserve_subopcode,
        };
    }
    return null;
}

fn refuseSignature(config: Config, value_type: ValType) ?[]const u8 {
    _ = refuse(config, .signature, 0);
    if (config.diagnostics) |diagnostics| diagnostics.signature_type = value_type;
    return null;
}

fn isScalar(value_type: ValType) bool {
    return value_type == .i32 or value_type == .i64 or value_type == .f32 or value_type == .f64;
}

fn isSupportedValue(value_type: ValType) bool {
    return isScalar(value_type) or isWideValue(value_type);
}

fn isWideValue(value_type: ValType) bool {
    return value_type.isRef() or value_type == .v128;
}

fn runtimeLoc(value_type: ValType) Loc {
    return if (value_type.isRef()) .ref else if (value_type == .v128) .v128 else .runtime;
}

/// Use a fresh view for a nonzero memory while retaining the cached r14/r15
/// pair for memory zero. The helper cannot allocate or re-enter Wasm/JS.
fn emitIndexedMemAddress(
    m: *x64.Masm,
    access: metadata.MemoryAccess,
    width: u32,
    address_slot: i32,
    mem_view_helper: ?usize,
    trap_oob: *x64.Masm.Label,
) Error!bool {
    const view = (try emitMemoryView(m, access.index, mem_view_helper)) orelse return false;
    if (access.memory64)
        try m.load64Disp32(.r10, .r12, address_slot)
    else
        try m.load32Disp32(.r10, .r12, address_slot);
    try emitMemAddressForView(m, access.offset, width, access.memory64, view.base, view.length, trap_oob);
    return true;
}

const MemoryView = struct { base: x64.Reg, length: x64.Reg };

fn emitMemoryView(m: *x64.Masm, index: u32, mem_view_helper: ?usize) Error!?MemoryView {
    if (index != 0) {
        const helper = mem_view_helper orelse return null;
        try m.subRegImm32(.rsp, 16);
        try m.load64Disp32(.rdi, .rsp, 16); // instance in the entry frame
        try m.movImm64(.rsi, index);
        try m.leaDisp32(.rdx, .rsp, 0);
        try m.movImm64(.r11, helper);
        try m.callReg(.r11);
        try m.load64Disp32(.r8, .rsp, 0);
        try m.load64Disp32(.rcx, .rsp, 8);
        // Restore the ordinary frame before any bounds-check trap edge.
        try m.addRegImm32(.rsp, 16);
    }
    return .{ .base = if (index == 0) .r14 else .r8, .length = if (index == 0) .r15 else .rcx };
}

/// §4.4.7 effective address and explicit software bounds check. Memory32
/// addresses arrive zero-extended; memory64 addresses and static offsets can
/// span all of u64, so the add's carry traps before a wrapped effective
/// address can pass the length check. r10 enters as the dynamic address; r11
/// returns as the host pointer. r9 is scratch. Host faults are never part of
/// the trap contract.
fn emitMemAddressForView(
    m: *x64.Masm,
    offset: u64,
    width: u32,
    memory64: bool,
    base: x64.Reg,
    length: x64.Reg,
    trap_oob: *x64.Masm.Label,
) Error!void {
    try m.movImm64(.r11, offset);
    try m.addReg64(.r10, .r11);
    if (memory64) try m.jumpCond(.below, trap_oob); // address + offset wrapped
    try m.cmpReg64(.r10, length);
    try m.jumpCond(.above, trap_oob);
    try m.movReg64(.r9, length);
    try m.subReg64(.r9, .r10);
    try m.cmpRegImm32(.r9, width);
    try m.jumpCond(.below, trap_oob);
    try m.movReg64(.r11, base);
    try m.addReg64(.r11, .r10);
}

/// Bounds-check `[offset, offset + count)` without overflow by comparing the
/// count against `mem_len - offset` only after proving offset <= mem_len.
fn emitRangeBounds(
    m: *x64.Masm,
    offset: x64.Reg,
    count: x64.Reg,
    length: x64.Reg,
    trap_oob: *x64.Masm.Label,
) Error!void {
    try m.cmpReg64(offset, length);
    try m.jumpCond(.above, trap_oob);
    try m.movReg64(.r10, length);
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
    for (callee.func.local_types) |local_type| if (!isSupportedValue(local_type)) return null;
    const offset = std.math.mul(usize, callee.local_index, config.call_gate_stride) catch return null;
    return std.math.add(usize, base, offset) catch null;
}

fn readSupportedValType(body: []const u8, index: *usize) ?ValType {
    var reader: Reader = .{ .bytes = body, .pos = index.* };
    const value_type = @import("types.zig").readValType(&reader) catch return null;
    if (!isSupportedValue(value_type)) return null;
    index.* = reader.pos;
    return value_type;
}

const BlockResult = struct { arity: u32, loc: Loc = .runtime };

fn readBlockResult(body: []const u8, index: *usize) ?BlockResult {
    if (index.* >= body.len) return null;
    if (body[index.*] == 0x40) {
        index.* += 1;
        return .{ .arity = 0 };
    }
    const value_type = readSupportedValType(body, index) orelse return null;
    return .{ .arity = 1, .loc = runtimeLoc(value_type) };
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

fn readF32Bits(body: []const u8, index: *usize) ?u32 {
    if (index.* > body.len or body.len - index.* < @sizeOf(u32)) return null;
    const bits = std.mem.readInt(u32, body[index.*..][0..@sizeOf(u32)], .little);
    index.* += @sizeOf(u32);
    return bits;
}

fn readF64Bits(body: []const u8, index: *usize) ?u64 {
    if (index.* > body.len or body.len - index.* < @sizeOf(u64)) return null;
    const bits = std.mem.readInt(u64, body[index.*..][0..@sizeOf(u64)], .little);
    index.* += @sizeOf(u64);
    return bits;
}
