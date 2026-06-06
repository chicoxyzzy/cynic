# Security

Cynic is intended to run untrusted JavaScript inside a host process —
edge runtimes, server JS, the WASM playground. A bug that aborts the
host, reads memory it shouldn't, or breaks out of the SES posture is a
real security problem, pre-alpha or not. Report them; they get
acknowledged.

## Supported versions

`main` at HEAD only. No release branches, no backports, no tagged
releases. `build.zig.zon` pins `version = "0.0.0"` on purpose.

| Version       | Supported |
|---------------|-----------|
| `main`        | yes       |
| anything else | no        |

## Reporting

[Open a private advisory on this repository.][ghsa] GitHub routes the
report to the maintainers without making it public.

Useful to include:

- a minimal reproducer — a `cynic eval '...'` one-liner or a short
  `cynic run` script;
- the build mode (`Debug` / `ReleaseSafe` / `ReleaseFast`);
- the CLI flags it ran under — `--allow=eval`, `--unhardened`,
  any `--enable=…`;
- expected vs. observed behaviour.

[ghsa]: https://github.com/chicoxyzzy/cynic/security/advisories/new

## What we commit to

Acknowledgement within 7 days of the report landing in GHSA.

That is the entire SLA. Cynic is a part-time project; fix timelines
depend on the bug, the day, and whether anyone else is awake. No
promises beyond "we read it and we'll tell you we read it."

## In scope

- **Host abort from user JavaScript.** `panic`, `unreachable`, an
  unchecked numeric cast, or OOM that crashes the process instead of
  throwing a JS exception.
- **Memory-safety violations reachable from user code.**
  Out-of-bounds read or write, use-after-free, type confusion through
  the NaN-boxed value representation.
- **Sandbox escape.** Arbitrary host-code execution from user JS.
- **Eval-gate bypass.** Any path that compiles or executes
  user-supplied source while `--allow=eval` is off.
- **SES-hardening bypass on a hardened realm.** Mutating a frozen
  primordial, defeating the override-mistake fix, or reaching state
  that ought to be sealed.
- **Cross-realm authority escape.** A `ShadowRealm` or multi-realm
  boundary that leaks intrinsics, scope-chain access, or `Function`
  constructors into the wrong realm.
- **Parser, lexer, or Perlex DoS on small input.** Catastrophic
  backtracking, super-linear time or space on adversarial source.
- **`Atomics` / `SharedArrayBuffer` races** that cross into undefined
  behaviour or memory-safety violations. Torn reads producing
  non-spec *values* without UB are conformance bugs, not security
  bugs.

## Out of scope

- The 15 documented Annex B regex carve-outs — see "Regex" in
  [`AGENTS.md`](AGENTS.md).
- Divergences from sloppy-mode behaviour. Cynic is strict-only by
  design — file these against test262, not security.
- Pre-Stage-4 proposal behaviour gated behind `--enable=`. The flag
  exists to opt into instability.
- Spec-conformance bugs without an exploitation path. Add a failing
  test262 fixture or a Cynic unit test instead.
- Anything that requires `--unhardened`. The flag is the explicit
  opt-out from SES; mutable primordials are the trade.
- Anything that requires `--allow=eval` and reduces to "with eval on,
  user code can monkey-patch things." Eval is the capability.
- Issues in `vendor/` (test262, UCD). Report those upstream.
- Performance or memory-use regressions that don't cross into DoS
  territory.

## Disclosure

Coordinated. Default embargo is 90 days from acknowledgement,
adjustable in either direction if a fix lands sooner or the
investigation needs more time. Advisories get published through GHSA
once a fix ships or the embargo expires.

## Safe harbour

Good-faith research on a local build of Cynic — fuzzing, manual
review, building a reproducer — is welcome. The maintainers will not
pursue legal action against research that stays within the scope
above and reports findings through the GHSA workflow.

## Current posture

What the engine does today, not a claim that it does it perfectly:

- **SES-hardened by default.** Every intrinsic is frozen at realm
  boot; `harden()` ships as a native global; the override-mistake fix
  is in place. `--unhardened` opts the whole posture out atomically.
  See [`docs/ses-alignment.md`](docs/ses-alignment.md).
- **Dynamic code generation off by default.** `eval`,
  `new Function(string)`, `new GeneratorFunction(string)`, and
  `new AsyncFunction(string)` throw `EvalError` unless `--allow=eval`
  is passed. Matches Node's
  `--disallow-code-generation-from-strings`.
- **No host abort on untrusted input.** Pathological input yields a
  catchable JS exception (`RangeError` / `EvalError`), not a panic,
  segfault, numeric-cast trap, or unbounded growth — enforced by
  saturating casts, recursion bounds, a native-reentry stack guard,
  and the GC rooting contract. See
  [`docs/handbook/host-safety.md`](docs/handbook/host-safety.md).
- **CI safety nets.** CodeQL static analysis on every push,
  dependabot on the dependency surface, the `test262` runtime sweep
  gating on a pass-rate floor, the advisory `test262-gc-stress` job
  (ReleaseSafe + `--gc-threshold=1` across the GC-mutation-heavy
  buckets, on every PR), and ReleaseSafe builds in the unit-test and
  conformance jobs so the GC verifiers and free-poison are armed.
