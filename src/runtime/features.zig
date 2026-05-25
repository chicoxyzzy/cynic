//! Pre-Stage-4 / experimental TC39 proposals Cynic ships ahead of
//! the published edition. Disabled by default in the CLI and for
//! embedders — programs must opt in via `--enable=<name>` or
//! `--enable-experimental`. The test262 harness flips every entry
//! on at fixture init so the per-feature scoreboard tracks
//! proposal conformance honestly.
//!
//! Adding a new pre-Stage-4 proposal:
//!  1. Extend `FeatureFlag` with a new variant.
//!  2. Add its CLI / frontmatter name to `name`.
//!  3. Add a one-liner to `description`.
//!  4. Gate the installer site with
//!     `if (realm.features.contains(.<flag>))`.
//!  5. The test262 harness picks the new flag up automatically
//!     via `all()` (per-feature scoreboard renders one row per
//!     `FeatureFlag` variant).
//!
//! When a proposal advances to Stage 4 / ships in a published
//! ECMA-262 edition: remove the gate (always install), remove the
//! enum variant, and the test262 fixtures stop being reclassified
//! as skip in the main rollup.

const std = @import("std");

pub const FeatureFlag = enum {
    /// `Iterator.zip(iterables)` and
    /// `Iterator.zipKeyed(iterables, options?)`. Stage 3 as of
    /// 2026-05. Installer site: `src/runtime/builtins/iterator.zig`.
    joint_iteration,

    /// CLI flag / test262 `features:` frontmatter name (kebab-case,
    /// matching the upstream tc39/test262 convention).
    pub fn name(self: FeatureFlag) []const u8 {
        return switch (self) {
            .joint_iteration => "joint-iteration",
        };
    }

    /// One-line description for `cynic --list-features`.
    pub fn description(self: FeatureFlag) []const u8 {
        return switch (self) {
            .joint_iteration => "Iterator.zip / Iterator.zipKeyed (Stage 3)",
        };
    }

    /// Reverse lookup: name → flag. Returns `null` for unknown
    /// names; callers surface a CLI error and exit.
    pub fn fromName(s: []const u8) ?FeatureFlag {
        inline for (@typeInfo(FeatureFlag).@"enum".fields) |f| {
            const tag: FeatureFlag = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, tag.name())) return tag;
        }
        return null;
    }
};

pub const FeatureSet = std.EnumSet(FeatureFlag);

/// Set with every tracked feature on. Used by the test262 harness
/// (so every fixture sees the proposals enabled) and by
/// `--enable-experimental` on the CLI.
pub fn all() FeatureSet {
    return FeatureSet.initFull();
}

/// Iterate every flag in declaration order. Convenient for
/// rendering tables and emitting `--list-features`.
pub fn each(comptime visitor: fn (FeatureFlag) void) void {
    inline for (@typeInfo(FeatureFlag).@"enum".fields) |f| {
        visitor(@enumFromInt(f.value));
    }
}
