//! AST → bytecode compiler statements + lexical scope.
//!
//! Walks `Statement` and `Expression` AST and emits Ignition-style
//! bytecode into a `Builder`. The result of every expression
//! lands in the accumulator.
//!
//! Register layout (single frame, later):
//! 0..bindings_top — binding slots (`var` / `let` / `const`).
//! Allocated by `declareBinding`; never
//! reused within a chunk.
//! bindings_top.. — temp slots used during expression
//! compilation. Reserved bottom-up via
//! `reserveTemp`, released top-down via
//! `releaseTemp`. The high-water mark sets
//! `Builder.register_count`.
//!
//! Entry points:
//! • `compileExpressionAsChunk` — single expression → chunk
//! (used by `cynic eval`).
//! • `compileScriptAsChunk` — full Script → chunk (used by
//! `cynic run`).
//!
//! Convention for binary opcodes: the LHS is materialised into a
//! register first, the RHS is computed into the accumulator, then
//! `<Op> <reg>` runs `acc = reg <op> acc`. Same shape Ignition
//! uses for its `BinaryOp`s. (Pure-stack designs would push/push/
//! op, but at the cost of dispatch density — see
//! [docs/handbook/compiler-engineering.md].)
//!
//! Numeric literal parsing handles decimal integers + fractions,
//! plus 0x / 0o / 0b radix forms (§12.8.3). Strict mode forbids
//! legacy octal (`0755`) — already rejected upstream by the
//! lexer (`legacy_octal_in_strict`), so this path doesn't need to.

const std = @import("std");

const ast = @import("../ast.zig");
const Expression = ast.expression.Expression;
const Statement = ast.statement.Statement;
const BinaryOp = ast.expression.BinaryOp;
const UnaryOp = ast.expression.UnaryOp;
const LogicalOp = ast.expression.LogicalOp;
const AssignmentOp = ast.expression.AssignmentOp;

const Span = @import("../source.zig").Span;
const Op = @import("op.zig").Op;
const Builder = @import("chunk.zig").Builder;
const Chunk = @import("chunk.zig").Chunk;
const Handler = @import("chunk.zig").Handler;
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;
const Binding = scope_mod.Binding;
const BindingKind = scope_mod.BindingKind;
const Value = @import("../runtime/value.zig").Value;
const Realm = @import("../runtime/realm.zig").Realm;
const heap_mod = @import("../runtime/heap.zig");
const Code = @import("../diagnostic.zig").Code;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Diagnostics = @import("../diagnostic.zig").Diagnostics;

const literals = @import("literals.zig");
const asExactSmi = literals.asExactSmi;
const parseNumericLiteral = literals.parseNumericLiteral;
const parseBigIntLiteral = literals.parseBigIntLiteral;
const decodeStringContent = literals.decodeStringContent;

const arguments_scan = @import("arguments_scan.zig");
const referencesArguments = arguments_scan.referencesArguments;

