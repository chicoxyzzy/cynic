//! Compile-time lexical scope chain.
//!
//! Each `Scope` is a name → register mapping owned by the compiler.
//! Scopes nest: the parser opens a new block-scope on every `{` /
//! `for (let …)` / `for (const …)` head, and the script body is
//! one outer "function scope" (later will introduce nested function
//! scopes — the API is shaped for that already).
//!
//! Binding kinds (`var` vs `let`/`const`) determine:
//! • Where the binding lives. `var` is hoisted to the nearest
//! function/script scope (§13.3.2). `let`/`const` is
//! block-scoped (§13.3.1).
//! • Whether reads emit `ThrowIfHole`. `let`/`const` need it
//! (TDZ runs from block entry to the binding's initialiser).
//! `var` doesn't (initialised to `undefined` at hoist).
//! • Whether assignments are allowed. `const` reassignment is a
//! compile-time error (`assignment_to_const`).
//!
//! The compiler reserves registers for every binding declared in a
//! scope at *scope-open* time (a pre-pass that walks the
//! StatementList for declarations). The bytecode prologue then
//! emits `LdaUndefined` / `LdaHole` plus `Star` for each. This is
//! how Ignition + Hermes both arrange it: the binding's slot is
//! present from the moment the scope is entered, even though the
//! TDZ check guards user-visible access until initialisation.

const std = @import("std");

const Span = @import("../source.zig").Span;

pub const BindingKind = enum {
    var_,
    let_,
    const_,
};

pub const Binding = struct {
    /// Borrowed slice into the original source text. Lifetime ties
    /// to the parser's source buffer, which outlives compilation.
    name: []const u8,
    /// Env slot — index into the enclosing function-like scope's
    /// `Environment.slots`. later puts every named binding in a
    /// heap environment; the compiler still uses register slots
    /// for anonymous temporaries. Unused when `is_global`; reads
    /// and writes route through `lda_global` / `sta_global` keyed
    /// by `name`.
    env_slot: u8,
    /// Number of function-like scopes between the outermost
    /// scope (script, env_depth=0) and the function that
    /// owns this binding. Used to compute the `depth` operand of
    /// `LdaEnv` / `StaEnv` at use sites:
    /// `depth = compiler.current_env_depth - binding.env_depth`.
    env_depth: u8,
    kind: BindingKind,
    /// Source span of the binding identifier — used for
    /// diagnostics on duplicate declarations / const reassignment.
    span: Span,
    /// True when this binding lives on the realm's global
    /// bindings map rather than on any per-frame `Environment`.
    /// Set for top-level `var` / `let` / `const` / `function`
    /// declarations in script bodies (later — multiple Scripts per
    /// Realm). Reads emit `lda_global` (with `throw_if_hole` for
    /// `let` / `const`) and writes emit `sta_global`, both keyed
    /// by `name`. Module top-level bindings keep `is_global =
    /// false` — module bindings are lexically local to the
    /// module, not global. Likewise nested function bodies always
    /// use env slots.
    is_global: bool = false,
    /// §8.1.1.5.5 CreateImportBinding — when true, this binding is
    /// an indirect alias for `(namespace, import_name)` rather
    /// than a value-holding env slot. Reads dereference through
    /// the namespace object stored in `import_ns_slot`; writes
    /// throw a TypeError (import bindings are immutable per spec).
    /// V8 / JSC / SpiderMonkey all implement imports as indirect
    /// slots so the live-binding semantics fall out for free —
    /// the importer sees post-init state of the source module's
    /// binding without any explicit refresh.
    is_import: bool = false,
    /// Env slot holding the loaded module's namespace object —
    /// `compileImportDecl` allocates one persistent slot per
    /// `import` declaration and seeds it with the result of
    /// `module_load`. Only meaningful when `is_import` is true.
    import_ns_slot: u8 = 0,
    /// Property key to read off the namespace — `"default"` for
    /// default imports, the imported export name otherwise.
    /// Borrowed; lives as long as the parser arena / compiler
    /// arena that produced it. Only meaningful when `is_import`
    /// is true.
    import_name: []const u8 = "",
};

