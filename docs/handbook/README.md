# Cynic engineering handbook

Project rules and reference material for anyone working on Cynic
(human or AI agent). Linked from [`AGENTS.md`](../../AGENTS.md).

| Document | What it covers |
|---|---|
| [tdd.md](tdd.md) | Tests-first discipline. The order is: write the failing test, run, implement, re-run. |
| [prior-art.md](prior-art.md) | Survey V8 / JavaScriptCore / SpiderMonkey / Hermes / QuickJS / XS / Boa, the ECMA-262 spec, test262, and SES / Compartments before non-trivial design decisions. |
| [compiler-engineering.md](compiler-engineering.md) | Design vocabulary and technique pointers — cover grammars, Pratt parsing, value representation, IR shapes, JIT tiers, GC strategies. References papers and engine blog posts. |
| [zig.md](zig.md) | Zig 0.16 idioms Cynic uses, with the gotchas that surface during contribution. |
