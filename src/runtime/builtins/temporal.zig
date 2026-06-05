//! Temporal — namespace install. Per-type bodies live under
//! `temporal/` (duration, plain_time, instant, plain_date, plain_date_time,
//! plain_year_month, plain_month_day, zoned_date_time, now); shared option
//! getters, field readers, calendar checks, and time-zone helpers live in
//! `temporal/shared.zig`.
//!
//! The `Temporal` global is a namespace object (like `Math`), not a
//! constructor. The instance state of each per-type value is a
//! heap-allocated `TemporalRecord` reached through `JSObject.temporal_record`
//! — never a `__cynic_*` property-bag key (AGENTS.md "no engine state on
//! user-visible objects").

const Realm = @import("../realm.zig").Realm;
const intrinsics = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");

const installToStringTag = intrinsics.installToStringTag;

/// Re-exported for `Date.prototype.toTemporalInstant` (the only cross-builtin
/// caller — see `date.zig`).
pub const createTemporalInstant = @import("temporal/instant.zig").createTemporalInstant;

pub fn install(realm: *Realm) !void {
    // The `Temporal` namespace object — a plain object inheriting
    // %Object.prototype% with a `Symbol.toStringTag` of "Temporal"
    // and the per-type constructors as non-enumerable data
    // properties.
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try installToStringTag(realm, ns, "Temporal");
    realm.intrinsics.temporal_namespace = ns;

    try @import("temporal/duration.zig").install(realm, ns);
    try @import("temporal/plain_time.zig").install(realm, ns);
    try @import("temporal/instant.zig").install(realm, ns);
    try @import("temporal/plain_date.zig").install(realm, ns);
    try @import("temporal/plain_date_time.zig").install(realm, ns);
    try @import("temporal/plain_year_month.zig").install(realm, ns);
    try @import("temporal/plain_month_day.zig").install(realm, ns);
    try @import("temporal/zoned_date_time.zig").install(realm, ns);
    try @import("temporal/now.zig").install(realm, ns);

    // `Temporal` is a non-enumerable, writable, configurable global
    // (§17 namespace-object convention, matching the property
    // descriptor of `Math` / `JSON` / `Reflect`).
    try realm.globals.put(realm.allocator, "Temporal", heap_mod.taggedObject(ns));
}
