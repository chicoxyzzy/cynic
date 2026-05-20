# `codemirror.bundle.js` — vendored CodeMirror 6

`codemirror.bundle.js` is a **committed build artifact**: a single
minified ES module containing exactly the CodeMirror 6 surface the
Cynic playground needs. Treat it like a pinned `vendor/` blob — do
not edit it by hand, regenerate it.

The playground bundles CM6 rather than pulling it from a CDN at
load time. Cynic is SES-aligned ("no eval, that's the point") — a
runtime CDN import would be supply-chain bait, and the playground
must work fully offline.

## Pinned versions

| Package | Version |
|---|---|
| `@codemirror/state` | 6.6.0 |
| `@codemirror/view` | 6.43.0 |
| `@codemirror/commands` | 6.10.3 |
| `@codemirror/language` | 6.12.3 |
| `@codemirror/lang-javascript` | 6.2.5 |
| `@lezer/highlight` | 1.2.3 |
| `esbuild` (bundler) | 0.28.0 |

## Source of truth

`codemirror-entry.mjs` is the entry module — it imports the CM6
packages and re-exports the exact symbols the front-end uses. It
carries the same version table and the regenerate command in a
header comment.

## Regenerate

```sh
mkdir -p /tmp/cm6-build && cd /tmp/cm6-build
npm init -y
npm install @codemirror/state@6.6.0 @codemirror/view@6.43.0 \
  @codemirror/commands@6.10.3 @codemirror/language@6.12.3 \
  @codemirror/lang-javascript@6.2.5 @lezer/highlight@1.2.3 \
  esbuild@0.28.0
cp <repo>/playground/codemirror-entry.mjs .
./node_modules/.bin/esbuild codemirror-entry.mjs \
  --bundle --format=esm --minify \
  --outfile=<repo>/playground/codemirror.bundle.js
```

`node_modules/` is git-ignored — only `codemirror.bundle.js` and
`codemirror-entry.mjs` are committed.
