//! Bundled re-exports of Cynic's native regex engine (Perlex) and its
//! Unicode resolver, sharing a single Perlex module instance.
//!
//! `unicode/perlex_props.zig` injects the `\p{…}` property resolver and
//! the `/iu` case folder into Perlex's compiler; its `resolve` /
//! `caseFold` signatures are typed against `perlex.PropertyResolver` /
//! `perlex.CaseFoldFn`. Re-exporting both from one module rooted at
//! `src/` guarantees they reference the same `perlex` instance, so an
//! in-process consumer (the `bench-regex` matcher benchmark) can pass
//! the resolver straight into `perlex.compileWithHooks` without a
//! cross-module type mismatch.

pub const perlex = @import("perlex/perlex.zig");
pub const perlex_props = @import("unicode/perlex_props.zig");
