//! SES-witness fixtures — curated test262 paths that **must
//! reclassify as `divergent`** under the hardened SES posture.
//!
//! Phase 3 of [docs/handbook/ses-test262-policy.md]. The
//! divergence classifier in `ses_divergent.zig` already drives
//! the bulk reclassification (2515 / 40161 fixtures); witnesses
//! are a curated subset that act as **positive proof SES is
//! enforcing what we claim it does**.
//!
//! The invariant: every witness fixture should produce a
//! `fail_divergent` outcome under `phase == .main`. If a witness
//! instead:
//!   - **passes** — SES enforcement has weakened (a previously-
//!     locked primordial slot is now mutable / extensible).
//!     This is correctness regression, not a score-row blip.
//!   - **fails** (`fail_false_reject`) — the fixture threw but
//!     the divergence classifier didn't recognise the message,
//!     OR the engine surfaced a different exception path
//!     (e.g. ReferenceError instead of TypeError). Likely a
//!     pattern miss in `ses_divergent.zig` or a real engine
//!     regression in the SES throw path.
//!
//! Either drift is a hard signal — CI gates the
//! `ses-witness` row at 100 %. The fixtures here are
//! deliberately short, focused on a single SES-tripping
//! operation, and stable across test262 corpus bumps.
//!
//! Adding a witness:
//!   1. Pick a divergent fixture whose body is < 30 lines and
//!      whose sole assertion is the SES-divergent invariant.
//!   2. Confirm it currently classifies as `divergent` by
//!      grepping the `--list-failures` output BEFORE the
//!      patch — it shouldn't appear there (post-Phase-2 the
//!      list is just the 12 known non-divergent fails).
//!   3. Add the path here. Verify the witness row stays at
//!      100 % under `zig build test262 -- --phase=main`.

const std = @import("std");

/// Curated witness set. Every path here MUST classify as
/// `divergent` under hardened-mode runs; any other outcome
/// is a SES enforcement regression.
///
/// Coverage targets the major SES-enforcement surfaces:
///   - Frozen prototype data slots (`Cannot assign to read-only
///     property`).
///   - Non-extensible intrinsic objects (`Cannot add property,
///     object is not extensible`).
///   - Frozen descriptor invariants (descriptor flag locked).
///   - Override-mistake fix synthetic accessor pairs.
///
/// Keep the list small and load-bearing — every entry is a
/// per-fixture cost on every full hardened sweep, and the
/// signal value drops once the count grows past ~20-30.
pub const witnesses = [_][]const u8{
    // Object.isExtensible() must return true on built-ins —
    // under SES they're all non-extensible. The fixture asserts
    // `Object.isExtensible(Object.prototype)` is true; under SES
    // it's false → assertion fails → message `Object.prototype is
    // extensible` matches the divergence list.
    "built-ins/Object/prototype/extensibility.js",

    // Object.isFrozen — built-ins are frozen under SES, tests
    // assert `false`. The propertyHelper raises
    // `b Expected SameValue(«true», «false»)`.
    "built-ins/Object/isFrozen/15.2.3.12-3-25.js",
    "built-ins/Object/isFrozen/15.2.3.12-3-11.js",

    // Object.isSealed — same shape as isFrozen above (sealed
    // built-ins). `15.2.3.11-4-24` tests TypeError on a sealed
    // intrinsic; same divergence pattern.
    "built-ins/Object/isSealed/15.2.3.11-4-24.js",

    // Built-in method `length` / `name` descriptor checks — under
    // SES these slots are `{w:f, c:f}`. Fixtures assert `{c:t}`
    // and fire `descriptor should be configurable` (Category A in
    // `ses_divergent.zig`). The `prop-desc.js` variants on Math
    // namespaces oddly don't trip the same pattern (the namespace's
    // freeze leaves the propertyHelper read-back happy), so only
    // the targeted `length` / `name` files are reliable witnesses
    // for those surfaces.
    "built-ins/Math/abs/name.js",
    "built-ins/Math/abs/length.js",
    "built-ins/Array/prototype/push/length.js",
    "built-ins/Array/prototype/push/name.js",
    "built-ins/Array/prototype/pop/length.js",

    // Frozen-value-slot writes — Array.prototype[@@unscopables]
    // is a data slot; reassignment throws "Cannot assign to
    // read-only property" under SES.
    "built-ins/Array/prototype/Symbol.unscopables/value.js",
};

/// True if `rel_path` is in the curated witness set.
pub fn isWitness(rel_path: []const u8) bool {
    for (witnesses) |w| {
        if (std.mem.eql(u8, w, rel_path)) return true;
    }
    return false;
}

test "isWitness: positive lookup" {
    try std.testing.expect(isWitness("built-ins/Object/prototype/extensibility.js"));
    try std.testing.expect(isWitness("built-ins/Math/abs/length.js"));
}

test "isWitness: negative lookup" {
    try std.testing.expect(!isWitness("built-ins/Math/abs/abs.js"));
    try std.testing.expect(!isWitness("language/expressions/addition/order.js"));
}

test "witness set size is sane" {
    // Phase 3 of the policy targets ~20 witnesses. Anything
    // wildly outside that range probably means we're either
    // not curating tightly (>40) or we lost coverage (<5).
    try std.testing.expect(witnesses.len >= 10);
    try std.testing.expect(witnesses.len <= 40);
}
