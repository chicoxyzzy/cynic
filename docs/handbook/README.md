# Cynic engineering handbook

Project rules and reference material for anyone working on Cynic
(human or AI agent). Linked from [`AGENTS.md`](../../AGENTS.md).

The normal change sequence is:

1. Read the current subsystem document from the
   [documentation index](../README.md).
2. Write the failing focused test first.
3. Survey the specification, test262, production engines, and relevant
   literature before making a non-trivial design choice.
4. Implement with the host-safety and GC-rooting contracts in view.
5. Run focused checks, then the broader bucket required by the touched
   machinery.

| Document | What it covers |
|---|---|
| [tdd.md](tdd.md) | Tests-first discipline. The order is: write the failing test, run, implement, re-run. |
| [prior-art.md](prior-art.md) | Survey V8 / JavaScriptCore / SpiderMonkey / Hermes / QuickJS / XS / Boa, the ECMA-262 spec, test262, and SES / Compartments before non-trivial design decisions. |
| [compiler-engineering.md](compiler-engineering.md) | Design vocabulary and technique pointers — cover grammars, Pratt parsing, value representation, IR shapes, JIT tiers, GC strategies. References papers and engine blog posts. |
| [host-safety.md](host-safety.md) | Never-abort-the-host contract, checked numeric conversion, recursion bounds, and the per-builtin review checklist. Read before touching code reached by untrusted JS. |
| [gc.md](gc.md) | What ships today: non-moving generational mark-sweep, card marking, incremental major marking, lazy sweep, allocation-pressure triggers, roots, and the `HandleScope` contract for natives that re-enter JS. Read before touching any heap-allocating built-in. |
| [environments.md](environments.md) | What ships today for §9.1 environment records — DeclarativeEnvironmentRecord / FunctionEnvironmentRecord / ModuleEnvironmentRecord / the split GlobalEnvironmentRecord (object env vs declarative env vs `[[VarNames]]`), opcode dispatch for top-level writes (`sta_global_init` / `sta_global_fn_decl` / `sta_global`), named-function-expression self-binding shape, and the §16.1.7 GlobalDeclarationInstantiation early-error pass. Read before touching binding declaration or resolution. |
| [agent-checks.md](agent-checks.md) | Regression-check protocol for shared-machinery changes — the `--only-failing` trap, per-touch bucket filters, the parallel-vs-`--threads=1` disambiguation, and the harness threading invariant (`threadlocal` requirement on per-fixture state). Read before declaring "no regressions." |
| [zig.md](zig.md) | Zig 0.17 idioms Cynic uses, with the gotchas that surface during contribution. |

`AGENTS.md` remains authoritative for project policy and commands. These pages
explain how to apply that policy; they should link to subsystem design records
instead of copying their delivery histories.
