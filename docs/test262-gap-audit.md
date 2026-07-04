# test262 engine-gap audit

The **engine gaps** class in [`test262-results.md`](../test262-results.md)
is the failures the harness classifier can't attribute to a policy class
from a fixture's *path* and *frontmatter* alone. Much of that tail is still
by-design — but the reason lives in the fixture *body*: a `Function(...)` /
`eval(...)` that runs as sloppy code, an Annex-B surface used inside the
test, an outdated upstream fixture. The classifier can't see any of that;
deciding it takes reading the body.

**That judgment is data now, not a dated snapshot.** It lives in the
machine-readable registry
[`tools/test262/gap_audit.zig`](../tools/test262/gap_audit.zig): one line
per fixture, mapping an exact path to its by-design reason (`sloppy_body`
/ `annex_b_body` / `stale_fixture`). `failClassOf` consults it during
classification, reclassifies matched fixtures out of the raw gap count
into their named reason, and **leaves anything NOT in the registry as an
engine gap**. So:

- the by-design counts auto-maintain on every sweep — no stale numbers to
  keep in this file;
- a newly-added by-design fixture surfaces as an *unaudited gap* for triage
  instead of silently inflating the number;
- a real engine bug is never auto-hidden — matching is by exact path (not
  glob), so a new fixture in an already-audited area still shows up.

**The live count is in the results doc, not here.** `test262-results.md`
regenerates the by-design breakdown + the residual **engine gaps** row on
every sweep. To see the current triage list, run the harness with
`--list-gaps` (on a full sweep): it prints every unregistered gap.

## Triaging a gap

When `--list-gaps` names a fixture:

1. **Read the body.** Is the failure a real engine bug, or by-design
   (sloppy semantics arriving via dynamic code, an Annex-B surface, an
   outdated fixture)?
2. If it's a **bug** — fix the engine; the gap disappears on the next sweep.
3. If it's **by-design** — add one line to `gap_audit.zig` with the matching
   reason. Confirm by reading the body; don't pattern-match on the path. The
   `String.prototype.split` pair is the cautionary tale: `separator-regexp`
   *looks* like the Annex-B split fixtures but uses plain ECMAScript regex
   (`/^/`, `/.{1,2}/`) and is a **real** gap, so it stays unregistered.

The three reasons: **`sloppy_body`** — sloppy `this` reaching the global via
`Function('return this')()`, `var eval` / `eval = 42`, a `-non-strict`
fixture, an in-body `with` (Cynic is strict-only). **`annex_b_body`** — an
Annex-B regex identity escape, legacy `substr`, `__proto__` / `__lookup*`
in the test logic (Cynic ships no Annex B). **`stale_fixture`** — Cynic is
spec-correct and the fixture predates a spec/data bump (refresh it upstream).

## History

The original 2026-06-11 manual audit and each subsequent re-triage, kept
as a dated record. The registry above is the live source of truth.

### 2026-06-11 — initial audit, fixed 6 fixtures (5 commits' worth of bugs)

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

### Update 2026-06-14 — error-stack-accessor (a real gap, now closed)

A test262 submodule bump after the 2026-06-11 audit added the
`built-ins/Error/prototype/stack` family (34 fixtures, feature
`error-stack-accessor`). Unlike the tail above, these were a **real**
engine gap, not a by-design posture: the `proposal-error-stacks`
accessor pair on `%Error.prototype%` was simply unimplemented. Closed
this session — the getter/setter (§6.1.7 receiver typing; the stack
string is the §20.5.3.4 toString header; the proxy- / accessor-aware
§SetterThatIgnoresPrototypeProperties now lives in `builtins/object.zig`
and is shared with `Iterator.prototype.constructor`) brings
`built-ins/Error` to 93/0. Headline: +34 (test262 → 45333).

A fresh triage of the rest of the current gap list re-confirmed every
by-design family above (sloppy-via-dynamic-code, Annex-B-in-body) — no
new real engine gaps surfaced; the verdict stands.

### Update 2026-07-03 — the intl402 by-design tail (a separate denominator)

The audit above covers the **main-sweep** engine-gap class, which by
construction excludes `intl402/`. But `intl402/` is scored in-scope at
`-Dintl=full`, and its residual fails land in the same "engine gaps"
column of `test262-results.md` — so the same body-level blind spot
applies there. After the 2026-07-03 ECMA-402 push closed every winnable
`intl402/` fixture, the phase sits at **10 remaining, all by-design**;
none is an engine gap, and two classes need a body read the classifier
can't do:

