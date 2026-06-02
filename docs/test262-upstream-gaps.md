# test262 upstream-gap log

Bugs Cynic patched that **no existing test262 fixture catches** — and
which we'd like to contribute fixtures for back to
[`tc39/test262`](https://github.com/tc39/test262).

A bug belongs here when one of:

- The spec rule it touches is well-defined but the fixture corpus
  doesn't exercise the specific path we tripped (negative
  arg, primitive vs. wrapper, error-completion at a non-trivial
  step, abrupt mid-coercion, …).
- The failure mode is engine-shape (parse / compile error, crash,
  hang, allocator double-free) that test262 doesn't target directly
  but a positive fixture exercising the same surface would have
  caught it on a robust engine.

Bugs that **are** covered by an existing test262 fixture do not go
here — the harness already exercises them. When in doubt, search
the corpus under the relevant section's directory before adding.

## Format

```
### <one-line description>

- **Fixed in:** <commit SHA>
- **Spec:** §X.Y.Z <abstract-op or section title>
- **Reproducer:**
  ```js
  // 8-15 lines max
  ```
- **Before fix:** <observed behaviour>
- **After fix:** <expected behaviour per spec>
- **Suggested fixture shape:** <positive / negative · runtime / parser ·
  async-flagged · `features:` tags · which subdirectory>
```

## Entries

### C-style `for` shared a body-block lexical when a closure captured it

- **Fixed in:** `1b5687c`
- **Spec:** §14.7.4.4 CreatePerIterationEnvironment — each iteration
  of a `let` / `const` `for` runs in a fresh environment; a closure
  capturing any binding in it observes iteration-specific values.
- **Reproducer:**
  ```js
  const fns = [];
  for (let i = 0; i < 3; i++) { let w = i * 10; fns.push(() => w); }
  fns.map(f => f()).join(","); // must be "0,10,20"
  ```
- **Before fix:** Returned `"20,20,20"`. Cynic's per-iteration-env
  elision optimisation checked only whether a body closure captured a
  loop-*head* binding (`i`). A closure capturing a body-block lexical
  (`w`) — which Cynic flattens into the same per-iteration env — was
  missed, the env was elided, and `w` was shared across iterations.
  Capturing the loop variable itself (`() => i`) worked.
- **After fix:** Returns `"0,10,20"`; the per-iteration env is kept
  whenever the loop body contains any closure.
- **Suggested fixture shape:** positive runtime fixture under
  `language/statements/for/`. The existing `scope-body-lex-*`
  fixtures assert per-iteration freshness of the loop *variable*;
  none assert it for a `let` declared inside the body block. A
  closure-array assertion like the reproducer would catch it — and
  the same gap applies to the `for-of` / `for-in` forms, which share
  the optimisation.

### Lazily-installed native methods had `null` as `[[Prototype]]`

- **Fixed in:** `eff8381`
- **Spec:** §10.3 Built-in Function Objects — every built-in
  function object has `%Function.prototype%` as the initial value
  of its `[[Prototype]]` internal slot (unless otherwise specified).
- **Reproducer:**
  ```js
  const it = [1, 2, 3][Symbol.iterator]();
  const next = Object.getPrototypeOf(it).next; // %ArrayIteratorPrototype%.next
  typeof next;                                  // "function"
  typeof next.call;                             // must be "function"
  Object.getPrototypeOf(next) === Function.prototype; // must be true
  next.call(it).value;                          // must be 1
  ```
- **Before fix:** `%ArrayIteratorPrototype%.next` — and every other
  native installed lazily after realm init (`%StringIteratorPrototype%.next`,
  `@@iterator` self-returns, …) — had a `null` `[[Prototype]]`.
  `next.call` / `.apply` / `.bind` were `undefined`; `next.call(it)`
  threw `TypeError`. Natives installed *during* init (e.g.
  `Array.prototype.slice`) were fine — a one-time wiring pass at the
  end of `intrinsics.install` reached only those.
