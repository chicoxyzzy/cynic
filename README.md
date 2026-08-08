# Cynic

[![CI](https://github.com/chicoxyzzy/cynic/actions/workflows/ci.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/ci.yml)
[![CodeQL](https://github.com/chicoxyzzy/cynic/actions/workflows/codeql.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/codeql.yml)
[![Playground](https://github.com/chicoxyzzy/cynic/actions/workflows/playground.yml/badge.svg)](https://github.com/chicoxyzzy/cynic/actions/workflows/playground.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Cynic is a strict-only ECMAScript and WebAssembly engine written from
scratch in Zig. It deliberately leaves out JavaScript's legacy
web-compatibility surface and starts each realm in a hardened posture.

**[Try the browser playground](https://chicoxyzzy.github.io/cynic/playground/)**

> Cynic is pre-alpha. Language coverage is broad, but the embedding API and
> runtime behavior are still evolving.

## Design contract

- **Strict-only ECMAScript.** Every script is parsed as strict code. Sloppy
  mode, Annex B, and legacy web-compatibility built-ins are intentionally out
  of scope.
- **Hardened by default.** Primordials are frozen, `harden()` is built in, and
  the override-mistake fix is enabled. Use `--unhardened` only when mutable
  primordials are required.
- **Code construction is host-controlled.** Runtime JavaScript strings require
  `--allow=eval`. WebAssembly is ready to use in the CLI; direct embedders can
  deny dynamic byte compilation with `Realm.allow_wasm_compile` while still
  accepting trusted modules and ordinary Wasm objects.
- **Modern features do not imply experiments.** Pre-Stage-4 proposals stay
  disabled unless selected with `--enable=<name>` or
  `--enable-experimental`.

The rationale and exact behavior are documented in
[`docs/ses-alignment.md`](docs/ses-alignment.md) and
[`AGENTS.md`](AGENTS.md).

## Quick start

The required Zig development build is pinned in
[`build.zig.zon`](build.zig.zon). [anyzig](https://github.com/marler8997/anyzig)
can resolve that exact version.

```sh
zig build
./zig-out/bin/cynic eval '1 + 2 * 3'
zig build test-fast
```

For test262 work, initialize the pinned suite once:

```sh
git submodule update --init vendor/test262
zig build test262 -- --quiet
```

## Run

```sh
./zig-out/bin/cynic lex path/to/file.js
./zig-out/bin/cynic parse path/to/file.js
./zig-out/bin/cynic parse --module path/to/file.js
./zig-out/bin/cynic eval '6 * 7'
./zig-out/bin/cynic run app.js
./zig-out/bin/cynic run first.js second.js   # one shared realm
./zig-out/bin/cynic repl                     # persistent realm
```

Top-level policy and feature controls come before the command:

```sh
./zig-out/bin/cynic --allow=eval eval 'eval("40 + 2")'
./zig-out/bin/cynic --unhardened run legacy-library.js
./zig-out/bin/cynic --list-features
./zig-out/bin/cynic --enable=ShadowRealm eval 'typeof ShadowRealm'
./zig-out/bin/cynic --no-jit run app.js
```

`Intl` is a compile-time choice rather than a runtime permission:

```sh
zig build -Dintl=off    # default: no Intl global
zig build -Dintl=stub   # structural Intl and Temporal extras
zig build -Dintl=full   # embedded tzdata and CLDR-backed formatting
```

## Status

Broad ECMAScript and WebAssembly coverage is working today; conformance and
embedding work remain active. Current details live in the
[roadmap](docs/ROADMAP.md), [test262 results](test262-results.md),
[WebAssembly results](wasm-results.md), and [JIT notes](docs/jit.md).

## Test and measure

```sh
zig build test-fast                         # ReleaseSafe, normal iteration
zig build test                              # Debug, canonical stack traces
zig build test-ses                          # hardened-realm coverage
zig build test262 -- --filter=Promise       # focused conformance run
zig build test262 -- --quiet                # full ECMAScript sweep
zig build wasm-testsuite -- --quiet         # generated official Wasm suite; see Wasm docs
zig build bench                             # local micro-benchmarks
```

The complete harness options, GC-stress postures, JIT differential gates, and
toolchain setup are maintained in [`AGENTS.md`](AGENTS.md). Before changing
shared runtime machinery, also read
[`docs/handbook/agent-checks.md`](docs/handbook/agent-checks.md).

## Supported targets

Native CI runs on `x86_64-linux-gnu` and Apple Silicon macOS. CI also
cross-builds `aarch64-linux-gnu`, `x86_64-linux-musl`, and `aarch64-macos`.
The browser playground uses `wasm32-freestanding`. Windows and mobile platform
integration are not yet supported.

## Project map

| Topic | Document |
|---|---|
| Documentation index and source-of-truth map | [`docs/README.md`](docs/README.md) |
| Architecture and component boundaries | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Shipped work and remaining scope | [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| Hardened realms, eval policy, and SES alignment | [`docs/ses-alignment.md`](docs/ses-alignment.md) |
| JIT tiers and rollout gates | [`docs/jit.md`](docs/jit.md) |
| WebAssembly engine and JS API | [`docs/wasm-engine.md`](docs/wasm-engine.md) |
| Benchmark methodology and results | [`docs/benchmarking.md`](docs/benchmarking.md) |
| Contributor rules and engineering handbook | [`AGENTS.md`](AGENTS.md), [`docs/handbook/`](docs/handbook/) |
| Security reports | [`SECURITY.md`](SECURITY.md) |

## Contributing

Start with [`AGENTS.md`](AGENTS.md). The project requires tests first,
ECMA-262-aligned naming, prior-art review for non-trivial engine decisions, and
catchable JavaScript exceptions instead of host aborts for untrusted input.

## License

Cynic is [MIT-licensed](LICENSE). Vendored test and data assets retain their
upstream licenses: Unicode and CLDR data under `vendor/unicode/` and
`vendor/cldr/`, IANA tzdata under `vendor/tzdata/iana/`, and test262 under
`vendor/test262/`.
