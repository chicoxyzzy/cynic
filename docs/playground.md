# Cynic Playground — WebAssembly build

The playground compiles the Cynic engine to a single
`wasm32-freestanding` WebAssembly module and pairs it with a
plain-HTML/JS front-end. A visitor types ECMAScript, hits **Run**,
and the same `Realm.evaluateScript` host path that powers `cynic
run` executes it in the browser sandbox.

Cynic is strict-only with no `eval` and no `Function(string)`. The
playground inherits that exactly — there is no path in the WASM
ABI that constructs code from a string at runtime. That is the
point of the demo.

## Layout

```
src/wasm.zig                       WASM entry module — C-ABI exports
playground/playground.html         two-column front-end
playground/playground.js           WASM loader + marshalling + CM6 editor
playground/codemirror.bundle.js    vendored CodeMirror 6 (committed artifact)
playground/codemirror-entry.mjs    bundle source — re-exports the CM6 surface
playground/codemirror.bundle.README.md  pinned versions + regenerate steps
playground/build.sh                convenience wrapper over `zig build wasm`
```

## Building

```
zig build wasm
```

This:

1. compiles the Cynic library + `src/wasm.zig` for
   `wasm32-freestanding`, `ReleaseSmall` (pure Zig — no C);
2. links into `zig-out/bin/cynic.wasm`;
3. assembles a directly-servable directory at
   `zig-out/playground/` containing `playground.html`,
   `playground.js`, `codemirror.bundle.js`, and `cynic.wasm`.

Serve `zig-out/playground/` over HTTP (a `file://` origin will not
satisfy `WebAssembly.instantiateStreaming` / `fetch`):

```
cd zig-out/playground && python3 -m http.server 8080
# open http://localhost:8080/playground.html
```

`playground/build.sh` runs `zig build wasm` and prints the
resulting module size.

The current module is ~3.4 MB (`ReleaseSmall`, unstripped). It is
a complete ECMAScript engine — lexer, parser, bytecode compiler,
register interpreter, garbage collector, the full built-in surface
(Object / Array / String / Map / Set / Promise / TypedArray /
Proxy / RegExp / …) — entirely native Zig, with no vendored C. The
native Unicode tables (case conversion, normalization, properties,
case folding) that replaced libunicode's bit-packed C tables are the
bulk of the size and an obvious target for later compression.

## Why `wasm32-freestanding` (not WASI)

Freestanding was chosen and reached without falling back. The
engine needs no filesystem, no clock-of-record, no environment,
and no stdio at runtime — `console.log` is captured into an
in-module buffer, not written to a host stream. A WASI module
would drag in an unused syscall surface and a larger import
object for no functional gain. And the engine is pure Zig, so
freestanding costs nothing extra: there is no libc shim to carry
and no C to satisfy — regex (Perlex) and the Unicode algorithms
are all native.

## Freestanding target guards

A handful of Zig-side sites need a target guard because they
assume a hosted platform: `clock_gettime` in `runtime/heap.zig`
and `runtime/builtins/date.zig` (no monotonic / wall clock on
freestanding — GC pause-time and `Date.now()` degrade to 0).
`Value`'s NaN-boxed pointer extraction also gained a `usize`
`@intCast` so it is correct on a 32-bit target (`wasm32`).

## Export ABI

`src/wasm.zig` exports a small C-ABI surface. All pointers are
byte offsets into the module's linear memory.

| Export | Signature | Purpose |
|---|---|---|
| `cynic_alloc` | `(len: u32) -> ptr` | allocate a guest buffer; JS writes UTF-8 source here |
| `cynic_free` | `(ptr, len: u32) -> void` | release a guest buffer |
| `cynic_eval` | `(ptr, len: u32) -> ptr` | parse + run source; returns a result frame |
| `cynic_parse` | `(ptr, len: u32) -> ptr` | parse + compile; returns a bytecode disassembly in the frame |
| `cynic_result_ptr` | `() -> ptr` | address of the last result frame |
| `cynic_result_len` | `() -> u32` | length of the last result frame |
| `cynic_version_ptr` / `cynic_version_len` | `() -> ptr / u32` | the engine version string |

