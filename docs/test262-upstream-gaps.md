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