pub const CompileError = error{
    OutOfMemory,
    TooManyRegisters,
    TooManyConstants,
    TooManyFunctions,
    TooManyClasses,
    JumpTooFar,
    /// A statement or expression that is well-formed at parse
    /// time but not yet implementable — e.g. later doesn't compile
    /// templates, regex bodies, BigInt, functions/calls, or
    /// objects. Callers can show the user "not supported yet".
    UnsupportedExpression,
    UnsupportedStatement,
    /// A numeric literal whose source text we couldn't parse.
    /// In practice this should be unreachable — the lexer
    /// already gates literal shape — but we surface it instead
    /// of crashing.
    BadNumericLiteral,
    /// `let`/`const` already declared in this scope (§13.3.1
    /// duplicate). Diagnostic emitted; bytecode construction
    /// stops because the chunk is no longer well-formed.
    DuplicateBinding,
    /// Identifier reference that doesn't resolve to any in-scope
    /// binding. later has no globals yet, so any unbound name is
    /// an error; later will replace this with `LdaGlobal`.
    UnresolvedReference,
    /// Assignment target evaluates to a `const` binding.
    AssignmentToConst,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
    builder: Builder,
    /// Optional sink for compile-time diagnostics. When `null`,
    /// errors still propagate via `CompileError` — the sink
    /// records the offending span / code for the test262 harness
    /// and the CLI.
    diagnostics: ?*Diagnostics = null,

    /// Innermost open scope. `null` only between `init` and the
    /// first `pushScope` (in practice always set during compile,
    /// since every entry point opens a scope first).
    scope: ?*Scope = null,
    /// Slot count of the *current* function-like scope's env.
    /// `declareBinding` allocates the next slot from here. Reset
    /// (saved/restored) at every function-template entry/exit.
    /// At the end of a function body the count is patched into
    /// the leading `MakeEnvironment` instruction so the runtime
    /// allocates the right number of slots.
    env_slot_count: u8 = 0,
    /// Function-like nesting depth. Script body = 0, top-level
    /// function = 1, nested function = 2, etc. Used to compute
    /// the `depth` operand of `LdaEnv` / `StaEnv` from the
    /// difference with the binding's recorded `env_depth`.
    env_depth: u8 = 0,
    /// Anonymous temp registers in use during expression
    /// evaluation. Independent of the env-based named bindings.
    temps_in_use: u8 = 0,
    /// Per-realm-build counter that gives each class a unique
    /// integer suffix for its private-name prefix. Two unrelated
    /// classes that both declare `#x` get keys `"P0#x"` and
    /// `"P1#x"` so their `private_properties` slots don't collide.
    class_uid_counter: u32 = 0,
    /// Stack of active class-compilation contexts. Pushed on
    /// entering a class body, popped on exit. The top frame
    /// gives the per-class `private_prefix` used to mangle
    /// `#name` references inside method bodies / field
    /// initializers.
    class_stack: std.ArrayListUnmanaged(ClassContext) = .empty,
    /// Innermost active loop. `break` / `continue` look up here
    /// to find their patch lists / continue target. Nesting is
    /// handled by save/restore in each loop's compile routine.
    current_loop: ?*LoopContext = null,
    /// True when compiling a module body. Toggles
    /// whether `import` declarations emit `module_load` ops and
    /// whether `export` declarations emit `module_export` ops.
    /// `false` for scripts and inline-test compiles, where
    /// import/export still parse but compile as no-ops.
    is_module: bool = false,
    /// §13.5.5 Optional-chain context — patch sites for
    /// `jmp_if_nullish` instructions emitted at `?.` boundaries.
    /// Non-null only while compiling inside a `chain` AST node;
    /// each entry is the position of an i16 placeholder that
    /// `compileChain` rewrites to point at the chain's
    /// short-circuit `lda_undefined` block.
    chain_patches: ?*std.ArrayListUnmanaged(u32) = null,
    /// §14.15 — stack of active `try { … } finally { F }` blocks.
    /// `return` walks the stack from inner to outer, inlining
    /// each `F` before emitting `return_`. Function entry resets
    /// the stack to `null` so a `return` inside a function inside
    /// an outer try-finally doesn't run the outer finally.
    finally_chain: ?*FinallyContext = null,

    pub fn init(allocator: std.mem.Allocator, realm: *Realm, source: []const u8) Compiler {
        return .{
            .allocator = allocator,
            .realm = realm,
            .source = source,
            .builder = Builder.init(allocator),
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.builder.deinit();
    }

    pub fn finish(self: *Compiler) !Chunk {
        return self.builder.finish();
    }

    fn report(self: *Compiler, code: Code, span: Span) CompileError!void {
        if (self.diagnostics) |sink| {
            try sink.append(self.allocator, .{
                .severity = .err,
                .code = code,
                .span = span,
            });
        }
    }

    // ── Register / env-slot allocation ──────────────────────────────────

    /// Reserve a temp register for an anonymous expression
    /// intermediate. Temps share the register file with no other
    /// users later (named bindings now live in env slots).
    fn reserveTemp(self: *Compiler) !u8 {
        if (self.temps_in_use == std.math.maxInt(u8)) return error.TooManyRegisters;
        const r = self.temps_in_use;
        self.temps_in_use += 1;
        if (self.temps_in_use > self.builder.register_count) {
            self.builder.register_count = self.temps_in_use;
        }
        return r;
    }

    fn releaseTemp(self: *Compiler) void {
        std.debug.assert(self.temps_in_use > 0);
        self.temps_in_use -= 1;
    }

    /// Allocate the next env slot for the current function-like
    /// scope. Bumps the per-function counter; the function's
    /// leading `MakeEnvironment` instruction is patched with the
    /// final count once compilation completes.
    fn newEnvSlot(self: *Compiler) !u8 {
        if (self.env_slot_count == std.math.maxInt(u8)) return error.TooManyRegisters;
        const s = self.env_slot_count;
        self.env_slot_count += 1;
        return s;
    }

    // ── Scope helpers ───────────────────────────────────────────────────

    /// Declare a binding in the current scope. Returns its
    /// register. Duplicate `let`/`const` in the same scope
    /// emits `unexpected_token` and yields `DuplicateBinding`.
    /// `var` redeclaration in the same function-like scope is
    /// silently merged (§13.3.2), reusing the existing register.
    fn declareBinding(
        self: *Compiler,
        name: []const u8,
        kind: BindingKind,
        span: Span,
    ) CompileError!u8 {
        const b = try self.declareBindingFull(name, kind, span);
        return b.env_slot;
    }

    /// Declare a binding and return the full `Binding` record —
    /// the call site can hand this directly to `emitStoreBinding`
    /// without re-resolving by name. Used by declarations that
    /// initialise the binding immediately after declaring it
    /// (function / class declarations, `var x = e`, etc.).
    fn declareBindingFull(
        self: *Compiler,
        name: []const u8,
        kind: BindingKind,
        span: Span,
    ) CompileError!Binding {
        const target = if (kind == .var_) self.functionScope() else self.scope.?;
        if (target.lookupLocal(name)) |existing| {
            switch (kind) {
                .var_ => switch (existing.kind) {
                    .var_ => return existing, // §13.3.2 merge
                    .let_, .const_ => {
                        try self.report(.unexpected_token, span);
                        return error.DuplicateBinding;
                    },
                },
                .let_, .const_ => {
                    try self.report(.unexpected_token, span);
                    return error.DuplicateBinding;
                },
            }
        }
        // top-level Script bindings (`var` / `let` /
        // `const` / `function`) live on the realm's global
        // bindings map rather than the per-frame env. Module
        // top-levels stay scope-local — their visibility model is
        // import / export, not the global object.
        const is_global = target.kind == .script and !self.is_module;
        const slot: u8 = if (is_global) 0 else try self.newEnvSlot();
        const binding: Binding = .{
            .name = name,
            .env_slot = slot,
            .env_depth = self.env_depth,
            .kind = kind,
            .span = span,
            .is_global = is_global,
        };
        try target.bindings.append(self.allocator, binding);
        if (is_global) {
            // Hoist-time install on the realm. `var` / function
            // get `undefined` (or the existing value, preserving
            // cross-script `var` re-declaration semantics);
            // `let` / `const` get the TDZ Hole that the
            // initializer's `sta_global` will overwrite.
            const init_value: Value = switch (kind) {
                .var_ => Value.undefined_,
                .let_, .const_ => Value.hole_,
            };
            const gop = try self.realm.globals.getOrPut(self.realm.allocator, name);
            if (!gop.found_existing or kind != .var_) {
                gop.value_ptr.* = init_value;
            }
        }
        return binding;
    }

    /// Emit the load sequence for `binding`: either `lda_env`
    /// (for env-slot bindings) or `lda_global` (for top-level
    /// Script bindings). Both append a `throw_if_hole` for `let`
    /// / `const` to enforce §13.3.1 TDZ.
    fn emitLoadBinding(self: *Compiler, binding: Binding, span: Span) !void {
        if (binding.is_global) {
            const k = try self.internString(binding.name);
            try self.builder.emitOp(.lda_global, span);
            try self.builder.emitU16(k);
        } else {
            const depth = self.env_depth - binding.env_depth;
            try self.builder.emitOp(.lda_env, span);
            try self.builder.emitU8(depth);
            try self.builder.emitU8(binding.env_slot);
        }
        if (binding.kind != .var_) {
            try self.builder.emitOp(.throw_if_hole, span);
        }
    }

    /// Emit the store sequence for `binding`. Mirrors
    /// `emitLoadBinding` for the global vs env-slot fork. No TDZ
    /// check — stores are how the Hole gets overwritten.
    fn emitStoreBinding(self: *Compiler, binding: Binding, span: Span) !void {
        if (binding.is_global) {
            const k = try self.internString(binding.name);
            try self.builder.emitOp(.sta_global, span);
            try self.builder.emitU16(k);
        } else {
            const depth = self.env_depth - binding.env_depth;
            try self.builder.emitOp(.sta_env, span);
            try self.builder.emitU8(depth);
            try self.builder.emitU8(binding.env_slot);
        }
    }

    fn functionScope(self: *Compiler) *Scope {
        var cursor: ?*Scope = self.scope;
        while (cursor) |s| : (cursor = s.parent) {
            if (s.isFunctionLike()) return s;
        }
        unreachable; // every entry point opens a script scope
    }

    /// Compile `expr`, leaving its result in the accumulator.
    pub fn compileExpression(self: *Compiler, expr: *const Expression) CompileError!void {
        switch (expr.*) {
            .null_literal => |n| try self.builder.emitOp(.lda_null, n.span),
            .boolean_literal => |b| try self.builder.emitOp(if (b.value) Op.lda_true else Op.lda_false, b.span),
            .numeric_literal => |n| try self.compileNumeric(n.span),
            .bigint_literal => |n| try self.compileBigInt(n.span),
            .string_literal => |s| try self.compileString(s.span),
            .identifier_reference => |id| try self.compileIdentRef(id.span),
            .parenthesized => |p| try self.compileExpression(p.expression),
            .unary => |u| try self.compileUnary(u),
            .binary => |b| try self.compileBinary(b),
            .logical => |l| try self.compileLogical(l),
            .conditional => |c| try self.compileConditional(c),
            .sequence => |s| try self.compileSequence(s),
            .assignment => |a| try self.compileAssignment(a),
            .function_expr => |fe| try self.compileFunctionExpr(fe),
            .arrow_function => |af| try self.compileArrowFunction(af),
            .call => |c| try self.compileCall(c),
            .new_expr => |n| try self.compileNewExpr(n),
            .object_literal => |o| try self.compileObjectLiteral(o),
            .array_literal => |a| try self.compileArrayLiteral(a),
            .member => |m| try self.compileMember(m),
            .template_literal => |t| try self.compileTemplateLiteral(t),
            .tagged_template => |tt| try self.compileTaggedTemplate(tt),
            .update => |u| try self.compileUpdate(u),
            .class_expr => |c| try self.compileClassExpr(c),
            .yield => |y| try self.compileYield(y),
            .await_ => |a| try self.compileAwait(a),
            .this_expr => |t| try self.builder.emitOp(.lda_this, t.span),
            .chain => |ch| try self.compileChain(ch),
            .regex_literal => |rl| try self.compileRegexLiteral(rl.span),
            .import_meta => |im| try self.compileImportMeta(im.span),
            .import_call => |ic| try self.compileImportCall(ic),
            else => return error.UnsupportedExpression,
        }
    }

    /// `import.meta` — return the meta object for the current
    /// module. later: real-module-graph metadata. Today it's a
    /// fresh empty object on each access (sufficient for the
    /// common `import.meta.url` / `import.meta.resolve` shape
    /// tests).
    fn compileImportMeta(self: *Compiler, span: Span) CompileError!void {
        try self.builder.emitOp(.make_object, span);
    }

    /// `import(specifier)` — dynamic import. Lower as
    /// `Promise.reject(new TypeError("dynamic import is not
    /// supported in this host"))`. Several test262 cases just
    /// check that the call returns a Promise; full module
    /// loading is later.
    fn compileImportCall(self: *Compiler, ic: ast.expression.ImportCallExpr) CompileError!void {
        // Evaluate (and discard) the argument for side effects.
        try self.compileExpression(ic.source);
        // Then emit `Promise.reject(new TypeError("…"))`. Temp
        // ordering is significant: `call_method` expects the
        // single arg in `r_callee + 1`, so we build the
        // TypeError in a scratch range that gets released before
        // we star the arg.
        const k_promise = try self.internString("Promise");
        try self.builder.emitOp(.lda_global, ic.span);
        try self.builder.emitU16(k_promise);
        const r_p = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, ic.span);
        try self.builder.emitU8(r_p);
        const k_reject = try self.internString("reject");
        try self.builder.emitOp(.lda_property, ic.span);
        try self.builder.emitU16(k_reject);
        const r_rej = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, ic.span);
        try self.builder.emitU8(r_rej);
        // Build the TypeError instance in scratch temps, then
        // release them so the next reserveTemp returns r_rej + 1
        // (the slot `call_method` needs for the single arg).
        {
            const k_te = try self.internString("TypeError");
            try self.builder.emitOp(.lda_global, ic.span);
            try self.builder.emitU16(k_te);
            const r_te = try self.reserveTemp();
            try self.builder.emitOp(.star, ic.span);
            try self.builder.emitU8(r_te);
            const k_msg = try self.builder.addConstant(Value.fromString(self.realm.heap.allocateString("dynamic import is not supported") catch return error.OutOfMemory));
            try self.builder.emitOp(.lda_constant, ic.span);
            try self.builder.emitU16(k_msg);
            const r_msg = try self.reserveTemp();
            try self.builder.emitOp(.star, ic.span);
            try self.builder.emitU8(r_msg);
            try self.builder.emitOp(.new_call, ic.span);
            try self.builder.emitU8(r_te);
            try self.builder.emitU8(1);
            self.releaseTemp(); // r_msg
            self.releaseTemp(); // r_te
        }
        const r_arg = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, ic.span);
        try self.builder.emitU8(r_arg);
        try self.builder.emitOp(.call_method, ic.span);
        try self.builder.emitU8(r_p);
        try self.builder.emitU8(r_rej);
        try self.builder.emitU8(1);
    }

    /// `/pat/flags` literal — emit as `new RegExp("pat", "flags")`.
    /// The span covers `/pat/flags`; we split on the last `/`
    /// to separate flags from pattern body.
    fn compileRegexLiteral(self: *Compiler, span: Span) CompileError!void {
        const text = self.source[span.start..span.end];
        if (text.len < 2 or text[0] != '/') return error.UnsupportedExpression;
        const Helper = struct {
            fn isFlag(c: u8) bool {
                return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
            }
        };
        // Find the closing `/` — scan from the right, skipping
        // any `\\/` (escaped slashes inside the pattern). Slashes
        // inside character classes need similar care, but the
        // parser already validated balance so the *last* lone
        // slash is the closer.
        var close_idx: ?usize = null;
        var i: usize = text.len;
        while (i > 1) {
            i -= 1;
            const ch = text[i];
            if (ch == '/') {
                close_idx = i;
                break;
            }
            // Stop scanning once we hit a non-flag char — flags
            // are ASCII letters only.
            if (!Helper.isFlag(ch)) return error.UnsupportedExpression;
        }
        const cidx = close_idx orelse return error.UnsupportedExpression;
        const pattern = text[1..cidx];
        const flags = text[cidx + 1 ..];

        // Look up `RegExp` from globals at runtime; emit
        // `new RegExp(pattern, flags)` via the literal call path.
        const k_regexp = try self.internString("RegExp");
        try self.builder.emitOp(.lda_global, span);
        try self.builder.emitU16(k_regexp);
        const r_ctor = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_ctor);

        const k_pat = try self.builder.addConstant(Value.fromString(self.realm.heap.allocateString(pattern) catch return error.OutOfMemory));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k_pat);
        const r_pat = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_pat);

        const k_flags = try self.builder.addConstant(Value.fromString(self.realm.heap.allocateString(flags) catch return error.OutOfMemory));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k_flags);
        const r_flags = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_flags);

        try self.builder.emitOp(.new_call, span);
        try self.builder.emitU8(r_ctor);
        try self.builder.emitU8(2);
    }

    /// §13.5.5 OptionalExpression — compile the inner expression
    /// inside a chain context that collects `jmp_if_nullish` patch
    /// sites. After the body, emit an unconditional jump past the
    /// undefined-loader, then the loader, and patch every collected
    /// site to land on the loader.
    fn compileChain(self: *Compiler, ch: ast.expression.ChainExpr) CompileError!void {
        var patches: std.ArrayListUnmanaged(u32) = .empty;
        defer patches.deinit(self.allocator);
        const prev = self.chain_patches;
        self.chain_patches = &patches;
        defer self.chain_patches = prev;

        try self.compileExpression(ch.expression);

        // Body completed without short-circuiting — skip past the
        // undefined-loader to the chain's join point.
        try self.builder.emitOp(.jmp, ch.span);
        const skip_patch = self.builder.here();
        try self.builder.emitI16(0);

        // Short-circuit landing pad: every `?.` that saw a nullish
        // LHS jumps here. `acc` is whatever the nullish LHS was
        // (null or undefined), which we overwrite with undefined.
        const undefined_target = self.builder.here();
        try self.builder.emitOp(.lda_undefined, ch.span);

        const join = self.builder.here();
        try self.builder.patchI16(skip_patch, join);
        for (patches.items) |patch| {
            try self.builder.patchI16(patch, undefined_target);
        }
    }

    /// Emit `jmp_if_nullish` with a placeholder offset and record
    /// the patch site on the surrounding chain. Caller must already
    /// have left the LHS (the side being null-checked) in `acc`.
    /// Outside a chain context this is a compile error — the
    /// parser only emits `optional: true` inside a `ChainExpr`,
    /// so reaching here without a chain is a parser/AST bug.
    fn emitOptionalShortCircuit(self: *Compiler, span: Span) CompileError!void {
        const patches = self.chain_patches orelse return error.UnsupportedExpression;
        try self.builder.emitOp(.jmp_if_nullish, span);
        const patch = self.builder.here();
        try self.builder.emitI16(0);
        try patches.append(self.allocator, patch);
    }

    fn compileYield(self: *Compiler, y: ast.expression.YieldExpr) CompileError!void {
        if (y.delegate) return error.UnsupportedExpression; // `yield*`
        if (y.argument) |arg| {
            try self.compileExpression(arg);
        } else {
            try self.builder.emitOp(.lda_undefined, y.span);
        }
        try self.builder.emitOp(.gen_yield, y.span);
    }

    fn compileAwait(self: *Compiler, a: ast.expression.AwaitExpr) CompileError!void {
        try self.compileExpression(a.argument);
        try self.builder.emitOp(.await_, a.span);
    }

    /// `++x` / `--x` (prefix), `x++` / `x--` (postfix). §13.4.
    /// Lowers to `acc = ToNumber(x); x = acc ± 1; result =
    /// (prefix ? acc_new : acc_old)`. Both identifier and
    /// member-access targets are supported.
    fn compileUpdate(self: *Compiler, u: ast.expression.UpdateExpr) CompileError!void {
        if (u.operand.* == .member) {
            return self.compileUpdateMember(u);
        }
        if (u.operand.* != .identifier_reference) {
            return error.UnsupportedExpression;
        }
        const span = u.operand.identifier_reference.span;
        const name = self.source[span.start..span.end];
        const scope = self.scope orelse return error.UnresolvedReference;
        const binding: Binding = scope.resolve(name) orelse blk: {
            if (self.realm.globals.contains(name)) {
                break :blk Binding{
                    .name = name,
                    .env_slot = 0,
                    .env_depth = 0,
                    .kind = .var_,
                    .span = span,
                    .is_global = true,
                };
            }
            return error.UnresolvedReference;
        };
        if (binding.kind == .const_) {
            try self.report(.assignment_to_const, u.span);
            return error.AssignmentToConst;
        }

        // Read x → acc (with TDZ check for let/const).
        try self.emitLoadBinding(binding, span);

        // §13.4.4.1 step 2.b — ToNumeric.
        try self.builder.emitOp(.to_number, span);

        // Save the coerced original for the result-of-postfix
        // and the lhs of the bump.
        const r_orig = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_orig);

        // bumped = orig ± 1. With our convention `add/sub r` is
        // `acc = r OP acc`, so put 1 in acc and reference r_orig.
        try self.builder.emitOp(.lda_smi, u.span);
        try self.builder.emitI32(1);
        const op: Op = if (u.op == .increment) .add else .sub;
        try self.builder.emitOp(op, u.span);
        try self.builder.emitU8(r_orig);
        try self.emitStoreBinding(binding, u.span);

        if (u.prefix) {
            // Result = bumped value (still in acc after sta_env /
            // sta_global — neither disturbs the accumulator).
        } else {
            // Result = original.
            try self.builder.emitOp(.ldar, u.span);
            try self.builder.emitU8(r_orig);
        }
    }

    /// `obj.x++`, `--arr[i]`, etc. The receiver is evaluated
    /// once, the property read coerced via ToNumeric, the bump
    /// stored back through the same access path, and the result
    /// (old vs new) chosen by `u.prefix`.
    fn compileUpdateMember(self: *Compiler, u: ast.expression.UpdateExpr) CompileError!void {
        const m = u.operand.member;
        if (m.optional) return error.UnsupportedExpression;

        // Evaluate the receiver once → r_obj.
        try self.compileExpression(m.object);
        const r_obj = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, u.span);
        try self.builder.emitU8(r_obj);

        // Resolve the key shape; computed keys evaluate the key
        // expression once into r_key so the get/set pair share
        // the same value (avoiding double-eval side effects).
        const Mode = enum { ident, computed };
        var mode: Mode = .ident;
        var k_const: u16 = 0;
        var r_key: u8 = 0;
        switch (m.property) {
            .ident => |span| {
                const key_slice = self.source[span.start..span.end];
                if (key_slice.len > 0 and key_slice[0] == '#') {
                    return error.UnsupportedExpression; // private field update
                }
                k_const = try self.internString(key_slice);
                mode = .ident;
            },
            .computed => |key_expr| {
                try self.compileExpression(key_expr);
                r_key = try self.reserveTemp();
                try self.builder.emitOp(.star, u.span);
                try self.builder.emitU8(r_key);
                mode = .computed;
            },
        }

        // Read current value → acc, ToNumeric, save as r_orig.
        try self.builder.emitOp(.ldar, u.span);
        try self.builder.emitU8(r_obj);
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.lda_property, u.span);
                try self.builder.emitU16(k_const);
            },
            .computed => {
                try self.builder.emitOp(.ldar, u.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitOp(.lda_computed, u.span);
                try self.builder.emitU8(r_obj);
            },
        }
        try self.builder.emitOp(.to_number, u.span);
        const r_orig = try self.reserveTemp();
        try self.builder.emitOp(.star, u.span);
        try self.builder.emitU8(r_orig);

        // bumped = orig ± 1.
        try self.builder.emitOp(.lda_smi, u.span);
        try self.builder.emitI32(1);
        const op: Op = if (u.op == .increment) .add else .sub;
        try self.builder.emitOp(op, u.span);
        try self.builder.emitU8(r_orig);

        // Store back — acc holds the bumped value.
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.sta_property, u.span);
                try self.builder.emitU16(k_const);
                try self.builder.emitU8(r_obj);
            },
            .computed => {
                try self.builder.emitOp(.sta_computed, u.span);
                try self.builder.emitU8(r_obj);
                try self.builder.emitU8(r_key);
            },
        }

        if (!u.prefix) {
            // Postfix — result is the original.
            try self.builder.emitOp(.ldar, u.span);
            try self.builder.emitU8(r_orig);
        }
        // Prefix — acc currently has the bumped value, leave it.

        self.releaseTemp(); // r_orig
        if (mode == .computed) self.releaseTemp(); // r_key
    }

    /// `` `head${ e1 }middle${ e2 }tail` `` — §13.2.8.6
    /// TemplateLiteral. Lowers to `head + ToString(e1) + middle +
    /// ToString(e2) + tail`. The Add op already string-coerces
    /// when either operand is a string (§13.7.3 step 8 — the
    /// string-concat shortcut), so the compiled chain is just
    /// repeated `Add r_acc`.
    fn compileTemplateLiteral(self: *Compiler, lit: ast.expression.TemplateLit) CompileError!void {
        // No substitutions — emit just the head quasi.
        if (lit.expressions.len == 0) {
            std.debug.assert(lit.quasis.len == 1);
            try self.compileTemplateQuasi(lit.quasis[0].span);
            return;
        }
        // First quasi → acc → temp.
        try self.compileTemplateQuasi(lit.quasis[0].span);
        const r_acc = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, lit.span);
        try self.builder.emitU8(r_acc);

        for (lit.expressions, 0..) |*expr, i| {
            // Evaluate the substitution; ToString is implicit on
            // string + non-string Add (matches V8 / SM lowering).
            try self.compileExpression(expr);
            try self.builder.emitOp(.add, lit.span);
            try self.builder.emitU8(r_acc);
            try self.builder.emitOp(.star, lit.span);
            try self.builder.emitU8(r_acc);

            // Trailing quasi after this substitution.
            try self.compileTemplateQuasi(lit.quasis[i + 1].span);
            try self.builder.emitOp(.add, lit.span);
            try self.builder.emitU8(r_acc);
            try self.builder.emitOp(.star, lit.span);
            try self.builder.emitU8(r_acc);
        }

        try self.builder.emitOp(.ldar, lit.span);
        try self.builder.emitU8(r_acc);
    }

    /// `tag`a${e1}b${e2}c`` — §13.3.11 TaggedTemplate. Lowers to
    /// `tag(strs, e1, e2,...)`.
    ///
    /// §13.3.11.4 GetTemplateObject mandates that the SAME `strs`
    /// object reference (with the same `raw` companion) is
    /// returned every time the same call-site evaluates. Tags
    /// that key on identity (the canonical example is React's
    /// `css\`…\`` for compile-time CSS-in-JS) require this.
    ///
    /// Cynic builds the `strs` + `raw` arrays once at compile
    /// time, allocates them on the realm heap, and parks the
    /// `strs` object as a chunk constant. The runtime emits
    /// `lda_constant` to load it — same Value every call,
    /// satisfying the identity contract.
    fn compileTaggedTemplate(self: *Compiler, tt: ast.expression.TaggedTemplateExpr) CompileError!void {
        if (tt.quasi.* != .template_literal) return error.UnsupportedExpression;
        const lit = tt.quasi.template_literal;
        const k_strs = try self.buildTemplateObject(lit);

        // Compile the tag → r_callee.
        try self.compileExpression(tt.tag);
        const r_callee = try self.reserveTemp();
        try self.builder.emitOp(.star, tt.span);
        try self.builder.emitU8(r_callee);

        // First arg = the cached `strs` object.
        const r_strs = try self.reserveTemp();
        try self.builder.emitOp(.lda_constant, tt.span);
        try self.builder.emitU16(k_strs);
        try self.builder.emitOp(.star, tt.span);
        try self.builder.emitU8(r_strs);

        // Compile each substitution into consecutive arg slots.
        var reserved: u8 = 1; // r_strs
        for (lit.expressions) |*e| {
            try self.compileExpression(e);
            const r_arg = try self.reserveTemp();
            reserved += 1;
            try self.builder.emitOp(.star, tt.span);
            try self.builder.emitU8(r_arg);
        }

        try self.builder.emitOp(.call, tt.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(@intCast(1 + lit.expressions.len));

        var k: u8 = 0;
        while (k < reserved) : (k += 1) self.releaseTemp();
        self.releaseTemp(); // r_callee
    }

    /// Allocate the per-call-site `strs` array (cooked quasis)
    /// with its `raw` companion (raw quasis), wire `length`,
    /// freeze-ish (we set the props but don't yet have full
    /// Object.freeze semantics for Arrays), and store the result
    /// as a chunk constant. Returns the constant index.
    fn buildTemplateObject(self: *Compiler, lit: ast.expression.TemplateLit) CompileError!u16 {
        // Allocate the `raw` array.
        const raw_arr = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        raw_arr.prototype = self.realm.intrinsics.array_prototype;
        for (lit.quasis, 0..) |q, i| {
            const raw_text = self.source[q.span.start..q.span.end];
            const owned = self.realm.heap.allocateString(raw_text) catch return error.OutOfMemory;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const idx_owned = self.realm.heap.allocateString(islice) catch return error.OutOfMemory;
            raw_arr.set(self.allocator, idx_owned.bytes, Value.fromString(owned)) catch return error.OutOfMemory;
        }
        raw_arr.set(self.allocator, "length", Value.fromInt32(@intCast(lit.quasis.len))) catch return error.OutOfMemory;

        // Allocate the `strs` array (cooked).
        const strs_arr = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        strs_arr.prototype = self.realm.intrinsics.array_prototype;
        for (lit.quasis, 0..) |q, i| {
            const cooked = self.decodeQuasi(q.span) catch return error.OutOfMemory;
            const owned = self.realm.heap.allocateString(cooked) catch return error.OutOfMemory;
            // Free the temp decoded buffer if it was newly
            // allocated (decodeQuasi may return either the raw
            // span as-is or an owned heap slice).
            self.allocator.free(cooked);
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const idx_owned = self.realm.heap.allocateString(islice) catch return error.OutOfMemory;
            strs_arr.set(self.allocator, idx_owned.bytes, Value.fromString(owned)) catch return error.OutOfMemory;
        }
        strs_arr.set(self.allocator, "length", Value.fromInt32(@intCast(lit.quasis.len))) catch return error.OutOfMemory;
        strs_arr.set(self.allocator, "raw", heap_mod.taggedObject(raw_arr)) catch return error.OutOfMemory;

        return self.builder.addConstant(heap_mod.taggedObject(strs_arr));
    }

    /// Decode a template quasi's escape sequences into a fresh
    /// allocator-owned slice. Mirrors what
    /// `compileTemplateQuasi` did at runtime, but eagerly so the
    /// cooked text can land in a heap-allocated `strs` element.
    /// Returns owned bytes — caller frees.
    fn decodeQuasi(self: *Compiler, span: Span) ![]u8 {
        const raw = self.source[span.start..span.end];
        // Common case: no escapes → just dup the slice.
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            return self.allocator.dupe(u8, raw);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c != '\\' or i + 1 >= raw.len) {
                try out.append(self.allocator, c);
                i += 1;
                continue;
            }
            const next = raw[i + 1];
            switch (next) {
                'n' => try out.append(self.allocator, '\n'),
                't' => try out.append(self.allocator, '\t'),
                'r' => try out.append(self.allocator, '\r'),
                '\\' => try out.append(self.allocator, '\\'),
                '\'' => try out.append(self.allocator, '\''),
                '"' => try out.append(self.allocator, '"'),
                '`' => try out.append(self.allocator, '`'),
                '0' => try out.append(self.allocator, 0),
                'b' => try out.append(self.allocator, 8),
                'f' => try out.append(self.allocator, 12),
                'v' => try out.append(self.allocator, 11),
                else => {
                    // Leave unrecognised escapes verbatim — full
                    // \u/\x decoding is the existing emit-time
                    // path, which the runtime LdaConstant handled
                    // before. Tests exercising tag-identity rarely
                    // need full decoding.
                    try out.append(self.allocator, '\\');
                    try out.append(self.allocator, next);
                },
            }
            i += 2;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Emit `LdaConstant` for the *raw* quasi text — preserves
    /// backslash escape sequences verbatim. Used for the `raw`
    /// companion array of a tagged template.
    fn compileTemplateQuasiRaw(self: *Compiler, span: Span) CompileError!void {
        const raw = self.source[span.start..span.end];
        const s = self.realm.heap.allocateString(raw) catch return error.OutOfMemory;
        const k = try self.builder.addConstant(Value.fromString(s));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k);
    }

    /// Emit `LdaConstant` for a template-literal quasi. The span
    /// covers raw text without surrounding markers (`` ` ``,
    /// `${`, `}`); reuse the standard escape-decoder so `\n`
    /// etc. behave like in a regular string literal.
    fn compileTemplateQuasi(self: *Compiler, span: Span) CompileError!void {
        const raw = self.source[span.start..span.end];
        const decoded = decodeStringContent(self.allocator, raw) catch return error.UnsupportedExpression;
        defer self.allocator.free(decoded);
        const s = self.realm.heap.allocateString(decoded) catch return error.OutOfMemory;
        const k = try self.builder.addConstant(Value.fromString(s));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k);
    }

    /// `[a, b, c]` (§13.2.4). later lowers an array literal
    /// to an object with stringified-index keys plus a `.length`
    /// property — close enough for code that just reads
    /// `arr[0]` / `arr.length`. later wires shapes / a true
    /// `JSArray` heap kind for fast indexing and `Array.prototype`
    /// method dispatch.
    ///
    /// Elisions (`[1,, 3]`) leave the slot unwritten — reading
    /// it falls through to the prototype chain (which yields
    /// `undefined` for an unowned key), matching §10.4.2.4.
    fn compileArrayLiteral(self: *Compiler, lit: ast.expression.ArrayLit) CompileError!void {
        try self.builder.emitOp(.make_array, lit.span);
        const r_arr = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, lit.span);
        try self.builder.emitU8(r_arr);

        // Two-pass strategy: when there are no spread elements we
        // can write each slot at a known stringified index and
        // set `.length` once at the end. With spreads, the index
        // depends on the source's length at runtime — we use the
        // `array_spread` op which appends + updates length, and
        // for fixed-position elements before/after we still write
        // by direct index but track the next-fixed-index slot
        // through a runtime-shifted length read. To keep the
        // emitted code simple, when any spread is present we
        // route every element through `array_spread` semantics
        // by emitting an inline 1-element source.
        var has_spread = false;
        for (lit.elements) |maybe_elem| {
            if (maybe_elem) |elem| {
                if (elem == .spread) {
                    has_spread = true;
                    break;
                }
            }
        }

        if (!has_spread) {
            var idx: usize = 0;
            for (lit.elements) |maybe_elem| {
                if (maybe_elem) |elem| {
                    var idx_buf: [16]u8 = undefined;
                    const idx_slice = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch unreachable;
                    const k = try self.internString(idx_slice);
                    try self.compileExpression(&elem);
                    try self.builder.emitOp(.sta_property, lit.span);
                    try self.builder.emitU16(k);
                    try self.builder.emitU8(r_arr);
                }
                idx += 1;
            }
            const k_length = try self.internString("length");
            if (idx <= std.math.maxInt(i32)) {
                try self.builder.emitOp(.lda_smi, lit.span);
                try self.builder.emitI32(@intCast(idx));
            } else {
                return error.UnsupportedExpression;
            }
            try self.builder.emitOp(.sta_property, lit.span);
            try self.builder.emitU16(k_length);
            try self.builder.emitU8(r_arr);
        } else {
            // length starts at 0 — array_spread / arrayPush rely
            // on the existing length. Initialise it explicitly.
            const k_length = try self.internString("length");
            try self.builder.emitOp(.lda_smi, lit.span);
            try self.builder.emitI32(0);
            try self.builder.emitOp(.sta_property, lit.span);
            try self.builder.emitU16(k_length);
            try self.builder.emitU8(r_arr);

            for (lit.elements) |maybe_elem| {
                if (maybe_elem) |elem| {
                    if (elem == .spread) {
                        // Eval the source into acc, then append.
                        try self.compileExpression(elem.spread.argument);
                        try self.builder.emitOp(.array_spread, lit.span);
                        try self.builder.emitU8(r_arr);
                    } else {
                        // Fixed-position: emit a tiny spread of a
                        // 1-element wrapper. To avoid allocating a
                        // temp object every iteration, instead read
                        // the current length, sta_computed at that
                        // index, then increment length. Easier: use
                        // the `Array.prototype.push` shape by
                        // calling our intrinsic via call_method.
                        // Simplest: read length → r_idx, sta_computed
                        // r_arr[r_idx] = acc, length++.
                        try self.compileExpression(&elem);
                        const r_val = try self.reserveTemp();
                        try self.builder.emitOp(.star, lit.span);
                        try self.builder.emitU8(r_val);
                        // r_idx = r_arr.length
                        try self.builder.emitOp(.ldar, lit.span);
                        try self.builder.emitU8(r_arr);
                        try self.builder.emitOp(.lda_property, lit.span);
                        try self.builder.emitU16(k_length);
                        const r_idx = try self.reserveTemp();
                        try self.builder.emitOp(.star, lit.span);
                        try self.builder.emitU8(r_idx);
                        // r_arr[r_idx] = r_val
                        try self.builder.emitOp(.ldar, lit.span);
                        try self.builder.emitU8(r_val);
                        try self.builder.emitOp(.sta_computed, lit.span);
                        try self.builder.emitU8(r_arr);
                        try self.builder.emitU8(r_idx);
                        // length += 1
                        try self.builder.emitOp(.ldar, lit.span);
                        try self.builder.emitU8(r_idx);
                        try self.builder.emitOp(.lda_smi, lit.span);
                        try self.builder.emitI32(1);
                        try self.builder.emitOp(.add, lit.span);
                        try self.builder.emitU8(r_idx);
                        try self.builder.emitOp(.sta_property, lit.span);
                        try self.builder.emitU16(k_length);
                        try self.builder.emitU8(r_arr);

                        self.releaseTemp(); // r_idx
                        self.releaseTemp(); // r_val
                    }
                } else {
                    // Elision in spread context — still bumps length.
                    try self.builder.emitOp(.ldar, lit.span);
                    try self.builder.emitU8(r_arr);
                    try self.builder.emitOp(.lda_property, lit.span);
                    try self.builder.emitU16(k_length);
                    const r_idx = try self.reserveTemp();
                    try self.builder.emitOp(.star, lit.span);
                    try self.builder.emitU8(r_idx);
                    try self.builder.emitOp(.lda_smi, lit.span);
                    try self.builder.emitI32(1);
                    try self.builder.emitOp(.add, lit.span);
                    try self.builder.emitU8(r_idx);
                    try self.builder.emitOp(.sta_property, lit.span);
                    try self.builder.emitU16(k_length);
                    try self.builder.emitU8(r_arr);
                    self.releaseTemp();
                }
            }
        }

        try self.builder.emitOp(.ldar, lit.span);
        try self.builder.emitU8(r_arr);
    }

    fn compileObjectLiteral(self: *Compiler, lit: ast.expression.ObjectLit) CompileError!void {
        // Allocate empty object.
        try self.builder.emitOp(.make_object, lit.span);
        const r_obj = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, lit.span);
        try self.builder.emitU8(r_obj);

        for (lit.properties) |prop| switch (prop) {
            .property => |p| {
                // §13.2.5.5 PropertyDefinitionEvaluation — computed
                // keys evaluate the expression, ToPropertyKey-coerce
                // it, and route through `sta_computed`. Static keys
                // intern the source slice and use `sta_property`.
                if (p.key == .computed) {
                    try self.compileExpression(p.key.computed);
                    const r_key = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, p.span);
                    try self.builder.emitU8(r_key);
                    try self.compileExpression(&p.value);
                    // §15.5.6.4 — anonymous function-likes pick up
                    // a name derived from the computed key. The
                    // opcode no-ops if the value already has a
                    // non-empty name or isn't a function.
                    if (isAnonymousFunctionLike(&p.value)) {
                        try self.builder.emitOp(.set_fn_name_from, p.span);
                        try self.builder.emitU8(r_key);
                        try self.builder.emitU8(0); // no prefix
                    }
                    try self.builder.emitOp(.sta_computed, p.span);
                    try self.builder.emitU8(r_obj);
                    try self.builder.emitU8(r_key);
                    continue;
                }
                const key_slice = switch (p.key) {
                    .ident => |span| try self.decodeIdentifierName(self.source[span.start..span.end]),
                    .string => |span| inner: {
                        // Strip surrounding quotes — string-literal keys
                        // include the quote bytes in their span. later
                        // will decode escape sequences here too.
                        const raw = self.source[span.start..span.end];
                        if (raw.len < 2) return error.UnsupportedExpression;
                        break :inner raw[1 .. raw.len - 1];
                    },
                    // §13.2.5.5 PropertyDefinitionEvaluation —
                    // `{0: x}` evaluates the literal and ToPropertyKey-
                    // coerces. For integer literals the canonical
                    // string form equals the source text; floats /
                    // exponents canonicalize differently but are
                    // rare in test262 fixtures.
                    .numeric => |span| self.source[span.start..span.end],
                    else => return error.UnsupportedExpression, // private
                };
                // §B.3.1 — `{ __proto__: v }` (with a non-computed
                // `__proto__` key, no shorthand): if `v` is Object
                // or Null, set [[Prototype]]; otherwise no-op. Do
                // *not* create a property named `__proto__`.
                if (std.mem.eql(u8, key_slice, "__proto__") and p.key != .computed) {
                    try self.compileExpression(&p.value);
                    try self.builder.emitOp(.set_proto_literal, p.span);
                    try self.builder.emitU8(r_obj);
                    continue;
                }
                const k = try self.internString(key_slice);
                // §13.2.5.5 step 7 — anonymous function-likes
                // adopt the property key as their `.name`.
                try self.compileNamedValue(&p.value, key_slice);
                try self.builder.emitOp(.sta_property, p.span);
                try self.builder.emitU16(k);
                try self.builder.emitU8(r_obj);
            },
            .method => |m| {
                if (m.is_generator or m.is_async) return error.UnsupportedExpression;
                // Computed-key method / accessor — evaluate the key,
                // park it in a temp, compile the body, then dispatch:
                //   .method  → `sta_computed`
                //   .getter  → `def_computed_accessor` (is_setter=0)
                //   .setter  → `def_computed_accessor` (is_setter=1)
                // §13.2.5.5 PropertyDefinitionEvaluation, with the
                // ComputedPropertyName subforms.
                if (m.key == .computed) {
                    try self.compileExpression(m.key.computed);
                    const r_key = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, m.span);
                    try self.builder.emitU8(r_key);
                    const tk = try compileFunctionTemplate(
                        self,
                        m.params,
                        FunctionBody{ .block = m.body.body },
                        null,
                        false,
                        m.span,
                    );
                    try self.builder.emitOp(.make_function, m.span);
                    try self.builder.emitU16(tk);
                    // §10.2.5 — object-literal methods carry a
                    // [[HomeObject]] pointing at the enclosing
                    // object so `super.x` walks its prototype chain.
                    try self.builder.emitOp(.set_home, m.span);
                    try self.builder.emitU8(r_obj);
                    // §15.5.6.4 — methods get the bare key as a
                    // name; getters/setters prefix `get `/`set `.
                    const prefix_kind: u8 = switch (m.kind) {
                        .method => 0,
                        .getter => 1,
                        .setter => 2,
                    };
                    try self.builder.emitOp(.set_fn_name_from, m.span);
                    try self.builder.emitU8(r_key);
                    try self.builder.emitU8(prefix_kind);
                    switch (m.kind) {
                        .method => {
                            try self.builder.emitOp(.sta_computed, m.span);
                            try self.builder.emitU8(r_obj);
                            try self.builder.emitU8(r_key);
                        },
                        .getter => {
                            try self.builder.emitOp(.def_computed_accessor, m.span);
                            try self.builder.emitU8(r_obj);
                            try self.builder.emitU8(r_key);
                            try self.builder.emitU8(0);
                        },
                        .setter => {
                            try self.builder.emitOp(.def_computed_accessor, m.span);
                            try self.builder.emitU8(r_obj);
                            try self.builder.emitU8(r_key);
                            try self.builder.emitU8(1);
                        },
                    }
                    continue;
                }
                const key_slice = switch (m.key) {
                    .ident => |span| try self.decodeIdentifierName(self.source[span.start..span.end]),
                    .string => |span| inner: {
                        const raw = self.source[span.start..span.end];
                        if (raw.len < 2) return error.UnsupportedExpression;
                        break :inner raw[1 .. raw.len - 1];
                    },
                    .numeric => |span| self.source[span.start..span.end],
                    else => return error.UnsupportedExpression,
                };
                const k = try self.internString(key_slice);
                // §15.5.6.4 — accessor `.name` is the property
                // key prefixed with `get ` / `set `; the bare
                // method form keeps the key as-is.
                const fn_name = switch (m.kind) {
                    .method => key_slice,
                    .getter => blk: {
                        const arena = self.realm.classAllocator();
                        break :blk std.fmt.allocPrint(arena, "get {s}", .{key_slice}) catch return error.OutOfMemory;
                    },
                    .setter => blk: {
                        const arena = self.realm.classAllocator();
                        break :blk std.fmt.allocPrint(arena, "set {s}", .{key_slice}) catch return error.OutOfMemory;
                    },
                };
                // Compile the method body as a function template.
                const tk = try compileFunctionTemplate(
                    self,
                    m.params,
                    FunctionBody{ .block = m.body.body },
                    fn_name,
                    false,
                    m.span,
                );
                try self.builder.emitOp(.make_function, m.span);
                try self.builder.emitU16(tk);
                // §10.2.5 — wire [[HomeObject]] before installing
                // so `super` lookups inside the method body resolve
                // against the enclosing object's prototype chain.
                try self.builder.emitOp(.set_home, m.span);
                try self.builder.emitU8(r_obj);
                switch (m.kind) {
                    .method => {
                        try self.builder.emitOp(.sta_property, m.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(r_obj);
                    },
                    .getter => {
                        try self.builder.emitOp(.def_accessor, m.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(r_obj);
                        try self.builder.emitU8(0); // getter
                    },
                    .setter => {
                        try self.builder.emitOp(.def_accessor, m.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(r_obj);
                        try self.builder.emitU8(1); // setter
                    },
                }
            },
            .spread => |sp| {
                // §13.2.5.5 / §7.3.26 CopyDataProperties — `{ ...src }`.
                // Compile the source into acc, then `object_spread`
                // walks its own enumerable string + symbol keys and
                // copies each into r_obj. `null` / `undefined` are
                // tolerated silently per spec.
                try self.compileExpression(sp.argument);
                try self.builder.emitOp(.object_spread, sp.span);
                try self.builder.emitU8(r_obj);
            },
        };

        // Final result of an object literal is the object itself.
        try self.builder.emitOp(.ldar, lit.span);
        try self.builder.emitU8(r_obj);
    }

    /// Decode `\uXXXX` / `\u{XXXX}` escapes inside an
    /// `IdentifierName` (member access key, object property
    /// key) into UTF-8. Per §12.7.1 the escapes' StringValue
    /// equals the corresponding source character, so
    /// `obj.if` has the property name `"if"`. Returns
    /// `key_slice` unchanged when there are no escapes.
    /// Allocations come from the realm's class arena (lifetime
    /// matches compiled chunks).
    fn decodeIdentifierName(self: *Compiler, key_slice: []const u8) CompileError![]const u8 {
        if (std.mem.indexOfScalar(u8, key_slice, '\\') == null) return key_slice;
        const arena = self.realm.classAllocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.ensureTotalCapacity(arena, key_slice.len);
        var i: usize = 0;
        while (i < key_slice.len) {
            if (key_slice[i] != '\\') {
                try out.append(arena, key_slice[i]);
                i += 1;
                continue;
            }
            // `\u…` only — IdentifierName forbids other escape forms.
            if (i + 1 >= key_slice.len or key_slice[i + 1] != 'u') return error.UnsupportedExpression;
            i += 2;
            var cp: u21 = 0;
            if (i < key_slice.len and key_slice[i] == '{') {
                i += 1;
                while (i < key_slice.len and key_slice[i] != '}') : (i += 1) {
                    const d = std.fmt.charToDigit(key_slice[i], 16) catch return error.UnsupportedExpression;
                    cp = (cp << 4) | d;
                }
                if (i >= key_slice.len or key_slice[i] != '}') return error.UnsupportedExpression;
                i += 1;
            } else {
                if (i + 4 > key_slice.len) return error.UnsupportedExpression;
                inline for (0..4) |_| {
                    const d = std.fmt.charToDigit(key_slice[i], 16) catch return error.UnsupportedExpression;
                    cp = (cp << 4) | d;
                    i += 1;
                }
            }
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &enc) catch return error.UnsupportedExpression;
            try out.appendSlice(arena, enc[0..n]);
        }
        return out.items;
    }

    fn compileMember(self: *Compiler, m: ast.expression.MemberExpr) CompileError!void {
        // `super.x` and `super[expr]` — `super_get` for ident keys,
        // `super_get_computed` (key in acc) for the bracket form.
        if (m.object.* == .super_) {
            switch (m.property) {
                .ident => |span| {
                    const key_slice = self.source[span.start..span.end];
                    const k = try self.internString(key_slice);
                    try self.builder.emitOp(.super_get, m.span);
                    try self.builder.emitU16(k);
                    return;
                },
                .computed => |key_expr| {
                    try self.compileExpression(key_expr);
                    try self.builder.emitOp(.super_get_computed, m.span);
                    return;
                },
            }
        }
        switch (m.property) {
            .ident => |span| {
                const raw_slice = self.source[span.start..span.end];
                if (raw_slice.len > 0 and raw_slice[0] == '#') {
                    // `obj.#name` — mangle with the current class's
                    // private prefix and emit `lda_private`.
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    const prefix = self.class_stack.items[self.class_stack.items.len - 1].private_prefix;
                    const arena = self.realm.classAllocator();
                    const mangled = std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, raw_slice[1..] }) catch return error.OutOfMemory;
                    const k = try self.internString(mangled);
                    try self.compileExpression(m.object);
                    if (m.optional) try self.emitOptionalShortCircuit(m.span);
                    try self.builder.emitOp(.lda_private, m.span);
                    try self.builder.emitU16(k);
                } else {
                    const key_slice = try self.decodeIdentifierName(raw_slice);
                    const k = try self.internString(key_slice);
                    try self.compileExpression(m.object);
                    if (m.optional) try self.emitOptionalShortCircuit(m.span);
                    try self.builder.emitOp(.lda_property, m.span);
                    try self.builder.emitU16(k);
                }
            },
            .computed => |key_expr| {
                // §13.3.2 EvaluatePropertyAccessWithExpressionKey.
                // Receiver into a temp, key into the accumulator,
                // emit `lda_computed`.
                try self.compileExpression(m.object);
                if (m.optional) try self.emitOptionalShortCircuit(m.span);
                const r_obj = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.star, m.span);
                try self.builder.emitU8(r_obj);

                try self.compileExpression(key_expr);
                try self.builder.emitOp(.lda_computed, m.span);
                try self.builder.emitU8(r_obj);
            },
        }
    }

    /// Allocate a `JSString` for `slice` in the realm's heap and
    /// add it to the chunk's constant pool, returning the index.
    /// Used by object-literal keys, member-access names, etc.
    fn internString(self: *Compiler, slice: []const u8) CompileError!u16 {
        const s = self.realm.heap.allocateString(slice) catch return error.OutOfMemory;
        return try self.builder.addConstant(Value.fromString(s));
    }

    /// `obj.x = v` and compound forms (`obj.x += 1`, `obj.x ??= y`).
    /// Computes the receiver into a temp once, then dispatches based
    /// on the op:
    /// • `=` — evaluate rhs and store.
    /// • `+=` / `-=` / etc. — read current value, evaluate rhs,
    /// run the bytecode op, store the result.
    /// • `&&=` / `||=` / `??=` — read current value, gate on it;
    /// when the gate skips, leave the read value in `acc` and
    /// skip the rhs and the store.
    fn compileMemberAssignment(self: *Compiler, a: ast.expression.AssignExpr) CompileError!void {
        const m = a.target.member;
        if (m.optional) return error.UnsupportedExpression;

        // §13.3.7 — `super.x = v` and `super[expr] = v`. Walks the
        // home object's prototype for a setter; falls back to a
        // plain `this[key] = v` write. Compound forms (`super.x +=
        // v` etc.) flow through the read-modify-write helper at
        // the bottom of this function, which doesn't yet handle
        // super receivers — surface that as an UnsupportedExpression
        // until the compound form is wired (~handful of fixtures).
        if (m.object.* == .super_) {
            if (a.op != .eq) return error.UnsupportedExpression;
            try self.compileExpression(a.value);
            const r_val = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, a.span);
            try self.builder.emitU8(r_val);
            switch (m.property) {
                .ident => |span| {
                    const raw = self.source[span.start..span.end];
                    if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
                    const k = try self.internString(try self.decodeIdentifierName(raw));
                    try self.builder.emitOp(.super_set, m.span);
                    try self.builder.emitU16(k);
                    try self.builder.emitU8(r_val);
                },
                .computed => |key_expr| {
                    try self.compileExpression(key_expr);
                    const r_key = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, a.span);
                    try self.builder.emitU8(r_key);
                    try self.builder.emitOp(.super_set_computed, m.span);
                    try self.builder.emitU8(r_key);
                    try self.builder.emitU8(r_val);
                },
            }
            return;
        }

        try self.compileExpression(m.object);
        const r_obj = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, m.span);
        try self.builder.emitU8(r_obj);

        // Resolve the property key into either a string-constant
        // index (for ident keys) or a temp register (for computed
        // keys). The dispatch below uses whichever is set.
        var name_k: ?u16 = null;
        var private_k: ?u16 = null;
        var computed_r: ?u8 = null;
        switch (m.property) {
            .ident => |span| {
                const raw_slice = self.source[span.start..span.end];
                if (raw_slice.len > 0 and raw_slice[0] == '#') {
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    const prefix = self.class_stack.items[self.class_stack.items.len - 1].private_prefix;
                    const arena = self.realm.classAllocator();
                    const mangled = std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, raw_slice[1..] }) catch return error.OutOfMemory;
                    private_k = try self.internString(mangled);
                } else {
                    const key_slice = try self.decodeIdentifierName(raw_slice);
                    name_k = try self.internString(key_slice);
                }
            },
            .computed => |key_expr| {
                try self.compileExpression(key_expr);
                const r_key = try self.reserveTemp();
                try self.builder.emitOp(.star, a.span);
                try self.builder.emitU8(r_key);
                computed_r = r_key;
            },
        }
        defer if (computed_r != null) self.releaseTemp();

        // Helper closures emulated as inline blocks. Read = load
        // the current property value into `acc`. Store = write
        // `acc` back. Both pick the correct named/private/computed
        // opcode based on which slot was filled above.
        const Helper = struct {
            fn emitRead(this_: *Compiler, span_: Span, ro: u8, nk: ?u16, pk: ?u16, ck: ?u8) CompileError!void {
                try this_.builder.emitOp(.ldar, span_);
                try this_.builder.emitU8(ro);
                if (nk) |k| {
                    try this_.builder.emitOp(.lda_property, span_);
                    try this_.builder.emitU16(k);
                } else if (pk) |k| {
                    try this_.builder.emitOp(.lda_private, span_);
                    try this_.builder.emitU16(k);
                } else if (ck) |k| {
                    try this_.builder.emitOp(.lda_computed, span_);
                    try this_.builder.emitU8(ro);
                    _ = k;
                } else unreachable;
            }
            fn emitStore(this_: *Compiler, span_: Span, ro: u8, nk: ?u16, pk: ?u16, ck: ?u8) CompileError!void {
                if (nk) |k| {
                    try this_.builder.emitOp(.sta_property, span_);
                    try this_.builder.emitU16(k);
                    try this_.builder.emitU8(ro);
                } else if (pk) |k| {
                    try this_.builder.emitOp(.sta_private, span_);
                    try this_.builder.emitU16(k);
                    try this_.builder.emitU8(ro);
                } else if (ck) |rk| {
                    try this_.builder.emitOp(.sta_computed, span_);
                    try this_.builder.emitU8(ro);
                    try this_.builder.emitU8(rk);
                } else unreachable;
            }
        };
        // Computed keys land the key in `computed_r` but the
        // `lda_computed` opcode reads the receiver from `r_obj`
        // and the key from a separate register. Pass `computed_r`
        // through but the read helper actually reads obj from
        // `ro`. (We rebuilt above to keep this clean — the
        // computed-key read needs both ro AND ck.)
        // Adjust: emit lda_computed manually for that case.
        const has_computed = computed_r != null;

        if (a.op == .eq) {
            try self.compileExpression(a.value);
            try Helper.emitStore(self, a.span, r_obj, name_k, private_k, computed_r);
            return;
        }

        // Compound forms — read current value first.
        if (has_computed) {
            // ldar r_obj; lda_computed r_obj — but wait, lda_computed
            // expects the key in acc and the receiver in a register.
            // We have receiver in r_obj and key in computed_r. So:
            // ldar computed_r ; key → acc
            // lda_computed r_obj ; obj[acc] → acc
            try self.builder.emitOp(.ldar, a.span);
            try self.builder.emitU8(computed_r.?);
            try self.builder.emitOp(.lda_computed, a.span);
            try self.builder.emitU8(r_obj);
        } else {
            try Helper.emitRead(self, a.span, r_obj, name_k, private_k, null);
        }

        if (a.op == .amp_amp_eq or a.op == .pipe_pipe_eq or a.op == .question_question_eq) {
            // Gate on the read value. Skip rhs+store when the gate
            // says "keep the existing value."
            const gate: Op = switch (a.op) {
                .amp_amp_eq => .jmp_if_false, // skip when falsy
                .pipe_pipe_eq => .jmp_if_true, // skip when truthy
                .question_question_eq => .jmp_if_nullish,
                else => unreachable,
            };
            if (a.op == .question_question_eq) {
                // `jmp_if_nullish to_rhs / jmp end / to_rhs: rhs / store / end:`
                try self.builder.emitOp(gate, a.span);
                const to_rhs = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.emitOp(.jmp, a.span);
                const skip_rhs = self.builder.here();
                try self.builder.emitI16(0);
                const rhs_target = self.builder.here();
                try self.builder.patchI16(to_rhs, rhs_target);
                try self.compileExpression(a.value);
                try Helper.emitStore(self, a.span, r_obj, name_k, private_k, computed_r);
                const end_target = self.builder.here();
                try self.builder.patchI16(skip_rhs, end_target);
                return;
            }
            try self.builder.emitOp(gate, a.span);
            const skip_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.compileExpression(a.value);
            try Helper.emitStore(self, a.span, r_obj, name_k, private_k, computed_r);
            const end_target = self.builder.here();
            try self.builder.patchI16(skip_patch, end_target);
            return;
        }

        // Arithmetic compound — `obj.x += y`. Save current value,
        // evaluate rhs, run the op, store back.
        const r_old = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, a.span);
        try self.builder.emitU8(r_old);
        try self.compileExpression(a.value);
        const op = compoundOp(a.op) orelse return error.UnsupportedExpression;
        try self.builder.emitOp(op, a.span);
        try self.builder.emitU8(r_old);
        try Helper.emitStore(self, a.span, r_obj, name_k, private_k, computed_r);
    }

    /// §IsAnonymousFunctionDefinition (informally) — the syntactic
    /// shapes that adopt a name from their binding context.
    /// Mirrors `compileNamedValue`'s match list so the runtime
    /// `set_fn_name_from` is only emitted when needed.
    /// `ParenthesizedExpression` is transparent here: per
    /// §IsAnonymousFunctionDefinition the cover grammar reduces
    /// `(expr)` to `expr` for naming purposes, so `(function(){})`
    /// still picks up the binding's name.
    fn isAnonymousFunctionLike(expr: *const Expression) bool {
        var cur = expr;
        while (cur.* == .parenthesized) cur = cur.parenthesized.expression;
        return switch (cur.*) {
            .function_expr => |fe| fe.name == null,
            .arrow_function => true,
            .class_expr => |ce| ce.name == null,
            else => false,
        };
    }

    /// §13.2.5.5 PropertyDefinitionEvaluation step 7 / 8.f /
    /// §15.5.6.4 — when an *anonymous* function-like value is
    /// assigned through certain binding contexts (object property,
    /// class field, variable initializer, default parameter), the
    /// containing key/identifier becomes its `.name`. This helper
    /// recognises the eligible expression shapes (anonymous
    /// `FunctionExpression`, `ArrowFunction`, anonymous
    /// `ClassExpression`) and threads `name` into the corresponding
    /// template; everything else falls back to the default
    /// `compileExpression` path.
    fn compileNamedValue(self: *Compiler, expr: *const Expression, name: []const u8) CompileError!void {
        // Peel transparent `(expr)` wrappers so that
        // `id: (function(){})` still infers `name = "id"`.
        var inner = expr;
        while (inner.* == .parenthesized) inner = inner.parenthesized.expression;
        switch (inner.*) {
            .function_expr => |fe| {
                if (fe.name == null) {
                    const k = try compileFunctionTemplateExt(
                        self,
                        fe.params,
                        FunctionBody{ .block = fe.body.body },
                        name,
                        false,
                        fe.is_generator,
                        fe.is_async,
                        fe.span,
                    );
                    try self.builder.emitOp(.make_function, fe.span);
                    try self.builder.emitU16(k);
                    return;
                }
            },
            .arrow_function => |af| {
                const body: FunctionBody = switch (af.body) {
                    .block => |b| .{ .block = b.body },
                    .expression => |e| .{ .expression = e },
                };
                const k = try compileFunctionTemplateExt(
                    self,
                    af.params,
                    body,
                    name,
                    true,
                    false,
                    af.is_async,
                    af.span,
                );
                try self.builder.emitOp(.make_function, af.span);
                try self.builder.emitU16(k);
                return;
            },
            .class_expr => |ce| {
                if (ce.name == null) {
                    const k = try compileClassTemplate(
                        self,
                        name,
                        ce.superclass,
                        ce.body,
                        ce.span,
                    );
                    if (ce.superclass) |s| try self.compileExpression(s);
                    try self.builder.emitOp(.make_class, ce.span);
                    try self.builder.emitU16(k);
                    return;
                }
            },
            else => {},
        }
        try self.compileExpression(expr);
    }

    fn compileFunctionExpr(self: *Compiler, fe: ast.expression.FunctionExpr) CompileError!void {
        const name_slice = if (fe.name) |n| self.source[n.span.start..n.span.end] else null;
        // §15.2 FunctionExpression — must propagate is_generator /
        // is_async into the template so the resulting JSFunction
        // gets `is_generator=true` (returns an iterator on call)
        // / `is_async=true` (returns a Promise). The shorthand
        // `compileFunctionTemplate` hardcodes both to false and
        // would silently downgrade `function*(){}` to a regular
        // function.
        const k = try compileFunctionTemplateExt(
            self,
            fe.params,
            FunctionBody{ .block = fe.body.body },
            name_slice,
            false,
            fe.is_generator,
            fe.is_async,
            fe.span,
        );
        try self.builder.emitOp(.make_function, fe.span);
        try self.builder.emitU16(k);
    }

    fn compileArrowFunction(self: *Compiler, af: ast.expression.ArrowFunction) CompileError!void {
        const body: FunctionBody = switch (af.body) {
            .block => |b| .{ .block = b.body },
            .expression => |e| .{ .expression = e },
        };
        const k = try compileFunctionTemplate(self, af.params, body, null, true, af.span);
        try self.builder.emitOp(.make_function, af.span);
        try self.builder.emitU16(k);
    }

    fn compileCall(self: *Compiler, c: ast.expression.CallExpr) CompileError!void {
        // `super(...)` in a constructor — invoke the parent
        // constructor with `this` from the current frame. The
        // arguments compile into consecutive temps; emit
        // `super_call r_args argc`.
        if (c.callee.* == .super_) {
            // §13.3.7 — `super(...spread)`. Build an args array
            // using the same `array_spread` + numeric-index
            // shape as `compileSpreadCall`, then dispatch via
            // `super_call_spread` which unpacks at runtime.
            var has_spread = false;
            for (c.arguments) |*arg| {
                if (arg.* == .spread) {
                    has_spread = true;
                    break;
                }
            }
            if (has_spread) {
                const r_args = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.make_array, c.span);
                try self.builder.emitOp(.star, c.span);
                try self.builder.emitU8(r_args);
                const k_length = try self.internString("length");
                try self.builder.emitOp(.lda_smi, c.span);
                try self.builder.emitI32(0);
                try self.builder.emitOp(.sta_property, c.span);
                try self.builder.emitU16(k_length);
                try self.builder.emitU8(r_args);
                for (c.arguments) |*arg| {
                    if (arg.* == .spread) {
                        try self.compileExpression(arg.spread.argument);
                        try self.builder.emitOp(.array_spread, c.span);
                        try self.builder.emitU8(r_args);
                    } else {
                        try self.compileExpression(arg);
                        const r_val = try self.reserveTemp();
                        defer self.releaseTemp();
                        try self.builder.emitOp(.star, c.span);
                        try self.builder.emitU8(r_val);
                        try self.builder.emitOp(.ldar, c.span);
                        try self.builder.emitU8(r_args);
                        try self.builder.emitOp(.lda_property, c.span);
                        try self.builder.emitU16(k_length);
                        const r_idx = try self.reserveTemp();
                        defer self.releaseTemp();
                        try self.builder.emitOp(.star, c.span);
                        try self.builder.emitU8(r_idx);
                        try self.builder.emitOp(.ldar, c.span);
                        try self.builder.emitU8(r_val);
                        try self.builder.emitOp(.sta_computed, c.span);
                        try self.builder.emitU8(r_args);
                        try self.builder.emitU8(r_idx);
                        // length = length + 1
                        try self.builder.emitOp(.lda_smi, c.span);
                        try self.builder.emitI32(1);
                        try self.builder.emitOp(.add, c.span);
                        try self.builder.emitU8(r_idx);
                        try self.builder.emitOp(.sta_property, c.span);
                        try self.builder.emitU16(k_length);
                        try self.builder.emitU8(r_args);
                    }
                }
                try self.builder.emitOp(.super_call_spread, c.span);
                try self.builder.emitU8(r_args);
                try self.builder.emitOp(.init_instance_fields, c.span);
                return;
            }
            const r_first = if (c.arguments.len > 0) try self.reserveTemp() else @as(u8, 0);
            var reserved: u8 = 0;
            if (c.arguments.len > 0) {
                // First arg already reserved as r_first.
                try self.compileExpression(&c.arguments[0]);
                try self.builder.emitOp(.star, c.span);
                try self.builder.emitU8(r_first);
                reserved += 1;
                for (c.arguments[1..]) |*arg| {
                    try self.compileExpression(arg);
                    const r = try self.reserveTemp();
                    try self.builder.emitOp(.star, c.span);
                    try self.builder.emitU8(r);
                    reserved += 1;
                }
            }
            try self.builder.emitOp(.super_call, c.span);
            try self.builder.emitU8(r_first);
            try self.builder.emitU8(@intCast(c.arguments.len));
            // §15.7.10 — instance fields run AFTER super(...).
            // Emit the field-init op only when the surrounding
            // class actually has fields (ClassContext doesn't
            // carry that flag at α; for β we always emit it and
            // let the runtime skip when there are no inits).
            try self.builder.emitOp(.init_instance_fields, c.span);
            var j: u8 = 0;
            while (j < reserved) : (j += 1) self.releaseTemp();
            return;
        }

        // `super.method(...)` — read super property then call
        // with `this` = current `this` (NOT the home object).
        if (c.callee.* == .member and !c.callee.member.optional) {
            const m = c.callee.member;
            if (m.object.* == .super_) {
                return self.compileSuperMethodCall(c, m);
            }
            return self.compileMethodCall(c, m);
        }

        // Spread in call args: build a runtime args array
        // (using the same array_spread machinery as array
        // literals) and dispatch via Function.prototype.apply.
        var has_spread = false;
        for (c.arguments) |*arg| {
            if (arg.* == .spread) {
                has_spread = true;
                break;
            }
        }
        if (has_spread) {
            return self.compileSpreadCall(c);
        }

        // Compile callee → acc, save in a temp.
        try self.compileExpression(c.callee);
        // §13.5.5 — `f?.(args)` short-circuits when `f` is nullish.
        // The optional flag on a CallExpr applies to the callee
        // value just produced.
        if (c.optional) try self.emitOptionalShortCircuit(c.span);
        const r_callee = try self.reserveTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // Compile each arg, store in consecutive temps so the
        // interpreter can fetch them by `r_callee + 1.. r_callee + argc`.
        var reserved: u8 = 0;
        for (c.arguments) |*arg| {
            try self.compileExpression(arg);
            const r = try self.reserveTemp();
            reserved += 1;
            try self.builder.emitOp(.star, c.span);
            try self.builder.emitU8(r);
        }

        try self.builder.emitOp(.call, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(@intCast(c.arguments.len));

        var j: u8 = 0;
        while (j < reserved) : (j += 1) self.releaseTemp();
        self.releaseTemp(); // r_callee
    }

    /// `f(...args)` / `f(a,...rest, b)` — desugar to
    /// `f.apply(undefined, [a,...rest, b])`. We build the args
    /// array using the same array_spread / sta_computed shape as
    /// array literals, then look up `.apply` on the callee and
    /// invoke it with `this = undefined` and the args array.
    fn compileSpreadCall(self: *Compiler, c: ast.expression.CallExpr) CompileError!void {
        // 1. callee → r_callee.
        try self.compileExpression(c.callee);
        const r_callee = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // 2. Build args array — same lowering as compileArrayLiteral
        // in spread mode. We re-use the helper routine.
        const r_args = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.make_array, c.span);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_args);

        const k_length = try self.internString("length");
        try self.builder.emitOp(.lda_smi, c.span);
        try self.builder.emitI32(0);
        try self.builder.emitOp(.sta_property, c.span);
        try self.builder.emitU16(k_length);
        try self.builder.emitU8(r_args);

        for (c.arguments) |*arg| {
            if (arg.* == .spread) {
                try self.compileExpression(arg.spread.argument);
                try self.builder.emitOp(.array_spread, c.span);
                try self.builder.emitU8(r_args);
            } else {
                try self.compileExpression(arg);
                const r_val = try self.reserveTemp();
                try self.builder.emitOp(.star, c.span);
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.ldar, c.span);
                try self.builder.emitU8(r_args);
                try self.builder.emitOp(.lda_property, c.span);
                try self.builder.emitU16(k_length);
                const r_idx = try self.reserveTemp();
                try self.builder.emitOp(.star, c.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.ldar, c.span);
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.sta_computed, c.span);
                try self.builder.emitU8(r_args);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.ldar, c.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.lda_smi, c.span);
                try self.builder.emitI32(1);
                try self.builder.emitOp(.add, c.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.sta_property, c.span);
                try self.builder.emitU16(k_length);
                try self.builder.emitU8(r_args);
                self.releaseTemp(); // r_idx
                self.releaseTemp(); // r_val
            }
        }

        // 3. Look up `.apply` on the callee → r_apply.
        const k_apply = try self.internString("apply");
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.lda_property, c.span);
        try self.builder.emitU16(k_apply);
        const r_apply = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_apply);

        // 4. Stage the call args at r_apply + 1, r_apply + 2:
        // arg[0] = undefined (thisArg), arg[1] = args array.
        const r_this = try self.reserveTemp();
        try self.builder.emitOp(.lda_undefined, c.span);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_this);
        const r_args_pos = try self.reserveTemp();
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_args);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_args_pos);

        // 5. call_method: r_callee is the receiver (`f`), r_apply
        // is the function, two args.
        try self.builder.emitOp(.call_method, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(r_apply);
        try self.builder.emitU8(2);

        self.releaseTemp(); // r_args_pos
        self.releaseTemp(); // r_this
    }

    /// `obj.method(args)` / `obj['method'](args)` — emit a
    /// `CallMethod` so the runtime binds `this = obj`.
    fn compileMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // Receiver into r_recv.
        try self.compileExpression(m.object);
        const r_recv = try self.reserveTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_recv);

        // Property load → acc, save in r_callee adjacent to r_recv.
        switch (m.property) {
            .ident => |span| {
                const key_slice = self.source[span.start..span.end];
                if (key_slice.len > 0 and key_slice[0] == '#') {
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    const prefix = self.class_stack.items[self.class_stack.items.len - 1].private_prefix;
                    const arena = self.realm.classAllocator();
                    const mangled = std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, key_slice[1..] }) catch return error.OutOfMemory;
                    const k = try self.internString(mangled);
                    try self.builder.emitOp(.ldar, c.span);
                    try self.builder.emitU8(r_recv);
                    try self.builder.emitOp(.lda_private, c.span);
                    try self.builder.emitU16(k);
                } else {
                    const k = try self.internString(key_slice);
                    try self.builder.emitOp(.ldar, c.span);
                    try self.builder.emitU8(r_recv);
                    try self.builder.emitOp(.lda_property, c.span);
                    try self.builder.emitU16(k);
                }
            },
            .computed => |key_expr| {
                try self.compileExpression(key_expr);
                try self.builder.emitOp(.lda_computed, c.span);
                try self.builder.emitU8(r_recv);
            },
        }
        const r_callee = try self.reserveTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // §13.5.5 — `obj.method?.()` short-circuits when the
        // method itself is nullish. The check runs after loading
        // the method but before evaluating arguments.
        if (c.optional) try self.emitOptionalShortCircuit(c.span);

        // Args at r_callee + 1.. r_callee + argc, mirroring `call`.
        var reserved: u8 = 0;
        for (c.arguments) |*arg| {
            try self.compileExpression(arg);
            const r = try self.reserveTemp();
            reserved += 1;
            try self.builder.emitOp(.star, c.span);
            try self.builder.emitU8(r);
        }

        try self.builder.emitOp(.call_method, c.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(@intCast(c.arguments.len));

        var j: u8 = 0;
        while (j < reserved) : (j += 1) self.releaseTemp();
        self.releaseTemp(); // r_callee
        self.releaseTemp(); // r_recv
    }

    /// `super.method(args)` — look up `method` through the home
    /// object's prototype, then call with `this` bound to the
    /// CURRENT `this` (not the home object). §13.3.7.
    fn compileSuperMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // Eval super.method via super_get / super_get_computed → r_callee.
        switch (m.property) {
            .ident => |span| {
                const key_slice = self.source[span.start..span.end];
                const k = try self.internString(key_slice);
                try self.builder.emitOp(.super_get, m.span);
                try self.builder.emitU16(k);
            },
            .computed => |key_expr| {
                try self.compileExpression(key_expr);
                try self.builder.emitOp(.super_get_computed, m.span);
            },
        }
        const r_callee = try self.reserveTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // Args at r_callee + 1...
        var reserved: u8 = 0;
        for (c.arguments) |*arg| {
            if (arg.* == .spread) return error.UnsupportedExpression;
            try self.compileExpression(arg);
            const r = try self.reserveTemp();
            reserved += 1;
            try self.builder.emitOp(.star, c.span);
            try self.builder.emitU8(r);
        }

        // Read `this` into a temp acting as the receiver, then
        // emit call_method with that temp.
        const r_recv = try self.reserveTemp();
        try self.builder.emitOp(.lda_this, c.span);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_recv);

        try self.builder.emitOp(.call_method, c.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(@intCast(c.arguments.len));

        self.releaseTemp(); // r_recv
        var j: u8 = 0;
        while (j < reserved) : (j += 1) self.releaseTemp();
        self.releaseTemp(); // r_callee
    }

    /// `new f(args)` (§13.3.5). Identical layout to `Call` — same
    /// callee/arg register placement — but emits `NewCall` so the
    /// interpreter allocates the instance, binds `this`, and
    /// applies the §13.3.5.1.1 ConstructResult rule on return.
    fn compileNewExpr(self: *Compiler, n: ast.expression.NewExpr) CompileError!void {
        var has_spread = false;
        for (n.arguments) |*arg| {
            if (arg.* == .spread) {
                has_spread = true;
                break;
            }
        }
        if (has_spread) {
            return self.compileSpreadNew(n);
        }
        try self.compileExpression(n.callee);
        const r_callee = try self.reserveTemp();
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_callee);

        var reserved: u8 = 0;
        for (n.arguments) |*arg| {
            try self.compileExpression(arg);
            const r = try self.reserveTemp();
            reserved += 1;
            try self.builder.emitOp(.star, n.span);
            try self.builder.emitU8(r);
        }

        try self.builder.emitOp(.new_call, n.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(@intCast(n.arguments.len));

        var j: u8 = 0;
        while (j < reserved) : (j += 1) self.releaseTemp();
        self.releaseTemp();
    }

    /// `new C(...arr, x,...)` — desugar to `Reflect.construct(C,
    /// flat_args)`. We build the flat-args array using the same
    /// array_spread machinery as array literals, then look up
    /// `Reflect.construct` and invoke it.
    fn compileSpreadNew(self: *Compiler, n: ast.expression.NewExpr) CompileError!void {
        try self.compileExpression(n.callee);
        const r_callee = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_callee);

        // Build the flat-args array.
        const r_args = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.make_array, n.span);
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_args);
        const k_length = try self.internString("length");
        try self.builder.emitOp(.lda_smi, n.span);
        try self.builder.emitI32(0);
        try self.builder.emitOp(.sta_property, n.span);
        try self.builder.emitU16(k_length);
        try self.builder.emitU8(r_args);
        for (n.arguments) |*arg| {
            if (arg.* == .spread) {
                try self.compileExpression(arg.spread.argument);
                try self.builder.emitOp(.array_spread, n.span);
                try self.builder.emitU8(r_args);
            } else {
                try self.compileExpression(arg);
                const r_val = try self.reserveTemp();
                try self.builder.emitOp(.star, n.span);
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.ldar, n.span);
                try self.builder.emitU8(r_args);
                try self.builder.emitOp(.lda_property, n.span);
                try self.builder.emitU16(k_length);
                const r_idx = try self.reserveTemp();
                try self.builder.emitOp(.star, n.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.ldar, n.span);
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.sta_computed, n.span);
                try self.builder.emitU8(r_args);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.ldar, n.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.lda_smi, n.span);
                try self.builder.emitI32(1);
                try self.builder.emitOp(.add, n.span);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.sta_property, n.span);
                try self.builder.emitU16(k_length);
                try self.builder.emitU8(r_args);
                self.releaseTemp();
                self.releaseTemp();
            }
        }
        // Call Reflect.construct(callee, args). It allocates the
        // new instance and binds `this` correctly per §10.2.2.
        const k_reflect = try self.internString("Reflect");
        try self.builder.emitOp(.lda_global, n.span);
        try self.builder.emitU16(k_reflect);
        const k_construct = try self.internString("construct");
        try self.builder.emitOp(.lda_property, n.span);
        try self.builder.emitU16(k_construct);
        const r_construct = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_construct);
        // Position args adjacent to r_construct: r_construct+1=callee, r_construct+2=args.
        try self.builder.emitOp(.ldar, n.span);
        try self.builder.emitU8(r_callee);
        const r_a1 = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_a1);
        try self.builder.emitOp(.ldar, n.span);
        try self.builder.emitU8(r_args);
        const r_a2 = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, n.span);
        try self.builder.emitU8(r_a2);
        try self.builder.emitOp(.call, n.span);
        try self.builder.emitU8(r_construct);
        try self.builder.emitU8(2);
    }

    fn compileIdentRef(self: *Compiler, span: Span) CompileError!void {
        const name = self.source[span.start..span.end];
        const scope = self.scope orelse return error.UnresolvedReference;
        const binding = scope.resolve(name) orelse {
            // Spec-mandated keywords that don't bind via the
            // global lookup table.
            if (std.mem.eql(u8, name, "undefined")) {
                try self.builder.emitOp(.lda_undefined, span);
                return;
            }
            // Fall through to the realm's global table — the
            // host installs `print`, `console`, etc. via
            // `Realm.installBuiltins`. Resolution failure at
            // runtime raises a ReferenceError.
            const k = try self.internString(name);
            try self.builder.emitOp(.lda_global, span);
            try self.builder.emitU16(k);
            return;
        };
        try self.emitLoadBinding(binding, span);
    }

    fn compileAssignment(self: *Compiler, a: ast.expression.AssignExpr) CompileError!void {
        // §13.15. Identifier targets go through the env-binding
        // path; member-access targets (`obj.x = …`) are later.
        // Peel `(target)` wrappers — `(x) = 1` is just `x = 1`
        // syntactically (§13.15.1 IsValidSimpleAssignmentTarget
        // walks through cover grammar transparently).
        var target_ptr = a.target;
        while (target_ptr.* == .parenthesized) target_ptr = target_ptr.parenthesized.expression;
        if (target_ptr.* == .member) {
            try self.compileMemberAssignment(a);
            return;
        }
        // §13.15.5 Destructuring Assignment — when the LHS is an
        // ArrayLiteral or ObjectLiteral, the parser hands us the
        // expression form and we reinterpret it as a pattern at
        // compile time. Handles defaults, rest, nesting, member
        // / identifier leaves. Compound assignment (`[a]+=x`)
        // is a SyntaxError; the parser already filters these,
        // so reaching here implies `op == .eq`.
        if ((target_ptr.* == .array_literal or target_ptr.* == .object_literal) and a.op == .eq) {
            try self.compileExpression(a.value);
            try self.compileAssignmentPattern(target_ptr.*);
            return;
        }
        if (target_ptr.* != .identifier_reference) {
            return error.UnsupportedExpression;
        }
        const name = self.source[target_ptr.identifier_reference.span.start..target_ptr.identifier_reference.span.end];
        const scope = self.scope orelse return error.UnresolvedReference;
        const binding: Binding = scope.resolve(name) orelse Binding{
            // Not in any user-visible scope. Treat the assignment
            // as a global write — `sta_global` creates the binding
            // if absent. This matches the "create on assign" path
            // that real engines take for forward-declared
            // top-level vars and is also what's needed for tests
            // that compile assignments to names whose
            // reachability is gated by an earlier throw (the
            // assignment never actually runs). Strict-mode
            // ReferenceError on truly-unresolvable PutValue is a
            // runtime check we leave to `sta_global` once we wire
            // a globalThis sentinel; today every top-level write
            // succeeds the way browsers do under sloppy mode.
            .name = name,
            .env_slot = 0,
            .env_depth = 0,
            .kind = .var_,
            .span = a.target.span(),
            .is_global = true,
        };
        if (binding.kind == .const_) {
            try self.report(.assignment_to_const, a.span);
            return error.AssignmentToConst;
        }

        if (a.op == .eq) {
            // §13.15.2 — for plain `x = e` where `e` is an
            // anonymous function-like, the binding identifier
            // becomes the function's `.name`. Compound forms
            // (`x += e`) and logical forms (`x ||= e`) don't
            // qualify per spec.
            try self.compileNamedValue(a.value, name);
        } else if (a.op == .amp_amp_eq or a.op == .pipe_pipe_eq or a.op == .question_question_eq) {
            // §13.15.4 Logical assignment — `x &&= y`, `x ||= y`,
            // `x ??= y`. Reads `x` once; if the gate fails, leaves
            // `x` unchanged (skipping the rhs and the store).
            try self.emitLoadBinding(binding, a.target.span());
            const gate: Op = switch (a.op) {
                .amp_amp_eq => .jmp_if_false,
                .pipe_pipe_eq => .jmp_if_true,
                .question_question_eq => .jmp_if_nullish,
                else => unreachable,
            };
            // For `&&=`: skip rhs+store when `x` is falsy → keep `x`.
            // For `||=`: skip rhs+store when `x` is truthy → keep `x`.
            // For `??=`: rhs+store run only when `x` is nullish.
            // The simplest encoding for the inverted senses is to
            // emit the inverse gate around the rhs/store. `&&=`
            // and `||=` use the natural gate above (skip when the
            // gate fires); `??=` is also "skip when not nullish",
            // so we emit the inverse: jump-past-rhs-when-not-nullish.
            if (a.op == .question_question_eq) {
                // `jmp_if_nullish to_rhs / jmp end / to_rhs: rhs / store / end:`
                try self.builder.emitOp(gate, a.span);
                const to_rhs = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.emitOp(.jmp, a.span);
                const skip_rhs = self.builder.here();
                try self.builder.emitI16(0);
                const rhs_target = self.builder.here();
                try self.builder.patchI16(to_rhs, rhs_target);
                try self.compileExpression(a.value);
                try self.emitStoreBinding(binding, a.span);
                const end_target = self.builder.here();
                try self.builder.patchI16(skip_rhs, end_target);
                return;
            }
            // `&&=`: jmp_if_false to skip rhs (leaving falsy `x` in acc).
            // `||=`: jmp_if_true to skip rhs (leaving truthy `x` in acc).
            try self.builder.emitOp(gate, a.span);
            const skip_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.compileExpression(a.value);
            try self.emitStoreBinding(binding, a.span);
            const skip_target = self.builder.here();
            try self.builder.patchI16(skip_patch, skip_target);
            return;
        } else {
            // Compound assignment: `x += y` ⇔ `x = x op y`.
            // Materialise `x` into a temp, compile `y` into acc,
            // then run the op. The TDZ check still gates the
            // initial read for `let`/`const`.
            const t = try self.reserveTemp();
            defer self.releaseTemp();
            try self.emitLoadBinding(binding, a.target.span());
            try self.builder.emitOp(.star, a.target.span());
            try self.builder.emitU8(t);
            try self.compileExpression(a.value);
            const op = compoundOp(a.op) orelse return error.UnsupportedExpression;
            try self.builder.emitOp(op, a.span);
            try self.builder.emitU8(t);
        }
        try self.emitStoreBinding(binding, a.span);
    }

    // ── Literals ────────────────────────────────────────────────────────

    fn compileNumeric(self: *Compiler, span: Span) CompileError!void {
        const text = self.source[span.start..span.end];
        const num = parseNumericLiteral(text) catch return error.BadNumericLiteral;
        // Smi-fast-path: if the value is a non-negative integer that
        // fits in i32 and equals its float form exactly, emit
        // LdaSmi. Otherwise spill to the constant pool. Negative
        // numbers go through unary `negate` in the AST, so the
        // literal itself is always non-negative here.
        if (asExactSmi(num)) |i| {
            try self.builder.emitOp(.lda_smi, span);
            try self.builder.emitI32(i);
        } else {
            const k = try self.builder.addConstant(Value.fromDouble(num));
            try self.builder.emitOp(.lda_constant, span);
            try self.builder.emitU16(k);
        }
    }

    /// `0n` / `42n` / `0xffn` / `0b1010n` etc. — strip the `n`
    /// suffix, parse the digits, allocate a `JSBigInt` in the
    /// realm heap, and store it as a constant. later uses
    /// i128 storage; literals exceeding ±2^127 throw at parse
    /// time (real arbitrary-precision is later).
    fn compileBigInt(self: *Compiler, span: Span) CompileError!void {
        const text = self.source[span.start..span.end];
        if (text.len == 0 or text[text.len - 1] != 'n') return error.BadNumericLiteral;
        const digits = text[0 .. text.len - 1];
        const value = parseBigIntLiteral(digits) catch return error.BadNumericLiteral;
        const bi = self.realm.heap.allocateBigInt(value) catch return error.OutOfMemory;
        const k = try self.builder.addConstant(@import("../runtime/heap.zig").taggedBigInt(bi));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k);
    }

    fn compileString(self: *Compiler, span: Span) CompileError!void {
        // The literal span includes the surrounding quote bytes.
        // Decode escape sequences when present; otherwise pass the
        // raw inner slice straight through.
        const raw = self.source[span.start..span.end];
        std.debug.assert(raw.len >= 2); // parser enforces matching quotes
        const inner = raw[1 .. raw.len - 1];
        const decoded = decodeStringContent(self.allocator, inner) catch return error.UnsupportedExpression;
        defer self.allocator.free(decoded);

        const s = self.realm.heap.allocateString(decoded) catch return error.OutOfMemory;
        const k = try self.builder.addConstant(Value.fromString(s));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k);
    }

    // ── Unary / Binary / Logical ────────────────────────────────────────

    fn compileUnary(self: *Compiler, u: ast.expression.UnaryExpr) CompileError!void {
        // §13.5.2 `void X` evaluates X for side effects and yields
        // `undefined`. We compile the operand (its value lands in
        // acc and is then overwritten by `LdaUndefined`).
        if (u.op == .void_) {
            try self.compileExpression(u.operand);
            try self.builder.emitOp(.lda_undefined, u.span);
            return;
        }
        // §13.5.1.2 `delete UnaryExpression`. Three flavours:
        // • `delete obj.x` → `del_named_property k, r_obj`
        // • `delete obj[expr]` → `del_computed_property r_obj, r_key`
        // • `delete (anything else)` → evaluate operand for side
        // effects, return `true` (the operand wasn't a Reference,
        // §13.5.1.2 step 2).
        // Bare-identifier deletes (`delete x`) are rejected by the
        // parser in strict mode, so we never see them here.
        if (u.op == .delete_) {
            // Optional-chain operands (`delete obj?.x`) — defer to
            // the existing UnsupportedExpression path. §13.5.1.2 has
            // its own short-circuit for `?.` — out of later scope.
            if (u.operand.* == .member) {
                const m = u.operand.member;
                if (m.optional) return error.UnsupportedExpression;
                if (m.object.* == .super_) {
                    // `delete super.x` — §13.5.1.2 step 5.a is a
                    // ReferenceError. Compile to a runtime throw
                    // via plain unsupported for now.
                    return error.UnsupportedExpression;
                }
                switch (m.property) {
                    .ident => |sp| {
                        const key_slice = self.source[sp.start..sp.end];
                        // Private-name deletes (`delete obj.#x`)
                        // are SyntaxErrors per §13.5.1.1; the parser
                        // catches them. Plain named delete:
                        if (key_slice.len > 0 and key_slice[0] == '#') {
                            return error.UnsupportedExpression;
                        }
                        const k = try self.internString(key_slice);
                        try self.compileExpression(m.object);
                        const r_obj = try self.reserveTemp();
                        defer self.releaseTemp();
                        try self.builder.emitOp(.star, u.span);
                        try self.builder.emitU8(r_obj);
                        try self.builder.emitOp(.del_named_property, u.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(r_obj);
                    },
                    .computed => |key_expr| {
                        try self.compileExpression(m.object);
                        const r_obj = try self.reserveTemp();
                        defer self.releaseTemp();
                        try self.builder.emitOp(.star, u.span);
                        try self.builder.emitU8(r_obj);

                        try self.compileExpression(key_expr);
                        const r_key = try self.reserveTemp();
                        defer self.releaseTemp();
                        try self.builder.emitOp(.star, u.span);
                        try self.builder.emitU8(r_key);

                        try self.builder.emitOp(.del_computed_property, u.span);
                        try self.builder.emitU8(r_obj);
                        try self.builder.emitU8(r_key);
                    },
                }
                return;
            }
            // Any non-Reference operand: evaluate for side effects,
            // discard the value, and yield `true`.
            try self.compileExpression(u.operand);
            try self.builder.emitOp(.lda_true, u.span);
            return;
        }
        // §13.5.3 — `typeof Identifier` of an unresolvable
        // Reference returns "undefined" instead of throwing
        // ReferenceError. We detect the bare-identifier case at
        // compile time: if the name doesn't resolve to any
        // local/closed-over binding, emit `lda_global_or_undef`
        // (silent miss). TDZ / let / const cases still resolve
        // to a real binding so they keep their throw-on-hole
        // behavior, matching the spec.
        if (u.op == .typeof_ and u.operand.* == .identifier_reference) {
            const span = u.operand.identifier_reference.span;
            const name = self.source[span.start..span.end];
            const scope = self.scope orelse return error.UnresolvedReference;
            if (scope.resolve(name) == null and !std.mem.eql(u8, name, "undefined")) {
                const k = try self.internString(name);
                try self.builder.emitOp(.lda_global_or_undef, span);
                try self.builder.emitU16(k);
                try self.builder.emitOp(.typeof_, u.span);
                return;
            }
        }
        try self.compileExpression(u.operand);
        const op: Op = switch (u.op) {
            .minus => .negate,
            .plus => .to_number,
            .bang => .logical_not,
            .tilde => .bit_not,
            .typeof_ => .typeof_,
            .void_ => unreachable, // handled above
            .delete_ => unreachable, // handled above
        };
        try self.builder.emitOp(op, u.span);
    }

    fn compileBinary(self: *Compiler, b: ast.expression.BinaryExpr) CompileError!void {
        const op: Op = switch (b.op) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .star_star => .pow,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .lt_lt => .shl,
            .gt_gt => .shr,
            .gt_gt_gt => .shr_u,
            .eq_eq => .eq,
            .eq_eq_eq => .strict_eq,
            .bang_eq => .neq,
            .bang_eq_eq => .strict_neq,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .instanceof_ => .instanceof_,
            .in_ => .in_op,
        };

        // LHS into a temp register, RHS into the accumulator,
        // then `<op> <reg>` runs `acc = reg <op> acc`.
        try self.compileExpression(b.lhs);
        const r = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, b.lhs.span());
        try self.builder.emitU8(r);
        try self.compileExpression(b.rhs);
        try self.builder.emitOp(op, b.span);
        try self.builder.emitU8(r);
    }

    fn compileLogical(self: *Compiler, l: ast.expression.LogicalExpr) CompileError!void {
        // §13.13 short-circuit semantics:
        // a && b: if !ToBoolean(a) → result = a; else result = b.
        // a || b: if ToBoolean(a) → result = a; else result = b.
        // a ?? b: if a is null/undefined → result = b; else a.
        //
        // later has no `JmpIfNullish` opcode yet — until later lands
        // it, `??` is unsupported. `&&` and `||` lower to a single
        // conditional jump each.
        try self.compileExpression(l.lhs);
        switch (l.op) {
            .and_and => {
                // `acc = lhs`. If false-ish, leave it; else compile rhs.
                try self.builder.emitOp(.jmp_if_false, l.span);
                const patch = self.builder.here();
                try self.builder.emitI16(0);
                try self.compileExpression(l.rhs);
                const target = self.builder.here();
                try self.builder.patchI16(patch, target);
            },
            .or_or => {
                try self.builder.emitOp(.jmp_if_true, l.span);
                const patch = self.builder.here();
                try self.builder.emitI16(0);
                try self.compileExpression(l.rhs);
                const target = self.builder.here();
                try self.builder.patchI16(patch, target);
            },
            .nullish => {
                // §13.13.1 `lhs ?? rhs` — return `lhs` unless it
                // is null/undefined. Emit a `jmp_if_nullish` to
                // the rhs branch; otherwise skip past it so `acc`
                // keeps the lhs.
                try self.builder.emitOp(.jmp_if_nullish, l.span);
                const to_rhs = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.emitOp(.jmp, l.span);
                const skip_rhs = self.builder.here();
                try self.builder.emitI16(0);
                const rhs_target = self.builder.here();
                try self.builder.patchI16(to_rhs, rhs_target);
                try self.compileExpression(l.rhs);
                const end_target = self.builder.here();
                try self.builder.patchI16(skip_rhs, end_target);
            },
        }
    }

    fn compileConditional(self: *Compiler, c: ast.expression.CondExpr) CompileError!void {
        // test: if false-ish, jump to else; else fall through.
        try self.compileExpression(c.test_);
        try self.builder.emitOp(.jmp_if_false, c.span);
        const else_patch = self.builder.here();
        try self.builder.emitI16(0);

        try self.compileExpression(c.consequent);
        try self.builder.emitOp(.jmp, c.span);
        const end_patch = self.builder.here();
        try self.builder.emitI16(0);

        const else_target = self.builder.here();
        try self.builder.patchI16(else_patch, else_target);
        try self.compileExpression(c.alternate);

        const end_target = self.builder.here();
        try self.builder.patchI16(end_patch, end_target);
    }

    fn compileSequence(self: *Compiler, s: ast.expression.SequenceExpr) CompileError!void {
        std.debug.assert(s.expressions.len > 0);
        for (s.expressions) |*e| try self.compileExpression(e);
        // Result of the comma operator is the last operand. Falls
        // out naturally because the last compileExpression leaves
        // its result in acc.
    }

