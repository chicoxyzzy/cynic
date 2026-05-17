# Cynic — Architecture

Long-running design sketch. Treat anything labelled "TBD" as an open question
that will be settled with an ADR when the time comes.

## Pipeline

```
source bytes  ──►  Lexer  ──►  Parser  ──►  AST
                                            │
                                            ▼
                                   Bytecode Compiler
                                            │
                                            ▼
                                   Interpreter (T0)
                                            │
                            hot ─►  Baseline JIT (T1)        ── future
                                            │
                          hotter ─►  Optimizing JIT (T2)     ── future
```

Each tier is a separate compilation strategy producing code that runs over the
same value representation and the same heap. All upper tiers can deopt back
into the interpreter; data flows one way (T0 → T1 → T2) but execution can fall
all the way back.

## Strict-only

Cynic does not implement sloppy mode. Every script and module is parsed as
strict. Practical consequences:

- `let`, `static`, `interface`, `package`, `private`, `protected`, `public`,
  `implements`, `yield` are always reserved.
- `eval` and `arguments` cannot be assignment targets.
- `with` is a SyntaxError.
- No legacy octal integer literals (`0755`).
- No legacy octal escape sequences in strings (`"\17"`).
- No HTML-like comments (`<!--`, `-->`).
- `delete` of a bare identifier is a SyntaxError.
- Functions don't expose `arguments.callee` / `arguments.caller`.
- Annex B §B.3 grammar additions are not implemented.

One acknowledged Annex B exception: regex grammar §B.1.4 (`\1`
outside a capturing group as octal, the lower-bound-elided
quantifier `{,n}`). The vendored libregexp accepts these forms
without `/u` or `/v`; every shipping engine does the same, so
Cynic lives with the leak. See AGENTS.md for the rationale.

This narrows the surface and sharpens the spec-conformance
target — Cynic is at ~89 % spec / ~96 % attempted on the
runtime-mode test262 sweep (see `test262-results.md`).

## Spec-faithful naming

Internal functions track ECMA-262 abstract operation names where practical:
`ParseScript`, `Evaluate`, `ToNumber`, `OrdinaryGet`, etc. The mapping from a
test262 failure to the abstract operation responsible should be easy to find.

## Single allocator threading

Every component takes a `std.mem.Allocator`. There are no globals. Long-lived
state (heap, parser arena, JIT code arena) is owned by an `Engine` struct that
the embedder constructs explicitly. This makes lifetimes explicit and makes
arena-per-compilation cheap.

## Diagnostics, not panics

Lexer and parser collect `Diagnostic` records (severity + code + span) instead
of aborting on the first error. Tests assert on exact diagnostic codes, which
makes test262's expected-error tests precise to wire up.

## Value representation

**NaN-boxing**, JSC encoding. Decided at later; see
[src/runtime/value.zig](../src/runtime/value.zig).

A `Value` is a 64-bit word. Doubles (the spec's default numeric type
per §6.1.6.1) are stored unboxed inline — every IEEE-754 finite double
is a valid encoding. Non-double values use the NaN payload: a 16-bit
tag in the high bits (`Int32`, `String`, `Object`, `Bool`, `Null`,
`Undefined`, `Hole`) plus the heap-pointer or immediate in the low 48
bits.

Cynic uses one `Object` tag for both `JSFunction` and `JSObject`.
Discrimination happens at bit 0 of the stored pointer: heap allocations
are 8-byte-aligned, so bit 0 is free. `taggedFunction` leaves it
clear; `taggedObject` sets it. This avoids depending on Zig field
layout (Zig 0.14+ reorders fields by default), which previously broke
a kind-discriminator-as-first-field design.

`Hole` (tag `0xFFFF`) is a distinct sentinel for `let` / `const`
slots in TDZ; reading it raises `ReferenceError`.

The pointer-tagged-Smi alternative (V8 style) was considered and
rejected: it exists to interop with V8's pointer compression, which is
unrelated to a from-scratch interpreter.

## Garbage collection

