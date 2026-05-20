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
src/wasm.zig                  WASM entry module — C-ABI exports
src/wasm_shim.c               freestanding libc shim (mem*/str*/malloc)
vendor/quickjs/wasm-libc/     stub <stdlib.h> / <string.h> / … headers
playground/playground.html    single-page front-end
playground/playground.js      WASM loader + marshalling
playground/build.sh           convenience wrapper over `zig build wasm`
```

## Building

```
zig build wasm
```

This:

1. compiles `vendor/quickjs/libregexp.c` + `libunicode.c` +
   `src/wasm_shim.c` for `wasm32-freestanding`, `ReleaseSmall`;
2. compiles the Cynic library + `src/wasm.zig` for the same
   target;
3. links them into `zig-out/bin/cynic.wasm`;
4. assembles a directly-servable directory at
   `zig-out/playground/` containing `playground.html`,
   `playground.js`, and `cynic.wasm`.

Serve `zig-out/playground/` over HTTP (a `file://` origin will not
satisfy `WebAssembly.instantiateStreaming` / `fetch`):

```
cd zig-out/playground && python3 -m http.server 8080
# open http://localhost:8080/playground.html
```

`playground/build.sh` runs `zig build wasm` and prints the
resulting module size.

The current module is ~1.6 MB (`ReleaseSmall`, unstripped). It is
a complete ECMAScript engine — lexer, parser, bytecode compiler,
register interpreter, garbage collector, the full built-in surface
(Object / Array / String / Map / Set / Promise / TypedArray /
Proxy / RegExp / …) — plus the vendored QuickJS-NG regex engine.

## Why `wasm32-freestanding` (not WASI)

Freestanding was chosen and reached without falling back. The
engine needs no filesystem, no clock-of-record, no environment,
and no stdio at runtime — `console.log` is captured into an
in-module buffer, not written to a host stream. A WASI module
would drag in an unused syscall surface and a larger import
object for no functional gain. The only freestanding cost is a
hand-written libc shim, which is small and fully contained here.

## The freestanding C shim

`wasm32-freestanding` has no libc. The vendored QuickJS C
(`libregexp.c` / `libunicode.c`, and the header-only `cutils.h`)
`#include`s `<stdlib.h>`, `<string.h>`, `<stdio.h>`,
`<inttypes.h>`, `<math.h>`, `<assert.h>`, `<time.h>`,
`<pthread.h>`, and friends, and references `malloc` / `free` /
`realloc`, the `mem*` / `str*` family, and a few stdio symbols.

Two pieces close that gap:

- **`vendor/quickjs/wasm-libc/`** — minimal stub headers placed
  *first* on the C include path for the WASM build only. They
  declare the symbols QuickJS references; the native build keeps
  using the real system libc. `<math.h>` maps everything to
  compiler builtins (`__builtin_*`), so no libm link is needed.
  `<pthread.h>` provides opaque types — the inline thread helpers
  in `cutils.h` are never called and are dropped by the compiler.

- **`src/wasm_shim.c`** — the implementations. `malloc` / `free` /
  `realloc` / `calloc` forward to three C-ABI hooks exported from
  `src/wasm.zig` (`cynic_host_alloc` / `cynic_host_free` /
  `cynic_host_realloc`), which route into a single Zig
  `std.heap.WasmAllocator`. The `mem*` / `str*` family is written
  from scratch. `printf` / `fprintf` are no-ops (their only caller
  is libregexp's `DUMP_REOP` bytecode dumper — debug output with
  nowhere to go in a sandbox). `vsnprintf` / `snprintf` get a
  small real implementation because libregexp formats a
  diagnostic string through them.

So one allocator — the Zig `WasmAllocator` — owns every byte,
native Zig and vendored C alike.

A handful of Zig-side sites needed a target guard because they
assume a hosted platform: `clock_gettime` in `runtime/heap.zig`
and `runtime/builtins/date.zig` (no monotonic / wall clock on
freestanding — GC pause-time and `Date.now()` degrade to 0), and
the `std.c` allocator in the QuickJS host hooks
(`runtime/c_alloc.zig` routes to libc on a hosted target, to the
shim on freestanding). `Value`'s NaN-boxed pointer extraction
also gained a `usize` `@intCast` so it is correct on a 32-bit
target (`wasm32`).

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
| `cynic_host_alloc` / `cynic_host_free` / `cynic_host_realloc` | C-ABI | allocator hooks for `wasm_shim.c` (not called from JS) |

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

The editor source is encoded into `location.hash` (`#code=` +
URI-encoded base64) for shareable links; on load, a present hash
seeds the editor. A few sample snippets ship in the editor
showing strict-mode behaviour (TDZ ReferenceError, a Proxy trap,
a generator, a frozen-object TypeError).

## Rebuilding and deploying to the project site

The playground is developed under `playground/` on the main
branch — a clean, reviewable location. The public site lives on
the `gh-pages` branch. To publish:

1. `zig build wasm` — produces `zig-out/playground/` with all
   three files.
2. Copy `playground.html`, `playground.js`, and `cynic.wasm`
   onto the `gh-pages` branch (e.g. into a `playground/`
   subdirectory there).
3. Ensure the host serves `.wasm` with
   `Content-Type: application/wasm` so
   `instantiateStreaming` works — GitHub Pages already does.

The front-end links back to `../` for the project site; adjust
the relative paths if the deploy location differs.
