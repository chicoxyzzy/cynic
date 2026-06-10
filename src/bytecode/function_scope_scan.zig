//! Function-entry environment elision — AST predicate.
//!
//! `compileFunctionTemplateExtNamed` emits a leading
//! `make_environment` for every compiled function so a fresh
//! per-call DeclarativeEnvironment exists for that body's
//! bindings (§10.2.10 FunctionDeclarationInstantiation). When the
//! function declares no bindings of its own — no params, no
//! implicit `arguments`, no `var` / `function` / `let` / `const` /
//! `class` anywhere in the body (recursive, stopping at inner
//! function / class boundaries) — the env is empty and
//! unreferenced. Cynic's strict-only target means no `with`, and
//! direct `eval` binds in its own per-invocation env (§19.2.1.3)
//! rather than the caller's. So the env is observably elidable.
//!
//! This predicate is the discovery half of the two-pass scope
//! compile: pure AST walk, no compiler state. If it returns
//! `false`, the caller skips the `make_environment` emit and
//! leaves `env_depth` at its outer value so `lda_env` / `sta_env`
//! depth deltas (computed against outer-scope bindings; this
//! function declared none) stay consistent with the runtime env
//! chain (which is one link shorter when elided).
//!
//! **Why a conservative full walk.** Cynic flattens block-scoped
//! `let` / `const` / `class` into the function-entry env — a
//! plain `{ }` block has no runtime env of its own
//! (`compileBlock` does NOT save / reset `env_slot_count`), so a
//! nested `let x` allocates a function-entry-env slot. A more
//! precise predicate would carve out the for-loop / for-in-of
//! per-iter envs (those DO get their own slot pool) and the
//! switch-case-block env, but those decisions depend on dynamic
//! capture analysis the predicate doesn't redo. The conservative
//! walk over-flags loops like `for (let i = 0; ...; ...) { ... }`
//! that the per-iter machinery would in fact contain, missing
//! some elision opportunities. The hot elision targets —
//! parameter-less methods (`inc() { this.n++; }`), no-param
//! arrows (`() => this.x + 1`), thin IIFEs, simple constructors —
//! have no body bindings at all, so they're caught either way.

const std = @import("std");
const ast = @import("../ast.zig");
const arguments_scan = @import("arguments_scan.zig");

/// Returns true when the function-entry `make_environment` is
/// required. Returns false when it can be elided.
///
/// `body_stmts == null` is a concise-body arrow (a single
/// expression with no declarations possible).
pub fn functionEntryEnvNeeded(
    source: []const u8,
    params: []const ast.statement.FunctionParam,
    body_stmts: ?[]ast.statement.Statement,
    is_arrow: bool,
    top_lex_promoted: bool,
) bool {
    // §10.2.4 IteratorBindingInitialization — every parameter
    // becomes an env binding, so the env must exist whenever the
    // parameter list is non-empty.
    if (params.len > 0) return true;

    const stmts = body_stmts orelse return false;

    // §10.4.4 Implicit `arguments` binding for non-arrow
    // functions. Installed when the body mentions `arguments`,
    // taking the first env slot.
    if (!is_arrow and arguments_scan.referencesArguments(source, stmts)) return true;

    for (stmts) |*s| {
        // Body-locals register promotion: when the caller promotes
        // top-level simple `let` / `const` declarators into
        // registers (`hoistLetConst`'s `promote_top_lex` path),
        // those statements stop being env consumers. The predicate
        // here must mirror the hoist's promotion predicate exactly
        // — both call `topLevelLexIsPromotable`.
        if (top_lex_promoted and topLevelLexIsPromotable(s)) continue;
        if (statementIntroducesBinding(s)) return true;
    }
    return false;
}

