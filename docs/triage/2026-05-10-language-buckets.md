# language/{expressions,statements} triage — 2026-05-10

Mode: `--mode=runtime --threads=4`. Counts come from
`/tmp/lang-expr-full.txt` (4148 fails) and `/tmp/lang-stmt-full.txt`
(4202 fails). Note: harness labels every runtime fail
"false-reject" — the label is misleading but the file paths are
genuine runtime failures (parser-only re-runs of the same fixtures
mostly pass).

## Top-level shared root causes (rank by leverage)

These cut across BOTH buckets:

1. **Destructuring at runtime is broken end-to-end (~1700+ fails).**
   `let [a]=[1]`, `let {a}=...`, `[a]=[1]`, `({a}=...)`, function
   params `function f([a]){}`, `for (let [a] of ...)` — all fail
   at the bytecode-compile stage with "CompileError". Surfaces as:
   - all `class/dstr/*` (754 expr + 754 stmt = 1508)
   - `object/dstr/*` (385), `assignment/dstr/*` (192), arrow `dstr`
   - `for-await-of/*-dstr-*` (~900), `for-of/dstr/*`, `for/dstr/*`,
     `variable/dstr/*` (~150 across statements)
   - Likely site: bytecode compiler — pattern lowering not wired.
     Search `src/bytecode/compiler.zig` (or `src/parser/codegen*`)
     for `BindingPattern` / `ArrayPattern` / `ObjectPattern`. Likely
     just falls through to an unsupported branch.
   - Size: **L** but very high leverage.

2. **`yield*` inside async generators is a CompileError (~600 fails).**
   `async function* g() { yield* [1,2]; }` fails to compile.
   `async-generator/*-yield-star-*` and `class/elements/async-gen-*`
   cluster. Plain (sync) `yield*` and plain async-gen `yield x`
   both work — only async-gen `yield*` is broken. Likely site:
   `src/bytecode/compiler.zig` (yield-star desugaring branch
   missing the async path that uses `Symbol.asyncIterator` +
   await-each). Size: **M**.

3. **`for await (… of …)` is a CompileError (~1100+ fails).**
   Affects all of `language/statements/for-await-of/*` (1113) and
   the async-iteration pieces of class/elements. Site: parser
   probably accepts; bytecode compiler missing the async-for-of
   lowering (await on `next()` and on `IteratorClose`). Size: **M-L**.

4. **Static private class members + private accessors broken
   (~830 fails).** Of `class/elements` 987, ~812 mention `private`
   in some shape; instance `#x = 1; this.#x` works, but
   `static #x` / `static #foo()` and `#getter`/`#setter` fail.
   `compound-assignment/*-private-reference-*` (84) and most of
   `class/elements/private-accessor-name` (40+) are the same root
   cause. Site: `src/runtime/class.zig` and the class-elements
   path of the bytecode compiler. Size: **M**.

5. **`super.foo()` / `super[expr]` runtime path broken
   (~60 fails across both buckets).** Repro
   `class B extends A { bar(){ return super.foo(); } }` fails to
   compile. Site: bytecode compiler's HomeObject / `MakeSuperPropertyReference`
   wiring. Drives `class/elements/super-*`, `expressions/super/*`,
   `arrow-function/lexical-super-property`. Size: **M**.

6. **Dynamic `import()` not wired at runtime (~305 expr fails).**
   All of `expressions/dynamic-import/*`. Out-of-scope-ish for
   minimal Cynic but high count. Likely intentionally deferred;
   noted, not investigated.

7. **`completion-value` / `cptn-*` fixtures use `eval()`
   (~70 stmt fails — out of scope).** All `statements/{try,switch,
   for,for-of,if,...}/cptn-*` use `eval('...')` to observe the
   completion value of a statement. eval is permanently out per
   AGENTS.md — these can be skip-listed wholesale.

## language/expressions — top sub-buckets

