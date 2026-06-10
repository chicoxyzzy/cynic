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

/// Loader for the live-default test: the default-exported NAMED
/// function reassigns its own binding when called.
fn liveDefaultLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) realm_mod.ModuleLoaderError!realm_mod.ModuleLoadResult {
    _ = realm;
    _ = base_url;
    _ = attribute_type;
    if (std.mem.eql(u8, specifier, "./m.js")) {
        return .{ .url = "./m.js", .source = "export default function fn() { fn = 2; return 1; }\nexport function probe() { return fn; }" };
    }
    if (std.mem.eql(u8, specifier, "./main.js")) {
        return .{ .url = "./main.js", .source =
        \\import * as ns from './m.js';
        \\const a = ns.default();
        \\const b = ns.default;
        \\export const ok = (a === 1) && (b === 2);
        };
    }
    return error.ModuleNotFound;
}

test "module namespace: a named default-function export is a live binding" {
    // §9.4.6.7 [[Get]] — `export default function fn() {}` binds a
    // MUTABLE local `fn` (function declarations are var-like); after
    // `fn = 2` runs inside the function, `ns.default` must read 2,
    // not the declaration-time closure.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    realm.module_loader = liveDefaultLoader;

    const out = try lantern.loadModule(testing.allocator, &realm, "./m.js", null, null);
    try testing.expect(out.mr != null);
    const ns = out.mr.?.exports;

    const before = ns.get("default");
    const heap_mod = @import("heap.zig");
    const fn_obj = heap_mod.valueAsFunction(before) orelse return error.TestUnexpectedResult;

    const call_mod = @import("lantern/call.zig");
    const outcome = try call_mod.callJSFunction(testing.allocator, &realm, fn_obj, .undefined_, &.{});
    switch (outcome) {
        .value, .yielded => |v| try testing.expectEqual(@as(i32, 1), v.asInt32()),
        .thrown => return error.TestUnexpectedResult,
    }

    // The module-level binding observes the write...
    const probe_fn = heap_mod.valueAsFunction(ns.get("probe")) orelse return error.TestUnexpectedResult;
    const probe_out = try call_mod.callJSFunction(testing.allocator, &realm, probe_fn, .undefined_, &.{});
    switch (probe_out) {
        .value, .yielded => |v| try testing.expectEqual(@as(i32, 2), v.asInt32()),
        .thrown => return error.TestUnexpectedResult,
    }

    // ...and so does the namespace's `default` (§9.4.6.7 [[Get]]).
    const after = ns.get("default");
    try testing.expect(after.isInt32());
    try testing.expectEqual(@as(i32, 2), after.asInt32());
}

/// Loader for the const-binding tests (§16.2.1.6.4 step 17 —
/// module-level `const` is an immutable binding; writes are runtime
/// TypeErrors, and the assert.throws shape must COMPILE).
fn constBindingLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) realm_mod.ModuleLoaderError!realm_mod.ModuleLoadResult {
    _ = realm;
    _ = base_url;
    _ = attribute_type;
    if (std.mem.eql(u8, specifier, "./c.js")) {
        return .{ .url = "./c.js", .source =
        \\const t = 23;
        \\export let r = "no-throw";
        \\(function () { try { t = 9; } catch (e) { r = e.constructor.name; } })();
        };
    }
    if (std.mem.eql(u8, specifier, "./star.js")) {
        return .{ .url = "./star.js", .source =
        \\import * as ns from './c.js';
        \\export let r2 = "no-throw";
        \\try { ns = null; } catch (e) { r2 = e.constructor.name; }
        };
    }
    return error.ModuleNotFound;
}

test "module const binding: reassignment from a closure is a runtime TypeError" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    realm.module_loader = constBindingLoader;
    const out = try lantern.loadModule(testing.allocator, &realm, "./c.js", null, null);
    try testing.expect(out.mr != null);
    const r = out.mr.?.exports.get("r");
    try testing.expect(r.isString());
    const rs: *@import("string.zig").JSString = @ptrCast(@alignCast(r.asString()));
    try testing.expectEqualStrings("TypeError", rs.flatBytes());
}

test "module star-import binding: reassignment is a runtime TypeError" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    realm.module_loader = constBindingLoader;
    const out = try lantern.loadModule(testing.allocator, &realm, "./star.js", null, null);
    try testing.expect(out.mr != null);
    const r2 = out.mr.?.exports.get("r2");
    try testing.expect(r2.isString());
    const r2s: *@import("string.zig").JSString = @ptrCast(@alignCast(r2.asString()));
    try testing.expectEqualStrings("TypeError", r2s.flatBytes());
}
