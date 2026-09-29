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
[`tools/wpt/baseline.json`](../tools/wpt/baseline.json) owns the measured named
subtest results. An implementation failure never changes selection.
The [measured results](../wpt-results.md) distinguish assertion failures,
strict-only parse errors, and observed subtest counts.

## Run and inspect

Requires the pinned Zig compiler and Python 3.9+ (standard library only).
Normal builds and runs do not download anything.

```sh
zig build test-wpt                         # importer, runner, real-engine contracts
zig build wpt -- --list                    # show selected paths
zig build wpt -- --filter=memory/toString  # one fixture, including all its subtests
zig build wpt -- --json-out=/tmp/wpt.json  # full results; nonzero for any failure
zig build wpt -- --baseline=tools/wpt/baseline.json
```

`wpt-build` builds and installs `zig-out/bin/cynic-wpt-case` without running
the suite. After that, direct runs avoid rebuilding:

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

The conformance posture is mutable primordials, eval permitted, Wasm byte
compilation permitted, and no experimental realm flags. Both JavaScript JIT
tiers and Spasm are off for the initial reference baseline. This affects only
the test executor; production hardening remains covered by `test-ses`.

The ordered scripts are environment metadata, `bootstrap.js`, the upstream
harness, `reporter.js`, `META: script` dependencies, the fixture, and `finish.js`.
All share one global environment. The executor drains microtasks only after
all scripts have evaluated, following ECMA-262
[ScriptEvaluation](https://tc39.es/ecma262/#sec-runtime-semantics-scriptevaluation)
and [Jobs](https://tc39.es/ecma262/#sec-jobs). The upstream shell harness uses a
Promise to finish loading, so an earlier checkpoint could complete before the
fixture registers its tests. `explicit_done` plus `done()` ends loading but
still waits for outstanding async tests; an empty job queue is not completion.

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
Browser HTML tests, the IDL harness, dedicated shared-memory/thread suites,
module-host integration, and unsupported proposal families have documented
exclusions. Included general-purpose fixtures can still contain individual
shared-memory assertions; these remain scored.
The shipped Exception/Tag API is eligible even where upstream filenames still
say `tentative`; strict-only failures inside those fixtures remain failures.

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
zig build wpt -- --write-baseline=tools/wpt/baseline.json --json-out=/tmp/wpt.json
zig build wpt -- --baseline=tools/wpt/baseline.json
```

Writing a baseline still returns nonzero when the scored run has failures.
Filtered runs cannot read or write the regression baseline. Improvements stay
visible, and a later deliberate refresh adds them to the protected pass set.

The `WPT Wasm JavaScript API` job in the main CI workflow runs on Linux after
the existing build/unit-test matrix. It verifies source hashes, runs the
importer/runner/executor contracts, and compares the complete selected corpus
with the committed named-result baseline. It uploads the JSON report even
when the comparison fails. The fixtures and support sources are vendored, so
the job needs no WPT checkout or browser download.

## API corrections and specification drift

The first correction pass covers WebIDL descriptors and brands, Global value
conversion and defaults, Memory/Table address conversion, shallow-frozen
exports, function names, import getters, required arguments, error inheritance,
and references held across JS callbacks and GC.
Focused engine tests also run collecting callbacks and hardened realms, which
the mutable-intrinsic WPT lane does not cover by itself.

The current [Wasm JS API](https://webassembly.github.io/spec/js-api/)
defines AddressValue dictionary members as `any`: Memory/Table constructors
read the dictionary before converting its numeric members. The pinned WPT
fixtures still expect some conversions during dictionary reads. Cynic follows
the current specification and records these assertions as failures. The same
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
