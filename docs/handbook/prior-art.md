# Survey prior art before non-trivial design

Before writing or designing a Cynic feature — lexer rule, parser
production, AST shape, bytecode op, GC choice, JIT tier, runtime
intrinsic — pause and do a brief prior-art survey. Then decide
where Cynic should follow the herd, where it should diverge, and
why.

## Why

Cynic is a from-scratch ECMAScript engine. Almost every problem
we'll hit has been solved (often more than once) by V8,
JavaScriptCore, SpiderMonkey, Hermes, QuickJS, XS, Boa, and the
academic literature behind them. Reinventing without that context
wastes effort and produces code that's worse than the average.
Surveying also makes deliberate divergence — strict-only, no Annex
B, eventual SES alignment — *informed* rather than accidental.

## What to survey

For each non-trivial feature:

1. **Specification anchor.** Cite the ECMA-262 section
   ([tc39.es/ecma262](https://tc39.es/ecma262/)). Internal function
   names mirror spec abstract operations so test262 failures map
   cleanly. Already a project rule; this just keeps it visible.

2. **How the major engines do it.**
   - **V8** — Ignition (bytecode interpreter), Sparkplug
     (non-optimizing baseline JIT, machine-code from bytecode),
     Maglev (mid-tier non-speculative), TurboFan (top-tier
     optimizing). [v8/v8](https://github.com/v8/v8); design notes
     on the [V8 blog](https://v8.dev/blog).
   - **JavaScriptCore** — LLInt (low-level interpreter, written in
     offlineasm), Baseline JIT, DFG (SSA optimizer), FTL (top
     tier, uses the B3 backend).
     [WebKit/WebKit](https://github.com/WebKit/WebKit/tree/main/Source/JavaScriptCore);
     architecture summarised in WebKit blog posts.
   - **SpiderMonkey** — bytecode interpreter, Baseline Interpreter,
     Baseline Compiler, WarpMonkey/Warp (formerly IonMonkey).
     [mozilla-firefox/firefox/js/src](https://github.com/mozilla-firefox/firefox/tree/main/js/src);
     [SpiderMonkey docs](https://firefox-source-docs.mozilla.org/js/index.html).
   - **Hermes** — AOT-bytecode interpreter optimized for mobile
     cold-start. Interesting reference for value representation
     and compact bytecode.
     [facebook/hermes](https://github.com/facebook/hermes).
   - **QuickJS** — Bellard, single-tier, very compact, surprisingly
     fast. Good baseline for "the simplest correct thing".
     [bellard/quickjs](https://github.com/bellard/quickjs).
   - **XS** — Moddable, embedded / microcontroller focus, C; one
     of the strongest test262 scores per byte of binary. Notable
     for memory-efficient design under tight RAM budgets and for
     first-class **SES / Compartments** support — the canonical
     reference for how Compartments are actually implemented in
     production.
     [Moddable-OpenSource/moddable](https://github.com/Moddable-OpenSource/moddable);
     XS-specific docs under `documentation/xs/`.
   - **Boa** — Rust, also from-scratch and spec-driven; closest
     spiritual match for Cynic. Useful when Zig idioms aren't
     transferable.
     [boa-dev/boa](https://github.com/boa-dev/boa).

   Don't copy-paste — note what each does in a sentence each, so
   the design space is visible before we pick.

3. **Relevant academic / design literature.** The classics:
   - Self / V8 *shapes* (hidden classes) — Chambers / Ungar.
   - NaN-boxing vs pointer-tagged Smis — Pizlo, "Speculation in
     JavaScriptCore" (2020); V8 "Pointer compression" (2020).
   - Inline caches / polymorphic ICs — Hölzle, Chambers, Ungar
     (1991), "Optimizing Dynamically-Typed Object-Oriented
     Languages With Polymorphic Inline Caches".
   - Tracing vs method JITs — TraceMonkey, PyPy.
   - Sea of Nodes — Click (1995); used by TurboFan and DFG.
   - Mark-region collectors — Immix (Blackburn, McKinley 2008);
     RegionTrees in Hermes.
   - Generational moving GC — Lieberman / Hewitt (1983); Ungar
     (1984).
   - Concurrent marking — V8 *Orinoco*; JSC *Riptide*.
   - On-stack replacement, deoptimization — V8 / SpiderMonkey
     blog posts, Self papers, Bebenita et al.
   - Baseline JITs from bytecode — V8 *Sparkplug* design (2021,
     V8 blog); JSC Baseline.

   Cite the paper or post when its idea drives a Cynic decision —
   a one-line link in the relevant code comment or design doc is
   enough.

4. **test262 coverage.** Every spec feature has corresponding
   tests in [tc39/test262](https://github.com/tc39/test262).
   Before implementing, glance at `vendor/test262/test/<area>` to
   see the shape of conformance — what edge cases are tested,
   what early errors are pinned. After implementing, run
   `zig build test262` and confirm the relevant slice flips from
   false-reject to pass.

5. **SES / Hardened JavaScript / Compartments**, when relevant.
   [SES](https://github.com/endojs/endo/tree/main/packages/ses)
   freezes primordials and constructs realm-like Compartments for
   isolation; the [Compartments proposal (TC39 stage 1)](https://github.com/tc39/proposal-compartments)
   adds language-level support. Cynic's strict-only stance is
   already aligned (no `with`, no sloppy mode, no Annex B); when
   designing realm / global-object / module-loading machinery,
   keep an eye on whether the choice forecloses or enables a
   Compartment-friendly future. SES / lockdown also informs which
   built-ins must be tamper-proof and how `Function` / `eval`
   should be exposed. **XS is the canonical implementation
   reference** for Compartments in production.

## How to present a survey

Short — three to six lines is fine.

> **§\<spec>** — *spec anchor*
> **V8 / JSC / SM / Hermes / QuickJS / XS** — one sentence each, only the
> ones that meaningfully differ.
> **Lit:** paper or post if any drove the decision.
> **test262:** the area path to watch.
> **SES:** any tamper / isolation concern.
> **Cynic choice:** what we'll do, and why we diverge if we do.

Skip sections that don't apply. The point isn't ceremony; it's
making sure the decision was *informed*.

## When to survey

Always for: AST shape, bytecode design, value representation, GC
strategy, JIT tier, runtime intrinsic, parser early-error
handling that has multiple valid implementations.

Skip for: trivial bug fixes, span-number adjustments, test
additions, local refactors that don't change observable behavior.

If unsure — survey. The cost is low; the cost of a wrong design
discovered three milestones later is high.
