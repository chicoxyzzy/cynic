// Cynic playground front-end.
//
// Streams + instantiates `cynic.wasm` (the wasm32-freestanding
// engine built by `zig build wasm`), marshals editor source into
// the module via `cynic_alloc`, runs it through `cynic_eval`, and
// renders the framed result.
//
// The editor is CodeMirror 6, vendored offline as a single
// committed bundle (`codemirror.bundle.js`) — Cynic is SES-aligned,
// so the playground pulls no third-party code at load time. See
// codemirror.bundle.README.md for the pinned versions + regenerate
// command.
//
// The WASM result frame layout (see src/wasm.zig):
//   [u8  status]      0 ok | 1 uncaught throw | 2 parse/compile error
//   [u32 stdout_len]  big-endian   followed by stdout_len bytes
//   [u32 value_len]   big-endian   followed by value_len  bytes
//   [u32 error_len]   big-endian   followed by error_len  bytes
//
// `cynic_parse` reuses the frame: `value` carries a bytecode
// disassembly, `stdout` is empty.

import {
  EditorState,
  EditorView,
  StateField,
  StateEffect,
  Decoration,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  history,
  defaultKeymap,
  historyKeymap,
  indentWithTab,
  syntaxHighlighting,
  HighlightStyle,
  indentUnit,
  javascript,
  tags as t,
} from './codemirror.bundle.js';

// ES modules are strict by definition — no `'use strict'` directive
// needed (and it would be invalid after the import statements).

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
  editorHost: document.getElementById('editor-host'),
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
let view = null; // the CodeMirror EditorView

// --------------------------------------------------------------------------
// CodeMirror editor
// --------------------------------------------------------------------------

// A StateEffect carries a `{from, to}` source range (or null to
// clear). The StateField below folds it into a DecorationSet so the
// bytecode-inspector hover-link can highlight source independently
// of the user's real selection — no .focus() needed.
const setHotRange = StateEffect.define();

// A single yellow mark over the hovered instruction's source span.
const hotMark = Decoration.mark({ class: 'cm-hot' });