/// Map a compound-assignment op token to the bytecode op that
/// computes `acc = lhs <op> rhs`. The bytecode-binary convention
/// (LHS-in-reg, RHS-in-acc) lines up directly with the existing
/// arithmetic opcodes; we just dispatch on the assignment op.
fn compoundOp(op: AssignmentOp) ?Op {
    return switch (op) {
        .eq => null, // simple assignment — caller handles
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .star_star_eq => .pow,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        .gt_gt_gt_eq => .shr_u,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        // `&&=` / `||=` / `??=` short-circuit; later leaves them
        // as future work alongside the later `??` op.
        .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => null,
    };
}

// ── Statement compilation ──────────────────────────────────────────────

pub fn compileStatement(self: *Compiler, stmt: *const Statement) CompileError!void {
    switch (stmt.*) {
        .expression => |es| {
            try self.compileExpression(&es.expression);
            // The expression's value lands in acc and stays there
            // until the next statement overwrites it. Top-level
            // `Return` reads whatever the last statement leaves.
        },
        .empty => {},
        .block => |b| try self.compileBlock(b.body, b.span),
        .lexical => |ld| try self.compileLexicalDecl(ld),
        .if_ => |s| try self.compileIf(s),
        .while_ => |s| try self.compileWhile(s),
        .do_while => |s| try self.compileDoWhile(s),
        .for_ => |s| try self.compileFor(s),
        .break_ => |s| try self.compileBreak(s),
        .continue_ => |s| try self.compileContinue(s),
        .throw_ => |s| try self.compileThrow(s),
        .try_ => |s| try self.compileTry(s),
        .return_ => |s| try self.compileReturn(s),
        .function_decl => |fd| try self.compileFunctionDecl(fd),
        .class_decl => |cd| try self.compileClassDecl(cd),
        .for_in_of => |s| try self.compileForInOf(s),
        .switch_ => |s| try self.compileSwitch(s),
        .debugger_ => {}, // no-op for later — V8 / d8 also no-op without a debugger attached
        .import_decl => |id| try self.compileImportDecl(id),
        .export_decl => |ed| try self.compileExportDecl(ed),
    }
}

