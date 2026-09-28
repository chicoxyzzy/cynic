# WPT Wasm JavaScript API results

Initial measured baseline: **14 of 40 included files pass completely**.
The remaining files are 24 assertion-failure files and 2 strict-mode parse
errors. Across files that execute, **266 subtests pass and 330 fail** (596
observed subtests). The two unparsed files contribute no observed subtests;
596 is therefore not the complete potential subtest denominator. No fixture
crashed, timed out, or ended without a harness result except those two explicit
parse errors. Another 40 files are explicitly excluded from the initial scope.

This measures a selected Wasm JavaScript API slice, not browser conformance or
the Wasm core instruction suite. See [the integration guide](docs/wpt.md),
[scope and exclusions](vendor/wpt/README.md), and the complete
[named-result baseline](tools/wpt/baseline.json).

## Measurement

| Input | Value |
| --- | --- |
| Captured | 2026-09-28 22:45:47 UTC |
| WPT revision | [`9ee707c850996c8d124809570c3ff855d67301b9`](https://github.com/web-platform-tests/wpt/tree/9ee707c850996c8d124809570c3ff855d67301b9/wasm/jsapi) |
| Engine checkout | `39619d43d32d89c2bb1f6b7105636cf8e97bf857`, with the local WPT integration changes |
| Host | macOS arm64 |
| Posture | Strict-only, mutable primordials, eval and Wasm compilation enabled; JS and Wasm JITs off |
| Limits | 50 million fuel units; 256 MiB engine memory; 10-second normal / 60-second long timeout |

The machine-readable baseline records corpus, adapter, and executable hashes.
Reproduce the score with `zig build wpt`. It exits nonzero while any included
file fails. Use `zig build wpt -- --baseline=tools/wpt/baseline.json` to check
for regressions against the recorded named results. Existing failures remain
reported as failures in this mode.

## Results by family

| Family | Passing files | Assertion-failure files | Parse errors | Passing subtests | Failing subtests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compilation / instantiation | 2 | 3 | 1 | 78 | 57 |
| Exception | 2 | 3 | 0 | 15 | 6 |
| Global | 1 | 3 | 0 | 17 | 115 |
| Instance | 1 | 3 | 1 | 8 | 28 |
| Interface | 0 | 1 | 0 | 46 | 26 |
| Memory | 1 | 5 | 0 | 22 | 34 |
| Module | 3 | 2 | 0 | 40 | 3 |
| Prototypes | 1 | 0 | 0 | 5 | 0 |
| Table | 1 | 4 | 0 | 27 | 61 |
| Tag | 2 | 0 | 0 | 8 | 0 |
| **Total** | **14** | **24** | **2** | **266** | **330** |

## What the failures show

The initial run identifies useful JS-facing gaps beyond binary execution:
`Global.prototype.valueOf` and receiver checks; constructor and prototype
property descriptors; exported-object extensibility and function identity;
Memory/Table argument conversion and exception types; missing fixed-length
and resizable memory-buffer methods; and Wasm error-constructor inheritance.
These are observed failure classes, not a one-to-one count of root causes.

Some failures reflect Cynic's deliberate strict-only policy. Both
`constructor/instantiate-bad-imports.any.js` and
`instance/constructor-bad-imports.any.js` bind a rest parameter named
`arguments`, which cannot parse as strict code. Several setter tests explicitly
expect sloppy-mode behavior, and exception fixtures contain undeclared loop
variables. These remain visible in the included-file results; adoption does
not relax the language policy or rewrite the fixtures.

The runner adapts only two support expressions in temporary copies: literal
regex braces in `testharness.js`, and the module builder's legacy `unescape`
UTF-8 encoding helper. All 143 imported upstream files remain byte-identical.
The known detached-Promise assertion fixture is explicitly excluded until host
rejection tracking or an upstream fixture correction makes it safe to score.
