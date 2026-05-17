# Environment records

What Cynic ships today for the spec's lexical environment
machinery (§9.1). Read before touching binding declaration,
resolution, or the global object's relationship to scripts /
modules.

## The four record kinds Cynic models

§9.1.1 names five; Cynic ships four (no `ObjectEnvironmentRecord`
in the `with`-statement sense — Cynic is strict-only, no `with`).

| Spec record | Cynic representation |
|---|---|
| **DeclarativeEnvironmentRecord** | `Environment` (`src/runtime/environment.zig`) — fixed-slot array; one struct per active frame. |
| **FunctionEnvironmentRecord** | Same `Environment`, with the function's args, `this`, and home-object plumbed through `JSFunction` rather than the env itself. |
| **ModuleEnvironmentRecord** | Same `Environment`, but the importer's bound names carry `is_import = true` (indirect read through the imported module's namespace; immutable). |
| **GlobalEnvironmentRecord** | `GlobalBindings` (`src/runtime/realm.zig`) — split structure described below. |

Block scopes (`{...}`, `for (let …)`, etc.) live as fresh
`Environment` instances chained via the `parent` pointer;
`for (let)` per-iteration freshness uses `CreatePerIterationEnvironment`-equivalent
re-allocation per the spec.

## GlobalEnvironmentRecord — the split

The global record is the only kind whose internals diverge from
the plain `Environment` struct. Per §9.1.1.4 it composes:

- an `ObjectEnvironmentRecord` over the global object (host-
  installed bindings: `Array`, `Math`, `print`; plus top-level
  `var` / `function` declarations);
- a `DeclarativeEnvironmentRecord` for top-level `let` / `const` /
  `class` (NOT mirrored on `globalThis`);
- a `[[VarNames]]` set tracking the names declared via `var` /
  `function` (drives the §16.1.7 step-5 collision check).

Cynic's `GlobalBindings` holds all three:

```zig
pub const GlobalBindings = struct {
    target: ?*JSObject,                 // ← the global object
    fallback: StringArrayHashMap(Value),
    decl_env: StringArrayHashMap(Value),    // §9.1.1.4 declarative record
    decl_consts: StringArrayHashMap(bool),  // is-const flag per decl_env entry
    var_names: StringArrayHashMap(void),    // §9.1.1.4.2 [[VarNames]]
    ...
};
```

Read path priority (§9.1.1.4 GetBindingValue): `decl_env` first,
then `target` (the object record). The interpreter's `lda_global`
runs this priority; the property-bag fall-through is what makes
`Array` resolve from intrinsics even though `decl_env` doesn't
hold it.

Write path opcodes:

