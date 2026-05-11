# post-yield-star runtime triage — 2026-05-11

**Top line:** with major levers (array destructuring, private accessors,
static private slots, for-await-of, yield\*, super spread, numeric-key
destructuring) shipped, runtime sits at **27,812 / 46,320 (60.05 %)**,
with **~10,324 false-reject fails** in `--mode=runtime`. The remaining
deficit is concentrated in async-generator iterator-protocol error paths,
old `15.4.4.x` ToObject-on-primitives prototype tests, and a small set
of systemic gaps in the iterator-record machinery.

Run: `zig build test262 -- --mode=runtime --quiet --threads=2 --list-failures=20000`.

## Top buckets (dir1/dir2 — raw fail count)

| #  | Bucket | Fails |
|----|---|------:|
|  1 | language/statements/class            | 1499 |
|  2 | language/expressions/class           | 1330 |
|  3 | built-ins/Array/prototype            |  774 |
|  4 | language/expressions/object          |  526 |
|  5 | built-ins/TypedArray/prototype       |  433 |
|  6 | built-ins/RegExp/prototype           |  321 |
|  7 | built-ins/String/prototype           |  308 |
|  8 | language/expressions/dynamic-import  |  304 |
|  9 | language/expressions/async-generator |  163 |
| 10 | built-ins/TypedArrayConstructors/internals | 144 |
| 11 | built-ins/Function/prototype         |  127 |
| 12 | language/statements/for-of           |  115 |
| 13 | built-ins/Object/defineProperties+defineProperty | 186 |

## Systemic root causes (rank by leverage = est_delta / hour)

### 1. Async generators inside class methods — yield\* error-path + iterator-protocol gaps. **L, ~1,750 fails.**

`class/elements/async-gen-private-method[-static]` (76 fails) plus
the dominant chunk of `class/dstr` (224 of 244 are async-gen / gen-method
bodies) plus `object/method-definition/async-gen-*` (~330 of 433)
plus `language/expressions/async-generator` (163) plus
`language/statements/async-generator` (84). The fixtures we sampled
exercise:

- `yield*` against a thenable whose `[Symbol.asyncIterator]` returns
  undefined / null / non-callable / non-object — should TypeError
  cleanly and complete the outer async gen.
- `yield*` against a sync iterable inside an async generator —
  per spec, GetIterator(SyncToAsync) wrapping, with each `next()`
  awaiting the resolved IteratorResult.
- Abrupt completion of the outer async gen must call `IteratorClose`
  / `AsyncIteratorClose` on the delegate iterator with `return` / `throw`.

Surgical site: `src/runtime/interpreter.zig` (async-gen `yield*` lowering
emitted by the bytecode compiler — likely `src/bytecode/compiler.zig`
`compileYieldStar` async branch) plus the IteratorRecord error path in
`src/runtime/iterator*.zig`. The wrapping (sync-to-async iterator) and
the abrupt-close paths are the cores. Fixing the async-iterator-close
contract alone should drop ~300-500 across object/method-definition and
class/dstr; getting the GetIterator-method-throws / returns-non-object
paths right adds another big chunk.

Repro:
```
async function* g() { yield* { [Symbol.asyncIterator]() { return undefined; } }; }
g().next().then(v => print("resolved"), e => print("rejected " + e.constructor.name));
```
Expect `rejected TypeError`.

### 2. Old `15.4.4.x` Array.prototype tests on primitive receivers / Array.prototype-as-prototype-chain accessors. **M, ~400 fails of 774.**

The biggest individual sub-buckets — `reduceRight (114)`, `lastIndexOf
(63)`, `map (48)`, `concat (46)`, `filter (39)`, `indexOf (37)`,
`every (27)`, `some (28)`, `splice (27)`, `forEach (25)` — are nearly
all the legacy `15.4.4.X-A-B-C` family, sharing 3-4 patterns:

- `Array.prototype.X.call(false, cb)` / `.call(1, cb)` / `.call("ab", cb)`
  — ToObject coercion of primitives to wrapper objects, then iterating
  on inherited length/index. Many also install `Boolean.prototype.length`
  / `Boolean.prototype[0]` and rely on prototype-chain lookup.
- Sparse arrays with accessor getters that mutate `length` mid-iteration
  (`9-b-iii`, `9-c-i` variants).
- `length` getter throws / index getter throws / `length` is a
  ToString-poisoned object.

Confirmed repro fails: `[1,2,3].lastIndexOf` with a coercing `fromIndex`
already works (`Number("2E0") === 2`), so the deficit isn't simple
ToInteger. It's the receiver-coercion + accessor-on-prototype path.
Site: `src/runtime/builtins/array.zig` — these methods likely loop
over `internal_storage` directly instead of going through HasProperty/Get
which would honor prototype-chain accessors. Switching to the spec
"abstract operation" loop (`ArraySpeciesCreate` aside) — using
`ToObject` + `LengthOfArrayLike` + `Get(O, ToString(k))` — should
cleanly unlock this whole tier across 10+ method buckets at once.

