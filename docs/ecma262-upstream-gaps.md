# ECMA-262 upstream-gap log

Spec-level improvements we'd propose to [`tc39/ecma262`](https://github.com/tc39/ecma262)
— places where the spec text is technically correct but the
algorithm wording, cross-references, or invariant placement
invited bugs while we were implementing Cynic. Mostly clarifications
and hardenings; occasionally a real spec change.

Companion to
[`test262-upstream-gaps.md`](test262-upstream-gaps.md), which
tracks **fixture** gaps we'd contribute upstream. This file is
the **specification** wishlist.

An entry belongs here when one of:

- The spec wording is ambiguous and we picked one interpretation
  ("clarification" entries — propose a worked example or tighter
  language).
- An invariant is implicit in the algorithm steps but easy to
  miss ("hardening" entries — propose an explicit assertion).
- A spec step is redundant in practice because of an upstream
  invariant ("simplification" entries — propose dropping the
  step or noting its observability).
- The normative-vs-Annex B boundary doesn't match
  shipping-engine reality ("normalize Annex B" entries —
  propose promoting to the main body).

Entries are not bug reports against the spec — the spec is
correct as written. They're observations from implementing it
that we'd like the editors to consider.

## Format

```
### <one-line description>

- **Spec:** §X.Y.Z <abstract-op or section title>
- **Observed during:** <commit SHA, fixture cluster, or
  free-text description of when we hit it>
- **Issue:** <what's confusing / under-specified / hard to get
  right; cite the specific step wording where useful>
- **Proposal:** <what TC39 / ecma262 change would help — a
  clarifying note, an explicit assertion, a worked example, a
  simpler equivalent algorithm, a normative promotion, …>
- **Prior art:** <links to existing tc39/ecma262 issues, V8 /
  SpiderMonkey / JSC commits that wrestled with the same
  language, or relevant TC39 plenary notes>
```

## Entries

### §B.1.4 regex grammar — promote permissive forms to normative

- **Spec:** §B.1.4 ExtendedRegExp / ExtendedAtom / ExtendedPatternCharacter.
- **Observed during:** every shipping regex engine (libregexp,
  V8 Irregexp, SpiderMonkey, JSC). Cynic ships these via the
  vendored QuickJS-NG libregexp and acknowledges the exception
  in `AGENTS.md`.
- **Issue:** Annex B is informative for non-web hosts per
  §B.0. But the permissive regex forms it carves out —
  octal `\1` outside a capturing group, the lower-bound-elided
  quantifier `{,n}`, identity-escape on
  non-Syntax / non-Unicode characters — are accepted by every
  shipping engine without the `/u` or `/v` flag. Real-world
  regexes in npm packages, Stack Overflow snippets, and
  config files rely on them. A SES-flavoured engine that
  followed §B.0 literally and refused them would reject ~3 %
  of real-world regex literals at parse time. Cynic targets
  edge runtimes (non-browser, no Annex B in general) and
  still ships these — that's the level of de-facto
  normativity at play.
- **Proposal:** move §B.1.4's extensions for non-Unicode (no
  `/u` / `/v`) regex patterns into the main grammar (§22.2.1).
  Keep the Unicode-mode strictness where it lives today (the
  `/u` and `/v` flags already enforce the strict grammar
  inside Annex B itself). The net effect on conforming
  implementations is zero — they all ship the extensions —
  but the spec stops lying about "non-web hosts may omit
  Annex B."
