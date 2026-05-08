//! test262 harness preload + `includes:` loader.
//!
//! Per [INTERPRETING.md](https://github.com/tc39/test262/blob/main/INTERPRETING.md)
//! every non-`raw` test runs in a Realm where `harness/sta.js` and
//! `harness/assert.js` have already been evaluated, plus any
//! files named in the test's `includes:` frontmatter. Real
//! engines load each as its own Script in the same Realm
//! (`d8 sta.js assert.js include1.js test.js`); later lets
//! Cynic do the same.
//!
//! The `IncludeCache` preloads every `.js` file in the harness
//! directory at startup so per-test lookups don't pay file-I/O.
//! At ~30 files / ~250KB, the cache is cheap and lasts the
//! whole `zig build test262` invocation.
//!
//! `loadShim` swaps upstream `assert.js` for a minimal
//! Cynic-shipped reimplementation — useful for measuring the
//! engine floor or when upstream `assert.js` drifts past what
//! Cynic compiles. For later onward the upstream version
//! compiles cleanly and is preferred.

const std = @import("std");

/// Cynic-shipped replacement for upstream `harness/assert.js`.
/// Provides the assertion call surface most tests use, written
/// with only the bytecode-compiler subset Cynic supports today
/// (no template literals, no switch, no `String(value)` coercion).
const cynic_assert_js: []const u8 =
    \\function assert(mustBeTrue, message) {
    \\  if (mustBeTrue === true) {
    \\    return;
    \\  }
    \\  if (message === undefined) {
    \\    message = "assertion failed";
    \\  }
    \\  throw new Test262Error(message);
    \\}
    \\assert._isSameValue = function (a, b) {
    \\  if (a === b) {
    \\    if (a !== 0) return true;
    \\    return 1 / a === 1 / b;
    \\  }
    \\  return a !== a && b !== b;
    \\};
    \\assert.sameValue = function (actual, expected, message) {
    \\  if (assert._isSameValue(actual, expected)) return;
    \\  if (message === undefined) message = "";
    \\  throw new Test262Error(message + " Expected SameValue to be true.");
    \\};
    \\assert.notSameValue = function (actual, unexpected, message) {
    \\  if (!assert._isSameValue(actual, unexpected)) return;
    \\  if (message === undefined) message = "";
    \\  throw new Test262Error(message + " Expected SameValue to be false.");
    \\};
    \\assert.throws = function (expectedErrorConstructor, func, message) {
    \\  if (typeof func !== "function") {
    \\    throw new Test262Error("assert.throws requires a function as second argument");
    \\  }
    \\  if (message === undefined) message = "";
    \\  try {
    \\    func();
    \\  } catch (thrown) {
    \\    if (typeof thrown !== "object" || thrown === null) {
    \\      throw new Test262Error(message + " Thrown value was not an object.");
    \\    }
    \\    if (thrown.constructor !== expectedErrorConstructor) {
    \\      throw new Test262Error(message + " Wrong error constructor.");
    \\    }
    \\    return;
    \\  }
    \\  throw new Test262Error(message + " Expected an error to be thrown.");
    \\};
    \\
;

/// Preloaded harness sources. `sta` and `assert_js` are
/// always evaluated (in that order) before the test source;
/// `includes` is a name→source map covering every `.js` file
/// in the harness directory, consulted lazily per-test.
pub const HarnessSources = struct {
    sta: []const u8,
    assert_js: []const u8,
    /// True when `assert_js` is the Cynic-shipped shim (a static
    /// const, not allocated). The shim is never freed.
    assert_is_shim: bool,
    /// Maps `compareArray.js` / `testTypedArray.js` / etc. to
    /// source bytes. Bytes are owned by the cache; entries live
    /// for the harness's lifetime.
    includes: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *HarnessSources, allocator: std.mem.Allocator) void {
        allocator.free(self.sta);
        if (!self.assert_is_shim) allocator.free(self.assert_js);
        var it = self.includes.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.includes.deinit(allocator);
    }

    /// Look up the source for an `includes:` name (e.g.
    /// `"compareArray.js"`). Returns null if Cynic doesn't have
    /// the file — the runner falls back to skipping the test.
    pub fn lookupInclude(self: *const HarnessSources, name: []const u8) ?[]const u8 {
        return self.includes.get(name);
    }
};

/// Read `harness_dir/sta.js` and `harness_dir/assert.js`, plus
/// every other `.js` file in the directory (cached in
/// `includes`). Cheap — there are ~30 files totalling ~250 KB.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    harness_dir: std.Io.Dir,
) !HarnessSources {
    const sta = try harness_dir.readFileAlloc(io, "sta.js", allocator, .limited(64 * 1024));
    errdefer allocator.free(sta);
    const assert_js = try harness_dir.readFileAlloc(io, "assert.js", allocator, .limited(64 * 1024));
    errdefer allocator.free(assert_js);

    var includes: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer includes.deinit(allocator);

    try populateIncludes(allocator, io, harness_dir, &includes);

    return .{ .sta = sta, .assert_js = assert_js, .assert_is_shim = false, .includes = includes };
}

/// Alternative load: use the Cynic-shipped minimal shim instead
/// of the upstream `assert.js`. Useful when measuring the
/// engine floor or when upstream `assert.js` has drifted past
/// Cynic's compiler.
pub fn loadShim(
    allocator: std.mem.Allocator,
    io: std.Io,
    harness_dir: std.Io.Dir,
) !HarnessSources {
    const sta = try harness_dir.readFileAlloc(io, "sta.js", allocator, .limited(64 * 1024));
    errdefer allocator.free(sta);

    var includes: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer includes.deinit(allocator);

    try populateIncludes(allocator, io, harness_dir, &includes);

    return .{ .sta = sta, .assert_js = cynic_assert_js, .assert_is_shim = true, .includes = includes };
}

fn populateIncludes(
    allocator: std.mem.Allocator,
    io: std.Io,
    harness_dir: std.Io.Dir,
    out: *std.StringHashMapUnmanaged([]const u8),
) !void {
    var iter = harness_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        // sta.js / assert.js are loaded explicitly above; don't
        // double-cache them.
        if (std.mem.eql(u8, entry.name, "sta.js")) continue;
        if (std.mem.eql(u8, entry.name, "assert.js")) continue;

        // The directory iterator may reuse its `entry.name`
        // buffer across calls; copy the name BEFORE the next
        // `read*` operation invalidates it.
        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);

        const source = harness_dir.readFileAlloc(io, owned_name, allocator, .limited(256 * 1024)) catch {
            allocator.free(owned_name);
            // Skip unreadable individual files rather than failing
            // the whole load — at worst tests using that include
            // will fall through to the "not found" skip path.
            continue;
        };
        try out.put(allocator, owned_name, source);
    }
}
