//! Phase 1 multi-realm contracts — D1 sharing policy.
//! See `docs/multi-realm.md` Phase 1 + the implementation-notes
//! sub-section.
//!
//! These tests pin the contract `intrinsics.installWithBase`
//! must satisfy: hardened realms sharing one `IntrinsicsBase`
//! get pointer-identical prototype objects; unhardened realms
//! never share (mutation would leak across them); a hardened-
//! shared base survives any one realm's `deinit` (lifetime is
//! the host's, not the realm's); the SES override-mistake fix
//! travels with the shared prototype.
//!
//! TDD discipline. Today's `installWithBase` is a stub: it
//! ignores `base` and delegates to `install`. The two sharing-
//! policy tests below would go red under it — they're marked
//! `error.SkipZigTest` so CI stays green while the contract
//! stays pinned. Phase 1 step 4 ("Rewrite installWithBase to
//! adopt shared pointers under hardened + non-null base", see
//! the landing-order list in `docs/multi-realm.md`) is the
//! commit that removes the skip lines. The three other tests
//! (hardened+unhardened, two-unhardened, override-mistake) hold
//! under the stub too, so they run unguarded and catch any
//! regression on the always-distinct + always-fixed properties.

const std = @import("std");
const testing = std.testing;

const intrinsics = @import("intrinsics.zig");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

// ── 1. Hardened realms sharing one base → identical pointers ────

test "phase 1: two hardened realms share Object.prototype pointer (D1)" {
    if (true) return error.SkipZigTest; // pending Phase 1 step 4

    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = true;
    try intrinsics.installWithBase(&rb, &base);

    // Hardened sharing — same pointer.
    try testing.expect(ra.intrinsics.object_prototype != null);
    try testing.expect(rb.intrinsics.object_prototype != null);
    try testing.expect(ra.intrinsics.object_prototype.? ==
        rb.intrinsics.object_prototype.?);
    try testing.expect(ra.intrinsics.array_prototype.? ==
        rb.intrinsics.array_prototype.?);
    try testing.expect(ra.intrinsics.function_prototype.? ==
        rb.intrinsics.function_prototype.?);
}

// ── 2. Hardened + unhardened → distinct, even with same base ───

test "phase 1: hardened + unhardened do not share (D1)" {
    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    // Unhardened can't share — would let `Array.prototype.x = …`
    // in rb leak into ra.
    rb.hardened = false;
    try intrinsics.installWithBase(&rb, &base);

    try testing.expect(ra.intrinsics.object_prototype.? !=
        rb.intrinsics.object_prototype.?);
}

// ── 3. Two unhardened realms always distinct ────────────────────

test "phase 1: two unhardened realms each get distinct primordials" {
    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = false;
    try intrinsics.installWithBase(&ra, null);

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = false;
    try intrinsics.installWithBase(&rb, null);

    try testing.expect(ra.intrinsics.object_prototype.? !=
        rb.intrinsics.object_prototype.?);
}

// ── 4. Shared base outlives any one realm's deinit ──────────────

test "phase 1: hardened-shared base survives realm deinit of one party" {
    if (true) return error.SkipZigTest; // pending Phase 1 step 4

    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = Realm.init(testing.allocator);
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    // Snapshot the shared pointer.
    const shared = ra.intrinsics.object_prototype.?;
    ra.deinit();

    // A second realm using the same base must still see a valid
    // object_prototype — `base` owns lifetime, not `ra`.
    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = true;
    try intrinsics.installWithBase(&rb, &base);

    try testing.expect(rb.intrinsics.object_prototype.? == shared);
    // …and accessing it must not segfault. Read a property that
    // the install pass always wires up.
    try testing.expect(rb.intrinsics.object_prototype.?.hasOwn("toString"));
}

// ── 5. Override-mistake fix travels with the shared prototype ───

test "phase 1: override-mistake fix triggers cross-realm under shared base" {
    // The synthetic accessor pair the SES Phase 3 fix bakes onto
    // every frozen prototype slot is per-slot, per-prototype —
    // NOT realm-aware (see `docs/multi-realm.md` Phase 1 note
    // (d)). Once it's on a shared %Object.prototype%, both
    // realms see the same override-mistake fix.
    //
    // Canonical pattern: `Foo.prototype.toString = …` succeeds
    // via instance-shadowing instead of throwing.
    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = true;
    try intrinsics.installWithBase(&rb, &base);

    // The fix triggers in ra…
    const r_a = try lantern.evaluateScript(testing.allocator, &ra,
        \\function Foo() {}
        \\Foo.prototype.toString = function () { return "from-ra"; };
        \\(new Foo()).toString();
    );
    try testing.expect(r_a == .value);

    // …and independently in rb. If the synthetic accessor were
    // somehow lost on the shared graph, rb would throw TypeError
    // on the second statement.
    const r_b = try lantern.evaluateScript(testing.allocator, &rb,
        \\function Bar() {}
        \\Bar.prototype.toString = function () { return "from-rb"; };
        \\(new Bar()).toString();
    );
    try testing.expect(r_b == .value);
}