/// §16.2.2 ImportDeclaration. In module mode emits
/// a `module_load` for the source specifier, then for each
/// imported name reads the matching property off the returned
/// namespace and stores into the local binding's env slot. In
/// script mode the bindings are declared but stay in TDZ
/// (legacy later path).
fn compileImportDecl(self: *Compiler, id: ast.statement.ImportDecl) CompileError!void {
    if (id.default) |bid| {
        const name = self.source[bid.span.start..bid.span.end];
        _ = try self.declareBinding(name, .let_, bid.span);
    }
    if (id.namespace) |bid| {
        const name = self.source[bid.span.start..bid.span.end];
        _ = try self.declareBinding(name, .let_, bid.span);
    }
    for (id.named) |spec| {
        const name = self.source[spec.local.span.start..spec.local.span.end];
        _ = try self.declareBinding(name, .let_, spec.local.span);
    }

    if (!self.is_module) return;

    // Strip surrounding quotes from the StringLiteral span.
    const raw = self.source[id.source.start..id.source.end];
    if (raw.len < 2) return error.UnsupportedStatement;
    const spec_text = raw[1 .. raw.len - 1];
    const k_spec = try self.internString(spec_text);
    try self.builder.emitOp(.module_load, id.span);
    try self.builder.emitU16(k_spec);

    const r_ns = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, id.span);
    try self.builder.emitU8(r_ns);

    if (id.namespace) |bid| {
        try self.builder.emitOp(.ldar, bid.span);
        try self.builder.emitU8(r_ns);
        const name = self.source[bid.span.start..bid.span.end];
        try self.assignToBinding(name, bid.span);
    }
    if (id.default) |bid| {
        const k_default = try self.internString("default");
        try self.builder.emitOp(.ldar, bid.span);
        try self.builder.emitU8(r_ns);
        try self.builder.emitOp(.lda_property, bid.span);
        try self.builder.emitU16(k_default);
        const name = self.source[bid.span.start..bid.span.end];
        try self.assignToBinding(name, bid.span);
    }
    for (id.named) |spec| {
        const imported_text = self.source[spec.imported_span.start..spec.imported_span.end];
        const imported_name = if (imported_text.len >= 2 and (imported_text[0] == '"' or imported_text[0] == '\''))
            imported_text[1 .. imported_text.len - 1]
        else
            imported_text;
        const k_imp = try self.internString(imported_name);
        try self.builder.emitOp(.ldar, spec.local.span);
        try self.builder.emitU8(r_ns);
        try self.builder.emitOp(.lda_property, spec.local.span);
        try self.builder.emitU16(k_imp);
        const local_name = self.source[spec.local.span.start..spec.local.span.end];
        try self.assignToBinding(local_name, spec.local.span);
    }
}

