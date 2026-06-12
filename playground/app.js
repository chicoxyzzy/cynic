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

// The engine half — the WASM ABI binding. Built + published alongside
// `cynic.wasm` by the engine's CI; this UI only sees the stable API.
import {
  loadEngine,
  engineVersion,
  evalSource,
  parseSource,
  parseAst,
} from './cynic-engine.js';

// ES modules are strict by definition — no `'use strict'` directive
// needed (and it would be invalid after the import statements).

// UI-side codecs for byte ↔ code-unit span mapping (disasm / AST
// hover). Independent of the engine glue's own encoder/decoder.
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const SAMPLES = {
  'Hello, strict world': `// Cynic is strict-only — every script runs in strict mode.
// The directive is a no-op here, but kept as a hint to anyone
// copy-pasting this into another engine.
"use strict";
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

  'Hardened by default': `// Cynic freezes the primordials at realm init — no lockdown()
// call, no SES import. Monkey-patching a built-in prototype throws
// on contact; the real method still works.
"use strict";
try {
  Array.prototype.push = () => "hijacked";
} catch (e) {
  console.log(e.name + " — Array.prototype is frozen");
}
console.log("Object.isFrozen(Array.prototype):", Object.isFrozen(Array.prototype));
[1, 2, 3].push(4);`,

  'BigInt — arbitrary precision': `// BigInt is sign-magnitude with a u64 limb array — same
// representation V8 / JSC ship. Below: 100! computed exactly,
// no rounding, no Infinity.
let n = 1n;
for (let i = 2n; i <= 100n; i++) n *= i;
console.log("100! =");
console.log(n.toString());
n.toString().length + " digits";`,

  'RegExp — named groups, lookbehind': `// Full ECMA-262 RegExp (§22.2) — named groups, lookbehind,
// Unicode property escapes, /v set notation. No Annex B leniency.
"use strict";
const m = "2026-05-31".match(/(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})/);
console.log("named: " + m.groups.year + "-" + m.groups.month + "-" + m.groups.day);
console.log("lookbehind: " + "total $42.00".match(/(?<=\\$)\\d+/)[0]);
console.log("script: " + "Δabc".match(/\\p{Script=Greek}/u)[0]);
"abc".match(/[\\p{Letter}--[b]]/v)[0];`,

  'Temporal — date arithmetic': `// Temporal — date/time math without the Date footguns. Adding
// a month to May 31 clamps to June 30; there is no June 31 to
// overflow into.
"use strict";
const d = Temporal.PlainDate.from("2026-05-31");
console.log("date: " + d.toString());
console.log("plus 1mo: " + d.add({ months: 1 }).toString());
const dur = Temporal.Duration.from({ hours: 2, minutes: 30 });
"duration: " + dur.toString();`,

  'Iterator helpers': `// Iterator.prototype.{map,filter,take,toArray} — the
// pre-Stage-4 iterator-helper proposal, lazy by construction.
function* nats() { let n = 1; while (true) yield n++; }
nats()
  .map(n => n * n)
  .filter(n => n % 2 === 1)
  .take(5)
  .toArray();`,

  'Map upsert — getOrInsert': `// Map.prototype.getOrInsertComputed runs the factory only when
// the key is absent, so building a multimap drops the
// has()/get()/set() dance. Stage 4 as of 2026-05 (§24.1.3.8).
"use strict";
const groups = new Map();
for (const word of ["ant", "bee", "ark", "bat", "cat"]) {
  groups.getOrInsertComputed(word[0], () => []).push(word);
}
JSON.stringify([...groups]);`,

  'Object.groupBy — bucketing': `// Object.groupBy bins items by a classifier's return value
// (Object.groupBy / Map.groupBy, ES2024). No reduce(), no
// manual bucket initialisation.
"use strict";
const groups = Object.groupBy([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], (n) => {
  if (n % 15 === 0) return "fizzbuzz";
  if (n % 3 === 0) return "fizz";
  if (n % 5 === 0) return "buzz";
  return "plain";
});
JSON.stringify(groups);`,

  'Async + microtasks': `// .then defers; await yields. The log order proves the
