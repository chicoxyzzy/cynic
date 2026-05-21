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
const decodeStringContent = literals.decodeStringContent;
const normalizeTemplateLineTerminators = literals.normalizeTemplateLineTerminators;

const arguments_scan = @import("arguments_scan.zig");
const referencesArguments = arguments_scan.referencesArguments;
const paramsReferenceArguments = arguments_scan.paramsReferenceArguments;

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
    /// Base index into the realm's global declarative env-record
    /// (`GlobalBindings.decl_env`) for this script's slot-indexed
    /// global-lexical bindings. Snapshotted ONCE in
    /// `compileScriptAsChunk` immediately before `hoistLetConst`
    /// (= `realm.globals.decl_env.count()` at that moment), then
    /// stamped into the script body chunk's `Builder` and into
    /// every nested-function sub-`Builder` so the whole compile
    /// tree shares one base. Runtime slot index =
    /// `global_lexical_base + Binding.global_lex_slot`. Unused
    /// (0) for modules. See `Chunk.global_lexical_base`.
    global_lexical_base: u32 = 0,
    /// Running counter for assigning `Binding.global_lex_slot` to
    /// top-level script `let` / `const` / `class` bindings, in
    /// hoist order. Each global-lexical binding declared via
    /// `declareBindingFull` takes the next value; `decl_env`
    /// entries land in the same insertion order, so slot `s`
    /// maps to `decl_env` index `global_lexical_base + s`.
    next_global_lex_slot: u32 = 0,
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
    /// True when the enclosing function is `async function` /
    /// `async function*` / async arrow / async method. `yield*`
    /// uses this to decide whether to emit an `await` on each
    /// inner-iterator step (async-generator yield* per §27.6.3.7).
    current_is_async: bool = false,
    /// True when compiling a module body. Toggles
    /// whether `import` declarations emit `module_load` ops and
    /// whether `export` declarations emit `module_export` ops.
    /// `false` for scripts and inline-test compiles, where
    /// import/export still parse but compile as no-ops.
    is_module: bool = false,
    /// §9.4.6.7 Module Namespace [[Get]] live binding propagation —
    /// maps a module-local binding name to the namespace key(s) it
    /// is exported under. Populated by `compileModuleAsChunk` from
    /// the module's export entries (`export var/let/const/class`,
    /// `export { local as exported }`, `export default <named>`).
    /// `emitStoreBindingMode` consults this map after each store
    /// to a top-level binding and emits a follow-up `module_export
    /// <exported>` for every alias so subsequent reads through
    /// `ns.<exported>` observe the live mutation rather than the
    /// declaration-time snapshot. `null` outside module-mode.
    ///
    /// Limitation: the `module_export` opcode writes to
    /// `realm.current_module`. Mutations made from inside a
    /// callback invoked across a module boundary (e.g. importer
    /// calls a setter exported by this module) land on the
    /// *caller's* current module if any — which is rare in the
    /// corpus but a spec divergence (true live bindings would
    /// follow the binding's *defining* module). Same-module
    /// mutation, the case the corpus and the spec
    /// (get-str-update.js) actually exercise, works.
    module_exports_by_local: ?*std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = null,
    /// Sticky flag set by `compileAwait` whenever an `await`
    /// emits at module top level (lexically outside any function /
    /// arrow / method body — i.e. the enclosing function-like
    /// scope is `.script` and `is_module` is true). Drives the
    /// `Chunk.is_async_module` flag set in `compileModuleAsChunk`,
    /// which tells `interpreter.run` to wrap the body via
    /// `startAsyncCall` so the `await_` opcode can suspend onto a
    /// JSGenerator-backed frame.
    module_has_top_level_await: bool = false,
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
    /// §14.13 LabelledStatement — accumulator of labels that
    /// `compileLabeled` has pushed for the *next* iteration /
    /// switch statement encountered. When a loop's compile
    /// routine enters, it snapshots and clears this list into
    /// its `LoopContext.labels`. A bare block / expression /
    /// non-iteration statement consumes the label by collapsing
    /// into a `BreakContext` (break-only target — see
    /// `pending_break_labels` / `break_chain`). `LabelIdentifier`
    /// scopes are per-function: a label in one function cannot
    /// be the target of a `break` / `continue` in a nested
    /// function. We rely on the fact that function compilers
    /// each get a fresh `Compiler` to avoid threading function
    /// boundaries here.
    pending_labels: std.ArrayListUnmanaged([]const u8) = .empty,

    /// §9.1.1.4.15 CanDeclareGlobalVar / §9.1.1.4.16
    /// CanDeclareGlobalFunction returned false during
    /// `validateGlobalDeclarations` — the script is fully parsed
    /// but its first executable opcode will be a TypeError throw,
    /// not user code. Set so the hoist + emit passes can skip
    /// installation entirely (per §16.1.7 step 12 we want NO
    /// `executed = true;` side effect before the TypeError).
    /// Null name means the failure isn't tied to a single
    /// identifier (defensive default).
    pending_global_decl_error: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, realm: *Realm, source: []const u8) Compiler {
        return .{
            .allocator = allocator,
            .realm = realm,
            .source = source,
            .builder = Builder.init(allocator),
        };
    }

    /// Allocate a `Builder` for a nested-function / sub-chunk,
    /// pre-stamped with the script's `global_lexical_base`. The
    /// base is constant for the entire compile tree of one
    /// script (see `Compiler.global_lexical_base`); a nested
    /// function is invoked with its own chunk, so that chunk
    /// must carry the script's base for its slot-indexed
    /// global-lexical opcodes to resolve. Modules leave the base
    /// at 0 (module top-levels are never slotted).
    fn freshSubBuilder(self: *Compiler) Builder {
        var b = Builder.init(self.allocator);
        b.global_lexical_base = self.global_lexical_base;
        return b;
    }

    pub fn deinit(self: *Compiler) void {
        self.builder.deinit();
        // Note: `pending_labels` and `class_stack` are torn down
        // by their owning compile-entry routine (script /
        // module / expression / function template). Doing it
        // here would double-free when `errdefer c.deinit()`
        // composes with the entry routine's explicit cleanup.
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

    /// Declare a formal parameter. Same shape as `declareBinding`
    /// with `kind = .let_` (params share lexical-env mechanics)
    /// but the resulting `Binding` is flagged `is_param` so a
    /// subsequent `var <same-name>` in the body silently no-ops
    /// per §10.2.11 step 27.b (FunctionDeclarationInstantiation).
    /// Returns the env slot. Caller still emits the `ldar`/store
    /// pair to seed the slot from the call-site register.
    fn declareParam(
        self: *Compiler,
        name: []const u8,
        span: Span,
    ) CompileError!u8 {
        const slot = try self.declareBinding(name, .let_, span);
        const scope = self.scope orelse return slot;
        // The binding we just added is the last entry on the
        // active scope's list — flip its `is_param` flag.
        var bindings = &scope.bindings;
        if (bindings.items.len > 0) {
            const last = &bindings.items[bindings.items.len - 1];
            if (std.mem.eql(u8, last.name, name)) last.is_param = true;
        }
        return slot;
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
                    // §10.2.11 FunctionDeclarationInstantiation
                    // step 27.b — a `var` whose name matches an
                    // existing parameter is silently skipped (the
                    // parameter's binding stands; the var is a
                    // no-op). Parameters are stored as `.let_` for
                    // env-shape symmetry but flagged `is_param`.
                    .let_, .const_ => if (existing.is_param) {
                        return existing;
                    } else {
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
        // Slot-indexed global-lexical access: a top-level script
        // `let` / `const` / `class` binding gets a compile-time
        // 0-based slot, assigned in hoist order. Top-level `var` /
        // `function` declarations stay on the object env-record
        // (no decl_env entry, no slot — keep the string-keyed
        // path); module top-levels are never `is_global`. Each
        // slotted binding takes the next counter value; the
        // matching `installScriptLexBinding` call below appends a
        // `decl_env` entry in the same order, so slot `s` maps to
        // `decl_env` index `global_lexical_base + s`.
        const has_lex_slot = is_global and kind != .var_;
        const lex_slot: u32 = if (has_lex_slot) blk: {
            const s = self.next_global_lex_slot;
            self.next_global_lex_slot += 1;
            break :blk s;
        } else 0;
        const binding: Binding = .{
            .name = name,
            .env_slot = slot,
            .env_depth = self.env_depth,
            .kind = kind,
            .span = span,
            .is_global = is_global,
            .global_lex_slot = lex_slot,
            .has_global_lex_slot = has_lex_slot,
        };
        try target.bindings.append(self.allocator, binding);
        if (is_global) {
            // Hoist-time install on the realm. §16.1.7
            // GlobalDeclarationInstantiation step 5-7 collision
            // checks (HasLexicalDeclaration vs HasVarDeclaration vs
            // HasRestrictedGlobalProperty) ran in
            // `validateGlobalDeclarations` before any hoisting,
            // so by the time we reach this install path the name
            // is known to be installable.
            //
            // • `var` / function → §9.1.1.4.18 / .19
            //   CreateGlobalVar/FunctionBinding — stamp on the
            //   object env-record (the global object's property
            //   bag) with non-configurable flags.
            // • `let` / `const` / `class` → §9.1.1.4.17 step b
            //   CreateMutable/ImmutableBinding — stamp on the
            //   declarative env-record (NOT on globalThis) with
            //   the TDZ Hole. The initialiser's `sta_global`
            //   overwrites.
            if (kind == .var_) {
                try self.realm.globals.installScriptVarBinding(
                    self.realm.allocator,
                    name,
                    Value.undefined_,
                );
            } else {
                try self.realm.globals.installScriptLexBinding(
                    self.realm.allocator,
                    name,
                    kind == .const_,
                );
            }
        }
        return binding;
    }

    /// Emit the load sequence for `binding`: either `lda_env`
    /// (for env-slot bindings) or `lda_global` (for top-level
    /// Script bindings). Both append a `throw_if_hole` for `let`
    /// / `const` to enforce §13.3.1 TDZ.
    fn emitLoadBinding(self: *Compiler, binding: Binding, span: Span) !void {
        if (binding.is_import) {
            // §8.1.1.5.5 CreateImportBinding — indirect alias.
            // Resolve at every read so the importer sees the live
            // state of the source module's binding (live binding
            // semantics, matching V8 / JSC / SpiderMonkey). The
            // namespace slot is module-local (depth 0 in the
            // module's own env); we still subtract env_depth so
            // closures inside the module reach back through the
            // env chain correctly.
            const depth = self.env_depth - binding.env_depth;
            try self.builder.emitOp(.lda_env, span);
            try self.builder.emitU8(depth);
            try self.builder.emitU8(binding.import_ns_slot);
            const k_imp = try self.internString(binding.import_name);
            try self.builder.emitOp(.lda_property, span);
            try self.builder.emitU16(k_imp);
            // §8.1.1.5.5 — accessing an indirect import binding
            // whose source-module slot is still uninitialised must
            // throw a ReferenceError. The source module pre-seeds
            // the namespace with `Hole` for any exported `let` /
            // `const` / `class` declaration that hasn't run yet
            // (see `compileModuleAsChunk`), so this check is what
            // promotes the Hole into the spec-mandated throw.
            try self.builder.emitOp(.throw_if_hole, span);
            return;
        }
        if (binding.is_global) {
            if (binding.has_global_lex_slot) {
                // Slot-indexed load — bounds-checked array index
                // into the realm's declarative env-record, no name
                // hash. The `throw_if_hole` below handles §13.3.1
                // TDZ exactly as the `lda_global` path does.
                try self.builder.emitOp(.lda_global_slot, span);
                try self.builder.emitU32(binding.global_lex_slot);
            } else {
                const k = try self.internString(binding.name);
                try self.builder.emitOp(.lda_global, span);
                try self.builder.emitU16(k);
            }
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
        return self.emitStoreBindingMode(binding, span, false);
    }

    /// Same as `emitStoreBinding` but flags the store as an
    /// initializer — for `is_global` lex bindings this routes
    /// through `sta_global_init` instead of `sta_global` so the
    /// initialization isn't rejected as a const re-assignment.
    /// §9.1.1.4 InitializeBinding vs §9.1.1.4 SetMutableBinding.
    fn emitStoreBindingInit(self: *Compiler, binding: Binding, span: Span) !void {
        return self.emitStoreBindingMode(binding, span, true);
    }

    fn emitStoreBindingMode(self: *Compiler, binding: Binding, span: Span, is_init: bool) !void {
        if (binding.is_fn_expr_name) {
            // §15.6.5 — the named-function-expression self-binding
            // is immutable. §8.1.1.1.4 SetMutableBinding step 9.b on
            // an immutable record throws TypeError. Mirrors the
            // import-binding path: `assignment_to_const` would be a
            // compile-time diagnostic, but real engines (V8 / JSC /
            // SpiderMonkey) surface this as a runtime TypeError so
            // user code can `try { G = 1; } catch (e) { assert(e
            // instanceof TypeError) }` from inside the body.
            try self.builder.emitOp(.throw_assign_const, span);
            return;
        }
        // §9.1.1.1.4 SetMutableBinding step 9.b — assignment to a
        // const captured from an outer function-like scope is the
        // spec's *runtime* TypeError, not an early error. The
        // `compileAssignment` / `compileUpdate` paths defer to us
        // for cross-function const writes (see `cross_fn_capture`);
        // emit the runtime throw so `assert.throws(TypeError, () =>
        // { c = 1; })` from a nested function rounds-trips per spec.
        // `is_init` writes (declarator initializers, named-fn-expr
        // self-bindings, etc.) are NOT assignments and must stay on
        // the regular `sta_env` / `sta_global_init` path.
        if (!is_init and binding.kind == .const_ and !binding.is_global and !binding.is_import and binding.env_depth < self.env_depth) {
            try self.builder.emitOp(.throw_assign_const, span);
            return;
        }
        if (binding.is_import) {
            // §8.1.1.5.5 — import bindings are immutable; §8.1.1.1.4
            // SetMutableBinding step 9.b throws TypeError on store
            // to an immutable record. Direct `x = ...` where `x` is
            // an imported name is also a SyntaxError under strict-
            // mode AssignmentTarget static semantics — but real
            // engines (V8 / JSC) surface it as a *runtime* TypeError
            // when reached via the assignment expression path. Tests
            // exercise both: `assert.throws(TypeError, () => { B =
            // null; })` expects the runtime throw, not a SyntaxError
            // that prevents the surrounding function from even
            // being created. Emit the throw at the store site.
            try self.builder.emitOp(.throw_assign_const, span);
            return;
        }
        if (binding.is_global) {
            if (binding.has_global_lex_slot) {
                // Slot-indexed store for a top-level `let` /
                // `const` / `class`. `is_init` writes (declarator
                // initializers, destructuring leaves threaded with
                // is_init) bypass the const gate via
                // `sta_global_slot_init` — §9.1.1.4
                // InitializeBinding. A re-assignment routes through
                // `sta_global_slot`, which re-applies the §13.3.1
                // TDZ + §13.15.2 const checks inside the opcode.
                // A slotted binding is always lexical and never a
                // function declaration (those are `var`-kind, no
                // slot), so the `sta_global_fn_decl` case can't
                // arise here.
                const op: Op = if (is_init) .sta_global_slot_init else .sta_global_slot;
                try self.builder.emitOp(op, span);
                try self.builder.emitU32(binding.global_lex_slot);
            } else {
                const k = try self.internString(binding.name);
                // §9.1.1.4 InitializeBinding (`is_init = true` for
                // let / const / class declarators + function-decl
                // hoist) bypasses the const-immutability gate so the
                // declaration's initial value lands cleanly. A later
                // re-assignment of the same name routes through the
                // ordinary `sta_global` path and re-applies the gate.
                //
                // §9.1.1.4.19 CreateGlobalFunctionBinding —
                // function-decl writes overwrite both data slot AND
                // descriptor flags via `sta_global_fn_decl`.
                const op: Op = if (is_init and binding.is_function_decl)
                    .sta_global_fn_decl
                else if (is_init and binding.kind != .var_)
                    .sta_global_init
                else
                    .sta_global;
                try self.builder.emitOp(op, span);
                try self.builder.emitU16(k);
            }
        } else {
            const depth = self.env_depth - binding.env_depth;
            // §13.3.1 — non-init store to a `let` / `const` env
            // slot must surface ReferenceError when the slot still
            // holds the TDZ Hole sentinel. `var` slots are seeded
            // `undefined` at hoist and never hold the Hole.
            if (!is_init and binding.kind != .var_) {
                const r_save = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.star, span);
                try self.builder.emitU8(r_save);
                try self.builder.emitOp(.lda_env, span);
                try self.builder.emitU8(depth);
                try self.builder.emitU8(binding.env_slot);
                try self.builder.emitOp(.throw_if_hole, span);
                try self.builder.emitOp(.ldar, span);
                try self.builder.emitU8(r_save);
            }
            try self.builder.emitOp(.sta_env, span);
            try self.builder.emitU8(depth);
            try self.builder.emitU8(binding.env_slot);
        }
        // §9.4.6.7 Module Namespace [[Get]] — re-publish to the
        // executing module's namespace if this binding is one of
        // its exports. `acc` is unmodified by `sta_env` /
        // `sta_global*`, so the follow-up `module_export` writes
        // the just-stored value through. `is_init` writes already
        // emit a `module_export` via `publishExportedNamesFromDecl`
        // (the per-decl publish path); a second emit here is
        // harmless but redundant. Only fire for re-assignments
        // (`is_init == false`) to avoid the double-publish on the
        // declaration line.
        if (!is_init) try self.maybeRepublishExport(binding, span);
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
            .new_target => |t| try self.builder.emitOp(.lda_new_target, t.span),
            .chain => |ch| try self.compileChain(ch),
            .regex_literal => |rl| try self.compileRegexLiteral(rl.span),
            .import_meta => |im| try self.compileImportMeta(im.span),
            .import_call => |ic| try self.compileImportCall(ic),
            else => return error.UnsupportedExpression,
        }
    }

    /// `import.meta` — §16.2.1.7 ImportMeta. Emit the
    /// `import_meta` opcode; the interpreter lazy-initialises
    /// the module's [[ImportMeta]] slot to an ordinary object
    /// (proto: `%Object.prototype%`) on first read and returns
    /// the same cached object on every subsequent read in the
    /// same module (test262
    /// `language/expressions/import.meta/same-object-returned.js`,
    /// `distinct-for-each-module.js`,
    /// `import-meta-is-an-ordinary-object.js`).
    fn compileImportMeta(self: *Compiler, span: Span) CompileError!void {
        try self.builder.emitOp(.import_meta, span);
    }

    /// `import(specifier)` — §13.3.10 dynamic import.
    /// Compiles the argument expression into acc, then dispatches
    /// the `dynamic_import` opcode which builds the Promise. The
    /// host's `realm.module_loader` does the actual fetch; on
    /// success the returned Promise fulfils with the namespace,
    /// on failure it rejects with the loader's TypeError.
    fn compileImportCall(self: *Compiler, ic: ast.expression.ImportCallExpr) CompileError!void {
        try self.compileExpression(ic.source);
        try self.builder.emitOp(.dynamic_import, ic.span);
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
        if (y.delegate) {
            // §14.4.14 / §27.6.3.7 — `yield* expr` delegates to
            // another iterator. Open an iterator (async-flavour
            // when the enclosing function is async), loop
            // stepping it, and yield each non-done value to the
            // outer consumer. Inner iterator's final value
            // becomes the value of the `yield*` expression.
            // Resume-arg forwarding (next-with-value /
            // return / throw completion routing) is approximated
            // — only the `next` path is wired today.
            return self.compileYieldDelegate(y);
        }
        if (y.argument) |arg| {
            try self.compileExpression(arg);
        } else {
            try self.builder.emitOp(.lda_undefined, y.span);
        }
        // §27.6.3.7 AsyncGeneratorYield: spec defines `yield X` in an
        // async generator as `Await(X); CompleteStep(NormalCompletion(X))`.
        // Emit the Await first so user-defined thenables get coerced
        // (§27.7.5.3 step 1 PromiseResolve → §27.2.1.3.2 thenable
        // detect → enqueue PromiseResolveThenableJob → suspend on
        // the synthesised Promise → resume with the resolved value
        // already in `acc`). Then gen_yield emits the resolved value.
        // Plain `function*` yields skip this — `current_is_async`
        // gates on the enclosing function being declared `async`.
        // `yield` is grammar-restricted to generator contexts, so
        // a `yield` here implies we're in a generator; `current_is_async`
        // distinguishes async-gen from sync-gen.
        if (self.current_is_async) {
            try self.builder.emitOp(.await_, y.span);
        }
        try self.builder.emitOp(.gen_yield, y.span);
    }

    fn compileYieldDelegate(self: *Compiler, y: ast.expression.YieldExpr) CompileError!void {
        const arg = y.argument orelse return error.UnsupportedExpression;
        const is_async = self.current_is_async;
        try self.compileExpression(arg);
        if (is_async) {
            try self.builder.emitOp(.async_iter_open, y.span);
        } else {
            try self.builder.emitOp(.iter_open, y.span);
        }
        const r_iter = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_iter);
        const r_val = try self.reserveTemp();
        defer self.releaseTemp();

        if (is_async) {
            // §27.6.3.7 async yield* — same shape as the sync
            // path but every inner method invocation is followed
            // by an `await_`. Synthetic handlers around each
            // inner `gen_yield` re-enter the loop on the outer
            // async-gen's `.throw(e)` / `.return(v)`.
            const k_next = try self.internString("next");
            const k_return = try self.internString("return");
            const k_throw = try self.internString("throw");
            const k_value = try self.internString("value");
            const k_done_key = try self.internString("done");
            const k_type_error = try self.internString("TypeError");

            const r_received = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.lda_undefined, y.span);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_received);
            const r_result = try self.reserveTemp();
            defer self.releaseTemp();
            const r_recv = try self.reserveTemp();
            defer self.releaseTemp();
            const r_callee = try self.reserveTemp();
            defer self.releaseTemp();
            const r_arg0 = try self.reserveTemp();
            defer self.releaseTemp();
            // §7.4.2 GetIterator step 4 — capture `[[NextMethod]]`
            // once, before the loop. The spec models `.next()`
            // invocation via `Call(iteratorRecord.[[NextMethod]],
            // iteratorRecord.[[Iterator]], …)` — re-reading `.next`
            // on every iteration would re-fire a user-defined `get
            // next()` accessor, violating
            // `yield-star-async-next.js` (which logs each access
            // and asserts exactly one `get next`). Sync `yield*`
            // also caches via the `__cynic_iter_next__` hidden slot
            // (see `iter_step`); for the async path we use a stack
            // temp because the inner loop calls run through
            // `call_method`, not `iter_step`.
            const r_next = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_next);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_next);

            // ── Next path ──
            const next_path_start = self.builder.here();
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_next);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_callee);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_arg0);
            try self.builder.emitOp(.call_method, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitU8(r_callee);
            try self.builder.emitU8(1);
            try self.builder.emitOp(.await_, y.span);
            // §27.6.3.7 step 7.b.iv — after Awaiting the inner step
            // result, if its Type is not Object, throw a TypeError.
            // A manually implemented async iterator can fulfil its
            // step Promise with a primitive; we must reject the
            // outer step rather than reading `.done` / `.value` off
            // the primitive's prototype chain.
            try self.builder.emitOp(.throw_if_not_object, y.span);
            // ── Shared body — acc holds the awaited result ──
            const body_after_call = self.builder.here();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_done_key);
            try self.builder.emitOp(.jmp_if_true, y.span);
            const exit_patch = self.builder.here();
            try self.builder.emitI16(0);
            // Entry point for the return-completion's "done is
            // false" branch: r_result is already populated and
            // done was already observed false in the return
            // handler. Don't re-read `.done` here — the iterator
            // result's `get done` accessor must run exactly once
            // per §27.6.3.7 step 7.c.ix.
            const body_after_done = self.builder.here();
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_value);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_val);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_val);
            const yield_start_pc = self.builder.here();
            try self.builder.emitOp(.gen_yield, y.span);
            const yield_end_pc = self.builder.here();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.jmp, y.span);
            const back_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.patchI16(back_patch, next_path_start);

            // ── Throw handler ──
            const throw_handler_pc = self.builder.here();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_throw);
            try self.builder.emitOp(.jmp_if_nullish, y.span);
            const no_throw_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_callee);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_arg0);
            try self.builder.emitOp(.call_method, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitU8(r_callee);
            try self.builder.emitU8(1);
            try self.builder.emitOp(.await_, y.span);
            try self.builder.emitOp(.jmp, y.span);
            const throw_to_body_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.patchI16(throw_to_body_patch, body_after_call);
            const no_throw_target = self.builder.here();
            try self.builder.patchI16(no_throw_patch, no_throw_target);
            try self.builder.emitOp(.iter_close, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitU8(0);
            try self.builder.emitOp(.lda_global, y.span);
            try self.builder.emitU16(k_type_error);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_callee);
            try self.builder.emitOp(.new_call, y.span);
            try self.builder.emitU8(r_callee);
            try self.builder.emitU8(0);
            try self.builder.emitOp(.throw_, y.span);

            // ── Return handler ──
            const return_handler_pc = self.builder.here();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_return);
            try self.builder.emitOp(.jmp_if_nullish, y.span);
            const no_return_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_callee);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_received);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_arg0);
            try self.builder.emitOp(.call_method, y.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitU8(r_callee);
            try self.builder.emitU8(1);
            try self.builder.emitOp(.await_, y.span);
            // §27.6.3.7 step 7.c.viii — after Awaiting the inner
            // `.return()` result, if its Type is not Object, throw
            // a TypeError. (The throw-handler path jumps back to
            // body_after_call which already has its own check;
            // this branch ends in `return_` so we check here.)
            try self.builder.emitOp(.throw_if_not_object, y.span);
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_done_key);
            try self.builder.emitOp(.jmp_if_false, y.span);
            const return_not_done_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_value);
            try self.builder.emitOp(.return_, y.span);
            const return_not_done_target = self.builder.here();
            try self.builder.patchI16(return_not_done_patch, return_not_done_target);
            // §27.6.3.7 step 7.c.xi — "done is false" branch: pass
            // the iter-step result to the body's value-read +
            // outer-yield, but DO NOT re-read `.done` (the
            // body_after_call entry would, breaking the test262
            // log-once invariant). Jump past the done read to
            // body_after_done.
            try self.builder.emitOp(.jmp, y.span);
            const return_to_body_patch = self.builder.here();
            try self.builder.emitI16(0);
            try self.builder.patchI16(return_to_body_patch, body_after_done);
            const no_return_target = self.builder.here();
            try self.builder.patchI16(no_return_patch, no_return_target);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_received);
            // §27.6.3.7 step 7.c.iii.1 — when the inner iterator has
            // no `return` method and generatorKind is async, the
            // received completion's value is Awaited before being
            // forwarded as the return completion. A user can call
            // `outerGen.return(promise)`; the spec unwraps that
            // Promise once so the outer .return() result is
            // `{value: resolvedV, done: true}`.
            try self.builder.emitOp(.await_, y.span);
            try self.builder.emitOp(.return_, y.span);

            // ── Exit ──
            const exit_target = self.builder.here();
            try self.builder.patchI16(exit_patch, exit_target);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, y.span);
            try self.builder.emitU16(k_value);

            try self.builder.addHandler(.{
                .start_pc = yield_start_pc,
                .end_pc = yield_end_pc,
                .handler_pc = throw_handler_pc,
                .catch_register = null,
                .is_finally = false,
            });
            try self.builder.addHandler(.{
                .start_pc = yield_start_pc,
                .end_pc = yield_end_pc,
                .handler_pc = return_handler_pc,
                .catch_register = null,
                .is_finally = true,
            });
            return;
        }

        // Sync yield* — §15.5.5 step 7. Two synthetic handlers
        // around the inner `gen_yield` make the outer generator's
        // `.throw(e)` / `.return(v)` re-enter our loop:
        //   • non-finally handler catches injected throws and
        //     forwards via `iterator.throw(e)` (or
        //     IteratorClose + TypeError if no `throw` method);
        //   • finally handler catches return-completions and
        //     forwards via `iterator.return(v)` (or propagates the
        //     return outright if no `return` method).
        // The compile-time complexity here is intentional — the
        // alternative would be a re-entrant runtime opcode that
        // resumes itself across suspensions, which doesn't fit
        // Cynic's straight-line dispatch loop.
        const k_next = try self.internString("next");
        const k_return = try self.internString("return");
        const k_throw = try self.internString("throw");
        const k_value = try self.internString("value");
        const k_done_key = try self.internString("done");
        const k_type_error = try self.internString("TypeError");

        // r_received — value to forward as the inner method arg.
        const r_received = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.lda_undefined, y.span);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_received);
        // r_result — latest `{value, done}` object.
        const r_result = try self.reserveTemp();
        defer self.releaseTemp();
        // Consecutive temps for call_method: r_recv, r_callee, r_arg0.
        const r_recv = try self.reserveTemp();
        defer self.releaseTemp();
        const r_callee = try self.reserveTemp();
        defer self.releaseTemp();
        const r_arg0 = try self.reserveTemp();
        defer self.releaseTemp();
        // §7.4.2 GetIterator step 4 — capture `[[NextMethod]]`
        // once. Re-reading `.next` each iteration would re-fire
        // a user-defined `get next()` accessor and break
        // `yield-star-sync-next.js`'s log-once invariant.
        const r_next = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_next);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_next);

        // ── Next path entry ──
        const next_path_start = self.builder.here();
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_next);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_received);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_arg0);
        try self.builder.emitOp(.call_method, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(1);
        // ── Shared body — acc holds inner result ──
        const body_after_call = self.builder.here();
        // §25.5.3.7 step 7.b.iii / 7.c.viii — `iter.next(received)` and
        // `iter.throw(received)` results must both be Objects. The
        // throw / return handlers below jump here after their calls,
        // so a single gate at `body_after_call` covers all three
        // invocations. (The return handler reads `.done` off
        // `r_result` separately and isn't routed through this label.)
        try self.builder.emitOp(.throw_if_not_object, y.span);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_done_key);
        try self.builder.emitOp(.jmp_if_true, y.span);
        const exit_patch = self.builder.here();
        try self.builder.emitI16(0);
        // §15.5.5 step 7.a.iv — `Set received to GeneratorYield(
        // innerResult)`. The inner iterator's result OBJECT is
        // surfaced verbatim out of the outer `.next()`, so we
        // (a) don't pre-read `.value` here (the spec only reads
        // it on the done-true exit branch — `value` accessors
        // on non-final results must not fire), and (b) yield via
        // `gen_yield_iter_result` to suppress the outer
        // CreateIterResultObject wrap that `gen_yield` would
        // trigger.
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        // Synthetic-handler-covered yield.
        const yield_start_pc = self.builder.here();
        try self.builder.emitOp(.gen_yield_iter_result, y.span);
        const yield_end_pc = self.builder.here();
        // Normal resume — save sent value, loop.
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_received);
        try self.builder.emitOp(.jmp, y.span);
        const back_patch = self.builder.here();
        try self.builder.emitI16(0);
        try self.builder.patchI16(back_patch, next_path_start);

        // ── Throw handler ──
        const throw_handler_pc = self.builder.here();
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_received);
        // GetMethod(r_iter, "throw").
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_throw);
        try self.builder.emitOp(.jmp_if_nullish, y.span);
        const no_throw_patch = self.builder.here();
        try self.builder.emitI16(0);
        // Have a throw method — call inner.throw(received).
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_received);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_arg0);
        try self.builder.emitOp(.call_method, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(1);
        try self.builder.emitOp(.jmp, y.span);
        const throw_to_body_patch = self.builder.here();
        try self.builder.emitI16(0);
        try self.builder.patchI16(throw_to_body_patch, body_after_call);
        // No throw — IteratorClose + throw new TypeError().
        const no_throw_target = self.builder.here();
        try self.builder.patchI16(no_throw_patch, no_throw_target);
        try self.builder.emitOp(.iter_close, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitU8(0); // mode = normal
        // `new TypeError()` — lda_global TypeError → r_callee, new_call.
        try self.builder.emitOp(.lda_global, y.span);
        try self.builder.emitU16(k_type_error);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.new_call, y.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(0);
        try self.builder.emitOp(.throw_, y.span);

        // ── Return handler ──
        const return_handler_pc = self.builder.here();
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_received);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_return);
        try self.builder.emitOp(.jmp_if_nullish, y.span);
        const no_return_patch = self.builder.here();
        try self.builder.emitI16(0);
        // Have a return method — call inner.return(received).
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_received);
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_arg0);
        try self.builder.emitOp(.call_method, y.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(1);
        // §15.5.5 step 7.c.iii — inner result must be Object.
        // Save the raw call result first so we can check it.
        try self.builder.emitOp(.star, y.span);
        try self.builder.emitU8(r_result);
        // Quick check: if it's nullish, throw TypeError. Otherwise
        // we still need a stricter "is Object" — but `lda_property`
        // on a primitive boxes; the spec wants TypeError on every
        // non-Object including booleans/strings/numbers. For now
        // accept this looser check (covers the
        // star-rhs-iter-rtrn-rtrn-call-non-obj 'return 23' shape
        // partially — 23 isn't nullish so we'd miss). Skip the
        // strict check for now; landed as a follow-up.
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_done_key);
        try self.builder.emitOp(.jmp_if_false, y.span);
        const return_not_done_patch = self.builder.here();
        try self.builder.emitI16(0);
        // Done — return result.value from the surrounding gen.
        // §15.5.5 7.c.vii.2: return-completion with value =
        // IteratorValue(innerReturnResult). A return-completion
        // here must run every active try/finally in the body
        // BEFORE settling the outer generator (§14.15) — bare
        // `return_` would pop the frame without that. Stash the
        // value, walk the finally chain, restore, return.
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_value);
        if (self.finally_chain != null) {
            const r_save = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_save);
            try self.emitFinalliesUntil(null, y.span);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_save);
        }
        try self.builder.emitOp(.return_, y.span);
        // Not done — loop back to body.
        const return_not_done_target = self.builder.here();
        try self.builder.patchI16(return_not_done_patch, return_not_done_target);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.jmp, y.span);
        const return_to_body_patch = self.builder.here();
        try self.builder.emitI16(0);
        try self.builder.patchI16(return_to_body_patch, body_after_call);
        // No return method — propagate the return completion.
        // §15.5.5 7.c.iii: `Return Completion(received)` — same
        // finally-walk requirement as the done-branch above.
        const no_return_target = self.builder.here();
        try self.builder.patchI16(no_return_patch, no_return_target);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_received);
        if (self.finally_chain != null) {
            const r_save = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, y.span);
            try self.builder.emitU8(r_save);
            try self.emitFinalliesUntil(null, y.span);
            try self.builder.emitOp(.ldar, y.span);
            try self.builder.emitU8(r_save);
        }
        try self.builder.emitOp(.return_, y.span);

        // ── Exit — `yield*` evaluates to inner's final value ──
        const exit_target = self.builder.here();
        try self.builder.patchI16(exit_patch, exit_target);
        try self.builder.emitOp(.ldar, y.span);
        try self.builder.emitU8(r_result);
        try self.builder.emitOp(.lda_property, y.span);
        try self.builder.emitU16(k_value);

        try self.builder.addHandler(.{
            .start_pc = yield_start_pc,
            .end_pc = yield_end_pc,
            .handler_pc = throw_handler_pc,
            .catch_register = null,
            .is_finally = false,
        });
        try self.builder.addHandler(.{
            .start_pc = yield_start_pc,
            .end_pc = yield_end_pc,
            .handler_pc = return_handler_pc,
            .catch_register = null,
            .is_finally = true,
        });
    }

    fn compileAwait(self: *Compiler, a: ast.expression.AwaitExpr) CompileError!void {
        try self.compileExpression(a.argument);
        try self.builder.emitOp(.await_, a.span);
        // §16.2.1.5.1 — flag any module-top-level await so the
        // module's chunk gets `is_async_module = true`. The
        // enclosing function-like scope is `.script` for module
        // top and `.function` for any nested function body; the
        // is_module guard excludes scripts (where TLA is a parse
        // error anyway).
        if (self.is_module) {
            const fn_scope = self.functionScope();
            if (fn_scope.kind == .script) {
                self.module_has_top_level_await = true;
            }
        }
    }

    /// `++x` / `--x` (prefix), `x++` / `x--` (postfix). §13.4.
    /// Lowers to `acc = ToNumber(x); x = acc ± 1; result =
    /// (prefix ? acc_new : acc_old)`. Both identifier and
    /// member-access targets are supported.
    fn compileUpdate(self: *Compiler, u: ast.expression.UpdateExpr) CompileError!void {
        // §13.4 / §13.15.3 — `(x)++` is a CoverParenthesizedExpression
        // covering an IdentifierReference. IsValidSimpleAssignmentTarget
        // sees through parentheses, so unwrap any layers before
        // dispatching to the identifier vs member path.
        var operand: *const ast.expression.Expression = u.operand;
        while (operand.* == .parenthesized) operand = operand.parenthesized.expression;
        if (operand.* == .member) {
            var unwrapped = u;
            unwrapped.operand = @constCast(operand);
            return self.compileUpdateMember(unwrapped);
        }
        if (operand.* != .identifier_reference) {
            return error.UnsupportedExpression;
        }
        const span = operand.identifier_reference.span;
        // §12.7 — resolve against the StringValue (decoded escapes).
        const name = try self.bindingName(span);
        const scope = self.scope orelse return error.UnresolvedReference;
        const binding: Binding = scope.resolve(name) orelse Binding{
            // §13.4 — an unresolved name is a *global* reference,
            // never an early error. `x++` / `++x` on an undeclared
            // `x` must compile and throw ReferenceError at runtime:
            // the `lda_global` read below performs GetValue, which
            // §6.2.5.5 makes throw on an unresolvable Reference.
            // Mirrors `compileIdentRef` / `compileAssignment`, which
            // already resolve an unknown name this way — only this
            // update path used to hard-fail at compile time.
            .name = name,
            .env_slot = 0,
            .env_depth = 0,
            .kind = .var_,
            .span = span,
            .is_global = true,
        };
        // §13.4.4 PostfixExpression / §13.4.5 UnaryExpression UPDATE
        // — no early error for `x++` / `++x` on a const binding. The
        // runtime path (PutValue → SetMutableBinding step 9.b) throws
        // TypeError. test262
        // language/statements/const/syntax/const-invalid-assignment-*
        // wrap the update in `assert.throws(TypeError, function(){})`,
        // so the surrounding function MUST compile; the body's update
        // op throws at runtime.
        if (binding.kind == .const_ and !binding.is_global and !binding.is_fn_expr_name) {
            try self.builder.emitOp(.throw_assign_const, u.span);
            return;
        }

        // Read x → acc (with TDZ check for let/const).
        try self.emitLoadBinding(binding, span);

        // §13.4.4.1 step 2.b — ToNumeric (BigInt-tolerant; the
        // `inc` / `dec` bump dispatches on Number vs BigInt).
        try self.builder.emitOp(.to_numeric, span);

        // Save the coerced original for the result-of-postfix.
        const r_orig = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_orig);

        // §13.4 bump = oldValue + Type(oldValue)::unit. Inc / Dec
        // dispatch on Number vs BigInt so the unit matches; the
        // older `lda_smi 1; add r` shape mixed BigInt + Number
        // and rejected `0n++` as a TypeError.
        const op: Op = if (u.op == .increment) .inc else .dec;
        try self.builder.emitOp(op, u.span);
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
        if (m.object.* == .super_) {
            return self.compileSuperUpdate(u, m);
        }

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
                const decoded = try self.decodeIdentifierName(key_slice);
                k_const = try self.internString(decoded);
                mode = .ident;
            },
            .computed => |key_expr| {
                try self.compileExpression(key_expr);
                // §13.4 — the operand expression evaluates *once*.
                // For computed access that means ToPropertyKey fires
                // once across the read + write, not twice. Stash
                // the raw key first, then do the spec-ordered
                // RequireObjectCoercible(base) → ToPropertyKey(key)
                // sequence, mirroring what `lda_computed` does at
                // runtime so `null[obj]++` still TypeErrors before
                // `obj.toString` runs.
                r_key = try self.reserveTemp();
                try self.builder.emitOp(.star, u.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitOp(.ldar, u.span);
                try self.builder.emitU8(r_obj);
                try self.builder.emitOp(.require_object_coercible, u.span);
                try self.builder.emitOp(.ldar, u.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitOp(.to_property_key, u.span);
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
        // §13.4.4.1 step 2.b — ToNumeric (BigInt-tolerant).
        try self.builder.emitOp(.to_numeric, u.span);
        const r_orig = try self.reserveTemp();
        try self.builder.emitOp(.star, u.span);
        try self.builder.emitU8(r_orig);

        // §13.4 bump = oldValue + Type(oldValue)::unit. Inc / Dec
        // dispatch on Number vs BigInt so BigInt members
        // (`obj.x++` with `x = 0n`) don't TypeError.
        const op: Op = if (u.op == .increment) .inc else .dec;
        try self.builder.emitOp(op, u.span);

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

    /// `super.x++` / `super[expr]--` (prefix or postfix). §13.4.
    /// `super_get` / `super_get_computed` reads the current value,
    /// ToNumeric + add 1 / sub 1, then `super_set` / `super_set_computed`
    /// writes back. Identifier private keys (`super.#x`) aren't a
    /// thing — private names aren't accessible through super.
    /// For computed keys, emit `super_check_this` first so a
    /// derived ctor before `super(...)` throws ReferenceError per
    /// §13.3.7.1 step 2 before the bracket expression evaluates.
    fn compileSuperUpdate(
        self: *Compiler,
        u: ast.expression.UpdateExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        const Mode = enum { ident, computed };
        var mode: Mode = .ident;
        var k_const: u16 = 0;
        var r_key: u8 = 0;
        switch (m.property) {
            .ident => |span| {
                const raw = self.source[span.start..span.end];
                if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
                const decoded = try self.decodeIdentifierName(raw);
                k_const = try self.internString(decoded);
                mode = .ident;
            },
            .computed => |key_expr| {
                // §13.3.7.1 step 2 — uninit-`this` precedes
                // Expression evaluation.
                try self.builder.emitOp(.super_check_this, m.span);
                try self.compileExpression(key_expr);
                r_key = try self.reserveTemp();
                try self.builder.emitOp(.star, u.span);
                try self.builder.emitU8(r_key);
                mode = .computed;
            },
        }

        // Read current value via super.
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.super_get, m.span);
                try self.builder.emitU16(k_const);
            },
            .computed => {
                try self.builder.emitOp(.ldar, u.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitOp(.super_get_computed, m.span);
            },
        }
        // §13.4.4.1 step 2.b — ToNumeric (BigInt-tolerant).
        try self.builder.emitOp(.to_numeric, u.span);
        const r_orig = try self.reserveTemp();
        try self.builder.emitOp(.star, u.span);
        try self.builder.emitU8(r_orig);

        // §13.4 bump = oldValue + Type(oldValue)::unit. Inc / Dec
        // dispatch on Number vs BigInt so BigInt members
        // (`obj.x++` with `x = 0n`) don't TypeError.
        const op: Op = if (u.op == .increment) .inc else .dec;
        try self.builder.emitOp(op, u.span);

        // Store via super.<key> = bumped.
        const r_val = try self.reserveTemp();
        try self.builder.emitOp(.star, u.span);
        try self.builder.emitU8(r_val);
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.super_set, m.span);
                try self.builder.emitU16(k_const);
                try self.builder.emitU8(r_val);
            },
            .computed => {
                try self.builder.emitOp(.super_set_computed, m.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitU8(r_val);
            },
        }

        if (!u.prefix) {
            // Postfix — result is the (coerced) original.
            try self.builder.emitOp(.ldar, u.span);
            try self.builder.emitU8(r_orig);
        }
        // Prefix — acc holds the bumped value (super_set leaves
        // it there).

        self.releaseTemp(); // r_val
        self.releaseTemp(); // r_orig
        if (mode == .computed) self.releaseTemp(); // r_key
    }

    /// `super.x op= v` / `super[expr] op= v` — compound assignment.
    /// §13.15 EvaluateBinaryExpression flow: read LHS, evaluate
    /// RHS, apply the op, store back through the same access path.
    /// For computed keys, emit `super_check_this` first (§13.3.7.1
    /// step 2 — GetThisBinding precedes the bracket expression).
    fn compileSuperCompoundAssign(
        self: *Compiler,
        a: ast.expression.AssignExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        const bin_op = compoundOp(a.op) orelse return error.UnsupportedExpression;

        const Mode = enum { ident, computed };
        var mode: Mode = .ident;
        var k_const: u16 = 0;
        var r_key: u8 = 0;
        switch (m.property) {
            .ident => |span| {
                const raw = self.source[span.start..span.end];
                if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
                const decoded = try self.decodeIdentifierName(raw);
                k_const = try self.internString(decoded);
                mode = .ident;
            },
            .computed => |key_expr| {
                try self.builder.emitOp(.super_check_this, m.span);
                try self.compileExpression(key_expr);
                r_key = try self.reserveTemp();
                try self.builder.emitOp(.star, a.span);
                try self.builder.emitU8(r_key);
                mode = .computed;
            },
        }

        // Read LHS through super → acc → r_lhs.
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.super_get, m.span);
                try self.builder.emitU16(k_const);
            },
            .computed => {
                try self.builder.emitOp(.ldar, a.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitOp(.super_get_computed, m.span);
            },
        }
        const r_lhs = try self.reserveTemp();
        try self.builder.emitOp(.star, a.span);
        try self.builder.emitU8(r_lhs);

        // Evaluate RHS → acc, then `acc = r_lhs <op> acc`.
        try self.compileExpression(a.value);
        try self.builder.emitOp(bin_op, a.span);
        try self.builder.emitU8(r_lhs);

        // Store the result via super.
        const r_val = try self.reserveTemp();
        try self.builder.emitOp(.star, a.span);
        try self.builder.emitU8(r_val);
        switch (mode) {
            .ident => {
                try self.builder.emitOp(.super_set, m.span);
                try self.builder.emitU16(k_const);
                try self.builder.emitU8(r_val);
            },
            .computed => {
                try self.builder.emitOp(.super_set_computed, m.span);
                try self.builder.emitU8(r_key);
                try self.builder.emitU8(r_val);
            },
        }
        // The expression's value is the stored new value; super_set
        // leaves it in `acc`.

        self.releaseTemp(); // r_val
        self.releaseTemp(); // r_lhs
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
            // §13.2.8.6 step 7 — `Let middle be ? ToString(sub)`.
            // Template literals coerce each substitution via
            // ToString (hint "string"), NOT via the `+` operator
            // (which uses ToPrimitive hint "default"). The two
            // observably differ on Symbol wrappers: hint "string"
            // calls `toString` first and produces "Symbol()",
            // while hint "default" calls `valueOf` first and
            // surfaces a Symbol primitive that ToString then
            // rejects with TypeError (test262
            // built-ins/Symbol/prototype/Symbol.toPrimitive/
            // redefined-symbol-wrapper-ordinary-toprimitive.js,
            // /removed-symbol-wrapper-ordinary-toprimitive.js).
            try self.compileExpression(expr);
            try self.builder.emitOp(.to_string, lit.span);
            try self.builder.emitOp(.add, lit.span);
            try self.builder.emitU8(r_acc);
            try self.builder.emitOp(.star, lit.span);
            try self.builder.emitU8(r_acc);

            // Trailing quasi after this substitution — already a
            // String literal, so no coercion needed before Add.
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

        // §13.3.11.4 — when the tag is a member expression
        // (`obj.fn\`…\``), the call must bind `this = obj` per
        // §13.3.6.1 EvaluateCall (the MemberExpression form
        // produces a Reference whose [[Base]] becomes the call's
        // `this`). Emit call_method so the runtime sees the
        // receiver. Plain identifier / paren / arbitrary
        // expressions take the regular `call` path with
        // `this = undefined`.
        if (tt.tag.* == .member) {
            const m = tt.tag.member;

            // Receiver → r_recv.
            try self.compileExpression(m.object);
            if (m.optional) try self.emitOptionalShortCircuit(m.span);
            const r_recv = try self.reserveTemp();
            try self.builder.emitOp(.star, tt.span);
            try self.builder.emitU8(r_recv);

            // Property load → r_callee (adjacent to r_recv).
            switch (m.property) {
                .ident => |span| {
                    const key_slice = self.source[span.start..span.end];
                    const decoded = try self.decodeIdentifierName(key_slice);
                    const k = try self.internString(decoded);
                    try self.builder.emitOp(.ldar, tt.span);
                    try self.builder.emitU8(r_recv);
                    try self.builder.emitOp(.lda_property, tt.span);
                    try self.builder.emitU16(k);
                },
                .computed => |key_expr| {
                    try self.compileExpression(key_expr);
                    try self.builder.emitOp(.lda_computed, tt.span);
                    try self.builder.emitU8(r_recv);
                },
            }
            const r_callee = try self.reserveTemp();
            try self.builder.emitOp(.star, tt.span);
            try self.builder.emitU8(r_callee);

            // arg[0] = template strs object.
            const r_strs = try self.reserveTemp();
            try self.builder.emitOp(.lda_constant, tt.span);
            try self.builder.emitU16(k_strs);
            try self.builder.emitOp(.star, tt.span);
            try self.builder.emitU8(r_strs);

            var reserved: u8 = 1;
            for (lit.expressions) |*e| {
                try self.compileExpression(e);
                const r_arg = try self.reserveTemp();
                reserved += 1;
                try self.builder.emitOp(.star, tt.span);
                try self.builder.emitU8(r_arg);
            }

            try self.builder.emitOp(.call_method, tt.span);
            try self.builder.emitU8(r_recv);
            try self.builder.emitU8(r_callee);
            try self.builder.emitU8(@intCast(1 + lit.expressions.len));

            var k: u8 = 0;
            while (k < reserved) : (k += 1) self.releaseTemp();
            self.releaseTemp(); // r_callee
            self.releaseTemp(); // r_recv
            return;
        }

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
        // §13.2.8.4 GetTemplateObject — the resulting `template`
        // and its `.raw` companion are Array exotic objects, and
        // both are frozen via SetIntegrityLevel(O, frozen):
        // indexed elements are enumerable/non-writable/non-
        // configurable, `length` and `raw` are non-enumerable/
        // non-writable/non-configurable, and the objects
        // themselves are non-extensible. Build that shape here so
        // a tag function observing the array gets the spec-frozen
        // descriptors (test262
        // language/expressions/tagged-template/template-object*.js).
        const indexed_frozen: @import("../runtime/object.zig").PropertyFlags = .{
            .writable = false,
            .enumerable = true,
            .configurable = false,
        };
        const meta_frozen: @import("../runtime/object.zig").PropertyFlags = .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };

        // Allocate the `raw` array.
        const raw_arr = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        raw_arr.prototype = self.realm.intrinsics.array_prototype;
        raw_arr.is_array_exotic = true;
        for (lit.quasis, 0..) |q, i| {
            const raw_text = self.source[q.span.start..q.span.end];
            // §12.8.6.1 TRV — raw `<CR>` / `<CR><LF>` collapse to a
            // single `<LF>`. The `<LS>` / `<PS>` cases pass through.
            const normalized_raw = normalizeTemplateLineTerminators(self.allocator, raw_text) catch return error.OutOfMemory;
            defer self.allocator.free(normalized_raw);
            const owned = self.realm.heap.allocateString(normalized_raw) catch return error.OutOfMemory;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const idx_owned = self.realm.heap.allocateString(islice) catch return error.OutOfMemory;
            raw_arr.setWithFlags(self.allocator, idx_owned.flatBytes(), Value.fromString(owned), indexed_frozen) catch return error.OutOfMemory;
            // The frozen descriptor flags force `setWithFlags` to
            // bag-promote the indexed slot into `properties`, keyed
            // by `idx_owned`'s borrowed byte slice. Anchor the
            // JSString or a GC frees it and the key dangles —
            // `String.raw` then reads the segment back as `undefined`.
            raw_arr.key_anchors.append(self.allocator, idx_owned) catch return error.OutOfMemory;
        }
        raw_arr.setWithFlags(self.allocator, "length", Value.fromInt32(@intCast(lit.quasis.len)), meta_frozen) catch return error.OutOfMemory;
        raw_arr.extensible = false;

        // Allocate the `strs` array (cooked).
        const strs_arr = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        strs_arr.prototype = self.realm.intrinsics.array_prototype;
        strs_arr.is_array_exotic = true;
        for (lit.quasis, 0..) |q, i| {
            // §12.8.6 / §13.2.8.4 GetTemplateObject — a quasi whose
            // body holds an escape that is invalid under the strict TV
            // grammar has cooked value `undefined` (the `raw`
            // companion above still carries the source text). The
            // parser flags this per-quasi from the lexer; without the
            // flag we'd hand `decodeQuasi` an invalid escape it can't
            // decode and fail the whole compile.
            const cooked_v: Value = if (q.had_invalid_escape)
                Value.undefined_
            else blk: {
                const cooked = self.decodeQuasi(q.span) catch return error.OutOfMemory;
                defer self.allocator.free(cooked);
                const owned = self.realm.heap.allocateString(cooked) catch return error.OutOfMemory;
                break :blk Value.fromString(owned);
            };
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const idx_owned = self.realm.heap.allocateString(islice) catch return error.OutOfMemory;
            strs_arr.setWithFlags(self.allocator, idx_owned.flatBytes(), cooked_v, indexed_frozen) catch return error.OutOfMemory;
            // See the `raw_arr` companion above — the bag-promoted
            // frozen index key needs its JSString anchored.
            strs_arr.key_anchors.append(self.allocator, idx_owned) catch return error.OutOfMemory;
        }
        strs_arr.setWithFlags(self.allocator, "length", Value.fromInt32(@intCast(lit.quasis.len)), meta_frozen) catch return error.OutOfMemory;
        strs_arr.setWithFlags(self.allocator, "raw", heap_mod.taggedObject(raw_arr), meta_frozen) catch return error.OutOfMemory;
        strs_arr.extensible = false;

        return self.builder.addConstant(heap_mod.taggedObject(strs_arr));
    }

    /// Decode a template quasi's escape sequences into a fresh
    /// allocator-owned slice. §12.8.6.1 TV (Template Value) —
    /// `\xNN`, `\uNNNN`, `\u{N…}`, LineContinuation all get the
    /// same decoding as a string literal would. Falls through to
    /// the shared `decodeStringContent` helper so the lexer's
    /// view stays the single source of truth.
    ///
    /// §12.8.6.1 also requires raw `<CR>` / `<CR><LF>` in the
    /// quasi to cook to a single `<LF>` (the TV of a
    /// LineTerminatorSequence). Run that normalization first so
    /// the LineContinuation arm of `decodeStringContent` sees the
    /// canonical `\<LF>` form.
    /// Returns owned bytes — caller frees.
    fn decodeQuasi(self: *Compiler, span: Span) ![]u8 {
        const raw = self.source[span.start..span.end];
        // Common case: no escapes and no `<CR>` → just dup the slice.
        const has_escape = std.mem.indexOfScalar(u8, raw, '\\') != null;
        const has_cr = std.mem.indexOfScalar(u8, raw, '\r') != null;
        if (!has_escape and !has_cr) {
            return self.allocator.dupe(u8, raw);
        }
        if (!has_escape) {
            return normalizeTemplateLineTerminators(self.allocator, raw);
        }
        if (!has_cr) {
            return decodeStringContent(self.allocator, raw);
        }
        const normalized = try normalizeTemplateLineTerminators(self.allocator, raw);
        defer self.allocator.free(normalized);
        return decodeStringContent(self.allocator, normalized);
    }

    /// Emit `LdaConstant` for the *raw* quasi text — preserves
    /// backslash escape sequences verbatim. Used for the `raw`
    /// companion array of a tagged template. Per §12.8.6.1 TRV,
    /// raw `<CR>` / `<CR><LF>` still collapse to a single `<LF>`
    /// (TRV(LineTerminatorSequence :: <CR>) = 0x000A; TRV(:: <CR>
    /// <LF>) = 0x000A).
    fn compileTemplateQuasiRaw(self: *Compiler, span: Span) CompileError!void {
        const raw = self.source[span.start..span.end];
        const normalized = normalizeTemplateLineTerminators(self.allocator, raw) catch return error.OutOfMemory;
        defer self.allocator.free(normalized);
        const s = self.realm.heap.allocateString(normalized) catch return error.OutOfMemory;
        const k = try self.builder.addConstant(Value.fromString(s));
        try self.builder.emitOp(.lda_constant, span);
        try self.builder.emitU16(k);
    }

    /// Emit `LdaConstant` for a template-literal quasi. The span
    /// covers raw text without surrounding markers (`` ` ``,
    /// `${`, `}`); reuse the standard escape-decoder so `\n`
    /// etc. behave like in a regular string literal. Per §12.8.6.1
    /// raw `<CR>` / `<CR><LF>` collapse to a single `<LF>` in TV;
    /// run that normalization before escape decoding.
    fn compileTemplateQuasi(self: *Compiler, span: Span) CompileError!void {
        const raw = self.source[span.start..span.end];
        const normalized = normalizeTemplateLineTerminators(self.allocator, raw) catch return error.OutOfMemory;
        defer self.allocator.free(normalized);
        const decoded = decodeStringContent(self.allocator, normalized) catch return error.UnsupportedExpression;
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
                    // §13.2.4.1 ArrayAccumulation — element init is
                    // CreateDataPropertyOrThrow, NOT [[Set]]. An
                    // inherited accessor on `Array.prototype.<idx>`
                    // must not fire.
                    try self.builder.emitOp(.def_property, lit.span);
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
                        // r_arr[r_idx] = r_val — §13.2.4.1 element
                        // init is CreateDataPropertyOrThrow (own data
                        // slot), not [[Set]] with proto walk.
                        try self.builder.emitOp(.ldar, lit.span);
                        try self.builder.emitU8(r_val);
                        try self.builder.emitOp(.def_computed, lit.span);
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
                    // §13.2.5.5 step 4.a — ToPropertyKey runs
                    // BEFORE the value expression, so a user-
                    // defined `toString` / `[@@toPrimitive]` on
                    // the key sees pre-value-evaluation state.
                    try self.builder.emitOp(.to_property_key, p.span);
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
                    // §13.2.5.5 step 8.e — PropertyDefinitionEvaluation
                    // for a property assignment is CreateDataPropertyOrThrow,
                    // NOT [[Set]]. Inherited accessors on
                    // `Object.prototype.<k>` must not fire.
                    try self.builder.emitOp(.def_computed, p.span);
                    try self.builder.emitU8(r_obj);
                    try self.builder.emitU8(r_key);
                    continue;
                }
                // §13.2.5.5 PropertyDefinitionEvaluation —
                // `{0: x}` / `{"a\tb": x}` evaluates the literal
                // and ToPropertyKey-coerces; ESCAPES in string
                // keys are decoded, and numeric keys take their
                // §6.1.6.1.13 Number::toString canonical form
                // (e.g. `0x10` → `"16"`, `1e3` → `"1000"`).
                const key_slice = if (p.key == .private)
                    return error.UnsupportedExpression
                else
                    try self.decodePropertyKeyName(p.key);
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
                // §13.2.5.5 step 8.e — CreateDataPropertyOrThrow,
                // NOT [[Set]]; an inherited accessor on
                // `Object.prototype.<k>` must not fire.
                try self.builder.emitOp(.def_property, p.span);
                try self.builder.emitU16(k);
                try self.builder.emitU8(r_obj);
            },
            .method => |m| {
                // Computed-key method / accessor — evaluate the key,
                // park it in a temp, compile the body, then dispatch:
                //   .method  → `sta_computed`
                //   .getter  → `def_computed_accessor` (is_setter=0)
                //   .setter  → `def_computed_accessor` (is_setter=1)
                // §13.2.5.5 PropertyDefinitionEvaluation, with the
                // ComputedPropertyName subforms.
                if (m.key == .computed) {
                    try self.compileExpression(m.key.computed);
                    // §13.2.5.5 step 4.a — the computed-method form
                    // runs ToPropertyKey on the key expression
                    // before the body is built. Without this an
                    // object-typed key (e.g. a function used as
                    // `{[fn](){…}}`) lands under the literal
                    // "[object]" placeholder; methods of plain
                    // properties already emit this opcode.
                    try self.builder.emitOp(.to_property_key, m.span);
                    const r_key = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, m.span);
                    try self.builder.emitU8(r_key);
                    // §10.2.5 — propagate is_generator / is_async
                    // so `{ *gen() {} }` / `{ async fn() {} }`
                    // produce the correct JSFunction shape.
                    const tk = try compileFunctionTemplateExt(
                        self,
                        m.params,
                        FunctionBody{ .block = m.body.body },
                        null,
                        false,
                        m.is_generator,
                        m.is_async,
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
                            // §13.2.5.5 method definition is also
                            // CreateDataPropertyOrThrow.
                            try self.builder.emitOp(.def_computed, m.span);
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
                const key_slice = if (m.key == .private)
                    return error.UnsupportedExpression
                else
                    try self.decodePropertyKeyName(m.key);
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
                // §15.4 / §15.5 — propagate is_generator / is_async
                // so `{ *gen() {} }` / `{ async fn() {} }` produce
                // the right JSFunction shape (returns a generator
                // wrapper / returns a Promise respectively).
                const tk = try compileFunctionTemplateExt(
                    self,
                    m.params,
                    FunctionBody{ .block = m.body.body },
                    fn_name,
                    false,
                    m.is_generator,
                    m.is_async,
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
                        // §13.2.5.5 method definition is also
                        // CreateDataPropertyOrThrow.
                        try self.builder.emitOp(.def_property, m.span);
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
    /// Decode a string-literal property-key span (`"…"` or `'…'`).
    /// Strips the surrounding quotes and runs §12.8.4 escape decoding
    /// so `"a\tb"` produces the key `"a\tb"` (tab char), not the
    /// six-byte source slice. Returned slice lives in the realm's
    /// class arena when escapes are present; otherwise it points
    /// back into `self.source`.
    fn decodeStringKey(self: *Compiler, key_span_slice: []const u8) CompileError![]const u8 {
        if (key_span_slice.len < 2) return error.UnsupportedExpression;
        const inner = key_span_slice[1 .. key_span_slice.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
        const arena = self.realm.classAllocator();
        return decodeStringContent(arena, inner) catch return error.UnsupportedExpression;
    }

    /// §6.1.6.1.13 Number::toString applied to a NumericLiteral's
    /// source spelling. `class C { get 0x10() {} }` exposes the
    /// property under the canonical decimal form `"16"`, not the
    /// raw `"0x10"` source span. Mirrors the formatting in
    /// `intrinsics.stringifyArg`'s double / int32 path.
    fn canonicalNumericKey(self: *Compiler, src_slice: []const u8) CompileError![]const u8 {
        const arena = self.realm.classAllocator();
        // BigInt literal — strip trailing `n`, parse the
        // arbitrary-precision magnitude, and render as decimal.
        if (src_slice.len > 0 and src_slice[src_slice.len - 1] == 'n') {
            const bigint_mod = @import("../runtime/bigint.zig");
            const v = bigint_mod.parseLiteralToValue(arena, src_slice[0 .. src_slice.len - 1]) catch return error.UnsupportedExpression;
            const tmp = bigint_mod.JSBigInt.initFromLimbs(arena, v.sign, v.limbs) catch return error.OutOfMemory;
            return bigint_mod.toStringAlloc(arena, tmp, 10) catch return error.OutOfMemory;
        }
        const d = parseNumericLiteral(src_slice) catch return error.UnsupportedExpression;
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        if (d == 0) return "0";
        // Integer fast-path — avoid the `1.0` formatting Zig
        // would otherwise give us for `1` typed as f64.
        if (asExactSmi(d)) |smi| {
            return std.fmt.allocPrint(arena, "{d}", .{smi}) catch return error.OutOfMemory;
        }
        const a = @abs(d);
        if (a != 0 and (a < 1e-6 or a >= 1e21)) {
            var buf: [64]u8 = undefined;
            const raw = std.fmt.bufPrint(&buf, "{e}", .{d}) catch return error.UnsupportedExpression;
            const normalized = @import("../runtime/intrinsics.zig").normalizeExponentPub(&buf, raw);
            return arena.dupe(u8, normalized) catch return error.OutOfMemory;
        }
        return std.fmt.allocPrint(arena, "{d}", .{d}) catch return error.OutOfMemory;
    }

    /// Resolve a PropertyKey to its runtime string form. Handles
    /// identifiers (with `\uXXXX` decoding), string literals
    /// (quote-strip + §12.8.4 escape decode), and numeric literals
    /// (§6.1.6.1.13 Number::toString canonicalization, so
    /// `class C { get 0x10() {} }` lives at `"16"`).
    fn decodePropertyKeyName(self: *Compiler, key: ast.expression.PropertyKey) CompileError![]const u8 {
        return switch (key) {
            .ident => |span| try self.decodeIdentifierName(self.source[span.start..span.end]),
            .string => |span| try self.decodeStringKey(self.source[span.start..span.end]),
            .numeric => |span| try self.canonicalNumericKey(self.source[span.start..span.end]),
            else => error.UnsupportedExpression,
        };
    }

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

    /// §12.7 IdentifierName — the StringValue of an IdentifierName
    /// is the decoded code-point sequence, NOT the raw source.
    /// `var \u{61} = 1` declares a binding named `"a"`, and `a`
    /// resolves to it. Callers that read an identifier span as the
    /// name of a binding (declaration, reference, assignment) MUST
    /// route through here so the escape-disguised form and the
    /// canonical form hash to the same key. Fast path returns the
    /// borrowed source slice when no escapes are present.
    fn bindingName(self: *Compiler, span: Span) CompileError![]const u8 {
        return self.decodeIdentifierName(self.source[span.start..span.end]);
    }

    fn compileMember(self: *Compiler, m: ast.expression.MemberExpr) CompileError!void {
        // `super.x` and `super[expr]` — `super_get` for ident keys,
        // `super_get_computed` (key in acc) for the bracket form.
        if (m.object.* == .super_) {
            switch (m.property) {
                .ident => |span| {
                    const raw = self.source[span.start..span.end];
                    const key_slice = try self.decodeIdentifierName(raw);
                    const k = try self.internString(key_slice);
                    try self.builder.emitOp(.super_get, m.span);
                    try self.builder.emitU16(k);
                    return;
                },
                .computed => |key_expr| {
                    // §13.3.7.1 SuperProperty evaluation — step 2
                    // (GetThisBinding) runs before Expression
                    // evaluation. Emit the precondition guard so
                    // a derived ctor before super() throws
                    // ReferenceError without evaluating the key.
                    try self.builder.emitOp(.super_check_this, m.span);
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
                    // §15.7.14 step 11 — lexical lookup; §12.7.1 decode escapes.
                    const decoded = try self.decodeIdentifierName(raw_slice[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
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

    /// §15.7.14 step 11 PrivateBoundIdentifiers — resolve `#name`
    /// (decoded) to the `private_prefix` of the innermost enclosing
    /// class that declares it. Falls back to the innermost class's
    /// prefix when nothing matches, so the bytecode still emits
    /// and the runtime brand check raises the TypeError the spec
    /// mandates.
    fn manglePrivateRef(self: *Compiler, decoded_name: []const u8) CompileError![]const u8 {
        std.debug.assert(self.class_stack.items.len > 0);
        const arena = self.realm.classAllocator();
        var prefix: []const u8 = self.class_stack.items[self.class_stack.items.len - 1].private_prefix;
        var i = self.class_stack.items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &self.class_stack.items[i];
            for (ctx.private_names) |n| {
                if (std.mem.eql(u8, n, decoded_name)) {
                    prefix = ctx.private_prefix;
                    i = 0; // break outer
                    break;
                }
            }
            if (i == 0) break;
        }
        return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, decoded_name }) catch return error.OutOfMemory;
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
        // v`, `super[expr]++`) route through
        // `compileSuperCompoundAssign` / `compileSuperUpdate` —
        // they share the lda / sta dispatch but interleave the
        // ToNumeric coercion and the binary op per §13.15 /
        // §13.4.
        if (m.object.* == .super_) {
            if (a.op != .eq) {
                return self.compileSuperCompoundAssign(a, m);
            }
            // §13.15.2 AssignmentExpression evaluation: evaluate the
            // LeftHandSideExpression FIRST, then the AssignmentExpression
            // (right-hand side). For `super[prop()] = expr()`, the LHS
            // evaluation runs §13.3.7.1 SuperProperty steps 1-5 — which
            // includes ToPropertyKey on the bracket key. So an abrupt
            // completion from `prop()` (or its ToPropertyKey coercion)
            // must short-circuit before `expr()` ever evaluates.
            //
            // For `super.ident = v` there's no observable LHS side
            // effect to order against, but the §13.3.7.1 step 2
            // GetThisBinding guard still has to fire before the RHS.
            //
            // Emit order:
            //   1. super_check_this  (§13.3.7.1 step 2)
            //   2. evaluate computed key, stash in r_key
            //   3. evaluate RHS, stash in r_val
            //   4. super_set / super_set_computed
            //
            // See test262 language/expressions/assignment/
            //   target-super-{computed-reference,identifier-reference-null}.js
            if (m.property == .computed) {
                try self.builder.emitOp(.super_check_this, m.span);
            }
            switch (m.property) {
                .ident => |span| {
                    const raw = self.source[span.start..span.end];
                    if (raw.len > 0 and raw[0] == '#') return error.UnsupportedExpression;
                    const k = try self.internString(try self.decodeIdentifierName(raw));
                    try self.compileExpression(a.value);
                    const r_val = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, a.span);
                    try self.builder.emitU8(r_val);
                    try self.builder.emitOp(.super_set, m.span);
                    try self.builder.emitU16(k);
                    try self.builder.emitU8(r_val);
                },
                .computed => |key_expr| {
                    // §13.3.2.1 EvaluatePropertyAccessWithExpressionKey
                    // steps 3-4 — evaluate the key expression and
                    // GetValue it BEFORE the RHS, but DO NOT
                    // ToPropertyKey here. §10.1.9.1 Set / §6.2.5.5
                    // PutValue defers the ToPropertyKey-equivalent
                    // until after RHS evaluation, so a `prop` whose
                    // `toString` throws still lets the RHS evaluate
                    // first and surface ITS abrupt instead. A throw
                    // from the key Expression itself (e.g. `prop()`)
                    // still short-circuits before the RHS, which is
                    // what the first half of test262
                    // language/expressions/assignment/
                    // target-super-computed-reference.js exercises.
                    try self.compileExpression(key_expr);
                    const r_key = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, a.span);
                    try self.builder.emitU8(r_key);
                    try self.compileExpression(a.value);
                    const r_val = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.star, a.span);
                    try self.builder.emitU8(r_val);
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
                    // §15.7.14 step 11 — lexical lookup; §12.7.1 decode escapes.
                    const decoded = try self.decodeIdentifierName(raw_slice[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
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
                // §13.15.2 + §13.3.4.1 — for a compound / logical
                // assignment (`obj[k] op= v`) the spec evaluates
                // the LHS reference (RequireObjectCoercible(base)
                // at step 5, ToPropertyKey(key) at step 6) BEFORE
                // the RHS, and the resulting Reference is used
                // once for both GetValue and PutValue. Cynic
                // lowers compound forms to `lda_computed` +
                // `<op>` + `sta_computed`; both ops independently
                // run ToPropertyKey on the cached key, which fires
                // user-defined `toString` / `[@@toPrimitive]`
                // hooks twice. Coerce now so the cached key is a
                // String/Symbol/BigInt — the runtime ToPropertyKey
                // is then a no-op on subsequent uses. Order
                // matters: RequireObjectCoercible(base) MUST fire
                // before ToPropertyKey(key) so that `null[obj] *=
                // …` throws TypeError without consulting `obj`.
                // Plain `=` is left alone: it only runs
                // `sta_computed` once, so a single ToPropertyKey
                // at the store site already matches the visible
                // side-effect count.
                if (a.op != .eq) {
                    try self.builder.emitOp(.ldar, m.span);
                    try self.builder.emitU8(r_obj);
                    try self.builder.emitOp(.require_object_coercible, m.span);
                    try self.builder.emitOp(.ldar, key_expr.span());
                    try self.builder.emitU8(r_key);
                    try self.builder.emitOp(.to_property_key, key_expr.span());
                    try self.builder.emitOp(.star, key_expr.span());
                    try self.builder.emitU8(r_key);
                }
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
                    // Mirror `emitClassBuild` anonymous branch: the
                    // class body may have `[expr]` computed keys
                    // whose evaluations must run in the enclosing
                    // frame (so `yield` / `await` work). Route
                    // through `emitMakeClass` rather than directly
                    // emitting the opcode — without this the
                    // bytecode would skip the inline key block and
                    // `make_class`'s `r_keys_base` operand would
                    // alias the next opcode byte.
                    const k = try compileClassTemplate(
                        self,
                        name,
                        ce.superclass,
                        ce.body,
                        ce.span,
                    );
                    // Anonymous class expression — no inner env, no
                    // binding to publish (sentinel 0xFF).
                    const reserved = try self.emitMakeClass(k, ce.superclass, ce.body, ce.span, 0xFF);
                    self.releaseMakeClassTemps(reserved);
                    // §15.7.14 step 16 — pop the class_stack frame
                    // left live by `compileClassTemplate` so the
                    // computed-key walk inside `emitMakeClass` could
                    // resolve this class's `#name` references.
                    _ = self.class_stack.pop();
                    return;
                }
            },
            else => {},
        }
        try self.compileExpression(expr);
    }

    fn compileFunctionExpr(self: *Compiler, fe: ast.expression.FunctionExpr) CompileError!void {
        // §12.7 — bind the inner name (recursion target) by StringValue.
        const name_slice = if (fe.name) |n| try self.bindingName(n.span) else null;
        // §15.6.5 InstantiateOrdinaryFunctionExpression — for a NAMED
        // function expression (incl. generator / async / async-gen
        // variants) the BindingIdentifier is exposed inside the body
        // as an immutable self-binding. The spec carves out a
        // 1-binding declarative env that wraps the function's outer
        // env; the function captures the wrapper, the binding is
        // initialised to the function itself. We model it in two
        // parts: at compile time `compileFunctionTemplateExtNamed`
        // splices a synthetic 1-binding scope above the body (so
        // inner references resolve to depth=1 / slot=0, with
        // `is_fn_expr_name=true` so writes lower to
        // `throw_assign_const` — TypeError per §8.1.1.1.4 step 9.b);
        // at runtime `make_named_function_expr` materialises the
        // wrapper env and seeds slot 0 with the function.
        //
        // §15.2 FunctionExpression — also propagates is_generator /
        // is_async into the template so the resulting JSFunction
        // gets the right `is_generator` / `is_async` flag and the
        // proto/length wiring in `make_function`.
        const k = try compileFunctionTemplateExtNamed(
            self,
            fe.params,
            FunctionBody{ .block = fe.body.body },
            name_slice,
            false,
            fe.is_generator,
            fe.is_async,
            fe.span,
            name_slice != null,
        );
        if (name_slice != null) {
            try self.builder.emitOp(.make_named_function_expr, fe.span);
        } else {
            try self.builder.emitOp(.make_function, fe.span);
        }
        try self.builder.emitU16(k);
    }

    fn compileArrowFunction(self: *Compiler, af: ast.expression.ArrowFunction) CompileError!void {
        const body: FunctionBody = switch (af.body) {
            .block => |b| .{ .block = b.body },
            .expression => |e| .{ .expression = e },
        };
        // §15.8 AsyncArrowFunction — must thread `is_async` into the
        // template so the resulting JSFunction's call dispatch goes
        // through AsyncFunctionStart and returns a Promise. The
        // shorthand `compileFunctionTemplate` hardcodes `is_async=false`
        // and silently downgrades `async () => x` to a sync arrow.
        const k = try compileFunctionTemplateExt(
            self,
            af.params,
            body,
            null,
            true,
            false,
            af.is_async,
            af.span,
        );
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

        // §13.2 ParenthesizedExpression is transparent — `(a.b)()`
        // is a method call on `a.b` and must preserve `this = a`
        // (§13.3.6.2 EvaluateCall uses the inner Reference's [[Base]]
        // when the call's expression evaluates to a Reference Record).
        // Peel `(…)` wrappers from the callee so a parenthesised
        // member expression still routes through `compileMethodCall`.
        // For `(a?.b)()` the parens wrap a `chain` that wraps the
        // optional member; peel both, and if the inner is a member,
        // set up a short-circuit context so `m.optional` still emits
        // its jump-on-nullish landing — preserving `this = a` when
        // `a` is non-nullish, and yielding `undefined` (call skipped)
        // when it is.
        var callee_peel = c.callee;
        while (callee_peel.* == .parenthesized) callee_peel = callee_peel.parenthesized.expression;
        var chained_member = false;
        if (callee_peel.* == .chain) {
            const inner_chain = callee_peel.chain.expression;
            var inner_peel = inner_chain;
            while (inner_peel.* == .parenthesized) inner_peel = inner_peel.parenthesized.expression;
            if (inner_peel.* == .member) {
                callee_peel = inner_peel;
                chained_member = true;
            }
        }
        // Set up a fresh chain-patches context for the
        // chained-member case so the inner optional `?.` short-
        // circuit (emitted inside `compileMethodCall`) jumps to
        // *our* undefined landing, not into a stale outer chain.
        var local_patches: std.ArrayListUnmanaged(u32) = .empty;
        defer local_patches.deinit(self.allocator);
        var prev_chain_patches: ?*std.ArrayListUnmanaged(u32) = null;
        if (chained_member) {
            prev_chain_patches = self.chain_patches;
            self.chain_patches = &local_patches;
        }
        // `super.method(...)` — read super property then call
        // with `this` = current `this` (NOT the home object).
        if (callee_peel.* == .member) {
            const m = callee_peel.member;
            if (m.object.* == .super_) {
                return self.compileSuperMethodCall(c, m);
            }
            // `obj.method(...spread)` — spread in args needs the
            // apply-style lowering, but with `this = obj`. Route
            // through `compileSpreadMethodCall` instead of the
            // generic spread path (which uses `this = undefined`).
            var has_spread_arg = false;
            for (c.arguments) |*arg| {
                if (arg.* == .spread) {
                    has_spread_arg = true;
                    break;
                }
            }
            // `a?.b(args)` — the `?.` is on the MEMBER (not the
            // call). When `a` is nullish the entire chain
            // shorts to undefined. Otherwise it's a regular
            // method call with `this = a`. The previous path
            // fell through to the plain-call branch which lost
            // the `this` binding (`a?.b()` called with
            // `this = undefined`). Route through
            // `compileMethodCall` for both optional and
            // non-optional member callees; the inner method
            // emits the short-circuit when the member is
            // optional.
            if (!has_spread_arg) {
                try self.compileMethodCall(c, m);
                if (chained_member) {
                    // Close the local chain context: jmp past the
                    // undefined-loader to the join, patch each
                    // recorded short-circuit to land there.
                    try self.builder.emitOp(.jmp, c.span);
                    const skip_patch = self.builder.here();
                    try self.builder.emitI16(0);
                    const und_target = self.builder.here();
                    try self.builder.emitOp(.lda_undefined, c.span);
                    const join = self.builder.here();
                    try self.builder.patchI16(skip_patch, join);
                    for (local_patches.items) |patch| {
                        try self.builder.patchI16(patch, und_target);
                    }
                    self.chain_patches = prev_chain_patches;
                }
                return;
            }
            // Spread + optional member is fine — `compileSpreadMethodCall`
            // doesn't yet special-case the optional flag, but
            // the common case (non-optional) is the win.
            if (chained_member) self.chain_patches = prev_chain_patches;
            return self.compileSpreadMethodCall(c, m);
        }
        if (chained_member) self.chain_patches = prev_chain_patches;

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
    /// `CallMethod` so the runtime binds `this = obj`. Handles
    /// both unconditional `obj.method(args)` and the optional
    /// forms `obj?.method(args)` (the `?.` short-circuits on
    /// nullish receiver) and `obj.method?.(args)` (the `?.()`
    /// short-circuits on nullish method).
    fn compileMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // Receiver into r_recv. `m.optional` flag (`a?.b`)
        // short-circuits to undefined when `a` is null/undefined.
        try self.compileExpression(m.object);
        if (m.optional) try self.emitOptionalShortCircuit(m.span);
        const r_recv = try self.reserveTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_recv);

        // Property load → acc, save in r_callee adjacent to r_recv.
        switch (m.property) {
            .ident => |span| {
                const key_slice = self.source[span.start..span.end];
                if (key_slice.len > 0 and key_slice[0] == '#') {
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    // §15.7.14 step 11 — lexical lookup; §12.7.1 decode escapes.
                    const decoded = try self.decodeIdentifierName(key_slice[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
                    const k = try self.internString(mangled);
                    try self.builder.emitOp(.ldar, c.span);
                    try self.builder.emitU8(r_recv);
                    try self.builder.emitOp(.lda_private, c.span);
                    try self.builder.emitU16(k);
                } else {
                    // §12.7.1 — `\uXXXX` escapes in IdentifierName
                    // decode to the source character, so `obj.\u{6F}()`
                    // is `obj.o()`.
                    const decoded = try self.decodeIdentifierName(key_slice);
                    const k = try self.internString(decoded);
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
    /// `obj.method(...spread)` — receiver lookup once + build args
    /// array + `.apply(obj, args)`. Same shape as `compileSpreadCall`
    /// but routes `this` to the receiver instead of `undefined`.
    fn compileSpreadMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // 1. Evaluate `obj` once into r_recv. Used as the `this`
        //    binding AND as the base for the method lookup.
        try self.compileExpression(m.object);
        const r_recv = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_recv);

        // 2. Look up the method on `obj` → r_callee.
        switch (m.property) {
            .ident => |span| {
                const key_slice = self.source[span.start..span.end];
                if (key_slice.len > 0 and key_slice[0] == '#') {
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    // §15.7.14 step 11 — lexical lookup; §12.7.1 decode escapes.
                    const decoded = try self.decodeIdentifierName(key_slice[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
                    const k = try self.internString(mangled);
                    try self.builder.emitOp(.ldar, c.span);
                    try self.builder.emitU8(r_recv);
                    try self.builder.emitOp(.lda_private, c.span);
                    try self.builder.emitU16(k);
                } else {
                    // §12.7.1 — decode `\uXXXX` in IdentifierName.
                    const decoded = try self.decodeIdentifierName(key_slice);
                    const k = try self.internString(decoded);
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
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // 3. Build args array using the same shape as
        //    compileSpreadCall.
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
                self.releaseTemp();
                self.releaseTemp();
            }
        }

        // 4. Look up `.apply` on the callee → r_apply, then call
        //    apply with `(r_recv, r_args)`.
        const k_apply = try self.internString("apply");
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.lda_property, c.span);
        try self.builder.emitU16(k_apply);
        const r_apply = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_apply);

        // 5. Stage args at r_apply + 1, r_apply + 2.
        const r_this = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_recv);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_this);
        const r_args_pos = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_args);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_args_pos);

        try self.builder.emitOp(.call_method, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(r_apply);
        try self.builder.emitU8(2);
    }

    fn compileSuperMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // §13.3.7.1 SuperProperty call — receiver is current `this`,
        // callee is the method walked off `home_object`'s [[Prototype]].
        // Spread args route to apply-style lowering (§7.3.18 Invoke
        // via Function.prototype.apply) with `this = current 'this'`.
        var has_spread = false;
        for (c.arguments) |*arg| {
            if (arg.* == .spread) {
                has_spread = true;
                break;
            }
        }
        if (has_spread) return self.compileSuperSpreadMethodCall(c, m);

        // Eval super.method via super_get / super_get_computed → r_callee.
        switch (m.property) {
            .ident => |span| {
                const raw = self.source[span.start..span.end];
                const key_slice = try self.decodeIdentifierName(raw);
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

    /// `super.method(...args)` / `super[expr](a, ...rest)` — apply-style
    /// lowering of a super-method call with spread args. Builds an args
    /// array, looks up `.apply` on the resolved super method, then
    /// invokes with `this = current 'this'` (§13.3.7.1 step 5 — the
    /// thisValue of the SuperProperty call is the running execution
    /// context's GetThisBinding(), NOT the home object). Mirrors
    /// `compileSpreadMethodCall`'s shape for the receiver case.
    fn compileSuperSpreadMethodCall(
        self: *Compiler,
        c: ast.expression.CallExpr,
        m: ast.expression.MemberExpr,
    ) CompileError!void {
        // 1. Resolve the super method → r_callee.
        switch (m.property) {
            .ident => |span| {
                const raw = self.source[span.start..span.end];
                const key_slice = try self.decodeIdentifierName(raw);
                const k = try self.internString(key_slice);
                try self.builder.emitOp(.super_get, m.span);
                try self.builder.emitU16(k);
            },
            .computed => |key_expr| {
                try self.builder.emitOp(.super_check_this, m.span);
                try self.compileExpression(key_expr);
                try self.builder.emitOp(.super_get_computed, m.span);
            },
        }
        const r_callee = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_callee);

        // 2. Build the args array (same shape as compileSpreadCall).
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
                self.releaseTemp();
                self.releaseTemp();
            }
        }

        // 3. Look up `.apply` on the method → r_apply.
        const k_apply = try self.internString("apply");
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.lda_property, c.span);
        try self.builder.emitU16(k_apply);
        const r_apply = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_apply);

        // 4. Stage `this = current this` and `args` at r_apply + 1, +2.
        const r_this = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.lda_this, c.span);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_this);
        const r_args_pos = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.ldar, c.span);
        try self.builder.emitU8(r_args);
        try self.builder.emitOp(.star, c.span);
        try self.builder.emitU8(r_args_pos);

        try self.builder.emitOp(.call_method, c.span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(r_apply);
        try self.builder.emitU8(2);
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
        // §12.7 — IdentifierReference resolves against the
        // StringValue (decoded `\u…` escapes), not the raw source.
        const name = try self.bindingName(span);
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
        const lhs_parenthesised = a.target.* == .parenthesized;
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
        // §12.7 — assignment target resolves against StringValue.
        const name = try self.bindingName(target_ptr.identifier_reference.span);
        const scope = self.scope orelse return error.UnresolvedReference;
        const resolved = scope.resolve(name);
        const binding: Binding = resolved orelse Binding{
            // Not in any user-visible scope. The assignment is a
            // write against the global object, which Cynic models
            // as `realm.globals`. Cynic is strict-only, so
            // §13.15.2 → §6.2.5.5 step 6 requires throwing
            // ReferenceError when the Reference is unresolvable
            // at PutValue time. The §13.15.2 evaluation order
            // captures the LHS Reference *before* the RHS runs,
            // so we emit an `assert_global_defined` ahead of the
            // RHS (see below) — a side-effecting RHS (e.g.
            // `this.x = 1` populating the binding mid-expression)
            // must not mask the unresolvable Reference.
            .name = name,
            .env_slot = 0,
            .env_depth = 0,
            .kind = .var_,
            .span = a.target.span(),
            .is_global = true,
        };
        // §13.15.2 — assignment to a `const` binding is a runtime
        // TypeError per spec, but Cynic upgrades it to a compile-
        // time SyntaxError for local lex bindings (where the
        // binding's identity is statically known and unambiguous).
        // Global lex bindings stay runtime-checked: per §9.1.1.4
        // SetMutableBinding the type / immutability test lives at
        // `sta_global` time, which lets fixtures wrap the throw
        // in `assert.throws(TypeError, () => { c = 1; })` without
        // the script's outer compile imploding. Named function-
        // expression self-bindings (§15.6.5) also defer to runtime
        // via `throw_assign_const`. Cross-function captures (the
        // binding lives in an outer function-like scope, e.g. a
        // module-top `const` written from inside a nested function)
        // also defer to runtime: the assignment only executes when
        // the inner function runs, so the spec's runtime TypeError
        // is the right shape and lets `assert.throws(TypeError, ()
        // => { c = 1; })` round-trip — matches V8 / JSC / SM.
        const cross_fn_capture = binding.env_depth < self.env_depth;
        if (binding.kind == .const_ and !binding.is_import and !binding.is_global and !binding.is_fn_expr_name and !cross_fn_capture) {
            try self.report(.assignment_to_const, a.span);
            return error.AssignmentToConst;
        }
        // Import bindings carry kind=.const_ for shape reasons,
        // but per §8.1.1.5.5 the early-error is supposed to be
        // SyntaxError, not a `const` reassignment. Real engines
        // (V8 / JSC) surface the error as a *runtime* TypeError
        // via SetMutableBinding so user code can `assert.throws
        // (TypeError, () => { imported = 0; })`. `emitStoreBinding`
        // emits `throw_assign_const` for the import case.

        // §13.15.2 step 1.a — for a plain `Identifier = expr`
        // assignment whose LHS doesn't resolve in any user-
        // visible scope, snapshot the unresolvable-Reference
        // state *before* the RHS runs. The flag lives in a
        // reserved register and is consumed by
        // `sta_global_strict` after the RHS settles, so a
        // side-effecting RHS that itself throws (e.g.
        // `s = (new Number("a")).toFixed(Infinity)` → RangeError)
        // wins over the ReferenceError that PutValue would
        // otherwise raise. Compound (`x += e`) and logical
        // (`x ||= e`) forms read the LHS via `lda_global`
        // first, which already throws on miss, so they don't
        // need the snapshot. Bindings resolved at compile time
        // live on env slots or pre-hoisted globals — also no
        // snapshot needed.
        const r_unresolved_flag: ?u8 = if (resolved == null and a.op == .eq) blk: {
            const r = try self.reserveTemp();
            const k = try self.internString(name);
            try self.builder.emitOp(.capture_unresolved_global, a.target.span());
            try self.builder.emitU16(k);
            try self.builder.emitU8(r);
            break :blk r;
        } else null;
        defer if (r_unresolved_flag != null) self.releaseTemp();

        if (a.op == .eq) {
            // §13.15.2 — for plain `x = e` where `e` is an
            // anonymous function-like, the binding identifier
            // becomes the function's `.name`. Note §13.15.2 step
            // 1.c gates this on `IsIdentifierRef(LeftHandSide
            // Expression) is true` — and per §13.2.8 the cover
            // grammar's `IsIdentifierRef` returns *false* for
            // `(x)`, so `(fn) = function() {}` must leave the
            // function's `.name` as `""`. Use the unwrapped name
            // only when the original LHS wasn't wrapped in parens.
            if (lhs_parenthesised) {
                try self.compileExpression(a.value);
            } else {
                try self.compileNamedValue(a.value, name);
            }
        } else if (a.op == .amp_amp_eq or a.op == .pipe_pipe_eq or a.op == .question_question_eq) {
            // §13.15.4 Logical assignment — `x &&= y`, `x ||= y`,
            // `x ??= y`. Reads `x` once; if the gate fails, leaves
            // `x` unchanged (skipping the rhs and the store).
            // Per §13.15.2 step 1.d, when `IsAnonymousFunction
            // Definition(AssignmentExpression)` and `IsIdentifier
            // Ref(LeftHandSideExpression)` are both true, the
            // RHS undergoes NamedEvaluation with the binding's
            // name. So `value &&= function () {}` produces a
            // function whose `.name` is `"value"`. Plain compound
            // (`+=`, `-=`, …) does NOT qualify — it always
            // applies the binary operator, so an anonymous
            // function literal there is illegal anyway.
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
                // §13.15.4 — IsIdentifierRef gates name inference;
                // a parenthesised LHS (`(x) ??= …`) is no longer
                // an IdentifierRef per the cover grammar.
                if (lhs_parenthesised) {
                    try self.compileExpression(a.value);
                } else {
                    try self.compileNamedValue(a.value, name);
                }
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
            if (lhs_parenthesised) {
                try self.compileExpression(a.value);
            } else {
                try self.compileNamedValue(a.value, name);
            }
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
        if (r_unresolved_flag) |r| {
            // `sta_global_strict` consumes the snapshot taken
            // ahead of the RHS — see §13.15.2 step 1.d.
            const k = try self.internString(binding.name);
            try self.builder.emitOp(.sta_global_strict, a.span);
            try self.builder.emitU16(k);
            try self.builder.emitU8(r);
        } else {
            try self.emitStoreBinding(binding, a.span);
        }
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
    /// suffix, parse the digits into an arbitrary-precision
    /// magnitude, allocate a `JSBigInt` in the realm heap, and
    /// store it as a constant (§12.9.5 BigInt Literals).
    fn compileBigInt(self: *Compiler, span: Span) CompileError!void {
        const text = self.source[span.start..span.end];
        if (text.len == 0 or text[text.len - 1] != 'n') return error.BadNumericLiteral;
        const digits = text[0 .. text.len - 1];
        const bigint_mod = @import("../runtime/bigint.zig");
        const v = bigint_mod.parseLiteralToValue(self.realm.heap.allocator, digits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBigInt => return error.BadNumericLiteral,
        };
        const bi = self.realm.heap.allocateBigIntValue(v) catch return error.OutOfMemory;
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
                    // §13.5.1.2 step 5.b — `delete` of a
                    // SuperReference throws ReferenceError at
                    // runtime (NOT a compile-time SyntaxError;
                    // the operand is evaluated as a reference, and
                    // the IsSuperReference test rejects it). Emit
                    // `new ReferenceError(); throw`.
                    const k_ref_error = try self.internString("ReferenceError");
                    const r_callee = try self.reserveTemp();
                    defer self.releaseTemp();
                    try self.builder.emitOp(.lda_global, u.span);
                    try self.builder.emitU16(k_ref_error);
                    try self.builder.emitOp(.star, u.span);
                    try self.builder.emitU8(r_callee);
                    try self.builder.emitOp(.new_call, u.span);
                    try self.builder.emitU8(r_callee);
                    try self.builder.emitU8(0);
                    try self.builder.emitOp(.throw_, u.span);
                    return;
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
                        const decoded = try self.decodeIdentifierName(key_slice);
                        const k = try self.internString(decoded);
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
        if (u.op == .typeof_) {
            // §13.5.3 typeof — parens don't change reference status:
            // `typeof (x)` and `typeof ((x))` are still typeof of a
            // bare Reference per §13.2.8 ParenthesizedExpression
            // (StringValue / IsIdentifierRef pass through). Unwrap
            // any ParenthesizedExpression layers before checking.
            var inner: *const ast.expression.Expression = u.operand;
            while (inner.* == .parenthesized) inner = inner.parenthesized.expression;
            if (inner.* == .identifier_reference) {
                const span = inner.identifier_reference.span;
                // §12.7 — typeof's silent-miss path also keys on StringValue.
                const name = try self.bindingName(span);
                const scope = self.scope orelse return error.UnresolvedReference;
                if (scope.resolve(name) == null and !std.mem.eql(u8, name, "undefined")) {
                    const k = try self.internString(name);
                    try self.builder.emitOp(.lda_global_or_undef, span);
                    try self.builder.emitU16(k);
                    try self.builder.emitOp(.typeof_, u.span);
                    return;
                }
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
        // §13.10.2 — `PrivateIdentifier in ShiftExpression` is a
        // cover form, parsed as `binary { op = in_, lhs =
        // private_identifier }`. The class-fields-private-in
        // proposal (stage 4) defines membership as a brand check:
        // the result is a Boolean indicating whether the receiver
        // has the private slot the identifier names. We lower to
        // a dedicated `private_in` opcode keyed by the mangled
        // (class-prefixed) private name; the RHS lands in `acc`
        // and the runtime verifies it is an Object before testing
        // the private slot maps.
        if (b.op == .in_ and b.lhs.* == .private_identifier) {
            const priv_span = b.lhs.private_identifier.span;
            const raw = self.source[priv_span.start..priv_span.end];
            // `#` prefix is part of the span — strip it before
            // mangling. The parser guards against a bare `in` LHS
            // outside a class body via `private_names_validate`,
            // but compiler-side `class_stack` is the source of
            // truth at codegen time.
            if (raw.len < 2 or raw[0] != '#') return error.UnsupportedExpression;
            if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
            const decoded = try self.decodeIdentifierName(raw[1..]);
            const mangled = try self.manglePrivateRef(decoded);
            const k = try self.internString(mangled);
            try self.compileExpression(b.rhs);
            try self.builder.emitOp(.private_in, b.span);
            try self.builder.emitU16(k);
            return;
        }

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
            .labeled => |lb| try self.compileLabeled(lb),
            .import_decl => |id| try self.compileImportDecl(id),
            .export_decl => |ed| try self.compileExportDecl(ed),
        }
    }

    /// §16.2.2 ImportDeclaration. In module mode emits a
    /// `module_load` for the source specifier and stores the
    /// resulting namespace in a per-import-decl env slot, then
    /// records each imported name as an indirect alias for
    /// `(namespace_slot, exported_name)`. Reads at use sites then
    /// dereference through the namespace at access time — matching
    /// §8.1.1.5.5 CreateImportBinding's live-binding semantics
    /// (every production engine implements imports this way: V8 /
    /// JSC / SpiderMonkey use the same env-slot-points-at-namespace
    /// shape). In script mode the bindings are declared but stay in
    /// TDZ (no actual import resolution in script mode).
    fn compileImportDecl(self: *Compiler, id: ast.statement.ImportDecl) CompileError!void {
        if (!self.is_module) {
            // Script mode — declare the binding names so a later
            // reference doesn't `UnresolvedReference`, but no module
            // loading happens. §12.7: bindings key off StringValue.
            if (id.default) |bid| {
                const name = try self.bindingName(bid.span);
                _ = try self.declareBinding(name, .let_, bid.span);
            }
            if (id.namespace) |bid| {
                const name = try self.bindingName(bid.span);
                _ = try self.declareBinding(name, .let_, bid.span);
            }
            for (id.named) |spec| {
                const name = try self.bindingName(spec.local.span);
                _ = try self.declareBinding(name, .let_, spec.local.span);
            }
            return;
        }

        // Strip surrounding quotes from the StringLiteral span.
        const raw = self.source[id.source.start..id.source.end];
        if (raw.len < 2) return error.UnsupportedStatement;
        const spec_text = raw[1 .. raw.len - 1];
        const k_spec = try self.internString(spec_text);
        try self.builder.emitOp(.module_load, id.span);
        try self.builder.emitU16(k_spec);

        // Reserve a persistent env slot for the namespace — one per
        // import-decl. All indirect bindings declared by this decl
        // dereference through this slot. We use an env slot (not a
        // temp register) so closures created later in the module body
        // can reach the namespace via `lda_env` — temps are
        // accumulator-only.
        const ns_slot = try self.newEnvSlot();
        try self.builder.emitOp(.sta_env, id.span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(ns_slot);

        // §13.3.1 ImportClause — the namespace binding (`import * as
        // ns from ...`) IS the namespace itself, so model it as a
        // regular `const` slot pointing at the namespace value. The
        // module_load above already left the namespace in the
        // accumulator and we've stored it; create a const binding
        // that aliases that slot. We can't share `ns_slot` directly
        // (it's "owned" by the import decl for indirect dereference)
        // so reload via the existing emit machinery.
        if (id.namespace) |bid| {
            const name = try self.bindingName(bid.span);
            const ns_binding = try self.declareBindingFull(name, .const_, bid.span);
            // Reload namespace from `ns_slot` into the accumulator,
            // then store into the const binding's own env slot.
            // §16.2.1.5 InitializeBinding for the namespace alias —
            // use the init store so the post-Hole TDZ guard added to
            // the assignment path doesn't fire on the very first
            // write into the freshly-declared const slot.
            try self.builder.emitOp(.lda_env, bid.span);
            try self.builder.emitU8(0);
            try self.builder.emitU8(ns_slot);
            try self.emitStoreBindingInit(ns_binding, bid.span);
        }
        if (id.default) |bid| {
            const name = try self.bindingName(bid.span);
            const binding: Binding = .{
                .name = name,
                .env_slot = 0,
                .env_depth = self.env_depth,
                .kind = .const_,
                .span = bid.span,
                .is_import = true,
                .import_ns_slot = ns_slot,
                .import_name = "default",
            };
            const target = self.scope.?;
            if (target.lookupLocal(name)) |_| {
                try self.report(.unexpected_token, bid.span);
                return error.DuplicateBinding;
            }
            try target.bindings.append(self.allocator, binding);
        }
        for (id.named) |spec| {
            const imported_text = self.source[spec.imported_span.start..spec.imported_span.end];
            const imported_name = if (imported_text.len >= 2 and (imported_text[0] == '"' or imported_text[0] == '\''))
                imported_text[1 .. imported_text.len - 1]
            else
                try self.decodeIdentifierName(imported_text);
            const local_name = try self.bindingName(spec.local.span);
            const binding: Binding = .{
                .name = local_name,
                .env_slot = 0,
                .env_depth = self.env_depth,
                .kind = .const_,
                .span = spec.local.span,
                .is_import = true,
                .import_ns_slot = ns_slot,
                .import_name = imported_name,
            };
            const target = self.scope.?;
            if (target.lookupLocal(local_name)) |_| {
                try self.report(.unexpected_token, spec.local.span);
                return error.DuplicateBinding;
            }
            try target.bindings.append(self.allocator, binding);
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
                // §15.2.3.11 ExportDeclaration : `export default
                // AssignmentExpression` — when the expression is an
                // anonymous ClassExpression, NamedEvaluation runs
                // ClassDefinitionEvaluation with `className =
                // "default"` (§15.7.14 step 1). The static-field
                // initializer body then observes `this.name ===
                // "default"`. Without this, the class compiles as
                // anonymous and `.name` is "". See test262
                // language/expressions/class/elements/
                // class-name-static-initializer-default-export.js.
                if (e == .class_expr and e.class_expr.name == null) {
                    try self.emitClassBuild("default", e.class_expr.superclass, e.class_expr.body, e.class_expr.span);
                } else {
                    try self.compileExpression(&e);
                }
                if (self.is_module) {
                    const k_default = try self.internString("default");
                    try self.builder.emitOp(.module_export, ed.span);
                    try self.builder.emitU16(k_default);
                }
            },
            .named => |body| {
                if (!self.is_module) return;
                if (body.source) |src_span| {
                    // §16.2.3.7 ExportDeclaration : `export NamedExports
                    // FromClause` — re-export from another module.
                    // Lower to `module_load <spec>` (which leaves the
                    // source namespace in `acc`) followed by a
                    // `module_reexport_named` per specifier. The
                    // single-purpose op forwards the source key's raw
                    // value — Hole included — to the importer's
                    // namespace under the renamed key, sidestepping
                    // the §9.4.6.7 GetBindingValue Hole-throw that
                    // `lda_property` applies to module namespaces.
                    // Throwing at re-export time would surface a
                    // ReferenceError when the source body is mid-cycle
                    // even if the importer never reads the binding
                    // (e.g. `instn-iee-bndng-*`); forwarding the Hole
                    // defers the throw to the importer's read site,
                    // matching spec semantics.
                    const raw = self.source[src_span.start..src_span.end];
                    if (raw.len < 2) return error.UnsupportedStatement;
                    const spec_text = raw[1 .. raw.len - 1];
                    const k_spec = try self.internString(spec_text);
                    try self.builder.emitOp(.module_load, ed.span);
                    try self.builder.emitU16(k_spec);
                    for (body.specifiers) |spec| {
                        // §12.7 IdentifierName escape-decoding: both
                        // sides are IdentifierName productions when
                        // not a StringLiteral form. `μ` decodes
                        // to `μ` so the redirect key matches the
                        // canonical name in the source module's
                        // namespace.
                        const local_text = self.source[spec.local_span.start..spec.local_span.end];
                        const local_name = if (local_text.len >= 2 and (local_text[0] == '"' or local_text[0] == '\''))
                            local_text[1 .. local_text.len - 1]
                        else
                            try self.decodeIdentifierName(local_text);
                        const exported_text = self.source[spec.exported_span.start..spec.exported_span.end];
                        const exported_name = if (exported_text.len >= 2 and (exported_text[0] == '"' or exported_text[0] == '\''))
                            exported_text[1 .. exported_text.len - 1]
                        else
                            try self.decodeIdentifierName(exported_text);
                        const k_local = try self.internString(local_name);
                        const k_exp = try self.internString(exported_name);
                        try self.builder.emitOp(.module_reexport_named, spec.span);
                        try self.builder.emitU16(k_local);
                        try self.builder.emitU16(k_exp);
                    }
                    return;
                }
                for (body.specifiers) |spec| {
                    // §16.2.3.5 ExportSpecifier — the *local* side is
                    // always an IdentifierName (no string-literal form);
                    // the *exported* side is a ModuleExportName which
                    // §16.2.2 also lets be a StringLiteral. Strip the
                    // surrounding quotes for the exported key so
                    // `export { f as "☿" }` registers under the bare
                    // code-point key on the namespace, not the literal
                    // `"\"☿\""` six-byte token. The from-clause branch
                    // above already strips; this is the parallel fix
                    // for the local-export branch.
                    //
                    // §12.7 IdentifierName — both sides are
                    // IdentifierName productions (when not a
                    // StringLiteral exported name), so `\uXXXX`
                    // escapes must decode to their code-point
                    // sequence. `export { x as μ }` registers
                    // the export under `μ` (2-byte UTF-8), not the
                    // literal `μ` token.
                    const local_name = try self.bindingName(spec.local_span);
                    const exported_text = self.source[spec.exported_span.start..spec.exported_span.end];
                    const exported_name = if (exported_text.len >= 2 and (exported_text[0] == '"' or exported_text[0] == '\''))
                        exported_text[1 .. exported_text.len - 1]
                    else
                        try self.decodeIdentifierName(exported_text);
                    // §16.2.1.7.1 ParseModule step 10.1.ii — if
                    // ExportEntry.LocalName matches an
                    // ImportEntry.LocalName, the export entry is
                    // demoted to an IndirectExportEntry referencing
                    // the original module. So
                    //     import { foo } from "./src";
                    //     export { foo };
                    // is spec-equivalent to
                    //     export { foo } from "./src";
                    // — both forms preserve binding identity, which
                    // matters for §15.2.1.16.3 ResolveExport's
                    // ambiguity test (two re-export routes that
                    // ultimately resolve to the same source-module
                    // binding aren't ambiguous, even when one is
                    // value-copied here and the other is a direct
                    // redirect). Detect the import-binding case and
                    // emit `module_reexport_named` so the redirect
                    // is installed on our namespace, giving
                    // `mergeStarKey` a chance to match terminals.
                    const scope = self.scope orelse return error.UnsupportedStatement;
                    const resolved = scope.resolve(local_name);
                    if (resolved) |binding| if (binding.is_import) {
                        // Re-export through the same import-source
                        // namespace. Load the source namespace from
                        // the import's persistent `import_ns_slot`
                        // into `acc`, then install the redirect.
                        const depth = self.env_depth - binding.env_depth;
                        try self.builder.emitOp(.lda_env, spec.span);
                        try self.builder.emitU8(depth);
                        try self.builder.emitU8(binding.import_ns_slot);
                        const k_local = try self.internString(binding.import_name);
                        const k_exp = try self.internString(exported_name);
                        try self.builder.emitOp(.module_reexport_named, spec.span);
                        try self.builder.emitU16(k_local);
                        try self.builder.emitU16(k_exp);
                        continue;
                    };
                    try self.emitBindingRead(local_name, spec.span);
                    const k = try self.internString(exported_name);
                    try self.builder.emitOp(.module_export, spec.span);
                    try self.builder.emitU16(k);
                }
            },
            .all => |all_body| {
                if (!self.is_module) return;
                // §16.2.3.7 ExportDeclaration : `export * as ns from
                // "src"` — load the source module's namespace and bind
                // it on our own namespace under `ns`. The
                // ModuleExportName may be a StringLiteral (§16.2.2);
                // strip surrounding quotes so the key is the bare code-
                // point sequence rather than the raw token. Lifetime
                // of `spec_text` and `ns_name` mirrors every other
                // module_export key: borrowed from `self.source`, which
                // outlives the chunk.
                //
                // `export * from "src"` (no `as`) is the namespace-
                // merge form — every non-`default` export from `src`
                // is forwarded onto our own namespace. Lower this to
                // `module_load <k_spec>; module_reexport_star` so the
                // runtime grabs the source namespace and copies its
                // exported keys onto the executing module's namespace.
                const src_span = all_body.source;
                const raw = self.source[src_span.start..src_span.end];
                if (raw.len < 2) return;
                const spec_text = raw[1 .. raw.len - 1];
                const k_spec = try self.internString(spec_text);
                if (all_body.namespace_local) |ns_span| {
                    try self.builder.emitOp(.module_load, ed.span);
                    try self.builder.emitU16(k_spec);
                    const ns_text = self.source[ns_span.start..ns_span.end];
                    const ns_name = if (ns_text.len >= 2 and (ns_text[0] == '"' or ns_text[0] == '\''))
                        ns_text[1 .. ns_text.len - 1]
                    else
                        ns_text;
                    const k_ns = try self.internString(ns_name);
                    try self.builder.emitOp(.module_export, ed.span);
                    try self.builder.emitU16(k_ns);
                } else {
                    try self.builder.emitOp(.module_load, ed.span);
                    try self.builder.emitU16(k_spec);
                    try self.builder.emitOp(.module_reexport_star, ed.span);
                }
            },
        }
    }

    /// After compiling an `export <decl>`, re-read each declared
    /// name and emit a `module_export` for it.
    fn publishExportedNamesFromDecl(self: *Compiler, stmt: *const Statement) CompileError!void {
        switch (stmt.*) {
            .lexical => |ld| {
                for (ld.declarators) |d| {
                    // §14.3.3 BindingPattern — `export const {a, b} = obj;`
                    // / `export const [x, y] = arr;` introduce one binding
                    // per pattern leaf. Walk the pattern and publish each
                    // bound identifier; identifier-only targets short-
                    // circuit through the same helper.
                    try self.publishExportedTargetNames(d.name, d.span);
                }
            },
            .function_decl => |fd| {
                const name = try self.bindingName(fd.name.span);
                try self.emitBindingRead(name, fd.name.span);
                const k = try self.internString(name);
                try self.builder.emitOp(.module_export, fd.name.span);
                try self.builder.emitU16(k);
            },
            .class_decl => |cd| {
                const name = try self.bindingName(cd.name.span);
                try self.emitBindingRead(name, cd.name.span);
                const k = try self.internString(name);
                try self.builder.emitOp(.module_export, cd.name.span);
                try self.builder.emitU16(k);
            },
            else => {},
        }
    }

    /// Walk a `BindingTarget` and emit a `module_export` for every
    /// bound identifier — covers identifier targets (the trivial
    /// case) and §14.3.3 destructuring patterns (`{ a }`, `[x, y]`,
    /// `[, ...rest]`, nested combinations). Used by
    /// `publishExportedNamesFromDecl` so a pattern-shaped `export
    /// const { a } = obj` publishes `a` on the module namespace
    /// alongside the simple-identifier case.
    fn publishExportedTargetNames(self: *Compiler, target: ast.statement.BindingTarget, span: Span) CompileError!void {
        switch (target) {
            .identifier => |id| {
                const name = self.source[id.span.start..id.span.end];
                try self.emitBindingRead(name, span);
                const k = try self.internString(name);
                try self.builder.emitOp(.module_export, span);
                try self.builder.emitU16(k);
            },
            .object => |op| {
                for (op.properties) |prop| {
                    try self.publishExportedTargetNames(prop.value.target, prop.span);
                }
                if (op.rest) |rest| {
                    const name = self.source[rest.span.start..rest.span.end];
                    try self.emitBindingRead(name, rest.span);
                    const k = try self.internString(name);
                    try self.builder.emitOp(.module_export, rest.span);
                    try self.builder.emitU16(k);
                }
            },
            .array => |ap| {
                for (ap.elements) |maybe_el| {
                    const el = maybe_el orelse continue; // elision
                    try self.publishExportedTargetNames(el.target, el.span);
                }
                if (ap.rest) |rest| try self.publishExportedTargetNames(rest.*, span);
            },
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

    /// At module instantiation, pre-seed the namespace with `Hole`
    /// for every exported TDZ-tracked binding so an importing module
    /// reading the binding before the source body initialises it
    /// triggers ReferenceError via `throw_if_hole` on the indirect
    /// import read. Spec basis: §8.1.1.5.5 CreateImportBinding's
    /// "the binding is initialized" record interacting with the
    /// importer's GetBindingValue (§8.1.1.1.6) — accessing an
    /// uninitialised binding throws ReferenceError, which we surface
    /// via the Hole sentinel.
    ///
    /// Covers: `export let X`, `export const X`, `export class X`,
    /// `export default class { ... }`, `export default <expr>`. The
    /// `default` slot is also seeded — the value lands at body
    /// evaluation, when `module_export "default"` runs. Skipped:
    /// `export function` / `export function*` / `export async fn`
    /// (already initialised by the hoisted function-decl phase
    /// before this seed runs would be observably wrong; they reach
    /// `module_export` via `publishExportedNamesFromDecl` in the
    /// hoist phase), `export var` (initialised to undefined at
    /// hoist), `export { X }` / `export { X } from` / `export *`
    /// (re-exports are resolved indirectly; no own slot).
    fn seedTdzExportHoles(self: *Compiler, body: []ast.statement.Statement, span: Span) CompileError!void {
        for (body) |s| {
            switch (s) {
                .export_decl => |ed| switch (ed.body) {
                    .declaration => |inner| switch (inner.*) {
                        // `export var` is hoist-initialised to
                        // `undefined`, not Hole — seeding Hole would
                        // flip pre-init importer reads from the spec
                        // `undefined` to a spurious ReferenceError.
                        // Only `let` / `const` participate in TDZ — but
                        // the namespace still has to *advertise* the
                        // exported var name from the start of body
                        // evaluation, otherwise `'attr' in ns` returns
                        // false for a self-import that sees the partial
                        // namespace before the `export var attr;` line
                        // runs. Publish `undefined` at hoist time so
                        // the property exists; the later var-init (if
                        // any) overwrites via `compileExportDecl`.
                        .lexical => |ld| if (ld.kind != .var_) {
                            for (ld.declarators) |d| {
                                if (identifierName(self.source, d.name)) |name| {
                                    try self.seedExportHole(name, d.span);
                                }
                            }
                        } else {
                            for (ld.declarators) |d| {
                                if (identifierName(self.source, d.name)) |name| {
                                    const k = try self.internString(name);
                                    try self.builder.emitOp(.lda_undefined, d.span);
                                    try self.builder.emitOp(.module_export, d.span);
                                    try self.builder.emitU16(k);
                                }
                            }
                        },
                        .class_decl => |cd| {
                            const name = try self.bindingName(cd.name.span);
                            try self.seedExportHole(name, cd.name.span);
                        },
                        else => {},
                    },
                    .default_value => {
                        // `export default <expr>` — the consumer
                        // imports via "default". Seed Hole so an
                        // importer reading default before the body
                        // evaluates the expression gets the spec
                        // ReferenceError.
                        try self.seedExportHole("default", ed.span);
                    },
                    .named => |nb| {
                        // §16.2.3.7 ExportDeclaration : `export
                        // NamedExports` (no `from`) — `export { local
                        // as exported }` resolves `exported` to the
                        // local `let` / `const` / `class` binding's
                        // value at module body evaluation. Per spec
                        // §9.4.6.7 step 12-13 the importer's read
                        // routes through GetBindingValue(localName,
                        // true) which throws on the source TDZ-Hole.
                        // Cynic publishes `exported` only when the
                        // `export { ... }` statement actually runs, so
                        // any cross-import read before then would see
                        // an absent slot (`undefined`) instead of the
                        // spec ReferenceError. Seed Hole for every
                        // non-source named export whose local resolves
                        // to a TDZ-tracked binding.
                        //
                        // §16.2.3.7 + `from` clause — re-exports
                        // (`export { x } from "./y"`) get the same
                        // Hole-seed: the publish runs only after the
                        // source module loads + this body's re-export
                        // statement executes, so without the seed
                        // cross-module reads pre-evaluation would see
                        // undefined. The compiler's re-export emit
                        // (`compileExportDecl .named` with source) does
                        // overwrite the Hole with the source's current
                        // value at run time.
                        for (nb.specifiers) |spec| {
                            const exported_text = self.source[spec.exported_span.start..spec.exported_span.end];
                            const exported_name = if (exported_text.len >= 2 and (exported_text[0] == '"' or exported_text[0] == '\''))
                                exported_text[1 .. exported_text.len - 1]
                            else
                                exported_text;
                            if (nb.source != null) {
                                // Re-export — the local name is the
                                // source's export, not a local binding;
                                // seed Hole for the renamed key.
                                try self.seedExportHole(exported_name, spec.span);
                                continue;
                            }
                            // No `from`: skip when the local resolves
                            // to a `var` / `function` (already
                            // initialised at hoist) or doesn't resolve
                            // (rare in a well-formed module — leave to
                            // ResolveExport-time SyntaxError).
                            const local_text = self.source[spec.local_span.start..spec.local_span.end];
                            const local_name = if (local_text.len >= 2 and (local_text[0] == '"' or local_text[0] == '\''))
                                local_text[1 .. local_text.len - 1]
                            else
                                local_text;
                            const scope = self.scope orelse continue;
                            const binding = scope.resolve(local_name) orelse continue;
                            switch (binding.kind) {
                                .let_, .const_ => try self.seedExportHole(exported_name, spec.span),
                                .var_ => {},
                            }
                        }
                    },
                    .all => {},
                },
                else => {},
            }
        }
        _ = span;
    }

    fn seedExportHole(self: *Compiler, name: []const u8, span: Span) CompileError!void {
        const k = try self.internString(name);
        try self.builder.emitOp(.lda_hole, span);
        try self.builder.emitOp(.module_export, span);
        try self.builder.emitU16(k);
    }

    /// §9.4.6.7 Module Namespace [[Get]] live-binding helper. After
    /// any `sta_env` / `sta_global` to a top-level binding that's
    /// also exported, emit a `module_export <exported>` for each
    /// alias so subsequent reads through the namespace observe the
    /// new value rather than the declaration-time snapshot. `acc`
    /// is preserved across both store ops and `module_export` so
    /// the resulting bytecode is value-neutral.
    ///
    /// Only fires for top-level bindings (`env_depth == 0`) inside
    /// a module — nested-scope bindings can't be exported in the
    /// first place. Indirect-export entries
    /// (`export { x } from "..."`) are NOT in this map: those
    /// resolve through `namespace_redirects` and have no local
    /// owning storage to mutate.
    fn maybeRepublishExport(self: *Compiler, binding: Binding, span: Span) CompileError!void {
        if (!self.is_module) return;
        if (binding.env_depth != 0) return;
        if (binding.is_import) return;
        const map = self.module_exports_by_local orelse return;
        const entry = map.get(binding.name) orelse return;
        for (entry.items) |exported| {
            const k = try self.internString(exported);
            try self.builder.emitOp(.module_export, span);
            try self.builder.emitU16(k);
        }
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
        const labels = try self.drainPendingLabels();

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
                        // §12.7 — bind by StringValue.
                        bind_name = try self.bindingName(id.span);
                        bind_span = id.span;
                    },
                    .array, .object => {
                        pattern_target = d.name;
                        bind_target_kind = .pattern;
                        bind_span = d.span;
                    },
                }
            },
            .expression => |e| {
                // §14.7.5.1 / §13.15.3 — when the LHS is a
                // ParenthesizedExpression and its inner refines to a
                // valid AssignmentTarget (IdentifierReference or
                // MemberExpression), the spec re-parses it under the
                // refined grammar. Peel transparent paren wrappers so
                // `for ((async) of …)` and `for ((x.y) of …)` reach the
                // same code paths as their unparenthesised forms. Note
                // we do NOT peel parens around array / object literals
                // — `([a]) ` does not refine to AssignmentPattern per
                // §13.15.5.1.
                var lhs = e;
                while (lhs == .parenthesized) {
                    const inner = lhs.parenthesized.expression.*;
                    switch (inner) {
                        .identifier_reference, .member, .parenthesized => lhs = inner,
                        else => break,
                    }
                }
                switch (lhs) {
                    .identifier_reference => |ir| {
                        // §12.7 — bind by StringValue.
                        bind_name = try self.bindingName(ir.span);
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
                        assignment_pattern_target = lhs;
                        bind_span = switch (lhs) {
                            .array_literal => |al| al.span,
                            .object_literal => |ol| ol.span,
                            else => unreachable,
                        };
                        bind_target_kind = .assignment_pattern;
                    },
                    else => return error.UnsupportedStatement,
                }
            },
        }

        // §14.7.5.6 CreatePerIterationEnvironment — when the loop
        // binding is `let` / `const`, every iteration runs in a
        // fresh env so closures captured inside the body see the
        // iteration-specific value. `var` and bare-identifier
        // assignment fall through to the function env (the spec
        // gives them the legacy single-binding behaviour). Pattern
        // targets get the same treatment as identifier targets.
        const binding_env_needed = (bind_target_kind == .binding or bind_target_kind == .pattern) and
            (bind_kind == .let_ or bind_kind == .const_);
        // §14.7.5.6 optimisation — the per-iteration environment is
        // only spec-observable when a nested closure in the body
        // captures the loop variable. With no such capture, V8 / JSC
        // / SpiderMonkey all elide it; Cynic hoists one env out of
        // the loop and reuses it, dropping a make/declare/pop on
        // every iteration. Single-identifier `let` / `const` only —
        // pattern targets keep the spec-faithful per-iteration env.
        var per_iter_env = binding_env_needed;
        var hoist_binding_env = false;
        if (binding_env_needed and bind_target_kind == .binding and
            !self.bodyHasClosure(s.body))
        {
            per_iter_env = false;
            hoist_binding_env = true;
        }

        var loop_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = per_iter_env or hoist_binding_env };
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

        // §13.7.5.6 ForIn/OfHeadEvaluation step 2 — when the
        // ForDeclaration has BoundNames (i.e. `let` / `const`),
        // create a fresh DeclarativeEnvironment, install every
        // bound name as a TDZ (uninitialised lex binding), and
        // evaluate the iterable expression inside it. Spec step 4
        // pops the env back to the outer one before
        // ForIn/OfBodyEvaluation. Closures created inside the
        // iterable expression (e.g. `{ i: function() { typeof x } }`)
        // capture the TDZ binding and observe a ReferenceError when
        // invoked later — `scope-head-lex-{open,close}.js` and
        // `head-{let,const}-bound-names-fordecl-tdz.js` assert this.
        var head_tdz_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = true };
        // §13.7.5.6 step 2 — the head TDZ env is required for every
        // `let` / `const` head regardless of whether the body's
        // per-iteration env is hoisted away.
        const head_tdz_env = binding_env_needed;
        var saved_head_slot_count: u8 = 0;
        if (head_tdz_env) {
            saved_head_slot_count = self.env_slot_count;
            self.env_slot_count = 0;
            self.scope = &head_tdz_scope;
            self.env_depth = saved_env_depth + 1;
            try self.builder.emitOp(.make_environment, s.span);
            const head_size_patch = self.builder.code.items.len;
            try self.builder.emitU8(0);
            if (pattern_target) |pt| {
                try self.declarePatternBindings(pt, bind_kind);
            } else {
                _ = try self.declareBinding(bind_name, bind_kind, bind_span);
            }
            self.builder.code.items[head_size_patch] = self.env_slot_count;
        }
        defer head_tdz_scope.deinit(self.allocator);

        // §14.7.5.6 ForIn/OfBodyEvaluation. Eval the iterable, open
        // an iterator (for-of: §7.4.1 GetIterator; for-in:
        // §14.7.5.6 EnumerateObjectProperties), then drive
        // `it.next()` until `result.done`.
        try self.compileExpression(&s.right);

        // §13.7.5.6 step 4 — close the head TDZ env before opening
        // the iterator. The iterator's `next()` calls and the
        // per-iteration body run in fresh envs parented to the OUTER
        // env, not the TDZ env (the TDZ binding is unreachable from
        // the body — only the iterable expression observed it).
        if (head_tdz_env) {
            try self.builder.emitOp(.pop_env, s.span);
            self.scope = &loop_scope;
            self.env_depth = saved_env_depth;
            self.env_slot_count = saved_head_slot_count;
        }
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

        // §7.4.5 GetIteratorDirect step 2 — `[[NextMethod]]` is
        // captured ONCE at iterator open and re-used per step.
        // Reading `iter.next` in the loop body would fire a user
        // `get next()` accessor every iteration; the fixtures
        // expect exactly one read (`iterator-next-reference.js`).
        // for-in (\`for_in_open\`) returns a Cynic-internal iterator
        // whose \`next\` is a fixed native method, so caching is
        // semantically a no-op there but still safe.
        const r_next_fn = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.ldar, s.span);
        try self.builder.emitU8(r_iter);
        try self.builder.emitOp(.lda_property, s.span);
        try self.builder.emitU16(k_next);
        try self.builder.emitOp(.star, s.span);
        try self.builder.emitU8(r_next_fn);

        // Plain sync `for-of` folds the step into `for_of_next`,
        // which writes the boolean `done` into its own register.
        // `for-await-of` and `for-in` keep the open-coded
        // `call_method` + `lda_property` sequence.
        const fast_for_of = s.kind != .in_ and !s.is_await;
        const r_done = try self.reserveTemp();
        defer self.releaseTemp();

        // §14.7.5.6 optimisation — hoisted binding env. When the body
        // captures nothing, the loop variable's environment is built
        // once here, before the loop, and reused across iterations
        // instead of a make / declare / pop on every step.
        var hoist_size_patch: usize = 0;
        var saved_hoist_slot_count: u8 = 0;
        if (hoist_binding_env) {
            saved_hoist_slot_count = self.env_slot_count;
            self.env_slot_count = 0;
            try self.builder.emitOp(.make_environment, s.span);
            hoist_size_patch = self.builder.code.items.len;
            try self.builder.emitU8(0); // placeholder; patched below
            self.env_depth = saved_env_depth + 1;
            _ = try self.declareBinding(bind_name, bind_kind, bind_span);
        }

        const loop_start = self.builder.here();

        if (fast_for_of) {
            // §7.4.2 IteratorNext + §7.4.8 IteratorStepValue —
            // `for_of_next` folds the `.next()` call, the
            // result-not-object check, and the `.done` / `.value`
            // reads into one op (fast path for the built-in Array
            // iterator). The stepped value lands in `acc`, the
            // boolean `done` in `r_done`.
            try self.builder.emitOp(.for_of_next, s.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitU8(r_next_fn);
            try self.builder.emitU8(r_done);
            // r_result holds the stepped value across the body.
            try self.builder.emitOp(.star, s.span);
            try self.builder.emitU8(r_result);
            // acc = done, for the loop-exit test below.
            try self.builder.emitOp(.ldar, s.span);
            try self.builder.emitU8(r_done);
        } else {
            // r_result = r_iter.next() — uses the cached `next`
            // from r_next_fn (read once above).
            // call_method r_recv=r_iter, r_callee=r_next_fn, argc=0
            try self.builder.emitOp(.call_method, s.span);
            try self.builder.emitU8(r_iter);
            try self.builder.emitU8(r_next_fn);
            try self.builder.emitU8(0);
            // §14.7.5 / §27.1.4.4 — for-await-of awaits each
            // next() result. Sync iters return `{done, value}`
            // directly; `await` on a non-Promise resolves to the
            // value as-is, so the sync fallback in
            // `async_iter_open` composes.
            if (s.is_await) try self.builder.emitOp(.await_, s.span);
            try self.builder.emitOp(.star, s.span);
            try self.builder.emitU8(r_result);

            // §7.4.2 IteratorNext step 4 — `If Type(result) is
            // not Object, throw a TypeError`. `for-in` is driven
            // by the harness iterator (always Object); skip it.
            if (s.kind != .in_) {
                try self.builder.emitOp(.ldar, s.span);
                try self.builder.emitU8(r_result);
                try self.builder.emitOp(.throw_if_not_object, s.span);
            }

            // acc = r_result.done, for the loop-exit test below.
            try self.builder.emitOp(.ldar, s.span);
            try self.builder.emitU8(r_result);
            try self.builder.emitOp(.lda_property, s.span);
            try self.builder.emitU16(k_done);
        }
        // if (done) jmp exit
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
        } else if (hoist_binding_env) {
            // The loop variable was already declared in the hoisted
            // env above the loop; `assignToBinding` below writes it
            // each iteration. Nothing to declare here.
        } else if (bind_target_kind == .binding) {
            // var / non-let binding lives in the function env.
            _ = try self.declareBinding(bind_name, bind_kind, bind_span);
        } else if (bind_target_kind == .pattern) {
            // var-pattern: declare each leaf in the function env.
            try self.declarePatternBindings(pattern_target.?, bind_kind);
        }

        // §14.7.5.7 / §7.4.6 — handler range starts BEFORE the LHS
        // assignment so a throw inside the per-iteration target
        // (poisoned setter on `for (x.attr of …)`, TDZ on `let` /
        // `const`, destructuring failure) calls IteratorClose.
        // §14.7.5.7 step 4 covers `lhsRef is abrupt` explicitly.
        // `for-in` is excluded (no IteratorClose contract).

        // value → bind. Fast `for-of` already holds the stepped
        // value in r_result; the slow / for-in path holds the
        // iterator result object there and must read `.value`.
        try self.builder.emitOp(.ldar, s.span);
        try self.builder.emitU8(r_result);
        if (!fast_for_of) {
            try self.builder.emitOp(.lda_property, s.span);
            try self.builder.emitU16(k_value);
        }

        // §14.7.5.7 / §7.4.6 — handler range starts AFTER `lda_property
        // "value"` (§7.4.7 IteratorValue runs before LHS assignment; a
        // thrown getter does NOT trigger IteratorClose per spec) but
        // BEFORE the LHS assignment so a throw inside the per-iteration
        // target (poisoned setter on `for (x.attr of …)`, TDZ on `let`
        // /`const`, destructuring failure) calls IteratorClose.
        // §14.7.5.7 step 4 covers `lhsRef is abrupt` explicitly.
        // `for-in` is excluded (no IteratorClose contract).
        const body_start_pc = self.builder.here();
        // Assign to the binding (lexical, identifier-assign target,
        // member target, assignment pattern, or destructuring pattern
        // walk).
        if (pattern_target) |pt| {
            // §14.7.5.7 — for-of with `let` / `const` / `var`
            // declarator pattern is BindingInitialization
            // (§14.3.3); leaves InitializeBinding the per-iteration
            // slot, which may legitimately be the Hole sentinel.
            try self.compileDestructure(pt, true);
        } else if (member_target) |m| {
            try self.compileForOfMemberAssign(m, s.span);
        } else if (assignment_pattern_target) |ap| {
            try self.compileAssignmentPattern(ap);
        } else {
            // §14.7.5.7 — `for (let x of …)` is
            // BindingInitialization on the per-iteration slot.
            // `for (x of …)` against an outer binding is plain
            // PutValue (§13.15.2) and must respect TDZ.
            const for_of_is_init = (bind_target_kind == .binding);
            try self.assignToBinding(bind_name, bind_span, for_of_is_init);
        }

        var ctx: LoopContext = .{
            .continue_target = 0,
            // Both the per-iteration env and the hoisted env are live
            // inside the body, so a `break` (or an outer loop's
            // break / continue skipping through) must pop one.
            .needs_env_pop = per_iter_env or hoist_binding_env,
            // §7.4.6 IteratorClose — `for-of` only. `for-in` walks
            // own keys directly and has no `.return()` contract.
            .iter_register = if (s.kind == .in_) null else r_iter,
            .parent = self.current_loop,
            .entry_finally_chain = self.finally_chain,
            .labels = labels,
        };
        defer ctx.deinit(self.allocator);
        const saved_loop = self.current_loop;
        self.current_loop = &ctx;
        defer self.current_loop = saved_loop;

        // §14.7.5.7 / §7.4.6 — wrap the body in an implicit handler
        // that calls IteratorClose(iter) on abrupt completion (throw).
        // `break` / `return` already close via compileBreak /
        // compileReturn; `continue` exits the body normally. The
        // handler isn't installed for `for-in` (no IteratorClose
        // contract).
        try self.compileStatement(s.body);
        const body_end_pc = self.builder.here();
        if (s.kind != .in_) {
            // Skip the synthetic handler on normal completion.
            try self.builder.emitOp(.jmp, s.span);
            const skip_handler_patch = self.builder.here();
            try self.builder.emitI16(0);
            const handler_pc = self.builder.here();
            // The thrown value is deposited in `acc` (catch_register =
            // null). Save, close the iterator (preserves acc per the
            // op's contract), then rethrow.
            const r_caught = try self.reserveTemp();
            defer self.releaseTemp();
            try self.builder.emitOp(.star, s.span);
            try self.builder.emitU8(r_caught);
            try self.builder.emitOp(.iter_close, s.span);
            try self.builder.emitU8(r_iter);
            // §7.4.6 step 7 — original throw wins; swallow any inner
            // throw from `return()` and skip the non-Object check.
            try self.builder.emitU8(1);
            try self.builder.emitOp(.ldar, s.span);
            try self.builder.emitU8(r_caught);
            try self.builder.emitOp(.throw_, s.span);
            const after_handler_pc = self.builder.here();
            try self.builder.patchI16(skip_handler_patch, after_handler_pc);
            try self.builder.addHandler(.{
                .start_pc = body_start_pc,
                .end_pc = body_end_pc,
                .handler_pc = handler_pc,
                .catch_register = null,
            });
        }

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

        // The `for_of_next`-done path falls through to here with the
        // hoisted env still live, so pop it. `break` already popped
        // its env via `needs_env_pop`, so it targets `real_exit`,
        // past this pop. With no hoisted env the two labels coincide.
        const exit_target = self.builder.here();
        if (hoist_binding_env) {
            try self.builder.emitOp(.pop_env, s.span);
        }
        const real_exit = self.builder.here();
        try self.builder.patchI16(exit_patch, exit_target);
        for (ctx.break_patches.items) |p| try self.builder.patchI16(p, real_exit);

        // Patch the per-iter `make_environment` size to whatever
        // env_slot_count grew to (iteration var + body lexicals),
        // and restore the enclosing function's slot counter.
        if (per_iter_env) {
            self.builder.code.items[per_iter_size_patch] = self.env_slot_count;
            self.env_slot_count = saved_per_iter_slot_count;
        }
        if (hoist_binding_env) {
            self.builder.code.items[hoist_size_patch] = self.env_slot_count;
            self.env_slot_count = saved_hoist_slot_count;
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
                if (raw.len > 0 and raw[0] == '#') {
                    // §13.2.7 / §7.3.30 PrivateFieldSet — `for (this.#x of …)`
                    // and `for (this.#x in …)` assign each iteration value
                    // through the private slot. Mangle the identifier with
                    // the enclosing class's private prefix and emit
                    // `sta_private`, which runs the §7.3.31 PrivateFieldFind
                    // brand check at runtime (throwing TypeError when the
                    // receiver is missing the slot).
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    const decoded = try self.decodeIdentifierName(raw[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
                    const k = try self.internString(mangled);
                    try self.builder.emitOp(.ldar, span);
                    try self.builder.emitU8(r_value);
                    try self.builder.emitOp(.sta_private, span);
                    try self.builder.emitU16(k);
                    try self.builder.emitU8(r_obj);
                    return;
                }
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
        // §14.13 — `LABEL : SwitchStatement` lets `break LABEL ;`
        // inside the cases exit the switch.
        const labels = try self.drainPendingLabels();

        // §14.12.3 SwitchStatement Runtime Semantics:
        //   1. Let exprRef be ? Evaluation of Expression.
        //   2. Let switchValue be ? GetValue(exprRef).
        //   3. Let oldEnv = running execution context's
        //      LexicalEnvironment.
        //   4. Let blockEnv = NewDeclarativeEnvironment(oldEnv).
        //   5. Perform BlockDeclarationInstantiation(CaseBlock,
        //      blockEnv).
        //   6. Set the LexicalEnvironment to blockEnv.
        //
        // So the discriminant is evaluated in the OUTER environment;
        // closures created during the discriminant capture that
        // outer env. Only after `switchValue` is captured does the
        // fresh CaseBlock env come into existence and pick up the
        // hoisted `let`/`const` slots from the case bodies. A test
        // expression / case body that mentions the same name as a
        // `let` declared inside a later case binds against the
        // inner CaseBlock binding (in TDZ until that case body
        // evaluates the declarator); but anything in the
        // discriminant resolves against `oldEnv`.

        // Evaluate the discriminant FIRST, in the outer scope.
        try self.compileExpression(&s.discriminant);
        const r_disc = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, s.span);
        try self.builder.emitU8(r_disc);

        // §14.12.3 — the CaseBlock gets a fresh DeclarativeEnvironment
        // ONLY when there are lexical declarations inside it. Without
        // any `let` / `const` / `class` in any case body, the spec
        // optimisation (and §14.2 BlockDeclarationInstantiation step
        // 1's empty-list early-out) means no env is created and the
        // CaseBlock runs in the enclosing env. Skipping the env
        // emission here keeps exception unwinding (which doesn't
        // rebalance the env stack) consistent: a `throw` from inside
        // a `switch (…) { case X: throw e; }` inside a `try` must
        // land on the outer catch without leaving a stray switch
        // env on the env chain.
        const has_lex_decls = blk: {
            for (s.cases) |case| {
                for (case.body) |*stmt| {
                    switch (stmt.*) {
                        .lexical => |ld| if (ld.kind != .var_) break :blk true,
                        .class_decl => break :blk true,
                        // §14.12.4 LexicallyDeclaredNames also
                        // includes function declarations in block
                        // positions (§14.2 BlockDeclarationInstantiation
                        // step 2.b). Cynic targets strict-only so
                        // Annex B's legacy hoist-to-outer doesn't
                        // apply — the function stays scoped to the
                        // CaseBlock and must not be visible outside.
                        .function_decl => break :blk true,
                        else => {},
                    }
                }
            }
            break :blk false;
        };

        var switch_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = has_lex_decls };
        defer switch_scope.deinit(self.allocator);
        const saved_scope = self.scope;
        self.scope = &switch_scope;
        defer self.scope = saved_scope;

        const saved_env_depth = self.env_depth;
        defer self.env_depth = saved_env_depth;
        const saved_slot_count = self.env_slot_count;
        if (has_lex_decls) self.env_slot_count = 0;
        defer self.env_slot_count = saved_slot_count;

        // §14.12.4 CaseBlock — emit a `make_environment` for the
        // fresh CaseBlock env when there are lexical declarations.
        // Slot count is patched once all declarations have been
        // hoisted.
        var switch_env_size_patch: usize = 0;
        if (has_lex_decls) {
            try self.builder.emitOp(.make_environment, s.span);
            switch_env_size_patch = self.builder.code.items.len;
            try self.builder.emitU8(0);
            self.env_depth = saved_env_depth + 1;

            // §14.12.4 CaseBlock — the whole CaseBlock shares one
            // lexical scope; LexicallyDeclaredNames(CaseBlock) is
            // the union of the lexically-declared names from every
            // case + the default. Hoist `let` / `const` slots from
            // every case body so a `switch (x) { case 1: let y = 1; }`
            // resolves when the body runs.
            for (s.cases) |case| {
                try self.hoistLetConst(case.body);
            }
        }

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
        // `needs_env_pop` matches the env we just emitted so a
        // `break` walks out of the CaseBlock env on the way out.
        var ctx: LoopContext = .{
            .continue_target = 0,
            .parent = self.current_loop,
            .entry_finally_chain = self.finally_chain,
            .labels = labels,
            .is_switch = true,
            .needs_env_pop = has_lex_decls,
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

        // §14.12.3 step 8 — pop the CaseBlock env on natural
        // fall-through to the end of the switch (no case body
        // hit a `break`). `break` inside a case body emits its
        // own `pop_env` via `LoopContext.needs_env_pop`, then
        // jumps past this site to `exit_pc`. When the switch
        // didn't allocate an env, both paths just land on
        // `exit_pc` directly.
        const fallback_target_pc = self.builder.here();
        if (has_lex_decls) {
            try self.builder.emitOp(.pop_env, s.span);
        }

        const exit_pc = self.builder.here();
        if (default_body_pc) |pc| {
            try self.builder.patchI16(fallback_patch, pc);
        } else {
            // No default: land on the natural-fall-through pop so
            // the env teardown still runs (when we have one).
            try self.builder.patchI16(fallback_patch, fallback_target_pc);
        }
        for (ctx.break_patches.items) |p| try self.builder.patchI16(p, exit_pc);
        if (has_lex_decls) {
            self.builder.code.items[switch_env_size_patch] = self.env_slot_count;
        }
    }

    fn compileReturn(self: *Compiler, s: ast.statement.ReturnStmt) CompileError!void {
        // §13.10.1 ReturnStatement Runtime Semantics:
        //   • `return;`                — exprValue is implicitly
        //     `undefined`, NO Await (step 1: return Completion with
        //     value undefined).
        //   • `return Expression;`     — evaluate Expression; if the
        //     enclosing function is async (regular async or async
        //     generator), `Await(exprValue)` before completing. The
        //     observable difference: explicit-form returns defer one
        //     microtask; bare `return;` settles synchronously inside
        //     the current task. (`return-undefined-implicit-and-
        //     explicit.js` asserts the tick gap.)
        const has_expr = s.argument != null;
        if (s.argument) |*arg| {
            try self.compileExpression(arg);
        } else {
            try self.builder.emitOp(.lda_undefined, s.span);
        }
        if (has_expr and self.current_is_async) {
            try self.builder.emitOp(.await_, s.span);
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
                // §7.4.6 — completion type here is `return`, not
                // `throw`: an inner throw from `return()` propagates;
                // a non-Object return value throws TypeError.
                try self.builder.emitU8(0);
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
        // §12.7 — bind by StringValue (decoded `\u…` escapes).
        const name_slice = try self.bindingName(fd.name.span);
        // Declare the binding FIRST so the function body can resolve
        // its own name (e.g. for recursion). With env-based scoping
        // the body sees `name` at depth=1, slot=this-slot.
        //
        // §14.2.5 / §14.12.4 — in strict mode (Cynic is strict-only)
        // ANY function declaration sitting inside a Block or
        // SwitchStatement case body is lex-scoped to that enclosing
        // block, not hoisted to the surrounding function / script.
        // Annex B B.3.3 web-compat hoisting (which would let plain
        // `function` leak out) is excluded by the strict-only target.
        const inside_block = self.scope.? != self.functionScope();
        const block_lex = inside_block;
        const binding_kind: BindingKind = if (block_lex) .let_ else .var_;
        var binding = try self.declareBindingFull(name_slice, binding_kind, fd.name.span);
        // §9.1.1.4.19 — top-level function decls overwrite the
        // descriptor on emit (data + writable+enumerable+non-
        // configurable). Block-lex function decls (binding_kind=.let_)
        // keep the ordinary lex init path.
        if (binding.is_global and binding_kind == .var_) {
            binding.is_function_decl = true;
        }
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
        // §9.1.1.4 InitializeBinding — function-decl hoist is the
        // initializer for its bound name. For block-lex function
        // decls (which use `.let_`) at the script top level the
        // global-init opcode applies; var-style function decls
        // route to the ordinary store path (they're hoisted as
        // var, which `emitStoreBindingInit` treats identically to
        // a regular `sta_global` write).
        try self.emitStoreBindingInit(binding, fd.span);
    }

    fn compileClassDecl(self: *Compiler, cd: ast.statement.ClassDecl) CompileError!void {
        // §12.7 — bind by StringValue.
        const name_slice = try self.bindingName(cd.name.span);
        // §15.7.1 / §13.2.1 — `class C {}` is a LexicallyScopedDeclaration:
        // the binding slot is pre-allocated by `hoistLetConst` so an
        // earlier-in-source-order inner function closing over `C` can
        // resolve to the binding and observe its TDZ Hole.
        // `lookupLocal` finds the hoisted binding; if the hoist
        // skipped this scope (Cynic also reaches `compileClassDecl`
        // from non-hoisting paths like switch-case bodies), fall
        // through to a fresh declare.
        const binding = self.scope.?.lookupLocal(name_slice) orelse
            try self.declareBindingFull(name_slice, .let_, cd.name.span);
        try self.emitClassBuild(name_slice, if (cd.superclass) |s| &s else null, cd.body, cd.span);
        try self.emitStoreBindingInit(binding, cd.span);
    }

    fn compileClassExpr(self: *Compiler, ce: ast.expression.ClassExpr) CompileError!void {
        // §12.7 — bind by StringValue when a name is present.
        const name_slice: ?[]const u8 = if (ce.name) |n| try self.bindingName(n.span) else null;
        try self.emitClassBuild(name_slice, ce.superclass, ce.body, ce.span);
    }

    /// Count `[expr]` computed keys across every method / field in
    /// `body` — must match the index-assignment walk in
    /// `compileClassTemplate`. Static blocks never contribute.
    fn countComputedKeys(body: []ast.statement.ClassMember) usize {
        var n: usize = 0;
        for (body) |member| switch (member) {
            .method => |m| if (m.key == .computed) {
                n += 1;
            },
            .field => |fd| if (fd.key == .computed) {
                n += 1;
            },
            .static_block => {},
        };
        return n;
    }

    /// §13.2.5 ComputedPropertyName + §15.7.14 ClassDefinitionEvaluation
    /// step 25 — emit the full make_class opcode sequence, including
    /// any `[expr]` computed-key evaluations and the heritage
    /// expression. Behaviour summary by class shape:
    ///
    ///   no heritage, no keys: `make_class k 0`
    ///   heritage, no keys:    `<heritage>; make_class k 0`
    ///   no heritage, keys:    `<key₀>; ToPropertyKey; star r₀; …;
    ///                          make_class k r₀`
    ///   heritage, keys:       `<heritage>; star r_h;
    ///                          <key₀>; ToPropertyKey; star r₀; …;
    ///                          ldar r_h; make_class k r₀`
    ///
    /// Key expressions emit inline in the enclosing function's
    /// bytecode (not a sub-chunk), so `yield` / `await` inside a
    /// computed key suspend the enclosing generator / async function —
    /// §27.5.3.7 GeneratorYield requires `f.generator != null`, which
    /// would not hold inside a sub-chunk's fresh frame.
    ///
    /// Returns the count of contiguous temps reserved (heritage stash
    /// + key block); caller must release them in the same order via
    /// `releaseTemp` once `make_class` has consumed them.
    fn emitMakeClass(
        self: *Compiler,
        template_idx: u16,
        superclass: ?*const Expression,
        body: []ast.statement.ClassMember,
        span: Span,
        /// §15.7.14 step 27.b — inner classScopeEnvRec slot index for
        /// the class binding (`C` in `class C { … }`). The interpreter
        /// uses this to publish the constructor into the inner env
        /// BEFORE static fields / blocks run, so a static initializer
        /// referencing `C` sees the binding live instead of in TDZ.
        /// Sentinel `0xFF` for anonymous classes (no inner env).
        inner_class_slot: u8,
    ) CompileError!usize {
        const key_count = countComputedKeys(body);

        // Fast path: no computed keys. Heritage lands in acc;
        // make_class ignores `r_keys_base` (template's `has_heritage`
        // gates acc).
        if (key_count == 0) {
            if (superclass) |s| try self.compileExpression(s);
            try self.builder.emitOp(.make_class, span);
            try self.builder.emitU16(template_idx);
            try self.builder.emitU8(0);
            try self.builder.emitU8(inner_class_slot);
            return 0;
        }

        // §15.7.14 step 6 — heritage evaluates before the
        // ClassElementList. Observable order matters when both have
        // side effects: `class extends side() { [other()](){} }`
        // calls `side` first, then `other`. Materialise heritage to
        // a temp so the per-key emit doesn't clobber it.
        var r_heritage: ?u8 = null;
        var reserved_count: usize = 0;
        if (superclass) |s| {
            try self.compileExpression(s);
            const r = try self.reserveTemp();
            reserved_count += 1;
            r_heritage = r;
            try self.builder.emitOp(.star, span);
            try self.builder.emitU8(r);
        }

        // Reserve a contiguous run of temps for the key block.
        // `reserveTemp` is monotonic; the run is addressable as
        // `r_keys_base + i`.
        const r_keys_base = try self.reserveTemp();
        reserved_count += 1;
        {
            var i: usize = 1;
            while (i < key_count) : (i += 1) {
                const r = try self.reserveTemp();
                reserved_count += 1;
                std.debug.assert(r == r_keys_base + i);
            }
        }

        var next_idx: usize = 0;
        for (body) |member| switch (member) {
            .method => |m| if (m.key == .computed) {
                try self.compileExpression(m.key.computed);
                try self.builder.emitOp(.to_property_key, m.span);
                try self.builder.emitOp(.star, m.span);
                try self.builder.emitU8(@intCast(r_keys_base + next_idx));
                next_idx += 1;
            },
            .field => |fd| if (fd.key == .computed) {
                try self.compileExpression(fd.key.computed);
                try self.builder.emitOp(.to_property_key, fd.span);
                try self.builder.emitOp(.star, fd.span);
                try self.builder.emitU8(@intCast(r_keys_base + next_idx));
                next_idx += 1;
            },
            .static_block => {},
        };
        std.debug.assert(next_idx == key_count);

        if (r_heritage) |rh| {
            try self.builder.emitOp(.ldar, span);
            try self.builder.emitU8(rh);
        }
        try self.builder.emitOp(.make_class, span);
        try self.builder.emitU16(template_idx);
        try self.builder.emitU8(r_keys_base);
        try self.builder.emitU8(inner_class_slot);
        return reserved_count;
    }

    /// Pair with `emitMakeClass`: release the temps reserved for the
    /// heritage stash and the key block, in LIFO order.
    fn releaseMakeClassTemps(self: *Compiler, reserved: usize) void {
        var i: usize = 0;
        while (i < reserved) : (i += 1) self.releaseTemp();
    }

    /// §15.7.1 ClassDefinitionEvaluation steps 8 / 27 — establish an
    /// inner declarative environment around the class body so methods
    /// close over a single, *immutable* `C` binding that's distinct
    /// from any outer mutable `C`. Without this scaffolding, a method
    /// like `class C { m() { return C; } }` resolves `C` to whatever
    /// the outer binding happens to hold at call time — and the
    /// outer is mutable, so `C = null; instance.m()` would surface
    /// `null` instead of the original class.
    ///
    /// Runtime layout (named-class case, no computed keys):
    ///
    ///     make_environment 1          // push class-env with 1 slot
    ///     [heritage] (if any)         // acc = parent ctor
    ///     make_class k 0              // methods capture class-env
    ///     sta_env 0 0                 // class fn → inner C slot
    ///     pop_env                     // back to enclosing env
    ///
    /// Anonymous class expression: no inner binding to create, so we
    /// skip the env push/pop entirely.
    fn emitClassBuild(
        self: *Compiler,
        name_slice: ?[]const u8,
        superclass: ?*const Expression,
        body: []ast.statement.ClassMember,
        span: Span,
    ) CompileError!void {
        const has_inner_name = name_slice != null;
        if (!has_inner_name) {
            // Anonymous `class { … }` expression. No `C` to see
            // from inside — `Function.prototype.toString` gives
            // the empty name. Skip the inner-env scaffolding and
            // pass the sentinel `0xFF` so make_class doesn't try
            // to publish into a non-existent inner binding.
            const k = try compileClassTemplate(self, name_slice, superclass, body, span);
            const reserved = try self.emitMakeClass(k, superclass, body, span, 0xFF);
            self.releaseMakeClassTemps(reserved);
            // §15.7.14 step 16 — the class's PrivateEnvironment spans
            // the full ClassTail eval; `compileClassTemplate` pushed
            // the class_stack frame and left it live for the computed-
            // key walk in `emitMakeClass`. Pop here.
            _ = self.class_stack.pop();
            return;
        }
        const name = name_slice.?;

        // Push the inner class scope. `has_own_env=true` so this
        // scope owns its own slot pool; methods bound inside it
        // get `env_depth = enclosing+1` and resolve `C` to the
        // single slot here. Save & reset the function-level
        // env_slot_count so the slot allocator counts WITHIN the
        // class env, then restore the outer counter on exit.
        var class_scope: Scope = .{ .parent = self.scope, .kind = .block, .has_own_env = true };
        defer class_scope.deinit(self.allocator);
        const saved_scope = self.scope;
        self.scope = &class_scope;
        defer self.scope = saved_scope;
        const saved_env_depth = self.env_depth;
        defer self.env_depth = saved_env_depth;
        const saved_slot_count = self.env_slot_count;
        self.env_slot_count = 0;
        defer self.env_slot_count = saved_slot_count;

        // §15.7.1 step 8 — `classScopeEnvRec.CreateImmutableBinding
        // (className, true)`. We model the immutable-ness via the
        // `const_` BindingKind so the compiler rejects `C = …`
        // *from inside the class body* at compile time.
        self.env_depth = saved_env_depth + 1;
        const inner_slot = try self.declareBinding(name, .const_, span);

        try self.builder.emitOp(.make_environment, span);
        try self.builder.emitU8(1);

        // Wrap the class-build (heritage eval, make_class with its
        // field-initializer + computed-key user-code re-entries)
        // in a synthetic handler that pops the inner env on throw
        // before rethrowing. Without this, a throwing static-field
        // initializer (or a throwing computed-key) would propagate
        // out of the make_class call with `f.env` still pointing
        // at the inner class env — leaking that env into the
        // enclosing handler's scope. The handler is emitted with
        // `is_finally=true` so it doesn't trip the `genReturn`
        // return-completion path (it's just bookkeeping).
        const build_start_pc = self.builder.here();
        // Compile every method / field template inside the inner
        // scope so they pick `C` up via Scope.resolve.
        const k = try compileClassTemplate(self, name_slice, superclass, body, span);
        // §15.7.14 step 27.b — pass the inner-env slot index for `C`
        // so make_class publishes the constructor into the binding
        // BEFORE static fields and static blocks run. The `inner_slot`
        // is always 0 here (the inner env has a single slot), but
        // make_class accepts the index symbolically for future-proofing.
        const reserved = try self.emitMakeClass(k, superclass, body, span, inner_slot);
        const build_end_pc = self.builder.here();
        self.releaseMakeClassTemps(reserved);
        // §15.7.14 step 16 — pop the class_stack frame left live by
        // `compileClassTemplate` for the computed-key walk above.
        _ = self.class_stack.pop();
        // The inner `C` slot was already published by make_class
        // (step 27.b) BEFORE static fields ran. The trailing
        // `sta_env` here is a no-op rewrite of the same slot to
        // the same value, kept for symmetry / robustness against
        // a future refactor that splits the publish step out of
        // make_class. Depth 0, slot `inner_slot` (always 0 today).
        try self.builder.emitOp(.sta_env, span);
        try self.builder.emitU8(0);
        try self.builder.emitU8(inner_slot);
        // Pop the class env. Methods captured the env at
        // `make_class` time; the JSEnvironment is kept alive
        // through that capture, so the pop only unlinks the
        // current frame.
        try self.builder.emitOp(.pop_env, span);
        // Jump past the synthetic-throw cleanup handler on the
        // normal-completion path.
        try self.builder.emitOp(.jmp, span);
        const skip_cleanup_patch = self.builder.here();
        try self.builder.emitI16(0);

        const cleanup_pc = self.builder.here();
        // The thrown value is deposited in `acc` (catch_register =
        // null). Pop the leaked inner env first, then rethrow.
        try self.builder.emitOp(.pop_env, span);
        try self.builder.emitOp(.throw_, span);
        try self.builder.addHandler(.{
            .start_pc = build_start_pc,
            .end_pc = build_end_pc,
            .handler_pc = cleanup_pc,
            .catch_register = null,
            // Marked `is_finally` so a generator's return-completion
            // (§27.5.1.3) doesn't get steered AWAY from this cleanup
            // — the env-pop must always run on the way out.
            .is_finally = true,
        });
        try self.builder.patchI16(skip_cleanup_patch, self.builder.here());
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

        // §15.7.14 step 11 — gather decoded `#name`s declared by this
        // class so private-name refs inside nested classes can walk
        // outward and find the *declaring* class's prefix.
        var private_names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        defer private_names_buf.deinit(self.allocator);
        for (body) |member| switch (member) {
            .method => |m| {
                const raw = switch (m.key) {
                    .private => |s| self.source[s.start..s.end],
                    .ident => |s| self.source[s.start..s.end],
                    else => continue,
                };
                if (raw.len == 0 or raw[0] != '#') continue;
                const decoded = try self.decodeIdentifierName(raw[1..]);
                var dup = false;
                for (private_names_buf.items) |n| if (std.mem.eql(u8, n, decoded)) {
                    dup = true;
                    break;
                };
                if (!dup) {
                    const owned = arena.dupe(u8, decoded) catch return error.OutOfMemory;
                    try private_names_buf.append(self.allocator, owned);
                }
            },
            .field => |fd| {
                if (fd.key != .private) continue;
                const raw = methodKeyName(self.source, fd.key) orelse continue;
                const decoded = try self.decodeIdentifierName(raw);
                var dup = false;
                for (private_names_buf.items) |n| if (std.mem.eql(u8, n, decoded)) {
                    dup = true;
                    break;
                };
                if (!dup) {
                    const owned = arena.dupe(u8, decoded) catch return error.OutOfMemory;
                    try private_names_buf.append(self.allocator, owned);
                }
            },
            .static_block => {},
        };
        const private_names_slice = arena.dupe([]const u8, private_names_buf.items) catch return error.OutOfMemory;

        // §15.7.14 step 16 — push onto the class stack so method
        // bodies / field initializers AND any `[expr]` computed keys
        // emitted by the caller's later `emitMakeClass` can resolve
        // `#name` references via `manglePrivateRef`. The compile-time
        // ClassPrivateEnvironment spans the whole ClassTail evaluation
        // — including the computed-key expressions that emit in the
        // enclosing function's bytecode (see emitMakeClass). The
        // caller is responsible for popping after make_class has been
        // emitted; we leave the frame live across `compileClassTemplate`'s
        // return so the computed-key walk in `emitMakeClass` still sees
        // this class's `#name` declarations. Without the spanning push,
        // a `[self.#f]` computed key would bail at `manglePrivateRef`'s
        // `class_stack.items.len > 0` assertion (empty stack) and the
        // surrounding `compileExpression` would return UnsupportedExpression.
        self.class_stack.append(self.allocator, .{
            .private_prefix = private_prefix,
            .is_derived = is_derived,
            .private_names = private_names_slice,
        }) catch return error.OutOfMemory;

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
                _ = is_priv;
                // §13.2.5 — computed-key methods can't be the
                // constructor (the name "constructor" isn't a
                // ComputedPropertyName the parser would route through
                // the static-name path). Count and emit; class.zig
                // resolves the runtime key.
                if (m.key == .computed) {
                    if (m.is_static) static_method_count += 1 else instance_method_count += 1;
                    continue;
                }
                const key_name = methodKeyName(self.source, m.key) orelse return error.UnsupportedStatement;
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
        // §15.7.14 step 34 — record the interleaved source order of
        // static fields + static blocks so the runtime evaluates them
        // in the spec-defined sequence (e.g. `static a = 1; static
        // { … } static b = 2;` runs field → block → field, not
        // field → field → block).
        var static_element_order = try self.allocator.alloc(u16, static_field_count + static_block_count);
        errdefer self.allocator.free(static_element_order);

        // §13.2.5 ComputedPropertyName — pre-walk `body` in source
        // order, assigning a sequential index to every method/field
        // whose key is `[expr]`. The emit walk in `emitClassBuild`
        // evaluates each key expression in the enclosing frame's
        // bytecode, `to_property_key`-coerces, and stashes the result
        // in a contiguous block of temps; both walks agree on the
        // slot per member through this side array.
        //
        // §15.7.14 step 25 PropertyDefinitionEvaluation iterates the
        // ClassElementList in source order, so this matches spec.
        //
        // Why inline rather than a sub-chunk: a key expression like
        // `[yield 9]` inside `function* g() { class C { [yield 9](){} } }`
        // must suspend the enclosing generator, not a private function
        // frame. Compiling the key into its own chunk (the previous
        // approach) put `gen_yield` in a non-generator frame and tripped
        // §27.5.3.7's `f.generator != null` assertion at runtime. Same
        // story for `await` in an async-module top-level class.
        var key_idx_for_pos = try self.allocator.alloc(i16, body.len);
        defer self.allocator.free(key_idx_for_pos);
        @memset(key_idx_for_pos, -1);
        var next_key_idx: i16 = 0;
        for (body, 0..) |member, pos| switch (member) {
            .method => |m| if (m.key == .computed) {
                key_idx_for_pos[pos] = next_key_idx;
                next_key_idx += 1;
            },
            .field => |fd| if (fd.key == .computed) {
                key_idx_for_pos[pos] = next_key_idx;
                next_key_idx += 1;
            },
            .static_block => {},
        };

        var i_if: usize = 0;
        var i_sf: usize = 0;
        var i_sb: usize = 0;
        var i_so: usize = 0;
        for (body, 0..) |member, pos| switch (member) {
            .field => |fd| {
                const fkey_index: i16 = key_idx_for_pos[pos];
                const key_name = blk: {
                    if (fd.key == .computed) {
                        break :blk "__cynic_computed__";
                    }
                    if (fd.key == .private) {
                        // `#x` — prefix with the class identity. Decode
                        // §12.7.1 escapes so `#\u{6F}` and `#o` share a
                        // single mangled key.
                        const raw = methodKeyName(self.source, fd.key) orelse return error.UnsupportedStatement;
                        const decoded_raw = try self.decodeIdentifierName(raw);
                        break :blk std.fmt.allocPrint(arena, "{s}{s}", .{ private_prefix, decoded_raw }) catch return error.OutOfMemory;
                    }
                    // Identifier / string-literal / numeric-literal
                    // class field name — decode escapes / canonicalize
                    // per §6.1.6.1.13 so `class C { 0x10 = 1 }` lives
                    // at `"16"`, `class C { "a\tb" = 1 }` at `"a<TAB>b"`.
                    break :blk try self.decodePropertyKeyName(fd.key);
                };
                // §15.7.10 / §IsAnonymousFunctionDefinition — for a
                // field initializer whose init is an anonymous function
                // / arrow / anonymous class, SetFunctionName uses the
                // field's textual key. For `#x` the name is `"#x"`
                // (the # prefix is part of the user-visible identifier
                // per §15.7's PrivateName treatment). Computed keys
                // would need a runtime `set_fn_name_from` — leave them
                // unnamed for now (this fixture only exercises static
                // text-keyed fields). The harness sees the spec
                // function name on `static #field = () => …` etc.
                const init_name: ?[]const u8 = blk_n: {
                    if (fd.key == .computed) break :blk_n null;
                    if (fd.key == .private) {
                        const raw = methodKeyName(self.source, fd.key) orelse break :blk_n null;
                        const decoded = try self.decodeIdentifierName(raw);
                        break :blk_n std.fmt.allocPrint(arena, "#{s}", .{decoded}) catch break :blk_n null;
                    }
                    break :blk_n try self.decodePropertyKeyName(fd.key);
                };
                const init_chunk: ?ChunkMod.Chunk = if (fd.init) |*init_expr|
                    try compileFieldInitChunk(self, init_expr, fd.span, init_name)
                else
                    null;
                const tmpl = ChunkMod.FieldTemplate{
                    .name = key_name,
                    .init_chunk = init_chunk,
                    .computed_key_index = fkey_index,
                };
                if (fd.is_static) {
                    // Record in source-order list. Low 15 bits hold
                    // the index into `static_fields`; high bit clear
                    // means "field".
                    static_element_order[i_so] = @intCast(i_sf);
                    i_so += 1;
                    static_fields[i_sf] = tmpl;
                    i_sf += 1;
                } else {
                    instance_fields[i_if] = tmpl;
                    i_if += 1;
                }
            },
            .static_block => |sb| {
                // Record in source-order list with high bit set
                // (block marker), low 15 bits = index into
                // `static_blocks`.
                static_element_order[i_so] = 0x8000 | @as(u16, @intCast(i_sb));
                i_so += 1;
                static_blocks[i_sb] = try compileStaticBlockChunk(self, sb.body, sb.span);
                i_sb += 1;
            },
            .method => {},
        };
        std.debug.assert(i_so == static_field_count + static_block_count);

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
        const ctor_spec_length: u8 = if (ctor_def) |c| computeSpecLength(c.params) else 0;
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
        for (body, 0..) |member, pos| switch (member) {
            .method => |m| {
                // §13.2.5 ComputedPropertyName — `class C { [expr]() {} }`.
                // The key expression has already been allocated a slot
                // index in `key_idx_for_pos` above; `emitClassBuild`
                // evaluates the expression inline in the enclosing
                // frame and `make_class` reads the coerced value from
                // the register file at runtime.
                const method_key_index: i16 = key_idx_for_pos[pos];
                const key_name: []const u8 = if (m.key == .computed) blk: {
                    break :blk "__cynic_computed__";
                } else blk: {
                    const raw_key = methodKeyName(self.source, m.key) orelse return error.UnsupportedStatement;
                    if (!m.is_static and std.mem.eql(u8, raw_key, "constructor")) {
                        // Constructor — skip (already compiled separately).
                        continue;
                    }
                    break :blk switch (m.key) {
                        .private => blk2: {
                            // §12.7.1 escapes decode for private names
                            // too — `#\u{6F}()` declares the same slot
                            // as `#o()`.
                            const decoded_raw = try self.decodeIdentifierName(raw_key);
                            break :blk2 std.fmt.allocPrint(arena, "{s}{s}", .{ private_prefix, decoded_raw }) catch return error.OutOfMemory;
                        },
                        // §12.7.1 — `\u…` escapes in IdentifierName decode
                        // to the source character, so `class C { if(){} }`
                        // installs `if`. §12.8.4 escapes in string-literal
                        // keys decode here too, and numeric literals route
                        // through §6.1.6.1.13 Number::toString — so
                        // `class C { get 0x10() {} }` installs `"16"`.
                        else => try self.decodePropertyKeyName(m.key),
                    };
                };
                // Computed-key constructor check needs to wait for
                // runtime; the static-name path handles it above.
                const method_chunk = try compileMethodBody(self, m.params, m.body.body, false, false, m.is_async, m.is_generator, m.span);
                const tmpl = ChunkMod.MethodTemplate{
                    .name = key_name,
                    .chunk = method_chunk,
                    .param_count = @intCast(m.params.len),
                    .spec_length = computeSpecLength(m.params),
                    .kind = switch (m.kind) {
                        .method => .method,
                        .getter => .getter,
                        .setter => .setter,
                    },
                    .is_generator = m.is_generator,
                    .is_async = m.is_async,
                    // §20.2.3.5 — borrow the MethodDefinition's source
                    // span for `Function.prototype.toString`. `source_start`
                    // points after the `static` modifier when present, so
                    // the slice matches the spec's MethodDefinition source.
                    .source = if (m.source_start <= m.span.end and m.span.end <= self.source.len)
                        self.source[m.source_start..m.span.end]
                    else
                        null,
                    .computed_key_index = method_key_index,
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
            .constructor_spec_length = ctor_spec_length,
            .instance_methods = instance_methods,
            .static_methods = static_methods,
            .instance_fields = instance_fields,
            .static_fields = static_fields,
            .static_blocks = static_blocks,
            .static_element_order = static_element_order,
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
            // §13.2.5 — numeric-literal class field names like
            // `class C { 0 = "bar"; 1.5 = "x"; }`. The slot key is
            // the source text's literal form (e.g. "0", "1.5"); the
            // ECMA-262 canonical-numeric-index normalisation happens
            // elsewhere (only for Array exotics).
            .numeric => |s| source[s.start..s.end],
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
        /// §IsAnonymousFunctionDefinition + §15.7.10 DefineField step
        /// 7 — when supplied, the init expression compiles through
        /// `compileNamedValue` so an anonymous function / arrow /
        /// anonymous class adopts the field's name (`#field` /
        /// `field` / etc.). `null` for computed keys (the runtime
        /// would need a `set_fn_name_from`-equivalent for those).
        init_name: ?[]const u8,
    ) CompileError!@import("chunk.zig").Chunk {
        const saved_builder = self.builder;
        const saved_scope = self.scope;
        const saved_env_slot_count = self.env_slot_count;
        const saved_temps_in_use = self.temps_in_use;
        const saved_env_depth = self.env_depth;
        const saved_current_loop = self.current_loop;

        self.builder = self.freshSubBuilder();
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
        if (init_name) |n| {
            try self.compileNamedValue(init_expr, n);
        } else {
            try self.compileExpression(init_expr);
        }
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

        self.builder = self.freshSubBuilder();
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

        self.builder = self.freshSubBuilder();
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

        // §10.4.4 + §10.2.10 step 22/27 — install `arguments`
        // BEFORE the param prologue so default expressions like
        // `constructor(x = arguments[2])` observe the full caller
        // argumentsList. See `compileFunctionTemplateExt` for the
        // spec citation.
        if (paramsReferenceArguments(self.source, params) or
            referencesArguments(self.source, body_stmts))
        {
            const slot = try self.declareBinding("arguments", .let_, span);
            try self.builder.emitOp(.lda_arguments, span);
            try self.builder.emitOp(.sta_env, span);
            try self.builder.emitU8(0);
            try self.builder.emitU8(slot);
        }

        // §10.2.4 IteratorBindingInitialization — reserve the leading
        // register slots so temps allocated by default-expression
        // compilation don't clobber caller-supplied arg registers.
        // See `compileFunctionTemplateExt` for the failure mode.
        const saved_ctor_prologue_temps = self.temps_in_use;
        self.temps_in_use = @intCast(@min(params.len, std.math.maxInt(u8)));
        if (self.temps_in_use > self.builder.register_count) {
            self.builder.register_count = self.temps_in_use;
        }
        for (params, 0..) |*p, i| {
            switch (p.*) {
                .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
                .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
            }
        }
        self.temps_in_use = saved_ctor_prologue_temps;

        // Base class: run field initializers at the start of the
        // user body. Derived classes wait for super_call to trigger.
        if (!is_derived and has_fields) {
            try self.builder.emitOp(.init_instance_fields, span);
        }

        // §13.3.2 — same pre-body sequence as `compileMethodBody`:
        // pre-declare let/const slots (TDZ), pre-declare every `var`
        // and `function` binding reachable through nested blocks, then
        // initialise every `var` to undefined so a forward `read`
        // never falls through to a parent scope. Without
        // hoistVarAndFunctions + emitVarInits, `class C { constructor() {
        // var x = 1; this.x = x; } }` raised CompileError because `x`
        // was undeclared at the use site.
        try self.hoistLetConst(body_stmts);
        try self.hoistVarAndFunctions(body_stmts);
        try self.emitVarInits(span);
        // Same two-pass order as the function path: function
        // declarations first (so later code can call them), then the
        // remaining statements.
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
        is_async: bool,
        is_generator: bool,
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
        const saved_is_async = self.current_is_async;

        self.builder = self.freshSubBuilder();
        var fn_scope: Scope = .{ .parent = self.scope, .kind = .function };
        self.scope = &fn_scope;
        self.env_slot_count = 0;
        self.temps_in_use = 0;
        self.env_depth = saved_env_depth + 1;
        self.current_loop = null;
        self.current_is_async = is_async;

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

        // §10.4.4 + §10.2.10 step 22/27 — install `arguments`
        // BEFORE the param prologue so default expressions like
        // `m(x = arguments[2])` observe the full caller
        // argumentsList. See `compileFunctionTemplateExt` for the
        // spec citation.
        if (paramsReferenceArguments(self.source, params) or
            referencesArguments(self.source, body_stmts))
        {
            const slot = try self.declareBinding("arguments", .let_, span);
            try self.builder.emitOp(.lda_arguments, span);
            try self.builder.emitOp(.sta_env, span);
            try self.builder.emitU8(0);
            try self.builder.emitU8(slot);
        }

        // Param prologue, same as compileFunctionTemplate. The
        // leading register slots are reserved so default-expression
        // temps don't clobber caller-supplied arg registers — see
        // `compileFunctionTemplateExt`.
        const saved_method_prologue_temps = self.temps_in_use;
        self.temps_in_use = @intCast(@min(params.len, std.math.maxInt(u8)));
        if (self.temps_in_use > self.builder.register_count) {
            self.builder.register_count = self.temps_in_use;
        }
        for (params, 0..) |*p, i| {
            switch (p.*) {
                .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
                .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
            }
        }
        self.temps_in_use = saved_method_prologue_temps;

        // §27.5 / §27.6 — generator methods suspend here so
        // `wrapGenerator` returns the wrapper after param init.
        if (is_generator) {
            try self.builder.emitOp(.gen_initial_suspend, span);
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
        self.current_is_async = saved_is_async;

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

        self.builder = self.freshSubBuilder();
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
            // sec-moduledeclarationinstantiation step 17 -- export <lexical-decl>
            // participates in the module's LexicallyScopedDeclarations the same way
            // the unwrapped form does. Recurse one level into
            // export_decl.body.declaration so `export let` / `export const`
            // get hoisted into the top-level lex env.
            const target: *const ast.statement.Statement = if (s.* == .export_decl) blk: {
                switch (s.export_decl.body) {
                    .declaration => |inner| break :blk inner,
                    else => continue,
                }
            } else s;
            // §15.7.1 ClassDeclaration — `class C {}` introduces a
            // mutable lexical binding for `C` in the enclosing scope.
            // §13.2.1 LexicallyScopedDeclarations counts it alongside
            // `let` / `const` for hoisting, so the binding is *visible*
            // (as a TDZ-Hole sentinel) before the class statement runs.
            // Module top-level `class C {}` must therefore behave the
            // same way `let C` does: an inner function `() => typeof C`
            // closing over `C` resolves to the lex binding and throws
            // ReferenceError on read instead of falling through to the
            // global-undef miss path. Treat class-decl as a let hoist.
            if (target.* == .class_decl) {
                const cd = target.class_decl;
                const name = try self.bindingName(cd.name.span);
                _ = try self.declareBindingFull(name, .let_, cd.name.span);
                continue;
            }
            if (target.* != .lexical) continue;
            const ld = target.lexical;
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
        // The body passed at the top-level call IS the function /
        // script body — statements at the function-top level get
        // regular var-style hoisting (including `function` decls).
        for (body) |*s| try self.hoistStatement(s, false);
    }

    /// §16.1.7 GlobalDeclarationInstantiation step 5-7 +
    /// CanDeclareGlobalVar / CanDeclareGlobalFunction (§9.1.1.4.15 /
    /// .16). Pure-validation walk over a Script body — does NOT
    /// mutate the realm. Reports duplicate / collision via
    /// `duplicate_lexical_binding` (SyntaxError) and sets
    /// `pending_global_decl_error` for canDeclare failures
    /// (deferred TypeError emitted in place of the script body).
    ///
    /// Walks the same shape as `hoistStatement` for var collection —
    /// recurses through Block / If / While / DoWhile / For /
    /// ForInOf / Try / Switch / ExportDecl — but doesn't follow into
    /// nested function / class bodies (those have their own scopes).
    fn validateGlobalDeclarations(self: *Compiler, body: []ast.statement.Statement) CompileError!void {
        if (self.is_module) return;

        // Collected names. Both sets are small in practice (a handful
        // of decls per script), so a linear-scan ArrayList beats the
        // bookkeeping cost of a HashSet.
        var lex_names: std.ArrayListUnmanaged(NameAtSpan) = .empty;
        defer lex_names.deinit(self.allocator);
        var var_names: std.ArrayListUnmanaged(NameAtSpan) = .empty;
        defer var_names.deinit(self.allocator);
        var fn_names: std.ArrayListUnmanaged(NameAtSpan) = .empty;
        defer fn_names.deinit(self.allocator);

        try collectScriptDeclNames(self, body, &lex_names, &var_names, &fn_names, false);

        // §16.1.7 step 5.b — lex-vs-lex duplicates. (lex-vs-var
        // covered by step 5.a below.) Tracked separately so a
        // pre-existing realm lex binding from a prior `evalScript`
        // also flags the duplicate per §9.1.1.4.18.
        for (lex_names.items, 0..) |a, i| {
            for (lex_names.items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    try self.report(.duplicate_lexical_binding, b.span);
                    return error.DuplicateBinding;
                }
            }
        }
        for (lex_names.items) |ln| {
            // §16.1.7 step 5.a — HasVarDeclaration: lex vs var on the
            // realm. The realm only tracks names through the object
            // env-record, so any prior `var` / `function` collides.
            if (self.realm.globals.hasVarDeclaration(ln.name)) {
                try self.report(.duplicate_lexical_binding, ln.span);
                return error.DuplicateBinding;
            }
            // §16.1.7 step 5.b — HasLexicalDeclaration: lex vs prior
            // lex on the realm.
            if (self.realm.globals.hasLexicalDeclaration(ln.name)) {
                try self.report(.duplicate_lexical_binding, ln.span);
                return error.DuplicateBinding;
            }
            // §16.1.7 step 5.c — HasRestrictedGlobalProperty: lex vs
            // non-configurable global property (e.g. `undefined`,
            // `NaN`, host-installed `Object.defineProperty(this, …,
            // {configurable:false})`).
            if (self.realm.globals.hasRestrictedGlobalProperty(ln.name) or
                isRestrictedGlobalName(ln.name))
            {
                try self.report(.duplicate_lexical_binding, ln.span);
                return error.DuplicateBinding;
            }
            // lex vs same-script var / function.
            for (var_names.items) |vn| if (std.mem.eql(u8, ln.name, vn.name)) {
                try self.report(.duplicate_lexical_binding, vn.span);
                return error.DuplicateBinding;
            };
            for (fn_names.items) |fn_n| if (std.mem.eql(u8, ln.name, fn_n.name)) {
                try self.report(.duplicate_lexical_binding, fn_n.span);
                return error.DuplicateBinding;
            };
        }

        // §16.1.7 step 6.a — vars (and function names) vs realm lex.
        for (var_names.items) |vn| {
            if (self.realm.globals.hasLexicalDeclaration(vn.name)) {
                try self.report(.duplicate_lexical_binding, vn.span);
                return error.DuplicateBinding;
            }
        }
        for (fn_names.items) |fn_n| {
            if (self.realm.globals.hasLexicalDeclaration(fn_n.name)) {
                try self.report(.duplicate_lexical_binding, fn_n.span);
                return error.DuplicateBinding;
            }
        }

        // §9.1.1.4.16 CanDeclareGlobalFunction for every function
        // declaration. Check this BEFORE the var canDeclare so the
        // `script-decl-func-err-non-configurable.js` fixture (which
        // pairs `var x; function data1() {}`) sees the function
        // failure win — though either order produces TypeError, the
        // failing-name carried into the error message matches V8's
        // when functions go first.
        for (fn_names.items) |fn_n| {
            if (!self.realm.globals.canDeclareGlobalFunction(fn_n.name)) {
                self.pending_global_decl_error = fn_n.name;
                return;
            }
        }

        // §9.1.1.4.15 CanDeclareGlobalVar — only meaningful when the
        // global object is non-extensible AND the name isn't already
        // a property. Skip names that also appear in `fn_names`: the
        // function-decl path handles them.
        for (var_names.items) |vn| {
            var is_func = false;
            for (fn_names.items) |fn_n| if (std.mem.eql(u8, vn.name, fn_n.name)) {
                is_func = true;
                break;
            };
            if (is_func) continue;
            if (!self.realm.globals.canDeclareGlobalVar(vn.name)) {
                self.pending_global_decl_error = vn.name;
                return;
            }
        }
    }

    const NameAtSpan = struct { name: []const u8, span: Span };

    fn collectScriptDeclNames(
        self: *Compiler,
        body: []ast.statement.Statement,
        lex_names: *std.ArrayListUnmanaged(NameAtSpan),
        var_names: *std.ArrayListUnmanaged(NameAtSpan),
        fn_names: *std.ArrayListUnmanaged(NameAtSpan),
        inside_block: bool,
    ) CompileError!void {
        for (body) |*s| try collectScriptDeclNamesOne(self, s, lex_names, var_names, fn_names, inside_block);
    }

    fn collectScriptDeclNamesOne(
        self: *Compiler,
        s: *ast.statement.Statement,
        lex_names: *std.ArrayListUnmanaged(NameAtSpan),
        var_names: *std.ArrayListUnmanaged(NameAtSpan),
        fn_names: *std.ArrayListUnmanaged(NameAtSpan),
        inside_block: bool,
    ) CompileError!void {
        switch (s.*) {
            .lexical => |ld| {
                if (ld.kind == .var_) {
                    if (inside_block) {
                        for (ld.declarators) |d|
                            try appendPatternVarNames(self, d.name, var_names);
                    } else {
                        for (ld.declarators) |d|
                            try appendPatternVarNames(self, d.name, var_names);
                    }
                } else if (!inside_block) {
                    // Only top-level lex binds reach the global lex
                    // record. Block-scoped `let` lives in the
                    // ordinary env and isn't validated here.
                    for (ld.declarators) |d|
                        try appendPatternLexNames(self, d.name, lex_names);
                }
            },
            .class_decl => |cd| {
                if (!inside_block) {
                    const name = try self.bindingName(cd.name.span);
                    try lex_names.append(self.allocator, .{ .name = name, .span = cd.name.span });
                }
            },
            .function_decl => |fd| {
                if (inside_block and (fd.is_async or fd.is_generator)) {
                    // §14.2.5 / §14.12.4 — async/gen function decls in
                    // nested blocks are lex-scoped to the block, not
                    // hoisted. Don't count toward global decls.
                    return;
                }
                if (inside_block) {
                    // §B.3.3 — Cynic is strict-only, so block-nested
                    // `function` doesn't hoist either. Skip global-
                    // decl tracking.
                    return;
                }
                const name = try self.bindingName(fd.name.span);
                try fn_names.append(self.allocator, .{ .name = name, .span = fd.name.span });
            },
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, inside_block),
                else => {},
            },
            .block => |b| {
                for (b.body) |*inner|
                    try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, true);
            },
            .if_ => |i| {
                try collectScriptDeclNamesOne(self, i.consequent, lex_names, var_names, fn_names, true);
                if (i.alternate) |alt|
                    try collectScriptDeclNamesOne(self, alt, lex_names, var_names, fn_names, true);
            },
            .while_ => |w| try collectScriptDeclNamesOne(self, w.body, lex_names, var_names, fn_names, true),
            .do_while => |dw| try collectScriptDeclNamesOne(self, dw.body, lex_names, var_names, fn_names, true),
            .for_ => |f| {
                if (f.init) |head| switch (head) {
                    .lexical => |ld| if (ld.kind == .var_) {
                        for (ld.declarators) |d|
                            try appendPatternVarNames(self, d.name, var_names);
                    },
                    .expression => {},
                };
                try collectScriptDeclNamesOne(self, f.body, lex_names, var_names, fn_names, true);
            },
            .for_in_of => |f| {
                switch (f.left) {
                    .lexical => |ld| if (ld.kind == .var_) {
                        for (ld.declarators) |d|
                            try appendPatternVarNames(self, d.name, var_names);
                    },
                    .expression => {},
                }
                try collectScriptDeclNamesOne(self, f.body, lex_names, var_names, fn_names, true);
            },
            .try_ => |t| {
                for (t.block.body) |*inner|
                    try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, true);
                if (t.handler) |h| for (h.body.body) |*inner|
                    try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, true);
                if (t.finalizer) |fin| for (fin.body) |*inner|
                    try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, true);
            },
            .switch_ => |sw| {
                for (sw.cases) |case| for (case.body) |*inner|
                    try collectScriptDeclNamesOne(self, inner, lex_names, var_names, fn_names, true);
            },
            // §14.13 LabelledStatement — transparent to declaration
            // collection; recurse into the wrapped body so a `var`
            // inside `lbl: do { … } while (0)` still reaches the
            // global-decl tally.
            .labeled => |lb| try collectScriptDeclNamesOne(self, lb.body, lex_names, var_names, fn_names, true),
            else => {},
        }
    }

    fn appendPatternVarNames(
        self: *Compiler,
        target: ast.statement.BindingTarget,
        var_names: *std.ArrayListUnmanaged(NameAtSpan),
    ) CompileError!void {
        switch (target) {
            .identifier => |id| {
                const name = try self.bindingName(id.span);
                try var_names.append(self.allocator, .{ .name = name, .span = id.span });
            },
            .array => |arr| {
                for (arr.elements) |maybe_elem| {
                    if (maybe_elem) |elem| try appendPatternVarNames(self, elem.target, var_names);
                }
                if (arr.rest) |rest| try appendPatternVarNames(self, rest.*, var_names);
            },
            .object => |obj| {
                for (obj.properties) |prop| try appendPatternVarNames(self, prop.value.target, var_names);
                if (obj.rest) |rest_id| {
                    const name = try self.bindingName(rest_id.span);
                    try var_names.append(self.allocator, .{ .name = name, .span = rest_id.span });
                }
            },
        }
    }

    fn appendPatternLexNames(
        self: *Compiler,
        target: ast.statement.BindingTarget,
        lex_names: *std.ArrayListUnmanaged(NameAtSpan),
    ) CompileError!void {
        switch (target) {
            .identifier => |id| {
                const name = try self.bindingName(id.span);
                try lex_names.append(self.allocator, .{ .name = name, .span = id.span });
            },
            .array => |arr| {
                for (arr.elements) |maybe_elem| {
                    if (maybe_elem) |elem| try appendPatternLexNames(self, elem.target, lex_names);
                }
                if (arr.rest) |rest| try appendPatternLexNames(self, rest.*, lex_names);
            },
            .object => |obj| {
                for (obj.properties) |prop| try appendPatternLexNames(self, prop.value.target, lex_names);
                if (obj.rest) |rest_id| {
                    const name = try self.bindingName(rest_id.span);
                    try lex_names.append(self.allocator, .{ .name = name, .span = rest_id.span });
                }
            },
        }
    }

    /// Emit a runtime `throw new TypeError(message)` sequence — used
    /// when §9.1.1.4.15 / .16 CanDeclareGlobalVar / CanDeclareGlobal
    /// Function returned false during validation. The chunk
    /// otherwise contains no user code, so any reachable observation
    /// from script source is suppressed.
    fn emitGlobalDeclThrow(self: *Compiler, name: []const u8, span: Span) CompileError!void {
        _ = name;
        const k_type_error = try self.internString("TypeError");
        const r_callee = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.lda_global, span);
        try self.builder.emitU16(k_type_error);
        try self.builder.emitOp(.star, span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitOp(.new_call, span);
        try self.builder.emitU8(r_callee);
        try self.builder.emitU8(0);
        try self.builder.emitOp(.throw_, span);
    }

    /// §9.1.1.4.5 HasRestrictedGlobalProperty — names whose global
    /// binding is created non-configurable by the host (`undefined`,
    /// `NaN`, `Infinity`). A script-mode `let` / `const` / `class`
    /// trying to bind one of these is a §16.1.7 step 5.c SyntaxError.
    fn isRestrictedGlobalName(name: []const u8) bool {
        return std.mem.eql(u8, name, "undefined") or
            std.mem.eql(u8, name, "NaN") or
            std.mem.eql(u8, name, "Infinity");
    }

    /// `inside_nested_block` is true when this statement is reached by
    /// recursive descent through a Block / SwitchCase / IfBranch / loop
    /// body / try-block / etc. — i.e. it's NOT a direct child of the
    /// enclosing function / script body. The flag gates strict-mode-
    /// only block scoping for `async` / `generator` / `async generator`
    /// function declarations (§14.2.5 / §14.12.4): those forms have
    /// never participated in Annex B web-compat hoisting, so even when
    /// the surrounding code might rely on legacy `var` visibility for
    /// plain `function`, the three async/gen forms in a nested block
    /// must NOT hoist to the enclosing function/script scope.
    fn hoistStatement(self: *Compiler, s: *ast.statement.Statement, inside_nested_block: bool) CompileError!void {
        switch (s.*) {
            .lexical => |ld| {
                if (ld.kind != .var_) return;
                for (ld.declarators) |d| {
                    try self.declarePatternVarBindings(d.name);
                }
            },
            .function_decl => |fd| {
                if (inside_nested_block) {
                    // §14.2.5 / §14.12.4 strict-mode block scope.
                    // ALL function-decl forms (plain, async, generator,
                    // async-generator) are lex-scoped to the enclosing
                    // block in strict mode — Cynic is strict-only and
                    // doesn't ship Annex B B.3.3 web-compat hoisting,
                    // so a `{ function f() {} }` at script top level
                    // must NOT make `f` visible outside the block.
                    // Leave it to `compileFunctionDecl` (which lex-
                    // binds via the current Scope) to install the
                    // binding at emission time.
                    return;
                }
                // §12.7 — declare against StringValue.
                const name = try self.bindingName(fd.name.span);
                _ = try self.declareBindingFull(name, .var_, fd.name.span);
            },
            // sec-moduledeclarationinstantiation step 17 -- function /
            // generator / async-function declarations exported via
            // `export <decl>` get hoisted into the module's lexical env
            // identically to the plain unwrapped forms. Without this, the
            // bound name lazily appears in source order and module cycles
            // observe `undefined` for the cross-reference.
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| try self.hoistStatement(inner, inside_nested_block),
                else => {},
            },
            .block => |b| for (b.body) |*inner| try self.hoistStatement(inner, true),
            .if_ => |i| {
                try self.hoistStatement(i.consequent, true);
                if (i.alternate) |alt| try self.hoistStatement(alt, true);
            },
            .while_ => |w| try self.hoistStatement(w.body, true),
            .do_while => |dw| try self.hoistStatement(dw.body, true),
            .for_ => |f| {
                if (f.init) |head| switch (head) {
                    .lexical => |ld| if (ld.kind == .var_) {
                        for (ld.declarators) |d| try self.declarePatternVarBindings(d.name);
                    },
                    .expression => {},
                };
                try self.hoistStatement(f.body, true);
            },
            .for_in_of => |f| {
                switch (f.left) {
                    .lexical => |ld| if (ld.kind == .var_) {
                        for (ld.declarators) |d| try self.declarePatternVarBindings(d.name);
                    },
                    .expression => {},
                }
                try self.hoistStatement(f.body, true);
            },
            .try_ => |t| {
                for (t.block.body) |*inner| try self.hoistStatement(inner, true);
                if (t.handler) |h| for (h.body.body) |*inner| try self.hoistStatement(inner, true);
                if (t.finalizer) |fin| for (fin.body) |*inner| try self.hoistStatement(inner, true);
            },
            .switch_ => |sw| {
                for (sw.cases) |case| for (case.body) |*inner| try self.hoistStatement(inner, true);
            },
            // §14.13 LabelledStatement — `LABEL : Statement` is
            // transparent to var-hoisting; the wrapped iteration /
            // block / etc. still contributes its `var` and function
            // declarations to the enclosing function / script scope.
            // Without this recursion, `lbl: do { var x; } while (0)`
            // would fail compileLexicalDecl's resolve() lookup with
            // UnresolvedReference because hoistStatement skipped the
            // body.
            .labeled => |lb| try self.hoistStatement(lb.body, true),
            // Nested function / class / arrow bodies have their own
            // function-like scope and are handled by their own
            // `hoistVarAndFunctions` call. Other statement shapes
            // (expression, return, throw, break, continue, debugger,
            // import / export) carry no `var` / function-decl
            // children we need to walk.
            else => {},
        }
    }

    fn declarePatternVarBindings(self: *Compiler, target: ast.statement.BindingTarget) CompileError!void {
        switch (target) {
            .identifier => |id| {
                const name = try self.bindingName(id.span);
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
                    const name = try self.bindingName(rest_id.span);
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
                const name = try self.bindingName(id.span);
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
                    const name = try self.bindingName(rest_id.span);
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
                        // §12.7 — `var` binding name is the StringValue.
                        const name = try self.bindingName(id.span);
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
                        // §14.3.2 — `var {a} = obj` is
                        // BindingInitialization (function-scoped),
                        // but `var` slots never start as Hole so
                        // the init flag is a no-op on this path.
                        try self.compileDestructure(d.name, true);
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
                    // §12.7 — `let`/`const` binding name is the StringValue.
                    const name = try self.bindingName(id.span);
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
                    // §9.1.1.4 InitializeBinding — initializer write,
                    // not assignment.
                    try self.emitStoreBindingInit(binding, d.span);
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
                    // §14.3.3 — `let` / `const` declarator pattern
                    // is BindingInitialization; leaf writes go
                    // through InitializeBinding (§9.1.1.4) and may
                    // legitimately overwrite the TDZ Hole.
                    try self.compileDestructure(d.name, true);
                },
            }
        }
    }

    /// Walk a destructuring pattern, assigning each leaf binding
    /// from the value currently in the accumulator. later
    /// supports shallow nesting; computed keys, rest elements, and
    /// rest-with-pattern are later.
    ///
    /// `is_init` distinguishes §14.3.3 BindingInitialization (a
    /// declarator like `let {a} = obj` — the leaf is an
    /// InitializeBinding §9.1.1.4 and legitimately overwrites the
    /// TDZ Hole) from §13.15.5 DestructuringAssignmentEvaluation
    /// (the LHS of `=` — the leaf is an ordinary PutValue and a
    /// Hole-slotted let / const must surface ReferenceError per
    /// §13.3.1). All current callers are declarator paths and pass
    /// `is_init = true`; the assignment-pattern form lives in
    /// `compileAssignmentPattern` and routes through
    /// `emitStoreBinding` directly.
    fn compileDestructure(self: *Compiler, target: ast.statement.BindingTarget, is_init: bool) CompileError!void {
        const r_src = try self.reserveTemp();
        defer self.releaseTemp();
        try self.builder.emitOp(.star, target.span());
        try self.builder.emitU8(r_src);

        switch (target) {
            .identifier => |id| {
                // Tolerated path for nested cases — declarators with
                // a plain ident name have already taken the direct
                // sta_env path above. §12.7 — bind by StringValue.
                const name = try self.bindingName(id.span);
                try self.builder.emitOp(.ldar, id.span);
                try self.builder.emitU8(r_src);
                try self.assignToBinding(name, id.span, is_init);
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
                        try self.assignPatternLeaf(elem.target, is_init);
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
                    try self.assignPatternLeaf(rest_target.*, is_init);
                } else {
                    // §7.4.10 IteratorClose — if the iter is not yet
                    // done (e.g. `[a, b] = source` where source has
                    // more than two elements), call `.return()`.
                    try self.builder.emitOp(.iter_close, target.span());
                    try self.builder.emitU8(r_iter);
                    // §7.4.6 — normal completion; propagate inner
                    // throws and TypeError on non-Object return.
                    try self.builder.emitU8(0);
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

                // §14.3.3.4 RestBindingInitialization — when the
                // pattern ends in `...rest`, allocate the excluded-key
                // array up front and fill one entry per BindingProperty
                // *as it is processed*. Building it inline (rather than
                // re-walking the AST in a second pass) is what lets a
                // computed key contribute its runtime post-ToPropertyKey
                // value — a second pass can only see source text, which
                // is why `{[expr]: x, ...rest}` used to fail to compile.
                // Mirrors the destructuring-assignment path.
                const r_excl_opt: ?u8 = if (obj_pat.rest != null) try self.reserveTemp() else null;
                defer if (r_excl_opt != null) self.releaseTemp();
                if (r_excl_opt) |r_excl| {
                    try self.builder.emitOp(.make_array, target.span());
                    try self.builder.emitOp(.star, target.span());
                    try self.builder.emitU8(r_excl);
                    const k_length = try self.internString("length");
                    try self.builder.emitOp(.lda_smi, target.span());
                    try self.builder.emitI32(@intCast(obj_pat.properties.len));
                    try self.builder.emitOp(.sta_property, target.span());
                    try self.builder.emitU16(k_length);
                    try self.builder.emitU8(r_excl);
                }

                var excl_idx: u32 = 0;
                for (obj_pat.properties) |prop| {
                    if (prop.key == .computed) {
                        // §14.3.3 BindingProperty : ComputedPropertyName
                        // BindingElement. Step 1: evaluate the key,
                        // ToPropertyKey-coerce. Step 2: GetV on
                        // `r_src`. The key expression is evaluated
                        // BEFORE the value is read, so a throwing
                        // `thrower()` key propagates without ever
                        // touching the value side (test262
                        // `obj-ptrn-prop-eval-err.case`).
                        try self.compileExpression(prop.key.computed);
                        try self.builder.emitOp(.to_property_key, prop.span);
                        const kr = try self.reserveTemp();
                        try self.builder.emitOp(.star, prop.span);
                        try self.builder.emitU8(kr);
                        // Pin the post-ToPropertyKey value into the rest
                        // exclusion list. `object_rest_from` honours
                        // string entries; a symbol key is harmless (a
                        // symbol-keyed property is excluded by it and
                        // matches by the symbol's `prop_key`).
                        if (r_excl_opt) |r_excl| {
                            try self.builder.emitOp(.ldar, prop.span);
                            try self.builder.emitU8(kr);
                            var ibuf: [16]u8 = undefined;
                            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{excl_idx}) catch unreachable;
                            const ik = try self.internString(islice);
                            try self.builder.emitOp(.sta_property, prop.span);
                            try self.builder.emitU16(ik);
                            try self.builder.emitU8(r_excl);
                            excl_idx += 1;
                        }
                        try self.builder.emitOp(.ldar, prop.span);
                        try self.builder.emitU8(kr);
                        try self.builder.emitOp(.lda_computed, prop.span);
                        try self.builder.emitU8(r_src);
                        self.releaseTemp(); // kr
                        try self.applyDefaultIfNeeded(prop.value);
                        try self.assignPatternLeaf(prop.value.target, is_init);
                        continue;
                    }
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
                        if (prop.key == .ident) {
                            break :blk try self.decodeIdentifierName(self.source[key_span.start..key_span.end]);
                        }
                        // §13.2.5.4 PropertyDefinitionEvaluation step 2 —
                        // `LiteralPropertyName : NumericLiteral` returns
                        // `! ToString(NumericValue)`. The raw source
                        // `1n` / `0x10` / `1e2` must canonicalise to
                        // the property key Cynic actually stored
                        // (`"1"` / `"16"` / `"100"`). Without this
                        // `let {1n: a} = {1: …}` reads at `"1n"` and
                        // misses.
                        break :blk try self.canonicalNumericKey(self.source[key_span.start..key_span.end]);
                    };
                    const k = try self.internString(key_slice);
                    // Record the static key in the exclusion list at
                    // first-pass time so the rest sees the same
                    // exclusions regardless of any user-getter side
                    // effects fired by the matching `lda_property`.
                    if (r_excl_opt) |r_excl| {
                        try self.builder.emitOp(.lda_constant, prop.span);
                        try self.builder.emitU16(k);
                        var ibuf: [16]u8 = undefined;
                        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{excl_idx}) catch unreachable;
                        const ik = try self.internString(islice);
                        try self.builder.emitOp(.sta_property, prop.span);
                        try self.builder.emitU16(ik);
                        try self.builder.emitU8(r_excl);
                        excl_idx += 1;
                    }
                    try self.builder.emitOp(.ldar, prop.span);
                    try self.builder.emitU8(r_src);
                    try self.builder.emitOp(.lda_property, prop.span);
                    try self.builder.emitU16(k);
                    try self.applyDefaultIfNeeded(prop.value);
                    try self.assignPatternLeaf(prop.value.target, is_init);
                }
                if (obj_pat.rest) |rest_id| {
                    // §14.3.3.4 RestElement — collect every own
                    // enumerable property of `r_src` not in the
                    // excluded list into a fresh object.
                    try self.builder.emitOp(.object_rest_from, target.span());
                    try self.builder.emitU8(r_src);
                    try self.builder.emitU8(r_excl_opt.?);
                    const rest_name = self.source[rest_id.span.start..rest_id.span.end];
                    try self.assignToBinding(rest_name, rest_id.span, is_init);
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

                // §13.15.5.2 ArrayAssignmentPattern step 5 — if any
                // abrupt completion (throw OR return-completion in a
                // generator) escapes the destructure walk and the
                // iterator is not yet [[Done]], IteratorClose must run.
                // Wrap from just after iter_open through the trailing
                // close/drain in a synthetic handler that calls
                // iter_close r_iter in throw mode and rethrows.
                const handler_start_pc = self.builder.here();

                for (al.elements[0..elem_count]) |maybe_elt| {
                    if (maybe_elt) |elt| {
                        // §13.15.5.4 IteratorDestructuringAssignmentEval
                        // step 5 — when AssignmentElement.target is not
                        // an Object/ArrayLiteral, evaluate the LHS
                        // reference BEFORE pulling the next value from
                        // the iterator. Mirror of the object-pattern
                        // pre-eval above.
                        const leaf_target = destructureLeafTarget(elt);
                        const prepared = try self.prepareAssignmentLeaf(leaf_target);
                        try self.builder.emitOp(.iter_step, target.span());
                        try self.builder.emitU8(r_iter);
                        try self.builder.emitU8(r_done);
                        try self.assignAssignmentPatternElemPrepared(elt, prepared);
                        self.releasePreparedLeaf(prepared);
                    } else {
                        // Elision — step and discard.
                        try self.builder.emitOp(.iter_step, target.span());
                        try self.builder.emitU8(r_iter);
                        try self.builder.emitU8(r_done);
                    }
                }

                if (rest_arg) |arg| {
                    // §13.15.5.3 AssignmentRestElement step 1 — when the
                    // rest target is neither an ObjectLiteral nor an
                    // ArrayLiteral, evaluate its LHS reference BEFORE
                    // draining the iterator (so a throwing lref —
                    // `[...{}[thrower()]]` — fires before any further
                    // iter_step). Inner pattern leaves walk through the
                    // assignAssignmentPatternLeaf branch and don't need
                    // pre-eval here.
                    const rest_inner = blk: {
                        var t = arg.*;
                        while (t == .parenthesized) t = t.parenthesized.expression.*;
                        break :blk t;
                    };
                    const rest_is_pattern = rest_inner == .array_literal or rest_inner == .object_literal;
                    const rest_prepared: PreparedLeaf = if (rest_is_pattern)
                        .none
                    else
                        try self.prepareAssignmentLeaf(arg.*);

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
                    if (rest_is_pattern) {
                        try self.assignAssignmentPatternLeaf(arg.*);
                    } else {
                        try self.assignAssignmentPatternElemPrepared(arg.*, rest_prepared);
                        self.releasePreparedLeaf(rest_prepared);
                    }
                }

                // Mark the end of the handler region BEFORE emitting the
                // trailing normal-completion `iter_close`. The normal
                // close itself propagates inner throws (mode=0); having
                // it covered by our synthetic handler would double-close
                // — `return()` would fire twice (test262
                // array-empty-iter-close-err.js asserts returnCount=1).
                const handler_end_pc = self.builder.here();
                if (rest_arg == null) {
                    // §7.4.10 — close iter if still open.
                    try self.builder.emitOp(.iter_close, target.span());
                    try self.builder.emitU8(r_iter);
                    // §7.4.6 — normal completion; propagate inner
                    // throws and TypeError on non-Object return.
                    try self.builder.emitU8(0);
                }

                // §13.15.5.2 step 5 / §27.5.1.3 — abrupt completion
                // escaping the destructure walk while the iterator is
                // not [[Done]] must IteratorClose. Two handlers cover
                // the same region:
                //
                //   • Throw-mode (`is_finally=false`, iter_close mode=1)
                //     — outer throw wins per §7.4.6 step 7; inner
                //     return() errors are swallowed.
                //   • Return-mode (`is_finally=true`, iter_close mode=0)
                //     — `unwindThrow` routes generator-return completions
                //     here (it skips non-finally handlers while
                //     `gen_return_completion` is set). Treat the
                //     completion as normal/return per §7.4.6 step 8/9:
                //     inner throws propagate, non-Object return result
                //     surfaces TypeError.
                //
                // Order matters — the non-finally entry must come first
                // so a true throw lands on it (without `is_finally`
                // discrimination throws would match either handler).
                try self.builder.emitOp(.jmp, target.span());
                const skip_handlers_patch = self.builder.here();
                try self.builder.emitI16(0);

                const throw_handler_pc = self.builder.here();
                const r_caught_throw = try self.reserveTemp();
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_caught_throw);
                try self.builder.emitOp(.iter_close, target.span());
                try self.builder.emitU8(r_iter);
                try self.builder.emitU8(1);
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_caught_throw);
                try self.builder.emitOp(.throw_, target.span());
                self.releaseTemp();

                const return_handler_pc = self.builder.here();
                const r_caught_ret = try self.reserveTemp();
                try self.builder.emitOp(.star, target.span());
                try self.builder.emitU8(r_caught_ret);
                try self.builder.emitOp(.iter_close, target.span());
                try self.builder.emitU8(r_iter);
                try self.builder.emitU8(0);
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_caught_ret);
                try self.builder.emitOp(.throw_, target.span());
                self.releaseTemp();

                try self.builder.patchI16(skip_handlers_patch, self.builder.here());
                try self.builder.addHandler(.{
                    .start_pc = handler_start_pc,
                    .end_pc = handler_end_pc,
                    .handler_pc = throw_handler_pc,
                    .catch_register = null,
                    .is_finally = false,
                });
                try self.builder.addHandler(.{
                    .start_pc = handler_start_pc,
                    .end_pc = handler_end_pc,
                    .handler_pc = return_handler_pc,
                    .catch_register = null,
                    .is_finally = true,
                });
            },
            .object_literal => |ol| {
                // §13.15.5.4 — assignment to an object pattern
                // requires the source be ToObject-coercible. `({} = null)`
                // throws TypeError; emit the guard before any property
                // reads (and before the empty-pattern early exit).
                try self.builder.emitOp(.ldar, target.span());
                try self.builder.emitU8(r_src);
                try self.builder.emitOp(.require_object_coercible, target.span());

                // Pre-allocate the rest exclusion array when the pattern
                // ends in `...rest`. We populate it during the first
                // pass so a computed key's *runtime* value (post-
                // ToPropertyKey) is what excludes — not the source-text
                // form. V8 / JSC do the same via CopyDataPropertiesWith-
                // ExcludedProperties: each bound key contributes one
                // exclusion entry resolved when it's evaluated.
                var rest_arg: ?*ast.expression.Expression = null;
                var rest_span: Span = target.span();
                var bound_count: i32 = 0;
                for (ol.properties) |p2| switch (p2) {
                    .property => bound_count += 1,
                    .spread => |sp| {
                        rest_arg = sp.argument;
                        rest_span = sp.span;
                    },
                    .method => return error.UnsupportedExpression,
                };

                const r_excl_opt: ?u8 = if (rest_arg != null) try self.reserveTemp() else null;
                defer if (r_excl_opt != null) self.releaseTemp();
                if (r_excl_opt) |r_excl| {
                    try self.builder.emitOp(.make_array, rest_span);
                    try self.builder.emitOp(.star, rest_span);
                    try self.builder.emitU8(r_excl);
                    const k_length = try self.internString("length");
                    try self.builder.emitOp(.lda_smi, rest_span);
                    try self.builder.emitI32(bound_count);
                    try self.builder.emitOp(.sta_property, rest_span);
                    try self.builder.emitU16(k_length);
                    try self.builder.emitU8(r_excl);
                }

                // Object pattern leaves can include `{...rest}` —
                // the parser parses that as a `.spread` property
                // member with an identifier_reference argument.
                var excl_idx: u32 = 0;
                for (ol.properties) |prop| switch (prop) {
                    .property => |op| {
                        // §13.15.5.5 AssignmentProperty : PropertyName :
                        // AssignmentElement — step 1 evaluates PropertyName
                        // FIRST (so a computed key's side effects fire
                        // before the AssignmentElement's lref-eval below),
                        // step 3 forwards to KeyedDestructuringAssignment-
                        // Evaluation. For a computed key we stash the
                        // ToPropertyKey'd value into a temp; for a plain
                        // ident / string / numeric key the key is a
                        // compile-time string constant.
                        var src_key_r: ?u8 = null;
                        if (op.key == .computed) {
                            try self.compileExpression(op.key.computed);
                            try self.builder.emitOp(.to_property_key, op.span);
                            const r = try self.reserveTemp();
                            try self.builder.emitOp(.star, op.span);
                            try self.builder.emitU8(r);
                            src_key_r = r;
                            // Pin the computed key (its post-ToPropertyKey
                            // value) into the rest exclusion list. The
                            // runtime side honours string entries; symbol
                            // keys aren't copied by `object_rest_from`
                            // anyway, so a symbol key in the list is
                            // harmless (the matching property won't be
                            // copied either).
                            if (r_excl_opt) |r_excl| {
                                try self.builder.emitOp(.ldar, op.span);
                                try self.builder.emitU8(r);
                                var ibuf: [16]u8 = undefined;
                                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{excl_idx}) catch unreachable;
                                const ik = try self.internString(islice);
                                try self.builder.emitOp(.sta_property, op.span);
                                try self.builder.emitU16(ik);
                                try self.builder.emitU8(r_excl);
                                excl_idx += 1;
                            }
                        } else if (r_excl_opt) |r_excl| {
                            // Static key — record by its decoded textual
                            // key. Done at first-pass time so the rest
                            // sees the same exclusions regardless of any
                            // user-getter side effects fired by the
                            // matching `lda_property` below.
                            const ks = try self.assignmentPatternKey(op.key);
                            const kk = try self.internString(ks);
                            try self.builder.emitOp(.lda_constant, op.span);
                            try self.builder.emitU16(kk);
                            var ibuf: [16]u8 = undefined;
                            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{excl_idx}) catch unreachable;
                            const ik = try self.internString(islice);
                            try self.builder.emitOp(.sta_property, op.span);
                            try self.builder.emitU16(ik);
                            try self.builder.emitU8(r_excl);
                            excl_idx += 1;
                        }
                        // §13.15.5.6 KeyedDestructuringAssignmentEval
                        // step 1 — when the inner DestructuringAssignment-
                        // Target is neither an Object/ArrayLiteral,
                        // evaluate its LHS reference BEFORE the source
                        // `GetV`. For `({a: this.#field} = src)` this
                        // resolves `this` (throws in a pre-`super()`
                        // derived ctor) and the private-name slot before
                        // the `src.a` getter runs.
                        const leaf_target = destructureLeafTarget(op.value);
                        const prepared = try self.prepareAssignmentLeaf(leaf_target);
                        if (src_key_r) |kr| {
                            // step 2 — GetV(value, propertyName).
                            try self.builder.emitOp(.ldar, op.span);
                            try self.builder.emitU8(kr);
                            try self.builder.emitOp(.lda_computed, op.span);
                            try self.builder.emitU8(r_src);
                            try self.assignAssignmentPatternElemPrepared(op.value, prepared);
                            self.releasePreparedLeaf(prepared);
                            self.releaseTemp(); // src_key_r
                            continue;
                        }
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
                        // `assignAssignmentPatternElemPrepared`.
                        try self.assignAssignmentPatternElemPrepared(op.value, prepared);
                        self.releasePreparedLeaf(prepared);
                    },
                    .spread => {},
                    .method => return error.UnsupportedExpression,
                };

                if (rest_arg) |rt| {
                    // §13.15.5 RestElement on object pattern — collect
                    // every own enumerable property of `r_src` not in
                    // the excluded list (`r_excl`) into a fresh object.
                    try self.builder.emitOp(.object_rest_from, rest_span);
                    try self.builder.emitU8(r_src);
                    try self.builder.emitU8(r_excl_opt.?);
                    try self.assignAssignmentPatternLeaf(rt.*);
                }
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
                    // §12.7 — `SetFunctionName` uses the StringValue.
                    break :blk try self.bindingName(t.identifier_reference.span);
                }
                break :blk null;
            };
            try self.applyDefaultExprNamed(elt.assignment.value, elt.assignment.span, named_target);
            try self.assignAssignmentPatternLeaf(elt.assignment.target.*);
            return;
        }
        try self.assignAssignmentPatternLeaf(elt);
    }

    /// §13.15.5.4 / §13.15.5.6 step 1 — when a DestructuringAssignment
    /// target is neither an ObjectLiteral nor an ArrayLiteral, its LHS
    /// reference must be evaluated BEFORE the source value is read.
    /// For `({a: this.#field} = src)` that resolves the receiver and
    /// the private name first; in a derived ctor before `super()`,
    /// reading `this` throws ReferenceError per §9.1.1.3.4 before the
    /// `src.a` getter ever runs.
    const PreparedMember = struct {
        span: Span,
        r_obj: u8,
        /// `r_key` is set iff `key` is `.computed`; the key was
        /// evaluated and stored in this temp BEFORE the source read.
        r_key: ?u8,
        key: union(enum) {
            name: u16,
            private: u16,
            computed: void,
        },
    };

    const PreparedLeaf = union(enum) {
        /// Leaf has no observable LHS side effects until store time —
        /// identifier_reference targets (just a binding write) and
        /// nested patterns (their own evaluation order is spec-
        /// correct) fall through to the regular leaf-write path.
        none,
        /// Member-target leaf with the receiver (and possibly key)
        /// already evaluated and stashed in `r_obj` (+ `r_key`).
        member: PreparedMember,
    };

    /// Evaluate the LHS reference of a destructuring leaf eagerly,
    /// stashing the receiver (and key for computed members) in fresh
    /// temps. Returns a `PreparedLeaf` whose temps must be released
    /// by `releasePreparedLeaf` after the matching `storePreparedLeaf`
    /// call. Per §13.15.5.6 step 1.a / §13.15.5.4 step 5 this MUST
    /// run before the source side is touched.
    fn prepareAssignmentLeaf(self: *Compiler, target: ast.expression.Expression) CompileError!PreparedLeaf {
        var t = target;
        while (t == .parenthesized) t = t.parenthesized.expression.*;
        switch (t) {
            .member => |m| {
                if (m.optional) return error.UnsupportedExpression;
                if (m.object.* == .super_) return error.UnsupportedExpression;
                // §13.3.2 — evaluate the object expression and pin
                // the receiver before anything else.
                try self.compileExpression(m.object);
                const r_obj = try self.reserveTemp();
                try self.builder.emitOp(.star, m.span);
                try self.builder.emitU8(r_obj);
                switch (m.property) {
                    .ident => |kspan| {
                        const raw = self.source[kspan.start..kspan.end];
                        if (raw.len > 0 and raw[0] == '#') {
                            // §13.2.7.3 — mangle the private identifier
                            // against the current class's private
                            // prefix at compile time. The brand check
                            // happens later, at `sta_private` time.
                            if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                            // §15.7.14 step 11 — lexical lookup.
                            const decoded = try self.decodeIdentifierName(raw[1..]);
                            const mangled = try self.manglePrivateRef(decoded);
                            const k = try self.internString(mangled);
                            return .{ .member = .{ .span = m.span, .r_obj = r_obj, .r_key = null, .key = .{ .private = k } } };
                        }
                        const key_slice = try self.decodeIdentifierName(raw);
                        const k = try self.internString(key_slice);
                        return .{ .member = .{ .span = m.span, .r_obj = r_obj, .r_key = null, .key = .{ .name = k } } };
                    },
                    .computed => |key_expr| {
                        // §13.3.3 — the computed-key expression is
                        // part of the LHS reference and is evaluated
                        // as part of step 1. Stash before source read.
                        try self.compileExpression(key_expr);
                        const r_key = try self.reserveTemp();
                        try self.builder.emitOp(.star, m.span);
                        try self.builder.emitU8(r_key);
                        return .{ .member = .{ .span = m.span, .r_obj = r_obj, .r_key = r_key, .key = .computed } };
                    },
                }
            },
            else => return .none,
        }
    }

    /// Emit the store half of a prepared leaf: `acc` holds the final
    /// value (post-default-application). For `.none` leaves we route
    /// back through the regular leaf-write helper.
    fn storePreparedLeaf(self: *Compiler, target: ast.expression.Expression, prepared: PreparedLeaf) CompileError!void {
        switch (prepared) {
            .none => try self.assignAssignmentPatternLeaf(target),
            .member => |pm| {
                // `acc` = value. Stash, then re-load to feed the
                // store op (the named/private/computed store ops take
                // value in `acc`).
                const r_value = try self.reserveTemp();
                defer self.releaseTemp();
                try self.builder.emitOp(.star, pm.span);
                try self.builder.emitU8(r_value);
                try self.builder.emitOp(.ldar, pm.span);
                try self.builder.emitU8(r_value);
                switch (pm.key) {
                    .name => |k| {
                        try self.builder.emitOp(.sta_property, pm.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(pm.r_obj);
                    },
                    .private => |k| {
                        try self.builder.emitOp(.sta_private, pm.span);
                        try self.builder.emitU16(k);
                        try self.builder.emitU8(pm.r_obj);
                    },
                    .computed => {
                        try self.builder.emitOp(.sta_computed, pm.span);
                        try self.builder.emitU8(pm.r_obj);
                        try self.builder.emitU8(pm.r_key.?);
                    },
                }
            },
        }
    }

    /// Release the temps reserved by `prepareAssignmentLeaf`, in
    /// reverse order. Must be called after the matching
    /// `storePreparedLeaf`.
    fn releasePreparedLeaf(self: *Compiler, prepared: PreparedLeaf) void {
        switch (prepared) {
            .none => {},
            .member => |pm| {
                if (pm.r_key != null) self.releaseTemp();
                self.releaseTemp();
            },
        }
    }

    /// Variant of `assignAssignmentPatternElem` that integrates with
    /// a pre-evaluated LHS reference. `acc` holds the property value
    /// read from the source; apply any default, then store into the
    /// prepared ref.
    fn assignAssignmentPatternElemPrepared(
        self: *Compiler,
        elt: ast.expression.Expression,
        prepared: PreparedLeaf,
    ) CompileError!void {
        if (elt == .assignment and elt.assignment.op == .eq) {
            const named_target: ?[]const u8 = blk: {
                var t = elt.assignment.target;
                while (t.* == .parenthesized) t = t.parenthesized.expression;
                if (t.* == .identifier_reference) {
                    // §12.7 — `SetFunctionName` uses the StringValue.
                    break :blk try self.bindingName(t.identifier_reference.span);
                }
                break :blk null;
            };
            try self.applyDefaultExprNamed(elt.assignment.value, elt.assignment.span, named_target);
            try self.storePreparedLeaf(elt.assignment.target.*, prepared);
            return;
        }
        try self.storePreparedLeaf(elt, prepared);
    }

    /// Extract the underlying assignment-target from an element node.
    /// The parser wraps `{x: target = default}` as
    /// `assignment(eq, target, default)`; the LHS-eval-order rule
    /// applies to `target`, not to the synthetic assignment node.
    fn destructureLeafTarget(elt: ast.expression.Expression) ast.expression.Expression {
        if (elt == .assignment and elt.assignment.op == .eq) {
            return elt.assignment.target.*;
        }
        return elt;
    }

    /// Assign `acc` to the LHS-shaped Expression. Leaves may be
    /// identifier_reference, member, parenthesized, or further
    /// destructuring patterns.
    fn assignAssignmentPatternLeaf(self: *Compiler, target: ast.expression.Expression) CompileError!void {
        switch (target) {
            .identifier_reference => |ir| {
                // §12.7 — assignment-pattern leaf resolves by StringValue.
                const name = try self.bindingName(ir.span);
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
                if (raw.len > 0 and raw[0] == '#') {
                    // §13.2.7 / §7.3.30 PrivateFieldSet — destructuring
                    // LHS like `({...this.#x} = src)` or `({a: this.#x} = src)`
                    // routes the store through the runtime brand check.
                    // Without this branch, the compiler bails on the
                    // member walk and the fixture surfaces a CompileError
                    // instead of the spec's runtime TypeError.
                    if (self.class_stack.items.len == 0) return error.UnsupportedExpression;
                    const decoded = try self.decodeIdentifierName(raw[1..]);
                    const mangled = try self.manglePrivateRef(decoded);
                    const k = try self.internString(mangled);
                    try self.builder.emitOp(.ldar, span);
                    try self.builder.emitU8(r_value);
                    try self.builder.emitOp(.sta_private, span);
                    try self.builder.emitU16(k);
                    try self.builder.emitU8(r_obj);
                    return;
                }
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
        return self.decodePropertyKeyName(key);
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
            // §12.7 — bind by StringValue.
            const param_name = try self.bindingName(rp.target.identifier.span);
            const slot = try self.declareParam(param_name, rp.span);
            try self.builder.emitOp(.rest_args_from, rp.span);
            try self.builder.emitU8(start_index);
            try self.builder.emitOp(.sta_env, rp.span);
            try self.builder.emitU8(0);
            try self.builder.emitU8(slot);
        } else {
            try self.declarePatternBindings(rp.target, .let_);
            try self.builder.emitOp(.rest_args_from, rp.span);
            try self.builder.emitU8(start_index);
            // §10.2.3 — rest-parameter binding is
            // InitializeBinding on the freshly-declared param slots.
            try self.compileDestructure(rp.target, true);
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
            // §12.7 — bind by StringValue.
            const param_name = try self.bindingName(sp.target.identifier.span);
            const slot = try self.declareParam(param_name, sp.span);
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
            // §15.2 — simple-param destructuring is
            // InitializeBinding on the param slots.
            try self.compileDestructure(sp.target, true);
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

    fn assignPatternLeaf(self: *Compiler, target: ast.statement.BindingTarget, is_init: bool) CompileError!void {
        switch (target) {
            .identifier => |id| {
                // §12.7 — bind by StringValue.
                const name = try self.bindingName(id.span);
                try self.assignToBinding(name, id.span, is_init);
            },
            .array, .object => try self.compileDestructure(target, is_init),
        }
    }

    fn assignToBinding(self: *Compiler, name: []const u8, span: Span, is_init: bool) CompileError!void {
        const scope = self.scope orelse return error.UnresolvedReference;
        // §13.7.5.13 ForIn/OfBodyEvaluation step 5.h.i — `Let lhsRef be
        // ? Evaluation of lhs`. For an unresolved bare identifier, the
        // spec resolves to an unresolvable Reference and `PutValue`
        // throws ReferenceError at runtime (strict mode). Cynic-side:
        // synthesise a global binding so the for-of/for-in LHS emits the
        // same `sta_global_strict` shape as `x = e` does — fixtures with
        // a never-entered loop (e.g. `for (k in undefined)`) compile and
        // run without raising the runtime ReferenceError.
        const binding = scope.resolve(name) orelse Binding{
            .name = name,
            .env_slot = 0,
            .env_depth = 0,
            .kind = .var_,
            .span = span,
            .is_global = true,
        };
        if (is_init) {
            try self.emitStoreBindingInit(binding, span);
        } else {
            try self.emitStoreBinding(binding, span);
        }
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

    /// §12.7 IdentifierName — variant of `identifierName` that decodes
    /// `\u…` escapes via the compiler's `bindingName` helper. Callers
    /// that need the canonical StringValue for binding declare / resolve
    /// (rather than the raw source slice for diagnostics or printing)
    /// should prefer this form.
    fn identifierBindingName(self: *Compiler, target: ast.statement.BindingTarget) CompileError!?[]const u8 {
        return switch (target) {
            .identifier => |id| try self.bindingName(id.span),
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
        /// §15.7.14 step 11 — the *decoded* `#name`s declared by this
        /// class (instance + static, fields + methods + accessors).
        /// Walked outward from `class_stack` at every private-name
        /// reference site so the mangle prefix is the *declaring*
        /// class's, not just the innermost. Allocated in the realm's
        /// class arena.
        private_names: []const []const u8 = &.{},
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
        /// §14.13 LabelledStatement label set — the IdentifierNames
        /// that an enclosing `LABEL : LoopStatement` wrapped this
        /// loop with. `break LABEL ;` / `continue LABEL ;` walks the
        /// `parent` chain to find the loop whose `labels` contains
        /// the target. Empty (`&.{}`) for unlabelled loops. Borrowed
        /// from the source buffer; lifetime is the parse arena.
        labels: []const []const u8 = &.{},
        /// True for `switch` LoopContexts — they accept `break`
        /// (with or without a label) but reject `continue` per
        /// §14.17.1 (target must be an *iteration* statement).
        is_switch: bool = false,
        /// True for synthetic LoopContexts wrapping a labelled
        /// Block / non-iteration body (`L: { … break L; }`).
        /// Like `is_switch` these accept labelled `break` but
        /// reject `continue` (§14.17.1 — continue target must be
        /// an iteration statement). Unlabelled `break` ignores
        /// these per §14.16.1 (break-from-outside-iteration-or-
        /// switch is a SyntaxError).
        is_block_label: bool = false,

        fn deinit(self: *LoopContext, allocator: std.mem.Allocator) void {
            self.break_patches.deinit(allocator);
            self.continue_patches.deinit(allocator);
            if (self.labels.len > 0) allocator.free(self.labels);
        }

        fn hasLabel(self: *const LoopContext, name: []const u8) bool {
            for (self.labels) |l| {
                if (std.mem.eql(u8, l, name)) return true;
            }
            return false;
        }
    };

    fn compileWhile(self: *Compiler, s: ast.statement.WhileStmt) CompileError!void {
        // §14.13 — claim any `LABEL :` that wrapped us BEFORE we
        // emit the loop body, so `break LABEL ;` inside the body
        // resolves to *this* LoopContext.
        const labels = try self.drainPendingLabels();
        const loop_start = self.builder.here();
        try self.compileExpression(&s.test_);
        try self.builder.emitOp(.jmp_if_false, s.span);
        const exit_patch = self.builder.here();
        try self.builder.emitI16(0);

        var ctx: LoopContext = .{
            .continue_target = loop_start,
            .parent = self.current_loop,
            .entry_finally_chain = self.finally_chain,
            .labels = labels,
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
        const labels = try self.drainPendingLabels();
        const loop_start = self.builder.here();
        var ctx: LoopContext = .{
            .continue_target = 0,
            .parent = self.current_loop,
            .entry_finally_chain = self.finally_chain,
            .labels = labels,
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

    /// True when `stmt`'s AST subtree contains any function, arrow,
    /// or class — anything that closes over the enclosing scope.
    ///
    /// Gates the for-of per-iteration-env hoist. Cynic flattens a
    /// loop body's block-scoped lexicals into the loop's own
    /// environment (blocks have no runtime env of their own — see
    /// `compileBlock`), so a hoisted single env would wrongly share
    /// not just the loop variable but every body lexical across
    /// iterations. A closure is the only thing that can observe
    /// that sharing; with none in the body, hoisting is sound. The
    /// exhaustive switches make a newly-added AST node a compile
    /// error here rather than a silent miss.
    fn bodyHasClosure(self: *Compiler, stmt: *const ast.statement.Statement) bool {
        return switch (stmt.*) {
            .function_decl, .class_decl => true,
            .empty, .debugger_, .break_, .continue_, .import_decl, .export_decl => false,
            .expression => |es| self.exprHasClosure(&es.expression),
            .block => |bs| self.stmtsHaveClosure(bs.body),
            .lexical => |ld| {
                for (ld.declarators) |d| {
                    if (d.init) |*e| if (self.exprHasClosure(e)) return true;
                }
                return false;
            },
            .if_ => |ifs| self.exprHasClosure(&ifs.test_) or
                self.bodyHasClosure(ifs.consequent) or
                (if (ifs.alternate) |alt| self.bodyHasClosure(alt) else false),
            .while_ => |ws| self.exprHasClosure(&ws.test_) or self.bodyHasClosure(ws.body),
            .do_while => |dw| self.bodyHasClosure(dw.body) or self.exprHasClosure(&dw.test_),
            .return_ => |rs| if (rs.argument) |*e| self.exprHasClosure(e) else false,
            .throw_ => |ts| self.exprHasClosure(&ts.argument),
            .for_ => |fs| blk: {
                if (fs.init) |head| switch (head) {
                    .lexical => |ld| for (ld.declarators) |d| {
                        if (d.init) |*e| if (self.exprHasClosure(e)) break :blk true;
                    },
                    .expression => |e| if (self.exprHasClosure(&e)) break :blk true,
                };
                if (fs.test_) |*t| if (self.exprHasClosure(t)) break :blk true;
                if (fs.update) |*u| if (self.exprHasClosure(u)) break :blk true;
                break :blk self.bodyHasClosure(fs.body);
            },
            .for_in_of => |fio| blk: {
                if (fio.left == .expression) {
                    if (self.exprHasClosure(&fio.left.expression)) break :blk true;
                } else for (fio.left.lexical.declarators) |d| {
                    if (d.init) |*e| if (self.exprHasClosure(e)) break :blk true;
                }
                if (self.exprHasClosure(&fio.right)) break :blk true;
                break :blk self.bodyHasClosure(fio.body);
            },
            .try_ => |ts| blk: {
                if (self.stmtsHaveClosure(ts.block.body)) break :blk true;
                if (ts.handler) |h| if (self.stmtsHaveClosure(h.body.body)) break :blk true;
                if (ts.finalizer) |f| if (self.stmtsHaveClosure(f.body)) break :blk true;
                break :blk false;
            },
            .switch_ => |sw| blk: {
                if (self.exprHasClosure(&sw.discriminant)) break :blk true;
                for (sw.cases) |c| {
                    if (c.test_) |*t| if (self.exprHasClosure(t)) break :blk true;
                    if (self.stmtsHaveClosure(c.body)) break :blk true;
                }
                break :blk false;
            },
            .labeled => |ls| self.bodyHasClosure(ls.body),
        };
    }

    fn stmtsHaveClosure(self: *Compiler, stmts: []const ast.statement.Statement) bool {
        for (stmts) |*st| {
            if (self.bodyHasClosure(st)) return true;
        }
        return false;
    }

    fn exprHasClosure(self: *Compiler, e: *const ast.expression.Expression) bool {
        return switch (e.*) {
            .function_expr, .arrow_function, .class_expr => true,
            .null_literal,
            .boolean_literal,
            .numeric_literal,
            .bigint_literal,
            .string_literal,
            .regex_literal,
            .this_expr,
            .super_,
            .import_meta,
            .new_target,
            .private_identifier,
            .identifier_reference,
            => false,
            .template_literal => |tl| {
                for (tl.expressions) |*sub| if (self.exprHasClosure(sub)) return true;
                return false;
            },
            .parenthesized => |p| self.exprHasClosure(p.expression),
            .unary => |u| self.exprHasClosure(u.operand),
            .binary => |b| self.exprHasClosure(b.lhs) or self.exprHasClosure(b.rhs),
            .logical => |l| self.exprHasClosure(l.lhs) or self.exprHasClosure(l.rhs),
            .conditional => |c| self.exprHasClosure(c.test_) or
                self.exprHasClosure(c.consequent) or self.exprHasClosure(c.alternate),
            .assignment => |a| self.exprHasClosure(a.target) or self.exprHasClosure(a.value),
            .sequence => |sq| {
                for (sq.expressions) |*sub| if (self.exprHasClosure(sub)) return true;
                return false;
            },
            .member => |m| self.exprHasClosure(m.object) or
                (m.property == .computed and self.exprHasClosure(m.property.computed)),
            .call => |c| blk: {
                if (self.exprHasClosure(c.callee)) break :blk true;
                for (c.arguments) |*arg| if (self.exprHasClosure(arg)) break :blk true;
                break :blk false;
            },
            .new_expr => |n| blk: {
                if (self.exprHasClosure(n.callee)) break :blk true;
                for (n.arguments) |*arg| if (self.exprHasClosure(arg)) break :blk true;
                break :blk false;
            },
            .chain => |ch| self.exprHasClosure(ch.expression),
            .tagged_template => |tt| self.exprHasClosure(tt.tag) or self.exprHasClosure(tt.quasi),
            .spread => |sp| self.exprHasClosure(sp.argument),
            .update => |up| self.exprHasClosure(up.operand),
            .array_literal => |al| {
                for (al.elements) |maybe| {
                    if (maybe) |sub| if (self.exprHasClosure(&sub)) return true;
                }
                return false;
            },
            .object_literal => |ol| blk: {
                for (ol.properties) |m| switch (m) {
                    .property => |p| {
                        if (p.key == .computed and self.exprHasClosure(p.key.computed)) break :blk true;
                        if (self.exprHasClosure(&p.value)) break :blk true;
                    },
                    .spread => |sp| if (self.exprHasClosure(sp.argument)) break :blk true,
                    // An object method is itself a closure.
                    .method => break :blk true,
                };
                break :blk false;
            },
            .yield => |y| if (y.argument) |arg| self.exprHasClosure(arg) else false,
            .await_ => |aw| self.exprHasClosure(aw.argument),
            .import_call => |ic| self.exprHasClosure(ic.source),
        };
    }

    fn exprMentionsNamesInNestedFn(
        self: *Compiler,
        e: *const ast.expression.Expression,
        names: []const []const u8,
    ) CompileError!bool {
        switch (e.*) {
            .null_literal,
            .boolean_literal,
            .numeric_literal,
            .bigint_literal,
            .string_literal,
            .regex_literal,
            .this_expr,
            .super_,
            .import_meta,
            .new_target,
            .private_identifier,
            .identifier_reference,
            => return false,
            .template_literal => |tl| {
                for (tl.expressions) |*sub| {
                    if (try self.exprMentionsNamesInNestedFn(sub, names)) return true;
                }
                return false;
            },
            .parenthesized => |p| return self.exprMentionsNamesInNestedFn(p.expression, names),
            .unary => |u| return self.exprMentionsNamesInNestedFn(u.operand, names),
            .binary => |b| {
                if (try self.exprMentionsNamesInNestedFn(b.lhs, names)) return true;
                return self.exprMentionsNamesInNestedFn(b.rhs, names);
            },
            .logical => |l| {
                if (try self.exprMentionsNamesInNestedFn(l.lhs, names)) return true;
                return self.exprMentionsNamesInNestedFn(l.rhs, names);
            },
            .conditional => |c| {
                if (try self.exprMentionsNamesInNestedFn(c.test_, names)) return true;
                if (try self.exprMentionsNamesInNestedFn(c.consequent, names)) return true;
                return self.exprMentionsNamesInNestedFn(c.alternate, names);
            },
            .assignment => |a| {
                if (try self.exprMentionsNamesInNestedFn(a.target, names)) return true;
                return self.exprMentionsNamesInNestedFn(a.value, names);
            },
            .sequence => |sq| {
                for (sq.expressions) |*sub| {
                    if (try self.exprMentionsNamesInNestedFn(sub, names)) return true;
                }
                return false;
            },
            .member => |m| {
                if (try self.exprMentionsNamesInNestedFn(m.object, names)) return true;
                if (m.property == .computed) {
                    return self.exprMentionsNamesInNestedFn(m.property.computed, names);
                }
                return false;
            },
            .call => |c| {
                if (try self.exprMentionsNamesInNestedFn(c.callee, names)) return true;
                for (c.arguments) |*arg| {
                    if (try self.exprMentionsNamesInNestedFn(arg, names)) return true;
                }
                return false;
            },
            .new_expr => |n| {
                if (try self.exprMentionsNamesInNestedFn(n.callee, names)) return true;
                for (n.arguments) |*arg| {
                    if (try self.exprMentionsNamesInNestedFn(arg, names)) return true;
                }
                return false;
            },
            .chain => |ch| return self.exprMentionsNamesInNestedFn(ch.expression, names),
            .tagged_template => |tt| {
                if (try self.exprMentionsNamesInNestedFn(tt.tag, names)) return true;
                return self.exprMentionsNamesInNestedFn(tt.quasi, names);
            },
            .spread => |sp| return self.exprMentionsNamesInNestedFn(sp.argument, names),
            .update => |up| return self.exprMentionsNamesInNestedFn(up.operand, names),
            .function_expr => |fe| return self.fnBodyMentionsNames(fe.params, fe.body.body, names),
            .arrow_function => |af| switch (af.body) {
                .block => |bs| return self.fnBodyMentionsNames(af.params, bs.body, names),
                .expression => |sub| {
                    // Arrow concise body — params can also have defaults that
                    // reference outer names. Check defaults via the params
                    // walker, then walk the concise expression as if it's
                    // inside a nested function body: any matching ident is a
                    // capture.
                    if (try self.paramsMentionNames(af.params, names)) return true;
                    return self.scanInitForIdentRefs(sub, names);
                },
            },
            .array_literal => |al| {
                for (al.elements) |maybe| {
                    if (maybe) |sub| {
                        if (try self.exprMentionsNamesInNestedFn(&sub, names)) return true;
                    }
                }
                return false;
            },
            .object_literal => |ol| {
                for (ol.properties) |m| switch (m) {
                    .property => |p| {
                        if (p.key == .computed) {
                            if (try self.exprMentionsNamesInNestedFn(p.key.computed, names)) return true;
                        }
                        if (try self.exprMentionsNamesInNestedFn(&p.value, names)) return true;
                    },
                    .spread => |sp| if (try self.exprMentionsNamesInNestedFn(sp.argument, names)) return true,
                    .method => |om| {
                        if (om.key == .computed) {
                            if (try self.exprMentionsNamesInNestedFn(om.key.computed, names)) return true;
                        }
                        if (try self.fnBodyMentionsNames(om.params, om.body.body, names)) return true;
                    },
                };
                return false;
            },
            .class_expr => |ce| return self.classBodyMentionsNames(
                if (ce.superclass) |sc| sc.* else null,
                ce.body,
                names,
            ),
            .yield => |y| {
                if (y.argument) |arg| return self.exprMentionsNamesInNestedFn(arg, names);
                return false;
            },
            .await_ => |aw| return self.exprMentionsNamesInNestedFn(aw.argument, names),
            .import_call => |ic| return self.exprMentionsNamesInNestedFn(ic.source, names),
        }
    }

    /// Inside a nested function/method/arrow's params + body: any
    /// identifier reference matching one of `names` is treated as a
    /// capture of the outer loop binding (over-approximation: we
    /// don't track inner shadowing). Param-default expressions are
    /// checked too — they evaluate in an environment that sees the
    /// outer loop binding.
    fn fnBodyMentionsNames(
        self: *Compiler,
        params: []const ast.statement.FunctionParam,
        body: []const ast.statement.Statement,
        names: []const []const u8,
    ) CompileError!bool {
        if (try self.paramsMentionNames(params, names)) return true;
        return self.scanForIdentRefs(body, names);
    }

    fn paramsMentionNames(
        self: *Compiler,
        params: []const ast.statement.FunctionParam,
        names: []const []const u8,
    ) CompileError!bool {
        for (params) |p| switch (p) {
            .simple => |sp| if (sp.default) |*d| {
                if (try self.exprMentionsNamesInNestedFn(d, names)) return true;
            },
            .rest => {},
        };
        return false;
    }

    fn classBodyMentionsNames(
        self: *Compiler,
        superclass: ?ast.expression.Expression,
        members: []const ast.statement.ClassMember,
        names: []const []const u8,
    ) CompileError!bool {
        if (superclass) |sc| {
            if (try self.exprMentionsNamesInNestedFn(&sc, names)) return true;
        }
        for (members) |m| switch (m) {
            .method => |md| {
                if (md.key == .computed) {
                    if (try self.exprMentionsNamesInNestedFn(md.key.computed, names)) return true;
                }
                if (try self.fnBodyMentionsNames(md.params, md.body.body, names)) return true;
            },
            .field => |fd| {
                if (fd.key == .computed) {
                    if (try self.exprMentionsNamesInNestedFn(fd.key.computed, names)) return true;
                }
                // Field initializers run in an implicit per-instance
                // method; treat the same as a nested function body.
                if (fd.init) |*e| {
                    if (try self.scanInitForIdentRefs(e, names)) return true;
                }
            },
            .static_block => |sb| {
                if (try self.scanForIdentRefs(sb.body, names)) return true;
            },
        };
        return false;
    }

    /// Once we're inside a nested function-like scope, any matching
    /// identifier reference (anywhere — including further-nested
    /// scopes, since `let X` shadowing inside the inner body still
    /// over-approximates safely) is a capture.
    fn scanForIdentRefs(
        self: *Compiler,
        body: []const ast.statement.Statement,
        names: []const []const u8,
    ) CompileError!bool {
        for (body) |*st| {
            if (try self.scanStmtForIdentRefs(st, names)) return true;
        }
        return false;
    }

    fn scanStmtForIdentRefs(
        self: *Compiler,
        stmt: *const ast.statement.Statement,
        names: []const []const u8,
    ) CompileError!bool {
        switch (stmt.*) {
            .expression => |es| return self.scanInitForIdentRefs(&es.expression, names),
            .block => |bs| return self.scanForIdentRefs(bs.body, names),
            .empty, .debugger_, .break_, .continue_ => return false,
            .lexical => |ld| {
                for (ld.declarators) |d| {
                    if (d.init) |*e| {
                        if (try self.scanInitForIdentRefs(e, names)) return true;
                    }
                }
                return false;
            },
            .if_ => |ifs| {
                if (try self.scanInitForIdentRefs(&ifs.test_, names)) return true;
                if (try self.scanStmtForIdentRefs(ifs.consequent, names)) return true;
                if (ifs.alternate) |alt| return self.scanStmtForIdentRefs(alt, names);
                return false;
            },
            .while_ => |ws| {
                if (try self.scanInitForIdentRefs(&ws.test_, names)) return true;
                return self.scanStmtForIdentRefs(ws.body, names);
            },
            .do_while => |dw| {
                if (try self.scanStmtForIdentRefs(dw.body, names)) return true;
                return self.scanInitForIdentRefs(&dw.test_, names);
            },
            .return_ => |rs| {
                if (rs.argument) |*e| return self.scanInitForIdentRefs(e, names);
                return false;
            },
            .throw_ => |ts| return self.scanInitForIdentRefs(&ts.argument, names),
            .for_ => |fs| {
                if (fs.init) |head| switch (head) {
                    .lexical => |ld| {
                        for (ld.declarators) |d| {
                            if (d.init) |*e| {
                                if (try self.scanInitForIdentRefs(e, names)) return true;
                            }
                        }
                    },
                    .expression => |e| {
                        if (try self.scanInitForIdentRefs(&e, names)) return true;
                    },
                };
                if (fs.test_) |*t| {
                    if (try self.scanInitForIdentRefs(t, names)) return true;
                }
                if (fs.update) |*u| {
                    if (try self.scanInitForIdentRefs(u, names)) return true;
                }
                return self.scanStmtForIdentRefs(fs.body, names);
            },
            .for_in_of => |fio| {
                if (fio.left == .expression) {
                    if (try self.scanInitForIdentRefs(&fio.left.expression, names)) return true;
                } else {
                    for (fio.left.lexical.declarators) |d| {
                        if (d.init) |*e| {
                            if (try self.scanInitForIdentRefs(e, names)) return true;
                        }
                    }
                }
                if (try self.scanInitForIdentRefs(&fio.right, names)) return true;
                return self.scanStmtForIdentRefs(fio.body, names);
            },
            .try_ => |ts| {
                if (try self.scanForIdentRefs(ts.block.body, names)) return true;
                if (ts.handler) |h| {
                    if (try self.scanForIdentRefs(h.body.body, names)) return true;
                }
                if (ts.finalizer) |f| {
                    if (try self.scanForIdentRefs(f.body, names)) return true;
                }
                return false;
            },
            .switch_ => |sw| {
                if (try self.scanInitForIdentRefs(&sw.discriminant, names)) return true;
                for (sw.cases) |c| {
                    if (c.test_) |*t| {
                        if (try self.scanInitForIdentRefs(t, names)) return true;
                    }
                    if (try self.scanForIdentRefs(c.body, names)) return true;
                }
                return false;
            },
            .labeled => |ls| return self.scanStmtForIdentRefs(ls.body, names),
            .function_decl => |fd| {
                // Already inside a nested function — params + body of
                // a still-deeper function. Continue scanning.
                if (try self.paramsForScan(fd.params, names)) return true;
                return self.scanForIdentRefs(fd.body.body, names);
            },
            .class_decl => |cd| {
                if (cd.superclass) |*sc| {
                    if (try self.scanInitForIdentRefs(sc, names)) return true;
                }
                for (cd.body) |m| switch (m) {
                    .method => |md| {
                        if (md.key == .computed) {
                            if (try self.scanInitForIdentRefs(md.key.computed, names)) return true;
                        }
                        if (try self.paramsForScan(md.params, names)) return true;
                        if (try self.scanForIdentRefs(md.body.body, names)) return true;
                    },
                    .field => |fd| {
                        if (fd.key == .computed) {
                            if (try self.scanInitForIdentRefs(fd.key.computed, names)) return true;
                        }
                        if (fd.init) |*e| {
                            if (try self.scanInitForIdentRefs(e, names)) return true;
                        }
                    },
                    .static_block => |sb| {
                        if (try self.scanForIdentRefs(sb.body, names)) return true;
                    },
                };
                return false;
            },
            .import_decl, .export_decl => return false,
        }
    }

    fn paramsForScan(
        self: *Compiler,
        params: []const ast.statement.FunctionParam,
        names: []const []const u8,
    ) CompileError!bool {
        for (params) |p| switch (p) {
            .simple => |sp| if (sp.default) |*d| {
                if (try self.scanInitForIdentRefs(d, names)) return true;
            },
            .rest => {},
        };
        return false;
    }

    fn scanInitForIdentRefs(
        self: *Compiler,
        e: *const ast.expression.Expression,
        names: []const []const u8,
    ) CompileError!bool {
        switch (e.*) {
            .identifier_reference => |ir| {
                const lex = self.source[ir.span.start..ir.span.end];
                // Cheap pre-check: if the lexeme contains a `\` then
                // it may be Unicode-escaped — fall back to the
                // canonicalised name compare.
                if (std.mem.indexOfScalar(u8, lex, '\\') == null) {
                    for (names) |n| {
                        if (std.mem.eql(u8, lex, n)) return true;
                    }
                    return false;
                }
                const decoded = self.bindingName(ir.span) catch return false;
                for (names) |n| {
                    if (std.mem.eql(u8, decoded, n)) return true;
                }
                return false;
            },
            .null_literal,
            .boolean_literal,
            .numeric_literal,
            .bigint_literal,
            .string_literal,
            .regex_literal,
            .this_expr,
            .super_,
            .import_meta,
            .new_target,
            .private_identifier,
            => return false,
            .template_literal => |tl| {
                for (tl.expressions) |*sub| {
                    if (try self.scanInitForIdentRefs(sub, names)) return true;
                }
                return false;
            },
            .parenthesized => |p| return self.scanInitForIdentRefs(p.expression, names),
            .unary => |u| return self.scanInitForIdentRefs(u.operand, names),
            .binary => |b| {
                if (try self.scanInitForIdentRefs(b.lhs, names)) return true;
                return self.scanInitForIdentRefs(b.rhs, names);
            },
            .logical => |l| {
                if (try self.scanInitForIdentRefs(l.lhs, names)) return true;
                return self.scanInitForIdentRefs(l.rhs, names);
            },
            .conditional => |c| {
                if (try self.scanInitForIdentRefs(c.test_, names)) return true;
                if (try self.scanInitForIdentRefs(c.consequent, names)) return true;
                return self.scanInitForIdentRefs(c.alternate, names);
            },
            .assignment => |a| {
                if (try self.scanInitForIdentRefs(a.target, names)) return true;
                return self.scanInitForIdentRefs(a.value, names);
            },
            .sequence => |sq| {
                for (sq.expressions) |*sub| {
                    if (try self.scanInitForIdentRefs(sub, names)) return true;
                }
                return false;
            },
            .member => |m| {
                if (try self.scanInitForIdentRefs(m.object, names)) return true;
                if (m.property == .computed) {
                    return self.scanInitForIdentRefs(m.property.computed, names);
                }
                return false;
            },
            .call => |c| {
                if (try self.scanInitForIdentRefs(c.callee, names)) return true;
                for (c.arguments) |*arg| {
                    if (try self.scanInitForIdentRefs(arg, names)) return true;
                }
                return false;
            },
            .new_expr => |n| {
                if (try self.scanInitForIdentRefs(n.callee, names)) return true;
                for (n.arguments) |*arg| {
                    if (try self.scanInitForIdentRefs(arg, names)) return true;
                }
                return false;
            },
            .chain => |ch| return self.scanInitForIdentRefs(ch.expression, names),
            .tagged_template => |tt| {
                if (try self.scanInitForIdentRefs(tt.tag, names)) return true;
                return self.scanInitForIdentRefs(tt.quasi, names);
            },
            .spread => |sp| return self.scanInitForIdentRefs(sp.argument, names),
            .update => |up| return self.scanInitForIdentRefs(up.operand, names),
            .function_expr => |fe| {
                if (try self.paramsForScan(fe.params, names)) return true;
                return self.scanForIdentRefs(fe.body.body, names);
            },
            .arrow_function => |af| switch (af.body) {
                .block => |bs| {
                    if (try self.paramsForScan(af.params, names)) return true;
                    return self.scanForIdentRefs(bs.body, names);
                },
                .expression => |sub| {
                    if (try self.paramsForScan(af.params, names)) return true;
                    return self.scanInitForIdentRefs(sub, names);
                },
            },
            .array_literal => |al| {
                for (al.elements) |maybe| {
                    if (maybe) |sub| {
                        if (try self.scanInitForIdentRefs(&sub, names)) return true;
                    }
                }
                return false;
            },
            .object_literal => |ol| {
                for (ol.properties) |om| switch (om) {
                    .property => |p| {
                        if (p.key == .computed) {
                            if (try self.scanInitForIdentRefs(p.key.computed, names)) return true;
                        }
                        if (try self.scanInitForIdentRefs(&p.value, names)) return true;
                    },
                    .spread => |sp| if (try self.scanInitForIdentRefs(sp.argument, names)) return true,
                    .method => |m| {
                        if (m.key == .computed) {
                            if (try self.scanInitForIdentRefs(m.key.computed, names)) return true;
                        }
                        if (try self.paramsForScan(m.params, names)) return true;
                        if (try self.scanForIdentRefs(m.body.body, names)) return true;
                    },
                };
                return false;
            },
            .class_expr => |ce| {
                if (ce.superclass) |sc| {
                    if (try self.scanInitForIdentRefs(sc, names)) return true;
                }
                for (ce.body) |m| switch (m) {
                    .method => |md| {
                        if (md.key == .computed) {
                            if (try self.scanInitForIdentRefs(md.key.computed, names)) return true;
                        }
                        if (try self.paramsForScan(md.params, names)) return true;
                        if (try self.scanForIdentRefs(md.body.body, names)) return true;
                    },
                    .field => |fd| {
                        if (fd.key == .computed) {
                            if (try self.scanInitForIdentRefs(fd.key.computed, names)) return true;
                        }
                        if (fd.init) |*ie| {
                            if (try self.scanInitForIdentRefs(ie, names)) return true;
                        }
                    },
                    .static_block => |sb| {
                        if (try self.scanForIdentRefs(sb.body, names)) return true;
                    },
                };
                return false;
            },
            .yield => |y| {
                if (y.argument) |arg| return self.scanInitForIdentRefs(arg, names);
                return false;
            },
            .await_ => |aw| return self.scanInitForIdentRefs(aw.argument, names),
            .import_call => |ic| return self.scanInitForIdentRefs(ic.source, names),
        }
    }

    fn compileFor(self: *Compiler, s: ast.statement.ForStmt) CompileError!void {
        // §14.7.4 ForStatement (C-style — for-in / for-of compile
        // separately). For `let`/`const` head bindings,
        // §14.7.4.1 ForBodyEvaluation step 2 + CreatePerIterationEnvironment
        // (§14.7.4.4) require a fresh declarative environment per
        // iteration so closures captured inside the body see
        // iteration-specific values. We support both single-binding
        // (the overwhelming majority) and multi-binding heads
        // (`for (let i = 0, j = 10; …)`); `var` heads stay on the
        // legacy single-slot path.
        //
        // §14.7.4.4 optimisation — when no closure in the loop body,
        // and no nested function in the update / test, captures a
        // head binding, the per-iter env is not spec-observable.
        // V8 / JSC / SpiderMonkey all elide it and run the loop in a
        // single lexical scope; Cynic does the same. The
        // regex property-escapes helper
        // `for (let codePoint = start; codePoint <= end; codePoint++)
        //   { codePoints[length++] = codePoint; }`
        // is the canonical case — without this optimisation those
        // fixtures (538 of them in `built-ins/RegExp/property-escapes`)
        // blow past the harness step budget once a fresh env is
        // allocated + populated + popped on every iteration.
        const labels = try self.drainPendingLabels();

        // Detect the `let`/`const`-binding case. Multi-binding is
        // supported when every declarator binds a single identifier
        // (pattern destructuring in a for-head is rare; falls back
        // to the legacy path).
        var per_iter_env = false;
        const PerIterBinding = struct { name: []const u8, span: Span, kind: BindingKind };
        var per_iter_bindings: std.ArrayListUnmanaged(PerIterBinding) = .empty;
        defer per_iter_bindings.deinit(self.allocator);
        if (s.init) |head| switch (head) {
            .lexical => |ld| if (ld.kind != .var_) {
                var all_ident = true;
                for (ld.declarators) |d| {
                    if (d.name != .identifier) {
                        all_ident = false;
                        break;
                    }
                }
                if (all_ident and ld.declarators.len > 0) {
                    const k: BindingKind = if (ld.kind == .let_) .let_ else .const_;
                    for (ld.declarators) |d| {
                        const name = try self.bindingName(d.name.identifier.span);
                        try per_iter_bindings.append(self.allocator, .{
                            .name = name,
                            .span = d.span,
                            .kind = k,
                        });
                    }
                    // Only emit the per-iter env when a nested
                    // function in the body / test / update actually
                    // captures one of the bindings. Without a
                    // capture, the per-iter env is unobservable and
                    // can be elided (treat as a single block scope).
                    var names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer names_buf.deinit(self.allocator);
                    for (per_iter_bindings.items) |b| {
                        try names_buf.append(self.allocator, b.name);
                    }
                    var captured = false;
                    // §13.3.2 — a closure created *inside* a head
                    // initializer (e.g. `let i = 0, f = function(){
                    // return i; }`) captures the init env and is
                    // spec-observable across iterations. Walk every
                    // declarator's init expression.
                    for (ld.declarators) |di| {
                        if (di.init) |*ie| {
                            if (try self.exprMentionsNamesInNestedFn(ie, names_buf.items)) {
                                captured = true;
                                break;
                            }
                        }
                    }
                    if (!captured) {
                        // Cynic flattens a loop body's block lexicals
                        // into the loop env (blocks have no runtime
                        // env of their own), so a closure capturing a
                        // body lexical — not just a loop-head binding
                        // — also observes per-iteration freshness.
                        // Any closure in the body therefore keeps the
                        // per-iteration env.
                        if (self.bodyHasClosure(s.body)) {
                            captured = true;
                        } else if (s.test_) |*t| {
                            if (try self.exprMentionsNamesInNestedFn(t, names_buf.items)) captured = true;
                        }
                    }
                    if (!captured) {
                        if (s.update) |*u| {
                            if (try self.exprMentionsNamesInNestedFn(u, names_buf.items)) captured = true;
                        }
                    }
                    per_iter_env = captured;
                    if (!captured) {
                        // Drop the bindings so the non-per-iter
                        // fallthrough below uses the legacy
                        // single-scope path.
                        per_iter_bindings.clearRetainingCapacity();
                    }
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

        // Carry-forward registers: one per binding. Hold the
        // binding's value across env swaps; loaded out of the
        // active per-iter env at the bottom of the body and used
        // to seed the fresh env for the next iteration.
        var carry_regs: std.ArrayListUnmanaged(u8) = .empty;
        defer carry_regs.deinit(self.allocator);
        var per_iter_size_patch: usize = 0;
        var saved_per_iter_slot_count: u8 = 0;
        if (per_iter_env) {
            const declarators = s.init.?.lexical.declarators;
            for (declarators) |_| {
                const r = try self.reserveTemp();
                try carry_regs.append(self.allocator, r);
            }

            // Per-iter env owns its own slot pool (loop vars + body
            // lexicals). Borrow `env_slot_count`, reset it, restore
            // at loop teardown — see compileForInOf for the same
            // shape. Without this, body's first `const` aliases the
            // loop variable.
            saved_per_iter_slot_count = self.env_slot_count;
            self.env_slot_count = 0;
            // §13.3.2 LexicalDeclaration evaluation inside a for-
            // head — create the loopEnv first, declare every
            // binding as TDZ, then evaluate each init INSIDE the
            // env. A closure constructed by a later init (e.g.
            // `f = function(){ return i; }`) captures the env that
            // holds `i`, so subsequent reads of `i` from the
            // closure resolve correctly even after the env is
            // swapped out per iteration.
            try self.builder.emitOp(.make_environment, s.span);
            per_iter_size_patch = self.builder.code.items.len;
            try self.builder.emitU8(0); // placeholder; patched below
            self.env_depth = saved_env_depth + 1;
            // Declare every binding before any init runs (TDZ).
            for (per_iter_bindings.items) |b| {
                _ = try self.declareBinding(b.name, b.kind, b.span);
            }
            // Now evaluate each init inside the env and write into
            // its slot.
            for (declarators, 0..) |d, i| {
                const b = per_iter_bindings.items[i];
                if (d.init) |*init_expr| {
                    try self.compileExpression(init_expr);
                } else {
                    try self.builder.emitOp(.lda_undefined, b.span);
                }
                try self.builder.emitOp(.sta_env, b.span);
                try self.builder.emitU8(0);
                try self.builder.emitU8(@intCast(i));
            }
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

        // §14.7.4.2 ForBodyEvaluation step 2 —
        // CreatePerIterationEnvironment runs ONCE before the loop
        // starts, swapping the init env (E_init) for the first
        // iteration env (E_0). Closures captured during init keep
        // pointing at E_init; E_init is detached from the live env
        // chain so subsequent body writes can't reach back into it.
        // The carry-and-swap dance mirrors the per-iteration step
        // emitted below: snapshot the init values, pop E_init, push
        // E_0, restore values.
        var per_iter_size_patch_pre: usize = 0;
        if (per_iter_env) {
            for (carry_regs.items, 0..) |r, i| {
                try self.builder.emitOp(.lda_env, s.span);
                try self.builder.emitU8(0);
                try self.builder.emitU8(@intCast(i));
                try self.builder.emitOp(.star, s.span);
                try self.builder.emitU8(r);
            }
            try self.builder.emitOp(.pop_env, s.span);
            try self.builder.emitOp(.make_environment, s.span);
            per_iter_size_patch_pre = self.builder.code.items.len;
            try self.builder.emitU8(0); // placeholder; patched below
            for (carry_regs.items, 0..) |r, i| {
                try self.builder.emitOp(.ldar, s.span);
                try self.builder.emitU8(r);
                try self.builder.emitOp(.sta_env, s.span);
                try self.builder.emitU8(0);
                try self.builder.emitU8(@intCast(i));
            }
        }

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
            .labels = labels,
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
            // Snapshot each binding's current value out of the
            // per-iter env into its carry register.
            for (carry_regs.items, 0..) |r, i| {
                try self.builder.emitOp(.lda_env, s.span);
                try self.builder.emitU8(0);
                try self.builder.emitU8(@intCast(i));
                try self.builder.emitOp(.star, s.span);
                try self.builder.emitU8(r);
            }
            // Pop current env and push a fresh one with the
            // carried-over values.
            try self.builder.emitOp(.pop_env, s.span);
            try self.builder.emitOp(.make_environment, s.span);
            per_iter_size_patch_2 = self.builder.code.items.len;
            try self.builder.emitU8(0); // placeholder; patched below
            for (carry_regs.items, 0..) |r, i| {
                try self.builder.emitOp(.ldar, s.span);
                try self.builder.emitU8(r);
                try self.builder.emitOp(.sta_env, s.span);
                try self.builder.emitU8(0);
                try self.builder.emitU8(@intCast(i));
            }
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
            // Patch all three per-iter `make_environment` size
            // operands (E_init / initial swap / per-iter refresh)
            // to whatever env_slot_count grew to. Restore the
            // enclosing function's slot counter.
            self.builder.code.items[per_iter_size_patch] = self.env_slot_count;
            self.builder.code.items[per_iter_size_patch_pre] = self.env_slot_count;
            self.builder.code.items[per_iter_size_patch_2] = self.env_slot_count;
            self.env_slot_count = saved_per_iter_slot_count;
            // Release each carry register in reverse order so the
            // temp allocator's stack invariant holds.
            var i: usize = carry_regs.items.len;
            while (i > 0) : (i -= 1) self.releaseTemp();
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

    /// §14.13 LabelledStatement — `IDENTIFIER : Statement`. Push the
    /// label onto `pending_labels` so the *first* iteration statement
    /// encountered while compiling the body claims it as one of its
    /// `LoopContext.labels`. The label is popped on exit; a body that
    /// isn't an iteration statement (e.g. `LABEL: { … }`) silently
    /// drops the label — `break LABEL ;` from inside such a block
    /// isn't supported yet, but the label is otherwise transparent.
    fn compileLabeled(self: *Compiler, lb: ast.statement.LabeledStmt) CompileError!void {
        const name = self.source[lb.label.start..lb.label.end];
        // §14.13.4 — when the LabelledItem is itself a Statement
        // that isn't an iteration / switch (e.g. `L: { … }` or
        // `L: stmt;`), `break L;` from inside the body still has
        // to find a target. Open a synthetic LoopContext whose
        // sole purpose is to accept the labelled `break`; the
        // post-body PC backfills every emitted break-patch.
        // Iteration statements drain `pending_labels` themselves
        // (so their LoopContext owns the label), but every other
        // body shape gets the synthetic wrap.
        const body_is_iteration = switch (lb.body.*) {
            .for_, .for_in_of, .while_, .do_while => true,
            else => false,
        };
        if (body_is_iteration) {
            try self.pending_labels.append(self.allocator, name);
            const len_before = self.pending_labels.items.len;
            defer {
                if (self.pending_labels.items.len == len_before) {
                    _ = self.pending_labels.pop();
                }
            }
            try self.compileStatement(lb.body);
            return;
        }
        const labels_dup = try self.allocator.alloc([]const u8, 1);
        labels_dup[0] = name;
        var ctx: LoopContext = .{
            .continue_target = 0,
            .parent = self.current_loop,
            .entry_finally_chain = self.finally_chain,
            .labels = labels_dup,
            .is_block_label = true,
        };
        defer ctx.deinit(self.allocator);
        const saved_loop = self.current_loop;
        self.current_loop = &ctx;
        defer self.current_loop = saved_loop;
        try self.compileStatement(lb.body);
        // §14.13.4 step 3 — break L lands here.
        const end_pc = self.builder.here();
        for (ctx.break_patches.items) |p| try self.builder.patchI16(p, end_pc);
    }

    /// Drain `pending_labels` into a freshly-allocated slice. Called
    /// at the top of each iteration-statement's compile routine; the
    /// returned slice is owned by the LoopContext and freed via
    /// `LoopContext.deinit`. Returns an empty slice (sharing the
    /// const `&.{}` static) when no labels are pending — that
    /// preserves the deinit-time `len > 0` guard.
    fn drainPendingLabels(self: *Compiler) CompileError![]const []const u8 {
        const n = self.pending_labels.items.len;
        if (n == 0) return &.{};
        const dup = try self.allocator.alloc([]const u8, n);
        @memcpy(dup, self.pending_labels.items);
        self.pending_labels.clearRetainingCapacity();
        return dup;
    }

    /// Locate the `LoopContext` that `break LABEL ;` should exit. If
    /// `label_span` is `null` (unlabelled `break ;`) returns the
    /// innermost loop. Otherwise walks `current_loop.parent*` for the
    /// loop whose `labels` includes the target. Returns `null` if no
    /// match — caller reports the diagnostic.
    fn findBreakTarget(self: *Compiler, label_span: ?Span) ?*LoopContext {
        var c = self.current_loop;
        if (label_span) |sp| {
            const name = self.source[sp.start..sp.end];
            while (c) |ctx| : (c = ctx.parent) {
                if (ctx.hasLabel(name)) return ctx;
            }
            return null;
        }
        // §14.16.1 — unlabelled `break` targets the innermost
        // iteration / switch statement; a labelled `Block`
        // synthetic LoopContext (`L: { … }`) doesn't satisfy
        // the early-error so skip past it.
        while (c) |ctx| : (c = ctx.parent) {
            if (!ctx.is_block_label) return ctx;
        }
        return null;
    }

    /// §14.17.1 ContinueStatement — the target must be an iteration
    /// statement (not a switch). Walks `current_loop.parent*` for a
    /// loop whose `labels` contains the target name; `is_switch`
    /// contexts are skipped over (a `continue` inside a switch
    /// targets the enclosing loop) and unlabelled `continue` lands
    /// on the innermost non-switch loop.
    fn findContinueTarget(self: *Compiler, label_span: ?Span) ?*LoopContext {
        var c = self.current_loop;
        if (label_span) |sp| {
            const name = self.source[sp.start..sp.end];
            while (c) |ctx| : (c = ctx.parent) {
                if (ctx.is_switch or ctx.is_block_label) continue;
                if (ctx.hasLabel(name)) return ctx;
            }
            return null;
        }
        while (c) |ctx| : (c = ctx.parent) {
            if (!ctx.is_switch and !ctx.is_block_label) return ctx;
        }
        return null;
    }

    fn compileBreak(self: *Compiler, s: ast.statement.BreakStmt) CompileError!void {
        const target = self.findBreakTarget(s.label) orelse {
            try self.report(.unexpected_token, s.span);
            return error.UnsupportedStatement;
        };
        // §7.4.6 IteratorClose — every for-of loop strictly between
        // this `break` and the target loop must have its iterator
        // closed before we leave it. Walk the chain inner→outer up
        // to *and including* the target.
        var c: ?*LoopContext = self.current_loop;
        while (c) |ctx| : (c = ctx.parent) {
            if (ctx.iter_register) |r_iter| {
                try self.builder.emitOp(.iter_close, s.span);
                try self.builder.emitU8(r_iter);
                // §7.4.6 — completion type is `break`; propagate
                // inner throw, TypeError on non-Object return.
                try self.builder.emitU8(0);
            }
            if (ctx == target) break;
        }
        // §14.15 — run every finally block opened between this
        // `break` and the target loop entry before transferring
        // control.
        try self.emitFinalliesUntil(target.entry_finally_chain, s.span);
        // `break` jumps past the natural `pop_env` site; emit one
        // `pop_env` for every per-iter-env loop we skip out of
        // (innermost → target inclusive).
        c = self.current_loop;
        while (c) |ctx| : (c = ctx.parent) {
            if (ctx.needs_env_pop) try self.builder.emitOp(.pop_env, s.span);
            if (ctx == target) break;
        }
        try self.builder.emitOp(.jmp, s.span);
        const patch = self.builder.here();
        try self.builder.emitI16(0);
        try target.break_patches.append(self.allocator, patch);
    }

    fn compileContinue(self: *Compiler, s: ast.statement.ContinueStmt) CompileError!void {
        // Defer the patch — `for` loops don't know their continue
        // target (the update PC) until the body has been compiled,
        // and `do-while` doesn't know its test PC until after the
        // body. Loop-specific compile routines walk
        // `continue_patches` at the end and patch each.
        const target = self.findContinueTarget(s.label) orelse {
            try self.report(.unexpected_token, s.span);
            return error.UnsupportedStatement;
        };
        // §7.4.6 IteratorClose — every for-of loop strictly between
        // this `continue` and the target loop must have its iterator
        // closed (we're leaving those loops outright). The target
        // loop itself is re-entered, so its iterator stays open.
        var c: ?*LoopContext = self.current_loop;
        while (c) |ctx| : (c = ctx.parent) {
            if (ctx == target) break;
            if (ctx.iter_register) |r_iter| {
                try self.builder.emitOp(.iter_close, s.span);
                try self.builder.emitU8(r_iter);
                try self.builder.emitU8(0);
            }
        }
        // §14.15 — run every finally block opened between this
        // `continue` and the target loop entry before transferring
        // control.
        try self.emitFinalliesUntil(target.entry_finally_chain, s.span);
        // For every loop we skip OUTWARDS through (i.e. strictly
        // inner to `target`), pop its per-iter env if it had one.
        // The target loop's own per-iter env teardown is handled by
        // its `continue_target` (which, for `for-of` over `let`,
        // emits its own `pop_env`).
        c = self.current_loop;
        while (c) |ctx| : (c = ctx.parent) {
            if (ctx == target) break;
            if (ctx.needs_env_pop) try self.builder.emitOp(.pop_env, s.span);
        }
        try self.builder.emitOp(.jmp, s.span);
        const patch = self.builder.here();
        try self.builder.emitI16(0);
        try target.continue_patches.append(self.allocator, patch);
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
                    .identifier => |cid| {
                        // §12.7 — bind by StringValue.
                        const name = try self.bindingName(cid.span);
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
                        // §14.15.10 step 5 — catch parameter
                        // destructuring is BindingInitialization on
                        // freshly-declared let slots.
                        try self.compileDestructure(target, true);
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
                    .is_finally = true,
                });
            } else if (catch_body_start != null and catch_body_end != null) {
                try self.builder.addHandler(.{
                    .start_pc = catch_body_start.?,
                    .end_pc = catch_body_end.?,
                    .handler_pc = synth_pc,
                    .catch_register = slot,
                    .is_finally = true,
                });
            }
        } else {
            // No finally — control just merges past the catch landing.
            const merge_pc = self.builder.here();
            try self.builder.patchI16(skip_handler_patch, merge_pc);
        }
    }
};

/// §9.4.6.7 — walk `body` and populate `out` with
/// (local-name → exported-name(s)) for every export entry that
/// owns a local binding. Aliasing (`export { x as a, x as b }`)
/// appends multiple names per local; `export { x } from "src"`
/// is omitted (re-exports have no local owning storage; their
/// live bindings flow through `namespace_redirects`).
fn collectLiveExports(
    c: *Compiler,
    body: []ast.statement.Statement,
    out: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) CompileError!void {
    for (body) |s| switch (s) {
        .export_decl => |ed| switch (ed.body) {
            .declaration => |inner| switch (inner.*) {
                .lexical => |ld| {
                    for (ld.declarators) |d| {
                        try collectLiveExportsFromTarget(c, d.name, out);
                    }
                },
                .function_decl => |fd| {
                    const name = try c.bindingName(fd.name.span);
                    try addLiveExportAlias(c, out, name, name);
                },
                .class_decl => |cd| {
                    const name = try c.bindingName(cd.name.span);
                    try addLiveExportAlias(c, out, name, name);
                },
                else => {},
            },
            .named => |nb| {
                if (nb.source != null) continue;
                for (nb.specifiers) |spec| {
                    const local_text = c.source[spec.local_span.start..spec.local_span.end];
                    const local_name = if (local_text.len >= 2 and (local_text[0] == '"' or local_text[0] == '\''))
                        local_text[1 .. local_text.len - 1]
                    else
                        try c.decodeIdentifierName(local_text);
                    const exported_text = c.source[spec.exported_span.start..spec.exported_span.end];
                    const exported_name = if (exported_text.len >= 2 and (exported_text[0] == '"' or exported_text[0] == '\''))
                        exported_text[1 .. exported_text.len - 1]
                    else
                        try c.decodeIdentifierName(exported_text);
                    try addLiveExportAlias(c, out, local_name, exported_name);
                }
            },
            // `export default <expr>` — anonymous defaults have no
            // observable local binding; named defaults
            // (`export default function F() {}` /
            // `export default class F {}`) create a local F that
            // user code can't reassign (no `let` form), so live-
            // binding propagation has no observable effect today.
            .default_value => {},
            .all => {},
        },
        else => {},
    };
}

fn collectLiveExportsFromTarget(
    c: *Compiler,
    target: ast.statement.BindingTarget,
    out: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) CompileError!void {
    switch (target) {
        .identifier => |id| {
            const name = c.source[id.span.start..id.span.end];
            try addLiveExportAlias(c, out, name, name);
        },
        .object => |op| {
            for (op.properties) |prop| {
                try collectLiveExportsFromTarget(c, prop.value.target, out);
            }
            if (op.rest) |rest| {
                // Object rest target is a BindingIdentifier (not a
                // nested pattern) — the spec disallows
                // `let {...{a}} = obj`.
                const name = c.source[rest.span.start..rest.span.end];
                try addLiveExportAlias(c, out, name, name);
            }
        },
        .array => |ap| {
            for (ap.elements) |maybe_el| {
                const el = maybe_el orelse continue; // elision
                try collectLiveExportsFromTarget(c, el.target, out);
            }
            if (ap.rest) |rest| try collectLiveExportsFromTarget(c, rest.*, out);
        },
    }
}

fn addLiveExportAlias(
    c: *Compiler,
    out: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    local_name: []const u8,
    exported_name: []const u8,
) CompileError!void {
    const gop = try out.getOrPut(c.allocator, local_name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(c.allocator, exported_name);
}

/// Discriminator for the body shape passed to
/// [compileFunctionTemplate]. Block-bodied functions and arrows
/// share one path; concise-body arrows take the other.
pub const FunctionBody = union(enum) {
    block: []ast.statement.Statement,
    expression: *const Expression,
};

/// §15.7.7 ExpectedArgumentCount — count formal parameters BEFORE
/// the first one with an initializer (`=`) or the rest element.
/// A bare BindingPattern (`[a,b]` / `{a}` with no `=`) has
/// `HasInitializer = false` (§8.4.2 / §8.5.2), so it COUNTS toward
/// the spec length just like a simple identifier param. Only an
/// explicit initializer or the rest element terminates the count.
fn computeSpecLength(params: []const ast.statement.FunctionParam) u8 {
    var n: u8 = 0;
    for (params) |p| switch (p) {
        .simple => |sp| {
            if (sp.default != null) break;
            n += 1;
        },
        .rest => break,
    };
    return n;
}

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
    return compileFunctionTemplateExtNamed(self, params, body, name, is_arrow, is_generator, is_async, span, false);
}

fn compileFunctionTemplateExtNamed(
    self: *Compiler,
    params: []ast.statement.FunctionParam,
    body: FunctionBody,
    name: ?[]const u8,
    is_arrow: bool,
    is_generator: bool,
    is_async: bool,
    span: Span,
    is_named_fn_expr: bool,
) CompileError!u16 {
    // Save outer state.
    const saved_builder = self.builder;
    const saved_scope = self.scope;
    const saved_env_slot_count = self.env_slot_count;
    const saved_temps_in_use = self.temps_in_use;
    const saved_env_depth = self.env_depth;
    const saved_current_loop = self.current_loop;
    const saved_is_async = self.current_is_async;
    // §14.13 — label scopes don't cross function boundaries.
    // Stash the outer `pending_labels` (and the function body
    // starts with an empty list), restore on exit. Without
    // this, `LABEL : function f() { … }` would let the inner
    // function's first loop claim the outer label.
    const saved_pending_labels = self.pending_labels;
    self.pending_labels = .empty;

    // Reset to a fresh inner state.
    self.builder = self.freshSubBuilder();
    // §15.6.5 — when this is a NAMED function expression, splice a
    // synthetic 1-binding scope between the outer scope and the
    // function body scope. Inner references to the function's own
    // name resolve to depth=1 / slot=0; writes lower to
    // `throw_assign_const` via the `is_fn_expr_name` flag. The
    // wrapper env is materialised at runtime by
    // `make_named_function_expr`, so the body's env_depth must be
    // bumped past the synthetic level for outer-scope reads to
    // index through it correctly.
    const has_fn_name_env = is_named_fn_expr and name != null;
    var name_scope: Scope = .{ .parent = self.scope, .kind = .block };
    if (has_fn_name_env) {
        name_scope.has_own_env = true;
        try name_scope.bindings.append(self.allocator, .{
            .name = name.?,
            .env_slot = 0,
            .env_depth = saved_env_depth + 1,
            .kind = .const_,
            .span = span,
            .is_fn_expr_name = true,
        });
    }
    var fn_scope: Scope = .{
        .parent = if (has_fn_name_env) &name_scope else self.scope,
        .kind = .function,
    };
    self.scope = &fn_scope;
    self.env_slot_count = 0;
    self.temps_in_use = 0;
    self.env_depth = saved_env_depth + 1 + (if (has_fn_name_env) @as(u8, 1) else @as(u8, 0));
    self.current_loop = null;
    self.current_is_async = is_async;

    var inner_finished = false;
    defer {
        if (!inner_finished) {
            self.builder.deinit();
            fn_scope.deinit(self.allocator);
            if (has_fn_name_env) name_scope.deinit(self.allocator);
            self.pending_labels.deinit(self.allocator);
            self.builder = saved_builder;
            self.scope = saved_scope;
            self.env_slot_count = saved_env_slot_count;
            self.temps_in_use = saved_temps_in_use;
            self.env_depth = saved_env_depth;
            self.current_loop = saved_current_loop;
            self.current_is_async = saved_is_async;
            self.pending_labels = saved_pending_labels;
        }
    }

    // Emit a `MakeEnvironment` placeholder. We patch the slot
    // count once the body has been compiled and we know how many
    // bindings the function needs.
    try self.builder.emitOp(.make_environment, span);
    const slot_count_patch = self.builder.here();
    try self.builder.emitU8(0);

    // §10.4.4 Implicit `arguments` binding for non-arrow
    // functions. Installed BEFORE the param prologue so default
    // expressions like `function f(x = arguments[2])` observe the
    // full caller argumentsList — §10.2.10 step 22/27
    // evaluates parameter initializers in a scope where
    // `arguments` is already bound. Only emitted when the body
    // or any param default references `arguments`, otherwise the
    // slot is saved. V8 / JSC / SpiderMonkey all install up
    // front; installing after params is an observable strict-mode
    // bug that flips `arguments.length` and indexed access on
    // unbound trailing args.
    if (!is_arrow) {
        const refs = paramsReferenceArguments(self.source, params) or switch (body) {
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

    // Declare params (env slots 0, 1,...) and emit the param-
    // receive preamble. Each arg arrives in caller-supplied
    // register r{i}; we Ldar then StaEnv into the function's
    // own env slot.
    //
    // §10.2.4 IteratorBindingInitialization — reserve the leading
    // register slots r0..r{params.len-1} as off-limits for the
    // temp allocator while the prologue runs. Without this,
    // `function f(x = arguments[2], y = arguments[3])` had the
    // default-expression compiler grab r0 / r1 as scratch
    // (for the `lda_computed` receiver), overwriting the
    // caller-supplied arg in register 1 with a saved
    // arguments-object handle — so `y` later read the
    // wrong register and got the arguments object instead of
    // its caller-supplied undefined. Restored to 0 after the
    // loop; named-binding values now live in env slots, so the
    // registers are free for body temps.
    const saved_prologue_temps = self.temps_in_use;
    self.temps_in_use = @intCast(@min(params.len, std.math.maxInt(u8)));
    if (self.temps_in_use > self.builder.register_count) {
        self.builder.register_count = self.temps_in_use;
    }
    for (params, 0..) |*p, i| {
        switch (p.*) {
            .simple => |*sp| try self.emitParamPrologue(sp, @intCast(i)),
            .rest => |*rp| try self.emitRestParamPrologue(rp, @intCast(i)),
        }
    }
    self.temps_in_use = saved_prologue_temps;

    // §27.5 / §27.6 — param init has run; suspend so the
    // wrapper can be handed back. Body resumes on first
    // `.next(arg)`.
    if (is_generator) {
        try self.builder.emitOp(.gen_initial_suspend, span);
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
    if (has_fn_name_env) name_scope.deinit(self.allocator);
    self.pending_labels.deinit(self.allocator);

    // Restore outer state.
    self.builder = saved_builder;
    self.scope = saved_scope;
    self.env_slot_count = saved_env_slot_count;
    self.temps_in_use = saved_temps_in_use;
    self.env_depth = saved_env_depth;
    self.current_loop = saved_current_loop;
    self.current_is_async = saved_is_async;
    self.pending_labels = saved_pending_labels;

    const sp_len = computeSpecLength(params);
    return self.builder.addFunctionTemplate(.{
        .chunk = inner_chunk,
        .param_count = @intCast(params.len),
        .spec_length = sp_len,
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
    defer c.pending_labels.deinit(c.allocator);
    c.diagnostics = diagnostics;

    var script_scope: Scope = .{ .parent = null, .kind = .script };
    defer script_scope.deinit(c.allocator);
    c.scope = &script_scope;
    c.env_depth = 0;
    c.env_slot_count = 0;

    // §16.1.7 GlobalDeclarationInstantiation step 5-7 — validate
    // every top-level lex / var / function name against the
    // realm's existing global env BEFORE any installation. A
    // SyntaxError here aborts compilation cleanly: no partial
    // bindings are stamped on the realm. CanDeclareGlobalVar /
    // CanDeclareGlobalFunction failures set
    // `pending_global_decl_error`; the emit path below builds a
    // chunk whose first opcode is an unconditional TypeError
    // throw, with NO hoist installation.
    try c.validateGlobalDeclarations(program.body);

    const start_span: Span = .{ .start = 0, .end = 0 };
    try c.builder.emitOp(.make_environment, start_span);
    const slot_count_patch = c.builder.here();
    try c.builder.emitU8(0);

    if (c.pending_global_decl_error) |name| {
        // §9.1.1.4.15 / .16 step 1.b TypeError. The throw is a
        // single message-bearing TypeError, then return — the rest
        // of the script body is dead code that never runs (and is
        // omitted to keep the chunk small).
        try c.emitGlobalDeclThrow(name, start_span);
    } else {
        // Slot-indexed global-lexical access: snapshot the realm's
        // declarative env-record size BEFORE `hoistLetConst`
        // installs this script's top-level `let` / `const` /
        // `class` bindings. Each such binding takes the next
        // 0-based slot (`next_global_lex_slot`); the runtime index
        // is `global_lexical_base + slot`. A realm runs multiple
        // scripts, so script 2's slot 0 is `decl_env` index N, not
        // 0 — this snapshot is what makes the multi-script case
        // correct. Stamp the base into the script body chunk's
        // builder; every nested-function sub-builder copies it via
        // `freshSubBuilder` so the whole tree shares one base.
        c.global_lexical_base = @intCast(c.realm.globals.decl_env.count());
        c.builder.global_lexical_base = c.global_lexical_base;
        try c.hoistLetConst(program.body);
        try c.hoistVarAndFunctions(program.body);
        try c.emitVarInits(start_span);

        // §14.1.3 — top-level function declarations are evaluated
        // before any other statement so forward calls (`f();
        // function f(){}`) resolve. Block-nested function decls
        // (strict-mode lexical) stay where they are.
        for (program.body) |*s| if (s.* == .function_decl) try c.compileStatement(s);
        for (program.body) |*s| if (s.* != .function_decl) try c.compileStatement(s);
    }

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
    defer c.pending_labels.deinit(c.allocator);
    c.diagnostics = diagnostics;
    c.is_module = true;

    // §9.4.6.7 Module Namespace [[Get]] — collect (local-name →
    // exported-aliases) so subsequent stores to top-level
    // bindings auto-publish onto the namespace, giving spec-
    // mandated live-binding semantics. Allocated on the compile-
    // time arena (`c.allocator`) and torn down via `deinit` below
    // after `c.finish` has produced the immutable chunk.
    var exports_by_local: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        var it_e = exports_by_local.iterator();
        while (it_e.next()) |entry| entry.value_ptr.deinit(c.allocator);
        exports_by_local.deinit(c.allocator);
    }
    try collectLiveExports(&c, program.body, &exports_by_local);
    c.module_exports_by_local = &exports_by_local;

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

    // §8.1.1.5.5 CreateImportBinding + §15.2.1.16.4 step 12 — at
    // module instantiation we need every exported TDZ-tracked
    // binding (`export let`, `export const`, `export class`,
    // `export default class`, `export default <named-expr>` /
    // `export default <anonymous-expr>` etc.) to be visible on
    // the namespace as `Hole`, so an importing module's indirect
    // read (lda_property + throw_if_hole) gets the spec-mandated
    // ReferenceError before the source body has run its decl.
    //
    // Re-exports (`export { A as B } from './x.js'`) and star
    // re-exports (`export * from`) DO NOT seed Hole here — they
    // resolve through their source module at access time and
    // never bind in the current env. `export var X` also skips
    // (var is initialised to `undefined` at hoist, no TDZ).
    // `export function` is already initialised to its closure
    // value below; seeding Hole would be observably wrong.
    try c.seedTdzExportHoles(program.body, start_span);

    // sec-moduledeclarationinstantiation -- ordered phases before body:
    //   1. FunctionDeclarations + GeneratorDeclarations, including
    //      `export <fn-decl>` wrappers (step 17). For exported forms
    //      also publish the module_export here so a self-import cycle
    //      re-entering during `evaluating` finds the live function on
    //      the partial namespace. Must precede imports so the partial
    //      namespace handed to a cycling importer already has these
    //      bindings published.
    //   2. ImportDeclarations resolve and bind (steps 9-12). Hoisted
    //      to the top of the body proper so a top-of-body reference
    //      to an imported name sees the resolved binding, not the TDZ.
    //   3. Remaining body statements run in source order.
    for (program.body) |*s| {
        switch (s.*) {
            .function_decl => try c.compileStatement(s),
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| if (inner.* == .function_decl) {
                    try c.compileStatement(s);
                },
                // §15.2.3.11 ExportDeclaration : `export default
                // HoistableDeclaration` — the Hoistable case covers
                // anonymous FunctionDeclaration / GeneratorDeclaration
                // / AsyncFunctionDeclaration / AsyncGeneratorDeclaration
                // exports. Cynic's AST parses these as a `default_value`
                // wrapping a `function_expr` (since the parser already
                // had the expression form). Treat them as hoistable
                // declarations: evaluate the function template here
                // and publish on the partial namespace under `"default"`
                // BEFORE imports resolve, so a cycle re-entering the
                // module sees the closure (and a same-module
                // `import f from './self.js'` lands on the live
                // binding instead of `undefined`).
                //
                // The named variant `export default function F() {}`
                // also creates a *local* `F` binding (§15.2.3.11 +
                // §15.2.1.16.4 step 17 path); the body of the module
                // can reference `F` directly. We materialise the
                // template once, store it via `emitStoreBindingInit`
                // for the local binding, then re-read for the
                // `default` publish so both views share one closure.
                .default_value => |dv| if (dv == .function_expr) {
                    const fe = dv.function_expr;
                    if (fe.name) |n| {
                        const name_slice = try c.bindingName(n.span);
                        const binding = try c.declareBindingFull(name_slice, .var_, n.span);
                        const k_tmpl = try compileFunctionTemplateExt(
                            &c,
                            fe.params,
                            FunctionBody{ .block = fe.body.body },
                            name_slice,
                            false,
                            fe.is_generator,
                            fe.is_async,
                            fe.span,
                        );
                        try c.builder.emitOp(.make_function, fe.span);
                        try c.builder.emitU16(k_tmpl);
                        try c.emitStoreBindingInit(binding, fe.span);
                        try c.emitBindingRead(name_slice, fe.span);
                        const k_default = try c.internString("default");
                        try c.builder.emitOp(.module_export, ed.span);
                        try c.builder.emitU16(k_default);
                    } else {
                        try c.compileExpression(&ed.body.default_value);
                        const k_default = try c.internString("default");
                        try c.builder.emitOp(.module_export, ed.span);
                        try c.builder.emitU16(k_default);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
    var any_import = false;
    for (program.body) |*s| if (s.* == .import_decl) {
        any_import = true;
        try c.compileStatement(s);
    };
    // §16.2.1.5 InnerModuleEvaluation — after the import hoist,
    // drain microtasks so any async dep that suspended at TLA
    // settles before the body proper observes its exports
    // (and so a rejection propagates as a throw at this
    // boundary). Only emit when the module actually has imports;
    // a zero-import module would never have populated
    // `pending_async_deps`, and the opcode no-ops anyway.
    if (any_import) {
        const link_span: Span = .{ .start = 0, .end = 0 };
        try c.builder.emitOp(.module_link_complete, link_span);
    }
    for (program.body) |*s| {
        switch (s.*) {
            .import_decl, .function_decl => {},
            .export_decl => |ed| switch (ed.body) {
                .declaration => |inner| if (inner.* == .function_decl) {} else try c.compileStatement(s),
                // §15.2.3.11 — Hoistable defaults already published
                // in phase 1; skip the body-phase compile to avoid
                // a double `module_export` (and a wasted
                // template-build on each module evaluation).
                .default_value => |dv| if (dv == .function_expr) {} else try c.compileStatement(s),
                else => try c.compileStatement(s),
            },
            else => try c.compileStatement(s),
        }
    }

    const end_span: Span = .{
        .start = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
        .end = if (program.body.len > 0) program.body[program.body.len - 1].span().end else 0,
    };
    try c.builder.emitOp(.return_, end_span);

    c.builder.code.items[slot_count_patch] = c.env_slot_count;
    // §16.2.1.5.1 [[IsAsync]] — surface the top-level-await flag
    // accumulated by `compileAwait` so the runtime knows to wrap
    // this module's evaluation as an async function call.
    c.builder.is_async_module = c.module_has_top_level_await;
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
    defer c.pending_labels.deinit(c.allocator);
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
