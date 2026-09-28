# Web Platform Tests: Wasm JavaScript API snapshot

This directory contains the complete upstream `wasm/jsapi/` subtree plus
`resources/testharness.js` and `LICENSE.md`, imported without source changes from
[web-platform-tests/wpt](https://github.com/web-platform-tests/wpt) commit
[`9ee707c850996c8d124809570c3ff855d67301b9`](https://github.com/web-platform-tests/wpt/tree/9ee707c850996c8d124809570c3ff855d67301b9)
(2026-09-28). The upstream license is retained in [LICENSE.md](LICENSE.md);
individual files retain their own copyright and license notices.

The authoritative pin, SHA-256 hashes, source sizes, fixture metadata, and
inclusion decisions are in [manifest.json](manifest.json). All 143 upstream
files are preserved byte for byte. This README and the manifest are local
integration metadata, not upstream source files.

## Scope

The initial baseline includes 40 `*.any.js` files that explicitly declare
the `jsshell` environment. Those exercise constructors, validation, compilation
and instantiation promises, imports/exports, prototypes, globals, tables, and
memory, plus the shipped Tag and Exception APIs. Seven Tag/Exception files still
carry upstream `.tentative` names; filename status alone does not exclude an
already-shipped feature. Stable APIs remain in scope even when Cynic does not yet implement them;
such results are engine failures, not selection exclusions.

The other 40 `*.any.js` files have an explicit `excluded_reason` in the manifest:

| Reason | Files |
| --- | ---: |
| Wasm ES module integration/module-host loading | 15 |
| Wasm JS type reflection/type descriptor extensions | 6 |
| Wasm source-phase imports/AbstractModuleSource | 1 |
| WebAssembly.Function proposal | 4 |
| Wasm GC | 3 |
| Wasm JS string builtins | 3 |
| Wasm JS Promise Integration | 3 |
| Shared Wasm memory/threads | 3 |
| Browser WebIDL harness | 1 |
| Detached asynchronous assertions requiring host rejection tracking | 1 |

`exception/identity.tentative.any.js` registers a synchronous `test()` but runs
its actual identity assertions in an unreturned `WebAssembly.instantiate(...)
.then(...)`. The shell currently has no host unhandled-rejection tracker, so a
rejected compilation or asynchronous assertion could appear to pass. This one
fixture remains explicitly excluded until it can be scored faithfully; its
source is unchanged. The other exception fixtures use awaited `promise_test`
work or synchronous assertions. Strict-only failures in the upstream `getArg`
and `is` fixtures (undeclared loop variables) remain visible in-scope failures.

Upstream HTML browser tests and support documents are preserved but are not
`*.any.js` fixture candidates. `.any.js` alone does not mean shell-compatible:
WPT's default globals are Window and dedicated worker. Every included fixture
declares `jsshell`, and every included `META: script` dependency is present in
the imported subtree. Excluded fixtures may reference browser resources outside
the snapshot; they are never run or counted as passes.

## Reproduce or update

From the repository root, verify the committed snapshot without network access:

```sh
python3 tools/wpt/import_corpus.py --verify
```

Reimport the exact commit currently recorded in the manifest:

```sh
python3 tools/wpt/import_corpus.py
```

Update deliberately using a complete upstream commit SHA:

```sh
python3 tools/wpt/import_corpus.py --revision <full-40-character-commit-sha>
```

The importer uses Python's standard library and GitHub's tree/raw endpoints. It
rejects truncated trees, missing dependency files, non-regular upstream files,
and bytes that do not match their pinned Git blob. All downloads and validation
finish before it changes the local snapshot. A refresh updates fixture metadata
and hashes; review changed scope, update this provenance note, and regenerate the
measured results/baseline separately.

The runner applies two accommodations to temporary support-file copies:
escaping literal braces in the harness's arrow-function-display regex, and
replacing the module builder's `unescape(encodeURIComponent(string))` with an
equivalent local percent-byte decoder. These preserve regex matching and UTF-8
encoding behavior without adding Annex B syntax or globals to Cynic. Each patch
requires exactly one matching expression; an upstream change must be reviewed.
The resulting hashes are recorded in reports. All imported sources, including
the fixtures themselves, remain unmodified.

This is a scoped engine conformance lane, not a browser WPT score. Selection and
results are separate: adding expected failures must never remove those fixtures
from the in-scope denominator.