`cynic_eval` and `cynic_parse` both return a **result frame** — a
self-describing buffer so the JS side needs no struct-layout
knowledge beyond the section-length encoding:

```
[u8  status]      0 = ok, 1 = uncaught throw, 2 = parse/compile error
[u32 stdout_len]  big-endian
[u8  stdout_len bytes]      captured console.log / print output
[u32 value_len]   big-endian
[u8  value_len bytes]       completion value, string form
[u32 error_len]   big-endian
[u8  error_len bytes]       error text (empty unless status != 0)
```

For `cynic_parse` the `value` section carries the bytecode
disassembly text and `stdout` is empty.

The frame is owned by the module and replaced on the next call;
the JS side reads it immediately via `cynic_result_ptr` /
`cynic_result_len`.

`cynic_eval` pre-parses with a diagnostics buffer so a syntax
error surfaces as readable text (status 2) instead of a silent
`undefined` — Cynic's parser is diagnostic-collecting and only
returns a hard error for fatal cases.

## Front-end

`playground/playground.js` streams the module with
`WebAssembly.instantiateStreaming` (falling back to `fetch` +
`arrayBuffer` on older browsers), copies editor source in via
`cynic_alloc`, calls `cynic_eval` (or `cynic_parse` when the
bytecode-inspector toggle is on), and decodes the result frame.
The import object is empty — the freestanding module imports
nothing.

The page is a full-width toolbar over a two-column grid (editor
left, output right; it collapses to a single stacked column under
~760 px).

The editor source is encoded into `location.hash` (`#code=` +
URI-encoded base64) for shareable links; on load, a present hash
seeds the editor. A few sample snippets ship in the editor
showing strict-mode behaviour (TDZ ReferenceError, a Proxy trap,
a generator, a frozen-object TypeError).

### CodeMirror 6 editor

The editor is [CodeMirror 6](https://codemirror.net/), vendored
**offline** as a single committed bundle,
`playground/codemirror.bundle.js`. Cynic is SES-aligned ("no eval,
that's the point") — a runtime CDN import would be supply-chain
bait, and the playground must work fully offline. The bundle is
treated like a pinned `vendor/` blob: regenerate it, never
hand-edit it. `playground/codemirror-entry.mjs` is the bundle
source — it imports the CM6 packages and re-exports exactly the
surface the front-end uses; `codemirror.bundle.README.md` carries
the pinned package versions and the `esbuild` regenerate command.

The bytecode inspector wires a **hover-link** between the two
columns: every disassembly instruction line carrying a trailing
`[start..end]` source span is rendered with a `.bc-hot` class and
`data-from` / `data-to` attributes. The engine's spans are UTF-8
byte offsets; the CodeMirror document is indexed in UTF-16 code
units, so the front-end builds a byte-offset → code-unit map from
the current source once per disassembly and converts. Hovering a
`.bc-hot` line dispatches a CodeMirror `StateEffect` that marks
the matching source range via a `StateField`-backed
`Decoration.mark` — a focus-independent highlight that never
touches the user's real selection.

## Rebuilding and deploying to the project site

The playground is developed under `playground/` on the main
branch — a clean, reviewable location. The public site lives on
the `gh-pages` branch. To publish:

1. `zig build wasm` — produces `zig-out/playground/` with all
   four files.
2. Copy `playground.html`, `playground.js`,
   `codemirror.bundle.js`, and `cynic.wasm` onto the `gh-pages`
   branch (e.g. into a `playground/` subdirectory there).
3. Ensure the host serves `.wasm` with
   `Content-Type: application/wasm` so
   `instantiateStreaming` works — GitHub Pages already does.

The front-end links back to `../` for the project site; adjust
the relative paths if the deploy location differs.
