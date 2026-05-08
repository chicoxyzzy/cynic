---
description: Survey current test262 failures, group by pattern, suggest fixes (analysis only)
---

Run the test262 conformance suite and analyze remaining failures.

1. Run `zig build test262 -- --quiet --list-failures=2000` and capture
   the output.
2. Parse out the failure paths and group by directory (everything
   before the basename). Show the top 10 directories by failure count.
3. Pick the top 5 directories. For each:
   - Sample three distinct test files. Read each one (full file —
     frontmatter and body).
   - State whether the group is **false-reject** (we reject legal
     code) or **false-accept** (we accept code that should error),
     using the labels in the harness output.
   - Identify the spec feature or early-error rule under test.
4. For each group, propose **one concrete fix**:
   - File path under `src/parser/` or `src/lexer/`.
   - What contextual change is needed (new flag, missing branch,
     missing rule).
   - Estimated test-count impact.
5. Report under 600 words. **Analysis only — do not implement.**

Read [docs/handbook/prior-art.md](../../docs/handbook/prior-art.md)
before suggesting non-trivial fixes — survey how V8 / JSC /
SpiderMonkey handle the rule.
