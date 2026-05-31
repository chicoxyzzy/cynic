# test262 — remaining in-corpus skips (taxonomy)

A handoff inventory of every test262 fixture Cynic still skips, grouped
by **blocker** and **owner**, so whoever picks up the eval or
multi-realm work starts from a precise picture rather than re-deriving
it. The source of truth is [`tools/test262/skip.zig`](../tools/test262/skip.zig);
this document is the human-readable map over it.

## Headline

- **0 real engine failures.** Every in-scope fixture Cynic attempts, it
  passes — or SES-diverges by design. `engine%` is 100.00 %; see
  [`test262-results.md`](../test262-results.md).
- The remaining `pass%` gap is **structural, not a bug backlog.** It is
  entirely two blockers: `--allow=eval` (runtime code construction) and
  per-realm error/identity attribution under a single active realm.
- Every cross-realm fixture that did **not** require eval is already
  passing (see "Already closed" below). The residue is exactly
  `eval ∪ (realm-of-origin under a true multi-realm host)`.

## Accounting note (read before trusting any count)

skip.zig enumerates **38 live fixtures** (all confirmed present in the
pinned submodule as of this writing). They split across two harness
accounting classes:

- **Dropped from the corpus denominator** — the permanent single-realm
  carve-outs (`single_realm_exact_paths`). Filtered at corpus-walk time
  exactly like the SES / Annex B / strict-only carve-outs, so they do
  **not** appear in the headline skip tally (a `--filter=realm` sweep
  shows only a handful of skips, not ~20, which confirms this).
- **Counted as in-corpus skips** — the movable, eval-gated set
  (`eval_dependent_exact_paths` + `single_realm_path_contains`).

`test262-results.md`'s headline skip count predates the most recent
skip-list edits; re-derive it with
`zig build test262 -- --quiet --write-results` once the working tree
settles. The taxonomy below (what / why / owner) is correct regardless
of the exact tally.

---

## Bucket 1 — eval-gated

**Blocker:** each needs `eval`, `new Function(string)`, or
`new other.Function(body)` — runtime code construction, which Cynic
bans by default for SES/edge-runtime alignment.
**Owner:** the `--allow=eval` effort — see
[`docs/ses-alignment.md`](ses-alignment.md) §Phase 4 and the AGENTS.md
"`eval` and runtime code construction — out by default" rule.
**Graduates when:** `--allow=eval` ships and the harness routes these
through an eval-allowed realm.

### 1a — pure `eval` / `Function(string)` (9 fixtures)

| Fixture | What it asserts |
|---|---|
| `built-ins/Function/prototype/S15.3.5.2_A1_T2.js` | `prototype` slot `DontDelete` on a string-body `Function` ctor result |
| `language/types/string/S8.4_A7.1.js` | `eval("var x = asdf<LineTerminator>ghjk")` → ReferenceError (LT terminates the decl) |
| `language/types/string/S8.4_A7.2.js` | same family, different line terminator |
| `language/types/string/S8.4_A7.3.js` | same family |
| `language/types/string/S8.4_A7.4.js` | same family |
| `language/statements/variable/12.2.1-9-s.js` | indirect-eval `var eval;` doesn't throw in strict |
| `language/statements/variable/12.2.1-10-s.js` | indirect-eval `eval = 42;` |
| `language/statements/variable/12.2.1-20-s.js` | indirect-eval `var arguments;` |
| `language/statements/variable/12.2.1-21-s.js` | indirect-eval `arguments = 42;` |

### 1b — cross-realm constructor built from a source string (9 fixtures)

The §10.1.14 default-proto fix (`remapDefaultProtoToCtorRealm` in
`lantern/call.zig`) recovered the rest of the `proto-from-ctor-realm`
family; these can't even build their `newTarget` / asserted constructor
without runtime code construction (`other.eval('…')`,
`new other.Function(body)`, `Reflect.construct(other.Function, …)`).

| Fixture | newTarget source |
|---|---|
| `built-ins/AsyncFunction/proto-from-ctor-realm.js` | source-string ctor |
| `built-ins/AsyncGeneratorFunction/proto-from-ctor-realm.js` | source-string ctor |
| `built-ins/AsyncGeneratorFunction/proto-from-ctor-realm-prototype.js` | source-string ctor |
| `built-ins/Function/proto-from-ctor-realm-prototype.js` | source-string ctor |
| `built-ins/GeneratorFunction/proto-from-ctor-realm.js` | source-string ctor |
| `built-ins/GeneratorFunction/proto-from-ctor-realm-prototype.js` | source-string ctor |
| `language/expressions/class/private-getter-brand-check-multiple-evaluations-of-class-realm-function-ctor.js` | `new other.Function(sourceString)` (private-brand) |
| `language/expressions/class/private-setter-brand-check-multiple-evaluations-of-class-realm-function-ctor.js` | same |
| `language/expressions/class/private-method-brand-check-multiple-evaluations-of-class-realm-function-ctor.js` | same |

> The three `-realm-function-ctor.js` fixtures are matched by the
> `single_realm_path_contains` substring rule (not an exact path), but
> their true blocker is eval — they belong to this bucket.

