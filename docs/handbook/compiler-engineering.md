# Compiler engineering — design vocabulary

Pointers to techniques and tradeoffs you'll meet building Cynic.
Not a textbook — a checklist with citations. Use it as a "have I
considered this?" pass before committing to a design.

## Lexer ↔ parser boundary

Cynic's lexer scans `InputElementDiv` by default and exposes
`rescanAsRegex(slash_start)` so the parser can re-enter scanning
when it sees `/` in expression-start position (§12.9.5). Template
continuations work the same way: the parser hands `}` back to
`Lexer.nextTemplateContinuationAfterBrace` to resume template
scanning.

The general lesson: the lexer is *parser-driven* for any
production where the same source byte can mean different tokens
in different syntactic contexts. Don't try to disambiguate in the
lexer alone — V8, JSC, and SpiderMonkey all carry a parser→lexer
mode hint for the same reason.

## Cover grammars

ECMAScript's grammar overlaps in two places where the same prefix
admits two productions:

- `CoverParenthesizedExpressionAndArrowParameterList` — `(x, y)`
  is either a parenthesised comma-expression or arrow parameters,
  decided when the parser sees `=>` (or doesn't).
- `CoverCallExpressionAndAsyncArrowHead` — `async(x)` is either a
  call to `async` or the head of an async arrow.

Cynic resolves these *post hoc*: parse the prefix as the
expression form, then reinterpret if the disambiguating token
appears. `expressionAsBindingTarget` is the workhorse. V8 and JSC
do the same. Don't try to predict; commit and reshape.

## Pratt-style precedence climbing

Cynic uses a single-function precedence climber for binary
operators (`parseBinary(min_prec)`), keyed by token kind.
Variants worth knowing:

- One function per precedence level (recursive descent) — clearer
  but more code; what most LR-style generators emit.
- Operator-precedence tables driving a generic loop — what we use.
- Pratt parsing with prefix / infix / postfix dispatch — slightly
  more general; useful when the same token has multiple roles
  (e.g. unary `-` vs binary `-`).

## Diagnostic recovery

Two strategies, often combined:

- **Synchronize on statement boundaries.** On parse error, skip
  tokens until the next `;`, `}`, or known statement-starter
  keyword. Cynic uses this. Quality is good when the grammar has
  clear sync points; poor inside expressions.
- **Phrase-level recovery** (panic-mode with FIRST/FOLLOW sets) —
  more sophisticated, much more code. Most production engines
  don't bother.

The harness reads `diagnostic.severity == .err` to detect failure
even when parsing returned a partial AST. Recovery exists so we
can score multiple errors per file in test262, not just the
first.

## AST design

Cynic uses tagged unions (Zig `union(enum)`) with arena
allocation. Pointers for self-referential cases (e.g. the
`BindingTarget ↔ ArrayPattern.rest` cycle resolved via
`*BindingTarget`). Alternatives:

- **Class hierarchy with virtual dispatch** — what V8 and JSC do
  in C++. Worse cache behavior, harder to add operations
  (visitor required).
- **Sealed sum types** — what we use; what Boa uses.
- **Pure structural** (every node is `Map<String, Any>`) —
  flexible, slow, error-prone.

The S-expression printer (`ast.printer.dump`) is the stable
serialization used in golden tests. Spans on every node make
errors point at source text.

## Early errors vs runtime errors

ECMA-262 distinguishes:

- **Early errors** (§16.1.1, §16.2.2, §15.x.x) — detected at
  parse time. Examples: duplicate parameter names in strict
  mode, `super` outside a method, `return` outside a function.
- **Runtime errors** — `ReferenceError`, `TypeError`, `RangeError`
  thrown during execution.

Parser-time context flags drive early errors: `in_async`,
`in_generator`, `is_module`, `allow_in`. These save / restore
across function and arrow boundaries; arrows inherit some of them
(`+Await` for body, `+NewTarget` if enclosed in a function) and
override others (`~Yield` always).

`Code.errorClass()` mechanically maps every diagnostic to its
JavaScript error class so test262 negative scoring matches the
spec's `negative.type`.

## Bytecode design

Cynic uses a register file plus an implicit accumulator, following
V8 Ignition and Hermes rather than QuickJS's stack machine. Binary
instructions read the left operand from a register and the right
operand from the accumulator. This keeps common instructions short
without making Bistromath reconstruct a virtual stack.

`src/bytecode/op.zig` is the single instruction schema. Every opcode
declares its mnemonic, operand layout, control-flow class, and
Bistromath strategy in `Op.spec()`. The disassembler, liveness pass,
statistics collector, branch decoder, Lantern, and Bistromath derive
their stream walk from that schema. Do not add a parallel operand-size
or opcode-classification table.

The wire format is compact but scalable:

- Common opcodes and registers are one byte; low registers and common
  constants have operand-free forms.
- Constants, IC indices, and call operands use narrow variants where
  their values fit. Separate load/store/computed IC tables give each
  family an independent small index space.
- Relative branches are emitted as logical patches and relaxed to
  signed i8, i16, or i32 at finalization. Re-emission remaps source
  positions, exception handlers, and dense-switch targets.
- Dense int32 `switch` statements use a side-table-backed `switch_smi`
  dispatch. Sparse or effectful cases preserve the ordered comparison
  chain required by §14.12.

`-Dbytecode-stats=true` compiles instrumentation; `cynic run
--bytecode-stats file.js` then reports nested-chunk instruction/byte
counts, operand-width fit, and dynamic opcode/pair/trigram frequencies.
The flag is compile-time so normal binaries contain no counter access.
Use those traces plus paired wall-time measurements before retaining a
new super-instruction. A 2026-07 loose-equality branch fusion removed
4.34% of Richards dispatches but made paired non-JIT wall time 3.8%
slower, so it was reverted.

The finalized-bytecode liveness pass builds a CFG, including every
`switch_smi` successor, and fails closed on unknown register effects.
It supports dead-store re-emission and accumulator forwarding for an
adjacent `Star r; Ldar r` only when the load is not a branch, switch,
or handler entry. This rewrite must run after branch finalization:
emission-time patch state does not yet know every incoming edge.
Explicit register reads come from the opcode schema; instructions with
implicit argument windows still require an explicit effect declaration.

Reference reading: V8 Ignition's accumulator/register bytecodes and
operand scaling, the Hermes bytecode reference, QuickJS's compact
stack bytecode and switch tables, and JavaScriptCore's generated
bytecode metadata plus `CodeBlock` side state.

## Value representation

The two dominant strategies:

- **NaN-boxing** — store all values as 64-bit, with non-numbers
  encoded as NaN bit patterns. JSC, SpiderMonkey, Hermes use this
  on 64-bit. Doubles are unboxed.
- **Pointer-tagged Smis** — 31- or 32-bit immediate integers in
  the bottom-tag region of a pointer. V8 uses this; doubles boxed
  on the heap (or compressed via pointer compression).

The choice interacts with everything else: GC barriers, IC
shape, JIT codegen. Make this decision *before* writing the
runtime — it's hard to retrofit. Pizlo, "Speculation in
JavaScriptCore" (2020) is the most accessible exposition.

## Object model

Cynic will need shapes / hidden classes (Self / V8 lineage):
property keys map to fixed offsets within a shape; property
addition transitions to a new shape; ICs cache the shape and
offset. Without shapes, every property access is a hashtable
lookup — orders of magnitude slower.

Reference reading: Chambers & Ungar (Self), Hölzle Chambers
Ungar (1991, polymorphic inline caches), V8 blog "Fast properties
in V8".

## GC strategies

Roughly in order of complexity:

1. **Bump-allocator + mark-sweep** — what to start with. Simple,
   correct, slow for long-running programs. **What Cynic ships
   today** — see [gc.md](gc.md) for the trigger / root-set / native
   safety contract.
2. **Generational moving** — ~80% of allocations die young.
   Bump-allocate in a young space, copy survivors to an old
   space, only old-space gets the heavy collector. Lieberman /
   Hewitt (1983), Ungar (1984).
3. **Concurrent marking** — mark on a separate thread, with
   write barriers to track mutations. V8 Orinoco, JSC Riptide.
4. **Mark-region (Immix)** — survivors evacuated within blocks,
   no full copying collector needed. Hermes uses RegionTrees,
   a relative.

Barriers cost in JIT'd code: every GC change touches the JIT.

## JIT tiering

Don't add the next tier until measurement says it's worth it.
The tiers exist because each is better at a different point on
the speed / startup-cost / memory tradeoff:

- **Interpreter** — fastest startup, slowest steady-state.
- **Baseline JIT** (V8 Sparkplug, JSC Baseline) — cheap
  compilation directly from bytecode, no IR. Good for code that
  runs warm but not hot.
- **Optimizing JIT** (V8 TurboFan / Maglev, JSC DFG / FTL) — IR,
  inline-cache feedback, type speculation, deopt. Good for hot
  code; expensive to compile.

V8 *Sparkplug* (Sander, 2021) is the cheapest possible baseline:
one machine-code handler per bytecode, register-allocated by
hand. A good model for Cynic's eventual second tier.

## Inline caches and deoptimization

ICs cache the result of a runtime lookup (property offset, method
target) keyed on the operand's shape. Polymorphic chains handle
multiple shapes; megamorphic falls back to the slow path.

Optimizing JITs *speculate* on IC observations: "this site is
always monomorphic on shape X, generate code that assumes X and
deopt if not." Deopt sites need on-stack replacement (OSR) state
to reconstruct the interpreter frame. Hard to retrofit; design
the bytecode and IR with deopt points in mind from day one.

## IR design

For the optimizing tier:

- **CFG-of-blocks** with explicit phi nodes — classic SSA. Clear
  structure, more passes are textbook.
- **Sea of Nodes** — Click (1995). Used by TurboFan and DFG. No
  basic-block ordering until scheduling; effects encoded as
  edges. More compact, more abstract.

Reference reading: Click & Paleczny, "A Simple Graph-Based
Intermediate Representation" (1995); V8 TurboFan blog posts.

## Where Cynic stands

Lexer + parser + bytecode compiler + interpreter all shipped.
The interpreter runs the full §13/§14 grammar — classes,
generators, async, async generators (with spec-faithful
`yield*` delegation), modules (static + dynamic `import()`),
proxies, every well-known symbol — at ~89 % spec / ~96 %
attempted on the runtime-mode test262 sweep. See
[../ROADMAP.md](../ROADMAP.md) "Bytecode & runtime" for the
per-area shipped / planned breakdown; current live numbers in
[../../test262-results.md](../../test262-results.md).

The choices in this doc reflect what landed:

- **NaN-boxing**, JSC encoding (§"Value representation" above).
- **Register file + accumulator** bytecode, Ignition / Hermes
  shape (§"Bytecode design" above).
- **Declarative opcode schema + compact finalization** — narrow
  operands, i8/i16/i32 branch relaxation, dense-switch side tables,
  and liveness-driven re-emission share one decoding contract.
- **Typed inline-cache side tables** — load, store, and computed
  sites pay only for the state their fast path consumes; Bistromath
  reads the same load-cache layout as Lantern.
- **Stop-the-world mark-sweep** GC with count + byte allocation
  triggers; see [gc.md](gc.md) for ops detail.
- **Hashtable-backed properties** with a prototype slot — no
  shapes yet (the next major perf win, per
  [../ROADMAP.md](../ROADMAP.md) "Performance"). Inline caches
  are also pending shapes.
- **Bistromath** — the baseline JIT, on by default since the
  delivery-order step-3 exit (`--no-jit` opts out); design +
  delivery ledger in
  [../jit.md](../jit.md). Ohaimark, the optimizing tier, stays a
  named future tier.

Cite this file when arguing for changes to the underlying
shape — e.g. moving to shapes, switching to a stack VM,
adding a baseline JIT.