### 3. `cpn-class-*-computed-property-name-from-*` tests. **S-M, ~250 fails.**

Distinct from class/elements; these are top-level class-body fixtures
named `cpn-class-decl-...` / `cpn-class-expr-...`. The bucket-distribution
data shows them as the dominant non-`elements` sub-dir under
`language/statements/class` and `language/expressions/class`. The fixture
names suggest: computed property names that come from a particular
expression form (assignment, arrow function, generator function,
conditional, math expression, multiplicative, …). Likely cause: the
computed-property-name evaluation in class-body installation either
swallows toPrimitive errors, mis-orders side-effects, or mis-names the
function (per §15.2 SetFunctionName). Site: class-body compile in
`src/bytecode/compiler.zig` + `src/runtime/class.zig` (ClassDefinitionEvaluation).
A single fix for "evaluate-computed-name-as-PropertyName-with-toPropertyKey-then-SetFunctionName"
could land ~150 in one go.

### 4. `RegExp.prototype[Symbol.{replace,match,split,search,matchAll}]` user-subclass paths. **M, ~190 fails.**

`Symbol.replace 66`, `Symbol.match 45`, `Symbol.split 43`,
`Symbol.search 21`, `Symbol.matchAll 18`. These are the
"installed-on-user-subclass-of-RegExp" / "user-replaces-`exec`-on-prototype"
/ "lastIndex-coercion-throws" / "result-coerce-index-err" paths — i.e.
the spec algorithm that re-invokes user-replaceable hooks
(`@@matchAll`, `exec`, `lastIndex` getter, `flags` getter). Cynic
probably calls the fast internal regex path without consulting
user-overridden hooks. Site: `src/runtime/builtins/regexp.zig` —
make each `Symbol.X` call the spec's `RegExpExec` abstraction (which
checks for a user `exec`) and re-route per-iteration property reads
(`lastIndex`, `flags`, `unicode`, `sticky`, `global`) through
`Get(R, "name")`.

### 5. `String.prototype.split / replaceAll / matchAll / replace` user-regexp paths. **S-M, ~90 fails of 308.**

Symmetric to lever #4 — String methods that, given a regex argument,
must delegate to `@@split` / `@@replace` / etc. Same root surgical
site (regexp.zig + a small dispatch fix in `src/runtime/builtins/string.zig`).
Won't fully drain the 308 String fails (the rest are scattered:
`indexOf 24`, `substring 12`, `startsWith 9`, `endsWith 11`,
`isWellFormed 8`, `toWellFormed 8`, `padStart 5`, etc.) but lights up
the largest sub-buckets.

### 6. TypedArray prototype methods iterating sparse / detached / out-of-bounds buffers. **M, ~250 fails of 433 (drop SAB/BigInt).**

`set 61`, `slice 54`, `subarray 39`, `filter 35`, `map 34`,
`toLocaleString 30`, `fill 29`. 96 of these are `*-sab.js`
(SharedArrayBuffer — out of scope). Many BigInt64/BigUint64
variants exist (subdir `BigInt/`). The remaining ~250 cluster on:

- Detached-buffer-during-tointeger-offset / start / end.
- Out-of-bounds index on a resizable buffer.
- `set(typedarray-arg, ...)` with overlapping source.

Site: `src/runtime/builtins/typed_array.zig` — wrap every iteration
with the "throw-if-detached" check at each spec-prescribed point
(not just up-front). High-touch but mechanical.

### 7. TypedArrayConstructors/internals MOP traps. **M, ~144 fails.**