/// §16.2.3 ExportDeclaration. In module mode emits
/// `module_export` opcodes that publish bindings to the
/// executing module's namespace.
fn compileExportDecl(self: *Compiler, ed: ast.statement.ExportDecl) CompileError!void {
    switch (ed.body) {
        .declaration => |stmt| {
            try self.compileStatement(stmt);
            if (self.is_module) try self.publishExportedNamesFromDecl(stmt);
        },
        .default_value => |e| {
            try self.compileExpression(&e);
            if (self.is_module) {
                const k_default = try self.internString("default");
                try self.builder.emitOp(.module_export, ed.span);
                try self.builder.emitU16(k_default);
            }
        },
        .named => |body| {
            if (!self.is_module) return;
            for (body.specifiers) |spec| {
                const local_name = self.source[spec.local_span.start..spec.local_span.end];
                const exported_name = self.source[spec.exported_span.start..spec.exported_span.end];
                try self.emitBindingRead(local_name, spec.span);
                const k = try self.internString(exported_name);
                try self.builder.emitOp(.module_export, spec.span);
                try self.builder.emitU16(k);
            }
        },
        .all => {},
    }
}

/// After compiling an `export <decl>`, re-read each declared
/// name and emit a `module_export` for it.
fn publishExportedNamesFromDecl(self: *Compiler, stmt: *const Statement) CompileError!void {
    switch (stmt.*) {
        .lexical => |ld| {
            for (ld.declarators) |d| {
                if (identifierName(self.source, d.name)) |name| {
                    try self.emitBindingRead(name, d.span);
                    const k = try self.internString(name);
                    try self.builder.emitOp(.module_export, d.span);
                    try self.builder.emitU16(k);
                }
            }
        },
        .function_decl => |fd| {
            const name = self.source[fd.name.span.start..fd.name.span.end];
            try self.emitBindingRead(name, fd.name.span);
            const k = try self.internString(name);
            try self.builder.emitOp(.module_export, fd.name.span);
            try self.builder.emitU16(k);
        },
        .class_decl => |cd| {
            const name = self.source[cd.name.span.start..cd.name.span.end];
            try self.emitBindingRead(name, cd.name.span);
            const k = try self.internString(name);
            try self.builder.emitOp(.module_export, cd.name.span);
            try self.builder.emitU16(k);
        },
        else => {},
    }
}

fn emitBindingRead(self: *Compiler, name: []const u8, span: Span) CompileError!void {
    const scope = self.scope orelse return error.UnresolvedReference;
    const binding = scope.resolve(name) orelse return error.UnresolvedReference;
    const depth = self.env_depth - binding.env_depth;
    try self.builder.emitOp(.lda_env, span);
    try self.builder.emitU8(depth);
    try self.builder.emitU8(binding.env_slot);
}

/// §14.12 SwitchStatement.
/// Layout: evaluate discriminant once, save in a temp; emit a
/// linear chain of `===` checks each jumping to the matching
/// case body; emit the bodies in source order, with fall-through
/// between cases when there's no intervening `break`. `break`
/// exits via the surrounding `LoopContext`'s break-patches list.
/// `for (binding of iterable) body` (§14.7.5). later uses an
/// array-like iteration protocol — walks `iterable.length` and
/// numeric-index access. Real `Symbol.iterator` dispatch lands
/// later once `Symbol` exists; for now this covers arrays
/// + strings, which is the bulk of test262's for-of use.
/// `for-in` and `for await` are deferred.
fn compileForInOf(self: *Compiler, s: ast.statement.ForInOfStmt) CompileError!void {
    // §14.7.5 `for await … of` — emits the same skeleton as
    // `for-of` but opens an async iterator (`@@asyncIterator`
    // first, sync fallback) and awaits each `next()` result.
    // The surrounding function must be async (or async generator)
    // for `await` to suspend; the parser already enforces that.

    // Determine the binding shape early — we need it before
    // opening the loop scope so we know whether to mark it as
    // `has_own_env` (closure-per-iteration semantics for
    // `let`/`const`).
    var bind_kind: BindingKind = .let_;
    var bind_name: []const u8 = "";
    var bind_span: Span = s.span;
    var bind_target_kind: enum { binding, identifier_assign, pattern, member_assign, assignment_pattern } = .binding;
    var pattern_target: ?ast.statement.BindingTarget = null;
    var member_target: ?ast.expression.MemberExpr = null;
    // §13.15.5 — for-of LHS shaped as an array/object literal is
    // re-parsed as an AssignmentPattern (§14.7.5.1 step 6.h.iv).
    // We hold the expression here and route through
    // `compileAssignmentPattern` at body emit.
    var assignment_pattern_target: ?ast.expression.Expression = null;
    switch (s.left) {
        .lexical => |ld| {
            if (ld.kind == .var_) bind_kind = .var_ else if (ld.kind == .let_) bind_kind = .let_ else bind_kind = .const_;
            if (ld.declarators.len != 1) return error.UnsupportedStatement;
            const d = ld.declarators[0];
            switch (d.name) {
                .identifier => |id| {
                    bind_name = self.source[id.span.start..id.span.end];
                    bind_span = id.span;
                },
                .array, .object => {
                    pattern_target = d.name;
                    bind_target_kind = .pattern;
                    bind_span = d.span;
                },
            }
        },
        .expression => |e| switch (e) {
            .identifier_reference => |ir| {
                bind_name = self.source[ir.span.start..ir.span.end];
                bind_span = ir.span;
                bind_target_kind = .identifier_assign;
            },
            // §14.7.5.1 — for-of LHS may be any LeftHandSideExpression,
            // including `x.y` / `x[k]` member access. The iteration
            // value is assigned via the same machinery as
            // `x.y = value`. (Optional chains on the LHS aren't
            // valid receivers per the spec; reject them.)
            .member => |m| {
                if (m.optional) return error.UnsupportedStatement;
                if (m.object.* == .super_) return error.UnsupportedStatement;
                member_target = m;
                bind_span = m.span;
                bind_target_kind = .member_assign;
            },
            // Array / object literal LHS in a for-of head is the
            // assignment-destructuring form: `for ([a,b] of …)`,
            // `for ({x: a.b} of …)`. Per §14.7.5.1 the LHS is
            // re-parsed as an AssignmentPattern. The parser already
            // produces an array/object literal for these (since
            // they're indistinguishable from expressions until we
            // see the `of`); we route them through
            // `compileAssignmentPattern`.
            .array_literal, .object_literal => {
                assignment_pattern_target = e;
                bind_span = switch (e) {
                    .array_literal => |al| al.span,
                    .object_literal => |ol| ol.span,
                    else => unreachable,
                };
                bind_target_kind = .assignment_pattern;
            },
            else => return error.UnsupportedStatement,
        },
    }

    // §14.7.5.6 CreatePerIterationEnvironment — when the loop
    // binding is `let` / `const`, every iteration runs in a
    // fresh env so closures captured inside the body see the
    // iteration-specific value. `var` and bare-identifier
    // assignment fall through to the function env (the spec
    // gives them the legacy single-binding behaviour). Pattern
    // targets get the same treatment as identifier targets.
    const per_iter_env = (bind_target_kind == .binding or bind_target_kind == .pattern) and
        (bind_kind == .let_ or bind_kind == .const_);

    var loop_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = per_iter_env };
    defer loop_scope.deinit(self.allocator);
    const saved_scope = self.scope;
    self.scope = &loop_scope;
    defer self.scope = saved_scope;

    // env_depth is NOT bumped yet — the iterable expression
    // evaluates in the OUTER env (per §14.7.5.6 step 1 of
    // ForIn/OfHeadEvaluation, the iterable is read before
    // CreatePerIterationEnvironment). The bump happens after
    // the iterable+`iter_open` so only the body sees the
    // per-iteration depth.
    const saved_env_depth = self.env_depth;
    defer self.env_depth = saved_env_depth;

    // §14.7.5.6 ForIn/OfBodyEvaluation. Eval the iterable, open
    // an iterator (for-of: §7.4.1 GetIterator; for-in:
    // §14.7.5.6 EnumerateObjectProperties), then drive
    // `it.next()` until `result.done`.
    try self.compileExpression(&s.right);
    const open_op: Op = if (s.kind == .in_)
        .for_in_open
    else if (s.is_await)
        .async_iter_open
    else
        .iter_open;
    try self.builder.emitOp(open_op, s.span);
    const r_iter = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, s.span);
    try self.builder.emitU8(r_iter);

    const k_next = try self.internString("next");
    const k_value = try self.internString("value");
    const k_done = try self.internString("done");

    // r_result is reused across iterations.
    const r_result = try self.reserveTemp();
    defer self.releaseTemp();

    const loop_start = self.builder.here();

    // r_result = r_iter.next()
    try self.builder.emitOp(.ldar, s.span);
    try self.builder.emitU8(r_iter);
    try self.builder.emitOp(.lda_property, s.span);
    try self.builder.emitU16(k_next);
    const r_next_fn = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, s.span);
    try self.builder.emitU8(r_next_fn);
    // call_method r_recv=r_iter, r_callee=r_next_fn, argc=0
    try self.builder.emitOp(.call_method, s.span);
    try self.builder.emitU8(r_iter);
    try self.builder.emitU8(r_next_fn);
    try self.builder.emitU8(0);
    // §14.7.5 / §27.1.4.4 — for-await-of awaits each next()
    // result. Sync iters return `{done, value}` directly;
    // `await` on a non-Promise resolves to the value as-is, so
    // the sync fallback in `async_iter_open` composes.
    if (s.is_await) try self.builder.emitOp(.await_, s.span);
    try self.builder.emitOp(.star, s.span);
    try self.builder.emitU8(r_result);

    // if (r_result.done) jmp exit
    try self.builder.emitOp(.ldar, s.span);
    try self.builder.emitU8(r_result);
    try self.builder.emitOp(.lda_property, s.span);
    try self.builder.emitU16(k_done);
    try self.builder.emitOp(.jmp_if_true, s.span);
    const exit_patch = self.builder.here();
    try self.builder.emitI16(0);

    // §14.7.5.6 CreatePerIterationEnvironment — push a fresh
    // env per iteration so closures captured inside the body
    // see this iteration's binding value. The compile-time
    // env_depth is bumped here so the body's binding accesses
    // pick up the +1 depth.
    //
    // Slot allocation note: the per-iter env has its OWN slot
    // pool, separate from the enclosing function's. We borrow
    // the global `env_slot_count` for it (reset to 0 here, the
    // body's lexicals append to it, restored on the way out)
    // and patch the `make_environment` size operand at the end
    // so it matches the actual count. Without this the loop
    // variable and the body's first `const` collide on slot 0.
    var per_iter_size_patch: usize = 0;
    var saved_per_iter_slot_count: u8 = 0;
    if (per_iter_env) {
        saved_per_iter_slot_count = self.env_slot_count;
        self.env_slot_count = 0;
        try self.builder.emitOp(.make_environment, s.span);
        per_iter_size_patch = self.builder.code.items.len;
        try self.builder.emitU8(0); // placeholder; patched below
        self.env_depth = saved_env_depth + 1;
        if (pattern_target) |pt| {
            try self.declarePatternBindings(pt, bind_kind);
        } else {
            // Use the regular slot allocator so the body's
            // inner lexicals know where to land.
            _ = try self.declareBinding(bind_name, bind_kind, bind_span);
        }
    } else if (bind_target_kind == .binding) {
        // var / non-let binding lives in the function env.
        _ = try self.declareBinding(bind_name, bind_kind, bind_span);
    } else if (bind_target_kind == .pattern) {
        // var-pattern: declare each leaf in the function env.
        try self.declarePatternBindings(pattern_target.?, bind_kind);
    }

    // value = r_result.value → bind
    try self.builder.emitOp(.ldar, s.span);
    try self.builder.emitU8(r_result);
    try self.builder.emitOp(.lda_property, s.span);
    try self.builder.emitU16(k_value);

    // Assign to the binding (lexical, identifier-assign target,
    // member target, assignment pattern, or destructuring pattern
    // walk).
    if (pattern_target) |pt| {
        try self.compileDestructure(pt);
    } else if (member_target) |m| {
        try self.compileForOfMemberAssign(m, s.span);
    } else if (assignment_pattern_target) |ap| {
        try self.compileAssignmentPattern(ap);
    } else {
        try self.assignToBinding(bind_name, bind_span);
    }

    var ctx: LoopContext = .{
        .continue_target = 0,
        .needs_env_pop = per_iter_env,
        // §7.4.6 IteratorClose — `for-of` only. `for-in` walks
        // own keys directly and has no `.return()` contract.
        .iter_register = if (s.kind == .in_) null else r_iter,
        .parent = self.current_loop,
        .entry_finally_chain = self.finally_chain,
    };
    defer ctx.deinit(self.allocator);
    const saved_loop = self.current_loop;
    self.current_loop = &ctx;
    defer self.current_loop = saved_loop;

    try self.compileStatement(s.body);

    // `continue` jumps to the per-iter env teardown.
    const incr_target = self.builder.here();
    for (ctx.continue_patches.items) |p| try self.builder.patchI16(p, incr_target);
    ctx.continue_target = incr_target;

    // Pop the per-iter env before jumping back so the next
    // iteration parents to the same outer env.
    if (per_iter_env) {
        try self.builder.emitOp(.pop_env, s.span);
    }

    // jmp loop_start
    try self.builder.emitOp(.jmp, s.span);
    const back_patch = self.builder.here();
    try self.builder.emitI16(0);
    try self.builder.patchI16(back_patch, loop_start);

    const exit_target = self.builder.here();
    try self.builder.patchI16(exit_patch, exit_target);
    for (ctx.break_patches.items) |p| try self.builder.patchI16(p, exit_target);

    // Patch the per-iter `make_environment` size to whatever
    // env_slot_count grew to (iteration var + body lexicals),
    // and restore the enclosing function's slot counter.
    if (per_iter_env) {
        self.builder.code.items[per_iter_size_patch] = self.env_slot_count;
        self.env_slot_count = saved_per_iter_slot_count;
    }
}

/// Assign `acc` (the current iteration's value) to a
/// member-expression target (`x.y` / `x[k]`) — the same
/// shape as `compileMemberAssignment` but driven from the
/// for-of loop body where the value is already in `acc`.
fn compileForOfMemberAssign(self: *Compiler, m: ast.expression.MemberExpr, span: Span) CompileError!void {
    const r_value = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, span);
    try self.builder.emitU8(r_value);

    try self.compileExpression(m.object);
    const r_obj = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, span);
    try self.builder.emitU8(r_obj);

    switch (m.property) {
        .ident => |kspan| {
            const raw = self.source[kspan.start..kspan.end];
            if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
            const key = try self.decodeIdentifierName(raw);
            const k = try self.internString(key);
            try self.builder.emitOp(.ldar, span);
            try self.builder.emitU8(r_value);
            try self.builder.emitOp(.sta_property, span);
            try self.builder.emitU16(k);
            try self.builder.emitU8(r_obj);
        },
        .computed => |key_expr| {
            try self.compileExpression(key_expr);
            const r_key = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, span);
            try self.builder.emitU8(r_key);
            try self.builder.emitOp(.ldar, span);
            try self.builder.emitU8(r_value);
            try self.builder.emitOp(.sta_computed, span);
            try self.builder.emitU8(r_obj);
            try self.builder.emitU8(r_key);
        },
    }
}

fn compileSwitch(self: *Compiler, s: ast.statement.SwitchStmt) CompileError!void {
    // A new block scope wraps the switch so `let`/`const` in case
    // bodies are scoped to the switch (§14.12.4 step 3).
    var switch_scope: Scope = .{ .parent = self.scope, .kind = .block };
    defer switch_scope.deinit(self.allocator);
    const saved_scope = self.scope;
    self.scope = &switch_scope;
    defer self.scope = saved_scope;

    try self.compileExpression(&s.discriminant);
    const r_disc = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, s.span);
    try self.builder.emitU8(r_disc);

    // Per-case forward-jump patches into the body region.
    var body_patches = try self.allocator.alloc(u32, s.cases.len);
    defer self.allocator.free(body_patches);

    // 1. Dispatch: for each case (skipping default) emit
    // `eval test → acc; strict_eq r_disc; jmp_if_true patch_i`.
    var default_idx: ?usize = null;
    for (s.cases, 0..) |case, i| {
        if (case.test_) |*test_expr| {
            try self.compileExpression(test_expr);
            try self.builder.emitOp(.strict_eq, case.span);
            try self.builder.emitU8(r_disc);
            try self.builder.emitOp(.jmp_if_true, case.span);
            body_patches[i] = self.builder.here();
            try self.builder.emitI16(0);
        } else {
            if (default_idx != null) return error.UnsupportedStatement;
            default_idx = i;
            // Reserve a slot we can later overwrite with the
            // jump-to-default; we patch this in the fallback below.
            body_patches[i] = std.math.maxInt(u32); // sentinel
        }
    }

    // 2. After all tests fail: jump to the default body if any,
    // else past the bodies to the exit.
    try self.builder.emitOp(.jmp, s.span);
    const fallback_patch = self.builder.here();
    try self.builder.emitI16(0);

    // Set up a loop context for `break` inside the switch.
    var ctx: LoopContext = .{
        .continue_target = 0,
        .parent = self.current_loop,
        .entry_finally_chain = self.finally_chain,
    };
    defer ctx.deinit(self.allocator);
    const saved_loop = self.current_loop;
    self.current_loop = &ctx;
    defer self.current_loop = saved_loop;

    // 3. Emit bodies. The case body's start is the patch target
    // for its dispatch jump (or the fallback jump for default).
    var default_body_pc: ?u32 = null;
    for (s.cases, 0..) |case, i| {
        const body_pc = self.builder.here();
        if (case.test_ == null) {
            default_body_pc = body_pc;
        } else {
            try self.builder.patchI16(body_patches[i], body_pc);
        }
        for (case.body) |*body_stmt| {
            try self.compileStatement(body_stmt);
        }
        // Fall-through to the next case body unless a `break`
        // already redirected us — the LoopContext break-patches
        // are queued for the post-switch exit.
    }

    const exit_pc = self.builder.here();
    if (default_body_pc) |pc| {
        try self.builder.patchI16(fallback_patch, pc);
    } else {
        try self.builder.patchI16(fallback_patch, exit_pc);
    }
    for (ctx.break_patches.items) |p| try self.builder.patchI16(p, exit_pc);
}

fn compileReturn(self: *Compiler, s: ast.statement.ReturnStmt) CompileError!void {
    if (s.argument) |*arg| {
        try self.compileExpression(arg);
    } else {
        try self.builder.emitOp(.lda_undefined, s.span);
    }
    // §7.4.6 IteratorClose — close every active for-of iterator
    // on the way out. Walks the loop chain stopping at the
    // enclosing function (the function entry resets
    // `current_loop` to null). Iterator close runs with `acc`
    // holding the return value; `iter_close` preserves `acc`.
    var ctx_iter = self.current_loop;
    while (ctx_iter) |c| : (ctx_iter = c.parent) {
        if (c.iter_register) |r_iter| {
            try self.builder.emitOp(.iter_close, s.span);
            try self.builder.emitU8(r_iter);
        }
    }
    // §14.15 — run every active finally block before returning.
    // Stash the return value in a temp so the finally bodies
    // can clobber `acc` freely, then restore it. The helper
    // rewinds `finally_chain` past each `f` before compiling
    // its body so an abrupt `return` / `break` / `continue`
    // inside it doesn't re-inline `f` (per §14.15.3 step 4 an
    // abrupt completion in finally replaces the outer one).
    if (self.finally_chain != null) {
        const r_save = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, s.span);
        try self.builder.emitU8(r_save);
        try self.emitFinalliesUntil(null, s.span);
        try self.builder.emitOp(.ldar, s.span);
        try self.builder.emitU8(r_save);
    }
    try self.builder.emitOp(.return_, s.span);
}

fn compileFunctionDecl(self: *Compiler, fd: ast.statement.FunctionDecl) CompileError!void {
    const name_slice = self.source[fd.name.span.start..fd.name.span.end];
    // Declare the binding FIRST so the function body can resolve
    // its own name (e.g. for recursion). With env-based scoping
    // the body sees `name` at depth=1, slot=this-slot. later
    // can extend to full §14.1.3 hoisting (visible above the
    // declaration); for now declare-on-encounter is sufficient
    // since the parser already accepts forward references that
    // typically only resolve at function-call time anyway.
    const binding = try self.declareBindingFull(name_slice, .var_, fd.name.span);
    const k = try compileFunctionTemplateExt(
        self,
        fd.params,
        FunctionBody{ .block = fd.body.body },
        name_slice,
        false,
        fd.is_generator,
        fd.is_async,
        fd.span,
    );
    try self.builder.emitOp(.make_function, fd.span);
    try self.builder.emitU16(k);
    try self.emitStoreBinding(binding, fd.span);
}

fn compileClassDecl(self: *Compiler, cd: ast.statement.ClassDecl) CompileError!void {
    const name_slice = self.source[cd.name.span.start..cd.name.span.end];
    const binding = try self.declareBindingFull(name_slice, .let_, cd.name.span);
    const k = try compileClassTemplate(
        self,
        name_slice,
        if (cd.superclass) |s| &s else null,
        cd.body,
        cd.span,
    );
    if (cd.superclass) |s| try self.compileExpression(&s);
    try self.builder.emitOp(.make_class, cd.span);
    try self.builder.emitU16(k);
    try self.emitStoreBinding(binding, cd.span);
}

fn compileClassExpr(self: *Compiler, ce: ast.expression.ClassExpr) CompileError!void {
    const name_slice: ?[]const u8 = if (ce.name) |n| self.source[n.span.start..n.span.end] else null;
    const k = try compileClassTemplate(
        self,
        name_slice,
        ce.superclass,
        ce.body,
        ce.span,
    );
    if (ce.superclass) |s| try self.compileExpression(s);
    try self.builder.emitOp(.make_class, ce.span);
    try self.builder.emitU16(k);
}

