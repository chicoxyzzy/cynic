// Cynic playground front-end.
//
// Streams + instantiates `cynic.wasm` (the wasm32-freestanding
// engine built by `zig build wasm`), marshals editor source into
// the module via `cynic_alloc`, runs it through `cynic_eval`, and
// renders the framed result.
//
// The WASM result frame layout (see src/wasm.zig):
//   [u8  status]      0 ok | 1 uncaught throw | 2 parse/compile error
//   [u32 stdout_len]  big-endian   followed by stdout_len bytes
//   [u32 value_len]   big-endian   followed by value_len  bytes
//   [u32 error_len]   big-endian   followed by error_len  bytes
//
// `cynic_parse` reuses the frame: `value` carries a bytecode
// disassembly, `stdout` is empty.

'use strict';

const SAMPLES = {
  'Hello, strict world': `// Cynic is strict-only — every script runs in strict mode.
console.log("hello from cynic");
const answer = 6 * 7;
answer;`,

  'TDZ ReferenceError': `// let / const bindings sit in the Temporal Dead Zone until
// initialised. Touching one early is a ReferenceError, exactly
// like the spec asked (ECMA-262 §13.3.1).
try {
  console.log(tooEarly);
  let tooEarly = 1;
} catch (e) {
  console.log(e.name + ": " + e.message);
}`,

  'Proxy trap': `// A Proxy with a get trap that logs every property read.
const watched = new Proxy(
  { x: 10, y: 20 },
  {
    get(target, key) {
      console.log("read:", key);
      return Reflect.get(target, key);
    },
  },
);
watched.x + watched.y;`,

  'Generator': `// Generators suspend and resume. This one is an infinite
// counter; we pull the first five values out by hand.
function* counter() {
  let n = 0;
  while (true) yield n++;
}
const it = counter();
const five = [];
for (let i = 0; i < 5; i++) five.push(it.next().value);
five.join(", ");`,

  'Frozen object throws': `// Strict mode turns a silent failure into a TypeError:
// writing to a frozen object's property is a hard error.
"use strict";
const frozen = Object.freeze({ locked: true });
try {
  frozen.locked = false;
} catch (e) {
  console.log(e.name + ": cannot write to a frozen object");
}
frozen.locked;`,
};

const DEFAULT_SNIPPET = SAMPLES['Hello, strict world'];

const els = {
  editor: document.getElementById('editor'),
  run: document.getElementById('run'),
  share: document.getElementById('share'),
  inspector: document.getElementById('inspector'),
  status: document.getElementById('status'),
  output: document.getElementById('output'),
  outputLabel: document.getElementById('output-label'),
  snippets: document.getElementById('snippets'),
  version: document.getElementById('version'),
};

let wasm = null; // { instance, exports, memory }

// --------------------------------------------------------------------------
// WASM loading
// --------------------------------------------------------------------------

async function loadWasm() {
  setStatus('loading engine…');
  // The freestanding module imports nothing — the C shim routes
  // allocation back into the module itself. An empty import object
  // is all `instantiateStreaming` needs.
  const importObject = {};
  try {
    const result = await instantiateWasm(importObject);
    wasm = {
      instance: result.instance,
      exports: result.instance.exports,
      memory: result.instance.exports.memory,
    };
    els.version.textContent = readVersion();
    setStatus('ready');
    els.run.disabled = false;
  } catch (err) {
    setStatus('engine failed to load');
    renderError('Could not load cynic.wasm: ' + err);
    console.error(err);
  }
}

