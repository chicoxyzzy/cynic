//! Phase 2 multi-realm contracts — per-realm module graph.
//! See `docs/multi-realm.md` Phase 2.
//!
//! Phase 2's headline goal — splitting a (would-be) process-wide
//! module cache into per-realm caches — is already satisfied
//! by today's `Realm.modules` field (it's per-instance, not a
//! global). These tests pin that contract empirically so a
//! future refactor can't accidentally introduce a process-wide
//! cache without a CI fail. The `StaticModuleRecord` sub-feature
//! (embedder-declared shared modules — the SES initial-modules
//! pattern) is deferred until Compartments land per
//! `docs/ses-alignment.md`; there's no user-observable surface
//! for it yet.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const realm_mod = @import("realm.zig");
const lantern = @import("lantern/interpreter.zig");

/// Loader source for test 1 — same source in both realms, but
/// loaded against different `*Realm`s. The cache lives on the
/// realm, so each must produce its own `ModuleRecord`.
fn sameSourceLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) realm_mod.ModuleLoaderError!realm_mod.ModuleLoadResult {
    _ = realm;
    _ = base_url;
    _ = attribute_type;
    if (std.mem.eql(u8, specifier, "./mod.js")) {
        return .{ .url = "./mod.js", .source = "export const x = 1;" };
    }
    return error.ModuleNotFound;
}

test "phase 2: two realms hold distinct ModuleRecords for the same specifier" {
    // Per-realm module cache: loading "./mod.js" against two
    // independent realms must allocate two distinct
    // `ModuleRecord`s. If `Realm.modules` ever silently
    // collapsed into a process-wide cache (or was reached
    // via a global accessor), one realm's evaluation could
    // observe the other's exports — a tenant-isolation
    // failure for any embedder running multiple realms.
    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    try ra.installBuiltins();
    ra.module_loader = sameSourceLoader;

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    try rb.installBuiltins();
    rb.module_loader = sameSourceLoader;

    const out_a = try lantern.loadModule(testing.allocator, &ra, "./mod.js", null, null);
    const out_b = try lantern.loadModule(testing.allocator, &rb, "./mod.js", null, null);

    try testing.expect(out_a.mr != null);
    try testing.expect(out_b.mr != null);
    try testing.expect(out_a.mr.? != out_b.mr.?);

    // Each cache holds its own record.
    try testing.expectEqual(@as(usize, 1), ra.modules.count());
    try testing.expectEqual(@as(usize, 1), rb.modules.count());
    try testing.expect(ra.modules.get("./mod.js").? == out_a.mr.?);
    try testing.expect(rb.modules.get("./mod.js").? == out_b.mr.?);
}

/// Loader source for test 2 — a module that throws at top
/// level. Only `ra` uses this loader; `rb` uses a clean one.
fn throwingLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) realm_mod.ModuleLoaderError!realm_mod.ModuleLoadResult {
    _ = realm;
    _ = base_url;
    _ = attribute_type;
    if (std.mem.eql(u8, specifier, "./mod.js")) {
        return .{ .url = "./mod.js", .source = "throw new Error('a-only');" };
    }
    return error.ModuleNotFound;
}

fn cleanLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) realm_mod.ModuleLoaderError!realm_mod.ModuleLoadResult {
    _ = realm;
    _ = base_url;
    _ = attribute_type;
    if (std.mem.eql(u8, specifier, "./mod.js")) {
        return .{ .url = "./mod.js", .source = "export const ok = true;" };
    }
    return error.ModuleNotFound;
}

test "phase 2: module errored in realm A doesn't poison realm B" {
    // Error isolation across realms. A poisoned cache entry
    // in `ra.modules` must not be visible to rb's loader,
    // even when both use the same specifier. The cache is
    // physically distinct (test 1); this verifies the
    // *evaluation outcome* doesn't bleed either.
    var ra = Realm.init(testing.allocator);
    defer ra.deinit();
    try ra.installBuiltins();
    ra.module_loader = throwingLoader;

    var rb = Realm.init(testing.allocator);
    defer rb.deinit();
    try rb.installBuiltins();
    rb.module_loader = cleanLoader;

    const out_a = try lantern.loadModule(testing.allocator, &ra, "./mod.js", null, null);
    try testing.expect(out_a.threw);

    const out_b = try lantern.loadModule(testing.allocator, &rb, "./mod.js", null, null);
    try testing.expect(!out_b.threw);
}
