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