| Opcode | When emitted | Semantics |
|---|---|---|
| `sta_global_init` | Top-level identifier `let x = e;` / `const x = e;` | Unconditional write into `decl_env`. The slot was hoisted as `Hole`; this fills it. No immutability gate. |
| `sta_global_fn_decl` | Top-level `function f(){}` (§9.1.1.4.19 CreateGlobalFunctionBinding) | Write into the object record AND stamp `{writable, enumerable, !configurable}` descriptor. Overwrites any prior accessor. |
| `sta_global` | Identifier assignment `x = e` at top level | Resolves via priority. Lex const: throw TypeError UNLESS the slot is still `Hole` (then it's the destructuring-binding init; fill the slot). Lex non-const: write into `decl_env`. Otherwise into the object record. |
| `sta_global_strict` | Identifier assignment where the LHS was an unresolvable reference (`y = 1` for undeclared `y`) | Throws ReferenceError (strict mode is Cynic's only mode). |

The const Hole-check on `sta_global` is the subtle piece —
without it, destructuring declarations (`const [x] = iter;`)
fail because the destructuring path lowers each leaf through the
generic `assignToBinding` → `sta_global` rather than
`sta_global_init`, and the binding's slot is still the TDZ Hole
at first write. Distinguishing InitializeBinding from
SetMutableBinding at runtime via the Hole sentinel is
spec-equivalent and simpler than threading an `is_init` flag
through every destructuring helper.

## Early errors for global declarations

§16.1.7 GlobalDeclarationInstantiation steps 5–7 mandate four
pre-evaluation checks per script body. Cynic runs them as one
pass in `validateGlobalDeclarations` (compile-time, before any
hoist):

1. `lex` vs `lex` collision — two top-level `let`/`const`/`class`
   with the same name. SyntaxError.
2. `lex` vs `var` collision — both forms declare the same name.
   SyntaxError.
3. `HasRestrictedGlobalProperty` — declaring a name that exists
   as a non-configurable own property on the global object
   (test262's `NaN`, `Infinity`, `undefined`, etc.). SyntaxError.
4. `CanDeclareGlobalVar` / `CanDeclareGlobalFunction` on a
   non-extensible global — TypeError. Deferred to runtime via
   `pending_global_decl_error`; the compiled chunk emits a
   `throw new TypeError()` as its first opcode so no user
   statement runs.

Modules skip this entire pass — `validateGlobalDeclarations`
short-circuits when `is_module`. Module top-level bindings live
in the module's own `ModuleEnvironmentRecord`, not the global
declarative record.

## Named function expressions — §15.6.5

`let r = function G() { … G … }` exposes `G` as an immutable
self-binding visible only inside the function's body. The spec
models this with a one-binding `DeclarativeEnvironmentRecord`
that wraps the function's captured outer env.

Cynic implements it with a synthetic 1-slot wrapper env between
the function's body env and the outer captured env:

- Compiler splices a synthetic `Scope` whose only binding has
  `is_fn_expr_name = true` and `kind = .const_`.
- New opcode `make_named_function_expr` allocates the 1-slot
  wrapper, instantiates the function capturing the wrapper, and
  seeds slot 0 with the function itself.
- Inner writes lower to `throw_assign_const` (the existing
  import-binding TypeError path) so `G = 1` from inside the body
  throws TypeError at runtime per §8.1.1.1.4 step 9.b.

The compile-time `const` reassignment diagnostic
(`assignment_to_const`) skips when `is_fn_expr_name = true` —
the spec rejects at PutValue (runtime), not at parse, so user
code can `try { G = 1; } catch (e) { assert(e instanceof TypeError) }`
from inside the body.

## Module environments

Module top-level bindings are stored in plain `Environment`
slots, **not** in `GlobalBindings`. Imports carry
`is_import = true` and read through their source module's
namespace (an indirect alias per §8.1.1.5.5 CreateImportBinding,
TDZ-Hole-seeded at module-instantiation time). Writes to an
import emit `throw_assign_const` (TypeError per §8.1.1.5.5 —
import bindings are immutable).

The Module Namespace exotic ([[Get]] §9.4.6.7) routes through
the source module's env-record `GetBindingValue` with
`strict = true`, so a `ns.uninit_const` access during the source
module's TDZ throws ReferenceError. `[[HasProperty]]` and
`[[OwnPropertyKeys]]` do NOT — only `[[Get]]` honors the TDZ.
The namespace's `@@toStringTag = "Module"` is installed at
brand-on-allocation time (alongside `is_module_namespace = true`
and `prototype = null`); cycles re-entering during evaluation
see the right tag even though `extensible` is still `true`
until the body returns.

### Top-level await — the link-complete boundary

A module body with TLA compiles with
`chunk.is_async_module = true`; `interpreter.run` routes it
through `startAsyncCall` to produce an evaluation Promise. When
the body suspends at the first top-level `await`, `loadModule`
records the dep on the importer's
`ModuleRecord.pending_async_deps` (Cynic's lightweight stand-in
for §16.2.1.5 [[PendingAsyncDependencies]]).

The compiler emits a `module_link_complete` opcode after the
importer's hoisted import block — before the body proper runs.
The opcode drains the microtask queue (so any async dep
suspended on `await` gets to resume before the importer
observes its exports), then walks `pending_async_deps` and
unwinds throw if any dep's evaluation Promise rejected
(approximating §16.2.1.9 AsyncModuleExecutionRejected's parent
path). Sync siblings ran during the import hoist itself, so a
sync module that destructures `globalThis` captures values from
*before* any async sibling resumes — the spec ordering for
`async-module-does-not-block-sibling-modules`.

What this approximation skips: the full
[[AsyncEvaluationOrder]] sort and the reverse
[[AsyncParentModules]] propagation. Sufficient for the entire
`top-level-await` fixture bucket today, but a future cycle test
that exercises the sort would need the real machinery.

### Dynamic import + async deps

`dynamic_import` calls `loadModule` and inspects the returned
`mr` — if `state == .evaluating_async`, it drains microtasks
until the dep's `evaluation_promise` settles, then wraps the
final namespace in a fulfilled (or rejected) Promise. Without
this, `await import("./tla")` would return the dep's pre-TLA
partial namespace.

### Lexical private-name resolution

Private names (`#x`) are lexically scoped to the *declaring*
class, not the innermost enclosing one. The compiler gathers
each class's `#name`s into `ClassContext.private_names` and the
`manglePrivateRef` helper walks `class_stack` outward to find
the right declaring class — handles the `class Outer { #x;
inner() { return [class { method() { return obj.#x; } }]; } }`
case where the inner anonymous class refers to Outer's `#x`.
The runtime carries `private_compile_prefix` alongside
`private_brand` on every class prototype and constructor;
`framePrivateBrand` matches the mangled key's `P{n}#` prefix
against the receiver's prototype chain to pick the right
per-evaluation brand. See `bytecode/compiler.zig` /
`runtime/class.zig` / `runtime/interpreter.zig`.

## Why this matters for binding-touching changes

Any edit that adjusts how names declare or resolve at the top
level needs to verify all four record kinds still behave
correctly:

- script top-level (GlobalEnvironmentRecord split);
- module top-level (ModuleEnvironmentRecord);
- function body / arrow / block (DeclarativeEnvironmentRecord
  chain);
- named function expression body (synthetic 1-slot wrapper).

See [`agent-checks.md`](agent-checks.md) for the regression
filter table — `bytecode/compiler.zig` (binding/scope) touches
all four.
