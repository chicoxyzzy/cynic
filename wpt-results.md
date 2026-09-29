# WPT Wasm JavaScript API results

Measured baseline after memory-buffer conversion and ownership corrections: **27 of 40
included files pass completely**. The remaining files are 11 assertion-failure files
and 2 strict-mode parse errors. Across files that execute, **584 subtests pass
and 12 fail** (596 observed subtests). The two unparsed files contribute no
observed subtests; 596 is not the complete potential subtest denominator.
No fixture crashed, timed out, or ended without a harness result except those
two explicit parse errors. Another 40 files are explicitly excluded.

Compared with the initial measurement, **318 additional named subtests pass**
and 13 additional files pass completely; no previously passing subtest was lost.

| Measurement | Passing files | Failing files | Parse errors | Passing subtests | Failing subtests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial integration | 14 | 24 | 2 | 266 | 330 |
| API corrections | 22 | 16 | 2 | 570 | 26 |
| Function identity | 23 | 15 | 2 | 575 | 21 |
| Store-object identity / buffer GC | 24 | 14 | 2 | 576 | 20 |
| Memory-buffer conversion / ownership | 27 | 11 | 2 | 584 | 12 |

This measures a selected Wasm JavaScript API slice, not browser conformance or
the Wasm core instruction suite. See [the integration guide](docs/wpt.md),
[scope and exclusions](vendor/wpt/README.md), and the complete
[normal named-result baseline](tools/wpt/baseline.json) and
[ReleaseSafe GC-pressure baseline](tools/wpt/baseline-gc.json).

## Measurement

| Input | Value |
| --- | --- |
| Captured | 2026-09-29T20:02:04Z (normal); 2026-09-29T19:54:29Z (GC pressure) |
| WPT revision | [`9ee707c850996c8d124809570c3ff855d67301b9`](https://github.com/web-platform-tests/wpt/tree/9ee707c850996c8d124809570c3ff855d67301b9/wasm/jsapi) |
| Engine checkout | `ac93c078fda7b523b89f074e4aec3c58c652d210` (clean source for both profiles) |
| Host | macOS arm64 |
| Profiles | ReleaseFast / default GC; ReleaseSafe / `--gc-threshold=1` |
| Posture | Strict-only, mutable primordials, eval and Wasm compilation enabled; JS and Wasm JITs off |
| Limits | 50 million fuel units; 256 MiB engine memory; 10-second normal / 60-second long timeout |

Both machine-readable baselines record corpus, adapter, and executable hashes,
plus the compile mode queried from each executor.
Reproduce the score with `zig build wpt`. It exits nonzero while any included
file fails. `zig build wpt -- --baseline=tools/wpt/baseline.json` gates named
regressions in CI while continuing to report existing failures as failures. The
required ReleaseSafe run uses `zig build wpt-safe -- --gc-threshold=1
--baseline=tools/wpt/baseline-gc.json`; CI also compares all named results
between the two profiles, including known failures.

## Results by family

| Family | Passing files | Assertion-failure files | Parse errors | Passing subtests | Failing subtests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compilation / instantiation | 3 | 2 | 1 | 133 | 2 |
| Exception | 2 | 3 | 0 | 17 | 4 |
| Global | 4 | 0 | 0 | 132 | 0 |
| Instance | 3 | 1 | 1 | 35 | 1 |
| Interface | 1 | 0 | 0 | 72 | 0 |
| Memory | 4 | 2 | 0 | 54 | 2 |
| Module | 5 | 0 | 0 | 43 | 0 |
| Prototypes | 1 | 0 | 0 | 5 | 0 |
| Table | 2 | 3 | 0 | 85 | 3 |
| Tag | 2 | 0 | 0 | 8 | 0 |
| **Total** | **27** | **11** | **2** | **584** | **12** |

## Corrections and remaining failures

The correction pass fixes Global conversion/defaults/valueOf, WebIDL property
attributes and required arguments, Memory/Table address conversions, import
getter ordering, numeric exported-function names, shallow-frozen exports,
branded Instance.exports, and Wasm error inheritance. Focused engine tests also
cover collecting getters/start callbacks, promise capabilities, retained import
closures, and a function escaping a trapping start. Those GC tests supplement
the WPT score; they do not inflate its denominator.

The function-identity correction reuses one JS wrapper per Wasm store function,
including aliases, imported reexports, table/global reads, and reference results.
Five named subtests passed in that correction. The store-object correction
now also passes the compound `instance/constructor-caching` test: Global,
Memory, and Table imports retain their original wrappers, properties, and
subclass prototypes. Duplicate exports and cross-realm reexports share identity.

All file, process-exit, harness, and named-subtest outcomes match between
ReleaseFast with default GC and ReleaseSafe with `--gc-threshold=1`. The latter
keeps GC verifiers and memory poisoning enabled, and both profiles are required
in CI. No verifier failure, crash, or timeout occurred in either run. Unit
regressions cover hardened and unhardened realms, cache-only collection,
child-realm access, and allocation-failure rollback. A separate GC regression
also prevents a stale cached Memory.buffer pointer after growth: without a
strong reference to the old buffer, collection and address reuse previously
made the getter return an unrelated ArrayBuffer. JS and Wasm growth are covered.

The memory-buffer correction passes eight more named subtests. Both conversion
methods preserve cached identity, resizable buffers follow JS and Wasm growth,
and shared wrappers are frozen without detaching their storage. Focused tests
also protect borrowed storage from transfer, reentrant coercion, overlapping
copies across shared wrappers, failed allocations, and unreachable-wrapper
cleanup.

The remaining 12 assertions fall into these observed categories:

| Category | Assertions | Status |
| --- | ---: | --- |
| BufferSource instantiate import-lookup timing | 1 | Engine currently instantiates synchronously |
| Multiple return values from JS imports | 1 | Unsupported host-call result arity |
| Exception fixture binaries rejected by the decoder | 2 | Wasm encoding support gap |
| Sloppy setter expectations / undeclared loop variable | 5 | Strict-only policy |
| Dictionary conversion order / explicit undefined Table.set | 3 | Pinned WPT expectations differ from the current JS API |

Both `constructor/instantiate-bad-imports.any.js` and
`instance/constructor-bad-imports.any.js` bind a rest parameter named
`arguments`, which cannot parse as strict code. They remain visible as the
two execution errors; the fixtures and language policy are unchanged.

The current Wasm JS API uses `any` AddressValue dictionary members, so numeric
conversion follows dictionary reads, and its optional Table.set value treats
explicit undefined as absent. The pinned WPT asserts older behavior in those
three cases. See [specification drift](docs/wpt.md#api-corrections-and-specification-drift).

The runner adapts only two support expressions in temporary copies: literal
regex braces in `testharness.js`, and the module builder's legacy `unescape`
UTF-8 encoding helper. All 143 imported upstream files remain byte-identical.
The known detached-Promise assertion fixture is explicitly excluded until host
rejection tracking or an upstream fixture correction makes it safe to score.
