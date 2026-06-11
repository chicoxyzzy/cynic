# test262 engine-gap audit

A per-fixture audit of the **engine gaps** class from
[`test262-results.md`](../test262-results.md) — the failures that are
not explained by the path/flag classifier (not `intl402/`, not
`noStrict`/`CanBlockIsFalse`-flagged, not an Annex-B builtin named in
the path). The classifier can only see paths and frontmatter; this
audit reads fixture *bodies* and assigns each remaining failure a
verified reason, so the gaps number is a real work list rather than a
pile of "unknown".

Audited 2026-06-11 against the pinned test262 submodule. Method: every
gap-classified failing fixture was read (individually or as a
generated family sharing one `_FIXTURE` / template), reproduced where
the verdict wasn't obvious, and either **fixed in the same session**
or classified below. Re-run the derivation with the harness's
`--list-failures` output filtered by the classifier rules to refresh
the list after a submodule bump.

## Verdict: 104 remaining, all by-design

| class | count | what it means |
|---|---:|---|
| sloppy-via-dynamic-code | 95 | The fixture's *body* depends on `Function(...)` / `eval(...)` producing **non-strict** code: sloppy `this`-coercion (`Function('return this')()` reaching the global), `var eval` / `eval = 42` / duplicate parameter names being legal, or a shared `_FIXTURE.js` that pokes globals through sloppy `this`. Cynic is strict-only by design — dynamic code parses as strict — so these can never pass. The flags can't catch them: many are even `onlyStrict`-flagged, because the *outer* code is strict and the sloppiness arrives via CreateDynamicFunction. |
| Annex-B surface in the body | 9 | The fixture calls an Annex-B builtin (`__lookupGetter__`, `__proto__`) or relies on Annex-B regex grammar (`\XA0`, bare `\x`, identity escapes of ID-continue chars) from inside the body, where the path classifier can't see it. Cynic ships no Annex B per AGENTS.md. |

Family breakdown of the 104 (areas with ≥2 fixtures):

| family | n | verified reason |
|---|---:|---|
| `built-ins/Function/prototype/{call,apply}` `S15.3.4.*` | 28 | sloppy `this`-coercion inside `Function(...)` bodies (null/undefined→global, primitive boxing) |
| `language/expressions/dynamic-import/**` | 20 | shared `_FIXTURE.js` files mutate globals via `Function('return this;')()` |
| `built-ins/Function` root + `/length` | 22 | duplicate parameter names (sloppy-only), sloppy `this`, `Function.call(obj, body)` scope shapes |
| `language/statements/variable/12.2.1-*-s` | 8 | assert `Function('var eval;')` / `'var arguments;'` parses — legal only in sloppy dynamic code |
| `language/module-code` | 5 | `fnGlobalObject()` / sloppy-`this` `_FIXTURE`s |
| `language/function-code/10.4.3-*` | 4 | assert dynamic functions are non-strict (`this` coerces) even when created from strict code |
| class-elements `private-{getter,setter}-is-not-a-own-property` | 4 | body calls `__lookupGetter__` |
| `language/literals/regexp` + `String/prototype/split` | 4 | Annex-B-only escapes in patterns (the documented Perlex strict-grammar posture) |
| `language/statements/function/13.0-*` | 2 | `new Function('eval = 42;')` — sloppy-only assignment target |
| `language/eval-code/indirect` | 2 | indirect eval of intrinsically sloppy source (`always-non-strict`, global-`with` env record) |
| singles | 5 | one verified sloppy/Annex-B dependence each (`call-bind-this-realm-*`, `S11.1.1_A4.1`, `tamper-with-global-object` ×2, `no-species` via `__proto__`) |

## Fixed during the audit (6 fixtures, 5 commits' worth of bugs)

- `built-ins/Function/S15.3.2.1_A3_T{1,3}` — §20.2.1.1.1
  CreateDynamicFunction stringified the body before the parameter
  args; a throwing param-`toString` must win.
- `language/statements/using/syntax/using-not-allowed-at-top-level-of-eval`
  — `using` at the top level of a Script (and therefore of eval code)
  is an early SyntaxError; the parser accepted it everywhere.
- `language/eval-code/direct/new.target-fn` — §13.3.1.1 allows
  `new.target` in direct-eval code contained in any non-arrow function
  code; the gate only admitted methods and derived constructors.
- `language/expressions/tagged-template/cache-eval-inner-function` —
  a direct `eval` in a `for (let …)` body read the loop counter, which
  the fused counter-loop had promoted to a register invisible to eval;
  a possible direct eval now poisons the promotion (matching
  `bodyIsRegisterSafe`).
- `built-ins/Function/prototype/toString/built-in-function-object` —
  `Object.getOwnPropertyDescriptors` rejected function targets
  (§20.1.2.9 ToObject admits them).

## What this means for the headline

The engine-gap class is exhausted as a work list: every remaining
member is pinned to a deliberate, documented posture (strict-only
dynamic code; no Annex B). Further headline movement comes from the
big policy buckets — ECMA-402 (`intl402/`, ~3.2k) being the only
whole-point lever — not from chasing the gap tail.