`DefineOwnProperty 46`, `Set 44`, `HasProperty 20`, `Get 12`,
`Delete 10`, `OwnPropertyKeys 8`, `GetOwnProperty 4`. These are the
exotic-object MOP override fixtures: integer-indexed-element rules
(canonical-numeric-index-string), out-of-bounds Get → undefined (not
throw), DefineOwnProperty with non-writable on integer keys, etc.
Site: `src/runtime/object.zig` for TypedArray exotic class (or
wherever TypedArray's `[[Get]]` / `[[Set]]` overrides live).

### 8. `Object.defineProperties` / `defineProperty` legacy `15.2.3.7-*` tests. **S, ~120 fails (of 186).**

`Object/defineProperties 95`, `defineProperty 91`. Sample: passing
a props object whose enumerable own accessor returns a descriptor
with no `get` — must define a default-undefined accessor (not
throw). Likely a strictness mismatch in `ToPropertyDescriptor` /
the validation around accessor descriptors. Site:
`src/runtime/builtins/object.zig` `ToPropertyDescriptor` and
`ValidateAndApplyPropertyDescriptor`.

### 9. `Function.prototype.toString` source-text fidelity for class accessors / async methods / generator methods. **L for full, S for the low-hanging chunk, ~44 fails.**

Tests assert the exact original source text (with comments preserved)
for getters/setters defined inside class expressions. Cynic probably
emits a synthetic toString. Site: `src/runtime/function.zig` —
store source span on FunctionObject and slice the original module
source. Already done for plain functions (the simple `function f(){}`
case works); class accessor / async methods need their source-span
range plumbed through `ClassElement` lowering.

### 10. `built-ins/Function/prototype/{apply,call,bind}` cross-realm tests + Function.prototype.toString. **S-M, ~75 fails of 127.**

`apply 27 + call 23 + bind 21 = 71`. About 1/3 of `apply` / `call`
fails are `*-realm.js` (`$262.createRealm`) cross-realm — Cynic
likely lacks a working multi-realm $262 host. The rest are
`argarray-not-object` / `this-not-callable` / typed-array-arg cases
which should be cheap to fix.

## Systemic call-outs spanning buckets

- **Iterator-record + iterator-close.** Touches: class/dstr (244),
  object/method-definition (~143 dstr + many gen tests), language/for-of
  iterator-close fixtures, async-generator yield\* abrupt-close. One
  audit of `src/runtime/iterator*.zig` to make sure every entry point
  builds a real IteratorRecord and routes abrupt completions through
  IteratorClose (sync) / AsyncIteratorClose (async) probably moves
  300+ across 4 buckets.
- **Spec-faithful prototype-chain access in built-ins.** Array, TypedArray,
  and even Object built-ins that loop over an array-like via direct
  internal-storage reads (instead of `Get(O, ToString(k))`) miss the
  inherited / accessor-on-prototype / `length`-getter-throws fixtures.
  Same fix shape across Array.prototype, TypedArray.prototype,
  `Object.{assign,keys,values,entries,defineProperties}`, JSON.stringify.
- **Spec-prescribed re-entrancy points in regexp/string methods.**
  RegExp `@@*` methods + String methods that take a regex must consult
  user-replaceable hooks (`exec`, `flags`, `lastIndex` getter,
  `@@matchAll`). One audit pass over `regexp.zig` + the regex-accepting
  String methods drains ~280 across two top-level buckets.

## Quick wins (smallest fix → non-trivial delta)

1. **`Object.defineProperties` accessor-descriptor-with-no-getter** (S, ~50)
   — fix one branch in `ToPropertyDescriptor`.
2. **`Function.prototype.{apply,call}` reject non-array-like argArray cleanly**
   (S, ~25) — the non-realm tests.
3. **TypedArray detached-buffer check inside `set`/`slice`/`subarray`/`fill`**
   (S, ~80) — repeat the check at every spec re-entry, no new logic.
4. **`Array.prototype.lastIndexOf` / `indexOf` / `includes` sparse-array
   correctness via `HasProperty` + `Get` rather than internal-slot read** (S, ~80).
5. **`String.prototype.split` regex delegation to `RegExp.prototype[@@split]`**
   (S, ~25) — a one-line dispatch.

## Out of scope (skip, not lever)

- **`language/expressions/dynamic-import` (304).** Deferred per ROADMAP.
- **`language/module-code/top-level-await` (56).** Module-graph TLA — defer.
- **SharedArrayBuffer (`*-sab.js`, ~96 across TypedArray).** Not shipped.
- **`$262.createRealm` cross-realm tests (~30 inside Function/prototype/*).**
  Needs multi-realm host harness; defer.
- **`*-eval-*` direct-eval fixtures inside class elements (~6).** `eval` is
  permanently out per AGENTS.md.
- **`built-ins/RegExp/{property-escapes,unicodeSets}` (75 + 67 = 142).**
  Unicode property data + Unicode-Sets parsing — bulk-data work, defer.

## Suggested order of attack (max delta in the next ~3 days)

1. Audit + fix the async-iterator-close path in `yield*` and dstr (lever #1)
   — biggest single move, ~400-700 fixtures.
2. Rewrite the Array.prototype iteration loop to use spec abstractions
   (lever #2) — ~300-400 fixtures, very mechanical.
3. RegExp `@@*` user-hook dispatch (lever #4) — ~190 fixtures.
4. Class computed-property-name evaluation (lever #3) — ~150 fixtures.
5. Quick wins #1-#5 — ~260 fixtures combined, all S effort.

Realistic target: a `--mode=runtime` score in the **mid 60 %s**
(~30,000 pass) without touching dynamic-import, TLA, SAB, or full
Unicode-property RegExp.
