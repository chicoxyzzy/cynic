# Cynic

A strict-only ECMAScript engine, written from scratch in Zig.

Cynic targets non-browser hosts — edge runtimes, Workers, server-side JS
— and omits browser-era legacy by design:

- **No sloppy mode.** Every source is parsed as strict. The strict
  reserved-word set, restricted assignment to `eval` / `arguments`, and
  the absence of `with`, labels, legacy octal, HTML-like comments, and
  Annex B *language* extensions (sloppy-mode-only function-in-block,
  `for-in` initializer, …) are baked in at the language level.
- **No browser-era built-ins.** `escape` / `unescape`, the 13
  `String.prototype` HTML wrappers (`anchor`, `bold`, …), and
  `Date.prototype.{getYear, setYear}` aren't shipped. The normative
  aliases real-world code actually uses
  (`String.prototype.{substr, trimLeft, trimRight}`,
  `Date.prototype.toGMTString`) are kept.
- **No runtime code construction.** `eval`, `new Function(string)`,
  `new GeneratorFunction(string)`, `new AsyncFunction(string)`. Aligns
  with [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses).

## Goals

- Track the spec faithfully — internal function names mirror ECMA-262
  abstract operations so test262 failures map cleanly to spec sections.
- Pass the strict subset of [test262](https://github.com/tc39/test262).
- Draw inspiration from production engines — V8 (Ignition + Sparkplug +
  Maglev + TurboFan), JavaScriptCore (LLInt + Baseline + DFG + FTL), and
  SpiderMonkey (Bytecode interp + Baseline Interp + Baseline Compiler +
  WarpMonkey) — without copying any one of them. Smaller engines like
  Hermes (AOT bytecode) and QuickJS (compact single-tier) are useful
  reference points; we vendor QuickJS-NG's `libregexp.c` for §22.2 RegExp.
  The plan is a clean bytecode interpreter first, then tiered compilation;
  the exact tier shape stays open until we have a working interpreter to
  measure against.
- Stay friendly to [SES / Hardened JavaScript](https://github.com/endojs/endo/tree/main/packages/ses)
  and the [Compartments](https://github.com/tc39/proposal-compartments) direction
  — strict-only and no Annex B *language* extensions already align Cynic
  with that world (the few normative Annex B *built-ins* we ship are
  trivial to omit per-realm); runtime design will keep tamper-proof
  primordials and Compartment-style isolation in mind.

## Status

Pre-alpha. Lexer + parser + bytecode interpreter ship; the runtime is
filling in. JITs and generational GC are future work. See
[`docs/ROADMAP.md`](docs/ROADMAP.md) for the thematic breakdown.

### Conformance

test262 conformance, Cynic-scoped (history + legend in
[`test262-results.md`](test262-results.md)):

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser**  | 54.76 % | 95.61 % | 28,542 / 52,125 |
| **runtime** | 30.15 % | 42.34 % | 15,718 / 52,125 |

`spec%` is coverage of the (Cynic-targeted) corpus; `attempted%` is the
quality of what's shipped, ignoring skips. Plus 700+ unit tests.

### What works today

**Parser.** Full §13 expression grammar with cover-grammar arrows;
classes with private members + getters/setters + static blocks;
generators, async, async generators; modules (`import` / `export` in
all forms); destructuring across declarators, params, catch, for-loop
bindings, and assignment targets — including rest patterns and defaults
+ nesting + renaming; regex literals via parser-driven lexer re-entry;
optional chaining, nullish coalescing, logical-assignments, `import.meta`,
dynamic `import()`.

**Statements & control flow.** `if` / `else`, `switch` (with
fall-through), `while`, `do/while`, C-style `for`, `for-of` over any
iterable (`@@iterator` with array-like fallback) including `for (const
[a, b] of pairs)` destructuring, `for-in` over own + inherited string
keys, `try` / `catch` / `finally` (including finally-on-throw via
synthetic handlers and finally-on-return inlined into `return`),
`throw`, lexical bindings with TDZ enforcement, closure-per-iteration
in both `for-let-of` and C-style `for-let`, template literals, tagged
templates, destructuring (defaults, nested, rest, all target positions
incl. function params), array + call-arg + `new C(...args)` spread,
iterator-close on for-of break + return per §7.4.6.

**Functions & classes.** Functions, arrows, closures via captured
environments; implicit `arguments` inside non-arrow functions;
`Function.prototype.{call, apply, bind}` (bind chains, prefix args,
`new boundFn(...)` ignores bound `this` per §10.4.1.2); class
declarations + expressions, instance + static methods, `extends`,
`super(...)`, `super.method(...)`, `super[expr]`, default-constructor
synthesis, only-via-`new` check, public + private instance fields with
brand checks, private methods, static fields, static blocks, getters /
setters on classes and object literals.

**Built-ins.** `Object` (`keys`/`values`/`entries`/`getPrototypeOf`/
`hasOwn`/`create`/`assign`/`freeze`/`seal`/`defineProperty`/
`fromEntries`/`groupBy`/…); `Array` (`isArray`/`of`/`from`) plus the
standard `Array.prototype` method set; `String.prototype` (`charAt`/
`slice`/`replace`/`replaceAll`/`padStart`/`split`/`match`/`matchAll`/
`search`/`codePointAt`/`localeCompare`/`normalize` passthrough/…);
full `Math`, `Number.*`, `JSON.{stringify, parse}`, `parseInt` /
`parseFloat`; URI globals (`encodeURI` / `decodeURI` + component
variants, full UTF-8 validation throwing `URIError` on malformed
input); `Map` / `Set` / `WeakMap` / `WeakSet` (insertion-ordered,
SameValueZero, full method surface, `Map.groupBy`); `Reflect`
(`has`/`get`/`set`/`deleteProperty`/`ownKeys`/`defineProperty`/
`getOwnPropertyDescriptor`/`preventExtensions`/…); **real `Symbol`
primitive** (NaN-boxed pointer-tagged variant; `typeof === "symbol"`;
distinct symbols are distinct property keys via per-symbol synthetic
key strings) with the standard well-known symbols, `Symbol.prototype.{
toString, valueOf, description}`, and `Symbol.for` / `Symbol.keyFor`
registry; `BigInt` (pointer-tagged i128, full arithmetic + ToBigInt);
`ArrayBuffer` / `DataView` + the typed-array family (`Int8Array` /
`Uint8Array` / `Int32Array` / `Float64Array` / `BigInt64Array` / …)
with the standard `%TypedArray%.prototype` surface; `Date` (constructor,
`.now()` / `.UTC()`, the standard `getXxx` / `setXxx` methods, all in
UTC; `toUTCString`, `toDateString`, `toTimeString`, `toLocale*` aliases);
typed `Error` / `TypeError` / `RangeError` / `ReferenceError` /
`SyntaxError` / `URIError` constructors with proto chain.

**Iterator helpers.** `Iterator` global with `Iterator.from(x)` and
prototype methods `map`, `filter`, `take`, `drop`, `toArray`,
`forEach`, `find`, `some`, `every`, `reduce`.

**RegExp.** Full ECMA-262 engine via vendored QuickJS-NG `libregexp.c`
(MIT, ~3500 LOC C). Backreferences, named groups, lookahead /
lookbehind, `u` / `v` flags, sticky / global / multiline / dotAll /
ignoreCase. Bridged from Zig with UTF-8 ↔ UTF-16 transcoding so match
indices land in spec-correct UTF-16 code units. `String.prototype`
methods (`match`, `matchAll`, `replace`, `replaceAll`, `split`,
`search`) all dispatch through it.

**Promises & async.** `Promise` with **full chaining semantics for
both settled and pending sources** — `.then(onF, onR)` registers a
reaction record, settlement enqueues a `promise_reaction` microtask
that runs the appropriate handler and resolves the chained
result Promise. Handler return values propagate; Promise-returning
handlers chain (`p.then(v => Promise.resolve(v+1))` works); throwing
handlers reject. `Promise.{resolve, reject, all, race, allSettled,
any, catch, finally}`. `new Promise(executor)` with working
resolve/reject. **`async function` with full pending-await suspension**
— the awaiting frame state is captured into a `JSGenerator` that's
registered as an internal waiter on the pending Promise; settlement
schedules an `async_resume` microtask that re-enters the dispatch loop
with the resolved value (or throws the rejection inside the resumed
frame). Generators (`function*` with `yield`, `it.next(arg)` resume,
`[Symbol.iterator]` self-iteration); **async generators** with
pending-promise yield-await chaining via promise reactions.

**Proxy.** `get`, `set`, `has`, `deleteProperty`, `defineProperty`,
`getOwnPropertyDescriptor`, `ownKeys` traps. **Callable proxies** —
`new Proxy(fn, handler)` produces an invocable wrapper that unwraps to
the target function on call / `new`. Apply / construct trap dispatch is
future work.

**Internals.** NaN-boxed value rep, Ignition-style register-file +
accumulator bytecode, stop-the-world mark-sweep heap. The test262
harness preload uses upstream `harness/sta.js` + `harness/assert.js`
(no Cynic-shipped shim).

### Known gaps

`yield*` (generator delegation; parser accepts, compiler errors),
`for await of` end-to-end runtime, top-level `await` in modules, real
module graph (cyclic imports, namespace objects, dynamic `import()`
resolution — current dynamic-`import` is a `TypeError` stub),
generator `.return()` running pending `finally` blocks inside the body
(only finally-on-throw fires today), tail-call optimization,
`Set.prototype.{union, intersection, difference, …}` ES2025 helpers,
`WeakRef` / `FinalizationRegistry`, `Promise.{try, withResolvers}`,
`Function.prototype.toString` returning real source, `String.prototype.normalize`
real NFC/NFD/NFKC/NFKD (currently passthrough), `Date` timezone
handling beyond UTC. Each takes a swing at the runtime score as it
lands.

## Build

```sh
git submodule update --init vendor/test262   # one-time; needed for `zig build test262`

zig build              # build cynic into zig-out/bin/
zig build test         # run all unit tests
zig build test262      # test262 conformance (parser mode by default)
zig build run -- lex   path/to/file.js              # tokenize and print
zig build run -- parse path/to/file.js              # parse a Script
zig build run -- parse --module path/to/file.js     # parse a Module
zig build run -- parse path/to/file.mjs             # .mjs ⇒ module
zig build run -- eval  '1 + 2 * 3'                  # compile + run an expression
zig build run -- run   path/to/file.js              # compile + run a script
zig build run -- run   a.js b.js c.js               # multiple files share one realm
```

Requires Zig 0.16 or newer.

`zig build test262` accepts forwarded flags after `--`:

- `--filter=<glob>` — run only matching paths.
- `--list-failures=<n>` — print the first `n` failing paths after the tally.
- `--mode={parser,runtime}` — parser-only (default) or full parse → compile → execute.
- `--quiet` / `--verbose` — progress noise dial.
- `--no-harness` — skip the `sta.js` + `assert.js` preamble in runtime mode (for measuring the floor).
- `--write-results` — update `test262-results.md` with today's row for the given mode. Re-running the same `(date, mode)` replaces that day's row rather than appending. The default run never touches that file.

The Unicode `ID_Start` / `ID_Continue` tables are committed under
`src/unicode/ident_tables.zig` (currently Unicode 17.0). ECMA-262 §3
references `unicode.org/versions/latest`, so we track upstream:
drop a refreshed `DerivedCoreProperties.txt` into `vendor/unicode/`
and run `zig build gen-unicode` to regenerate.

## Working on Cynic

Contributors — human or AI agent — should read
[`AGENTS.md`](AGENTS.md) for project conventions (tests-first,
prior-art surveys, spec-faithful naming) and pointers into the
engineering handbook under [`docs/handbook/`](docs/handbook/).

## Layout

```
src/
├── main.zig                CLI entry point (lex / parse / eval / run)
├── root.zig                Library root, re-exports public API
├── source.zig              Source, Span, line/column lookup
├── diagnostic.zig          Diagnostic representation + Code enum
├── lexer/
│   ├── lexer.zig           Strict-mode lexical scanner (§11/§12)
│   └── token.zig           Token + reserved-word table (§12.7)
├── unicode/
│   ├── idents.zig          IdentifierStart / IdentifierPart predicates
│   └── ident_tables.zig    Generated UCD ranges (do not edit)
├── ast.zig                 AST barrel module
├── ast/
│   ├── expression.zig      §13 expression nodes
│   ├── statement.zig       §14/§16 statement nodes
│   ├── program.zig         Top-level Script / Module
│   └── printer.zig         S-expression dumper (used by tests + CLI)
├── parser/
│   ├── parser.zig          Statement parser, token-stream API,
│   │                       module entry, parseScript / parseModule
│   ├── parser_test.zig     Parser unit tests
│   └── expression.zig      Pratt-style expression parser
├── bytecode.zig            Bytecode barrel module
├── bytecode/
│   ├── op.zig              Opcode enum + operand-decoding helpers
│   ├── chunk.zig           Chunk (bytecode + constants + spans) + Builder
│   ├── compiler.zig        AST → Chunk compiler
│   ├── scope.zig           Compile-time lexical scope chain + TDZ tracking
│   ├── disasm.zig          Bytecode disassembler
│   ├── literals.zig        Literal-parsing helpers
│   └── arguments_scan.zig  Implicit-`arguments` reference scan
├── runtime.zig             Runtime barrel module
├── runtime/
│   ├── value.zig           NaN-boxed Value, predicates, coercions
│   ├── heap.zig            Mark-sweep heap, allocation entry points
│   ├── realm.zig           Realm: heap + globals + intrinsics + buffered output
│   ├── string.zig          JSString heap object
│   ├── symbol.zig          JSSymbol primitive (heap-side)
│   ├── bigint.zig          JSBigInt primitive (heap-side)
│   ├── function.zig        JSFunction + native-callback shape + property table
│   ├── object.zig          JSObject (plain hashtable, prototype slot)
│   ├── generator.zig       JSGenerator (function* / async function frame state)
│   ├── module.zig          ModuleRecord
│   ├── environment.zig     Heap-allocated declarative environment record
│   ├── class.zig           §15.7.14 OrdinaryClassDefinition host helper
│   ├── interpreter.zig     Switch-dispatch interpreter loop, reentrant call API
│   ├── interpreter_arith.zig  Arithmetic + coercion helpers
│   ├── interpreter_test.zig   End-to-end interpreter tests
│   ├── intrinsics.zig      Cross-builtin orchestrator + shared helpers
│   └── builtins/           JS-visible per-builtin install + prototypes:
│       ├── object.zig          Object statics + Object.prototype + descriptors
│       ├── array.zig           Array.prototype + Array statics
│       ├── string.zig          String.prototype methods
│       ├── number.zig          Number prototype + statics + parseInt / parseFloat
│       ├── uri.zig             encodeURI{,Component} / decodeURI{,Component}
│       ├── math.zig            Math object
│       ├── json.zig            JSON.{stringify, parse}
│       ├── error.zig           Error / TypeError / RangeError / URIError installers
│       ├── function.zig        Function.prototype.{call, apply, bind} + variants
│       ├── collections.zig     Map / Set / WeakMap / WeakSet + iterator factories
│       ├── promise.zig         Promise constructor + statics + .then chaining
│       ├── reflect.zig         Reflect static methods
│       ├── symbol.zig          Symbol constructor + well-known symbols
│       ├── bigint.zig          BigInt constructor + statics
│       ├── proxy.zig           Proxy with trap dispatch + callable wrappers
│       ├── regexp.zig          RegExp via libregexp bridge
│       ├── iterator.zig        Iterator global + helper prototype
│       ├── date.zig            Date constructor + prototype + statics
│       └── typed_array.zig     ArrayBuffer + DataView + TypedArray family
└── cli/
    ├── eval.zig            `cynic eval <expr>` subcommand
    └── run.zig             `cynic run <file>` subcommand
tools/
├── gen_unicode_idents.zig  Generator for src/unicode/ident_tables.zig
├── test262.zig             test262 conformance harness (parser + runtime modes)
└── test262/
    ├── frontmatter.zig     YAML-subset frontmatter parser
    ├── harness.zig         sta.js + assert.js preload
    └── skip.zig            Unsupported features + path skip lists
vendor/
├── quickjs/                Vendored QuickJS-NG (MIT) — libregexp engine
├── unicode/                UCD source (Unicode 17.0.0; tracks latest)
└── test262/                git submodule, tc39/test262
docs/
├── ARCHITECTURE.md         Architecture overview
├── ROADMAP.md              Thematic roadmap
└── handbook/               Engineering handbook (TDD, prior-art,
                            compiler-engineering, Zig idioms)
AGENTS.md                   Entry point for any contributor
CLAUDE.md                   One-line @AGENTS.md import for Claude Code
```

## License

Cynic is [MIT-licensed](LICENSE). Bundled third-party code under
`vendor/` keeps its own license:

- `vendor/quickjs/` — QuickJS-NG (`libregexp` + `libunicode`), MIT,
  © 2017–2018 Fabrice Bellard, © 2023+ QuickJS-NG contributors.
  Upstream: <https://github.com/quickjs-ng/quickjs>.
- `vendor/unicode/` — Unicode Character Database
  (`DerivedCoreProperties.txt`), under the Unicode, Inc. License
  Agreement. Upstream: <https://www.unicode.org/license.txt>.
- `vendor/test262/` — ECMAScript Test Suite, BSD-3-Clause (with
  Ecma International notices). git submodule pinned to
  `tc39/test262`. Upstream: <https://github.com/tc39/test262>.