- **After fix:** `[[Prototype]]` is `%Function.prototype%` for every
  native regardless of install time; the inherited `.call` /
  `.apply` / `.bind` resolve.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/ArrayIteratorPrototype/next/`. The fixtures there cover
  `name`, `length`, `property-descriptor`, `non-own-slots`, and
  iteration behaviour — none assert the method's own `[[Prototype]]`.
  `Object.getPrototypeOf(nextMethod) === Function.prototype` plus a
  `nextMethod.call(iter)` round-trip would catch it; the same gap
  applies to `%StringIteratorPrototype%.next` and the other
  lazily-built iterator prototypes.

### `Iterator.zip` with a primitive String in the inner-iter sequence

- **Fixed in:** `b896b71`
- **Spec:** §27.5.4 step 6.b — `GetIteratorFlattenable(value,
  REJECT-STRINGS)` rejects primitive strings.
- **Reproducer:**
  ```js
  Iterator.zip(["abc"]);            // outer iter yields the string "abc"
  Iterator.zip([Object("abc"), ""]); // boxed-string is fine; primitive "" is not
  ```
- **Before fix:** Cynic segfaulted via a double-`deinit` in
  `collectZipIters`'s error path when `getIteratorFlattenable`
  threw on a primitive-string element.
- **After fix:** Throws `TypeError` per spec (REJECT-STRINGS).
- **Suggested fixture shape:** positive `assert.throws(TypeError,
  () => Iterator.zip([primitiveString]))` runtime fixture under
  `built-ins/Iterator/zip/`, tagged `features: [joint-iteration]`.
  Existing fixtures cover (i) the *outer* iter being a primitive
  (`iterables-primitive.js`) and (ii) boxed-string elements
  (`iterables-containing-string-objects.js`), but neither asserts
  the REJECT-STRINGS gate on a primitive-string *element*.

### `Object.defineProperty(arr, "length", { value })` ToNumber observability

- **Fixed in:** `3db0fbc`
- **Spec:** §10.4.2.4 ArraySetLength steps 3-5 — `ToUint32(Desc.[[Value]])`
  (step 3) AND `ToNumber(Desc.[[Value]])` (step 4), then
  `SameValueZero` on the two results.
- **Reproducer:**
  ```js
  let calls = 0;
  const len = { valueOf() { calls++; return 2; } };
  const arr = [1, 2];
  Object.defineProperty(arr, "length", { value: len });
  // calls must be 2 — one for ToUint32, one for the standalone ToNumber.
  ```
- **Before fix:** Cynic called `ToPrimitive` once, so `calls === 1`.
- **After fix:** Both coercions fire; mid-flight side effects on the
  array (e.g. a `valueOf` that flips `length: { writable: false }`)
  are observable per spec.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Array/length/`. `define-own-prop-length-coercion-order.js`
  exists but bundles the two-call assertion with a mutation-then-write
  TypeError, hiding the count semantics behind the throw expectation.
  A pure two-call counter assert would be a clearer regression test.

### `class` constructor body raised `CompileError` on `var` declarations

- **Fixed in:** `0f73c43`
- **Spec:** §15.7 / §10.2.1 — a class constructor body is a
  function body; `var` declarations hoist normally.
- **Reproducer:**
  ```js
  class C {
    constructor() {
      var x = 5;
      this.x = x;
    }
  }
  new C();
  ```
- **Before fix:** `CompileError` at compile time — the binding
  for `x` was never created, so the `var x = 5` use site
  failed name resolution.
- **After fix:** Runs cleanly; `new C().x === 5`.
- **Suggested fixture shape:** positive runtime fixture under
  `language/statements/class/` (or `language/expressions/class/`).
  Many existing fixtures touch `var` in class scopes via
  `scope-*-paramsbody-var-*.js`, but they target *methods* /
  *static-init blocks* and field initializers — not the
  constructor body specifically. A
  `class-ctor-body-var-hoist.js` positive test would freeze the
  shape.

