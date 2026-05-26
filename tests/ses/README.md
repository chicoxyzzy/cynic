## Cynic SES positive-coverage tests

Hand-written JavaScript tests proving Cynic's SES posture
behaves as `docs/handbook/ses-test262-policy.md` (Phase 4)
claims it does — the dual of Phase 3's witness-inversion set
in `tools/test262/ses_witnesses.zig`.

The Phase 3 witnesses are **negative** evidence — divergent
test262 fixtures whose expected behaviour SES correctly
breaks. The fixtures here are **positive** evidence — the
hardened-mode behaviour SES is supposed to enable
(override-mistake shadowing, `harden()` traversal,
frozen-globalThis carve-outs) actually works.

### Running

```
zig build test-ses
```

Wraps `tools/test-ses.sh`, which runs every `tests/ses/*.js`
file via `zig-out/bin/cynic run` (hardened-by-default) and
reports pass / fail by exit code. A passing test completes
silently; a failing test throws. CI runs this as a gating
step alongside `zig build test`.

### Adding a test

- One assertion per file. Throw on failure with a message
  that names what was checked, not just `"failed"`.
- Use the minimal JS that exercises the SES invariant —
  no prologue, no helpers. The whole point is that the
  behaviour is observable from plain ECMAScript.
- Categorise via filename prefix:
  - `override_*` — override-mistake fix corners.
  - `harden_*` — `harden()` graph traversal invariants.
  - `globalthis_*` — frozen-globalThis edges.
  - `primordials_*` — frozen-intrinsic surfaces.

The list is intentionally small and load-bearing — every
file is run on every CI build. Aim for high signal per
fixture; don't bloat with cases that are also covered by
the test262 corpus running in hardened mode.