/// The shared promotion predicate for one function-body-top-level
/// statement: a `let` / `const` declaration (not `var`, not
/// `using` — dispose machinery needs real scope semantics) whose
/// declarators are all simple identifiers. Used by
/// `functionEntryEnvNeeded` above and the compiler's
/// `hoistLetConst` so the env-elision decision and the actual
/// declaration path can never disagree.
pub fn topLevelLexIsPromotable(s: *const ast.statement.Statement) bool {
    if (s.* != .lexical) return false;
    const ld = s.lexical;
    if (ld.kind != .let_ and ld.kind != .const_) return false;
    for (ld.declarators) |d| {
        if (d.name != .identifier) return false;
    }
    return true;
}

/// Walk `s` looking for any declaration that would land in the
/// function-entry env. Recurses through nested control-flow but
/// stops at inner function / class boundaries — those introduce
/// their own scopes and don't contribute to this function-entry
/// env.
fn statementIntroducesBinding(s: *const ast.statement.Statement) bool {
    return switch (s.*) {
        // §13.3 LexicalDeclaration / VariableStatement — `let`,
        // `const`, `var`, `using`, `await using`. All allocate
        // function-entry-env slots when declared in a position
        // that lacks its own env (plain blocks, function-body
        // top level, etc.). The for-loop / for-in-of head cases
        // would in fact go into a per-iter env, but we
        // conservatively flag them here so the caller doesn't
        // need to redo the capture analysis that picks per-iter.
        .lexical => true,
        // §14.5 / §15.7 — `function f` and `class C` bind their
        // names in the enclosing scope (var-hoisted at function
        // top level, lex-bound in nested blocks). Either way the
        // slot comes from the function-entry env.
        .function_decl, .class_decl => true,
        .export_decl => |ed| switch (ed.body) {
            .declaration => |inner| statementIntroducesBinding(inner),
            else => false,
        },
        .block => |b| blockIntroducesBinding(b.body),
        .if_ => |i| blk: {
            if (statementIntroducesBinding(i.consequent)) break :blk true;
            if (i.alternate) |alt| if (statementIntroducesBinding(alt)) break :blk true;
            break :blk false;
        },
        .while_ => |w| statementIntroducesBinding(w.body),
        .do_while => |dw| statementIntroducesBinding(dw.body),
        .for_ => |f| blk: {
            if (f.init) |head| switch (head) {
                .lexical => break :blk true,
                .expression => {},
            };
            break :blk statementIntroducesBinding(f.body);
        },
        .for_in_of => |f| blk: {
            switch (f.left) {
                .lexical => break :blk true,
                .expression => {},
            }
            break :blk statementIntroducesBinding(f.body);
        },
        .try_ => |t| blk: {
            // §14.15 CatchParameter — when present, the catch
            // identifier (or `__cynic_catch_ex__` synth slot for
            // a destructuring pattern) declares a function-entry
            // env slot at emit time (`compileTry` does not reset
            // `env_slot_count` around the catch_scope), regardless
            // of where the spec would place it.
            if (t.handler) |h| if (h.param != null) break :blk true;
            // §14.15.3 abrupt-completion handler — every try with
            // a finalizer declares a synthetic `__cynic_finally_ex__`
            // slot at emit time to thread the saved abrupt value
            // through the dispose / rethrow path.
            if (t.finalizer != null) break :blk true;
            // No synth-slot triggers — walk the bodies for inner
            // declarations.
            if (blockIntroducesBinding(t.block.body)) break :blk true;
            if (t.handler) |h| if (blockIntroducesBinding(h.body.body)) break :blk true;
            if (t.finalizer) |fin| if (blockIntroducesBinding(fin.body)) break :blk true;
            break :blk false;
        },
        .switch_ => |sw| blk: {
            for (sw.cases) |c| if (blockIntroducesBinding(c.body)) break :blk true;
            break :blk false;
        },
        .labeled => |lb| statementIntroducesBinding(lb.body),
        // Function / class / arrow expressions inside an
        // expression context don't add to our env — they have
        // their own. Same for `return e`, `throw e`, etc.
        else => false,
    };
}

fn blockIntroducesBinding(stmts: []const ast.statement.Statement) bool {
    for (stmts) |*s| if (statementIntroducesBinding(s)) return true;
    return false;
}
