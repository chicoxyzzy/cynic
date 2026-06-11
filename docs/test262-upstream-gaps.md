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

### Deep recursion through a native builtin crashed instead of throwing RangeError

- **Fixed in:** `833f8ca`
- **Spec:** §spec — there is no normative stack limit, but an
  implementation that cannot continue must throw
  `RangeError("Maximum call stack size exceeded")` (the
  observable behaviour every shipping engine gives); it must not
  fault the process.
- **Reproducer:**
  ```js
  const o = { get x() { return o.x; } };
  o.x;                                       // recursion via accessor [[Get]]
  // and: function f() { return [0].map(f); } f();
  // and: function f() { return Reflect.apply(f, null, []); } f();
  ```
- **Before fix:** Cynic bounded only *direct* JS recursion (one
  dispatch's frame list, cap 1024). Recursion that re-entered the
  engine through a native builtin — an accessor getter, an
  `Array.prototype.map` / `forEach` callback, `Reflect.apply`, a
  Proxy trap, the promise reaction drain — started a fresh native
  `runFrames` per level with no limit, overflowing the host stack
  (`EXC_BAD_ACCESS`) and crashing the process.
- **After fix:** An address-based stack guard throws a catchable
  `RangeError` before the host stack overflows.
- **Suggested fixture shape:** positive runtime fixtures asserting
  `assert.throws(RangeError, …)` for each native-reentry shape:
  a self-referential accessor getter under
  `built-ins/Object/defineProperty/` or
  `language/expressions/property-accessors/`; a self-recursive
  `Array.prototype.map` callback under
  `built-ins/Array/prototype/map/`; a self-recursive
  `Reflect.apply` under `built-ins/Reflect/apply/`. The corpus
  exercises these builtins heavily but none drives one into
  unbounded native re-entry to assert the RangeError-not-crash
  contract — so a robust engine's stack-limit handling on the
  *native callback* path goes untested. (The bug surfaced only
  because `built-ins/Array/{from,fromAsync}` and
  `built-ins/Temporal/*` fixtures incidentally recurse deeply
  enough to crash mid-sweep; none asserts the limit directly.)

### Binary operand evaluation order when RHS reassigns a function parameter

- **Fixed in:** `05d2e67`
- **Spec:** §13.15.2 EvaluateStringOrNumericBinaryExpression — the
  left operand is evaluated to a value (steps 1-2) BEFORE the right
  operand (steps 3-4), so a side effect in the right operand cannot
  retroactively change the value already read for the left.
- **Reproducer:**
  ```js
  function f(x) { return x + (x = 5); }
  f(3);              // must be 8 (3 + 5), not 10
  function g(x) { return x + x++; }
  g(3);              // must be 6 (3 + 3), not 7
  ```
- **Before fix:** Returned `10` / `7`. A bytecode peephole kept a
  simple-parameter binding in its caller-supplied register and, for
  `lhs op rhs` where `lhs` was that register, emitted `<eval rhs>;
  op r_lhs` — reading `r_lhs` *after* the RHS ran. When the RHS
  reassigns the parameter (`x = 5`) or updates it (`x++`), the
  register already holds the new value, so the left operand was
  observed post-write.
- **After fix:** Returns `8` / `6`. The peephole now falls back to
  the snapshot-first path (`load lhs; save to temp; eval rhs; op
  temp`) whenever the RHS subtree contains any assignment or update
  expression.
- **Suggested fixture shape:** positive runtime fixture under
  `language/expressions/addition/` (and siblings
  `subtraction/`, `multiplication/`, `bitwise-*`). The corpus has
  rich operand-coercion-order coverage (`*-order.js` with logged
  `valueOf` side effects on two *distinct* objects), but none
  exercises a right operand that *mutates a binding the left operand
  already read* — especially a plain function parameter, the case an
  engine is most tempted to keep in a register. A fixture asserting
  `f(3) === 8` for `x + (x = 5)` (and the `x++` / `++x` / `x += n`
  variants) would catch any engine that elides the left-operand
  snapshot. The same gap applies to every numeric/bitwise binary
  operator, since they share the operand-ordering rule.

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

### `Function.prototype.apply` ignored a `length` getter on a *callable* argArray

- **Fixed in:** see working-tree fix to `functionApply` in
  `src/runtime/builtins/function.zig` (SHA to be filled at commit time)
- **Spec:** §20.2.3.1 Function.prototype.apply → §7.3.18
  CreateListFromArrayLike → §7.3.2 Get(O, P) — the `length` read and each
  indexed slot read are accessor-aware. §6.1.7: a function *is* an Object,
  so a callable used as the array-like is read through the same
  accessor-firing `Get`.
- **Reproducer:**
  ```js
  let received;
  function fn(...a) { received = a; }
  let f = function () {};            // a callable used as the array-like
  Object.defineProperty(f, "length", { get() { return 1; } });
  fn.apply(null, f);
  // expected: received.length === 1 (the length getter fired, one undefined arg)
  // observed pre-fix: received.length === 0 (getter ignored, plain slot
  //   read saw the function's own arity 0)
  ```
- **Before fix:** `apply` handled a function used as `argArray`, but read
  its `length` and indexed slots with a plain `JSFunction.get(...)` slot
  read that does not fire accessors. A `length` getter installed via
  `Object.defineProperty(someFunction, "length", { get() { return 1 } })`
  was ignored — `length` was treated as the function's own arity (0) — so
  no arguments were forwarded.
- **After fix:** the read routes through the polymorphic
  `intrinsics.getPropertyChainOnValue(realm, value, key)`, which fires
  accessors on both `JSObject` and `JSFunction` receivers; the getter runs
  and `received.length === 1`.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Function/prototype/apply/` (and a sibling under
  `built-ins/Function/prototype/call/`, which shares the argArray /
  argument-list shape), no `features:` tag. The §28.1.x Reflect sibling of
  this bug *is* covered —
  `built-ins/Reflect/apply/arguments-list-is-not-array-like-but-still-valid.js`
  passes `new Function()`, `new Object()`, `new Number()`, `new Boolean()`
  each with a `length` getter — but there is no equivalent fixture for
  `Function.prototype.apply` / `.call` accepting a *callable* array-like
  whose `length` is an accessor. A fixture mirroring the Reflect one but
  targeting `apply` would catch an engine that special-cases callable
  array-likes with a non-accessor-firing slot read.

### `Number.prototype.toString` / `JSON.stringify` skipped exponential notation

- **Fixed in:** `85c1de7`
- **Spec:** §6.1.6.1.20 Number::toString(x, 10) — exponential form when
  the integer part needs more than 21 digits (`n > 21`) or the magnitude
  is below `1e-6` (`n ≤ -6`); §25.5.2.4 SerializeJSONNumber == ToString.
- **Reproducer:**
  ```js
  (1e21).toString();      // must be "1e+21"
  (1e-7).toString();      // must be "1e-7"
  JSON.stringify(1e21);   // must be "1e+21"
  ```
- **Before fix:** `(1e21).toString()` → `"1000000000000000000000"` (full
  decimal); `JSON.stringify(1e21)` → `"1e21"` (raw, missing the `+`). The
  radix-10 `Number.prototype.toString` and the JSON number serializer each
  had their own formatter that didn't apply the §6.1.6.1.20 thresholds.
- **After fix:** both produce `"1e+21"`, matching engine262 + every
  production engine.
- **Suggested fixture shape:** positive runtime fixtures under
  `built-ins/Number/prototype/toString/` (boundary values `1e20` /
  `1e21` / `1e-6` / `1e-7`, fixed vs. exponential) and
  `built-ins/JSON/stringify/` (a large/small Number serializes with the
  ToString exponential form), no `features:` tag. Existing toString
  fixtures cover the radix argument and NaN/Infinity but not the
  `n > 21` / `n ≤ -6` decimal↔exponential transition.

### `Array.from(string)` iterated by WTF-8 byte, not code point

- **Fixed in:** `ff01cd2`
- **Spec:** §23.1.2.1 Array.from — a String uses the §22.1.5.1 String
  iterator, which yields code POINTS (a supplementary character is one
  element), matching spread / `for-of`.
- **Reproducer:**
  ```js
  Array.from("a\u{1D7D9}b");          // ["a", "𝟙", "b"], length 3
  Array.from("\u{1F600}x", (c,i)=>i); // [0, 1]  (code-point index)
  ```
- **Before fix:** `Array.from("a𝟙b")` produced 6 elements — the astral
  char shattered into its 4 WTF-8 bytes — and the mapfn / output index
  was the byte offset. The string fast path sliced one byte per element.
- **After fix:** 3 code-point elements; index is the code-point index.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Array/from/`, `features: [String.prototype.@@iterator]`,
  using a string with a supplementary character and asserting both the
  element count and the mapfn index. Existing `from` fixtures exercise
  array-likes and custom iterators but not astral-character iteration of
  a primitive string.

### `for-in` enumerated Symbol-keyed properties

- **Fixed in:** `234f372`
- **Spec:** §14.7.5.9 EnumerateObjectProperties — yields only String
  property keys; Symbols are never enumerated (own or inherited).
- **Reproducer:**
  ```js
  var o = { a: 1 };
  o[Symbol("s")] = 2; o[Symbol.iterator] = 3;
  var k = []; for (var p in o) k.push(p);
  k.join(",");  // must be "a"  (no Symbol)
  ```
- **Before fix:** for-in surfaced the Symbol-keyed property (Cynic
  flattens Symbol keys to internal `@@<name>` / `<sym:N>` strings; the
  plain-object enumeration loops skipped only `__cynic_` keys, not these),
  so for-in diverged from `Object.keys` (which excluded it correctly).
- **After fix:** for-in yields only the String keys.
- **Suggested fixture shape:** positive runtime fixture under
  `language/statements/for-in/`, `features: [Symbol]`, with own and
  inherited (prototype-chain) Symbol keys plus String keys, asserting the
  Symbols are absent. Most engines never had this bug (they don't store
  Symbol keys as strings), so the corpus doesn't probe the exclusion
  explicitly — but a robust positive fixture would catch it.

### `ArraySpeciesCreate` ignored `@@species` inherited from `%Array%`

- **Fixed in:** `a9f10e7`
- **Spec:** §23.1.3.34 ArraySpeciesCreate step 5 — `Get(C, @@species)`;
  for `class Sub extends Array` the `@@species` accessor is inherited from
  `%Array%` (Sub's `[[Prototype]]`) and returns Sub.
- **Reproducer:**
  ```js
  class A extends Array {}
  var a = A.of(1, 2, 3);
  a.map(x => x) instanceof A;   // must be true (also filter/slice/
  a.filter(() => true) instanceof A;  // splice/concat/flat/flatMap)
  ```
- **Before fix:** all of map / filter / slice / splice / concat / flat /
  flatMap returned a plain `Array`. The native `@@species` lookup read
  only the constructor's OWN accessors, missing the one inherited from
  `%Array%`, so ArraySpeciesCreate fell back to the default `ArrayCreate`.
  An explicit own `static get [Symbol.species]` was honoured.
- **After fix:** the inherited accessor is invoked with the subclass as
  receiver and returns Sub, so the methods produce Sub instances.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Array/prototype/map/` (and siblings for the other species
  methods), `features: [Symbol.species]`, with a bare `class Sub extends
  Array {}` (NO own `@@species`) asserting `result instanceof Sub`.
  Existing `create-species*` fixtures install an OWN `@@species` (or a
  custom `constructor`), so they never exercise the inherited-accessor
  resolution.

### Promise thenable adoption did not fire the adopting promise's reactions

- **Fixed in:** `8150ddf`
- **Spec:** §27.2.2.2 NewPromiseResolveThenableJob — the job creates a
  FRESH pair of resolving functions (CreateResolvingFunctions) with their
  own `[[AlreadyResolved]] = false`, so a thenable calling `resolve(v)`
  settles the adopting promise and runs its reactions.
- **Reproducer:**
  ```js
  let ran = "no";
  Promise.resolve({ then(res) { res(42); } }).then(v => { ran = "yes:" + v; });
  // after the microtask queue drains, `ran` must be "yes:42"
  ```
- **Before fix:** the thenable's `then` was invoked (so `res` was called),
  but the adopting promise never settled and the `.then` reaction never
  ran. Cynic modelled `[[AlreadyResolved]]` as one promise-level flag that
  `Promise.resolve` had already set true on first seeing the thenable, so
  the job's `resolve(v)` hit the guard and no-op'd. Native promise
  resolution was unaffected.
- **After fix:** the reaction runs with the adopted value; the
  exception-after-resolve guard (a throw after `resolve()` in the
  thenable's `then`) still suppresses the rejection.
- **Suggested fixture shape:** positive **async-flagged** fixture
  (`flags: [async]`) under `built-ins/Promise/resolve/` (and a sibling
  for `new Promise((r) => r(thenable))`), asserting via `asyncTest` that a
  `.then` reaction on a promise adopted from a synchronously-resolving
  thenable fires with the resolved value. The corpus covers thenable
  adoption broadly, but no fixture distinguishes the engine-specific
  shared-`[[AlreadyResolved]]` regression where the reaction silently
  never runs.
### `Number.prototype.toString(radix)` truncated the fraction for radix ≠ 10

- **Fixed in:** `8f99024`
- **Spec:** §21.1.3.6 Number.prototype.toString → §6.1.6.1.20
  Number::toString step 6 — for radix `r ≠ 10`, the result is the
  String representation of `x` in radix `r` at implementation-defined
  precision (every production engine + engine262 use V8's
  DoubleToRadixCString shortest-round-trip expansion).
- **Reproducer:**
  ```js
  (255.5).toString(16);   // expected "ff.8"
  (0.5).toString(2);      // expected "0.1"
  (5.75).toString(2);     // expected "101.11"
  (-10.5).toString(2);    // expected "-1010.1"
  (0.1).toString(3);      // expected "0.0022002200220022002200220022002201"
  ```
- **Before fix:** the non-decimal path handled only integer-valued `x`;
  any non-integer with `radix ≠ 10` fell through to a base-10
  `std.fmt` print, so `(255.5).toString(16)` returned the *decimal*
  string `"255.5"` instead of `"ff.8"`. The fraction was never expanded
  in the requested radix.
- **After fix:** ports the V8 algorithm — emit fraction digits under a
  half-ULP `delta` bound (round-to-even with carry-over into the integer
  part), so the output round-trips and agrees digit-for-digit with
  engine262 / V8 / JSC / SpiderMonkey / Hermes / QuickJS.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Number/prototype/toString/`, no `features:` tag. The
  existing `toString` fixtures (`S15.7.4.2_A2_T*`) only exercise
  integer-valued receivers in non-decimal radixes; none passes a
  non-integer to `toString(<radix ≠ 10>)`, so the whole fractional
  branch is uncovered. A fixture asserting a handful of exact
  expansions (e.g. `(255.5).toString(16) === "ff.8"`,
  `(5.75).toString(2) === "101.11"`) would catch an engine that
  truncates or mis-rounds the fraction.

### `String.prototype.split("")` split by storage byte, not UTF-16 code unit

- **Fixed in:** `8efcfd9`
- **Spec:** §22.1.3.23 String.prototype.split — with an empty separator,
  SplitMatch never matches, so each element is the substring spanning a
  single UTF-16 code unit (§6.1.4 String type). A supplementary
  character is two code units and splits into its lead + trail
  surrogate halves.
- **Reproducer:**
  ```js
  // U+1D7D9 is one code point = two UTF-16 code units (D835 DFD9)
  var p = "a\u{1D7D9}b".split("");
  p.length;                 // expected 4  → ["a", "\uD835", "\uDFD9", "b"]
  p[1].charCodeAt(0);       // expected 0xD835 (lead surrogate)
  p[2].charCodeAt(0);       // expected 0xDFD9 (trail surrogate)
  ```
- **Before fix:** Cynic stores Strings as WTF-8; the empty-separator
  path iterated the raw storage bytes, so a 4-byte character produced
  *four* one-byte fragments (each an ill-formed WTF-8 piece rendering as
  a replacement char) — `p.length === 6` for the input above.
- **After fix:** iterates UTF-16 code units via `utf16.codeUnitAt` /
  `appendCodeUnitAsWtf8`, yielding one element per code unit (lead/trail
  surrogates for supplementary characters); `limit` still caps by code
  unit.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/String/prototype/split/`, no `features:` tag. The existing
  empty-separator fixtures
  (`separator-empty-string-instance-is-string.js`,
  `call-split-instance-is-string-one-two-three.js`, …) all use ASCII
  receivers; none contains a supplementary character, so the
  byte-vs-code-unit distinction is untested. A fixture splitting a
  string with an astral code point on `""` and asserting the surrogate
  halves via `charCodeAt` would catch any engine whose internal
  encoding leaks through `split("")`.

### Array-like iterator `next()` aborted the host on an out-of-range `length`

- **Fixed in:** `3cf3386`
- **Spec:** §23.1.5.2.1 %ArrayIteratorPrototype%.next step 6 —
  `len = ? LengthOfArrayLike(O)` = `F(ToLength(? Get(O, "length")))`
  (§7.1.20 ToLength clamps NaN / -∞ / negatives to 0 and caps at
  2⁵³ - 1).
- **Reproducer:**
  ```js
  // Array.prototype.values over a non-array array-like reads `length`
  // directly. A user-controlled `length` that exceeds i64 range — or
  // is NaN / ±Infinity — must coerce via ToLength, not crash.
  Array.prototype.values.call({ length: Infinity, 0: "a" }).next(); // → { value: "a", done: false }
  Array.prototype.values.call({ length: 1e30, 0: "a" }).next();     // → { value: "a", done: false }
  Array.prototype.values.call({ length: NaN, 0: "a" }).next();      // → { value: undefined, done: true }
  ```
- **Before fix:** the array-like iterator step cast a `Double` `length`
  with a raw `@intFromFloat`, which panics (SIGABRT, uncatchable by JS
  `try`/`catch`) for any finite magnitude past i64 range, NaN, or
  ±Infinity — a trivial host-abort DoS reachable from
  `[].values.call(arrayLike)` / `Array.prototype[Symbol.iterator]`.
- **After fix:** the step routes the `length` Get through the shared
  §7.1.20 `ToLength` helper, so the three reproducers return their spec
  completions and never abort.
- **Suggested fixture shape:** positive runtime fixtures under
  `built-ins/Array/prototype/Symbol.iterator/` — one each for
  `{ length: Infinity }`, a large finite `{ length: 1e30 }`, and
  `{ length: NaN }` on a non-array array-like, asserting the first
  `next()` result. The corpus exercises the iterator on real Arrays and
  TypedArrays, but not a plain array-like whose `length` is an
  out-of-range Number coerced via `LengthOfArrayLike` → `ToLength`.

### ShadowRealm callable-boundary `length` copy aborted on an out-of-range arity

- **Fixed in:** `3cf3386`
- **Spec:** §3.8.3.5.1 (ShadowRealm proposal) CopyNameAndLength
  step 4.b — `targetLen = max(0, trunc(L))`, then set the wrapped
  function's `length` to that integer.
- **Reproducer:**
  ```js
  // requires --enable=ShadowRealm
  const sr = new ShadowRealm();
  const f = sr.evaluate(
    'Object.defineProperty(function g() {}, "length", { value: 1e30 });'
  );
  f.length; // → 1e30 (no host abort)
  ```
- **Before fix:** CopyNameAndLength gated the `length` box on a
  round-trip equality `clamped == @floatFromInt(@intFromFloat(clamped))`,
  but the inner `@intFromFloat` ran unconditionally — so wrapping a
  callable whose `length` exceeds i64 range aborted the host before the
  comparison could short-circuit. NaN / -∞ were already handled; only the
  large-finite arity tripped it.
- **After fix:** the cast is gated by the i32 upper-bound check first
  (`clamped <= 2147483647.0` boxes Int32, else Double); the cast only
  runs once `clamped` is known to fit, so a `1e30` arity round-trips as a
  Double.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/ShadowRealm/prototype/evaluate/` (feature: `ShadowRealm`)
  wrapping a callable whose `length` is `Object.defineProperty`'d to a
  large finite value, asserting the wrapped function's `length` matches.
  Existing fixtures cover the +∞ and 0/NaN cases; none drives an arity
  past the engine's native integer width.

### `setPrototypeOf` on a function + chain walk via Proxy trap segfaulted after GC

- **Fixed in:** `4bdbb66`
- **Spec:** §10.2 [[Prototype]] — a function's `__proto__` is
  reachable through the function and must remain so for the
  lifetime of the function's own reachability. Not a normative
  rule but a memory-safety invariant every shipping engine
  preserves.
- **Reproducer:**
  ```js
  function f() {}
  const h = { get: (t, k, r) => Reflect.get(t, k, r) };
  Object.setPrototypeOf(f, new Proxy(Object.getPrototypeOf(f), h));
  __collectGarbage();
  void (1 / f);  // ToPrimitive walks f.__proto__.@@toPrimitive
  ```
- **Before fix:** Cynic's mark phase walked `JSObject.prototype`
  but not `JSFunction.proto`, so the new Proxy installed as
  `f.__proto__` was reachable only through `f.proto` and got
  reclaimed at the next major sweep. ToPrimitive's chain walk then
  dereferenced 0xaa-poisoned memory and segfaulted (ReleaseSafe)
  or read garbage (ReleaseFast). Fuzzilli's Probe instrumentation
  surfaced this pattern as 166 of 188 deterministic crashes in a
  single 4-minute run.
- **After fix:** Both `markValue`'s function arm and
  `markFunctionInternalSlots` enqueue `f.proto`, matching the
  JSObject prototype handling.
- **Suggested fixture shape:** positive runtime fixture (requires
  a `gc()` host hook — `$262.gc()` is the test262 convention)
  under `language/expressions/binary-operators/` or
  `built-ins/Symbol/toPrimitive/` that calls `gc()` after
  `setPrototypeOf(fn, proxy)`, then exercises a chain walk that
  crosses the new proto. Existing GC stress tests don't combine
  `setPrototypeOf` on a callable with a Proxy proto and a
  subsequent ToPrimitive trigger.

### `new Date(0, 1e308)` aborted the host on the `@intFromFloat` cast

- **Fixed in:** `43cc2ea`
- **Spec:** §21.4.1.13 MakeDay — the result must be a Number;
  out-of-range month / day inputs flow through MakeTime and
  TimeClip to NaN per §21.4.1.14 / §21.4.1.21.
- **Reproducer:**
  ```js
  new Date(0, -2.3e307).getTime();  // → NaN, not a host abort
  Date.UTC(0, 1e20, 1);
  ```
- **Before fix:** `makeUTC` guarded the year against the
  §21.4.1.13 envelope but not month / day; values outside i64
  reached `@intFromFloat` and panicked the process.
- **After fix:** Month and day are clamped to ±9e15 (below i64
  saturation and the downstream `era*146097` overflow threshold),
  returning NaN for larger inputs — matching what TimeClip would
  produce downstream.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Date/UTC/` and `built-ins/Date/` asserting
  `Number.isNaN(new Date(0, 1e20).getTime())`. The existing
  `fp-evaluation-order.js` tests precision but not OOB-month
  aborts; no current fixture drives an OOB month past i64 range.

### TypedArray.prototype.{length, byteLength} aborted on buffers larger than 2^31

- **Fixed in:** `3189821`
- **Spec:** §23.2.3.18 / §23.2.3.2 — return the current size as a
  Number. A Number losslessly represents up to 2^53-1 (§6.1.6),
  so the accessor must accommodate any buffer size the
  implementation allows.
- **Reproducer:**
  ```js
  const buf = new ArrayBuffer(2147483648, { maxByteLength: 4294967296 });
  const v = new Uint8Array(buf);
  buf.resize(2147483649);
  v.length;  // → 2147483649, not host-abort
  ```
- **Before fix:** Both accessors cast `usize` through `@intCast`
  to `i32` before `Value.fromInt32`. A view with > 2^31 elements
  panicked with "integer does not fit in destination type".
- **After fix:** Fast-path the int32 case (the common path); fall
  back to `Value.fromDouble` for the larger range. Result is still
  a Number primitive.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/TypedArray/prototype/length/` exercising
  `length > 2^31` on a growable buffer, asserting the value is
  exact; similar for `byteLength`. Current fixtures top out
  around the array-length cap.

### `parseInt` / `parseFloat` aborted on a string with invalid UTF-8 bytes

- **Fixed in:** `2f41632`
- **Spec:** §19.2.5 parseInt / §19.2.6 parseFloat — `S = ! ToString(string)`.
  ToString never throws here; the parser must consume `S` and
  return NaN if no prefix is parseable, regardless of what bytes
  the string contains.
- **Reproducer:**
  ```js
  // a string whose storage contains a byte that's not a valid
  // UTF-8 start byte (e.g. a lone 0xFF, or a surrogate-half
  // sequence smuggled through fromCharCode).
  parseInt(String.fromCharCode(0xDC00));  // → NaN, not a host abort
  ```
- **Before fix:** `skipStrWhiteSpace` iterated through
  `std.unicode.Utf8View.initUnchecked`, whose internal
  `utf8ByteSequenceLength(b) catch unreachable` panicked on any
  byte that wasn't a valid UTF-8 start byte. The function's own
  docstring already promised "an invalid sequence stops the scan"
  — this was a contract violation against its own spec.
- **After fix:** Manual byte loop calling `utf8ByteSequenceLength`
  and `utf8Decode` with `catch return i`; invalid bytes terminate
  the scan and the parser sees no whitespace at that position.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/parseInt/` and `built-ins/parseFloat/` building a
  string from `String.fromCharCode(0xDC00)` (a lone surrogate) and
  asserting `Number.isNaN`. Existing fixtures cover the WS-only
  and valid-numeric paths; none drives an invalid-UTF-8 prefix
  through ToString.

### `Object.getOwnPropertyNames` aborted on `@memcpy` aliasing under GC pressure

- **Fixed in:** `820f987`
- **Spec:** §20.1.2.10 — return a fresh Array of the receiver's
  own string-keyed property names. No normative rule on lifetime
  management; the engine-side contract is that allocations during
  the loop must not invalidate the keys still being copied.
- **Reproducer:**
  ```js
  const o = {};
  for (let i = 0; i < 100; i++) o[`p${i}`] = i;
  // force allocator reuse of the JSString buffers backing `o`'s keys
  for (let j = 0; j < 1000; j++) ({});
  __collectGarbage();
  Object.getOwnPropertyNames(o);  // → array of names, not host abort
  ```
- **Before fix:** The loop borrowed each `key` slice from existing
  JSString buffers. The inner `allocateString(index_string)`
  triggered GC, which could reclaim a JSString whose bytes a later
  iteration's `key` pointed to; if the next slab allocation landed
  at the same byte address, `allocateString(key)` saw
  `dest_ptr == src_ptr` and Zig's `@memcpy` panicked on the
  aliasing check.
- **After fix:** Each `key` is duped onto `realm.allocator` (not
  the GC heap) at the top of the iteration, so the bytes survive
  any intervening collection.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Object/getOwnPropertyNames/` building an object with
  dozens of string-keyed properties, forcing GC between property
  additions, then asserting the result. No existing fixture
  combines property enumeration with GC stress this way.

### Object spread / rest from a TypedArray dangled the target's index keys

- **Spec:** §7.3.27 CopyDataProperties (used by §13.2.5.5
  PropertyDefinitionEvaluation for `{ ...src }` and by §14.3.3.4
  RestBindingInitialization for `let { ...rest } = src`) — step 4.c.iv
  `CreateDataPropertyOrThrow(target, key, propValue)`. No normative
  rule on lifetime management; the engine-side contract is that the
  target's own property keys must remain valid for the target's
  lifetime, not just the spread expression's.
- **Reproducer:**
  ```js
  // Only observable under allocation-triggered GC (e.g. the
  // harness' --gc-threshold=1). The TypedArray exposes its indices
  // as integer-keyed own properties (§10.4.5.7) — the spread side
  // synthesises a fresh JSString per index that gets rooted only
  // while the opcode runs.
  const v = new Int16Array(50);
  const o = { set b(a) {}, ...v };
  // GC after the opcode closed its key_scope sweeps the index
  // JSStrings; o.properties retains their slice pointers.
  Object.getOwnPropertyNames(o);   // must list "0".."49","b", not crash
  ```
- **Before fix:** `ownPropertyKeysOrdered` allocated a JSString for
  each TypedArray index and rooted it on the spread / rest opcode's
  temporary `key_scope`. The spread loop then passed the returned
  slices straight to `obj.set` (no anchor). For a *non-array-exotic*
  target — a plain object — integer-index keys skip `own_key_order`
  (recordKey rejects them) and land in the property bag as borrowed
  slices. After the opcode's `key_scope.close()` ran, the synthesised
  JSStrings had no remaining root; the next allocation-pressure GC
  swept them and the target's bag held 50+ dangling key slices.
  `Object.getOwnPropertyNames(o)` then walked the bag through
  `orderListContains`, dereferenced reclaimed memory, and
  segfaulted (or returned garbage on shorter-string sites). String-
  keyed spread sources had the same hazard one step removed — the
  slices borrowed from `src`'s `key_anchors`, so dropping `src`
  produced the same dangling-key bag on the target.
- **After fix:** Both opcodes allocate a fresh JSString per key inside
  the loop and route through `storePropertyComputedOwned`, which
  appends the JSString to the target's `key_anchors` — the bag's
  borrowed slice stays live as long as the target.
- **Suggested fixture shape:** positive runtime fixture under
  `language/expressions/object/` (and a sibling under
  `language/statements/variable/` for the rest binding) spreading a
  TypedArray view into a plain-object target, allocating heavily
  between the spread and the next `Object.getOwnPropertyNames` call,
  then asserting the full key list. Existing spread fixtures cover
  the value-copy side and proxy traps but never combine TypedArray
  source + GC stress + post-spread own-key enumeration.

### A class method's `return` inlined an enclosing function's `try`/`finally`

- **Fixed in:** `9c947a8`
- **Spec:** §10.2.10 FunctionDeclarationInstantiation — a method
  body, class constructor body, and `static { … }` class block
  are each function-shape chunks with their own scope chain.
  §14.15.3 / §13.10.1 inline-finally and §9.5.4 DisposeResources
  walks attach to the *enclosing function's* try / using chain,
  not the inner function's.
- **Reproducer:**
  ```js
  try { throw 0; } catch (e) {
      class C { m() { return 99; } }
      (new C()).m();   // → 99
  } finally {
      const t = 1;   // a binding in the finally is the trigger
  }
  ```
- **Before fix:** The class-body compile entry points
  (`compileMethodBody`, `compileConstructorBody`,
  `compileStaticBlockChunk`) did NOT reset the compiler-global
  `finally_chain` / `current_dispose_stack` / `pending_labels` /
  `try_with_handler_depth` / `in_tail_position` at the function
  boundary. The inner `return` then saw the outer try's finally
  chain, inlined the finally body (which declared its own `let`),
  bumped `env_slot_count` past the elided method-entry env, and
  surfaced as a host-side `unreachable` (the `env_slot_count == 0`
  assertion at the elision tail) — observable from the script as
  an engine-internal panic. Fuzzilli surfaced this with a
  `static [self-ref]` class inside `try/catch/finally`.
- **After fix:** All three class-body entry points now mirror
  `compileFunctionTemplateExtNamed`'s save/reset/restore of those
  five compiler-global fields at the function boundary, matching
  the ordinary function-decl / arrow path.
- **Suggested fixture shape:** positive runtime fixture under
  `language/expressions/class/` asserting that
  `(new C()).m()` inside an outer `try { } finally { let t; }`
  returns the method's value cleanly. Sibling fixtures cover
  inline-finally for ordinary functions but none with a method
  body nested inside an outer try-finally.

### `using` block's `dispose_stack` register leaked into a nested class method's frame

- **Fixed in:** TBD
- **Spec:** §13.2.4.6 BlockStatement / §9.5.4 DisposeResources —
  the synthetic dispose-stack and its finally context attach to
  the enclosing function's chunk. A class method compiled inside
  the using block has its own frame and must not emit a
  `dispose_stack r` that references the outer block's register.
- **Reproducer:**
  ```js
  function F() {
      for (const v of "i") {
          const d = Symbol.dispose;
          class C { [d]() {} }
          using r = new C();
      }
  }
  F();   // → completes, no panic
  ```
- **Before fix:** Same root cause as the entry above —
  `compileMethodBody` inherited the outer block's
  `current_dispose_stack` and `finally_chain`, so the method's
  `return` inlined the dispose walk with the outer's register
  index. At runtime the method's frame had only a few registers
  but the opcode read register 4, panicking the interpreter's
  bounds check (`index out of bounds`).
- **After fix:** Same fix as above — the function-body boundary
  saves and resets `current_dispose_stack` along with the rest of
  the finally state.
- **Suggested fixture shape:** positive runtime fixture under
  `language/statements/for-of/using-class-method-body.js` (or
  `language/statements/using/`) wiring a class with a
  `Symbol.dispose` method inside a for-of body that contains a
  `using` declaration, asserting the loop completes. No existing
  fixture combines a `using` declaration with a nested class
  method body.

### `DataView.prototype.byteLength` aborted on length-tracking views past 2^31 bytes

- **Fixed in:** `3597550`
- **Spec:** §25.3.4.1 — return the current view byte length as a
  Number. A Number losslessly represents up to 2^53-1 (§6.1.6), so
  the accessor must accommodate any view size the implementation
  allows.
- **Reproducer:**
  ```js
  const buf = new ArrayBuffer(2147483648, { maxByteLength: 4294967296 });
  const dv = new DataView(buf);
  buf.resize(2147483649);
  dv.byteLength;  // → 2147483649, not host-abort
  ```
- **Before fix:** the accessor cast `usize` through `@intCast` to
  `i32` before `Value.fromInt32`. A length-tracking view over a
  resizable buffer past 2^31 bytes panicked with "integer does not
  fit in destination type".
- **After fix:** Fast-path the int32 case; fall back to
  `Value.fromDouble` for the larger range. Same shape as the
  earlier `typedArrayLength` / `typedArrayByteLength` fix
  (`3189821`).
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/DataView/prototype/byteLength/` exercising a
  length-tracking view past 2^31 bytes on a growable buffer.
  Current fixtures top out around the i32 boundary.

### `Array.prototype.toLocaleString` aborted the host on a self-referential array

- **Fixed in:** `2241a32`
- **Spec:** §23.1.3.32 — `Invoke(elt, "toLocaleString")` for each
  element. A circular array would re-enter
  `Array.prototype.toLocaleString` indefinitely; the spec says
  nothing about cycle detection, but every shipping engine throws
  RangeError on host-stack exhaustion (and the matching
  `Array.prototype.join` already does — see the test262 fixture
  `built-ins/Array/prototype/join/length-near-overflow.js`).
- **Reproducer:**
  ```js
  const a = [];
  a.push(a);
  a.toLocaleString();  // → RangeError, not a host abort
  ```
- **Before fix:** `arrayJoin` had the address-based native-stack
  guard (`stack_guard.nearLimit()` throwing RangeError); the
  sibling `arrayToLocaleString` was missed at the time the join
  guard landed (commit `833f8ca`). The 4h Fuzzilli post-host-
  safety-fixes run surfaced six distinct reprs that all
  trace-bottom into this recursion.
- **After fix:** Same `stack_guard.nearLimit()` check at the top
  of `arrayToLocaleString`, throwing a catchable RangeError.
- **Suggested fixture shape:** positive runtime fixture under
  `built-ins/Array/prototype/toLocaleString/` asserting that
  `assert.throws(RangeError, () => { const a = []; a.push(a);
  a.toLocaleString(); })`. The join sibling has this fixture
  (`length-near-overflow.js` family); the toLocaleString one
  doesn't.

### A bare `\` inside a block spun parser error-recovery, OOMing the host

- **Fixed in:** `89f671b`
- **Spec:** §12.7 IdentifierName (a `\` not opening a
  `UnicodeEscapeSequence` is not a valid token → SyntaxError) and
  §14 StatementList. There is no normative recovery algorithm —
  this is an engine-shape robustness bug, not a conformance one —
  but the input is a finite, well-formed byte sequence the engine
  must reject with a catchable SyntaxError, never with unbounded
  allocation.
- **Reproducer:**
  ```js
  {1\
  // also: {;\   ·  switch(0){default:1\   ·  class C{static{1\
  //       function f(){1\   ·  try{1\
  // the originally-reported degenerate form (doubled split/regex):
  // try { var r = "x".split(/try { var r = "x".split(/\d/); } …
  ```
- **Before fix:** A lone `\` (not `\u…`) makes the lexer report
  `invalid_escape_sequence` and return the error *without consuming
  the backslash* (`scanIdentifierStart` → `parseIdentifierEscape`
  leaves `pos` parked on the `\`). A StatementList recovery loop
  (block / switch-case / function / static-block body) that hits
  `ParseError`, resynchronizes, and retries therefore never
  advances: `synchronize`'s `bump() catch return` bails on the
  in-place lex error, leaving `current` on the same token, so the
  loop re-parses it forever and grows the parse arena without
  bound — RSS climbed past multiple GB (observed 133 GB / 3 GB
  under a cap) until the host OOMed. The bug needed at least one
  successfully-parsed item before the `\` so the `\` was the loop's
  *third-or-later* token; the top-level program loop already had a
  forward-progress guard, so a `\` reached as the first/second
  token (e.g. `{\`) rejected cleanly.
- **After fix:** A shared `recoverStatementListItem` guard (now used
  by the program, block, and switch-case loops) forces a `bump`
  when a resync made no progress and breaks the loop when even that
  bump can't advance (the wedged-lexer case). Every form above
  terminates in a few steps with a catchable SyntaxError.
- **Suggested fixture shape:** negative parser fixture (`negative:
  phase: parse, type: SyntaxError`) under
  `language/statements/block/` (mirrors under
  `language/statements/switch/` and `language/statements/class/`
  static blocks) with a body like `{ 1\ ` — a robust engine rejects
  it as a SyntaxError; the value is catching the host-abort
  variant. No existing fixture pairs a parsed StatementListItem
  with a trailing lone backslash inside a nested block.

### Const reassignment silently succeeded for register-promoted locals

- **Fixed in:** `30dca94` (2026-06-11)
- **Spec:** §8.1.1.1.4 SetMutableBinding step 4 (immutable binding →
  TypeError when S is true; const bindings are created
  strict-immutable per §14.3.1.1)
- **Reproducer:**

  ```js
  function f() {
    const a = 1;
    try { a = 2; } catch (e) { return e instanceof TypeError; }
    return "no-throw: " + a;
  }
  f();
  ```

- **Before fix:** when an engine promotes non-captured function-body
  `let`/`const` bindings into registers (Cynic's body-local register
  promotion; analogous fast paths exist in production tiers), the
  promoted store path bypassed the const-immutability lowering: the
  write landed in the register and `f()` returned `"no-throw: 2"`.
  The corpus didn't catch it because the existing
  `const-invalid-assignment` shapes either sit at top level / in
  blocks (not promotable positions) or assert the error from a
  *non-promoted* context.
- **After fix:** every non-init store to a const binding lowers to the
  runtime TypeError regardless of storage (env slot, global slot, or
  promoted register), ordered after the §8.1.1.1.4 step 2
  uninitialized-binding ReferenceError.
- **Suggested fixture shape:** runtime positive under
  `language/statements/const/` — a *function-body* const with no
  closure capture, reassigned inside `assert.throws(TypeError, …)`,
  plus a sibling where the reassignment sits in a nested block of the
  same function. The function-body placement is the load-bearing part:
  it puts the binding in the exact position register-promoting engines
  optimize.

### Deep prototype / static-inheritance chain crashed the host on property read

- **Fixed in:** `8f7ae3e` (2026-06-11)
- **Spec:** §10.1.8.1 OrdinaryGet / §7.3.12 HasProperty — the
  prototype-chain walk
- **Reproducer:**

  ```js
  var o = null;
  for (var i = 0; i < 200000; i++) o = Object.create(o);
  o.nope;          // a missing-property read walks the whole chain
  ```

- **Before fix:** `JSObject.get` / `hasProperty` and `JSFunction.get`
  walked the prototype chain by native recursion (`return
  proto.get(key)`). A chain this deep — trivially built with
  `Object.create` in a loop, or a deep `class … extends …` tower —
  recursed once per link and overflowed the native C stack, SIGSEGV'ing
  the host process. Untrusted JS could thereby abort the embedding host
  (a denial-of-service), violating the never-abort-the-host contract.
  The corpus doesn't catch it: no fixture builds a multi-100k-deep
  chain, and a process crash is invisible to a conformance assertion
  regardless.
- **After fix:** each walk iterates the chain in a loop (the
  realm-aware getter-firing `getPropertyChain` was already iterative);
  a deep chain resolves to `undefined` / `false` in bounded stack.
- **Suggested fixture shape:** a runtime positive under
  `built-ins/Object/create/` building a deep `Object.create` chain in a
  loop and asserting a missing-property read returns `undefined` — the
  value is in *not crashing*. The overflow depth is host-stack-dependent,
  so it may fit better as an engine-internal robustness test than a
  portable test262 fixture (cf. the deep-nesting parser cases).
