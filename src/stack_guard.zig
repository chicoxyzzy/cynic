//! Shared native-stack-exhaustion guard.
//!
//! Several of the engine's subsystems are recursive descent over
//! user-controlled depth and run on the host (native) stack:
//!   • the bytecode interpreter's native re-entry — a builtin that
//!     calls back into JS (`callJSFunction` → a fresh `runFrames`);
//!   • the JSON parser (`parseValue` → `parseArray` / `parseObject`
//!     → `parseValue`) and its reviver walk;
//!   • the AST parser (`parseAssignment` / `parsePrimary` /
//!     `parseStatement` nesting through `[`, `(`, `{`, prefix `!`…).
//!
//! Each grows the native stack proportional to input nesting depth.
//! Left unbounded, deeply-nested untrusted input (`[[[[…]]]]`,
//! `o = { get x() { return o.x } }; o.x`,
//! `JSON.parse("[".repeat(1e5)+…)`) overflows the stack and faults
//! the process (`EXC_BAD_ACCESS`) — a crash where the spec wants a
//! catchable `RangeError("Maximum call stack size exceeded")`.
//!
//! Rather than each subsystem inventing its own depth magic number
//! (fragile across build modes — an unoptimized frame is far larger
//! — and across thread stack sizes — the test262 harness runs 2 MiB
//! agent workers alongside 16 MiB default workers), they all consult
//! one address-based check that measures *actual remaining native
//! stack*:
//!   • macOS — exact per-thread bounds via `pthread_get_stackaddr_np`
//!     / `pthread_get_stacksize_np`; adapts to each thread's real
//!     stack.
//!   • Other targets — a portable growth-from-base heuristic: the
//!     first call on a thread records its SP; the guard trips once
//!     growth past it exceeds `stack_growth_budget`, chosen below the
//!     smallest stack the engine runs on.
//!
//! The check is a couple of instructions (a stack-address read plus
//! a compare), cheap enough to sit at each recursive entry point.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn pthread_self() *anyopaque;
// Darwin / BSD spelling — returns the stack's *high* address (stack
// grows down). Only referenced under `builtin.os.tag.isDarwin()`.
extern "c" fn pthread_get_stackaddr_np(thread: *anyopaque) *anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: *anyopaque) usize;
// glibc / musl GNU extension — fills `attr` with the running thread's
// attributes (incl. its real stack base + size). Only referenced under
// `builtin.os.tag == .linux`, so the externs never resolve on targets
// (macOS, wasm-freestanding) whose libc lacks them.
extern "c" fn pthread_getattr_np(thread: *anyopaque, attr: *anyopaque) c_int;
extern "c" fn pthread_attr_getstack(attr: *anyopaque, stackaddr: *?*anyopaque, stacksize: *usize) c_int;
extern "c" fn pthread_attr_destroy(attr: *anyopaque) c_int;

/// Headroom kept below the true stack limit: enough for the error
/// allocation plus the worst-case native frames between this check
/// and the actual page guard — it must exceed the stack one full
/// recursion level consumes. Debug builds don't optimize locals, so
/// a single dispatch / parse frame is far larger there; size the red
/// zone per build mode. Release stacks include the harness's 2 MiB
/// agent workers, so the release zone stays modest; Debug only ever
/// runs on the 16 MiB main thread / default workers, where 2 MiB of
/// headroom is comfortable.
const stack_red_zone: usize = switch (builtin.mode) {
    .Debug => 2 * 1024 * 1024,
    else => 256 * 1024,
};

/// Fallback growth allowance for targets without OS stack
/// introspection. Kept below the harness's smallest worker stack
/// (2 MiB `agent_stack`) so the guard always trips before a real
/// overflow regardless of thread stack size.
const stack_growth_budget: usize = 1024 * 1024;

/// Lowest stack address a recursive caller may touch before it must
/// throw, computed once per thread from OS bounds. `0` = not yet
/// computed (or this platform lacks precise bounds — see the
/// fallback base).
threadlocal var stack_limit_addr: usize = 0;
/// Heuristic-path high-water base: the shallowest SP seen on this
/// thread. `growth = base - sp`. Updated upward so a later top-level
/// entry from a shallower context never underflows.
threadlocal var stack_fallback_base: usize = 0;
/// Set once per thread after the first precise-bounds attempt so a
/// platform without OS introspection doesn't re-probe every call.
threadlocal var stack_bounds_probed: bool = false;

/// True when the native stack is within the red zone — the caller
/// must throw `RangeError` (or its parse-phase equivalent) rather
/// than recurse one level deeper. Shared by every recursive-descent
/// subsystem so the bound is consistent and stack-size-adaptive.
pub inline fn nearLimit() bool {
    var probe: u8 = undefined;
    const sp = @intFromPtr(&probe);
    if (stack_limit_addr != 0) return sp <= stack_limit_addr;
    if (!stack_bounds_probed) {
        stack_bounds_probed = true;
        if (builtin.os.tag.isDarwin()) {
            const self = pthread_self();
            const base = @intFromPtr(pthread_get_stackaddr_np(self)); // high addr; stack grows down
            const size = pthread_get_stacksize_np(self);
            if (size > stack_red_zone and base > size) {
                stack_limit_addr = base - size + stack_red_zone;
                return sp <= stack_limit_addr;
            }
        } else if (builtin.os.tag == .linux and builtin.link_libc) {
            // glibc / musl: `pthread_getattr_np` reports the running
            // thread's real stack bounds. `pthread_attr_getstack`
            // returns the LOW address (unlike Darwin's high-address
            // `pthread_get_stackaddr_np`), so the limit is
            // `low + red_zone`. `pthread_attr_t` is opaque and its
            // size varies by libc/arch (glibc x86_64 = 56 B,
            // aarch64 = 64 B; musl = 64 B on LP64); a 16-aligned
            // 128-byte buffer covers every 64-bit target the engine
            // builds for.
            var attr: [128]u8 align(16) = undefined;
            const attr_ptr: *anyopaque = @ptrCast(&attr);
            if (pthread_getattr_np(pthread_self(), attr_ptr) == 0) {
                defer _ = pthread_attr_destroy(attr_ptr);
                var low_ptr: ?*anyopaque = null;
                var size: usize = 0;
                if (pthread_attr_getstack(attr_ptr, &low_ptr, &size) == 0) {
                    const low = @intFromPtr(low_ptr);
                    if (size > stack_red_zone and low != 0) {
                        stack_limit_addr = low + stack_red_zone;
                        return sp <= stack_limit_addr;
                    }
                }
            }
        }
    }
    // Portable growth-from-base fallback.
    if (sp > stack_fallback_base) stack_fallback_base = sp;
    return stack_fallback_base - sp > stack_growth_budget;
}
