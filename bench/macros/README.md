# Macro benchmarks

The six compute-heavy workloads every JavaScript engine is known by —
the pure-compute core of the (retired) V8 **Octane 2.0** suite. They
complement `bench/micros/` (which isolate one interpreter mechanism
each) with whole-program workloads, and they make the cross-engine
table (`tools/bench-cross.sh`) meaningful: "Cynic vs QuickJS on
Richards" is a number people recognise.

| Fixture | Workload | `CYNIC_ITERS` |
|---|---|---|
| `richards.js` | OS task-scheduler simulation (deep OOP, message passing) | 100 |
| `deltablue.js` | One-way constraint solver | 30 |
| `crypto.js` | RSA encrypt + decrypt (Tom Wu's jsbn big-integer) | 2 |
| `raytrace.js` | Ray tracer rendering a small scene | 3 |
| `navier-stokes.js` | 2-D fluid dynamics solver | 2 |
| `splay.js` | Splay-tree insert/remove under a large retained payload tree | 1 |

## What these measure, and what they don't

These run on Cynic's **interpreter tier** (and Bistromath behind
`--jit`); every cross-engine peer runs **jitless** too, so the
comparison is apples-to-apples at the interpreter tier — not a
JIT-throughput contest. Octane was *retired by its own authors*
because engines over-tuned to it, so treat these as **relative
tracking** (Cynic over time) and **cross-engine interpreter-tier
comparison**, never a headline score. This repo deliberately avoids
benchmark theatre; these earn their place by being recognisable
workloads, not by producing a big number.

`splay.js` is dominated by its one-time setup — an 8000-node payload
tree (~250k allocations) the GC must manage — so for Cynic it reads as
a **GC/allocation macro** more than a splay-rotation micro. That's the
most useful signal it gives a from-scratch engine, and the canonical
`kSplayTreeSize` is left unchanged.

## Provenance and licence

Each `*.js` body is **byte-for-byte upstream**
([github.com/chromium/octane](https://github.com/chromium/octane)),
including its original copyright header. Octane is distributed under a
BSD-3-Clause-style licence (richards/deltablue/splay: "the V8 project
authors"; raytrace: Flog/Adobe; crypto's jsbn: Tom Wu) — all permit
redistribution with the notice retained, which it is.

## The Cynic wrapper

Octane's own driver (`base.js`) is a scoring harness Cynic doesn't
use. Instead each fixture is **self-contained**: a small prelude
stands in for `base.js`'s `BenchmarkSuite` / `Benchmark` registry
(capturing each benchmark's `run`/`Setup`/`TearDown`), and a tail runs
a fixed `CYNIC_ITERS` count — no warmup, no scoring. `tools/bench.zig`
times the whole process. The prelude also shims `performance.now()`
(a browser global Cynic omits) onto `Date.now()` for Splay's latency
sampler, and pre-declares the nine implicit globals jsbn assigns
(strict mode forbids the bare assignment; the body stays verbatim).

## Running

Both postures, exactly like the micros — interpreter-only (Lantern)
and JIT-enabled (Bistromath, the engine default):

    # single-engine (Cynic)
    zig build bench -- --macros                 # JIT on (Bistromath, default)
    zig build bench -- --macros --no-jit        # interpreter-only baseline
    zig build bench -- --macros --runs=3        # quick pass (Splay is heavy)

    # cross-engine — both tiers in one go (two tables):
    #   interpreter-tier (all peers jitless) + full-speed (peer JITs on)
    tools/bench-cross.sh --macros
    tools/bench-cross.sh --macros --tier interp # interpreter tier only

The single-engine `--no-jit` vs default pair is the same comparison
the micro history records in `bench-results.md` (Lantern vs
Bistromath); the cross-engine run mirrors `bench-cross.sh`'s default
two-tier output. The interpreter tier is the fairer from-scratch
comparison; the full-speed tier shows the gap to production JITs.

All macro runs pass `--unhardened` to Cynic: the workloads monkey-patch
primordial prototypes (normal for ES5-era code), which the default
frozen-primordials posture rejects. Peers are unhardened by nature, so
this keeps the comparison fair.