### `+` concat of a lone high surrogate with a lone low surrogate stored ill-formed

- **Fixed in:** `8a266ea`
- **Spec:** §13.15.5 / §22.1.3.4 string concatenation; §6.1.4 the
  String type as UTF-16 code units. Cynic-internal: the WTF-8
  storage invariant (AGENTS.md) — a *valid* surrogate pair is
  always the 4-byte UTF-8 form, never two adjacent 3-byte CESU-8
  escapes.
- **Reproducer:**
  ```js
  var combined = "\uD800" + "\uDC00";          // high + low surrogate
  var direct = String.fromCodePoint(0x10000);  // same supplementary cp
  combined === direct;            // expected true
  combined.codePointAt(0) === 0x10000;         // expected true
  combined.isWellFormed();                     // expected true
  ```
- **Before fix:** the `+` operator's single-allocation concat
  path did a plain two-memcpy join, leaving the paired
  surrogates as two 3-byte CESU-8 escapes (6 bytes) where a
  flat-built equivalent has one 4-byte sequence (4 bytes).
  `combined === direct` was `false` — two String values that
  are the same per spec compared unequal because the byte-wise
  `===` saw different lengths.
- **After fix:** the concat merges the seam into the 4-byte
  supplementary form; `combined === direct` is `true`.
- **Suggested fixture shape:** positive runtime fixture under
  `language/expressions/addition/` (or `built-ins/String/`),
  `features: []`. Asserts a `+`-built string equals the
  `String.fromCodePoint` / `\u{10000}` equivalent and round-
  trips through `codePointAt` / `isWellFormed` / `[...str]`.
  No existing fixture concatenates split surrogate halves and
  checks the result is a well-formed pair — the corpus tests
  lone surrogates and pairs, but not the *cross-concat* seam.

### Fresh-coerced primitive receiver freed across a re-entrant builtin

- **Fixed in:** `d4b20c7`
- **Spec:** §22.1.3 String.prototype methods (RequireObjectCoercible
  then ToString on a non-string `this`); §7.1.1.1 OrdinaryToPrimitive.
  The coerced result is a spec value the method must keep live for the
  whole of its body — Cynic-internal: the `HandleScope` rooting
  contract in [docs/handbook/gc.md](handbook/gc.md).
- **Reproducer:**
  ```js
  // Only observable under allocation-triggered GC (the harness'
  // --gc-threshold=1). An object receiver coerces to a *fresh*
  // JSString that no register roots; the allocating argument
  // coercion below then drives a collection that frees it mid-method.
  const recv = { toString() { return "\u{1F600}abcdef"; } };
  const arg  = { valueOf() { for (let i = 0; i < 300; i++) ("" + i).padStart(64); return 2; } };
  String.prototype.indexOf.call(recv, arg); // must read live bytes, not freed
  ```
- **Before fix:** the fresh receiver string was unrooted; a GC during
  the argument's `valueOf` (or any later re-entry / allocate-from-slice)
  swept it, and the method then read freed / recycled WTF-8 bytes —
  surfacing as a `Utf8ExpectedContinuation` panic or a wrong result. A
  *string* receiver (register-rooted) and a wrapper-object receiver
  (slot-marked) were both fine; only the primitive-coercion path leaked.
