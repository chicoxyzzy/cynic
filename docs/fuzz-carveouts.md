# Cynic fuzz carve-outs

Documented intentional divergences from production engines. Each
entry encodes a Cynic posture decision — strict-only, non-browser-
host, SES-aligned, gated runtime code construction — and names the
spec clause it touches plus the AGENTS.md section that justifies
it. **A fuzzer-found divergence that matches an entry here is not
a bug** and must not be filed as one.

Triage tools (`tools/fuzz/triage-crashes.sh`, downstream consumers
like pragmatist's fuzz lane) read this file to dismiss known
carve-outs before emitting candidates for human review. The entry
ids are the stable handle they emit on every dismissed sample so a
reviewer can grep this file to see why something was dropped and
challenge the rule if it looks wrong.

When a posture decision changes in [AGENTS.md](../AGENTS.md), this
file changes in lockstep. Downstream consumers are mirrors of this
file; this is the source of truth.

## Format

Entries use level-3 headings with the stable id, then a fixed set
of labeled fields:

    ### <stable.id>
    - **Description:** what Cynic does on this input.
    - **Spec:** §X.Y.Z — the ECMA-262 clause the carve-out touches.
    - **Policy:** AGENTS.md section that justifies the decision.
    - **Example:** minimal JS that triggers it.
    - **Detection:** syntactic regex (pre-engine) or behavioural
      shape (post-engine outcome).

Adding a new entry: pick a stable id with the `cynic.` prefix, put
it in the right section (syntactic vs. behavioural — see below),
and add the AGENTS.md cross-reference. Renaming an id is a
breaking change for downstream triage tools — keep the old id
with a `Deprecated:` note for at least one fuzzing season.

Carve-outs split two ways:

- **Syntactic** — match the source text alone (regex grammar,
  removed intrinsics, source-form Annex B). Cheap; run as a
  pre-filter before the engine fan-out.
- **Behavioural** — match the per-engine diff result (Cynic's
  strict-only mode refusing what sloppy mode allows; Cynic's
  process panicking instead of throwing). Need the engine outcome
  to decide; run after the fan-out.

## Syntactic carve-outs

### cynic.annex-b-regex

- **Description:** Cynic enforces the strict §22.2.1 regex grammar
  in every mode. Four Annex B §B.1.2 relaxations are rejected:
  lone `]` / `{` / `}` as ExtendedPatternCharacter, DecimalEscape
  past capture count, missing Quantifier lower bound (`{,n}`), and
  CharacterClassEscape in a class range (`[\d-a]`, `[a-\d]`).
  Browser engines accept these via Annex B; Cynic does not.
- **Spec:** §22.2.1 Patterns (Cynic posture); §B.1.2 Regular
  Expressions Patterns (the relaxations Cynic rejects).
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only,
  non-browser-host target — *Regex Annex B (§B.1.4)*.
- **Example:**
  ```js
  /[\d-a]/.test("x");       // SyntaxError under Cynic; accepted in V8/JSC/SM
  /pattern{,5}/.test("x");  // SyntaxError under Cynic
  /^]$/.test("]");          // SyntaxError under Cynic
  ```
- **Detection (syntactic):** body of any `/.../`-style regex
  literal whose flags don't include `u` or `v` contains:
  - a lone `]` not closing a class, or a lone `{`/`}` not part of
    a quantifier `{n,m}` shape;
  - `{,n}` (no lower bound);
  - `\1`–`\9` with zero capture groups (back-reference past count);
  - `[\d-x]` / `[x-\d]` shape (class range with CharacterClassEscape
    bound).

### cynic.proto-accessor

- **Description:** Cynic does not implement the
  `Object.prototype.__proto__` accessor (Annex B §B.2.2.1). Use
  `Object.{get,set}PrototypeOf` instead. Object-literal
  `{__proto__: …}` keys (a separate clause, §B.1.2.1.2
  ObjectLiteral) are also carved out for now since cynic-fuzz
  rarely emits that form and conservatism is cheap.
- **Spec:** §B.2.2.1 `Object.prototype.__proto__`.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only,
  non-browser-host target.
- **Example:**
  ```js
  obj.__proto__;       // undefined (accessor not installed)
  obj.__proto__ = p;   // no-op (accessor not installed)
  ```
- **Detection (syntactic):** any occurrence of the string
  `__proto__` in the source.

### cynic.legacy-regexp-globals

- **Description:** Cynic does not implement the RegExp legacy
  globals: `RegExp.$1` … `RegExp.$9`, `RegExp.input`,
  `RegExp.lastMatch`, `RegExp.lastParen`, `RegExp.leftContext`,
  `RegExp.rightContext`. Annex B §B.2.5; out of scope for Cynic's
  non-browser-host target.
- **Spec:** §B.2.5 Additional Properties of the RegExp Constructor.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only,
  non-browser-host target.
- **Example:**
  ```js
  /(a)/.test("a"); RegExp.$1;          // undefined under Cynic
  /b/.test("ab");  RegExp.leftContext;  // undefined under Cynic
  ```
- **Detection (syntactic):** `RegExp.($1..$9|input|lastMatch|lastParen|leftContext|rightContext)`.

### cynic.html-comment

- **Description:** Cynic rejects HTML-like comments (`<!--`, `-->`).
  Annex B §B.1.3 permits them in scripts to ease cohabitation with
  `<script>`-embedded JS; Cynic's non-browser-host target has no
  such requirement.
- **Spec:** §B.1.3 HTML-like Comments.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *Annex B in
  its entirety*.
- **Example:**
  ```js
  <!-- a line comment in browsers; SyntaxError under Cynic
  var x = 1; --> also accepted in browsers as a line comment
  ```
- **Detection (syntactic):** presence of `<!--` or `-->`.

### cynic.legacy-octal

- **Description:** Cynic rejects legacy octal numeric literals.
  `0o7` (the ES6 form) parses; `07` does not. Annex B §B.1.1
  permits the latter in non-strict scripts; Cynic is strict-only.
- **Spec:** §B.1.1 Numeric Literals.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *Annex B in
  its entirety*.
- **Example:**
  ```js
  var x = 07;   // SyntaxError under Cynic (legacy octal)
  var y = 0o7;  // 7 — modern octal, parses
  ```
- **Detection (syntactic):** a leading `0` followed by `[0-7]+`,
  not preceded by `.`/`[A-Za-z_$0-9]`, not part of a `0x`/`0o`/`0b`
  prefix.

### cynic.labelled-function-declaration

- **Description:** Cynic rejects labelled function declarations.
  Annex B §B.3.1 permits `label: function f() {}` in non-strict
  code; Cynic's strict-only target does not.
- **Spec:** §B.3.1 Labelled Function Declarations.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *Annex B in
  its entirety*.
- **Example:**
  ```js
  outer: function f() {}   // SyntaxError under Cynic
  ```
- **Detection (syntactic):** identifier-colon-`function` shape:
  `[A-Za-z_$][A-Za-z0-9_$]*\s*:\s*function\s`.

### cynic.for-in-initializer

- **Description:** Cynic rejects `for-in` statements with an
  initializer. Annex B §B.3.5 permits the form in non-strict
  code; Cynic is strict-only.
- **Spec:** §B.3.5 `for-in` statement with var initializer.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *Annex B in
  its entirety*.
- **Example:**
  ```js
  for (var x = 1 in obj) {}   // SyntaxError under Cynic
  ```
- **Detection (syntactic):** `\bfor\s*\(\s*var\s+[^;)]*=\s*[^;)]*\s+in\s+`.

### cynic.removed-intrinsics

- **Description:** Cynic does not implement Annex B legacy
  intrinsics: `escape` / `unescape`,
  `String.prototype.{substr, trimLeft, trimRight}`,
  `Date.prototype.{getYear, setYear, toGMTString}`,
  `Object.prototype.__{define,lookup}{Getter,Setter}__`. Calls
  surface as `TypeError` / `ReferenceError` depending on the path.
- **Spec:** §B.2 Additional ECMAScript Features for Web Browsers
  (the suite of legacy properties Cynic omits).
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only,
  non-browser-host target.
- **Example:**
  ```js
  escape("a b");                       // ReferenceError under Cynic
  "abc".substr(1, 2);                  // TypeError under Cynic
  new Date().getYear();                // TypeError under Cynic
  ({}).__defineGetter__("x", () => 1); // TypeError under Cynic
  ```
- **Detection (syntactic):** source contains any name in the list
  above; the matcher reports which one as evidence.

## Behavioural carve-outs

### cynic.eval-gate

- **Description:** Cynic gates runtime code construction (`eval`,
  `Function`, `GeneratorFunction`, `AsyncFunction`,
  `AsyncGeneratorFunction`) behind the `--allow=eval` flag. Without
  it, every dynamic-code path throws `EvalError` per §19.2.1.2
  HostEnsureCanCompileStrings. The canonical fuzz posture
  (`cynic-fuzz`, `CYNIC_FLAGS=--allow=eval`) opens the gate; default
  embedders don't. Triage suppresses this carve-out when the gate
  is documented-open for the run.
- **Spec:** §19.2.1.2 HostEnsureCanCompileStrings.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *eval and
  runtime code construction*; finding `0041` in pragmatist's store.
- **Example:**
  ```js
  eval("1+1");          // EvalError without --allow=eval
  new Function("x");    // EvalError without --allow=eval
  ```
- **Detection (syntactic + posture):** source matches
  `\beval\s*\(` or `\bnew\s+(Function|AsyncFunction|GeneratorFunction|AsyncGeneratorFunction)\s*\(`,
  AND the run posture doesn't include `--allow=eval`. Suppressed
  when the flag is on.

### cynic.ses-hardening

- **Description:** Cynic's default SES posture freezes the
  primordials and `globalThis`. Direct mutation of
  `Array.prototype.X = …` or `globalThis.X = …` throws TypeError.
  The fuzz posture sets `CYNIC_FLAGS=--unhardened` to disable the
  freeze pass; user-facing embedders keep the default.
- **Spec:** §10.1.6.4 SetIntegrityLevel (the spec mechanism Cynic
  uses to freeze the primordials at realm init); no normative rule
  mandates the posture either way — Cynic's choice.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only — *SES-aligned
  by default; `--unhardened` opts out*.
- **Example:**
  ```js
  Array.prototype.push = null;   // TypeError under default Cynic
  globalThis.foo = 1;            // TypeError under default Cynic
  ```
- **Detection (behavioural):** Cynic throws `TypeError` on a write
  that production engines accept silently. The matcher uses the
  diff outcome rather than the source because the same source can
  go either way depending on `CYNIC_FLAGS`.

### cynic.strict-only

- **Description:** Cynic executes every source as if it had
  `'use strict'` at the top. When production engines run the
  sample sloppy (no directive) and the resulting divergence
  vanishes once strict mode is forced on the others, the
  divergence is the strict/sloppy gap, not a Cynic bug.
- **Spec:** §10.2.10 FunctionDeclarationInstantiation and
  §16.1.6 ScriptEvaluation — strictness propagation per §10.2.4.
- **Policy:** [AGENTS.md](../AGENTS.md) §Strict-only; finding
  `0005` in pragmatist's store records the canonical example.
- **Example:**
  ```js
  function f() { return this; }
  f();   // undefined under Cynic; window/global under sloppy V8
  ```
- **Detection (behavioural):** Cynic + the strict-forced
  production engines agree; only the sloppy outcomes disagree.
  This matcher needs the diff result, so it runs after the engine
  fan-out.

### cynic.crash-route

- **Description:** Cynic's process panicked on this input — a Zig
  runtime trap abended the host. This is not a divergence but a
  crash; route to the crashes channel for stack-trace dedup and a
  separate finding shape. Finding clusters `0042` / `0043`
  (`@intFromFloat` panics) set the precedent.
- **Spec:** N/A — engine-shape failure, not a spec outcome.
  Cynic's host-safety contract per
  [AGENTS.md](../AGENTS.md) ("never abort the host on untrusted
  input") classifies any panic on user JS as a bug, but bugs of
  this shape need crash-bucket dedup rather than divergence triage.
- **Policy:** [AGENTS.md](../AGENTS.md) §*Never abort the host on
  untrusted input*; findings `0042`, `0043`.
- **Example:**
  ```js
  // Any input that triggers a Zig panic — typically out-of-range
  // @intFromFloat, integer overflow in user-controlled arithmetic,
  // or a missing HandleScope in a native that re-enters JS.
  ```
- **Detection (behavioural):** the engine wrapper surfaces the
  panic as `RunnerError` with `panic:` / `thread N panic` /
  `integer overflow` / `integer cast` in the message.

## Notes for downstream mirrors

External consumers (pragmatist's `src/fuzz/carveouts.ts`, any
future Zig-side helper) must mirror the entries in this file,
cite their ids verbatim (downstream renames break dashboards), and
keep the AGENTS.md cross-references intact. When this file gets a
new entry, the downstream mirror gets the same entry; when this
file's policy lands in AGENTS.md (the canonical source for the
posture decision itself), this file changes in lockstep.

The migration from a downstream-authored carve-out list to
Cynic-authored arrived because fuzz triage is engine-side quality
work: the carve-outs encode *Cynic's* posture, not the
downstream's audit posture. Routing the policy through here keeps
the engine self-contained and the public README able to link
straight to the carve-out list without naming any downstream tool.