/// Compile a class body — constructor + methods + static methods +
/// fields + static blocks + private members — into a
/// `ClassTemplate` and register it on the enclosing chunk.
fn compileClassTemplate(
    self: *Compiler,
    name: ?[]const u8,
    superclass: ?*const Expression,
    body: []ast.statement.ClassMember,
    span: Span,
) CompileError!u16 {
    const is_derived = superclass != null;
    const ChunkMod = @import("chunk.zig");

    // Allocate this class's private-name prefix in the realm's
    // class arena so it outlives the compiler. The prefix is
    // class-unique so two unrelated classes that both declare
    // `#x` get distinct private slots.
    const class_uid = self.class_uid_counter;
    self.class_uid_counter += 1;
    const arena = self.realm.classAllocator();
    const private_prefix = std.fmt.allocPrint(arena, "P{d}#", .{class_uid}) catch return error.OutOfMemory;

    // Push onto the class stack so method bodies / field
    // initializers can mangle private names.
    self.class_stack.append(self.allocator, .{
        .private_prefix = private_prefix,
        .is_derived = is_derived,
    }) catch return error.OutOfMemory;
    defer _ = self.class_stack.pop();

    // Extract constructor + bucket the rest.
    var ctor_def: ?ast.statement.MethodDef = null;
    var instance_method_count: usize = 0;
    var static_method_count: usize = 0;
    var instance_field_count: usize = 0;
    var static_field_count: usize = 0;
    var static_block_count: usize = 0;
    for (body) |member| switch (member) {
        .method => |m| {
            // Generator and async methods are runtime concerns —
            // the body compiles the same; the `is_generator` /
            // `is_async` flags propagate to the JSFunction at
            // MakeClass time so the call site allocates a
            // generator / wraps in a Promise as appropriate.
            const is_priv = m.key == .private;
            const key_name = methodKeyName(self.source, m.key) orelse return error.UnsupportedStatement;
            _ = is_priv;
            if (!m.is_static and std.mem.eql(u8, key_name, "constructor")) {
                if (ctor_def != null) return error.UnsupportedStatement; // duplicate
                ctor_def = m;
                continue;
            }
            if (m.is_static) static_method_count += 1 else instance_method_count += 1;
        },
        .field => |fd| {
            if (fd.is_static) static_field_count += 1 else instance_field_count += 1;
        },
        .static_block => static_block_count += 1,
    };

    // Compile field initializers FIRST so they can be carried
    // alongside the method/constructor bodies in the template.
    // Each field initializer is a tiny chunk that evaluates the
    // init expression with `this` bound; if the expression is
    // missing (`class C { x; }`), `init_chunk = null`.
    var instance_fields = try self.allocator.alloc(ChunkMod.FieldTemplate, instance_field_count);
    errdefer self.allocator.free(instance_fields);
    var static_fields = try self.allocator.alloc(ChunkMod.FieldTemplate, static_field_count);
    errdefer self.allocator.free(static_fields);
    var static_blocks = try self.allocator.alloc(ChunkMod.Chunk, static_block_count);
    errdefer self.allocator.free(static_blocks);

    var i_if: usize = 0;
    var i_sf: usize = 0;
    var i_sb: usize = 0;
    for (body) |member| switch (member) {
        .field => |fd| {
            const key_name = blk: {
                const raw = methodKeyName(self.source, fd.key) orelse return error.UnsupportedStatement;
                if (fd.key == .private) {
                    // `#x` — prefix with the class identity.
                    break :blk std.fmt.allocPrint(arena, "{s}{s}", .{ private_prefix, raw }) catch return error.OutOfMemory;
                }
                break :blk raw;
            };
            const init_chunk: ?ChunkMod.Chunk = if (fd.init) |*init_expr|
                try compileFieldInitChunk(self, init_expr, fd.span)
            else
                null;
            const tmpl = ChunkMod.FieldTemplate{
                .name = key_name,
                .init_chunk = init_chunk,
            };
            if (fd.is_static) {
                static_fields[i_sf] = tmpl;
                i_sf += 1;
            } else {
                instance_fields[i_if] = tmpl;
                i_if += 1;
            }
        },
        .static_block => |sb| {
            static_blocks[i_sb] = try compileStaticBlockChunk(self, sb.body, sb.span);
            i_sb += 1;
        },
        .method => {},
    };

    // Detect any per-instance init work — fields OR private
    // methods need init_instance_fields to fire.
    var has_private_methods = false;
    for (body) |member| switch (member) {
        .method => |m| {
            if (!m.is_static and m.key == .private) {
                has_private_methods = true;
                break;
            }
            // `.ident` whose source slice starts with `#`
            const raw = methodKeyName(self.source, m.key) orelse continue;
            _ = raw;
        },
        else => {},
    };
    // Also catch `#name` parsed as `.ident` with leading '#'.
    if (!has_private_methods) {
        for (body) |member| switch (member) {
            .method => |m| {
                if (m.is_static) continue;
                const raw = switch (m.key) {
                    .ident => |s| self.source[s.start..s.end],
                    else => continue,
                };
                if (raw.len > 0 and raw[0] == '#') {
                    has_private_methods = true;
                    break;
                }
            },
            else => {},
        };
    }
    const has_init_work = instance_field_count > 0 or has_private_methods;

    // Compile the constructor (explicit or synthesised).
    const ctor_param_count: u8 = if (ctor_def) |c| @intCast(c.params.len) else 0;
    const ctor_chunk = if (ctor_def) |c|
        try compileConstructorBody(self, c.params, c.body.body, is_derived, has_init_work, span)
    else
        try compileSynthDefaultConstructor(self, is_derived, has_init_work, span);

    // Compile each method into its own chunk.
    var instance_methods = try self.allocator.alloc(ChunkMod.MethodTemplate, instance_method_count);
    errdefer self.allocator.free(instance_methods);
    var static_methods = try self.allocator.alloc(ChunkMod.MethodTemplate, static_method_count);
    errdefer self.allocator.free(static_methods);

    var i_inst: usize = 0;
    var i_stat: usize = 0;
    for (body) |member| switch (member) {
        .method => |m| {
            const raw_key = methodKeyName(self.source, m.key) orelse return error.UnsupportedStatement;
            if (!m.is_static and std.mem.eql(u8, raw_key, "constructor")) continue;
            const key_name = switch (m.key) {
                .private => std.fmt.allocPrint(arena, "{s}{s}", .{ private_prefix, raw_key }) catch return error.OutOfMemory,
                // §12.7.1 — `\u…` escapes in IdentifierName decode to
                // the source character, so `class C { if(){} }`
                // installs `if`. String / numeric keys are already the
                // PropertyKey value once their literal frame is stripped.
                .ident => try self.decodeIdentifierName(raw_key),
                else => raw_key,
            };
            const method_chunk = try compileMethodBody(self, m.params, m.body.body, false, false, m.span);
            const tmpl = ChunkMod.MethodTemplate{
                .name = key_name,
                .chunk = method_chunk,
                .param_count = @intCast(m.params.len),
                .kind = switch (m.kind) {
                    .method => .method,
                    .getter => .getter,
                    .setter => .setter,
                },
                .is_generator = m.is_generator,
                .is_async = m.is_async,
                // §20.2.3.5 — borrow the MethodDefinition's source
                // span for `Function.prototype.toString`.
                .source = if (m.span.start <= m.span.end and m.span.end <= self.source.len)
                    self.source[m.span.start..m.span.end]
                else
                    null,
            };
            if (m.is_static) {
                static_methods[i_stat] = tmpl;
                i_stat += 1;
            } else {
                instance_methods[i_inst] = tmpl;
                i_inst += 1;
            }
        },
        .field, .static_block => {},
    };

    return self.builder.addClassTemplate(.{
        .name = name,
        .span = span,
        .source = if (span.start <= span.end and span.end <= self.source.len)
            self.source[span.start..span.end]
        else
            null,
        .has_heritage = is_derived,
        .private_prefix = private_prefix,
        .constructor_chunk = ctor_chunk,
        .constructor_param_count = ctor_param_count,
        .instance_methods = instance_methods,
        .static_methods = static_methods,
        .instance_fields = instance_fields,
        .static_fields = static_fields,
        .static_blocks = static_blocks,
    });
}

/// Resolve a class member's PropertyKey to the key string.
fn methodKeyName(source: []const u8, key: ast.expression.PropertyKey) ?[]const u8 {
    return switch (key) {
        .ident => |s| source[s.start..s.end],
        .string => |s| blk: {
            const raw = source[s.start..s.end];
            if (raw.len < 2) break :blk raw;
            break :blk raw[1 .. raw.len - 1];
        },
        .private => |s| blk: {
            // `#name` — strip the `#`. The compiler later mangles
            // with the class's private_prefix.
            const raw = source[s.start..s.end];
            if (raw.len > 0 and raw[0] == '#') break :blk raw[1..];
            break :blk raw;
        },
        else => null,
    };
}

/// Compile `class C { x = init; }` field-initializer expression
/// into a parameterless function-shape chunk. Body:
/// MakeEnvironment 0
/// <init_expr> → acc
/// Return
/// `this` is provided by the caller via the frame's this_value.
fn compileFieldInitChunk(
    self: *Compiler,
    init_expr: *const Expression,
    span: Span,
) CompileError!@import("chunk.zig").Chunk {
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    try self.builder.emitOp(.make_environment, span);
    try self.builder.emitU8(0);
    try self.compileExpression(init_expr);
    try self.builder.emitOp(.return_, span);

    self.builder.code.items[1] = self.env_slot_count;
    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return inner_chunk;
}

/// Compile a `static { … }` block body into a function-shape
/// chunk that runs once at class definition time with `this`
/// bound to the class.
fn compileStaticBlockChunk(
    self: *Compiler,
    body: []ast.statement.Statement,
    span: Span,
) CompileError!@import("chunk.zig").Chunk {
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    try self.builder.emitOp(.make_environment, span);
    const slot_count_patch = self.builder.here();
    try self.builder.emitU8(0);
    try self.hoistLetConst(body);
    try self.hoistVarAndFunctions(body);
    try self.emitVarInits(span);
    for (body) |*s| if (s.* == .function_decl) try self.compileStatement(s);
    for (body) |*s| if (s.* != .function_decl) try self.compileStatement(s);
    try self.builder.emitOp(.lda_undefined, span);
    try self.builder.emitOp(.return_, span);

    self.builder.code.items[slot_count_patch] = self.env_slot_count;
    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return inner_chunk;
}

/// Like compileMethodBody but with prologue tweaks for class
/// constructors: base classes get `init_instance_fields` at the
/// start of the user body; derived classes leave it to the
/// `super_call` op to trigger (we patch it post-hoc by detecting
/// super_call ops emitted from the body).
fn compileConstructorBody(
    self: *Compiler,
    params: []ast.statement.FunctionParam,
    body_stmts: []ast.statement.Statement,
    is_derived: bool,
    has_fields: bool,
    span: Span,
) CompileError!@import("chunk.zig").Chunk {
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    try self.builder.emitOp(.make_environment, span);
    const slot_count_patch = self.builder.here();
    try self.builder.emitU8(0);

    for (params, 0..) |*p, i| {
        switch (p.*) {
            .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
            .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
        }
    }

    // Base class: run field initializers at the start of the
    // user body. Derived classes wait for super_call to trigger.
    if (!is_derived and has_fields) {
        try self.builder.emitOp(.init_instance_fields, span);
    }

    // §10.4.4 — implicit `arguments` binding.
    if (referencesArguments(self.source, body_stmts)) {
        const slot = try self.declareBinding("arguments", .let_, span);
        try self.builder.emitOp(.lda_arguments, span);
        try self.builder.emitOp(.sta_env, span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(slot);
    }

    try self.hoistLetConst(body_stmts);
    for (body_stmts) |*s| try self.compileStatement(s);
    try self.builder.emitOp(.lda_undefined, span);
    try self.builder.emitOp(.return_, span);

    self.builder.code.items[slot_count_patch] = self.env_slot_count;
    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return inner_chunk;
}

/// Compile a method body — same pipeline as compileFunctionTemplate
/// minus the outer chunk registration. `is_constructor` makes
/// the prologue end with `lda_this; return_` instead of
/// `lda_undefined; return_` (so `new C()` returns `this` even
/// without explicit return — handled by the construct frame).
/// `derived` synthesises a `super(...)` for default-derived
/// constructors when `is_constructor` is also true and the body
/// is empty (the caller signals this by passing an empty stmts
/// slice).
fn compileMethodBody(
    self: *Compiler,
    params: []ast.statement.FunctionParam,
    body_stmts: []ast.statement.Statement,
    is_constructor: bool,
    derived: bool,
    span: Span,
) CompileError!@import("chunk.zig").Chunk {
    _ = is_constructor;
    _ = derived;

    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    try self.builder.emitOp(.make_environment, span);
    const slot_count_patch = self.builder.here();
    try self.builder.emitU8(0);

    // Param prologue, same as compileFunctionTemplate.
    for (params, 0..) |*p, i| {
        switch (p.*) {
            .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
            .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
        }
    }

    // §10.4.4 — implicit `arguments` for class methods (non-arrow).
    if (referencesArguments(self.source, body_stmts)) {
        const slot = try self.declareBinding("arguments", .let_, span);
        try self.builder.emitOp(.lda_arguments, span);
        try self.builder.emitOp(.sta_env, span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(slot);
    }

    // Body.
    try self.hoistLetConst(body_stmts);
    try self.hoistVarAndFunctions(body_stmts);
    try self.emitVarInits(span);
    for (body_stmts) |*s| if (s.* == .function_decl) try self.compileStatement(s);
    for (body_stmts) |*s| if (s.* != .function_decl) try self.compileStatement(s);
    try self.builder.emitOp(.lda_undefined, span);
    try self.builder.emitOp(.return_, span);

    self.builder.code.items[slot_count_patch] = self.env_slot_count;
    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return inner_chunk;
}

/// Synthesise the default constructor body (§15.7.14 step 14):
/// • base class: `constructor() {}` → emit `LdaUndefined; Return`.
/// • derived class: `constructor(...args) { super(...args); }` →
/// emit `MakeEnvironment 0; SuperCallForward; LdaUndefined;
/// Return`.
fn compileSynthDefaultConstructor(
    self: *Compiler,
    is_derived: bool,
    has_fields: bool,
    span: Span,
) CompileError!@import("chunk.zig").Chunk {
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    try self.builder.emitOp(.make_environment, span);
    try self.builder.emitU8(0);
    if (is_derived) {
        try self.builder.emitOp(.super_call_forward, span);
    }
    if (has_fields) {
        try self.builder.emitOp(.init_instance_fields, span);
    }
    try self.builder.emitOp(.lda_undefined, span);
    try self.builder.emitOp(.return_, span);

    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return inner_chunk;
}

fn compileBlock(self: *Compiler, body: []ast.statement.Statement, span: Span) CompileError!void {
    _ = span;
    var block_scope: Scope = .{ .parent = self.scope, .kind = .block };
    defer block_scope.deinit(self.allocator);
    const saved = self.scope;
    self.scope = &block_scope;
    defer self.scope = saved;

    // Pre-pass: hoist `let` / `const` slots so any reference
    // inside the block (including from forward declarations)
    // sees the binding in the TDZ rather than as undeclared.
    try self.hoistLetConst(body);

    for (body) |*s| try self.compileStatement(s);
}

/// Walk `body` and pre-allocate env slots for every `let` /
/// `const` BindingIdentifier so subsequent reads in this scope
/// see the binding (initially the TDZ Hole installed by
/// `MakeEnvironment`) instead of failing to resolve. Block
/// scopes share their enclosing function's env later; the
/// pre-pass therefore adds slots without emitting any per-block
/// runtime initialisation — the function-entry MakeEnvironment
/// already filled the env with `hole` values.
fn hoistLetConst(self: *Compiler, body: []ast.statement.Statement) CompileError!void {
    for (body) |*s| {
        if (s.* != .lexical) continue;
        const ld = s.lexical;
        if (ld.kind == .var_) continue;
        const kind: BindingKind = if (ld.kind == .let_) .let_ else .const_;
        for (ld.declarators) |d| {
            try self.declarePatternBindings(d.name, kind);
        }
    }
}

/// §13.3.2 — pre-declare every `var` binding (and the names of
/// every function declaration) reachable in the function body
/// without crossing a nested function / class / arrow boundary.
/// Walks into blocks, control-flow bodies, switch cases, try /
/// catch / finally, and the heads / bodies of `for` / `for-in` /
/// `for-of` (where `var` is allowed), so that
///
///     console.log(x); var x = 1;
///     f();           function f(){}
///
/// resolve their forward references against a binding that
/// already exists at scope-entry. `var` bindings still need to
/// be initialised to `undefined` ahead of any reachable read —
/// `emitVarInits` handles that immediately after `make_environment`.
fn hoistVarAndFunctions(self: *Compiler, body: []ast.statement.Statement) CompileError!void {
    for (body) |*s| try self.hoistStatement(s);
}

fn hoistStatement(self: *Compiler, s: *ast.statement.Statement) CompileError!void {
    switch (s.*) {
        .lexical => |ld| {
            if (ld.kind != .var_) return;
            for (ld.declarators) |d| {
                try self.declarePatternVarBindings(d.name);
            }
        },
        .function_decl => |fd| {
            const name = self.source[fd.name.span.start..fd.name.span.end];
            _ = try self.declareBindingFull(name, .var_, fd.name.span);
        },
        .block => |b| try self.hoistVarAndFunctions(b.body),
        .if_ => |i| {
            try self.hoistStatement(i.consequent);
            if (i.alternate) |alt| try self.hoistStatement(alt);
        },
        .while_ => |w| try self.hoistStatement(w.body),
        .do_while => |dw| try self.hoistStatement(dw.body),
        .for_ => |f| {
            if (f.init) |head| switch (head) {
                .lexical => |ld| if (ld.kind == .var_) {
                    for (ld.declarators) |d| try self.declarePatternVarBindings(d.name);
                },
                .expression => {},
            };
            try self.hoistStatement(f.body);
        },
        .for_in_of => |f| {
            switch (f.left) {
                .lexical => |ld| if (ld.kind == .var_) {
                    for (ld.declarators) |d| try self.declarePatternVarBindings(d.name);
                },
                .expression => {},
            }
            try self.hoistStatement(f.body);
        },
        .try_ => |t| {
            try self.hoistVarAndFunctions(t.block.body);
            if (t.handler) |h| try self.hoistVarAndFunctions(h.body.body);
            if (t.finalizer) |fin| try self.hoistVarAndFunctions(fin.body);
        },
        .switch_ => |sw| {
            for (sw.cases) |case| try self.hoistVarAndFunctions(case.body);
        },
        // Nested function / class / arrow bodies have their own
        // function-like scope and are handled by their own
        // `hoistVarAndFunctions` call. Other statement shapes
        // (expression, return, throw, break, continue, debugger,
        // import / export, labeled — n/a) carry no `var` /
        // function-decl children we need to walk.
        else => {},
    }
}

fn declarePatternVarBindings(self: *Compiler, target: ast.statement.BindingTarget) CompileError!void {
    switch (target) {
        .identifier => |id| {
            const name = self.source[id.span.start..id.span.end];
            _ = try self.declareBindingFull(name, .var_, id.span);
        },
        .array => |arr| {
            for (arr.elements) |maybe_elem| {
                if (maybe_elem) |elem| try self.declarePatternVarBindings(elem.target);
            }
            if (arr.rest) |rest| try self.declarePatternVarBindings(rest.*);
        },
        .object => |obj| {
            for (obj.properties) |prop| try self.declarePatternVarBindings(prop.value.target);
            if (obj.rest) |rest_id| {
                const name = self.source[rest_id.span.start..rest_id.span.end];
                _ = try self.declareBindingFull(name, .var_, rest_id.span);
            }
        },
    }
}

/// Emit `lda_undefined; sta_env 0 slot` for every non-global
/// `var` binding currently in the function-like scope.
/// `make_environment` allocates slots filled with the TDZ Hole;
/// reading a hoisted `var` before its initialiser would otherwise
/// see Hole and trip `throw_if_hole`. Globals are pre-initialised
/// to `undefined` in the realm map by `declareBindingFull` so
/// they don't need bytecode here.
fn emitVarInits(self: *Compiler, span: Span) CompileError!void {
    const fn_scope = self.functionScope();
    var emitted_undef = false;
    for (fn_scope.bindings.items) |b| {
        if (b.kind != .var_ or b.is_global) continue;
        if (!emitted_undef) {
            try self.builder.emitOp(.lda_undefined, span);
            emitted_undef = true;
        }
        try self.builder.emitOp(.sta_env, span);
        try self.builder.emitU8(0); // depth=0 — the freshly-pushed env
        try self.builder.emitU8(b.env_slot);
    }
}

/// Count every BindingIdentifier produced by `target`. Used by
/// for-of with a destructuring lhs to size the per-iteration
/// environment ahead of `make_environment`.
fn countPatternBindings(target: ast.statement.BindingTarget) u8 {
    return switch (target) {
        .identifier => 1,
        .array => |arr_pat| blk: {
            var n: u8 = 0;
            for (arr_pat.elements) |maybe_elem| {
                if (maybe_elem) |elem| n +|= countPatternBindings(elem.target);
            }
            if (arr_pat.rest) |rest_target| n +|= countPatternBindings(rest_target.*);
            break :blk n;
        },
        .object => |obj_pat| blk: {
            var n: u8 = 0;
            for (obj_pat.properties) |prop| n +|= countPatternBindings(prop.value.target);
            if (obj_pat.rest) |_| n +|= 1;
            break :blk n;
        },
    };
}

/// Recursively declare every BindingIdentifier inside a
/// destructuring pattern. later only supports shallow
/// patterns — nested patterns / rest elements with patterns
/// are later.
fn declarePatternBindings(self: *Compiler, target: ast.statement.BindingTarget, kind: BindingKind) CompileError!void {
    switch (target) {
        .identifier => |id| {
            const name = self.source[id.span.start..id.span.end];
            _ = try self.declareBinding(name, kind, id.span);
        },
        .array => |arr_pat| {
            for (arr_pat.elements) |maybe_elem| {
                if (maybe_elem) |elem| {
                    try self.declarePatternBindings(elem.target, kind);
                }
            }
            if (arr_pat.rest) |rest_target| {
                try self.declarePatternBindings(rest_target.*, kind);
            }
        },
        .object => |obj_pat| {
            for (obj_pat.properties) |prop| {
                try self.declarePatternBindings(prop.value.target, kind);
            }
            if (obj_pat.rest) |rest_id| {
                const name = self.source[rest_id.span.start..rest_id.span.end];
                _ = try self.declareBinding(name, kind, rest_id.span);
            }
        },
    }
}

fn compileLexicalDecl(self: *Compiler, ld: ast.statement.LexicalDecl) CompileError!void {
    if (ld.kind == .var_) {
        // `var` bindings (and their function-scope slots) were
        // pre-declared and pre-initialised to `undefined` by
        // `hoistVarAndFunctions` + `emitVarInits` at function /
        // script entry. The work here is just running the
        // initialiser when one's present.
        for (ld.declarators) |d| {
            switch (d.name) {
                .identifier => |id| {
                    const name = self.source[id.span.start..id.span.end];
                    if (d.init) |*init_expr| {
                        // §14.3.1.2 — anonymous function-likes
                        // adopt the binding identifier as `.name`.
                        try self.compileNamedValue(init_expr, name);
                        const binding = self.scope.?.resolve(name) orelse blk: {
                            // Hoist always declares; the only way to
                            // miss is a cross-realm shadow on the
                            // global object (treat as global write).
                            if (self.realm.globals.contains(name)) {
                                break :blk Binding{
                                    .name = name,
                                    .env_slot = 0,
                                    .env_depth = 0,
                                    .kind = .var_,
                                    .span = d.span,
                                    .is_global = true,
                                };
                            }
                            return error.UnresolvedReference;
                        };
                        try self.emitStoreBinding(binding, d.span);
                    }
                    // No init: hoist already wrote undefined.
                },
                else => {
                    if (d.init) |*init_expr| {
                        try self.compileExpression(init_expr);
                    } else {
                        try self.builder.emitOp(.lda_undefined, d.span);
                    }
                    try self.compileDestructure(d.name);
                },
            }
        }
        return;
    }
    // `let` / `const` slots were pre-allocated by hoistLetConst
    // in the enclosing scope. Evaluate the initialiser and store.
    for (ld.declarators) |d| {
        switch (d.name) {
            .identifier => |id| {
                const name = self.source[id.span.start..id.span.end];
                const binding = self.scope.?.lookupLocal(name) orelse return error.UnresolvedReference;
                if (d.init) |*init_expr| {
                    // §14.3.1.2 — anonymous function-likes adopt
                    // the binding identifier as their `.name`.
                    try self.compileNamedValue(init_expr, name);
                } else {
                    // §14.3.1 — `const x;` is a SyntaxError (already
                    // rejected by the parser via `const_without_initializer`).
                    // For `let x;` (no init), the binding becomes
                    // `undefined` once the declaration is reached.
                    try self.builder.emitOp(.lda_undefined, d.span);
                }
                try self.emitStoreBinding(binding, d.span);
            },
            else => {
                if (d.init) |*init_expr| {
                    try self.compileExpression(init_expr);
                } else {
                    // Pattern targets require an initialiser per
                    // spec; the parser may not have caught it,
                    // so emit `undefined` and let defaults fire.
                    try self.builder.emitOp(.lda_undefined, d.span);
                }
                try self.compileDestructure(d.name);
            },
        }
    }
}

/// Walk a destructuring pattern, assigning each leaf binding
/// from the value currently in the accumulator. later
/// supports shallow nesting; computed keys, rest elements, and
/// rest-with-pattern are later.
fn compileDestructure(self: *Compiler, target: ast.statement.BindingTarget) CompileError!void {
    const r_src = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, target.span());
    try self.builder.emitU8(r_src);

    switch (target) {
        .identifier => |id| {
            // Tolerated path for nested cases — declarators with
            // a plain ident name have already taken the direct
            // sta_env path above.
            const name = self.source[id.span.start..id.span.end];
            try self.builder.emitOp(.ldar, id.span);
            try self.builder.emitU8(r_src);
            try self.assignToBinding(name, id.span);
        },
        .array => |arr_pat| {
            // §14.3.3.5 IteratorBindingInitialization for an
            // ArrayBindingPattern — open an iterator on `src`,
            // step it once per pattern element (binding the
            // result, or `undefined` on done), collect any rest
            // through repeated `iter_step`, and close the iter
            // afterwards if it didn't fully drain (§7.4.10).
            try self.builder.emitOp(.ldar, target.span());
            try self.builder.emitU8(r_src);
            try self.builder.emitOp(.iter_open, target.span());
            const r_iter = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, target.span());
            try self.builder.emitU8(r_iter);
            const r_done = try self.reserveTemp();
            defer self.releaseTemp();

            for (arr_pat.elements) |maybe_elem| {
                if (maybe_elem) |elem| {
                    try self.builder.emitOp(.iter_step, elem.span);
                    try self.builder.emitU8(r_iter);
                    try self.builder.emitU8(r_done);
                    try self.applyDefaultIfNeeded(elem);
                    try self.assignPatternLeaf(elem.target);
                } else {
                    // Elision — step the iter, discard the value.
                    try self.builder.emitOp(.iter_step, target.span());
                    try self.builder.emitU8(r_iter);
                    try self.builder.emitU8(r_done);
                }
            }

            if (arr_pat.rest) |rest_target| {
                // §14.3.3.4 BindingRestElement — drain the iter
                // into a fresh Array. `iter_step` marks the iter
                // done when it surfaces `done: true`, so the
                // closing `iter_close` below is a no-op for the
                // rest case.
                const r_rest = try self.reserveTemp();
                defer self.releaseTemp();
                const r_idx = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.make_array, target.span());
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_rest);
                try self.builder.emitOp(.lda_smi, target.span());
                try self.builder.emitI32(0);
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_idx);

                const r_val = try self.reserveTemp();
                defer self.releaseTemp();
                const loop_start = self.builder.here();
                try self.builder.emitOp(.iter_step, target.span());
                try self.builder.emitU8(r_iter);
                try self.builder.emitU8(r_done);
                // Snapshot the stepped value — the `ldar r_done`
                // below clobbers `acc`.
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_val);
                // if (r_done) jmp loop_end
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_done);
                try self.builder.emitOp(.jmp_if_true, target.span());
                const exit_patch = self.builder.here();
                try self.builder.emitI16(0);
                // rest[idx] = value
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.sta_computed, target.span());
                try self.builder.emitU8(r_rest);
                try self.builder.emitU8(r_idx);
                // idx += 1 — `add r` is `acc = registers[r] + acc`.
                try self.builder.emitOp(.lda_smi, target.span());
                try self.builder.emitI32(1);
                try self.builder.emitOp(.add, target.span());
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.jmp, target.span());
                const back_patch = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.patchI16(back_patch, loop_start);
                const exit_target = self.builder.here();
                try self.builder.patchI16(exit_patch, exit_target);

                // rest array → leaf
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_rest);
                try self.assignPatternLeaf(rest_target.*);
            } else {
                // §7.4.10 IteratorClose — if the iter is not yet
                // done (e.g. `[a, b] = source` where source has
                // more than two elements), call `.return()`.
                try self.builder.emitOp(.iter_close, target.span());
                try self.builder.emitU8(r_iter);
            }
        },
        .object => |obj_pat| {
            // §13.15.5.4 / §14.3.3 — destructuring an object
            // pattern starts with RequireObjectCoercible on the
            // source. `const {} = null` must throw TypeError before
            // any (zero) property reads happen.
            try self.builder.emitOp(.ldar, target.span());
            try self.builder.emitU8(r_src);
            try self.builder.emitOp(.require_object_coercible, target.span());
            for (obj_pat.properties) |prop| {
                const key_span: Span = switch (prop.key) {
                    .ident => |s| s,
                    .string => |s| s,
                    .numeric => |s| s,
                    else => return error.UnsupportedStatement,
                };
                const key_slice: []const u8 = blk: {
                    if (prop.key == .string) {
                        const raw = self.source[key_span.start..key_span.end];
                        if (raw.len < 2) break :blk raw;
                        break :blk raw[1 .. raw.len - 1];
                    }
                    break :blk self.source[key_span.start..key_span.end];
                };
                const k = try self.internString(key_slice);
                try self.builder.emitOp(.ldar, prop.span);
                try self.builder.emitU8(r_src);
                try self.builder.emitOp(.lda_property, prop.span);
                try self.builder.emitU16(k);
                try self.applyDefaultIfNeeded(prop.value);
                try self.assignPatternLeaf(prop.value.target);
            }
            if (obj_pat.rest) |rest_id| {
                // §14.3.3.4 RestElement on ObjectPattern — collect
                // every own enumerable property of `r_src` not in
                // the excluded list (the previously-bound keys)
                // into a fresh object.
                const r_excl = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.make_array, target.span());
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_excl);
                const k_length = try self.internString("length");
                try self.builder.emitOp(.lda_smi, target.span());
                try self.builder.emitI32(@intCast(obj_pat.properties.len));
                try self.builder.emitOp(.sta_property, target.span());
                try self.builder.emitU16(k_length);
                try self.builder.emitU8(r_excl);
                for (obj_pat.properties, 0..) |prop, idx| {
                    const key_span: Span = switch (prop.key) {
                        .ident => |s| s,
                        .string => |s| s,
                        .numeric => |s| s,
                        else => return error.UnsupportedStatement,
                    };
                    const key_slice: []const u8 = blk: {
                        if (prop.key == .string) {
                            const raw = self.source[key_span.start..key_span.end];
                            if (raw.len < 2) break :blk raw;
                            break :blk raw[1 .. raw.len - 1];
                        }
                        break :blk self.source[key_span.start..key_span.end];
                    };
                    const k = try self.internString(key_slice);
                    try self.builder.emitOp(.lda_constant, target.span());
                    try self.builder.emitU16(k);
                    var idx_buf: [16]u8 = undefined;
                    const idx_slice = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch unreachable;
                    const idx_k = try self.internString(idx_slice);
                    try self.builder.emitOp(.sta_property, target.span());
                    try self.builder.emitU16(idx_k);
                    try self.builder.emitU8(r_excl);
                }
                try self.builder.emitOp(.object_rest_from, target.span());
                try self.builder.emitU8(r_src);
                try self.builder.emitU8(r_excl);
                const rest_name = self.source[rest_id.span.start..rest_id.span.end];
                try self.assignToBinding(rest_name, rest_id.span);
            }
        },
    }
}