Stop-the-world mark-sweep over per-type free lists, triggered on
allocation pressure. See [src/runtime/heap.zig](../src/runtime/heap.zig)
for the collector itself; the trigger and the realm-wide root walker
live in [src/runtime/realm.zig](../src/runtime/realm.zig) and the
interpreter dispatch loop in
[src/runtime/interpreter.zig](../src/runtime/interpreter.zig). The
operational details — root set, threshold, the `HandleScope` contract
for natives — are in [docs/handbook/gc.md](handbook/gc.md).

`Heap` tracks `JSString`, `JSFunction`, `JSObject`, `Environment`,
`JSGenerator`, `JSSymbol`, and `JSBigInt` on separate lists. Each
`allocateX` increments `allocs_since_gc`; large heap-owned payloads
(string bytes, ArrayBuffer slabs) additionally `charge(n)` the byte
counterpart `bytes_since_gc`. The dispatch loop checks **either**
counter — count against `gc_threshold` (default 16,384) or charged
bytes against `gc_byte_threshold` (default 16 MiB) — between opcodes
and runs `Realm.collectGarbage` when one crosses. Roots include the
realm's globals, intrinsics, microtask queue, modules, top-level
chunks, the active frames' registers + accumulator + this + env +
home_object, and any open handle scopes.

The heap also exposes always-on counters (`bytes_alloc_total`,
`bytes_live_peak`, `gc_cycles_total`, `gc_time_ns_total`) that the
test262 harness surfaces via `--mem-summary`, `--top-alloc=<N>`, and
the existing `--gc-stats` line.

Reference counting (QuickJS) was rejected: it leaks cycles and bloats
the runtime API. Generational moving GC (Lieberman / Hewitt 1983,
Ungar 1984) is the path forward later. Concurrent collection is M5+.

## Bytecode

Register file + accumulator, Ignition / Hermes style. Decided at
later; see [src/bytecode/op.zig](../src/bytecode/op.zig).

Per-frame register file; an implicit accumulator threads through
binary and unary ops to keep the dispatch loop tight. One-byte
opcodes for the common case. Bytecode is the source of truth for IR
— JIT tiers (M5, M6) will consume bytecode + profile data, not the
AST.

A pure-stack design (QuickJS) was considered and rejected: higher
dispatch counts, and worse fit for the M5 baseline JIT, which wants
a register file (Sparkplug, JSC Baseline both work that way).

## Object model

Plain hashtable-backed properties at later, with a prototype-pointer
slot reserved for later. See
[src/runtime/object.zig](../src/runtime/object.zig).

Shapes / hidden classes are mandatory long-term — without them every
property access is a hashtable lookup, and every M5 inline-cache site
must be retrofitted. The intended design (Self / V8 lineage,
Chambers & Ungar) is `Shape = (parent_shape, key, attrs, slot_index)`
transition nodes with a per-parent transition cache and a
dictionary-mode fallback after a transition threshold. Landing this
is later.

## Environment records

Every named binding (`var` / `let` / `const`, function params,
function-name self-binding, imports) lives in a heap-allocated
declarative `Environment`; closures capture the enclosing env
pointer. See
[src/runtime/environment.zig](../src/runtime/environment.zig).

Four record shapes ship today, distinguishing flags on the
binding rather than separate types:

- **DeclarativeEnvironmentRecord** — the default. Block scopes,
  function bodies, catch params.
- **FunctionEnvironmentRecord** — same `Environment` struct;
  args, `this`, and `[[HomeObject]]` are plumbed through
  `JSFunction` instead of the env itself.
- **ModuleEnvironmentRecord** — same `Environment`; imports
  carry `is_import = true` and read indirectly through the
  source module's namespace (TDZ-Hole-seeded at instantiation
  per §15.2.1.16.4). Writes throw TypeError.
- **GlobalEnvironmentRecord** — split into the object env
  (the realm's global object, holds `var` / `function` decls
  and host bindings) plus a declarative env (`let` / `const` /
  `class`, NOT mirrored on `globalThis`) plus a `[[VarNames]]`
  set per §9.1.1.4. Top-level writes lower to one of three
  opcodes (`sta_global_init`, `sta_global_fn_decl`,
  `sta_global`) that route through the correct sub-record.

Named function expressions (`let r = function G() {...}`) get
a synthetic one-binding wrapper env between the function body
and the captured outer env, holding `G` as immutable per
§15.6.5.

