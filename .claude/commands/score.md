---
description: Run test262, append a row to test262-results.md, show delta vs prior row
---

Score current parser-only test262 conformance and update the score
history.

1. Run `zig build test262 -- --quiet --write-results`.
2. Read the last two rows of `test262-results.md` (the freshly
   appended one and the row above it).
3. Report:
   - Current score: `pass / total (pct%)`.
   - Delta vs prior row: `∆ tests`, `∆ pct`.
   - False-reject count + delta.
   - False-accept count + delta.

Do **not** commit. Just print the summary.
