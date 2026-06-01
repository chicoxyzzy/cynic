---
description: Profile a test262 sweep under samply; emit a top-N hot-function list
---

Sample the test262 runtime path and surface the hottest functions
in the interpreter. Use this when planning a perf-shaped change to
make sure the target is actually hot.

1. If `samply` is not on PATH, instruct the user to install:
   - macOS: `brew install samply`
   - Any platform with Rust: `cargo install samply`
2. Run `tools/profile.sh "<filter>" <top_n>` (defaults:
   `built-ins/Array`, 20). The filter is a `--filter=` substring
   that the test262 harness matches against the fixture path —
   pick something that takes ~10-30 s to keep the sample count
   sensible.
3. The script writes `profile.json` (Firefox-Profiler format) and
   prints the load command.
4. Either:
   - Recommend the user open the profile in the browser-based
     viewer: `samply load profile.json`, or
   - Tail-walk the JSON to extract the top-N inclusive samples
     and print them inline.

Do **not** commit. The `profile.json` is a local artifact.

Tip: a hot function is only actionable if it's something we can
change. Zig std library hot paths (`ArrayHashMap.getOrPut`, etc.)
point at *indirect* targets — usually a caller is hitting them
more than expected.