The "register slots for non-captured bindings, env slots for
captured ones, plus escape-analysis pre-pass" alternative was
deferred when "everything on the heap" proved correct and fast
enough; the escape-analysis pass is a later optimization.

See [docs/handbook/environments.md](handbook/environments.md)
for the per-opcode dispatch table, the §16.1.7 early-error
pass, the const InitializeBinding / SetMutableBinding
distinction via the TDZ-Hole sentinel, and the
named-fn-expr-wrapper-env construction. Read it before touching
binding declaration or resolution.

## Built-in layout

Cynic ships a sizable spec surface (Object, Array, String, Number,
Map, Set, Promise, TypedArray, Date, …). Each lives in its own
file under `src/runtime/builtins/`, exporting a `pub fn install(realm)`
that wires the constructor + prototype methods + statics. The
top-level `intrinsics.install(realm)` calls each in turn:

```
runtime/intrinsics.zig          orchestrator + shared helpers
└── runtime/builtins/
    ├── array.zig                Array.prototype + Array statics
    ├── async_iterator.zig       %AsyncFromSyncIteratorPrototype% etc.
    ├── bigint.zig               BigInt constructor + statics
    ├── collections.zig          Map / Set / WeakMap / WeakSet
    ├── date.zig                 Date
    ├── error.zig                Error class hierarchy
    ├── finalization_registry.zig FinalizationRegistry
    ├── function.zig             Function.prototype
    ├── iterator.zig             Iterator helpers (Stage 4 + drafts)
    ├── json.zig                 JSON.{stringify, parse}
    ├── math.zig                 Math object
    ├── number.zig               Number + parseInt / parseFloat globals
    ├── object.zig               Object statics + Object.prototype
    ├── promise.zig              Promise + then-chaining + statics
    ├── proxy.zig                Proxy
    ├── reflect.zig              Reflect static methods
    ├── regexp.zig               RegExp (vendored libregexp + spec
    │                             surface — see AGENTS.md "Regex")
    ├── string.zig               String.prototype methods
    ├── symbol.zig               Symbol constructor + well-known
    ├── typed_array.zig          ArrayBuffer / DataView / TypedArray
    ├── uri.zig                  encodeURI / decodeURI family
    └── weak_ref.zig             WeakRef
```

**Layer split.** The `src/runtime/<X>.zig` file holds the heap-side
`JSX` struct (fields, init / deinit, internal slot access). The
`src/runtime/builtins/<X>.zig` file holds the JS-visible API surface
(constructor body, prototype methods, install function). Five
names overlap (`bigint`, `function`, `object`, `string`, `symbol`):

| File | Responsibility |
|---|---|
| `runtime/<X>.zig` | Engine-internal data structure |
| `runtime/builtins/<X>.zig` | User-callable JS API |

`builtins/X.zig` imports `runtime/X.zig` for the `JSX` type; the
heap-side struct knows nothing about the JS API. `intrinsics.zig`
exposes shared helpers (`installConstructor`, `coerceToNumber`,
`toPrimitive`, `getPropertyChain`, `throwTypeError`, …) that every
builtin reaches for via a single import alias at the top of the
file.

## Realm and host bindings

`Realm` ([src/runtime/realm.zig](../src/runtime/realm.zig)) owns
the heap, the intrinsics table, the microtask queue, the module
cache, and a `GlobalBindings` struct (the
GlobalEnvironmentRecord — see Environment records above for the
object / declarative / `[[VarNames]]` split). Host bindings
(`print`, `console`, etc.) are installed on the global object
via per-builtin `install(realm)` calls and looked up by the
`lda_global` opcode when an identifier reference doesn't
resolve in any user scope. Multiple realms are also the
foundation for the SES / Compartments direction; today ships a
single realm and the API is shaped so adding more later is a
structural addition, not a refactor.

`print` and friends are wired as `JSFunction` instances with a
`native_callback: ?NativeFn` field (a Zig function pointer). The
interpreter's `Call` op fast-paths native callees: it forms an args
slice over the register window and invokes the Zig function directly.

