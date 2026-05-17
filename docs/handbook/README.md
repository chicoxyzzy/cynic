# Cynic engineering handbook

Project rules and reference material for anyone working on Cynic
(human or AI agent). Linked from [`AGENTS.md`](../../AGENTS.md).

| Document | What it covers |
|---|---|
| [tdd.md](tdd.md) | Tests-first discipline. The order is: write the failing test, run, implement, re-run. |
| [prior-art.md](prior-art.md) | Survey V8 / JavaScriptCore / SpiderMonkey / Hermes / QuickJS / XS / Boa, the ECMA-262 spec, test262, and SES / Compartments before non-trivial design decisions. |
| [compiler-engineering.md](compiler-engineering.md) | Design vocabulary and technique pointers — cover grammars, Pratt parsing, value representation, IR shapes, JIT tiers, GC strategies. References papers and engine blog posts. |
| [gc.md](gc.md) | What ships today: stop-the-world mark-sweep, count + byte allocation-pressure triggers, root set, the `HandleScope` contract for natives that re-enter JS, and the sweep-level memory-profiling counters surfaced by the test262 harness. Read before touching any heap-allocating built-in. |
| [environments.md](environments.md) | What ships today for §9.1 environment records — DeclarativeEnvironmentRecord / FunctionEnvironmentRecord / ModuleEnvironmentRecord / the split GlobalEnvironmentRecord (object env vs declarative env vs `[[VarNames]]`), opcode dispatch for top-level writes (`sta_global_init` / `sta_global_fn_decl` / `sta_global`), named-function-expression self-binding shape, and the §16.1.7 GlobalDeclarationInstantiation early-error pass. Read before touching binding declaration or resolution. |
| [agent-checks.md](agent-checks.md) | Regression-check protocol for shared-machinery changes — the `--only-failing` trap, per-touch bucket filters, the parallel-vs-`--threads=1` disambiguation, and the harness threading invariant (`threadlocal` requirement on per-fixture state). Read before declaring "no regressions." |
| [zig.md](zig.md) | Zig 0.17 idioms Cynic uses, with the gotchas that surface during contribution. |