// microtask queue runs spec-correctly (ECMA-262 §9.4).
console.log("1 — sync");
Promise.resolve().then(() => console.log("3 — microtask"));
(async () => {
  console.log("2 — async body (sync prefix)");
  await null;
  console.log("4 — after await");
})();
"queued";`,

  'Class + private field': `// Private fields (#x) live in a separate slot the property
// bag can't see. Cross-instance access is a TypeError.
class Counter {
  #n = 0;
  inc() { this.#n++; return this; }
  get value() { return this.#n; }
}
const c = new Counter().inc().inc().inc();
\`value = \${c.value}\`;`,

  'using — deterministic cleanup': `// Explicit Resource Management — a using declaration runs the
// value's [Symbol.dispose] when the scope exits, in reverse order.
// The finally block you keep forgetting to write.
"use strict";
const log = [];
function open(name) {
  return { [Symbol.dispose]() { log.push("close " + name); } };
}
{
  using a = open("a");
  using b = open("b");
  log.push("body runs");
}
log.push("scope exited");
log.join(" -> ");`,

  'WeakRef — genuinely weak': `// WeakRef holds a target without keeping it alive. Spec quirk
// (§9.10): the ctor pins the target until the next job boundary,
// so drop + GC have to happen in a follow-up microtask.
"use strict";
let target = { tag: "doomed" };
const ref = new WeakRef(target);
console.log("before:", ref.deref()?.tag);
target = null;

Promise.resolve().then(() => {
  // 200k allocations force a GC cycle.
  for (let i = 0; i < 200000; i++) ({ k: i });
  console.log("after:", ref.deref()?.tag ?? "collected");
});
"queued";`,

  'Proper Tail Calls': `// ES2015 §15.10 — a call in tail position reuses the caller's
// frame instead of pushing a fresh one. Recursing 100,000 deep
// without PTC would overflow the 1024-frame dispatch stack;
// here it lands cleanly because each \`return f(...)\` is a
// frame reuse, not a frame push. Second engine after
// JavaScriptCore to ship this. Error.stack is shorter as a
// result — that's the deal the spec wrote down.
//
// "use strict" is mandatory per spec — PTC only fires in strict
// code. Cynic is always strict so the directive is redundant here,
// but copying this to JSC (the only other shipping engine) needs
// it to work.
"use strict";
function loop(n, acc) {
  return n === 0 ? acc : loop(n - 1, acc + 1);
}
loop(100000, 0);`,
};

const DEFAULT_SNIPPET = SAMPLES['Hello, strict world'];

const els = {
  editorHost: document.getElementById('editor-host'),
  run: document.getElementById('run'),
  share: document.getElementById('share'),
  status: document.getElementById('status'),
  output: document.getElementById('output'),
  spanEdgeUp: document.getElementById('span-edge-up'),
  spanEdgeDown: document.getElementById('span-edge-down'),
  snippets: document.getElementById('snippets'),
  version: document.getElementById('version'),
  unhardened: document.getElementById('unhardened'),
  modeTabs: Array.from(document.querySelectorAll('.mode-tab')),
};

let view = null;   // the CodeMirror EditorView
let currentMode = 'eval'; // 'eval' | 'bytecode' | 'ast' — driven by the right-panel tabs
let engineReady = false;  // set once cynic-engine.js's loadEngine() resolves

// --------------------------------------------------------------------------
// CodeMirror editor
// --------------------------------------------------------------------------

// A StateEffect carries a `{from, to}` source range (or null to
// clear). The StateField below folds it into a DecorationSet so the
// bytecode-inspector hover-link can highlight source independently
// of the user's real selection — no .focus() needed.
const setHotRange = StateEffect.define();

// A second effect carries the error-range to underline. Separate from
// the hot-range so a hover doesn't clobber an error squiggle and an
// error doesn't compete with a hover. The two ride parallel fields,
// not a single combined one, to keep the update logic obvious.
const setErrorRange = StateEffect.define();

// A single yellow mark over the hovered instruction's source span.
const hotMark = Decoration.mark({ class: 'cm-hot' });
// A red wavy underline over the source range a parse / runtime error
// fingers — TypeScript-playground style.
const errorMark = Decoration.mark({ class: 'cm-error-range' });

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

// Error squiggles auto-clear the moment the user touches the source
// (the diagnostic was about the *previous* state of the document).
// Hover marks deliberately don't — they live only as long as the
// pointer hovers the disasm line.
const errorRangeField = StateField.define({
  create() {
    return Decoration.none;
  },
  update(deco, tr) {
    if (tr.docChanged) return Decoration.none;
    for (const e of tr.effects) {
      if (e.is(setErrorRange)) {
        deco =
          e.value === null
            ? Decoration.none
            : Decoration.set([errorMark.range(e.value.from, e.value.to)]);
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
  // Parse / runtime error range — wavy red underline. The SVG data
  // URI ships its own colour so the squiggle stays legible against
  // the paper background regardless of the syntax-highlight palette.
  '.cm-error-range': {
    backgroundImage:
      'url("data:image/svg+xml;utf8,' +
      '<svg xmlns=%22http://www.w3.org/2000/svg%22 width=%224%22 height=%223%22>' +
      '<path d=%22M0,2 Q1,0 2,2 T4,2%22 stroke=%22%23c91414%22 fill=%22none%22 stroke-width=%221%22/>' +
      '</svg>")',
    backgroundRepeat: 'repeat-x',
    backgroundPosition: 'left bottom',
    paddingBottom: '2px',
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
        errorRangeField,
        keymap.of([runShortcut, indentWithTab, ...defaultKeymap, ...historyKeymap]),
        cynicTheme,
        EditorState.tabSize.of(2),
        // Mirror every document edit to localStorage (debounced) so a
        // reload restores the draft. See scheduleSave / loadSaved.
        EditorView.updateListener.of((update) => {
          if (update.docChanged) scheduleSave();
        }),
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

// Mark a source range with the error squiggle (or clear it with null).
function setEditorErrorRange(range) {
  if (!view) return;
  view.dispatch({ effects: setErrorRange.of(range) });
}

// Translate a frame's byte-offset span into the editor's code-unit
// range. Returns null if the span is null, empty, or falls outside
// the current document. The byteToCodeUnit map is shared with the
// disasm hover-link so the conversion stays consistent.
function frameSpanToEditorRange(errorSpan) {
  if (!errorSpan) return null;
  const map = buildByteToCodeUnitMap(getSource());
  const startByte = Math.min(errorSpan.startByte, map.length - 1);
  const endByte = Math.min(errorSpan.endByte, map.length - 1);
  const docLength = view.state.doc.length;
  let from = Math.max(0, Math.min(map[startByte], docLength));
  let to = Math.max(from, Math.min(map[endByte], docLength));
  return to > from ? { from, to } : null;
}

// --------------------------------------------------------------------------
// WASM loading
// --------------------------------------------------------------------------

// Load the engine (the WASM ABI lives in `cynic-engine.js`) and wire
// the load result into the UI. Pure engine plumbing stays in the glue
// module; this only owns the status / version / run-button display.
async function loadWasm() {
  setStatus('loading engine…');
  try {
    await loadEngine();
    engineReady = true;
    els.version.textContent = engineVersion();
    setStatus('ready');
    els.run.disabled = false;
  } catch (err) {
    setStatus('engine failed to load');
    renderError('Could not load cynic.wasm: ' + err);
    console.error(err);
  }
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
  setEditorErrorRange(null);
  appendLine(text, 'out-error');
}

function renderEvalResult(frame) {
  clearOutput();
  lastSpanLines = [];

  let printedAnything = false;

  if (frame.stdout.length > 0) {
    // The engine terminates each console.log line with \n; show
    // it verbatim, trimming only the single trailing newline.
    appendLine(frame.stdout.replace(/\n$/, ''), 'out-stdout');
    printedAnything = true;
  }

  if (frame.status === 0) {
    setEditorErrorRange(null);
    if (frame.value.length > 0) {
      // Each segment is its own block (see the .out-* CSS), so the
      // value sits on its own line under stdout. No leading-"\n"
      // hack — that put the ::before "⇒ " marker at the tail of the
      // previous stdout line instead of at the start of this one.
      appendLine(frame.value, 'out-value');
      printedAnything = true;
    }
  } else {
    // status 1 (throw) or 2 (parse/compile error). Underline the
    // source range the engine fingered, if it surfaced one.
    setEditorErrorRange(frameSpanToEditorRange(frame.errorSpan));
    appendLine(frame.error || 'unknown error', 'out-error');
    printedAnything = true;
  }

  if (!printedAnything) {
    appendLine('(no output — the script produced undefined)', 'out-empty');
  }

  // Runtime stats footer — chunk shape + GC totals the engine reports
  // after a successful run or an uncaught throw. Empty on parse/compile
  // errors and on older WASM bundles (cynic-engine.js defaults the
  // field to ''), so the footer is conditional.
  if (frame.stats && frame.stats.length > 0) {
    appendLine(frame.stats, 'out-stats');
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

// Match the first ` [start..end]` source span on an inspector line.
// Bytecode disasm always trails the span; the AST printer embeds it
// mid-line (a closing `)` may follow) — so we match the *first* span
// per line rather than anchoring to end-of-line.
const SPAN_RE = /\s?\[(\d+)\.\.(\d+)\]/;

// Pull the first `[start..end]` span off an inspector line, returning
// the span's byte offsets plus the line text with that span removed
// (including any single space that preceded it, so the cleaned text
// doesn't have a stray gap). Returns `{ line, span: null }` if the
// line carries no span — header / closing-paren lines included.
function extractSpan(rawLine) {
  const m = rawLine.match(SPAN_RE);
  if (!m) return { line: rawLine, span: null };
  const startByte = Number(m[1]);
  const endByte = Number(m[2]);
  const cleaned = rawLine.slice(0, m.index) + rawLine.slice(m.index + m[0].length);
  return { line: cleaned, span: { startByte, endByte } };
}

// Disasm-line token classification. Patterns match the format
// produced by `src/bytecode/disasm.zig` — keep both sides in sync
// when adding a new operand shape. The line text reaching the
// tokenizer has already had its trailing `[start..end]` span
// stripped (see `extractSpan`); no span group needed here.
//   • 4-hex-digit offset at line start (`0005`)
//   • Mnemonic — UpperCamelCase identifier
//   • Register / index sigils: `r0`, `k1`, `t2`, `c0`, `s5`, `^1`
//   • Jump form: `+12 -> 0024` / `-5 -> 0010`
const DISASM_TOKEN_RE = new RegExp(
  [
    '(?<offset>^[0-9a-f]{4})',            // 0005
    '(?<mnem>\\b[A-Z][A-Za-z]+\\b)',      // LdaSmi, JmpIfFalse, …
    '(?<reg>\\br[0-9]+\\b)',              // r0, r12
    '(?<index>\\b[kctsi][0-9]+\\b)',      // k1, t0, c2, s5
    '(?<envdepth>\\^[0-9]+)',             // ^1 (lda_env / sta_env)
    '(?<jump>[+-]\\d+\\s*->\\s*[0-9a-f]{4})', // +12 -> 0024
    '(?<num>[+-]?\\b\\d+\\b)',            // 42
    '(?<paren>\\([^)]*\\))',              // (2 args), (chunk …)
  ].join('|'),
  'g',
);

function appendDisasmTokens(parent, line) {
  let last = 0;
  for (const m of line.matchAll(DISASM_TOKEN_RE)) {
    if (m.index > last) {
      parent.appendChild(document.createTextNode(line.slice(last, m.index)));
    }
    const token = m[0];
    const span = document.createElement('span');
    const cls =
      m.groups.offset    ? 'bc-tok-offset' :
      m.groups.mnem      ? 'bc-tok-mnem' :
      m.groups.reg       ? 'bc-tok-reg' :
      m.groups.index     ? 'bc-tok-index' :
      m.groups.envdepth  ? 'bc-tok-index' :
      m.groups.jump      ? 'bc-tok-jump' :
      m.groups.num       ? 'bc-tok-num' :
      m.groups.paren     ? 'bc-tok-paren' :
      '';
    if (cls) span.className = cls;
    span.textContent = token;
    parent.appendChild(span);
    last = m.index + token.length;
  }
  if (last < line.length) {
    parent.appendChild(document.createTextNode(line.slice(last)));
  }
  parent.appendChild(document.createTextNode('\n'));
}

// AST printer token classification — output shape lives in
// `src/ast/printer.zig`. Cleaned line (span already stripped by
// `extractSpan`) has these atoms:
//   • `(head` — opening paren glued to a node name (e.g. `(program`,
//     `(expr-stmt`). We split this into a paren + head pair so the
//     head can take the keyword colour without breaking the paren run.
//   • One or more closing parens `)))`.
//   • `key=value` attribute pair (`op=+`, `kind=let_`).
//   • Quoted source slice — `"x"`, `"100"`.
//   • Bare integer (rare — kept for future printer additions).
//   • Bare lowercase identifier — e.g. `script` after `(program`.
const AST_TOKEN_RE = new RegExp(
  [
    '(?<openhead>\\([a-z][a-zA-Z0-9-]*)',           // (program, (expr-stmt
    '(?<closeparen>\\)+)',                          // ), )))
    '(?<attr>\\b[a-z_][\\w-]*=\\S+)',               // op=+, kind=let_, source_kind=script
    '(?<string>"(?:[^"\\\\]|\\\\.)*")',         // "x"
    '(?<num>[+-]?\\b\\d+\\b)',                      // 1, -2
    '(?<ident>[a-z][a-zA-Z0-9_-]*)',                // script, identifier
  ].join('|'),
  'g',
);

function appendAstTokens(parent, line) {
  let last = 0;
  for (const m of line.matchAll(AST_TOKEN_RE)) {
    if (m.index > last) {
      parent.appendChild(document.createTextNode(line.slice(last, m.index)));
    }
    const token = m[0];
    if (m.groups.openhead) {
      // Split `(program` into a paren span and a head span so the
      // colours pick up the role rather than the glued shape.
      const paren = document.createElement('span');
      paren.className = 'ast-tok-paren';
      paren.textContent = '(';
      parent.appendChild(paren);
      const head = document.createElement('span');
      head.className = 'ast-tok-head';
      head.textContent = token.slice(1);
      parent.appendChild(head);
    } else {
      const span = document.createElement('span');
      const cls =
        m.groups.closeparen ? 'ast-tok-paren' :
        m.groups.attr       ? 'ast-tok-attr' :
        m.groups.string     ? 'ast-tok-string' :
        m.groups.num        ? 'ast-tok-num' :
        m.groups.ident      ? 'ast-tok-ident' :
        '';
      if (cls) span.className = cls;
      span.textContent = token;
      parent.appendChild(span);
    }
    last = m.index + token.length;
  }
  if (last < line.length) {
    parent.appendChild(document.createTextNode(line.slice(last)));
  }
  parent.appendChild(document.createTextNode('\n'));
}

// Every span-bearing line element from the most recent inspector
// render, in source order — shared between bytecode and AST modes.
// Used by the reverse hover-link (mouse-in-editor -> highlight the
// matching output line) so we don't rescan the DOM on every
// mousemove. Reset on every render and on mode switch.
let lastSpanLines = [];

// Pin a span-bearing line element to its source range. Computes the
// CodeMirror code-unit range from the engine's UTF-8 byte span, tags
// the element with the shared `.span-line` class, and records it in
// `lastSpanLines` for the reverse hover-link. The element keeps its
// own mode-specific class (`.bc-line` / `.ast-line`) for layout.
function attachSpanToLine(el, span, byteToCodeUnit, docLength) {
  if (!span) return;
  let from = byteToCodeUnit[Math.min(span.startByte, byteToCodeUnit.length - 1)];
  let to = byteToCodeUnit[Math.min(span.endByte, byteToCodeUnit.length - 1)];
  from = Math.max(0, Math.min(from, docLength));
  to = Math.max(from, Math.min(to, docLength));
  if (to <= from) return;
  el.classList.add('span-line');
  el.dataset.from = String(from);
  el.dataset.to = String(to);
  lastSpanLines.push(el);
}

function renderInspectorResult(frame) {
  clearOutput();
  setEditorHotRange(null);
  lastSpanLines = [];

  if (frame.status !== 0 || frame.value.length === 0) {
    setEditorErrorRange(frameSpanToEditorRange(frame.errorSpan));
    appendLine(frame.error || 'could not disassemble', 'out-error');
    return;
  }
  setEditorErrorRange(null);

  // A one-line affordance hint: the inspector lines are hoverable in
  // both directions (line → source, source → line), which isn't
  // obvious at a glance. Muted so it never competes with the disasm.
  appendLine('Hover a line to highlight its source — or hover the source to find its line.', 'out-hint');

  // The hover-link maps byte offsets in the *source the engine
  // disassembled* — that's the current editor document.
  const byteToCodeUnit = buildByteToCodeUnitMap(getSource());
  const docLength = view.state.doc.length;

  const lines = frame.value.split('\n');
  for (const rawLine of lines) {
    const { line, span } = extractSpan(rawLine);
    const el = document.createElement('span');
    el.className = 'bc-line out-stdout';
    appendDisasmTokens(el, line);
    attachSpanToLine(el, span, byteToCodeUnit, docLength);
    els.output.appendChild(el);
  }
}

// Hovering a `.span-line` (bytecode instruction or AST node) marks
// the matching source range in CodeMirror. The mark is a StateField
// decoration — it does not touch the user's real selection and needs
// no .focus().
function wireInspectorHover() {
  els.output.addEventListener('mouseover', (e) => {
    const hot = e.target.closest('.span-line');
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

// Reverse direction of the hover-link: while the pointer is over the
// editor in bytecode or AST mode, light up the output lines whose
// source range contains the doc position under the cursor. Uses
// `view.posAtCoords` (CodeMirror's hit-test) and walks the cached
// `lastSpanLines` set; output DOM is at most a few hundred elements
// so a linear scan per mousemove is fine.
// Tracks the editor hot-range the reverse-hover last set, so we only
// dispatch a CodeMirror transaction when the highlighted span actually
// changes (mousemove fires per pixel; transactions are not free).
let lastSourceHotKey = null;

function wireSourceToSpanHover() {
  els.editorHost.addEventListener('mousemove', (e) => {
    if (lastSpanLines.length === 0) return;
    if (!view) return;
    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos == null) {
      clearSpanActive();
      return;
    }
    // First pass: find the narrowest span width that brackets the
    // cursor — the most-specific node / instruction. Ties (several
    // lines tagged with the same minimal span) share it.
    let best = null;
    let bestSize = Infinity;
    for (const el of lastSpanLines) {
      const from = Number(el.dataset.from);
      const to = Number(el.dataset.to);
      if (pos >= from && pos < to) {
        const size = to - from;
        if (size < bestSize) {
          bestSize = size;
          best = el;
        }
      }
    }
    // Second pass: tier the right panel. Lines tagged with the narrowest
    // span get the strong `.span-active`; wider enclosing spans get the
    // faint `.span-active-ancestor`. Every containing line still lights
    // up (the all-spans view is preserved), but depth is now legible —
    // hovering `console` makes its own load op strong and the call ops
    // it's nested inside faint, rather than all of them equal.
    const activeEls = [];
    for (const el of lastSpanLines) {
      const from = Number(el.dataset.from);
      const to = Number(el.dataset.to);
      const inside = pos >= from && pos < to;
      const primary = inside && to - from === bestSize;
      el.classList.toggle('span-active', primary);
      el.classList.toggle('span-active-ancestor', inside && !primary);
      if (inside) activeEls.push(el);
    }
    updateOffscreenHints(activeEls);
    // Left panel: mirror the narrowest containing span back onto the
    // source as the hot-range mark, so hovering the editor shows the
    // exact extent of the node / instruction under the cursor — not
    // just which output line it maps to. Reuses `setEditorHotRange`,
    // the same decoration the forward (right-panel) hover draws; the
    // pointer is only ever in one panel at a time, so they don't fight.
    const key = best ? `${best.dataset.from}:${best.dataset.to}` : null;
    if (key !== lastSourceHotKey) {
      lastSourceHotKey = key;
      setEditorHotRange(
        best
          ? { from: Number(best.dataset.from), to: Number(best.dataset.to) }
          : null,
      );
    }
    // No autoscroll. Auto-scrolling the output panel to reveal an
    // off-screen match read as a jolt; instead `updateOffscreenHints`
    // (above) flags the direction with an edge pill the reader can act
    // on at their own pace — the highlight stays in place.
  });
  els.editorHost.addEventListener('mouseleave', clearSpanActive);
}

// Toggle the top / bottom edge pills based on whether any highlighted
// output line sits outside the panel's visible scroll window. A pure
// hint — the pills are `pointer-events: none` and vanish with the
// highlight on mouse-leave, so the reader knows a match is up / down
// without anything moving under the cursor.
function updateOffscreenHints(activeEls) {
  if (!els.spanEdgeUp || !els.spanEdgeDown) return;
  let above = false;
  let below = false;
  if (activeEls.length > 0) {
    const view = els.output.getBoundingClientRect();
    for (const el of activeEls) {
      const r = el.getBoundingClientRect();
      if (r.bottom <= view.top + 1) above = true;
      else if (r.top >= view.bottom - 1) below = true;
    }
  }
  els.spanEdgeUp.hidden = !above;
  els.spanEdgeDown.hidden = !below;
}

function clearSpanActive() {
  for (const el of lastSpanLines) {
    el.classList.remove('span-active', 'span-active-ancestor');
  }
  if (lastSourceHotKey !== null) {
    lastSourceHotKey = null;
    setEditorHotRange(null);
  }
  if (els.spanEdgeUp) els.spanEdgeUp.hidden = true;
  if (els.spanEdgeDown) els.spanEdgeDown.hidden = true;
}

// --------------------------------------------------------------------------
// AST inspector — S-expression dump of the parser's AST. Each line is
// emitted as a `.span-line` with the AST printer's `[start..end]` span
// extracted into data-from / data-to, so the same hover-link machinery
// powers source↔AST cross-highlighting (the inner-most match wins on
// the reverse scan, since AST spans nest).
// --------------------------------------------------------------------------

function renderAstResult(frame) {
  clearOutput();
  setEditorHotRange(null);
  lastSpanLines = [];

  if (frame.status !== 0 || frame.value.length === 0) {
    setEditorErrorRange(frameSpanToEditorRange(frame.errorSpan));
    appendLine(frame.error || 'could not parse', 'out-error');
    return;
  }
  setEditorErrorRange(null);

  // Same hoverable-lines hint as the bytecode inspector (see
  // renderInspectorResult). AST nodes nest, so the reverse hover
  // resolves to the tightest enclosing span.
  appendLine('Hover a line to highlight its source — or hover the source to find its line.', 'out-hint');

  const byteToCodeUnit = buildByteToCodeUnitMap(getSource());
  const docLength = view.state.doc.length;

  const lines = frame.value.split('\n');
  for (const rawLine of lines) {
    const { line, span } = extractSpan(rawLine);
    const el = document.createElement('span');
    el.className = 'bc-line out-stdout';
    appendAstTokens(el, line);
    attachSpanToLine(el, span, byteToCodeUnit, docLength);
    els.output.appendChild(el);
  }
}

// --------------------------------------------------------------------------
// Actions
// --------------------------------------------------------------------------

function run() {
  if (!engineReady) return;
  const source = getSource();
  setStatus('running…');
  try {
    // Reset the hover-link decoration on every run — it's a stale
    // pointer otherwise (the disasm that produced it is gone in
    // eval / AST mode).
    setEditorHotRange(null);
    switch (currentMode) {
      case 'bytecode':
        renderInspectorResult(parseSource(source));
        break;
      case 'ast':
        renderAstResult(parseAst(source));
        break;
      case 'eval':
      default:
        // `hardened` defaults on; the toolbar toggle flips it off
        // (the `--unhardened` posture — mutable primordials).
        renderEvalResult(evalSource(source, { hardened: !els.unhardened?.checked }));
        break;
    }
    setStatus('ready');
  } catch (err) {
    renderError('Engine call failed: ' + err);
    setStatus('error');
    console.error(err);
  }
}

// Switch the active output mode and re-run. Called by the tab-row
// click handler; also responsible for visually flipping the
// aria-selected state across the tab buttons.
function setMode(mode) {
  if (mode === currentMode) return;
  currentMode = mode;
  for (const tab of els.modeTabs) {
    tab.setAttribute('aria-selected', tab.dataset.mode === mode ? 'true' : 'false');
  }
  // Keep the tabpanel's accessible name pointed at the active tab so a
  // screen reader announces the right mode when focus enters the
  // output region. Tab ids are `tab-<mode>` (see playground.html).
  els.output.setAttribute('aria-labelledby', 'tab-' + mode);
  // Switching modes invalidates any cached span-line state — the
  // output DOM is about to be replaced.
  lastSpanLines = [];
  if (engineReady) run();
}

function wireModeTabs() {
  for (const tab of els.modeTabs) {
    tab.addEventListener('click', () => setMode(tab.dataset.mode));
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
  // `history` (without `window.`) resolves to the CodeMirror
  // `history` extension imported at the top of this module — a
  // function with no `replaceState`. Without the explicit
  // `window.`, every click on Copy link throws
  // `TypeError: history.replaceState is not a function` and the
  // clipboard write never fires.
  window.history.replaceState(null, '', hash);
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
// Local autosave — the editor source is mirrored to localStorage so a
// reload restores the last-edited draft. A shared `#code=` hash (above)
// still wins on load; this is the fallback when there's no shared link.
// --------------------------------------------------------------------------

const STORAGE_KEY = 'cynic.playground.source';
let saveTimer = 0;

// Debounced: every keystroke fires the editor's update listener, but we
// only touch localStorage ~400ms after typing settles. localStorage
// writes are synchronous, so coalescing keeps them off the hot path.
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      localStorage.setItem(STORAGE_KEY, getSource());
    } catch (err) {
      // Private-mode / quota-exceeded / storage-disabled — autosave is
      // a convenience, never a hard dependency. Swallow and move on.
      console.warn('autosave write failed:', err);
    }
  }, 400);
}

function loadSaved() {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch (err) {
    console.warn('autosave read failed:', err);
    return null;
  }
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
      // Keep the selected option visible — used to reset to the
      // "— sample snippets —" placeholder, which made it impossible
      // to tell which snippet was loaded after picking.
      // The previous run's output is about to be stale — wipe it so
      // the user knows the next Run will reflect the new snippet. Same
      // resets we'd do on a fresh page load.
      clearOutput();
      setEditorHotRange(null);
      setEditorErrorRange(null);
      lastSpanLines = [];
      appendLine('Run something. Cynic will judge it.', 'out-empty');
      view.focus();
    }
  });
}

// --------------------------------------------------------------------------
// Init
// --------------------------------------------------------------------------

function init() {
  els.run.disabled = true;
  // Load precedence: an explicit shared link wins, then the locally
  // autosaved draft, then the default snippet. A shared `#code=` URL
  // must always show exactly what was shared, ignoring local state.
  createEditor(seedFromHash() || loadSaved() || DEFAULT_SNIPPET);
  wireSnippets();
  wireModeTabs();
  wireInspectorHover();
  wireSourceToSpanHover();
  els.run.addEventListener('click', run);
  els.share.addEventListener('click', shareLink);
  loadWasm();
}

init();
