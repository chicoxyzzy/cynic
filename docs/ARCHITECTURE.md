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

This narrows the surface and sharpens the spec-conformance target.

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
`allocateX` increments `allocs_since_gc`; the dispatch loop checks
the counter against `gc_threshold` (default 16,384) between opcodes
and runs `Realm.collectGarbage` when it crosses. Roots include the
realm's globals, intrinsics, microtask queue, modules, top-level
chunks, the active frames' registers + accumulator + this + env +
home_object, and any open handle scopes.

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
function-name self-binding) lives in a heap-allocated declarative
`Environment`; closures capture the enclosing env pointer. See
[src/runtime/environment.zig](../src/runtime/environment.zig).

This is heavier than a register-only design at later/later scale, but
the alternative — register slots for non-captured bindings, env slots
for captured ones, with a compile-time escape-analysis pre-pass —
was deferred when the simpler "everything on the heap" design proved
correct and fast enough for the later milestone work to flow. The
escape-analysis pre-pass is a later optimization.

## Built-in layout

Cynic ships a sizable spec surface (Object, Array, String, Number,
Map, Set, Promise, TypedArray, Date, …). Each lives in its own
file under `src/runtime/builtins/`, exporting a `pub fn install(realm)`
that wires the constructor + prototype methods + statics. The
top-level `intrinsics.install(realm)` calls each in turn:

```
runtime/intrinsics.zig          orchestrator + shared helpers
└── runtime/builtins/
    ├── object.zig               Object statics + Object.prototype
    ├── array.zig                Array.prototype + Array statics
    ├── string.zig               String.prototype methods
    ├── number.zig               Number + parseInt / parseFloat globals
    ├── uri.zig                  encodeURI / decodeURI family
    ├── math.zig                 Math object
    ├── json.zig                 JSON.{stringify, parse}
    ├── error.zig                Error class hierarchy
    ├── function.zig             Function.prototype + variant ctors
    ├── collections.zig          Map / Set / WeakMap / WeakSet
    ├── promise.zig              Promise + then-chaining + statics
    ├── reflect.zig              Reflect static methods
    ├── symbol.zig               Symbol constructor + well-known
    ├── bigint.zig               BigInt constructor + statics
    ├── proxy.zig                Proxy stub
    ├── regexp.zig               RegExp stub (no engine)
    ├── date.zig                 Date
    └── typed_array.zig          ArrayBuffer / DataView / TypedArray
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

`Realm` ([src/runtime/realm.zig](../src/runtime/realm.zig)) owns the
heap and a `globals` map. Host bindings (`print`, `console`, etc.)
are installed via `installBuiltins` and looked up by the `LdaGlobal`
opcode when an identifier reference doesn't resolve in any user
scope. Multiple realms are also the foundation for the SES /
Compartments direction; later ships a single realm and the API is
shaped so adding more later is a structural addition, not a
refactor.

`print` and friends are wired as `JSFunction` instances with a
`native_callback: ?NativeFn` field (a Zig function pointer). The
interpreter's `Call` op fast-paths native callees: it forms an args
slice over the register window and invokes the Zig function directly.

`Realm.output: ArrayListUnmanaged(u8)` buffers `print` / `console.log`
output. The host (CLI or test runner) flushes it after a script
finishes. Buffering avoids threading `std.Io` into the runtime, which
would touch every allocation site.

## Module system

Cynic targets `Source Text Module Record` per §16. `import` / `export` are
first-class; we don't ship CommonJS interop.

## Testing

- Inline `test` blocks per file for unit coverage (`zig build test`).
- Custom test262 harness (a Zig program in `tools/test262.zig`) once the
  parser exists. Filter to `flags: [onlyStrict, module]` plus tests with no
  `flags` field that don't rely on Annex B / sloppy mode.
- Differential testing against V8's `d8` is on the table for behavioural
  regressions where the spec is ambiguous.
