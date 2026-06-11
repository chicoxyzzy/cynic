#!/usr/bin/env bash
#
# tools/lint-builtin-safety.sh — advisory host-safety lint for builtins.
#
# Flags NEWLY-ADDED raw float→int casts (`@intFromFloat`) under
# src/runtime/builtins/ that don't route through a saturating helper. A
# raw `@intFromFloat` traps the host (SIGABRT, uncatchable by JS) for any
# finite user-controlled Number outside the destination integer's range
# — the never-abort-the-host invariant (AGENTS.md /
# docs/handbook/host-safety.md), the class issues #22 / #23 closed.
#
# Coerce a user Number through `intrinsics.doubleTo{I64,Usize,U32,I32}
# Saturating` instead — or, if the value is provably bounded by a
# preceding check, add a `// safety: <reason>` comment on the cast line.
#
# DIFF-SCOPED: only added lines versus the base ref, so the ~70
# already-guarded historical call sites are grandfathered. This catches
# a NEW regression, not the back-catalogue.
#
# ADVISORY: prints findings and exits 0 — wire as a non-gating CI step or
# a pre-push reminder, not a hard gate.
#
# Usage: tools/lint-builtin-safety.sh [base-ref]   (default: origin/main)

set -euo pipefail
BASE="${1:-origin/main}"
cd "$(dirname "$0")/.."

diff_out="$(git diff "$BASE" -- 'src/runtime/builtins/*.zig' 2>/dev/null || true)"

findings="$(printf '%s\n' "$diff_out" | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    # Hunk header: @@ -old,+ +new,+ @@  — grab the new-file start line.
    if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
  }
  /^\+/ {
    code = substr($0, 2)
    if (code ~ /@intFromFloat/ && code !~ /Saturating/ && code !~ /\/\/ safety:/) {
      sub(/^[ \t]+/, "", code)
      printf "  %s:%d  %s\n", file, ln, code
    }
    ln++
    next
  }
  /^ / { ln++ }
')"

if [ -n "$findings" ]; then
  {
    echo "host-safety lint: newly-added raw @intFromFloat in builtins"
    echo "  A raw float->int cast traps the host on an out-of-range user Number"
    echo "  (issues #22/#23). Route through intrinsics.doubleTo*Saturating, or add"
    echo "  a '// safety: <bound>' comment if a preceding check already bounds it."
    echo "$findings"
    echo "(advisory — not blocking)"
  } >&2
fi
exit 0