const hotRangeField = StateField.define({
  create() {
    return Decoration.none;
  },
  update(deco, tr) {
    // Map existing decorations through any document change first.
    deco = deco.map(tr.changes);
    for (const e of tr.effects) {
      if (e.is(setHotRange)) {
        deco =
          e.value === null
            ? Decoration.none
            : Decoration.set([hotMark.range(e.value.from, e.value.to)]);
      }
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// Editor theme — paints the playground palette onto CodeMirror.
// CSS custom properties resolve against :root, so the Simpsons
// palette in playground.html drives these too.
const cynicTheme = EditorView.theme({
  '&': {
    color: 'var(--ink)',
    backgroundColor: 'var(--paper)',
    height: '100%',
    fontSize: '14px',
  },
  '.cm-content': {
    fontFamily: 'var(--mono)',
    caretColor: 'var(--ink)',
    padding: '12px 0',
  },
  '.cm-scroller': { fontFamily: 'var(--mono)', lineHeight: '1.5' },
  '&.cm-focused': { outline: '2px solid var(--marge)', outlineOffset: '-2px' },
  '.cm-gutters': {
    backgroundColor: 'var(--paper)',
    color: 'var(--ink-soft)',
    border: 'none',
    borderRight: '2px dashed rgba(0, 0, 0, 0.18)',
  },
  '.cm-activeLine': { backgroundColor: 'rgba(255, 213, 33, 0.22)' },
  '.cm-activeLineGutter': { backgroundColor: 'rgba(255, 213, 33, 0.30)' },
  '.cm-cursor': { borderLeftColor: 'var(--ink)' },
  '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': {
    backgroundColor: 'rgba(17, 166, 214, 0.30)',
  },
  // The bytecode-inspector hover-link decoration.
  '.cm-hot': {
    backgroundColor: 'var(--skin)',
    borderRadius: '2px',
  },
});

// Syntax highlighting tuned to the playground palette.
const cynicHighlight = HighlightStyle.define([
  { tag: t.keyword, color: '#9b1d8f', fontWeight: '700' },
  { tag: [t.controlKeyword, t.moduleKeyword], color: '#9b1d8f', fontWeight: '700' },
  { tag: [t.name, t.deleted, t.character, t.macroName], color: 'var(--ink)' },
  { tag: [t.propertyName], color: '#0d7a8a' },
  { tag: [t.function(t.variableName), t.labelName], color: '#1a64b8' },
  { tag: [t.string, t.special(t.string)], color: '#1f7a2e' },
  { tag: [t.number, t.bool, t.null], color: '#b5500f' },
  { tag: [t.comment, t.lineComment, t.blockComment], color: 'var(--ink-soft)', fontStyle: 'italic' },
  { tag: [t.operator, t.operatorKeyword], color: '#6a3d00' },
  { tag: [t.punctuation, t.separator, t.bracket], color: 'var(--ink-soft)' },
  { tag: [t.typeName, t.className], color: '#1a64b8' },
  { tag: t.regexp, color: '#b5500f' },
  { tag: t.invalid, color: 'var(--bart)' },
]);

function createEditor(initialDoc) {
  const runShortcut = {
    // Ctrl/Cmd+Enter runs — matches the old textarea binding.
    key: 'Mod-Enter',
    run: () => {
      run();
      return true;
    },
  };

  view = new EditorView({
    parent: els.editorHost,
    state: EditorState.create({
      doc: initialDoc,
      extensions: [
        lineNumbers(),
        highlightActiveLine(),
        highlightActiveLineGutter(),
        history(),
        javascript(),
        syntaxHighlighting(cynicHighlight),
        indentUnit.of('  '),
        hotRangeField,
        keymap.of([runShortcut, indentWithTab, ...defaultKeymap, ...historyKeymap]),
        cynicTheme,
        EditorState.tabSize.of(2),
      ],
    }),
  });
}

// The editor's text is the document string.
function getSource() {
  return view.state.doc.toString();
}

// Replace the whole document via a transaction.
function setSource(text) {
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
  });
}

// Highlight a source range in the editor (or clear it with null).
function setEditorHotRange(range) {
  if (!view) return;
  view.dispatch({ effects: setHotRange.of(range) });
}

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

// --------------------------------------------------------------------------
// Bytecode inspector — disassembly with a CodeMirror hover-link
// --------------------------------------------------------------------------

// The engine's `[start..end]` spans are UTF-8 byte offsets; the
// CodeMirror document is indexed in UTF-16 code units. Build a
// byte-offset -> code-unit-index map for `source` once per
// disassembly. `map[b]` is the code-unit index of the character
// that starts at byte `b`; bytes inside a multi-byte sequence are
// left pointing at the start of that character. `map` has
// `byteLength + 1` entries so an end-offset at EOF maps cleanly.
function buildByteToCodeUnitMap(source) {
  const bytes = encoder.encode(source);
  const map = new Uint32Array(bytes.length + 1);
  let codeUnit = 0;
  let b = 0;
  for (const ch of source) {
    // `ch` is one Unicode code point; its UTF-16 length is 1 or 2.
    const utf16Len = ch.length;
    const utf8Len = encoder.encode(ch).length;
    for (let k = 0; k < utf8Len; k++) map[b + k] = codeUnit;
    b += utf8Len;
    codeUnit += utf16Len;
  }
  map[bytes.length] = codeUnit;
  return map;
}

// Match a trailing ` [start..end]` source span on a disasm line.
const SPAN_RE = /\[(\d+)\.\.(\d+)\]\s*$/;

function renderInspectorResult(frame) {
  clearOutput();
  els.outputLabel.textContent = 'bytecode disassembly';
  setEditorHotRange(null);

  if (frame.status !== 0 || frame.value.length === 0) {
    appendLine(frame.error || 'could not disassemble', 'out-error');
    return;
  }

  // The hover-link maps byte offsets in the *source the engine
  // disassembled* — that's the current editor document.
  const byteToCodeUnit = buildByteToCodeUnitMap(getSource());
  const docLength = view.state.doc.length;

  const lines = frame.value.split('\n');
  for (const line of lines) {
    const el = document.createElement('span');
    el.className = 'bc-line out-stdout';
    el.textContent = line + '\n';

    const m = line.match(SPAN_RE);
    if (m) {
      // The `(chunk …` header and the closing `)` carry no span —
      // only real instruction lines reach here.
      const startByte = Number(m[1]);
      const endByte = Number(m[2]);
      let from = byteToCodeUnit[Math.min(startByte, byteToCodeUnit.length - 1)];
      let to = byteToCodeUnit[Math.min(endByte, byteToCodeUnit.length - 1)];
      // Clamp into the live document, just in case.
      from = Math.max(0, Math.min(from, docLength));
      to = Math.max(from, Math.min(to, docLength));

      el.classList.add('bc-hot');
      el.dataset.from = String(from);
      el.dataset.to = String(to);
    }

    els.output.appendChild(el);
  }
}

// Hovering a `.bc-hot` instruction line marks the matching source
// range in CodeMirror. The mark is a StateField decoration — it
// does not touch the user's real selection and needs no .focus().
function wireInspectorHover() {
  els.output.addEventListener('mouseover', (e) => {
    const hot = e.target.closest('.bc-hot');
    if (!hot || !els.output.contains(hot)) return;
    const from = Number(hot.dataset.from);
    const to = Number(hot.dataset.to);
    if (Number.isFinite(from) && Number.isFinite(to) && to > from) {
      setEditorHotRange({ from, to });
    }
  });
  // Pointer leaving the output panel entirely clears the link.
  els.output.addEventListener('mouseleave', () => {
    setEditorHotRange(null);
  });
}

// --------------------------------------------------------------------------
// Actions
// --------------------------------------------------------------------------

function run() {
  if (!wasm) return;
  const source = getSource();
  setStatus('running…');
  try {
    if (els.inspector.checked) {
      renderInspectorResult(callEngine('cynic_parse', source));
    } else {
      setEditorHotRange(null);
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
  const hash = '#code=' + encodeURIComponent(encodeSource(getSource()));
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
// Sample snippets
// --------------------------------------------------------------------------

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
      setSource(SAMPLES[name]);
      els.snippets.value = '';
      view.focus();
    }
  });
}

// --------------------------------------------------------------------------
// Init
// --------------------------------------------------------------------------

function init() {
  els.run.disabled = true;
  createEditor(seedFromHash() || DEFAULT_SNIPPET);
  wireSnippets();
  wireInspectorHover();
  els.run.addEventListener('click', run);
  els.share.addEventListener('click', shareLink);
  els.inspector.addEventListener('change', () => {
    if (wasm) run();
  });
  loadWasm();
}

init();
