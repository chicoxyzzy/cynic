//! Cycle-free Ohaimark tier policy constants.
//!
//! Lantern / Bistromath / the OSR driver must agree on heat floors and
//! strike limits without forming a module import cycle (bistromath cannot
//! import driver.zig). Keep every shared number here.

/// Starting T2 heat floor (docs/ohaimark.md §3.15). Full threshold is
/// `tier_up_base + 32 * min(code_len, 1<<20)`.
pub const tier_up_base: u32 = 8 * 1024;

/// Function-entry T2 guard-exit budget before dispatch bypasses the entry.
pub const guard_exit_limit: u8 = 4;

/// OSR enter-and-bail strike budget (docs/ohaimark.md §3.17). Cooperative
/// safepoint resumes must not charge this counter.
pub const osr_strike_limit: u8 = 8;

pub fn tierUpThreshold(code_len: usize) u32 {
    const len: u32 = @intCast(@min(code_len, 1 << 20));
    return tier_up_base +| (32 *| len);
}