`Realm.output: ArrayListUnmanaged(u8)` buffers `print` / `console.log`
output. The host (CLI or test runner) flushes it after a script
finishes. Buffering avoids threading `std.Io` into the runtime, which
would touch every allocation site.

## Module system

Cynic targets Source Text Module Record per §16. `import` /
`export` are first-class; CommonJS interop isn't shipped.

What's wired today:

- Static `import` / `export` (including re-exports, `export *
  from`, and StringLiteral as ModuleExportName per §16.2.3.5
  — `export * as "ns" from "src"`, `import { "y" as local }`).
- Indirect imports as live aliases per §8.1.1.5.5
  CreateImportBinding — reads dereference through the source
  module's namespace; writes throw TypeError.
- TDZ for indirect imports: the source module's exported
  `let` / `const` / `class` / `export default` slots are
  Hole-seeded at instantiation so the importer sees a
  ReferenceError before the source body has initialised them
  (§15.2.1.16.4 step 12). `export const { x } = obj`
  destructuring patterns are walked to every binding leaf,
  matching what `let` / `const` declarators publish.
- Module Namespace exotic ([[Get]] §9.4.6.7) routes through
  `GetBindingValue` with `strict = true`, surfacing the TDZ
  Hole as ReferenceError. `[[HasProperty]]` and
  `[[OwnPropertyKeys]]` do NOT — only `[[Get]]` honors TDZ.
  `IsExtensible` / `SetPrototypeOf` are brand-aware per
  §9.4.6.{1,3}, refusing extension and prototype change with
  the spec-mandated `false`. `@@toStringTag = "Module"` is
  installed at brand-on-allocation time so cycles see the
  right tag while the namespace is still mid-evaluation.
- Top-level `await` (§16.2.1.5.1). Module bodies with TLA
  compile with `chunk.is_async_module = true`; the runtime
  routes them through `startAsyncCall` to produce an
  evaluation Promise. Async deps suspended at TLA land on
  `ModuleRecord.pending_async_deps`; the compiler emits a
  `module_link_complete` opcode after the importer's hoisted
  import block to drain microtasks (and propagate any dep
  rejection as an abrupt completion at the link boundary).
  Cynic doesn't yet model the full §16.2.1.5
  [[PendingAsyncDependencies]] count or
  [[AsyncEvaluationOrder]] sort — sufficient for every TLA
  fixture in today's corpus.
- Dynamic `import()` per §13.3.10 — returns a Promise that
  rejects with `SyntaxError` on instantiation failure
  (ambiguous indirect-export, circular re-export, etc.). For
  async deps the import() Promise drains microtasks until the
  dep's evaluation Promise settles, so callers see the post-
  TLA namespace rather than a partial mid-await view.
- `import.meta`.

Module loading is host-driven via `Realm.module_loader` — a
callback the embedder installs (the CLI resolves siblings on
disk; the test262 harness reads from `vendor/test262/test/`).

## Testing

- Inline `test` blocks per file for unit coverage
  (`zig build test`).
- Custom test262 harness (`tools/test262.zig`, ~3 k lines)
  scored against the Cynic-targeted scope: Annex B,
  `intl402/`, `staging/`, `harness/`, and the browser-era
  built-ins Cynic doesn't ship are dropped from `total`
  entirely. The harness runs in `runtime` (parse + compile +
  execute) and `parser` (parse-only) modes, supports
  `--filter` + `--only-failing` for fast iteration, and ships
  diagnostics flags (`--top-rss`, `--top-slow`, `--top-alloc`,
  `--mem-summary`, `--leak-check`, `--max-rss`) for the kind
  of leak / perf bisecting that comes up in shared-machinery
  work. Per-day score rows + bucket scoreboard live in
  `test262-results.md`. AGENTS.md "Build & test" covers the
  iteration cadence and the leak-check policy for new
  allocation paths;
  [docs/handbook/agent-checks.md](handbook/agent-checks.md)
  covers the regression-check protocol for changes that
  touch shared compiler / runtime machinery.
- Differential testing against V8's `d8` is still on the
  table for behavioural regressions where the spec is
  ambiguous (mostly handled today by direct reference to the
  spec text via the `tc39` MCP server in `.mcp.json`).