- **After fix:** the coerced receiver is pushed onto a `HandleScope`
  before the first re-entry / allocation, so it survives to the end of
  the method.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/String/prototype/<method>/`. Fixtures exercising object
  receivers and side-effecting argument coercion exist separately, but
  none combine an object receiver whose `toString` yields a
  supplementary-plane string with a heap-allocating argument coercion —
  the combination a robust engine (ASAN / GC-stress) needs to expose
  the freed-receiver read. The same shape recurs for object-receiver
  coercion on `Symbol.prototype.toString` / `valueOf` (§20.4.3).

### A quantified empty-matching `/v` `\q{}` set threw at construction

- **Fixed in:** `fa5445c`
- **Spec:** §22.2.2.3 RepeatMatcher (the zero-width progress guard) +
  §22.2.1.4 / §22.2.2.7 ClassSetExpression / `\q{…}` ClassString
  matching — a `/v` set whose membership includes the empty string is a
  legal nullable atom, and a quantifier over it is well-defined.
- **Reproducer:**
  ```js
  // `\q{}` contributes the empty string to the set's membership, so
  // [\q{}a] matches "a" or "". All of these are valid /v patterns.
  /[\q{}a]*/v.exec("aab")[0];      // must be "aa"
  /[\q{}a]+/v.exec("b")[0];        // must be ""  (mandatory iter matches empty)
  /[\q{}a]{2,3}/v.exec("a")[0];    // must be "a"
  new RegExp("[\\q{}]*", "v");      // must construct, not throw
  ```
- **Before fix:** Cynic's native engine deferred any quantifier over a
  nullable `\q{}` set to its vendored libregexp fallback, which does not
  implement `\q{…}` at all — so the pattern threw
  `SyntaxError: invalid escape sequence` at `RegExp` construction
  instead of compiling. A non-quantified `[\q{}a]` matched fine; only
  the quantified form tripped the deferral.
- **After fix:** the set is owned natively; the §22.2.2.3 progress guard
  stops the zero-width loop and the `min = 0` precondition lets the
  mandatory iterations match empty and still participate, so the
  patterns above return their spec results.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/RegExp/unicodeSets/` (or `language/literals/regexp/`),
  `features: [regexp-v-flag]`. The corpus has `\q{}` set-membership and
  set-algebra fixtures, but none quantify an empty-matching set — the
  exact combination that exposes a fallback-shaped engine to a
  construction-time throw. The mandatory-iteration cases
  (`[\q{}a]+` on `"b"`, `[\q{}a]{2,3}` on `"a"`) double as a
  §22.2.2.3-step-2.b regression guard: engine262 currently returns
  `null` for them (V8 / JSC / SpiderMonkey / Hermes / QuickJS all
  match), so a fixture asserting the match would also catch that.

### Non-`/u` `i` folds a non-ASCII unit to a *different* non-ASCII unit

- **Fixed in:** `6c9a7e6`
- **Spec:** §22.2.2.7.3 Canonicalize, the non-Unicode path (steps
  3–10): when neither `u` nor `v` is set, a code unit folds via
  `toUppercase` (not case-folding), subject to two guards — a
  multi-code-unit uppercase leaves the unit unchanged (`ß` stays
  `ß`), and the **ASCII-exclusion**: a unit ≥ 128 whose uppercase is
  a single ASCII unit stays itself (so `U+212A` KELVIN and `U+017F`
  ſ are *not* matched by `/[a-z]/i`). A unit whose uppercase is
  *another non-ASCII unit* does fold to it.
- **Reproducer:**
  ```js
  /à/i.test("À");      // à matches À — must be true
  /[σ]/i.test("ς");    // [σ] matches ς (both → Σ) — true
  /[σ]/i.test("Σ");    // [σ] matches Σ — true
  /µ/i.test("Μ");      // µ matches Μ (µ → Μ) — true
  ```
- **Before fix:** A non-browser engine that implements non-`/u` `i`
  as an *ASCII-only* fold (the common shortcut) returns `false` for
  every line above yet still passes the entire corpus. The
  Perlex-only measurement confirmed it: the only two corpus fixtures
  that reach non-`/u` `i` over a non-ASCII unit are
  `built-ins/RegExp/S15.10.2.8_A3_T18.js` (whose subject string is
  pure ASCII, so its `[\x81-\xff]` class never folds) and
  `language/literals/regexp/u-case-mapping.js` (which asserts only
  the *exclusion* direction — `/K/i` matches neither `k` nor
  `K`). Neither asserts a non-ASCII→non-ASCII fold, so the positive
  direction is unguarded.