/// §13.15.5 DestructuringAssignment — walk an array_literal or
/// object_literal AST as an assignment pattern. Source value
/// is in `acc` on entry; this function consumes it. Leaves can
/// be IdentifierReference, MemberExpression, nested patterns,
/// or `target = default`. Spread (`[...rest]` / `{...rest}`)
/// is a rest element; defaults flow through `applyDefaultExpr`.
fn compileAssignmentPattern(self: *Compiler, target: ast.expression.Expression) CompileError!void {
    const r_src = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, target.span());
    try self.builder.emitU8(r_src);

    switch (target) {
        .array_literal => |al| {
            // §13.15.5.5 ArrayAssignmentPattern — open an
            // iterator on `src` and step it per non-elision
            // element, then drain (if there's a rest) or close.
            // Spread (`[...rest]`) can only appear as the last
            // element per the parser.
            var rest_arg: ?*ast.expression.Expression = null;
            var elem_count = al.elements.len;
            if (al.elements.len > 0) {
                if (al.elements[al.elements.len - 1]) |last| {
                    if (last == .spread) {
                        rest_arg = last.spread.argument;
                        elem_count -= 1;
                    }
                }
            }

            try self.builder.emitOp(.ldar, target.span());
            try self.builder.emitU8(r_src);
            try self.builder.emitOp(.iter_open, target.span());
            const r_iter = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, target.span());
            try self.builder.emitU8(r_iter);
            const r_done = try self.reserveTemp();
            defer self.releaseTemp();

            for (al.elements[0..elem_count]) |maybe_elt| {
                if (maybe_elt) |elt| {
                    try self.builder.emitOp(.iter_step, target.span());
                    try self.builder.emitU8(r_iter);
                    try self.builder.emitU8(r_done);
                    try self.assignAssignmentPatternElem(elt);
                } else {
                    // Elision — step and discard.
                    try self.builder.emitOp(.iter_step, target.span());
                    try self.builder.emitU8(r_iter);
                    try self.builder.emitU8(r_done);
                }
            }

            if (rest_arg) |arg| {
                // Drain the iterator into a fresh Array, then
                // bind it to the rest leaf.
                const r_rest = try self.reserveTemp();
                defer self.releaseTemp();
                const r_idx = try self.reserveTemp();
                defer self.releaseTemp();
                const r_val = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.make_array, target.span());
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_rest);
                try self.builder.emitOp(.lda_smi, target.span());
                try self.builder.emitI32(0);
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_idx);

                const loop_start = self.builder.here();
                try self.builder.emitOp(.iter_step, target.span());
                try self.builder.emitU8(r_iter);
                try self.builder.emitU8(r_done);
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_done);
                try self.builder.emitOp(.jmp_if_true, target.span());
                const exit_patch = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_val);
                try self.builder.emitOp(.sta_computed, target.span());
                try self.builder.emitU8(r_rest);
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.lda_smi, target.span());
                try self.builder.emitI32(1);
                try self.builder.emitOp(.add, target.span());
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_idx);
                try self.builder.emitOp(.jmp, target.span());
                const back_patch = self.builder.here();
                try self.builder.emitI16(0);
                try self.builder.patchI16(back_patch, loop_start);
                const exit_target = self.builder.here();
                try self.builder.patchI16(exit_patch, exit_target);

                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_rest);
                try self.assignAssignmentPatternLeaf(arg.*);
            } else {
                // §7.4.10 — close iter if still open.
                try self.builder.emitOp(.iter_close, target.span());
                try self.builder.emitU8(r_iter);
            }
        },
        .object_literal => |ol| {
            // §13.15.5.4 — assignment to an object pattern
            // requires the source be ToObject-coercible. `({} = null)`
            // throws TypeError; emit the guard before any property
            // reads (and before the empty-pattern early exit).
            try self.builder.emitOp(.ldar, target.span());
            try self.builder.emitU8(r_src);
            try self.builder.emitOp(.require_object_coercible, target.span());
            // Object pattern leaves can include `{...rest}` —
            // the parser parses that as a `.spread` property
            // member with an identifier_reference argument.
            for (ol.properties) |prop| switch (prop) {
                .property => |op| {
                    const key_slice = try self.assignmentPatternKey(op.key);
                    const k = try self.internString(key_slice);
                    try self.builder.emitOp(.ldar, op.span);
                    try self.builder.emitU8(r_src);
                    try self.builder.emitOp(.lda_property, op.span);
                    try self.builder.emitU16(k);
                    // Shorthand `{a}` is target `a` (assign back to a).
                    // `{a = 1}` is shorthand with default — the parser
                    // wraps the value as `assignment(eq, identifier_reference, default)`.
                    // `{x: a = 1}` puts the same `assignment(...)` node
                    // under a renamed key. Either shape is handled by
                    // `assignAssignmentPatternElem`.
                    try self.assignAssignmentPatternElem(op.value);
                },
                .spread => |sp| {
                    // §13.15.5 RestElement on object pattern —
                    // collect own enumerables not in the
                    // already-bound key list. Mirrors the
                    // declaration path's `object_rest_from` shape.
                    const r_excl = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.make_array, sp.span);
                    try self.builder.emitOp(.star, sp.span);
                    try self.builder.emitU8(r_excl);
                    const k_length = try self.internString("length");
                    var bound_count: i32 = 0;
                    for (ol.properties) |p2| switch (p2) {
                        .property => bound_count += 1,
                        else => {},
                    };
                    try self.builder.emitOp(.lda_smi, sp.span);
                    try self.builder.emitI32(bound_count);
                    try self.builder.emitOp(.sta_property, sp.span);
                    try self.builder.emitU16(k_length);
                    try self.builder.emitU8(r_excl);
                    var i: u32 = 0;
                    for (ol.properties) |p2| switch (p2) {
                        .property => |op2| {
                            const ks = try self.assignmentPatternKey(op2.key);
                            const kk = try self.internString(ks);
                            try self.builder.emitOp(.lda_constant, sp.span);
                            try self.builder.emitU16(kk);
                            var ibuf: [16]u8 = undefined;
                            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                            const ik = try self.internString(islice);
                            try self.builder.emitOp(.sta_property, sp.span);
                            try self.builder.emitU16(ik);
                            try self.builder.emitU8(r_excl);
                            i += 1;
                        },
                        else => {},
                    };
                    try self.builder.emitOp(.object_rest_from, sp.span);
                    try self.builder.emitU8(r_src);
                    try self.builder.emitU8(r_excl);
                    try self.assignAssignmentPatternLeaf(sp.argument.*);
                },
                .method => return error.UnsupportedExpression,
            };
        },
        else => return error.UnsupportedExpression,
    }
    // §13.15.2 / §13.15.4 — DestructuringAssignmentEvaluation
    // returns the RHS value (the source we destructured). Caller
    // (expression context) reads `acc` for the assignment-expression
    // result, so restore it here. Statement / for-of callers
    // overwrite `acc` immediately and don't care.
    try self.builder.emitOp(.ldar, target.span());
    try self.builder.emitU8(r_src);
}

/// Assignment-pattern element handling. The element AST is
/// `assignment(eq, target, default)` for defaults, otherwise
/// the bare target Expression. Acc holds the property value
/// already loaded by the caller.
fn assignAssignmentPatternElem(self: *Compiler, elt: ast.expression.Expression) CompileError!void {
    if (elt == .assignment and elt.assignment.op == .eq) {
        // §13.15.5.5 — when the destructuring target is a plain
        // identifier reference and the initializer is anonymous,
        // `SetFunctionName` adopts the identifier as the name.
        const named_target: ?[]const u8 = blk: {
            var t = elt.assignment.target;
            while (t.* == .parenthesized) t = t.parenthesized.expression;
            if (t.* == .identifier_reference) {
                break :blk self.source[t.identifier_reference.span.start..t.identifier_reference.span.end];
            }
            break :blk null;
        };
        try self.applyDefaultExprNamed(elt.assignment.value, elt.assignment.span, named_target);
        try self.assignAssignmentPatternLeaf(elt.assignment.target.*);
        return;
    }
    try self.assignAssignmentPatternLeaf(elt);
}

/// Assign `acc` to the LHS-shaped Expression. Leaves may be
/// identifier_reference, member, parenthesized, or further
/// destructuring patterns.
fn assignAssignmentPatternLeaf(self: *Compiler, target: ast.expression.Expression) CompileError!void {
    switch (target) {
        .identifier_reference => |ir| {
            const name = self.source[ir.span.start..ir.span.end];
            const scope = self.scope orelse return error.UnresolvedReference;
            // §13.15.5.3 — fall through to a global write when the
            // identifier doesn't resolve in any user-visible scope.
            // Matches the regular-assignment fallback (sloppy-mode
            // "create on assign"); strict-mode `ReferenceError` is a
            // runtime check `sta_global` will own once `globalThis`
            // grows a sentinel.
            const binding: Binding = scope.resolve(name) orelse Binding{
                .name = name,
                .env_slot = 0,
                .env_depth = 0,
                .kind = .var_,
                .span = ir.span,
                .is_global = true,
            };
            try self.emitStoreBinding(binding, ir.span);
        },
        .member => |m| {
            if (m.optional) return error.UnsupportedExpression;
            if (m.object.* == .super_) return error.UnsupportedExpression;
            try self.assignToMember(m, m.span);
        },
        .parenthesized => |paren| try self.assignAssignmentPatternLeaf(paren.expression.*),
        .array_literal, .object_literal => try self.compileAssignmentPattern(target),
        else => return error.UnsupportedExpression,
    }
}

/// Same shape as `compileForOfMemberAssign`'s body — emit a
/// member-target assignment with `acc` as the value.
fn assignToMember(self: *Compiler, m: ast.expression.MemberExpr, span: Span) CompileError!void {
    const r_value = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, span);
    try self.builder.emitU8(r_value);

    try self.compileExpression(m.object);
    const r_obj = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, span);
    try self.builder.emitU8(r_obj);

    switch (m.property) {
        .ident => |kspan| {
            const raw = self.source[kspan.start..kspan.end];
            if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
            const key = try self.decodeIdentifierName(raw);
            const k = try self.internString(key);
            try self.builder.emitOp(.ldar, span);
            try self.builder.emitU8(r_value);
            try self.builder.emitOp(.sta_property, span);
            try self.builder.emitU16(k);
            try self.builder.emitU8(r_obj);
        },
        .computed => |key_expr| {
            try self.compileExpression(key_expr);
            const r_key = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, span);
            try self.builder.emitU8(r_key);
            try self.builder.emitOp(.ldar, span);
            try self.builder.emitU8(r_value);
            try self.builder.emitOp(.sta_computed, span);
            try self.builder.emitU8(r_obj);
            try self.builder.emitU8(r_key);
        },
    }
}

/// Decode the property-key shape for an assignment-pattern
/// `.property` element. Mirrors the rules in compileObjectLiteral
/// (ident decode + string-literal trim).
fn assignmentPatternKey(self: *Compiler, key: ast.expression.PropertyKey) CompileError![]const u8 {
    return switch (key) {
        .ident => |span| try self.decodeIdentifierName(self.source[span.start..span.end]),
        .string => |span| inner: {
            const raw = self.source[span.start..span.end];
            if (raw.len < 2) return error.UnsupportedExpression;
            break :inner raw[1 .. raw.len - 1];
        },
        .numeric => |span| self.source[span.start..span.end],
        else => return error.UnsupportedExpression,
    };
}

/// `acc = (acc === undefined) ? <default-expr> : acc`.
/// Assignment-pattern variant that takes the default as an
/// already-parsed Expression pointer (not a BindingElement).
fn applyDefaultExpr(self: *Compiler, default_expr: *const ast.expression.Expression, span: Span) CompileError!void {
    return applyDefaultExprNamed(self, default_expr, span, null);
}

/// `applyDefaultExpr` with optional `binding_name` — when
/// supplied and the default expression is an anonymous
/// function-like, the function adopts that name (§13.15.5.5).
fn applyDefaultExprNamed(self: *Compiler, default_expr: *const ast.expression.Expression, span: Span, binding_name: ?[]const u8) CompileError!void {
    const r_val = try self.reserveTemp();
    defer self.releaseTemp();
    try self.builder.emitOp(.star, span);
    try self.builder.emitU8(r_val);

    try self.builder.emitOp(.lda_undefined, span);
    try self.builder.emitOp(.strict_neq, span);
    try self.builder.emitU8(r_val);
    try self.builder.emitOp(.jmp_if_true, span);
    const keep_patch = self.builder.here();
    try self.builder.emitI16(0);

    if (binding_name) |name| {
        try self.compileNamedValue(default_expr, name);
    } else {
        try self.compileExpression(default_expr);
    }
    try self.builder.emitOp(.jmp, span);
    const end_patch = self.builder.here();
    try self.builder.emitI16(0);

    const keep_target = self.builder.here();
    try self.builder.patchI16(keep_patch, keep_target);
    try self.builder.emitOp(.ldar, span);
    try self.builder.emitU8(r_val);

    const end_target = self.builder.here();
    try self.builder.patchI16(end_patch, end_target);
}

