# Web Platform Tests: Wasm JavaScript API

Cynic runs a pinned, explicitly scoped slice of WPT against its own engine.
This complements test262 (ECMAScript semantics) and the Wasm core testsuite
(binary validation/execution) with JavaScript-facing Wasm API coverage:
constructors, brands, descriptors, coercions, imports/exports, promises,
exceptions, and memory/table behavior. It is not a browser conformance score.

The corpus, license, pin, and inclusion reasons live in
[`vendor/wpt/`](../vendor/wpt/README.md). Sources are preserved byte for byte;
[`manifest.json`](../vendor/wpt/manifest.json) records hashes and all included
and excluded `.any.js` candidates. The manifest owns selection;
[`tools/wpt/baseline.json`](../tools/wpt/baseline.json) and
[`tools/wpt/baseline-gc.json`](../tools/wpt/baseline-gc.json) own the measured named
subtest results for the normal and GC-pressure profiles. An implementation
failure never changes selection.
The [measured results](../wpt-results.md) distinguish assertion failures,
strict-only parse errors, and observed subtest counts.

## Run and inspect

Requires the pinned Zig compiler and Python 3.9+ (standard library only).
Normal builds and runs do not download anything.

```sh
zig build test-wpt test-wpt-safe           # tooling and both real-engine contracts
zig build wpt -- --list                    # show selected paths
zig build wpt -- --filter=memory/toString  # one fixture, including all its subtests
zig build wpt -- --json-out=/tmp/wpt.json  # full results; nonzero for any failure
zig build wpt -- --baseline=tools/wpt/baseline.json
zig build wpt-safe -- --gc-threshold=1 --baseline=tools/wpt/baseline-gc.json
```

`wpt-build` builds and installs `zig-out/bin/cynic-wpt-case` without running
the suite. `wpt-safe-build` installs `zig-out/bin/cynic-wpt-case-safe`, with both
the executor and engine compiled in ReleaseSafe. The corresponding `wpt-safe`
run target preserves GC verifiers and memory poisoning; pass `--gc-threshold=1`
explicitly to collect on allocation pressure. After building, direct runs avoid
rebuilding:

```sh
python3 tools/wpt/run.py --binary=zig-out/bin/cynic-wpt-case --filter=module/
```

The summary reports file outcomes and individual subtest statuses separately.
A file passes only if the process exits successfully, WPT reports completion
with an OK harness status, at least one subtest ran, and every subtest passed.
Crashes, wall-clock timeouts, uncaught exceptions, malformed protocol output,
missing completion, zero-test files, and harness errors are distinct outcomes.
WPT `TIMEOUT`, `NOTRUN`, and `PRECONDITION_FAILED` subtests are never passes.

The JSON report preserves names, statuses, assertion diagnostics, process
diagnostics, configuration, source provenance, and explicit exclusions. Use
`--quiet` to omit passing file lines, retaining failures and the summary.

## Execution contract

`tools/wpt/run.py` handles metadata, checksum verification, process supervision,
and reporting. Each selected fixture runs in a separate `cynic-wpt-case`
process, with a fresh Realm. `tools/wpt/case.zig` uses the actual Cynic parser,
compiler, interpreter, and Wasm engine. Python does not execute JavaScript.

Before running fixtures, the supervisor queries the executor's standalone
`--build-info` command. Its JSON response reports the actual compile mode from
Zig's `builtin.mode`; no Realm or JavaScript is created for this query. Missing,
malformed, timed-out, or unsuccessful responses fail the run. The report records
the observed mode in `configuration.build_mode`, and `--expect-build-mode` rejects
a mismatch before any fixture executes. The build targets supply their expected
mode automatically: normally ReleaseFast for `wpt`, always ReleaseSafe for
`wpt-safe`. Changing `-Doptimize` does not change these dedicated executors;
`-Dtest262-debug=true` selects Debug for the normal executor only.

The conformance posture is mutable primordials, eval permitted, Wasm byte
compilation permitted, and no experimental realm flags. Both JavaScript JIT
tiers and Spasm are off for the initial reference baseline. This affects only
the test executor; production hardening remains covered by `test-ses`.

