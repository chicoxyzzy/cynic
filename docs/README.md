# Cynic documentation

Use this page to find the authoritative document for a topic. The public
overview stays in the repository [README](../README.md); contributor policy and
the complete command reference stay in [AGENTS.md](../AGENTS.md).

## Sources of truth

| Question | Read |
|---|---|
| What is Cynic and how do I run it? | [README.md](../README.md) |
| What rules apply to a code change? | [AGENTS.md](../AGENTS.md) |
| How do the major components fit together? | [ARCHITECTURE.md](ARCHITECTURE.md) |
| What has shipped and what remains? | [ROADMAP.md](ROADMAP.md) |
| What engineering workflow should I follow? | [Engineering handbook](handbook/README.md) |
| What are the current conformance scores? | [ECMAScript](../test262-results.md) and [WebAssembly](../wasm-results.md) results |
| What are the current cross-engine measurements? | [bench-cross-results.md](../bench-cross-results.md) |

Documents use four roles:

- **Reference** describes current behavior or a current engineering contract.
- **Design record** preserves accepted decisions and their delivery history.
- **Research note** records a measured recommendation, including negative
  results. It is not an implementation requirement unless its status says so.
- **Ledger** is append-only evidence: scores, carve-outs, or upstream gaps.

For a long design record, read its opening status before the older phase text.
Future-tense implementation plans are often retained to explain why the shipped
shape exists.

## Engineering handbook

| Document | Role |
|---|---|
| [Tests first](handbook/tdd.md) | Required TDD sequence |
| [Prior art](handbook/prior-art.md) | Required survey protocol for non-trivial design |
| [Compiler engineering](handbook/compiler-engineering.md) | Parser, bytecode, VM, JIT, and GC vocabulary |
| [Host-abort safety](handbook/host-safety.md) | Safety contract for untrusted input |
| [Garbage collection](handbook/gc.md) | Current Metla design, roots, barriers, and `HandleScope` contract |
| [Environment records](handbook/environments.md) | Current binding and global-environment model |
| [Regression checks](handbook/agent-checks.md) | Required focused and full verification postures |
| [Zig idioms](handbook/zig.md) | Project-specific Zig 0.17 patterns |

## Runtime architecture

| Document | Role and scope |
|---|---|
| [SES alignment](ses-alignment.md) | Current hardened-default policy plus delivery record |
| [Multi-realm](multi-realm.md) | Shipped realm substrate; deferred Compartment design |
| [Realm snapshots](realm-snapshots.md) | Partial rollout: core fresh-realm capture/restore and remaining gates |
| [Resource metering](resource-metering.md) | Shipped fuel, memory, and interrupt API |
| [Inline caches](inline-caches.md) | Shipped shape/IC substrate and remaining IC work |
| [Lazy property bag](lazy-property-bag.md) | Shipped phases and deferred property-storage work |
| [SharedArrayBuffer and Atomics](sab-atomics.md) | Single-agent design and shipped surface |
| [Multi-agent Atomics](multi-agent-atomics.md) | Shipped threaded test262 host substrate and follow-ups |
| [Playground](playground.md) | Browser-Wasm build and deployment reference |

## Execution tiers

| Document | Role and scope |
|---|---|
| [JIT tiers](jit.md) | Shared Bistromath, Ohaimark, and Spasm architecture and rollout gates |
| [Ohaimark](ohaimark.md) | Optimizing-JIT accepted design, deoptimization contract, OSR, and delivery ledger |
| [Sarcasm WebAssembly engine](wasm-engine.md) | Wasm decoder, validator, interpreter, JS API, and Spasm boundary |

## Verification and operations

| Document | Role and scope |
|---|---|
| [Benchmarking](benchmarking.md) | Local and cross-engine measurement protocol |
| [Fuzzing](fuzzing.md) | Fuzzilli setup, triage, and continuous-fuzzing gate |
| [Differential fuzzing](fuzz-differential.md) | Native and external-oracle differential strategy |
| [Fuzz carve-outs](fuzz-carveouts.md) | Machine-consumed ledger of intentional divergences |
| [test262 gap audit](test262-gap-audit.md) | Classification of body-only, by-design failures |
| [test262 upstream gaps](test262-upstream-gaps.md) | Fixture proposals for bugs not covered upstream |
| [ECMA-262 upstream gaps](ecma262-upstream-gaps.md) | Specification clarification proposals |

## Research and decision records

These files preserve experiments so closed paths are not re-investigated
without new evidence.

| Document | Recorded outcome |
|---|---|
| [Incremental/concurrent marking](gc-concurrent-marking-research.md) | Incremental marking shipped; concurrent marker deferred |
| [Generational aging](gc-generational-aging.md) | Card marking shipped; aging did not justify the proposed path |
| [Generational major collection](gc-generational-major.md) | Closed for a non-moving collector |
| [Immix rearchitecture](gc-immix-rearchitecture.md) | Measurements did not support an Immix rewrite |
| [Reference counting](gc-reference-counting.md) | Prototype measured as a no-go |
| [Parallel GC](gc-parallel.md) | Design only; useful for large-heap trigger analysis |
| [Property-key interning](interned-keys.md) | Prototype measured as a no-go |
| [`ctor_array_build` gap](ctor-array-build-gap.md) | Interpreter bottleneck diagnosis and ranked options |
| [OSS-Fuzz assessment](fuzz-ossfuzz-assessment.md) | Not currently a fit for Cynic's Fuzzilli pipeline |

When a subsystem document and a score ledger disagree, the ledger owns the
number and the subsystem document owns the design. Fix the stale cross-link;
do not duplicate a live score into another overview.