/// §10.2.3 — rest parameter prologue: collect the trailing args
/// (the ones beyond the explicit params) into a fresh Array via
/// `rest_args_from start`, and bind that array to the rest
/// target's slot. Destructuring rest targets walk the resulting
/// array through `compileDestructure`.
fn emitRestParamPrologue(self: *Compiler, rp: *const ast.statement.RestParam, start_index: u8) CompileError!void {
    if (rp.target == .identifier) {
        const param_name = self.source[rp.target.identifier.span.start..rp.target.identifier.span.end];
        const slot = try self.declareBinding(param_name, .let_, rp.span);
        try self.builder.emitOp(.rest_args_from, rp.span);
        try self.builder.emitU8(start_index);
        try self.builder.emitOp(.sta_env, rp.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(slot);
    } else {
        try self.declarePatternBindings(rp.target, .let_);
        try self.builder.emitOp(.rest_args_from, rp.span);
        try self.builder.emitU8(start_index);
        try self.compileDestructure(rp.target);
    }
}

/// §10.2.3 prologue for a single non-rest parameter — declare
/// the binding, copy the caller-supplied register `i` into the
/// function's env slot, and apply a default expression when the
/// arg is `undefined` (§15.2.4 IteratorBindingInitialization).
/// Destructuring patterns route through `compileDestructure`
/// after the default is in `acc`.
fn emitParamPrologue(self: *Compiler, sp: *const ast.statement.SimpleParam, i: u8) CompileError!void {
    if (sp.target == .identifier) {
        const param_name = self.source[sp.target.identifier.span.start..sp.target.identifier.span.end];
        const slot = try self.declareBinding(param_name, .let_, sp.span);
        // Load the caller-supplied register into acc.
        try self.builder.emitOp(.ldar, sp.span);
        try self.builder.emitU8(i);
        // §15.2.4 step 8 — `function f(x = expr)`: when the
        // argument is `undefined`, evaluate `expr` (with the
        // already-bound earlier params visible) and use its
        // value. Anonymous function-likes pick up the param
        // name (§15.5.6.4).
        if (sp.default) |*default_expr| {
            try self.applyDefaultExprNamed(default_expr, sp.span, param_name);
        }
        try self.builder.emitOp(.sta_env, sp.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(slot);
    } else {
        // §15.2 Destructuring parameter — declare each leaf
        // binding, then walk the pattern over the arg in `acc`.
        try self.declarePatternBindings(sp.target, .let_);
        try self.builder.emitOp(.ldar, sp.span);
        try self.builder.emitU8(i);
        if (sp.default) |*default_expr| {
            try self.applyDefaultExprNamed(default_expr, sp.span, null);
        }
        try self.compileDestructure(sp.target);
    }
    // Account for the param register so the chunk's register
    // file sizing covers them.
    if (i + 1 > self.builder.register_count) {
        self.builder.register_count = i + 1;
    }
}

/// `acc = (acc === undefined) ? default : acc`. No-op if no
/// default is attached.
fn applyDefaultIfNeeded(self: *Compiler, elem: ast.statement.BindingElement) CompileError!void {
    if (elem.default) |*default_expr| {
        // §13.15.5.5 — when the destructure target is a plain
        // BindingIdentifier and the initializer is anonymous,
        // SetFunctionName adopts the binding name. Routing
        // through `applyDefaultExprNamed` lets the caller skip
        // explicit re-encoding here.
        const inferred_name: ?[]const u8 = switch (elem.target) {
            .identifier => |id| self.source[id.span.start..id.span.end],
            else => null,
        };
        try self.applyDefaultExprNamed(default_expr, elem.span, inferred_name);
    }
}

fn assignPatternLeaf(self: *Compiler, target: ast.statement.BindingTarget) CompileError!void {
    switch (target) {
        .identifier => |id| {
            const name = self.source[id.span.start..id.span.end];
            try self.assignToBinding(name, id.span);
        },
        .array, .object => try self.compileDestructure(target),
    }
}

fn assignToBinding(self: *Compiler, name: []const u8, span: Span) CompileError!void {
    const scope = self.scope orelse return error.UnresolvedReference;
    const binding = scope.resolve(name) orelse return error.UnresolvedReference;
    try self.emitStoreBinding(binding, span);
}

/// Returns the binding name slice for a `BindingTarget` if it is
/// a single bare identifier. Destructuring (object / array
/// patterns) is later+post; until then we surface
/// `UnsupportedStatement` for those forms.
fn identifierName(source: []const u8, target: ast.statement.BindingTarget) ?[]const u8 {
    return switch (target) {
        .identifier => |id| source[id.span.start..id.span.end],
        else => null,
    };
}

fn compileIf(self: *Compiler, s: ast.statement.IfStmt) CompileError!void {
    try self.compileExpression(&s.test_);
    try self.builder.emitOp(.jmp_if_false, s.span);
    const else_patch = self.builder.here();
    try self.builder.emitI16(0);

    try self.compileStatement(s.consequent);

    if (s.alternate) |alt| {
        try self.builder.emitOp(.jmp, s.span);
        const end_patch = self.builder.here();
        try self.builder.emitI16(0);
        const else_target = self.builder.here();
        try self.builder.patchI16(else_patch, else_target);
        try self.compileStatement(alt);
        const end_target = self.builder.here();
        try self.builder.patchI16(end_patch, end_target);
    } else {
        const end_target = self.builder.here();
        try self.builder.patchI16(else_patch, end_target);
    }
}

/// Frame on `Compiler.class_stack` — pushed when entering a
/// class body so method / field bodies can find the surrounding
/// class's `private_prefix`. The prefix is owned by the realm's
/// `class_arena`, so it outlives the compiler.
const ClassContext = struct {
    private_prefix: []const u8,
    is_derived: bool,
};

/// §14.15 active try-finally context. Linked list, innermost
/// first. `compileReturn` walks it to emit each finally body
/// before issuing `return_`.
const FinallyContext = struct {
    body: []ast.statement.Statement,
    span: Span,
    parent: ?*FinallyContext = null,
};

const LoopContext = struct {
    /// PC where `continue` jumps. For `while` / `do-while` this
    /// is the test re-entry; for C-style `for` it's the update
    /// expression.
    continue_target: u32,
    /// Pending `break` patches — backfilled with the post-loop
    /// PC at loop exit.
    break_patches: std.ArrayListUnmanaged(u32) = .empty,
    /// Pending `continue` patches when the continue target isn't
    /// known at the time the `continue` statement is compiled
    /// (rare later — `for` resolves it at update-emit time).
    continue_patches: std.ArrayListUnmanaged(u32) = .empty,
    /// True for `for-of` / `for-in` loops over `let` / `const`
    /// — the body runs in a per-iteration env that must be
    /// popped before any cross-loop jump (`break` skips past
    /// the natural `pop_env`; `continue` jumps to a target
    /// that emits one).
    needs_env_pop: bool = false,
    /// For `for-of` loops, the register holding the open
    /// iterator. `break` and `return` from inside the body
    /// must invoke §7.4.6 IteratorClose on this iterator before
    /// jumping out. `null` for `for`, `while`, `do-while`, and
    /// `for-in` (the latter doesn't follow the iterator
    /// protocol).
    iter_register: ?u8 = null,
    /// Surrounding loop within the same function frame, or
    /// `null` at the outermost. `return` walks this chain to
    /// close every active `for-of` iterator on the way out.
    /// Function boundaries reset to `null` (each function gets
    /// its own loop chain).
    parent: ?*LoopContext = null,
    /// Snapshot of `finally_chain` at the moment the loop was
    /// entered. `break` and `continue` walk the chain from the
    /// current head down to (but not including) this anchor,
    /// inlining each finally body so abrupt exits from inside a
    /// `try { … } finally { F }` nested in the loop body still
    /// run F. §14.15.3 step 4: an abrupt finally completion
    /// replaces the outer one outright.
    entry_finally_chain: ?*FinallyContext = null,

    fn deinit(self: *LoopContext, allocator: std.mem.Allocator) void {
        self.break_patches.deinit(allocator);
        self.continue_patches.deinit(allocator);
    }
};

fn compileWhile(self: *Compiler, s: ast.statement.WhileStmt) CompileError!void {
    const loop_start = self.builder.here();
    try self.compileExpression(&s.test_);
    try self.builder.emitOp(.jmp_if_false, s.span);
    const exit_patch = self.builder.here();
    try self.builder.emitI16(0);

    var ctx: LoopContext = .{
        .continue_target = loop_start,
        .parent = self.current_loop,
        .entry_finally_chain = self.finally_chain,
    };
    defer ctx.deinit(self.allocator);
    const saved = self.current_loop;
    self.current_loop = &ctx;
    defer self.current_loop = saved;

    try self.compileStatement(s.body);
    try self.builder.emitOp(.jmp, s.span);
    const back_patch = self.builder.here();
    try self.builder.emitI16(0);
    try self.builder.patchI16(back_patch, loop_start);

    const exit_target = self.builder.here();
    try self.builder.patchI16(exit_patch, exit_target);
    for (ctx.break_patches.items) |p| try self.builder.patchI16(p, exit_target);
    // `while`'s continue target is `loop_start` — but
    // `compileContinue` deferred the patch in case the loop
    // shape resolved its target later. Patch them now.
    for (ctx.continue_patches.items) |p| try self.builder.patchI16(p, loop_start);
}

fn compileDoWhile(self: *Compiler, s: ast.statement.DoWhileStmt) CompileError!void {
    const loop_start = self.builder.here();
    var ctx: LoopContext = .{
        .continue_target = 0,
        .parent = self.current_loop,
        .entry_finally_chain = self.finally_chain,
    }; // patched after body
    defer ctx.deinit(self.allocator);
    const saved = self.current_loop;
    self.current_loop = &ctx;
    defer self.current_loop = saved;

    try self.compileStatement(s.body);
    const test_pc = self.builder.here();
    ctx.continue_target = test_pc;
    try self.compileExpression(&s.test_);
    try self.builder.emitOp(.jmp_if_true, s.span);
    const back_patch = self.builder.here();
    try self.builder.emitI16(0);
    try self.builder.patchI16(back_patch, loop_start);

    const exit_target = self.builder.here();
    for (ctx.break_patches.items) |p| try self.builder.patchI16(p, exit_target);
    for (ctx.continue_patches.items) |p| try self.builder.patchI16(p, test_pc);
}

fn compileFor(self: *Compiler, s: ast.statement.ForStmt) CompileError!void {
    // §14.7.4 ForStatement (C-style — for-in / for-of compile
    // separately). For a single `let`/`const` head binding,
    // §14.7.4.1 ForBodyEvaluation step 2 + CreatePerIterationEnvironment
    // require a fresh declarative environment per iteration so
    // closures captured inside the body see iteration-specific
    // values. later handles the single-binding case (the
    // overwhelming majority of for-let loops); multi-declarator
    // heads and `var` heads stay on the legacy single-slot
    // path.

    // Detect the single-let/const-binding case.
    var per_iter_env = false;
    var single_name: []const u8 = "";
    var single_span: Span = s.span;
    var single_kind: BindingKind = .let_;
    if (s.init) |head| switch (head) {
        .lexical => |ld| if (ld.kind != .var_ and ld.declarators.len == 1) {
            const d = ld.declarators[0];
            if (identifierName(self.source, d.name)) |name| {
                per_iter_env = true;
                single_name = name;
                single_span = d.span;
                single_kind = if (ld.kind == .let_) .let_ else .const_;
            }
        },
        else => {},
    };

    var for_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = per_iter_env };
    defer for_scope.deinit(self.allocator);
    const saved = self.scope;
    self.scope = &for_scope;
    defer self.scope = saved;

    const saved_env_depth = self.env_depth;
    defer self.env_depth = saved_env_depth;

    // Carry-forward register: holds the binding's value across
    // env swaps. Seeded from the init expression; later updated
    // from the per-iter env's slot before each fresh-env push.
    var r_carry: u8 = 0;
    var per_iter_size_patch: usize = 0;
    var saved_per_iter_slot_count: u8 = 0;
    if (per_iter_env) {
        r_carry = try self.reserveTemp();

        // Evaluate the init expression in the OUTER env. The
        // declarator's init RHS can reference outer bindings;
        // it cannot reference the loop binding itself (TDZ).
        if (s.init.?.lexical.declarators[0].init) |*init_expr| {
            try self.compileExpression(init_expr);
        } else {
            try self.builder.emitOp(.lda_undefined, single_span);
        }
        try self.builder.emitOp(.star, single_span);
        try self.builder.emitU8(r_carry);

        // Per-iter env owns its own slot pool (loop var + body
        // lexicals). Borrow `env_slot_count`, reset it, restore
        // at loop teardown — see compileForInOf for the same
        // shape. Without this, body's first `const` aliases the
        // loop variable.
        saved_per_iter_slot_count = self.env_slot_count;
        self.env_slot_count = 0;
        // Push the initial per-iter env (E_0) and seed it.
        try self.builder.emitOp(.make_environment, s.span);
        per_iter_size_patch = self.builder.code.items.len;
        try self.builder.emitU8(0); // placeholder; patched below
        self.env_depth = saved_env_depth + 1;
        _ = try self.declareBinding(single_name, single_kind, single_span);
        try self.builder.emitOp(.ldar, single_span);
        try self.builder.emitU8(r_carry);
        try self.builder.emitOp(.sta_env, single_span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(0);
    } else if (s.init) |head| switch (head) {
        .lexical => |ld| {
            if (ld.kind != .var_) {
                const kind: BindingKind = if (ld.kind == .let_) .let_ else .const_;
                for (ld.declarators) |d| {
                    // §13.3.1 — declare every leaf binding (or
                    // the single ident) for `let`/`const`. Patterns
                    // are walked via `declarePatternBindings`; the
                    // assignment / destructure happens later via
                    // `compileLexicalDecl`.
                    try self.declarePatternBindings(d.name, kind);
                }
            }
            try self.compileLexicalDecl(ld);
        },
        .expression => |e| try self.compileExpression(&e),
    };

    const loop_start = self.builder.here();

    var exit_patch: ?u32 = null;
    if (s.test_) |*t| {
        try self.compileExpression(t);
        try self.builder.emitOp(.jmp_if_false, s.span);
        exit_patch = self.builder.here();
        try self.builder.emitI16(0);
    }

    var ctx: LoopContext = .{
        .continue_target = 0,
        .needs_env_pop = per_iter_env,
        .parent = self.current_loop,
        .entry_finally_chain = self.finally_chain,
    };
    defer ctx.deinit(self.allocator);
    const saved_loop = self.current_loop;
    self.current_loop = &ctx;
    defer self.current_loop = saved_loop;

    try self.compileStatement(s.body);

    // §14.7.4.1 ForBodyEvaluation step 2.d/2.e —
    // CreatePerIterationEnvironment runs AFTER the body, BEFORE
    // the update. The closures captured in the body must keep
    // referring to *their* iteration's env (which is left
    // alive only via those closures); the update mutates the
    // FRESH env that becomes the next iteration's view.
    const update_pc = self.builder.here();
    ctx.continue_target = update_pc;
    var per_iter_size_patch_2: usize = 0;
    if (per_iter_env) {
        // r_carry ← value from current per-iter env
        try self.builder.emitOp(.lda_env, s.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(0);
        try self.builder.emitOp(.star, s.span);
        try self.builder.emitU8(r_carry);
        // Pop current env and push a fresh one.
        try self.builder.emitOp(.pop_env, s.span);
        try self.builder.emitOp(.make_environment, s.span);
        per_iter_size_patch_2 = self.builder.code.items.len;
        try self.builder.emitU8(0); // placeholder; patched below
        try self.builder.emitOp(.ldar, s.span);
        try self.builder.emitU8(r_carry);
        try self.builder.emitOp(.sta_env, s.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(0);
    }
    if (s.update) |*u| {
        try self.compileExpression(u);
    }

    try self.builder.emitOp(.jmp, s.span);
    const back_patch = self.builder.here();
    try self.builder.emitI16(0);
    try self.builder.patchI16(back_patch, loop_start);

    // Exit: pop the lingering per-iter env on test-failed exit.
    // `break` pops via compileBreak; the natural test-fail path
    // needs an explicit pop here.
    if (per_iter_env) {
        if (exit_patch) |p| {
            const fail_pc = self.builder.here();
            try self.builder.patchI16(p, fail_pc);
            try self.builder.emitOp(.pop_env, s.span);
        }
    } else if (exit_patch) |p| {
        try self.builder.patchI16(p, self.builder.here());
    }
    const real_exit = self.builder.here();
    for (ctx.break_patches.items) |patch| try self.builder.patchI16(patch, real_exit);
    for (ctx.continue_patches.items) |patch| try self.builder.patchI16(patch, update_pc);

    if (per_iter_env) {
        // Patch both per-iter `make_environment` size operands
        // (initial seed + per-iteration refresh) to whatever
        // env_slot_count grew to. Restore the enclosing
        // function's slot counter.
        self.builder.code.items[per_iter_size_patch] = self.env_slot_count;
        self.builder.code.items[per_iter_size_patch_2] = self.env_slot_count;
        self.env_slot_count = saved_per_iter_slot_count;
        self.releaseTemp(); // r_carry
    }
}

/// Inline every finally body whose try-statement was opened
/// after `anchor` (i.e. lies between the abrupt-completion site
/// and `anchor` in lexical order). Used by `break` / `continue`
/// to honour §14.15.3 step 4: a `try { … break; } finally { F }`
/// must run F before the loop exit. The chain is rewound past
/// each `f` before its body is compiled so an abrupt `return` /
/// `break` / `continue` inside F doesn't re-inline F itself.
fn emitFinalliesUntil(
    self: *Compiler,
    anchor: ?*FinallyContext,
    span: Span,
) CompileError!void {
    if (self.finally_chain == anchor) return;
    const saved_chain = self.finally_chain;
    defer self.finally_chain = saved_chain;
    var fctx = self.finally_chain;
    while (fctx) |f| : (fctx = f.parent) {
        if (f == anchor) break;
        self.finally_chain = f.parent;
        try self.compileBlock(f.body, span);
    }
}

fn compileBreak(self: *Compiler, s: ast.statement.BreakStmt) CompileError!void {
    const ctx = self.current_loop orelse {
        try self.report(.unexpected_token, s.span);
        return error.UnsupportedStatement;
    };
    // §7.4.6 IteratorClose — `for-of` iterator must be closed
    // when `break` interrupts iteration. Other loop kinds skip.
    if (ctx.iter_register) |r_iter| {
        try self.builder.emitOp(.iter_close, s.span);
        try self.builder.emitU8(r_iter);
    }
    // §14.15 — run every finally block opened between this
    // `break` and the loop entry before transferring control.
    try self.emitFinalliesUntil(ctx.entry_finally_chain, s.span);
    // `break` jumps past the natural `pop_env` site; emit one
    // here so the per-iteration env doesn't outlive the loop.
    if (ctx.needs_env_pop) try self.builder.emitOp(.pop_env, s.span);
    try self.builder.emitOp(.jmp, s.span);
    const patch = self.builder.here();
    try self.builder.emitI16(0);
    try ctx.break_patches.append(self.allocator, patch);
}

fn compileContinue(self: *Compiler, s: ast.statement.ContinueStmt) CompileError!void {
    // Defer the patch — `for` loops don't know their continue
    // target (the update PC) until the body has been compiled,
    // and `do-while` doesn't know its test PC until after the
    // body. Loop-specific compile routines walk
    // `continue_patches` at the end and patch each.
    const ctx = self.current_loop orelse {
        try self.report(.unexpected_token, s.span);
        return error.UnsupportedStatement;
    };
    // §14.15 — run every finally block opened between this
    // `continue` and the loop entry before transferring control.
    try self.emitFinalliesUntil(ctx.entry_finally_chain, s.span);
    // `continue` lands at `continue_target`, which (for
    // for-of/for-in over `let`) emits the `pop_env` itself —
    // so we don't need to pop here.
    try self.builder.emitOp(.jmp, s.span);
    const patch = self.builder.here();
    try self.builder.emitI16(0);
    try ctx.continue_patches.append(self.allocator, patch);
}

fn compileThrow(self: *Compiler, s: ast.statement.ThrowStmt) CompileError!void {
    try self.compileExpression(&s.argument);
    try self.builder.emitOp(.throw_, s.span);
}

fn compileTry(self: *Compiler, s: ast.statement.TryStmt) CompileError!void {
    // §14.15 TryStatement.
    //
    // try { A } catch (e) { B } — A's handler runs B.
    // try { A } finally { F } — Synthetic handler:
    // A's throw lands on
    // F, which re-throws
    // at end.
    // try { A } catch (e) { B } finally {} — A's handler runs B,
    // F runs on every
    // path (B's throws
    // via a second
    // synthetic handler).
    //
    // distinguish abrupt-return vs throw inside finally
    // (currently both propagate as throws via the rethrow at the
    // end of synthetic handlers).

    // Push the finally context BEFORE compiling the try body so
    // any `return` / `break` inside it knows to inline the
    // finally before exiting.
    var fctx_storage: FinallyContext = undefined;
    var pushed_finally = false;
    if (s.finalizer) |fb| {
        fctx_storage = .{
            .body = fb.body,
            .span = fb.span,
            .parent = self.finally_chain,
        };
        self.finally_chain = &fctx_storage;
        pushed_finally = true;
    }

    const start_pc = self.builder.here();
    try self.compileBlock(s.block.body, s.block.span);
    const end_pc = self.builder.here();

    // Jump past the catch landing on the normal-completion path.
    try self.builder.emitOp(.jmp, s.span);
    const skip_handler_patch = self.builder.here();
    try self.builder.emitI16(0);

    // Track the catch body's PC range so a `finally` (if any) can
    // also wrap a synthetic handler around it.
    var catch_body_start: ?u32 = null;
    var catch_body_end: ?u32 = null;
    var catch_register: ?u8 = null;
    if (s.handler) |h| {
        const handler_pc = self.builder.here();
        catch_body_start = handler_pc;
        var catch_scope: Scope = .{ .parent = self.scope, .kind = .block };
        defer catch_scope.deinit(self.allocator);
        const saved = self.scope;
        self.scope = &catch_scope;
        defer self.scope = saved;

        if (h.param) |target| {
            // §14.15 CatchParameter is a BindingIdentifier or
            // BindingPattern. The dispatch in `unwindThrow` deposits
            // the thrown value into the env slot recorded as
            // `catch_register`. For a bare identifier we declare
            // that identifier directly. For a pattern we allocate a
            // synthetic let slot, declare each leaf binding inside
            // the pattern, and deconstruct from the synthetic slot
            // at the top of the handler body.
            switch (target) {
                .identifier => {
                    const name = identifierName(self.source, target) orelse return error.UnsupportedStatement;
                    catch_register = try self.declareBinding(name, .let_, h.span);
                },
                .array, .object => {
                    const synth_slot = try self.declareBinding("__cynic_catch_ex__", .let_, target.span());
                    catch_register = synth_slot;
                    try self.declarePatternBindings(target, .let_);
                    // Load the deposited exception into acc and run
                    // BindingInitialization (§14.15.10 step 5).
                    try self.builder.emitOp(.lda_env, target.span());
                    try self.builder.emitU8(0);
                    try self.builder.emitU8(synth_slot);
                    try self.compileDestructure(target);
                },
            }
        }
        try self.compileBlock(h.body.body, h.body.span);
        catch_body_end = self.builder.here();

        try self.builder.addHandler(.{
            .start_pc = start_pc,
            .end_pc = end_pc,
            .handler_pc = handler_pc,
            .catch_register = catch_register,
        });
    }

    // Pop the finally context — the merge / synthetic-handler
    // emission below should NOT see it (so a `return` inside
    // the finally block doesn't recurse into itself).
    if (pushed_finally) self.finally_chain = fctx_storage.parent;

    // §14.15.10 — when a finally block is present, wire two
    // synthetic handlers so abrupt completions thread through it:
    // 1. If `try` has NO catch: handler covers the try body and
    // lands on an inline finally-then-rethrow snippet.
    // 2. If `try` has BOTH catch and finally: the catch body
    // itself gets a synthetic handler that runs finally and
    // rethrows when the catch body throws.
    if (s.finalizer) |fb| {
        // Normal/caught path lands at merge_pc and runs finally.
        // The finally chain was already popped above so a
        // `return` inside fb won't recurse.
        const merge_pc = self.builder.here();
        try self.builder.patchI16(skip_handler_patch, merge_pc);
        try self.compileBlock(fb.body, fb.span);
        try self.builder.emitOp(.jmp, s.span);
        const skip_synth_patch = self.builder.here();
        try self.builder.emitI16(0);

        // Synthetic abrupt-completion handler: receives the thrown
        // value in a fresh slot, runs finally, then `throw`s the
        // saved value to propagate.
        const synth_pc = self.builder.here();
        var synth_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = true };
        defer synth_scope.deinit(self.allocator);
        const saved_scope = self.scope;
        self.scope = &synth_scope;
        defer self.scope = saved_scope;
        const saved_env_depth = self.env_depth;
        defer self.env_depth = saved_env_depth;
        const slot = try self.declareBinding("__cynic_finally_ex__", .let_, s.span);
        // The handler dispatch deposits the thrown value via
        // `catch_register` (an env slot at depth 0).
        try self.compileBlock(fb.body, fb.span);
        try self.builder.emitOp(.lda_env, s.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(slot);
        try self.builder.emitOp(.throw_, s.span);
        const after_finally_pc = self.builder.here();
        try self.builder.patchI16(skip_synth_patch, after_finally_pc);

        // No-catch case: cover the try body with the synthetic
        // handler. With-catch case: cover the catch body too.
        if (s.handler == null) {
            try self.builder.addHandler(.{
                .start_pc = start_pc,
                .end_pc = end_pc,
                .handler_pc = synth_pc,
                .catch_register = slot,
            });
        } else if (catch_body_start != null and catch_body_end != null) {
            try self.builder.addHandler(.{
                .start_pc = catch_body_start.?,
                .end_pc = catch_body_end.?,
                .handler_pc = synth_pc,
                .catch_register = slot,
            });
        }
    } else {
        // No finally — control just merges past the catch landing.
        const merge_pc = self.builder.here();
        try self.builder.patchI16(skip_handler_patch, merge_pc);
    }
}
};

/// Discriminator for the body shape passed to
/// [compileFunctionTemplate]. Block-bodied functions and arrows
/// share one path; concise-body arrows take the other.
pub const FunctionBody = union(enum) {
    block: []ast.statement.Statement,
    expression: *const Expression,
};

fn compileFunctionTemplate(
    self: *Compiler,
    params: []ast.statement.FunctionParam,
    body: FunctionBody,
    name: ?[]const u8,
    is_arrow: bool,
    span: Span,
) CompileError!u16 {
    return compileFunctionTemplateExt(self, params, body, name, is_arrow, false, false, span);
}

fn compileFunctionTemplateExt(
    self: *Compiler,
    params: []ast.statement.FunctionParam,
    body: FunctionBody,
    name: ?[]const u8,
    is_arrow: bool,
    is_generator: bool,
    is_async: bool,
    span: Span,
) CompileError!u16 {
    // Save outer state.
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;

    // Reset to a fresh inner state.
    self.builder = @import("chunk.zig").Builder.init(self.allocator);
    var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1;
    self.current_loop = null;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
        }
    }

    // Emit a `MakeEnvironment` placeholder. We patch the slot
    // count once the body has been compiled and we know how many
    // bindings the function needs.
    try self.builder.emitOp(.make_environment, span);
    const slot_count_patch = self.builder.here();
    try self.builder.emitU8(0);

    // Declare params (env slots 0, 1,...) and emit the param-
    // receive preamble. Each arg arrives in caller-supplied
    // register r{i}; we Ldar then StaEnv into the function's
    // own env slot.
    for (params, 0..) |*p, i| {
        switch (p.*) {
            .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
            .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
        }
    }

    // §10.4.4 Implicit `arguments` binding for non-arrow
    // functions. Only installed when the body actually
    // references `arguments` — saves a slot otherwise.
    if (!is_arrow) {
        const refs = switch (body) {
            .block => |stmts| referencesArguments(self.source, stmts),
            .expression => false, // concise-body arrows can't be reached here
        };
        if (refs) {
            const slot = try self.declareBinding("arguments", .let_, span);
            try self.builder.emitOp(.lda_arguments, span);
            try self.builder.emitOp(.sta_env, span);
            try self.builder.emitU8(0);
            try self.builder.emitU8(slot);
        }
    }

    // Compile body.
    switch (body) {
        .block => |stmts| {
            try self.hoistLetConst(stmts);
            try self.hoistVarAndFunctions(stmts);
            try self.emitVarInits(span);
            // Function decls go first — see compileScriptAsChunk.
            for (stmts) |*s| if (s.* == .function_decl) try self.compileStatement(s);
            for (stmts) |*s| if (s.* != .function_decl) try self.compileStatement(s);
            try self.builder.emitOp(.lda_undefined, span);
            try self.builder.emitOp(.return_, span);
        },
        .expression => |e| {
            try self.compileExpression(e);
            try self.builder.emitOp(.return_, span);
        },
    }

    // Patch the MakeEnvironment slot count.
    self.builder.code.items[slot_count_patch] = self.env_slot_count;

    const final_slot_count = self.env_slot_count;
    _ = final_slot_count;

    const inner_chunk = try self.builder.finish();
    inner_finished = true;
    fn_scope.deinit(self.allocator);

    // Restore outer state.
    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;

    return self.builder.addFunctionTemplate(.{
        .chunk = inner_chunk,
        .param_count = @intCast(params.len),
        .name = name,
        .is_arrow = is_arrow,
        .is_generator = is_generator,
        .is_async = is_async,
        // §20.2.3.5 — borrow the original source span so
        // `Function.prototype.toString` can hand it back verbatim
        // (whitespace, comments, and all). The slice points into
        // `self.source`, which the realm keeps pinned.
        .source = if (span.start <= span.end and span.end <= self.source.len)
            self.source[span.start..span.end]
        else
            null,
    });
}

/// Compile a top-level Script. Top-level `var` / `let` / `const`
/// / function / class declarations live on the realm's globals
/// map: `declareBinding` registers the name with its
/// initial value and tags the `Binding` as `is_global`, so reads
/// emit `lda_global` and writes emit `sta_global`. The script
/// frame still gets a `make_environment` so block-scoped `let`s
/// inside top-level `{ … }` (which don't migrate to the global
/// env) have a place to live; the slot count is patched once
/// compilation finishes and is typically 0 in real-world scripts.
pub fn compileScriptAsChunk(
    allocator: std.mem.Allocator,
    realm: *Realm,
    program: *const ast.program.Program,
    source: []const u8,
    diagnostics: ?*Diagnostics,
) CompileError!Chunk {
    var c = Compiler.init(allocator, realm, source);
    errdefer c.deinit();
    defer c.class_stack.deinit(c.allocator);
    c.diagnostics = diagnostics;

    var script_scope: Scope = .{ .parent = null, .kind = .script };
    defer script_scope.deinit(c.allocator);
    c.scope = &script_scope;
    c.env_depth = 0;
    c.env_slot_count = 0;

    const start_span: Span = .{ .start = 0, .end = 0 };
    try c.builder.emitOp(.make_environment, start_span);
    const slot_count_patch = c.builder.here();
    try c.builder.emitU8(0);

    try c.hoistLetConst(program.body);
    try c.hoistVarAndFunctions(program.body);
    try c.emitVarInits(start_span);

    // §14.1.3 — top-level function declarations are evaluated
    // before any other statement so forward calls (`f();
    // function f(){}`) resolve. Block-nested function decls
    // (strict-mode lexical) stay where they are.
    for (program.body) |*s| if (s.* == .function_decl) try c.compileStatement(s);
    for (program.body) |*s| if (s.* != .function_decl) try c.compileStatement(s);

    const end_span: Span = .{
        .start = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
        .end = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
    };
    try c.builder.emitOp(.return_, end_span);

    c.builder.code.items[slot_count_patch] = c.env_slot_count;
    var chunk = try c.finish();
    // Pin every JSString in the chunk's constant pool (incl.
    // nested function / class templates). Chunks are realm-
    // lifetime; pinning lets the GC skip walking the chunk
    // tree on every collect. See `Heap.pinChunk`.
    realm.heap.pinChunk(&chunk);
    return chunk;
}

/// Compile a Module — same as `compileScriptAsChunk` but the
/// resulting chunk carries the source URL (for relative-import
/// resolution) and `compileExportDecl` emits `module_export`
/// opcodes that publish bindings to the module's namespace.
pub fn compileModuleAsChunk(
    allocator: std.mem.Allocator,
    realm: *Realm,
    program: *const ast.program.Program,
    source: []const u8,
    diagnostics: ?*Diagnostics,
    base_url: []const u8,
) CompileError!Chunk {
    var c = Compiler.init(allocator, realm, source);
    errdefer c.deinit();
    defer c.class_stack.deinit(c.allocator);
    c.diagnostics = diagnostics;
    c.is_module = true;

    var script_scope: Scope = .{ .parent = null, .kind = .script };
    defer script_scope.deinit(c.allocator);
    c.scope = &script_scope;
    c.env_depth = 0;
    c.env_slot_count = 0;

    const start_span: Span = .{ .start = 0, .end = 0 };
    try c.builder.emitOp(.make_environment, start_span);
    const slot_count_patch = c.builder.here();
    try c.builder.emitU8(0);

    try c.hoistLetConst(program.body);
    try c.hoistVarAndFunctions(program.body);
    try c.emitVarInits(start_span);

    for (program.body) |*s| if (s.* == .function_decl) try c.compileStatement(s);
    for (program.body) |*s| if (s.* != .function_decl) try c.compileStatement(s);

    const end_span: Span = .{
        .start = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
        .end = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
    };
    try c.builder.emitOp(.return_, end_span);

    c.builder.code.items[slot_count_patch] = c.env_slot_count;
    var chunk = try c.finish();
    chunk.base_url = base_url;
    realm.heap.pinChunk(&chunk);
    return chunk;
}

/// Top-level convenience: compile a single expression as a program
/// that runs to a value. Emits a leading MakeEnvironment 0 (no
/// bindings needed for a bare expression) plus a trailing
/// `Return`.
pub fn compileExpressionAsChunk(
    allocator: std.mem.Allocator,
    realm: *Realm,
    expr: *const Expression,
    source: []const u8,
) CompileError!Chunk {
    var c = Compiler.init(allocator, realm, source);
    errdefer c.deinit();
    defer c.class_stack.deinit(c.allocator);
    var script_scope: Scope = .{ .parent = null, .kind = .script };
    defer script_scope.deinit(c.allocator);
    c.scope = &script_scope;
    c.env_depth = 0;
    c.env_slot_count = 0;

    try c.builder.emitOp(.make_environment, expr.span());
    try c.builder.emitU8(0);

    try c.compileExpression(expr);
    try c.builder.emitOp(.return_, expr.span());
    var chunk = try c.finish();
    realm.heap.pinChunk(&chunk);
    return chunk;
}

// ── Helpers ────────────────────────────────────────────────────────────


const testing = std.testing;
const parser_mod = @import("../parser/parser.zig");
const disasm = @import("disasm.zig");

fn expectChunk(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    try testing.expect(program.body.len == 1);
    const stmt = program.body[0];
    try testing.expect(stmt == .expression);
    const expr = stmt.expression.expression;

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    var chunk = try compileExpressionAsChunk(testing.allocator, &realm, &expr, source);
    defer chunk.deinit(testing.allocator);

    const got = try disasm.dump(testing.allocator, &chunk);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

// Note: later's golden-disasm tests for expression compilation were
// removed in the later refactor. Every chunk now begins with
// `MakeEnvironment` and named bindings live in env slots, so the
// pinned byte-by-byte expectations no longer fit. Coverage moved
// to the interpreter-level tests in `runtime/interpreter.zig`,
// which assert on observed *values* and stay stable across
// bytecode-shape changes.

test "compiler: smoke — chunk has the leading MakeEnvironment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), "1;", null);
    try testing.expect(program.body.len == 1);
    const expr = program.body[0].expression.expression;

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    var chunk = try compileExpressionAsChunk(testing.allocator, &realm, &expr, "1;");
    defer chunk.deinit(testing.allocator);

    // First instruction is `MakeEnvironment`, last is `Return`.
    try testing.expect(chunk.code.len >= 2);
    try testing.expectEqual(@intFromEnum(@import("op.zig").Op.make_environment), chunk.code[0]);
    try testing.expectEqual(@intFromEnum(@import("op.zig").Op.return_), chunk.code[chunk.code.len - 1]);
}