The ordered scripts are environment metadata, `bootstrap.js`, the upstream
harness, `reporter.js`, `META: script` dependencies, the fixture, and `finish.js`.
All share one global environment. The executor begins draining only after
all scripts have evaluated, following ECMA-262
[ScriptEvaluation](https://tc39.es/ecma262/#sec-runtime-semantics-scriptevaluation)
and [Jobs](https://tc39.es/ecma262/#sec-jobs). The existing `drainMicrotasks`
entry point also drives queued Wasm instantiation tasks: it completes the
ordinary promise-job checkpoint before each Wasm task, including reactions
queued by earlier reactions. Import getters and core instantiation therefore
have separate checkpoints. This is a host-driven queue, not an event loop or
timer service. The upstream shell harness uses a Promise to finish loading, so
an earlier checkpoint could complete before the fixture registers its tests.
`explicit_done` plus `done()` ends loading but still waits for outstanding
async tests; empty queues are not completion.

Two support-source adaptations are applied only to temporary copies. The
harness's arrow-function-display regex gets escaped literal braces, preserving
its matching behavior under Cynic's strict RegExp grammar. The Wasm module
builder's `unescape(encodeURIComponent(string))` UTF-8 conversion gets an
equivalent local percent-byte decoder; the Annex B `unescape` global stays
absent. Both patches require exactly one matching upstream expression, and
their resulting hashes are recorded with the adapter. Fixtures are never
rewritten. Bootstrap supplies `self` and console aliases without claiming a
DOM, workers, timers, a network stack, or an event loop.

Limits default to 10 seconds per normal fixture, 60 for `META: timeout=long`,
50 million fuel units, and a 256 MiB engine memory ceiling. The memory ceiling
is engine accounting, not an OS process-RSS limit. The executor streams output
with a finite byte cap; the supervisor bounds captured diagnostics. `--timeout`,
`--long-timeout`, `--fuel`, `--memory-limit`, and `--gc-threshold` support focused
diagnosis. Changed limits require a separate reviewed baseline.

## Scope and limitations

Only fixtures explicitly declaring `jsshell` are eligible. WPT `.any.js`
defaults to window and dedicated-worker environments, not arbitrary engines.
Browser HTML tests, the IDL harness, thread-dependent suites, module-host
integration, and unsupported proposal families have documented exclusions.
Three explicitly reviewed shared-memory fixtures run within one agent: memory
construction, fixed-length buffer conversion, and resizable buffer conversion.
They require no workers or thread coordination. Other shared-memory and thread
fixtures still require review before inclusion. Shared-memory assertions in
general-purpose fixtures also remain scored.
The shipped Exception/Tag API and shared-memory constructor are eligible even
where upstream filenames still say `tentative`; strict-only failures inside
those fixtures remain failures.

There is no host unhandled-rejection event reporting yet. Returned promises
inside `promise_test` are observed by the upstream harness, but detached
rejections are not. The known `exception/identity.tentative.any.js` fixture
launches detached asynchronous assertions inside synchronous `test()` and is
explicitly excluded, rather than producing a misleading pass. Revisit it with
an upstream `promise_test` correction or host rejection tracking.

The initial corpus has no META variants. The supervisor rejects nonempty
variants until their host context is implemented; it does not fabricate browser
URL or module-loading APIs for future additions. Review new metadata and host
requirements when updating the corpus.

## Baseline and CI

The regular scoring command exits nonzero for any nonpassing in-scope file.
The explicit `--baseline` mode gates regressions while continuing to display
existing failures as failures. It compares named results and membership, not
just an aggregate percentage: a new pass cannot hide a previously passing
subtest becoming a failure, and disappearing fixtures/subtests are errors.
Corpus, adapter, and execution-configuration changes require review.

To intentionally refresh after inspecting the full run:

```sh
python3 tools/wpt/import_corpus.py --verify
zig build wpt -- --write-baseline=/tmp/wpt-baseline.json --json-out=/tmp/wpt.json
zig build wpt-safe -- --gc-threshold=1 --write-baseline=/tmp/wpt-gc-baseline.json --json-out=/tmp/wpt-gc.json
python3 tools/wpt/compare_profiles.py --normal=/tmp/wpt.json --gc-stress=/tmp/wpt-gc.json
# Review both reports before copying the baselines into tools/wpt/.
```

Writing a baseline still returns nonzero when the scored run has failures.
Generate both from the same clean source revision, keeping temporary outputs
outside the checkout until both measurements finish. Each baseline requires an
exact execution-configuration match, including compile mode and GC threshold;
the normal baseline cannot substitute for the GC-pressure baseline.
Filtered runs cannot read or write the regression baseline. Improvements stay
visible, and a later deliberate refresh adds them to the protected pass set.

The `WPT Wasm JavaScript API` job in the main CI workflow runs on Linux after
the existing build/unit-test matrix. It verifies source hashes, runs the
importer/runner/profile-comparison contracts and both executors, then runs the
complete selected corpus in ReleaseFast with the default GC threshold and in
ReleaseSafe with `--gc-threshold=1`. Both are required checks against separate
committed baselines. A final comparison requires exact fixture membership,
named subtest statuses, file outcomes, process exit codes, and harness statuses
between the two reports, so independently refreshed baselines cannot hide a
GC-only difference. It also requires the same corpus, adapters, engine revision,
and limits; only build mode and GC threshold may differ in configuration.
Diagnostic text, timings, and binary hashes may differ.

The existing job name is preserved. It uploads both available JSON reports even
when a check fails. The fixtures and support sources are vendored, so the job
needs no WPT checkout or browser download.

## API corrections and specification drift

The first correction pass covers WebIDL descriptors and brands, Global value
conversion and defaults, Memory/Table address conversion, shallow-frozen
exports, function names, import getters, required arguments, error inheritance,
and references held across JS callbacks and GC.
Focused engine tests also run collecting callbacks and hardened realms, which
the mutable-intrinsic WPT lane does not cover by itself.

Exported-function identity is cached by canonical store address across aliases,
reexports, table/global reads, and reference results. The cache follows the
store owner across realms and is traced during GC; failed instantiation rolls
back new entries while preserving provider wrappers. See
[the ownership design](wasm-engine.md#8-the-js-boundary).
Global, Memory, and Table wrappers likewise preserve store-address identity
across duplicate exports and import/reexport chains. Direct constructors seed
the cache with their original receiver, including subclasses. Focused tests
cover child realms, cache-only GC retention, memory-buffer replacement after
growth, and allocation-failure rollback.

Memory buffer conversion now covers both fixed and resizable wrappers,
page-granular host resizing, and identity/extent updates across JS, interpreter,
and Spasm growth. Shared wrappers stay frozen and attached; overlap-sensitive
copies compare backing-store identity. The selected WPT corpus also exercises
shared-memory construction, buffer caching, maximum size, and growth in both
CI profiles. Transfer rejects Wasm-owned storage and rechecks ordinary buffers
after collecting coercion callbacks. Focused tests
also cover allocation failure, weak registration cleanup, and child-realm
teardown; these checks supplement the WPT score.

JS-backed Wasm imports support up to 16 parameters and 16 results. Multiple
results are consumed as an iterable before checking the count and converting
values in signature order; abrupt iteration does not call `return()`. Native
iterator property access handles callable Proxies and function objects, while
primitive results use their intrinsic prototypes even if the corresponding
global constructors are replaced. Focused coverage checks conversion order,
throw identity, hardened realms, GC pressure, start functions, cross-realm
reentry, fuel, and allocation failure in the interpreter and Spasm. Externrefs
stay rooted through the outermost call, and allocation failure retains its
OOM status across the host boundary. See the
[host-function design](wasm-engine.md#8-the-js-boundary).

`WebAssembly.instantiate(bytes, imports)` copies the selected bytes before
returning and reads imports in a deferred compilation-completion task.
The Module overload reads imports synchronously; both overloads defer active
segments and the start function until a later host task. Nested promise
reactions run before each task, and captured imports survive that checkpoint.
Focused tests cover byte-view offsets and later detachment, import mutation,
throw identity, GC, allocation failure, teardown, and uncatchable host termination.
The executor contract checks observable ordering and WPT completion in both CI
profiles. See the [async boundary design](wasm-engine.md#8-the-js-boundary).

The current [Wasm JS API](https://webassembly.github.io/spec/js-api/)
defines AddressValue dictionary members as `any`: Memory/Table constructors
read the dictionary before converting its numeric members. The pinned WPT
fixtures, including the shared-memory constructor, still expect some
conversions during dictionary reads. Cynic follows the current specification
and records these assertions as failures. The same
principle applies to Table.set value conversion before bounds checking and
Table.grow's size snapshot before reentrant delta conversion, as well as
Table.set's optional value treating explicit undefined as absent. A baseline is
an observation of this exact corpus, not permission to replace normative
behavior with whatever yields a higher score.

## Prior art

WPT's own [JavaScript test format](https://web-platform-tests.org/writing-tests/testharness.html)
defines `jsshell` and metadata loading; its
[`ShellTestEnvironment`](https://github.com/web-platform-tests/wpt/blob/9ee707c850996c8d124809570c3ff855d67301b9/resources/testharness.js)
supplies the completion model. JavaScriptCore's
[shell Wasm WPT integration](https://commits.webkit.org/317464@main) is a close
precedent for small host shims and an explicit final checkpoint.
[Node's selective WPT imports](https://github.com/nodejs/node/blob/main/test/wpt/README.md)
provide the per-family pinning precedent. Cynic follows those patterns while
retaining its strict-only grammar and a separate hardened-runtime test lane.