- **After fix:** Each line returns `true`; the matcher canonicalizes
  non-ASCII units through the full §22.2.2.7.3 toUppercase orbit.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/RegExp/` (no `features:` tag — base regex). Assert the
  à↔À atom fold, the σ/ς/Σ three-way inside a class, and the µ→Μ
  case, paired with the exclusion negatives (`/K/i` rejects
  `k`/`K`; `/[a-z]/i` rejects ſ). A `match-vs-no-match` table over
  these units would lock down both directions, complementing
  `u-case-mapping.js`'s exclusion-only coverage.

### A third `&` in a `/v` ClassIntersection (`&&&`) compiled instead of throwing

- **Fixed in:** `1dffada`
- **Spec:** §22.2.1 ClassSetExpression / ClassIntersection + §22.2.1.1
  early errors — `ClassIntersection :: ClassSetOperand && ClassSetOperand`
  (with an optional repeated `&& ClassSetOperand` tail). After each `&&`
  the next token must be a ClassSetOperand, and a ClassSetOperand cannot
  begin with `&` (it is a ClassSetReservedDoublePunctuator). So `&&&`
  (and `&&&&`) has no derivation — it is an early error.
- **Reproducer:**
  ```js
  new RegExp("[a&&&b]", "v");   // must throw SyntaxError
  new RegExp("[a&&&&b]", "v");  // must throw SyntaxError
  new RegExp("[a&&b]", "v");    // valid intersection — must construct
  /[a&&&b]/v;                   // literal form: must be a parse SyntaxError
  ```
- **Before fix:** Cynic's native engine returned `Unsupported` on the
  third `&`, deferring to its vendored libregexp fallback, which accepts
  the pattern (QuickJS — also libregexp — agrees). So `[a&&&b]/v`
  compiled instead of throwing. engine262 + V8 / JSC / SpiderMonkey all
  reject it; Cynic and QuickJS were the only acceptors.
- **After fix:** the third `&` is a §22.2.1.1 early error in the native
  engine, so both `new RegExp(…, "v")` and the `/…/v` literal throw
  `SyntaxError` at construction / parse time.
- **Suggested fixture shape:** negative fixture (`negative: { phase:
  parse, type: SyntaxError }` for the literal; a runtime `assert.throws`
  for the `new RegExp` form) under `built-ins/RegExp/unicodeSets/`,
  `features: [regexp-v-flag]`. The corpus has `&&` intersection
  positives and reserved-punctuator negatives, but none assert that a
  *third* `&` after a valid `&&` is rejected — the exact spot a
  libregexp-backed engine slips through.

### A backreference number that overflows the engine's integer width compiled

- **Fixed in:** `6d134cc`
- **Spec:** §22.2.1 DecimalEscape + §22.2.1.1 early errors — a
  backreference `\N` whose CapturingGroupNumber is strictly greater than
  the number of capturing groups is an early error (in a strict, non-Annex
  B engine, in every mode). Annex B §B.1.2 rereads such a `\N` as a
  legacy octal / identity escape, which Cynic drops.
- **Reproducer:**
  ```js
  new RegExp("(a)\\2");                        // SyntaxError — \2 past 1 group
  new RegExp("(a)\\99999999999999999999999");  // must ALSO be SyntaxError
  ```
- **Before fix:** Cynic strict-rejects every out-of-range backref whose
  number fits a `usize` (`\2`, `\99`, `(a)(b)\3`, …) — matching engine262
  + the spec. But a number too large to fit `usize` overflowed the
  parser's integer parse and fell through to the libregexp fallback, which
  applies the Annex B reread and *accepts* the pattern. So the second line
  compiled instead of throwing. engine262 rejects both lines; V8 / JSC /
  SpiderMonkey / Hermes / QuickJS accept both (Annex B). Cynic was the lone
  engine that rejected the small form yet accepted the overflowing one — a
  pure integer-width artifact.
- **After fix:** a backreference value too large for `usize` is trivially
  past the capture count, so the parser raises the same §22.2.1.1 early
  error; both lines throw.
- **Suggested fixture shape:** negative fixture (parse-phase SyntaxError
  for the literal, `assert.throws` for `new RegExp`) under
  `built-ins/RegExp/`, no `features:` tag. The corpus exercises
  out-of-range backrefs with small numbers; a deliberately huge digit run
  (more digits than any integer width holds) would catch an engine that
  rejects the small form but mishandles the overflow boundary.

### `Promise.withResolvers` skipped the NewPromiseCapability executor gate

- **Fixed in:** `080d127`
- **Spec:** §27.2.4.6 Promise.withResolvers + §27.2.1.5
  NewPromiseCapability steps 7-8 (after `Construct(C, « executor »)`,
  `[[Resolve]]` and `[[Reject]]` must each be callable).
- **Reproducer:**
  ```js
  // A constructor that never invokes its executor leaves the
  // capability's resolve/reject undefined — §27.2.1.5 must throw.
  Promise.withResolvers.call(function () {});   // → TypeError

  // And a Promise subclass's own constructor must run:
  class P extends Promise {}
  P.withResolvers().promise instanceof P;        // → true
  ```
- **Before fix:** `withResolvers` inlined a `%Promise%`-only
  construction that never ran `Construct(C, « executor »)`, so the
  bogus constructor yielded a `{ promise, resolve, reject }` object with
  working-looking resolvers instead of throwing, and `P.withResolvers()`
  produced a base Promise (subclass constructor skipped). node / JSC /
  SpiderMonkey / QuickJS / engine262 all throw TypeError for the first
  line.
- **After fix:** routes through the shared `NewPromiseCapability(C)`,
  which runs the `Construct` and enforces steps 7-8 — the first line
  throws TypeError, and the subclass constructor runs.
- **Suggested fixture shape:** positive runtime fixtures under
  `built-ins/Promise/withResolvers/` — one
  `assert.throws(TypeError, () => Promise.withResolvers.call(function(){}))`,
  one asserting `class P extends Promise {};
  P.withResolvers().promise instanceof P`. The existing `ctx-ctor.js`
  exercises a well-behaved custom constructor; neither the
  executor-never-invoked case nor the subclass-instance case is covered.

### `GetSetRecord` accepted a Set-like with a negative `size`

- **Fixed in:** `080d127`
- **Spec:** §24.2.1.2 GetSetRecord step 3.f — if `numSize` < 0, throw a
  RangeError. (Step 3.e already throws TypeError for NaN.)
- **Reproducer:**
  ```js
  const bad = { size: -1, has() { return false; }, keys() { return [].values(); } };
  new Set([1]).union(bad);   // → RangeError
  ```
- **Before fix:** `validateSetLike` clamped a negative size to 0 and
  proceeded, so all seven ES2025 Set methods (union, intersection,
  difference, symmetricDifference, isSubsetOf, isSupersetOf,
  isDisjointFrom) accepted the malformed record. node / JSC /
  SpiderMonkey / QuickJS / engine262 all throw RangeError.
- **After fix:** a negative size throws RangeError, after the existing
  step-3.e NaN→TypeError check.
- **Suggested fixture shape:** negative-path runtime fixture under
  `built-ins/Set/prototype/union/` (and the sibling methods) —
  `assert.throws(RangeError, () => new Set([1]).union({ size: -1,
  has(){…}, keys(){…} }))`. The corpus covers NaN-size (TypeError),
  missing / non-callable has/keys, and a non-object receiver, but not the
  negative-size RangeError of step 3.f.