| # | Sub-bucket | Fails | Root cause | Site | Size |
|---|---|---|---|---|---|
| 1 | class/elements | 2093 | static #private + private-accessor + async-gen-private-method (most also need dstr/yield-star) | runtime/class.zig + bytecode compiler | M-L |
| 2 | class/dstr | 754 | destructuring in class methods (compounded with async-gen) | bytecode compiler | L |
| 3 | object | 553 | object-method dstr params (385) + async-gen / yield-star method-definition (143) | bytecode compiler | L |
| 4 | dynamic-import | 305 | not wired at runtime | runtime + intrinsics | L (deferred) |
| 5 | async-generator | 278 | yield* inside async-gen | bytecode compiler | M |
| 6 | assignment | 206 | destructuring-assignment LHS (192 of 206) | bytecode compiler | L |
| 7 | generators | 88 | dstr inside generator bodies | (same as #6) | included |
| 8 | compound-assignment | 84 | LHS is private-reference (`obj.#x += 1`) | bytecode compiler private-ref path | S |
| 9 | super | 54 | runtime `super.x` / `super[x]` | bytecode compiler | M |
| 10 | arrow-function | 47 | mostly dstr params + lexical super/new.target | (same as #1, #5, #9) | included |

## language/statements — top sub-buckets

| # | Sub-bucket | Fails | Root cause | Site | Size |
|---|---|---|---|---|---|
| 1 | class | 2273 | same as expressions/class — dstr + private + async-gen | bytecode compiler + class.zig | M-L |
| 2 | for-await-of | 1113 | `for await (...)` not lowered + dstr in head | bytecode compiler | M-L |
| 3 | for-of | 199 | dstr in head + `iterator-close` semantics | bytecode compiler | M |
| 4 | async-generator | 143 | yield* in async-gen | bytecode compiler | M |
| 5 | generators | 82 | dstr in generator params/locals | (same as #3) | included |
| 6 | for | 73 | dstr in init + completion-record cptn-* (eval) | bytecode compiler | M |
| 7 | function | 66 | mostly dstr params + a few completion-value | bytecode compiler | included |
| 8 | variable | 38 | dstr in `var` decl | bytecode compiler | included |
| 9 | try | 38 | mostly cptn-* (eval — skip) + a few catch-binding | mostly out-of-scope | S |
| 10 | switch | 28 | mostly cptn-* (eval) + scope-lex | mostly out-of-scope | S |
| 11 | for-in | 27 | dstr in head | (same as dstr) | included |

## Quick wins (smallest fix, biggest delta)

1. **Wire destructuring at the bytecode compiler.** Single
   surgical change in the binding-pattern lowering path. Instantly
   moves ~1700+ fails to pass across both buckets — every `dstr`
   sub-bucket in both halves of the report. Highest-leverage
   single change in the project right now.

2. **Add async-for-of lowering (`for await (... of ...)`).**
   Drives ~1100 stmt fails plus a chunk of class/elements
   (async iteration over private generators). Once dstr lands,
   the head-pattern variants flip pass automatically — order
   matters: do dstr first, then async-for-of.

3. **Add yield-star-async desugaring inside async generators.**
   ~600 fails. Self-contained branch in the yield-star compiler —
   essentially a sibling of the existing sync `yield*` path that
   awaits each step + closes via `Symbol.asyncIterator`.

4. **Static private fields/methods + private accessors.**
   ~830 fails in `class/elements`. The instance path already
   works, so this is "copy and adjust home-object" rather than
   greenfield. Also unlocks `compound-assignment` private-LHS
   (~80 more).

5. **`super.x` / `super[x]` runtime path.** ~60 direct +
   unblocks subclass-builtins / `arrow-function` lexical-super.
   Smallish fix relative to its blast radius.

## Out-of-scope / deferred (note but skip)

- `dynamic-import/*` (305) — `import()` runtime not wired; punt
  unless Workers/Deno parity is the next milestone.
- `cptn-*` fixtures (~70 across statements) — they all `eval()`,
  permanently out per AGENTS.md. Add a path-skip rule.
- `import.meta` (8), `static-init-await-reference` (a couple) —
  module-only edge cases, low yield.

## Estimated total recoverable

Quick-wins #1–#5 should plausibly recover **~5000–6000** of the
8350 combined fails — most of `class`, `for-await-of`, `dstr`
families, plus ripple effects in `arrow-function`, `generators`,
`async-generator`, `object`, `assignment`, and `compound-assignment`.
That would lift `language/expressions` from 54% to ~80% and
`language/statements` from 48% to ~75%.
