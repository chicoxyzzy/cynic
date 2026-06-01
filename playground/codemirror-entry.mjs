// CodeMirror 6 entry module for the Cynic playground.
//
// This file is the SOURCE for `codemirror.bundle.js`. It imports
// exactly the CodeMirror 6 surface the playground front-end needs
// and re-exports it as a single ES module. The bundle is committed
// as a pinned `vendor/`-style artifact: the playground pulls no
// third-party code at load time (Cynic is SES-aligned — no
// supply-chain bait, works fully offline).
//
// Pinned CodeMirror 6 package versions:
//   @codemirror/state          6.6.0
//   @codemirror/view           6.43.0
//   @codemirror/commands       6.10.3
//   @codemirror/language       6.12.3
//   @codemirror/lang-javascript 6.2.5
//   @lezer/highlight           1.2.3
//   (bundled with esbuild      0.28.0)
//
// Regenerate `codemirror.bundle.js` from this file:
//
//   mkdir -p /tmp/cm6-build && cd /tmp/cm6-build
//   npm init -y
//   npm install @codemirror/state@6.6.0 @codemirror/view@6.43.0 \
//     @codemirror/commands@6.10.3 @codemirror/language@6.12.3 \
//     @codemirror/lang-javascript@6.2.5 @lezer/highlight@1.2.3 \
//     esbuild@0.28.0
//   cp <repo>/playground/codemirror-entry.mjs .
//   ./node_modules/.bin/esbuild codemirror-entry.mjs \
//     --bundle --format=esm --minify \
//     --outfile=<repo>/playground/codemirror.bundle.js
//
// Do not edit `codemirror.bundle.js` by hand — regenerate it.

export { EditorState, StateField, StateEffect, RangeSetBuilder } from "@codemirror/state";
export {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  Decoration,
} from "@codemirror/view";
export {
  history,
  defaultKeymap,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
export {
  syntaxHighlighting,
  defaultHighlightStyle,
  HighlightStyle,
  indentUnit,
} from "@codemirror/language";
export { javascript } from "@codemirror/lang-javascript";
export { tags } from "@lezer/highlight";
