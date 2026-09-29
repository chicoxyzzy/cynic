# WPT Wasm JavaScript API results

Measured baseline after the first API correction pass: **22 of 40 included
files pass completely**. The remaining files are 16 assertion-failure files
and 2 strict-mode parse errors. Across files that execute, **570 subtests pass
and 26 fail** (596 observed subtests). The two unparsed files contribute no
observed subtests; 596 is not the complete potential subtest denominator.
No fixture crashed, timed out, or ended without a harness result except those
two explicit parse errors. Another 40 files are explicitly excluded.

Compared with the initial measurement, **304 additional named subtests pass**
and 8 additional files pass completely; no previously passing subtest was lost.

| Measurement | Passing files | Failing files | Parse errors | Passing subtests | Failing subtests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial integration | 14 | 24 | 2 | 266 | 330 |
| API corrections | 22 | 16 | 2 | 570 | 26 |

This measures a selected Wasm JavaScript API slice, not browser conformance or
the Wasm core instruction suite. See [the integration guide](docs/wpt.md),
[scope and exclusions](vendor/wpt/README.md), and the complete
[named-result baseline](tools/wpt/baseline.json).

## Measurement

| Input | Value |
| --- | --- |
| Captured | 2026-09-29T00:19:28Z |
| WPT revision | [`9ee707c850996c8d124809570c3ff855d67301b9`](https://github.com/web-platform-tests/wpt/tree/9ee707c850996c8d124809570c3ff855d67301b9/wasm/jsapi) |
| Engine checkout | `5efeabe324367f563f02b979e230da053e5ec308` (clean runtime source) |
| Host | macOS arm64 |
| Posture | Strict-only, mutable primordials, eval and Wasm compilation enabled; JS and Wasm JITs off |
| Limits | 50 million fuel units; 256 MiB engine memory; 10-second normal / 60-second long timeout |

The machine-readable baseline records corpus, adapter, and executable hashes.
Reproduce the score with `zig build wpt`. It exits nonzero while any included
file fails. `zig build wpt -- --baseline=tools/wpt/baseline.json` gates named
regressions in CI while continuing to report existing failures as failures.

## Results by family

| Family | Passing files | Assertion-failure files | Parse errors | Passing subtests | Failing subtests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compilation / instantiation | 3 | 2 | 1 | 133 | 2 |
| Exception | 2 | 3 | 0 | 17 | 4 |
| Global | 4 | 0 | 0 | 132 | 0 |
| Instance | 2 | 2 | 1 | 34 | 2 |
| Interface | 1 | 0 | 0 | 72 | 0 |
| Memory | 1 | 5 | 0 | 46 | 10 |
| Module | 5 | 0 | 0 | 43 | 0 |
| Prototypes | 1 | 0 | 0 | 5 | 0 |
| Table | 1 | 4 | 0 | 80 | 8 |
| Tag | 2 | 0 | 0 | 8 | 0 |
| **Total** | **22** | **16** | **2** | **570** | **26** |

## Corrections and remaining failures

The correction pass fixes Global conversion/defaults/valueOf, WebIDL property
attributes and required arguments, Memory/Table address conversions, import
getter ordering, numeric exported-function names, shallow-frozen exports,
branded Instance.exports, and Wasm error inheritance. Focused engine tests also
cover collecting getters/start callbacks, promise capabilities, retained import
closures, and a function escaping a trapping start. Those GC tests supplement
the WPT score; they do not inflate its denominator.

The remaining 26 assertions fall into these observed categories:

| Category | Assertions | Status |
| --- | ---: | --- |
| Exported-function wrapper identity/caching | 6 | Engine gap |
| Fixed-length/resizable memory-buffer methods | 7 | Missing API |
| Shared-memory buffer freezing | 1 | Engine gap in an included basic assertion |
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