---

## Bucket 2 — single-realm error / identity attribution

**Blocker:** each asserts a realm-of-origin property (the thrower's
realm on a cross-realm TypeError, per-realm tagged-template caches,
`GetFunctionRealm` over a Proxy chain) under a true multi-realm host
(`$262.createRealm()`). Cynic resolves errors/identity against the
*active* realm; production `cynic` exposes no `$262` at all. AGENTS.md
marks this a **permanent** carve-out for the single-realm production
target — these are dropped from the corpus denominator.
**Owner:** the multi-realm effort — see
[`docs/multi-realm.md`](multi-realm.md).
**Graduates when:** Cynic models per-realm error/identity attribution
(if it ever does — the spec story doesn't move under the current
single-active-realm posture).

| Area | Fixtures |
|---|---|
| Function internals | `built-ins/Function/internals/Construct/derived-return-val-realm.js`, `built-ins/Function/internals/Construct/derived-this-uninitialized-realm.js`, `built-ins/Function/internals/Call/class-ctor-realm.js`, `built-ins/Function/call-bind-this-realm-undef.js`, `built-ins/Function/call-bind-this-realm-value.js` |
| Proxy | `built-ins/Proxy/apply/arguments-realm.js`, `built-ins/Proxy/construct/arguments-realm.js`, `built-ins/Proxy/construct/trap-is-undefined-proto-from-newtarget-realm.js`, `built-ins/Proxy/get-fn-realm.js`, `built-ins/Proxy/get-fn-realm-recursive.js` |
| String.prototype | `built-ins/String/prototype/toString/non-generic-realm.js`, `built-ins/String/prototype/valueOf/non-generic-realm.js` |
| JSON | `built-ins/JSON/stringify/value-bigint-cross-realm.js` |
| RegExp | `built-ins/RegExp/prototype/Symbol.split/splitter-proto-from-ctor-realm.js` |
| ThrowTypeError | `built-ins/ThrowTypeError/distinct-cross-realm.js` |
| language | `language/expressions/super/realm.js`, `language/expressions/tagged-template/cache-realm.js`, `language/types/reference/get-value-prop-base-primitive-realm.js`, `language/types/reference/put-value-prop-base-primitive-realm.js` |

> **Dual-blocker:** `built-ins/Error/isError/non-error-objects-other-realm.js`
> is listed under the single-realm carve-out but its *operative* blocker
> is eval — it builds the other realm's object via `new other.Function('')`.
> It only graduates once **both** eval and multi-realm attribution land.

---

## Already closed (don't re-do)

The cross-realm work that *did not* need eval is finished — listing it so
the next owner doesn't re-open it:

- **Cross-realm TypeError attribution A/B/C** (commit `b95694b`): RegExp
  cross-realm `source`/`flags` getters + `Function.prototype.{apply,call}`
  TypeError realm (§9.4); `GetFunctionRealm` recursion through a bound
  target (§10.4.1.3); revoked-Proxy `[[Call]]` TypeError using the running
  execution context's realm (§10.5.12). Unskipped
  `built-ins/Proxy/revocable/tco-fn-realm.js`. Threads a per-frame
  `CallFrame.running_realm` through the call path.
- **`proto-from-ctor-realm` ordinary-function family**
  (`remapDefaultProtoToCtorRealm` + `baseConstructIntrinsicDefaultProto`
  in `lantern/call.zig`, §10.1.14 / §10.2.2): every cross-realm proto
  fixture whose `newTarget` is *not* built from a source string now
  passes.
- **RegExp-getter `cross-realm.js` siblings** and
  **`Function.prototype.{apply,bind}/*-realm.js`** via
  `active_native_fn_realm` + the bound-target `getFunctionRealm()`
  recursion (§22.2.6 / §20.2.3.1 / §10.2.5).
- **Agent-wide identity** for `Symbol/*/cross-realm.js` and
  `RegExp/escape/cross-realm.js` — well-known symbols + the global symbol
  registry are shared via `test262CreateRealm`'s `shareWellKnownSymbolsWith`
  and the shared `heap.symbol_registry`, so these were never realm-of-origin
  tests and already pass.

---

## How to refresh / verify

- **Enumerate the live skip set:** the three arrays in
  `tools/test262/skip.zig` — `single_realm_exact_paths` (Bucket 2),
  `single_realm_path_contains` (Bucket 1b class fixtures),
  `eval_dependent_exact_paths` (Bucket 1).
- **Re-baseline the headline count:**
  `zig build test262 -- --quiet --write-results` (run after the working
  tree settles; refreshes `test262-results.md` + the pass-cache).
- **When `--allow=eval` ships:** Bucket 1 graduates to the attempted
  column once the harness routes the eval-gated fixtures through an
  eval-allowed realm.
- **When per-realm error attribution lands:** Bucket 2 graduates.
- **Reaching a literal 100 % `pass%` therefore requires *both*** the eval
  effort and the multi-realm error-attribution effort — it is not a
  single feature.