- **Prior art:** [ecma262 #2034](https://github.com/tc39/ecma262/issues/2034)
  (Annex B layering discussion). The QuickJS-NG, V8, JSC, and
  SpiderMonkey source all confirm by behaviour: there is no
  engine that ships `RegExp("\\1")` rejection.

### §16.2.1.5 InnerModuleEvaluation — simpler approximation viable for non-cycle graphs

- **Spec:** §16.2.1.5 InnerModuleEvaluation, §16.2.1.6
  ExecuteAsyncModule, §16.2.1.7 GatherAvailableAncestors,
  §16.2.1.8 AsyncModuleExecutionFulfilled, §16.2.1.9
  AsyncModuleExecutionRejected.
- **Observed during:** Cynic's top-level-await implementation
  (commits `046c23e`, `522baff`, `b539bbe`, `e4ddfac`,
  `81e61bf`, `b21565b`).
- **Issue:** The full algorithm allocates four new internal
  slots per module record ([[PendingAsyncDependencies]],
  [[AsyncEvaluation]] / [[AsyncEvaluationOrder]],
  [[AsyncParentModules]], [[CycleRoot]]) and runs a reverse-
  pointer propagation through GatherAvailableAncestors on
  every async settlement. The complexity sits at the
  intersection of two threads — module instantiation and the
  microtask queue — that are otherwise loosely coupled, and
  the wording cross-references ten distinct abstract
  operations across two spec sections (16.2.1 and 9.4).
  Cynic ships a single-opcode approximation
  (`module_link_complete` drains the microtask queue once
  after the importer's import block) that passes every
  fixture in `language/module-code/top-level-await/`
  including the sibling-doesn't-block, dfs-invariant,
  pending-async-dep-from-cycle, and fulfillment-order cases.
  The approximation skips [[AsyncEvaluationOrder]] sort and
  the reverse-[[AsyncParentModules]] walk entirely.
- **Proposal:** add an informative note distinguishing the
  observable behaviour of the full algorithm from the
  simpler "drain microtasks at link-complete" implementation,
  and identify (or contribute upstream) the test fixtures
  that distinguish them. If the only difference is
  observability under a specific multi-cycle async ordering
  that doesn't appear in real-world code, an editorial note
  acknowledging the simplification opportunity would let
  smaller engines (Cynic, Hermes, XS) skip the full graph
  without losing conformance.
- **Prior art:** the spec's own §16.2.1.5 has an "Editor's
  Note" structure precedent (e.g. §16.2.1.5.4 step 4.a "It
  is an editor's intention …"). Cynic's
  `docs/handbook/environments.md` "Top-level await — the
  link-complete boundary" section documents what we ship.

### §7.3.28 / §7.3.32 PrivateElementAdd — same-class accessor pair gotcha

- **Spec:** §7.3.28 PrivateMethodOrAccessorAdd,
  §7.3.32 PrivateFieldAdd. The step "If entry is not empty,
  throw a TypeError" runs `PrivateElementFind(P.[[Key]], O)`.
- **Observed during:** Cynic's class private double-init fix
  (commit `7df013d`). Multiple agents and we ourselves
  initially flagged this as "needs to merge half-accessors
  into one PrivateElement record at class-def time."
- **Issue:** A class body with both `get #m()` and `set #m()`
  produces TWO PrivateMethodOrAccessorAdd calls per
  instantiation — one for the getter half, one for the
  setter half. Both target the same `[[Key]]`. A naive
  PrivateElementFind that matches on key alone would treat
  the second call as a duplicate-add and throw. The spec
  side-steps this by tagging entries with `[[Kind]]`
  (accessor / method) AND by treating the accessor's get/set
  halves as **fields of the same entry** — but the
  algorithm text doesn't say "merge"; it says "find an entry
  with the same key, and if you find one of accessor kind,
  set its [[Get]] / [[Set]] half." That second clause is
  buried in §7.3.28 step 4.b, which is easy to miss when
  implementing the duplicate-detection invariant.
- **Proposal:** restructure §7.3.28 so the same-class
  accessor-pair merge is the first step, with the duplicate
  check happening only after merge has run. Or add a
  worked example showing `get #m` / `set #m` interleaved
  with a class-evaluated-twice scenario distinguishing
  legitimate accessor pairs from genuine double-adds.
- **Prior art:** [V8 4769](https://chromium-review.googlesource.com/c/v8/v8/+/2486783)
  fixed an analogous bug in 2020. SpiderMonkey
  [bug 1715840](https://bugzilla.mozilla.org/show_bug.cgi?id=1715840)
  hit the same shape.

### §9.5.7-9.5.11 Proxy internal methods — explicit recursion on proxy-of-proxy

- **Spec:** §9.5.7 [[GetOwnProperty]] through §9.5.11
  [[Delete]] — each describes a trap-with-fallback flow.
- **Observed during:** Cynic's Proxy trap rewrite
  (commits `9cca358`, `6d474b0`, `e9d6bcc`, `c670861`, etc.).
- **Issue:** When a Proxy's `[[ProxyTarget]]` is itself a
  Proxy, the invariant checks (§9.5.7 step 19-22, §9.5.8
  step 11-12, §9.5.9 step 9-11, §9.5.10 step 12-14, §9.5.11
  step 7-9) must be re-applied at each level. The spec's
  step text reads as a single invocation against the target,
  not a recursion through the proxy chain. Implementations
  that don't recurse pass the trap-defined fixtures but
  fail the `trap-is-undefined-target-is-proxy` family.
- **Proposal:** add an explicit "Note" after each trap
  algorithm: "If `target` is itself an Exotic Object whose
  internal method is being invoked, the invariants apply
  to the result returned by the innermost call." Or
  refactor the algorithm steps so the invariant check is
  named (`ValidateProxyTrapResult(target, trapResult)`)
  and the recursion through proxy-of-proxy is explicit.
- **Prior art:** V8 / SpiderMonkey / JSC all recurse;
  the canonical "ChromeAPI tests" (V8 `test/mjsunit/proxies/`)
  cover proxy-of-proxy invariants extensively even though
  the spec text doesn't call them out.

### §13.4 UpdateExpression — observable mid-coercion side effects

- **Spec:** §13.4 UpdateExpressionRuntimeSemantics.
- **Observed during:** Cynic's Update opcode rewrite
  (commit `ab57ef9`).
- **Issue:** The spec algorithm reads `lhs.[[Value]]` → ToNumeric
  → add/subtract one → PutValue. When the LHS is a member
  expression `obj[key]`, the algorithm folds key evaluation
  into the same Reference Record — which means
  `ToPropertyKey(key)` runs ONCE during LHS evaluation,
  and is observable both at GetValue and PutValue. A naive
  bytecode lowering that re-evaluates `key` for each side
  trips on a `valueOf` that has side effects (`let k = {
  valueOf() { calls++; return 0; } }; obj[k]++` — `calls`
  must be exactly 1). The spec is precise but the "single
  Reference, two GetValue/PutValue" coupling is implicit.
- **Proposal:** add an editorial note after §13.4 step 2 (or
  §6.2.5.5 PutValue) explicitly calling out that
  Reference Record coercion happens once across the
  combined GetValue + PutValue pair. A non-normative
  pseudocode block showing the typical bytecode lowering
  would prevent the trap.
- **Prior art:** test262's
  `language/expressions/postfix-increment/target-cover-id.js`
  catches this for parenthesized covers but not for member
  expressions with side-effecting computed keys. Both V8
  and JSC have historical commits fixing the same pattern.

## Submission process

This file is a sketchbook. When an entry feels ready (worded
clearly, the proposal is concrete, prior art surveyed) we open
a TC39 issue or, for editorial changes, send a pull request
to [ecma262](https://github.com/tc39/ecma262). Mark the entry
with the upstream link once filed so we can track it.