// Instantiate `cynic.wasm`. Prefer streaming compile, but fall
// back to a buffered fetch on ANY streaming failure — not just a
// missing `instantiateStreaming`. `instantiateStreaming` rejects
// when the server sends the wrong `Content-Type` (anything other
// than `application/wasm`), which happens on local static servers
// that don't know the `.wasm` MIME type. GitHub Pages serves it
// correctly, so the fallback is purely local-dev insurance.
async function instantiateWasm(importObject) {
  if (WebAssembly.instantiateStreaming) {
    try {
      return await WebAssembly.instantiateStreaming(
        fetch('cynic.wasm'),
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
  const bytes = await (await fetch('cynic.wasm')).arrayBuffer();
  return WebAssembly.instantiate(bytes, importObject);
}

function readVersion() {
  const ex = wasm.exports;
  if (!ex.cynic_version_ptr || !ex.cynic_version_len) return 'cynic-wasm';
  const ptr = ex.cynic_version_ptr();
  const len = ex.cynic_version_len();
  return new TextDecoder().decode(
    new Uint8Array(wasm.memory.buffer, ptr, len),
  );
}

// --------------------------------------------------------------------------
// Calling into the engine
// --------------------------------------------------------------------------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Run `source` through one of the engine's two entry points and
// return the parsed result frame.
function callEngine(exportName, source) {
  const ex = wasm.exports;
  const bytes = encoder.encode(source);
  const ptr = ex.cynic_alloc(bytes.length);
  if (ptr === 0) throw new Error('cynic_alloc returned null');

  try {
    // Re-view memory each time — `memory.grow` inside the call can
    // detach the previous ArrayBuffer.
    new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
    ex[exportName](ptr, bytes.length);
    return readFrame();
  } finally {
    ex.cynic_free(ptr, bytes.length);
  }
}

// Decode the framed result buffer the engine left behind.
function readFrame() {
  const ex = wasm.exports;
  const framePtr = ex.cynic_result_ptr();
  const frameLen = ex.cynic_result_len();
  if (framePtr === 0 || frameLen === 0) {
    return { status: -1, stdout: '', value: '', error: 'engine returned no result' };
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

  return {
    status,
    stdout: section(),
    value: section(),
    error: section(),
  };
}

// --------------------------------------------------------------------------
// Rendering
// --------------------------------------------------------------------------

function setStatus(text) {
  els.status.textContent = text;
}

function clearOutput() {
  els.output.textContent = '';
}

function appendLine(text, cls) {
  const span = document.createElement('span');
  span.className = cls;
  span.textContent = text;
  els.output.appendChild(span);
}

function renderError(text) {
  clearOutput();
  appendLine(text, 'out-error');
}

function renderEvalResult(frame) {
  clearOutput();
  els.outputLabel.textContent = 'output';

  let printedAnything = false;

  if (frame.stdout.length > 0) {
    // The engine terminates each console.log line with \n; show
    // it verbatim, trimming only the single trailing newline.
    appendLine(frame.stdout.replace(/\n$/, ''), 'out-stdout');
    printedAnything = true;
  }

  if (frame.status === 0) {
    if (frame.value.length > 0) {
      appendLine((printedAnything ? '\n' : '') + frame.value, 'out-value');
      printedAnything = true;
    }
  } else {
    // status 1 (throw) or 2 (parse/compile error).
    appendLine(
      (printedAnything ? '\n' : '') + (frame.error || 'unknown error'),
      'out-error',
    );
    printedAnything = true;
  }

  if (!printedAnything) {
    appendLine('(no output — the script produced undefined)', 'out-empty');
  }
}

function renderInspectorResult(frame) {
  clearOutput();
  els.outputLabel.textContent = 'bytecode disassembly';
  if (frame.status === 0 && frame.value.length > 0) {
    appendLine(frame.value, 'out-stdout');
  } else {
    appendLine(frame.error || 'could not disassemble', 'out-error');
  }
}

// --------------------------------------------------------------------------
// Actions
// --------------------------------------------------------------------------

function run() {
  if (!wasm) return;
  const source = els.editor.value;
  setStatus('running…');
  try {
    if (els.inspector.checked) {
      renderInspectorResult(callEngine('cynic_parse', source));
    } else {
      renderEvalResult(callEngine('cynic_eval', source));
    }
    setStatus('ready');
  } catch (err) {
    renderError('Engine call failed: ' + err);
    setStatus('error');
    console.error(err);
  }
}

// --------------------------------------------------------------------------
// Shareable URL — the editor source is base64'd into location.hash.
// --------------------------------------------------------------------------

function encodeSource(source) {
  // UTF-8 safe base64: encode to bytes, then to a binary string.
  const bytes = encoder.encode(source);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function decodeSource(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return decoder.decode(bytes);
}

function shareLink() {
  const hash = '#code=' + encodeURIComponent(encodeSource(els.editor.value));
  const url = location.origin + location.pathname + hash;
  history.replaceState(null, '', hash);
  navigator.clipboard?.writeText(url).then(
    () => setStatus('link copied to clipboard'),
    () => setStatus('link in address bar'),
  );
}

function seedFromHash() {
  const m = location.hash.match(/[#&]code=([^&]+)/);
  if (m) {
    try {
      return decodeSource(decodeURIComponent(m[1]));
    } catch (err) {
      console.warn('bad #code hash:', err);
    }
  }
  return null;
}

// --------------------------------------------------------------------------
// Editor wiring
// --------------------------------------------------------------------------

function wireEditor() {
  // Tab inserts two spaces rather than moving focus.
  els.editor.addEventListener('keydown', (e) => {
    if (e.key === 'Tab') {
      e.preventDefault();
      const start = els.editor.selectionStart;
      const end = els.editor.selectionEnd;
      const v = els.editor.value;
      els.editor.value = v.slice(0, start) + '  ' + v.slice(end);
      els.editor.selectionStart = els.editor.selectionEnd = start + 2;
    }
    // Ctrl/Cmd+Enter runs.
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      run();
    }
  });
}

function wireSnippets() {
  for (const name of Object.keys(SAMPLES)) {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = name;
    els.snippets.appendChild(opt);
  }
  els.snippets.addEventListener('change', () => {
    const name = els.snippets.value;
    if (name && SAMPLES[name]) {
      els.editor.value = SAMPLES[name];
      els.snippets.value = '';
      els.editor.focus();
    }
  });
}

// --------------------------------------------------------------------------
// Init
// --------------------------------------------------------------------------

function init() {
  els.run.disabled = true;
  els.editor.value = seedFromHash() || DEFAULT_SNIPPET;
  wireEditor();
  wireSnippets();
  els.run.addEventListener('click', run);
  els.share.addEventListener('click', shareLink);
  els.inspector.addEventListener('change', () => {
    if (wasm) run();
  });
  loadWasm();
}

init();
