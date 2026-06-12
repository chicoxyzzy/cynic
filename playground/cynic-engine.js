// cynic-engine.js — the WASM ABI binding for the Cynic playground.
//
// This module is the *engine half* of the playground: it owns the raw
// `cynic.wasm` ABI (`cynic_alloc` / `cynic_eval` / `cynic_result_ptr`
// / …) and wraps it in a small, stable JavaScript API. It is built and
// published alongside `cynic.wasm` by the engine's CI (see
// `.github/workflows/playground.yml`), because it tracks the ABI
// exported from `src/wasm.zig` — an ABI change is absorbed here, not in
// the UI.
//
// The website-side UI (`app.js`, which lives on the `gh-pages` branch)
// imports only the exports below and the returned *frame* shape; it
// never touches the raw exports. Keep this API steady so the UI and the
// engine can evolve on separate branches.
//
// Exports:
//   loadEngine(wasmUrl?)            — instantiate the module (once).
//   engineVersion()                — the version string the build stamped.
//   evalSource(src, { hardened? }) — run a Script; default hardened (SES).
//   parseSource(src)               — compile to bytecode (inspector view).
//   parseAst(src)                  — parse to an S-expression AST.
//
// Every `*Source` / `parse*` call returns a frame:
//   { status, stdout, value, error, errorSpan, stats }
// where `errorSpan` is `{ startByte, endByte }` or `null` and
// `stats` is a short multi-line string (e.g. `chunk: 24 B · 1 consts
// · 2 regs\nGC: 0 cycles · 0.0 ms pause · peak 0 B · alloc 24 B`)
// or the empty string. Only `evalSource` populates `stats` today;
// `parseSource` / `parseAst` always return `''` so the UI can
// uniformly render or hide it.

let wasm = null; // { instance, exports, memory }

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Instantiate `cynic.wasm`. Prefer streaming compile, but fall back to
// a buffered fetch on ANY streaming failure — not just a missing
// `instantiateStreaming`. `instantiateStreaming` rejects when the
// server sends the wrong `Content-Type` (anything other than
// `application/wasm`), which happens on local static servers that don't
// know the `.wasm` MIME type. GitHub Pages serves it correctly, so the
// fallback is purely local-dev insurance.
async function instantiateWasm(wasmUrl, importObject) {
  if (WebAssembly.instantiateStreaming) {
    try {
      return await WebAssembly.instantiateStreaming(
        fetch(wasmUrl),
        importObject,
      );
    } catch (err) {
      console.warn(
        'instantiateStreaming failed (likely a Content-Type other ' +
          'than application/wasm); retrying with a buffered fetch.',
        err,
      );
    }
  }
  const bytes = await (await fetch(wasmUrl)).arrayBuffer();
  return WebAssembly.instantiate(bytes, importObject);
}

// Load + instantiate the engine. Call once before any eval/parse.
// Throws if the module can't be fetched or compiled; the caller owns
// the user-facing error surfacing.
export async function loadEngine(wasmUrl = 'cynic.wasm') {
  // The freestanding module imports nothing — allocation routes back
  // into the module itself. An empty import object is all it needs.
  const result = await instantiateWasm(wasmUrl, {});
  wasm = {
    instance: result.instance,
    exports: result.instance.exports,
    memory: result.instance.exports.memory,
  };
}

// The version string the build stamped into the module (commit SHA).
export function engineVersion() {
  const ex = wasm.exports;
  if (!ex.cynic_version_ptr || !ex.cynic_version_len) return 'cynic-wasm';
  const ptr = ex.cynic_version_ptr();
  const len = ex.cynic_version_len();
  return decoder.decode(new Uint8Array(wasm.memory.buffer, ptr, len));
}

// Run `source` through one of the engine's entry points and return the
// parsed result frame. `extraArgs` carries export-specific trailing
// params (e.g. `cynic_eval`'s `hardened` flag); parse/AST exports pass
// none.
function callEngine(exportName, source, ...extraArgs) {
  const ex = wasm.exports;
  const bytes = encoder.encode(source);
  const ptr = ex.cynic_alloc(bytes.length);
  if (ptr === 0) throw new Error('cynic_alloc returned null');

  try {
    // Re-view memory each time — `memory.grow` inside the call can
    // detach the previous ArrayBuffer.
    new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
    ex[exportName](ptr, bytes.length, ...extraArgs);
    return readFrame();
  } finally {
    ex.cynic_free(ptr, bytes.length);
  }
}

// Compile + run `src` as a Script. `hardened` (default true) mirrors the
// CLI's SES posture: frozen primordials + frozen globalThis. `false`
// is the `--unhardened` opt-out — mutable intrinsics.
export function evalSource(src, { hardened = true } = {}) {
  return callEngine('cynic_eval', src, hardened ? 1 : 0);
}

// Compile `src` to bytecode (the inspector / disassembly view).
export function parseSource(src) {
  return callEngine('cynic_parse', src);
}

// Parse `src` to an S-expression AST.
export function parseAst(src) {
  return callEngine('cynic_parse_ast', src);
}

// Decode the framed result buffer the engine left behind.
function readFrame() {
  const ex = wasm.exports;
  const framePtr = ex.cynic_result_ptr();
  const frameLen = ex.cynic_result_len();
  if (framePtr === 0 || frameLen === 0) {
    return {
      status: -1,
      stdout: '',
      value: '',
      error: 'engine returned no result',
      errorSpan: null,
    };
  }
  const view = new DataView(wasm.memory.buffer, framePtr, frameLen);
  let off = 0;
  const status = view.getUint8(off); off += 1;

  const section = () => {
    const len = view.getUint32(off, false); off += 4;
    const text = decoder.decode(
      new Uint8Array(wasm.memory.buffer, framePtr + off, len),
    );
    off += len;
    return text;
  };

  const stdout = section();
  const value = section();
  const error = section();

  // The engine appends an 8-byte error_span (start:u32 + end:u32, big-
  // endian byte offsets into source) past the textual error section.
  // `start == end` is the wire sentinel for "no source range"; null
  // here so the renderer skips the wavy-underline decoration. Older
  // WASM bundles without the span tail still parse cleanly because the
  // section lengths are explicit — `off` simply stops before the
  // missing bytes.
  let errorSpan = null;
  if (off + 8 <= frameLen) {
    const start = view.getUint32(off, false); off += 4;
    const end = view.getUint32(off, false); off += 4;
    if (end > start) errorSpan = { startByte: start, endByte: end };
  }

  // Same backwards-compatibility shape as the error_span tail above:
  // the stats section is `[u32 len][bytes]` and rides at the very end
  // of the frame. Older WASM bundles without it simply leave `off`
  // past the available bytes — we default to empty string.
  let stats = '';
  if (off + 4 <= frameLen) {
    const len = view.getUint32(off, false); off += 4;
    if (off + len <= frameLen) {
      stats = decoder.decode(
        new Uint8Array(wasm.memory.buffer, framePtr + off, len),
      );
      off += len;
    }
  }

  return { status, stdout, value, error, errorSpan, stats };
}