| class | count | what it means |
|---|---:|---|
| legacy `[[FallbackSymbol]]` (`intl-normative-optional`) | 8 | `FallbackSymbol/*` (2) + `{NumberFormat,DateTimeFormat}/intl-legacy-constructed-symbol*` (6). The §11.1.1/§11.1.2 legacy constructor shim (`Intl.NumberFormat.call(obj)` stashing the formatter under a well-known symbol) is legacy web-compat Cynic declines like Annex B. Already pinned by the harness `FailClass.norm_optional` on the `intl-normative-optional` feature tag. |
| Annex-B / stale in the body | 2 | `Temporal/Instant/prototype/toString/timezone-string-datetime` fails **only** on `result.substr(-6)` — Annex-B `String.prototype.substr`, which Cynic ships no Annex B for; the Temporal IANA-annotation parse it actually tests is correct (verified: the same value read with `.slice(-6)` is `"-08:00"`). `DateTimeFormat/prototype/format/numbering-system` is a **stale** fixture — Cynic emits the CLDR-42 narrow-no-break space (U+202F) before the dayPeriod, the fixture still expects the pre-42 U+0020. |

So the `intl402/` gap count is a pile of deliberate postures + one
outdated fixture, not a work list — same conclusion as the main-sweep
tail. Don't re-triage these: the FallbackSymbol six are policy declines,
the substr one is Annex B, the numbering-system one is a fixture that
predates the CLDR bump Cynic tracks (§3, `unicode.org/versions/latest`).
The substr case is a fixture-portability nit (reading `.slice(-6)`
instead of the Annex-B `.substr(-6)` would let the Temporal assertion it
actually targets pass on strict-only engines) — an upstream-fixture
observation, distinct from this repo's logs, so it stays with whoever
owns the tc39 contribution rather than being filed as a Cynic gap.

### Update 2026-07-04 — built-ins/Temporal (a real gap cluster, now closed)

A test262 submodule bump surfaced 14 `built-ins/Temporal` failures that were
**real** engine gaps — like the 2026-06-14 error-stack-accessor entry, not the
by-design tail. Two clusters, both closed this session:

- **`toLocaleString/branding` (6 fixtures; `1725af5f`).** The shared
  `Temporal.*.prototype.toLocaleString` bridge (Instant, PlainTime, PlainDate,
  PlainYearMonth, PlainMonthDay, PlainDateTime) formatted whatever receiver it
  was handed, so a stolen method applied to a non-Temporal `this` returned a
  string instead of throwing. §13.x RequireInternalSlot now guards the
  receiver's `[[InitializedTemporal*]]` slot before any option processing.
- **PlainYearMonth / PlainMonthDay string validation (8 fixtures; `e42220ac`).**
  Two ParseTemporal{YearMonth,MonthDay}String gaps: a day-less year-month
  can't re-anchor a non-ISO calendar (`1976-11[u-ca=gregory]` → RangeError),
  and a non-ISO PlainMonthDay converts the full ISO date, so an out-of-range
  year is rejected (`-999999-01-01[u-ca=gregory]`) while the ISO calendar keeps
  discarding it (`-999999-10-01` valid).

`built-ins/Temporal` → 100% (4589/14 → 4603/0). A fresh triage of the rest of
the gap list re-confirms every by-design family above — the residue is the
documented sloppy-via-dynamic-code, Annex-B-in-body, strict-only, and
by-design / stale-`intl402` postures.

### Update 2026-07-04 — the audit became a registry

The manual verdicts above are now encoded as data in
[`tools/test262/gap_audit.zig`](../tools/test262/gap_audit.zig) (see the
methodology at the top), and the harness applies them: the 104 by-design
fixtures reclassify out of `engine gaps` into named classes on every sweep,
so the number auto-maintains and a new by-design fixture surfaces for triage
instead of rotting this doc. `test262-results.md` engine gaps: **106 → 2**.

The two survivors are real, and the exercise **corrected the record**: both
are `built-ins/String/prototype/split` fixtures the 2026-06-11 audit had
grouped under "Annex-B escapes in patterns", but reading the bodies shows
`separator-regexp` uses plain ECMAScript regex (`/^/`, `/.{1,2}/`) — a
genuine split/regex gap — and `checking-by-using-eval` throws an unexpected
`ReferenceError` binding `String.prototype.split` to top-level `this`. Both
stay unregistered as engine gaps for a real fix. Exactly the safe default:
pattern-matching the path would have hidden them.
