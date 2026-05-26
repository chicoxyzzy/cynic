// Under `--unhardened`, the global `harden` binding is not
// installed at realm init. This is the "round-trip" check for the
// SES posture: every piece toggles off atomically when the flag
// is set, including the user-facing API.

// `typeof` of an undeclared global returns "undefined" without
// throwing ReferenceError (§13.5.3 typeof on unresolvable
// reference). Use it to probe presence safely.
if (typeof harden !== "undefined") {
  throw new Error(
    "global `harden` is installed under --unhardened (should be absent)"
  );
}