pub const ScopeKind = enum {
    /// The implicit top-level scope of a Script. Function-like
    /// (introduces an environment); `var` and `function`
    /// declarations from any nested block hoist here.
    script,
    /// A function / arrow body's outer scope. Function-like —
    /// `var` / `function` hoists to the nearest one.
    function,
    /// A `{... }` BlockStatement scope. NOT function-like —
    /// `var` walks past, `let` / `const` stop here. Bindings
    /// declared in a block still live in the enclosing
    /// function's environment (later single env per function;
    /// later may add per-block envs for tighter loop-let
    /// semantics).
    block,
};

pub const Scope = struct {
    parent: ?*Scope,
    kind: ScopeKind,
    /// Bindings introduced *in this scope*. Lookup walks up the
    /// chain when a name doesn't appear here. Insertion is
    /// append-only, so iteration order matches declaration order
    /// (used by the prologue).
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    /// Whether this scope owns its own runtime environment.
    /// Function-like scopes (`script` / `function`) always do
    /// (their prologue emits `make_environment N`). Block
    /// scopes opt in for closure-per-iteration in
    /// `for (let x of …)` — every iteration emits a
    /// fresh `make_environment 1` so closures captured inside
    /// the body see distinct bindings (§14.7.5.6
    /// CreatePerIterationEnvironment).
    has_own_env: bool = false,

    pub fn isFunctionLike(self: *const Scope) bool {
        return self.kind == .script or self.kind == .function;
    }

    /// Find the binding for `name`, looking up through parents.
    /// Returns the closest match; nested-shadowing falls out
    /// naturally because we walk innermost-first.
    pub fn resolve(self: *Scope, name: []const u8) ?Binding {
        var cursor: ?*Scope = self;
        while (cursor) |s| : (cursor = s.parent) {
            for (s.bindings.items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b;
            }
        }
        return null;
    }

    /// Same as `resolve`, but only searches *this* scope —
    /// duplicate-detection on `let` / `const` declaration.
    pub fn lookupLocal(self: *Scope, name: []const u8) ?Binding {
        for (self.bindings.items) |b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Scope: lookupLocal finds in-scope, ignores parent" {
    var script: Scope = .{ .parent = null, .kind = .script };
    defer script.deinit(testing.allocator);
    var block: Scope = .{ .parent = &script, .kind = .block };
    defer block.deinit(testing.allocator);

    try script.bindings.append(testing.allocator, .{
        .name = "outer",
        .env_slot = 0,
        .env_depth = 0,
        .kind = .var_,
        .span = .{ .start = 0, .end = 5 },
    });
    try block.bindings.append(testing.allocator, .{
        .name = "inner",
        .env_slot = 1,
        .env_depth = 0,
        .kind = .let_,
        .span = .{ .start = 6, .end = 11 },
    });

    try testing.expect(block.lookupLocal("inner") != null);
    try testing.expect(block.lookupLocal("outer") == null);
    try testing.expect(script.lookupLocal("outer") != null);
}

test "Scope: resolve walks the chain innermost-first" {
    var script: Scope = .{ .parent = null, .kind = .script };
    defer script.deinit(testing.allocator);
    var block: Scope = .{ .parent = &script, .kind = .block };
    defer block.deinit(testing.allocator);

    try script.bindings.append(testing.allocator, .{
        .name = "x",
        .env_slot = 0,
        .env_depth = 0,
        .kind = .var_,
        .span = .{ .start = 0, .end = 1 },
    });
    try block.bindings.append(testing.allocator, .{
        .name = "x",
        .env_slot = 1,
        .env_depth = 0,
        .kind = .let_,
        .span = .{ .start = 5, .end = 6 },
    });

    // Inner `let x` shadows outer `var x`.
    const r = block.resolve("x").?;
    try testing.expectEqual(@as(u8, 1), r.env_slot);
    try testing.expectEqual(BindingKind.let_, r.kind);

    // Outer scope still sees its own `x`.
    const outer = script.resolve("x").?;
    try testing.expectEqual(@as(u8, 0), outer.env_slot);
}

test "Scope: resolve returns null on missing names" {
    var s: Scope = .{ .parent = null, .kind = .script };
    defer s.deinit(testing.allocator);
    try testing.expect(s.resolve("nope") == null);
}
