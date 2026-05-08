# Tests first

Write failing tests *before* the production code that satisfies
them. For any new lexer, parser, or runtime feature in Cynic:

1. Add the inline `test` blocks covering the golden path, edge
   cases, and diagnostics.
2. Run `zig build test` and confirm the new tests fail with the
   expected shape.
3. Implement the code that makes them pass.
4. Re-run `zig build test`.

Do not batch tests and implementation in a single edit.

## Why

Tests-first surfaces design problems early: writing the assertion
first forces you to name what success looks like, in source-text
terms. It also creates the regression net before any code lands —
which matters when the next session breaks something the tests
would have caught.

The discipline applies even to features that look trivial. The
hashbang implementation is the canonical example: shipping tests
and code together once let an unrelated bug in
`scanIdentifierStart`'s ASCII path slip through; only a test
written separately revealed it.

## How to format the tests

- **Golden-AST tests** use the S-expression printer
  (`expectAst` / `expectModuleAst`). Compare a literal multi-line
  string against `cynic.ast.printer.dump`. The printer's output is
  stable enough to make span numbers part of the assertion.
- **Diagnostic tests** use `parseScript` / `parseModule` with a
  `Diagnostics` sink, then assert on `diags.items[0].code` and the
  count. Convention: `_ = parseScript(arena, source, &diags) catch
  {};` so a hard parse error doesn't leak past the test.
- **Lexer tests** use `expectKinds` for token-stream shape, or
  hand-rolled `lex.next()` calls when a token's `had_escape` /
  `line_terminator_before` flag matters.

If the change is in `tools/test262/...`, the inline tests there
follow the same shape.

## When the rule bends

Span-only off-by-one fixes to existing test expectations don't
need a separate failing-test step — you're correcting the
expectation, not the behavior. Anything that changes parser /
lexer / runtime behavior gets a test first.
