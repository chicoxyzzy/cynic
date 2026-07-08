//! Realm snapshots — the CYSN binary image format plus
//! `Snapshot.capture` / `Snapshot.restore`.
//!
//! Serializes a fully-initialized, quiescent realm (post-`Realm.init`
//! + `Realm.installBuiltins`, before any user code) to a byte image
//! and rebuilds an equivalent realm from it, V8-startup-snapshot
//! style. Design, format layout, prior art, and the phase plan live
//! in [docs/realm-snapshots.md](../../docs/realm-snapshots.md); the
//! measured motivation is the ~1.3 ms hardened `installBuiltins`
//! median (two thirds of it the SES `freezePrimordials` pass).
//!
//! Key mechanics (doc §4-§6):
//!
//! - **NaN-box index rewriting** — a serialized `Value` keeps its
//!   64-bit NaN-box encoding verbatim for non-heap tags; the two
//!   heap tags (`0xFFF9` object-family, `0xFFFA` string) have their
//!   48-bit pointer payload rewritten to `(kind << 45) | table_index`
//!   and resolved back through the per-kind restore tables.
//! - **Content-interned keys** — every borrowed `[]const u8` in the
//!   graph (property-map keys, `own_key_order` entries,
//!   `SyntheticAccessor.key`, function `name` slices) is serialized
//!   by content into the KEYS blob, erasing rodata-vs-heap-vs-dupe
//!   provenance. The restored realm owns one copy of the blob
//!   (`Realm.snapshot_key_bytes`, freed at teardown); restored keys
//!   are views into it, so `key_anchors` restore empty by design.
//!   Slices that a `deinit` path frees (`JSString` payloads,
//!   `JSSymbol.{description, prop_key}`) restore as allocator dupes
//!   instead, preserving the teardown contract.
//! - **External references** — `native_callback` code pointers are
//!   serialized as offsets relative to an anchor symbol in the
//!   image. Same-binary-only by construction: the header's
//!   `build_id` (comptime toolchain/mode/intl hash) plus three
//!   code-layout probe offsets gate `restore` fail-closed
//!   (`error.SnapshotBuildMismatch`) — a stale code offset would be
//!   arbitrary-code-execution-grade UB, so there is no best-effort
//!   mode. A snapshot is trusted input in the same sense V8
//!   documents for its snapshots; `restore` still bounds-checks
//!   every offset, count, and table index so a corrupted or
//!   truncated image fails with `error.SnapshotCorrupt`, never a
//!   panic (the never-abort-the-host contract applies to snapshot
//!   bytes too).
//! - **Two-pass restore** — pass 1 allocates every heap header
//!   through the ordinary pools into index→pointer tables (restored
//!   objects GC normally, no special cases; everything restores as
//!   `generation = .mature`); pass 2 decodes records and resolves
//!   references through the tables, rebuilding hashmaps by
//!   insertion so §10.1.11 own-key order is preserved.
//!
//! Capture is fail-closed on scope: object state that cannot occur
//! in a fresh `-Dintl=off` realm (Map/Set data, typed arrays,
//! proxies, pending promises, bound functions, chunk-backed
//! functions, environments, generators, bigints, wasm backings, …)
//! returns `error.SnapshotUnsupported`, and the comptime-exhaustive
//! field walks below fail the *build* when a new field is added to
//! `JSObject` / `JSObjectExtension` / `JSFunction` until it is
//! classified here (doc §8 R2).

const std = @import("std");
const builtin = @import("builtin");

const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const object_mod = @import("object.zig");
const JSObject = object_mod.JSObject;
const JSObjectExtension = object_mod.JSObjectExtension;
const PropertyFlags = object_mod.PropertyFlags;
const Accessor = object_mod.Accessor;
const function_mod = @import("function.zig");
const JSFunction = function_mod.JSFunction;
const SyntheticAccessor = function_mod.SyntheticAccessor;
const NativeFn = function_mod.NativeFn;
const string_mod = @import("string.zig");
const JSString = string_mod.JSString;
const JSSymbol = @import("symbol.zig").JSSymbol;
const shape_mod = @import("shape.zig");
const Shape = shape_mod.Shape;
const realm_mod = @import("realm.zig");
const Realm = realm_mod.Realm;
const Intrinsics = @import("intrinsics.zig").Intrinsics;
const features = @import("features.zig");
const intl_config = @import("intl_config.zig");

/// The on-disk encoding is the in-memory NaN-box encoding with
/// payload rewriting — 64-bit little-endian hosts only, exactly
/// like NaN-boxing itself (value.zig). Checked lazily (inside
/// `capture` / `restore`) rather than in a top-level `comptime`
/// block so merely importing this file — e.g. from a wasm32
/// playground build that never references `Snapshot` — cannot
/// fail the build.
fn comptimeHostGuard() void {
    comptime {
        if (builtin.cpu.arch.endian() != .little)
            @compileError("CYSN snapshots require a little-endian host");
        if (@sizeOf(usize) != 8)
            @compileError("CYSN snapshots require a 64-bit host");
    }
}

// ── Format constants ────────────────────────────────────────────────

const magic = "CYSN";
const format_version: u32 = 1;

/// Comptime build identity — toolchain + build mode + ISA + intl
/// flavour. Deliberately conservative: any of these changing means
/// anchor-relative code offsets are meaningless. `build.zig`
/// plumbing for a git-SHA component is a doc §5.2 follow-up; until
/// then the layout probes below carry the source-identity load.
const build_id: u64 = blk: {
    var h = std.hash.Fnv1a_64.init();
    h.update("CYSN\x01");
    h.update(builtin.zig_version_string);
    h.update(@tagName(builtin.mode));
    h.update(@tagName(builtin.cpu.arch));
    h.update(if (intl_config.has_locale_data) "intl=full" else if (intl_config.enabled) "intl=stub" else "intl=off");
    break :blk h.final();
};

/// Anchor symbol for external-reference encoding. Any always-linked
/// function works; within one build of a statically-linked binary,
/// function addresses are fixed relative to the image base, so
/// ASLR cancels out of anchor-relative offsets.
fn anchorAddr() usize {
    return @intFromPtr(&Realm.installBuiltins);
}

/// Three additional code addresses, anchor-relative. Two distinct
/// builds of the engine essentially never agree on all three
/// inter-function distances, so these act as a practical
/// binary-layout fingerprint on top of `build_id`.
fn layoutProbes() [3]u64 {
    const a = anchorAddr();
    return .{
        @intFromPtr(&Heap.allocateObject) -% a,
        @intFromPtr(&JSObject.getOrCreateExtension) -% a,
        @intFromPtr(&shape_mod.ShapeTree.transition) -% a,
    };
}

// Section tags (ASCII, read as little-endian u32).
fn sectionTag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .little);
}
const tag_keys = sectionTag("KEYS");
const tag_strs = sectionTag("STRS");
const tag_syms = sectionTag("SYMS");
const tag_shap = sectionTag("SHAP");
const tag_cell = sectionTag("CELL");
const tag_objs = sectionTag("OBJS");
const tag_fncs = sectionTag("FNCS");
const tag_extr = sectionTag("EXTR");
const tag_relm = sectionTag("RELM");
const tag_chck = sectionTag("CHCK");

// Header field offsets (all little-endian).
const header_len: usize = 96; // magic..section_count inclusive
const off_version: usize = 4;
const off_build_id: usize = 8;
const off_probes: usize = 16; // 3 × u64
const off_flags: usize = 40;
const off_features: usize = 48;
const off_proto_rev: usize = 56;
const off_proto_epoch: usize = 64;
const off_next_symbol_id: usize = 72;
const off_class_brand: usize = 80; // u32
const off_decl_revision: usize = 84; // u64
const off_section_count: usize = 92; // u32
const section_entry_len: usize = 20; // tag u32 + offset u64 + len u64

// Posture flag bits in the header `flags` word.
const flag_hardened: u64 = 1 << 0;
const flag_allow_eval: u64 = 1 << 1;
const flag_allow_wasm: u64 = 1 << 2;
const flag_agent_can_block: u64 = 1 << 3;
const flag_jit_enabled: u64 = 1 << 4;

// On-disk Value heap-payload layout: bits 45..47 = pool kind,
// bits 0..44 = table index (doc §4.1).
const ref_kind_shift: u6 = 45;
const ref_index_mask: u64 = (1 << 45) - 1;
const ref_kind_string: u64 = 4; // kinds 0..3 mirror heap.kind_*

// Per-object/function record field tags (doc §4.2 tagged encoding —
// default-valued fields are simply absent; an unknown tag is a
// decode error, so a record can't silently smuggle state).
const obj_tag_end: u8 = 0;
const obj_tag_properties: u8 = 1;
const obj_tag_property_flags: u8 = 2;
const obj_tag_shape: u8 = 3;
const obj_tag_slots: u8 = 4;
const obj_tag_prototype: u8 = 5;
const obj_tag_prototype_fn: u8 = 6;
const obj_tag_elements: u8 = 7;
const obj_tag_own_key_order: u8 = 8;
const obj_tag_accessors: u8 = 9;
const obj_tag_regexp_source: u8 = 10;
const obj_tag_regexp_flags: u8 = 11;
const obj_tag_boxed_primitive: u8 = 12;
const obj_tag_boxed_string: u8 = 13;
const obj_tag_date_ms: u8 = 14;

const fn_tag_end: u8 = 0;
const fn_tag_name: u8 = 1;
const fn_tag_name_string: u8 = 2;
const fn_tag_prototype: u8 = 3;
const fn_tag_proto: u8 = 4;
const fn_tag_home_object: u8 = 5;
const fn_tag_home_function: u8 = 6;
const fn_tag_static_parent: u8 = 7;
const fn_tag_synth_accessor: u8 = 8;
const fn_tag_properties: u8 = 9;
const fn_tag_property_flags: u8 = 10;
const fn_tag_accessors: u8 = 11;
const fn_tag_own_key_order: u8 = 12;
const fn_tag_captured_this: u8 = 13;
const fn_tag_captured_new_target: u8 = 14;
const fn_tag_bound_this: u8 = 15;

// Intrinsics-field type bytes in the RELM section.
const intr_null: u8 = 0;
const intr_object: u8 = 1;
const intr_function: u8 = 2;
const intr_value: u8 = 3;

fn flagsToByte(f: PropertyFlags) u8 {
    var b: u8 = 0;
    if (f.writable) b |= 1;
    if (f.enumerable) b |= 2;
    if (f.configurable) b |= 4;
    return b;
}

fn flagsFromByte(b: u8) PropertyFlags {
    return .{ .writable = b & 1 != 0, .enumerable = b & 2 != 0, .configurable = b & 4 != 0 };
}

fn featureBits(set: features.FeatureSet) u64 {
    var bits: u64 = 0;
    inline for (comptime std.meta.fieldNames(features.FeatureFlag)) |name| {
        const flag = @field(features.FeatureFlag, name);
        comptime std.debug.assert(@intFromEnum(flag) < 64);
        if (set.contains(flag)) bits |= @as(u64, 1) << @intFromEnum(flag);
    }
    return bits;
}

fn featureSetFromBits(bits: u64) features.FeatureSet {
    var set = features.FeatureSet.initEmpty();
    inline for (comptime std.meta.fieldNames(features.FeatureFlag)) |name| {
        const flag = @field(features.FeatureFlag, name);
        if (bits & (@as(u64, 1) << @intFromEnum(flag)) != 0) set.insert(flag);
    }
    return set;
}

// ── Comptime-exhaustive field classification (doc §8 R2) ────────────
//
// Every field of the three big structs must appear in exactly one of
// the lists below. Adding a field to the struct without classifying
// it here fails the BUILD — the alternative is a restored realm that
// silently drops state.

/// Fields `serializeObject` / `restoreObject` encode.
const object_serialized_fields = [_][]const u8{
    "kind",                  "properties",          "property_flags", "shape",
    "inline_slots",          "slot_count",          "overflow_slots", "prototype",
    "prototype_fn",          "extensible",          "proxy_callable", "is_array_exotic",
    "array_length_writable", "is_arguments_exotic", "is_raw_json",    "has_error_data",
    "elements",              "own_key_order",       "extension",      "regexp_source",
    "regexp_flags",          "needs_internal_scan", "is_pristine",
};
/// Fields recomputed / re-defaulted at restore (GC header, heap
/// back-pointer, dropped-by-design anchors).
const object_recomputed_fields = [_][]const u8{
    "heap", "mark_color", "generation", "dirty", "key_anchors",
};
/// Fields that must be at their default at capture — non-default
/// means the object is outside the phase-1 envelope
/// (`error.SnapshotUnsupported`).
const object_asserted_fields = [_][]const u8{
    "array_like_iter",          "map_set_iter",          "regexp_string_iter",  "iter_record",
    "iter_helper",              "promise_store",         "promise_state",       "promise_value",
    "promise_already_resolved", "proxy_target",          "proxy_handler",       "proxy_target_fn",
    "proxy_revoked",            "regex_perlex",          "is_weak_ref",         "is_shadow_realm",
    "is_module_namespace",      "is_sparse",             "sparse_elements",     "sparse_length",
    "elements_pooled",          "has_array_buffer_data", "array_buffer_shared",
};

const extension_serialized_fields = [_][]const u8{
    "accessors", "boxed_primitive", "boxed_string", "date_ms",
};
const extension_asserted_fields = [_][]const u8{
    "private_properties",           "private_methods",          "private_accessors",
    "namespace_redirects",          "ambiguous_namespace_keys", "map_data",
    "set_data",                     "wasm_module",              "wasm_global",
    "wasm_table",                   "wasm_memory",              "wasm_tag",
    "wasm_exception",               "capability_record",        "generator_ref",
    "finally_callback",             "finally_value",            "finally_constructor",
    "instance_field_inits",         "private_method_inits",     "private_brand",
    "private_compile_prefix",       "weak_ref_target",          "finalization_cells",
    "array_buffer",                 "array_buffer_external",    "shared_block",
    "array_buffer_max_byte_length", "typed_view",               "data_view",
    "host_data",                    "shadow_realm_owner",       "disposable_state",
    "disposable_resources",         "async_dispose_walk",       "temporal_record",
    "intl_record",
};

const function_serialized_fields = [_][]const u8{
    "kind",           "native_callback",     "param_count",              "name",
    "name_string",    "is_arrow",            "constructor_kind",         "is_class_constructor",
    "has_construct",  "defers_proto_lookup", "native_ordinary_function", "is_generator",
    "is_async",       "captured_this",       "captured_new_target",      "home_object",
    "home_function",  "static_parent",       "synth_accessor",           "properties",
    "property_flags", "accessors",           "prototype",                "proto",
    "extensible",     "own_key_order",       "bound_this",
};
const function_recomputed_fields = [_][]const u8{
    "realm", "heap", "mark_color", "generation", "dirty", "key_anchors",
};
const function_asserted_fields = [_][]const u8{
    "chunk",             "source",          "captured_env",           "owning_module",
    "super_called_cell", "bound_target",    "bound_args",             "wasm_export",
    "wrapped_target",    "revocable_proxy", "private_properties",     "private_accessors",
    "private_methods",   "private_brand",   "private_compile_prefix",
};

fn assertExhaustive(comptime T: type, comptime lists: []const []const []const u8) void {
    comptime {
        @setEvalBranchQuota(100_000);
        for (std.meta.fieldNames(T)) |field_name| {
            var handled = false;
            for (lists) |list| {
                for (list) |name| {
                    if (std.mem.eql(u8, name, field_name)) handled = true;
                }
            }
            if (!handled) @compileError("snapshot.zig: unclassified " ++ @typeName(T) ++
                " field '" ++ field_name ++ "' — add it to the serialized / " ++
                "recomputed / asserted-default lists and handle it in the codec");
        }
    }
}

comptime {
    assertExhaustive(JSObject, &.{ &object_serialized_fields, &object_recomputed_fields, &object_asserted_fields });
    assertExhaustive(JSObjectExtension, &.{ &extension_serialized_fields, &extension_asserted_fields });
    assertExhaustive(JSFunction, &.{ &function_serialized_fields, &function_recomputed_fields, &function_asserted_fields });
}

// ── Byte-stream writer / reader ─────────────────────────────────────

const Writer = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    fn w8(self: *Writer, v: u8) !void {
        try self.buf.append(self.allocator, v);
    }
    fn w32(self: *Writer, v: u32) !void {
        try self.buf.appendSlice(self.allocator, std.mem.asBytes(&v));
    }
    fn w64(self: *Writer, v: u64) !void {
        try self.buf.appendSlice(self.allocator, std.mem.asBytes(&v));
    }
    fn bytes(self: *Writer, b: []const u8) !void {
        try self.buf.appendSlice(self.allocator, b);
    }
    fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn r8(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return error.SnapshotCorrupt;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn r32(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return error.SnapshotCorrupt;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn r64(self: *Reader) !u64 {
        if (self.pos + 8 > self.data.len) return error.SnapshotCorrupt;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn atEnd(self: *const Reader) bool {
        return self.pos == self.data.len;
    }
};

// ── Capture ─────────────────────────────────────────────────────────

pub const Snapshot = struct {
    pub const CaptureError = error{ OutOfMemory, RealmNotQuiescent, SnapshotUnsupported };
    pub const RestoreError = error{ OutOfMemory, SnapshotCorrupt, SnapshotVersionMismatch, SnapshotBuildMismatch };

    /// Serialize a quiescent, fully-installed realm. Runs a full GC
    /// first so the heap pools contain only live objects, then
    /// serializes them wholesale (everything in the pools is
    /// reachable from the realm's roots). Caller owns the returned
    /// bytes.
    pub fn capture(realm: *Realm, allocator: std.mem.Allocator) Snapshot.CaptureError![]u8 {
        comptimeHostGuard();
        var cap = Capture.init(allocator, realm);
        defer cap.deinit();
        return cap.run();
    }

    /// Rebuild a realm from a snapshot image. Returns a
    /// heap-allocated `Realm` (stable address — required by
    /// `registerWithHeap` and the finalization-enqueue context),
    /// registered with its fresh heap, host hooks re-installed,
    /// ready for `evaluateScript`. The snapshot header's posture
    /// flags are authoritative. Caller tears down via
    /// `realm.deinit()` + `allocator.destroy(realm)`.
    pub fn restore(allocator: std.mem.Allocator, image: []const u8) RestoreError!*Realm {
        comptimeHostGuard();
        return restoreImage(allocator, image);
    }
};

const KeyRef = struct { off: u32, len: u32 };

const Capture = struct {
    allocator: std.mem.Allocator,
    realm: *Realm,

    // Content-interned key blob (doc §5.3): map from content to
    // blob offset. The map's keys are views into `key_blob`, which
    // never shrinks; ArrayList growth may move the blob, so the map
    // is keyed by an owned copy? No — keyed by offset+len pairs
    // resolved through the blob would invalidate on growth, so the
    // map stores content hashes: content -> KeyRef with the map key
    // slice OWNED by the map (duped).
    key_blob: std.ArrayListUnmanaged(u8) = .empty,
    key_map: std.StringHashMapUnmanaged(KeyRef) = .empty,

    string_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    object_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    function_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    symbol_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    cell_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    shape_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    extr_index: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    extr_list: std.ArrayListUnmanaged(u64) = .empty,

    strings: std.ArrayListUnmanaged(*JSString) = .empty,
    objects: std.ArrayListUnmanaged(*JSObject) = .empty,
    functions: std.ArrayListUnmanaged(*JSFunction) = .empty,
    symbols: std.ArrayListUnmanaged(*JSSymbol) = .empty,
    shapes: std.ArrayListUnmanaged(*Shape) = .empty,

    fn init(allocator: std.mem.Allocator, realm: *Realm) Capture {
        return .{ .allocator = allocator, .realm = realm };
    }

    fn deinit(self: *Capture) void {
        self.key_blob.deinit(self.allocator);
        var it = self.key_map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.key_map.deinit(self.allocator);
        self.string_index.deinit(self.allocator);
        self.object_index.deinit(self.allocator);
        self.function_index.deinit(self.allocator);
        self.symbol_index.deinit(self.allocator);
        self.cell_index.deinit(self.allocator);
        self.shape_index.deinit(self.allocator);
        self.extr_index.deinit(self.allocator);
        self.extr_list.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.objects.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
    }

    fn internKey(self: *Capture, content: []const u8) !KeyRef {
        if (self.key_map.get(content)) |ref| return ref;
        if (content.len > std.math.maxInt(u32)) return error.SnapshotUnsupported;
        if (self.key_blob.items.len > std.math.maxInt(u32)) return error.SnapshotUnsupported;
        const ref: KeyRef = .{ .off = @intCast(self.key_blob.items.len), .len = @intCast(content.len) };
        try self.key_blob.appendSlice(self.allocator, content);
        const owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned);
        try self.key_map.put(self.allocator, owned, ref);
        return ref;
    }

    fn writeKeyRef(self: *Capture, w: *Writer, content: []const u8) !void {
        const ref = try self.internKey(content);
        try w.w32(ref.off);
        try w.w32(ref.len);
    }

    fn externRef(self: *Capture, cb: NativeFn) !u64 {
        const addr = @intFromPtr(cb);
        if (self.extr_index.get(addr)) |idx| return idx;
        const idx: u64 = self.extr_list.items.len;
        try self.extr_list.append(self.allocator, @intFromPtr(cb) -% anchorAddr());
        try self.extr_index.put(self.allocator, addr, idx);
        return idx;
    }

    /// Encode a `Value` for the image (doc §4.1): non-heap tags are
    /// pure bits, heap tags get their payload rewritten to
    /// `(kind << 45) | index`.
    fn encodeValue(self: *Capture, v: Value) Snapshot.CaptureError!u64 {
        if (!v.isHeapValue()) return v.bits;
        if (v.isString()) {
            const p: *JSString = @ptrCast(@alignCast(v.asString()));
            const idx = self.string_index.get(@intFromPtr(p)) orelse return error.SnapshotUnsupported;
            return (@as(u64, Value.tag_string) << 48) | (ref_kind_string << ref_kind_shift) | idx;
        }
        // Object-family pointer — low 2 payload bits select the kind.
        if (heap_mod.valueAsFunction(v)) |f| {
            const idx = self.function_index.get(@intFromPtr(f)) orelse return error.SnapshotUnsupported;
            return (@as(u64, Value.tag_object) << 48) | (heap_mod.kind_function << ref_kind_shift) | idx;
        }
        if (heap_mod.valueAsPlainObject(v)) |o| {
            const idx = self.object_index.get(@intFromPtr(o)) orelse return error.SnapshotUnsupported;
            return (@as(u64, Value.tag_object) << 48) | (heap_mod.kind_object << ref_kind_shift) | idx;
        }
        if (heap_mod.valueAsSymbol(v)) |s| {
            const idx = self.symbol_index.get(@intFromPtr(s)) orelse return error.SnapshotUnsupported;
            return (@as(u64, Value.tag_object) << 48) | (heap_mod.kind_symbol << ref_kind_shift) | idx;
        }
        // BigInt — none exist in a fresh realm (asserted in run()).
        return error.SnapshotUnsupported;
    }

    fn objectRef(self: *Capture, o: *JSObject) Snapshot.CaptureError!u64 {
        return self.object_index.get(@intFromPtr(o)) orelse error.SnapshotUnsupported;
    }
    fn functionRef(self: *Capture, f: *JSFunction) Snapshot.CaptureError!u64 {
        return self.function_index.get(@intFromPtr(f)) orelse error.SnapshotUnsupported;
    }
    fn stringRef(self: *Capture, s: *JSString) Snapshot.CaptureError!u64 {
        return self.string_index.get(@intFromPtr(s)) orelse error.SnapshotUnsupported;
    }

    fn checkQuiescent(self: *Capture) Snapshot.CaptureError!void {
        const realm = self.realm;
        const heap = realm.heap;
        // Doc §6.1 — the capture envelope. Transient runtime state
        // must be empty; a realm mid-execution (or one that has run
        // user code) is refused rather than mis-captured.
        if (realm.microtask_queue.items.len != 0 or
            realm.frame_stacks.items.len != 0 or
            realm.kept_alive.items.len != 0 or
            realm.pending_async_waits.items.len != 0 or
            realm.modules.count() != 0 or
            realm.script_chunks.items.len != 0 or
            realm.eval_sources.items.len != 0 or
            realm.child_realms.items.len != 0 or
            realm.derived_ctor_cells.items.len != 0 or
            realm.pending_exception != null or
            realm.current_module != null or
            realm.jit_active_frames != null)
        {
            return error.RealmNotQuiescent;
        }
        if (heap.handle_scopes.items.len != 0 or
            heap.const_roots.items.len != 0 or
            heap.native_ctor_roots.items.len != 0 or
            heap.realms.items.len != 1)
        {
            return error.RealmNotQuiescent;
        }
        // NOTE: `class_arena` may be non-null here — the accessor
        // installers allocate display-name strings ("get x",
        // "[Symbol.iterator]") from it at install time. Those are
        // borrowed name slices, which the KEYS content-interning
        // erases the provenance of, so the arena itself needs no
        // serialization. Class *state* (field inits, brands) is
        // rejected per-object by the comptime-exhaustive walks.
        if (realm.wasm_arena != null or heap.jit_code != null) {
            return error.SnapshotUnsupported;
        }
        if (realm.globals.target == null or
            realm.globals.fallback.count() != 0 or
            realm.globals.decl_env.count() != 0 or
            realm.globals.decl_consts.count() != 0 or
            realm.globals.var_names.count() != 0)
        {
            return error.SnapshotUnsupported;
        }
        // Kinds with no phase-1 codec must be absent entirely.
        if (heap.environmentCount() != 0 or heap.generatorCount() != 0 or heap.bigintCount() != 0) {
            return error.SnapshotUnsupported;
        }
    }

    fn run(self: *Capture) Snapshot.CaptureError![]u8 {
        try self.checkQuiescent();
        // Pre-capture full GC (doc §6.1): afterwards everything in
        // the pools is live and rooted, so capture serializes the
        // per-kind lists wholesale — no reachability trace needed.
        self.realm.collectGarbage();
        try self.checkQuiescent();
        const heap = self.realm.heap;

        // Index assignment: young then mature, per kind.
        try self.indexKind(*JSString, &self.strings, &self.string_index, heap.strings_young.items, heap.strings_mature.items);
        try self.indexKind(*JSObject, &self.objects, &self.object_index, heap.objects_young.items, heap.objects_mature.items);
        try self.indexKind(*JSFunction, &self.functions, &self.function_index, heap.functions_young.items, heap.functions_mature.items);
        try self.indexKind(*JSSymbol, &self.symbols, &self.symbol_index, heap.symbols_young.items, heap.symbols_mature.items);
        for (self.realm.synth_accessor_cells.items, 0..) |cell, i| {
            try self.cell_index.put(self.allocator, @intFromPtr(cell), i);
        }
        try self.collectShapes();

        var strs = Writer{ .allocator = self.allocator };
        defer strs.deinit();
        var syms = Writer{ .allocator = self.allocator };
        defer syms.deinit();
        var shap = Writer{ .allocator = self.allocator };
        defer shap.deinit();
        var cell = Writer{ .allocator = self.allocator };
        defer cell.deinit();
        var objs = Writer{ .allocator = self.allocator };
        defer objs.deinit();
        var fncs = Writer{ .allocator = self.allocator };
        defer fncs.deinit();
        var extr = Writer{ .allocator = self.allocator };
        defer extr.deinit();
        var relm = Writer{ .allocator = self.allocator };
        defer relm.deinit();

        try self.serializeStrings(&strs);
        try self.serializeSymbols(&syms);
        try self.serializeShapes(&shap);
        try self.serializeCells(&cell);
        try objs.w32(@intCast(self.objects.items.len));
        for (self.objects.items) |o| try self.serializeObject(&objs, o);
        try fncs.w32(@intCast(self.functions.items.len));
        for (self.functions.items) |f| try self.serializeFunction(&fncs, f);
        try self.serializeRealm(&relm);
        // EXTR last — every distinct native callback has been seen.
        try extr.w32(@intCast(self.extr_list.items.len));
        for (self.extr_list.items) |off| try extr.w64(off);

        return self.assemble(&.{
            .{ .tag = tag_keys, .data = self.key_blob.items },
            .{ .tag = tag_strs, .data = strs.buf.items },
            .{ .tag = tag_syms, .data = syms.buf.items },
            .{ .tag = tag_shap, .data = shap.buf.items },
            .{ .tag = tag_cell, .data = cell.buf.items },
            .{ .tag = tag_objs, .data = objs.buf.items },
            .{ .tag = tag_fncs, .data = fncs.buf.items },
            .{ .tag = tag_extr, .data = extr.buf.items },
            .{ .tag = tag_relm, .data = relm.buf.items },
        });
    }

    fn indexKind(
        self: *Capture,
        comptime P: type,
        list: *std.ArrayListUnmanaged(P),
        index: *std.AutoHashMapUnmanaged(usize, u64),
        young: []const P,
        mature: []const P,
    ) !void {
        try list.ensureTotalCapacity(self.allocator, young.len + mature.len);
        for (young) |p| list.appendAssumeCapacity(p);
        for (mature) |p| list.appendAssumeCapacity(p);
        try index.ensureTotalCapacity(self.allocator, @intCast(list.items.len));
        for (list.items, 0..) |p, i| index.putAssumeCapacity(@intFromPtr(p), i);
    }

    fn collectShapes(self: *Capture) !void {
        // BFS from the tree root: parents always precede children,
        // which is what the loader's single forward pass needs.
        const root = self.realm.heap.shapes.root;
        try self.shapes.append(self.allocator, root);
        try self.shape_index.put(self.allocator, @intFromPtr(root), 0);
        var cursor: usize = 0;
        while (cursor < self.shapes.items.len) : (cursor += 1) {
            const node = self.shapes.items[cursor];
            for (node.transitions.items) |t| {
                if (self.shape_index.contains(@intFromPtr(t.child))) continue;
                const idx: u64 = self.shapes.items.len;
                try self.shapes.append(self.allocator, t.child);
                try self.shape_index.put(self.allocator, @intFromPtr(t.child), idx);
            }
        }
    }

    fn serializeStrings(self: *Capture, w: *Writer) !void {
        try w.w32(@intCast(self.strings.items.len));
        const bytes_allocator = self.realm.heap.bytes_allocator;
        for (self.strings.items) |s| {
            // Ropes flatten at capture (doc §3.5) — the image holds
            // only flat payloads.
            const flat = s.flatten(bytes_allocator) catch return error.OutOfMemory;
            try w.w8(if (s.pinned) 1 else 0);
            try w.w32(s.length_cu);
            try self.writeKeyRef(w, flat);
        }
    }

    fn serializeSymbols(self: *Capture, w: *Writer) !void {
        try w.w32(@intCast(self.symbols.items.len));
        for (self.symbols.items) |s| {
            try w.w8(if (s.description != null) 1 else 0);
            if (s.description) |d| try self.writeKeyRef(w, d);
            try self.writeKeyRef(w, s.prop_key);
            try w.w8(if (s.is_registered) 1 else 0);
            try w.w8(if (s.pinned) 1 else 0);
        }
    }

    fn serializeShapes(self: *Capture, w: *Writer) !void {
        try w.w32(@intCast(self.shapes.items.len));
        for (self.shapes.items, 0..) |node, i| {
            if (node.parent) |p| {
                const pidx = self.shape_index.get(@intFromPtr(p)) orelse return error.SnapshotUnsupported;
                try w.w32(@intCast(pidx));
            } else {
                if (i != 0) return error.SnapshotUnsupported; // only the root is parentless
                try w.w32(std.math.maxInt(u32));
            }
            try self.writeKeyRef(w, node.key);
            try w.w8(flagsToByte(node.attrs));
            try w.w8(@intFromEnum(node.kind));
            try w.w32(node.slot);
            try w.w32(node.property_count);
        }
    }

    fn serializeCells(self: *Capture, w: *Writer) !void {
        const cells = self.realm.synth_accessor_cells.items;
        try w.w32(@intCast(cells.len));
        for (cells) |c| {
            try w.w64(try self.encodeValue(c.value));
            try self.writeKeyRef(w, c.key);
            try w.w8(if (c.is_setter) 1 else 0);
        }
    }

    fn writeValueMap(self: *Capture, w: *Writer, map: *const std.StringArrayHashMapUnmanaged(Value)) !void {
        try w.w32(@intCast(map.count()));
        var it = map.iterator();
        while (it.next()) |e| {
            try self.writeKeyRef(w, e.key_ptr.*);
            try w.w64(try self.encodeValue(e.value_ptr.*));
        }
    }

    fn writeFlagsMap(self: *Capture, w: *Writer, map: *const std.StringArrayHashMapUnmanaged(PropertyFlags)) !void {
        try w.w32(@intCast(map.count()));
        var it = map.iterator();
        while (it.next()) |e| {
            try self.writeKeyRef(w, e.key_ptr.*);
            try w.w8(flagsToByte(e.value_ptr.*));
        }
    }

    fn writeAccessorMap(self: *Capture, w: *Writer, map: *const std.StringArrayHashMapUnmanaged(Accessor)) !void {
        try w.w32(@intCast(map.count()));
        var it = map.iterator();
        while (it.next()) |e| {
            try self.writeKeyRef(w, e.key_ptr.*);
            const a = e.value_ptr.*;
            try w.w32(if (a.getter) |g| @intCast((try self.functionRef(g)) + 1) else 0);
            try w.w32(if (a.setter) |s| @intCast((try self.functionRef(s)) + 1) else 0);
        }
    }

    fn writeKeyList(self: *Capture, w: *Writer, list: []const []const u8) !void {
        try w.w32(@intCast(list.len));
        for (list) |k| try self.writeKeyRef(w, k);
    }

    fn serializeObject(self: *Capture, w: *Writer, o: *JSObject) Snapshot.CaptureError!void {
        // Asserted-default fields (comptime-exhaustive contract):
        // any deviation puts the object outside the phase-1 envelope.
        if (o.array_like_iter != null or o.map_set_iter != null or
            o.regexp_string_iter != null or o.iter_record != null or
            o.iter_helper != null or o.promise_store != null or
            o.promise_state != .none or !o.promise_value.isUndefined() or
            o.promise_already_resolved or o.proxy_target != null or
            o.proxy_handler != null or o.proxy_target_fn != null or
            o.proxy_revoked or o.regex_perlex != null or o.is_weak_ref or
            o.is_shadow_realm or o.is_module_namespace or o.is_sparse or
            o.sparse_elements.count() != 0 or o.sparse_length != 0 or
            o.elements_pooled or o.has_array_buffer_data or o.array_buffer_shared)
        {
            return error.SnapshotUnsupported;
        }

        var flags0: u8 = 0;
        if (o.extensible) flags0 |= 1 << 0;
        if (o.needs_internal_scan) flags0 |= 1 << 1;
        if (o.is_pristine) flags0 |= 1 << 2;
        if (o.proxy_callable) flags0 |= 1 << 3;
        if (o.is_array_exotic) flags0 |= 1 << 4;
        if (o.array_length_writable) flags0 |= 1 << 5;
        if (o.is_arguments_exotic) flags0 |= 1 << 6;
        if (o.is_raw_json) flags0 |= 1 << 7;
        var flags1: u8 = 0;
        if (o.has_error_data) flags1 |= 1 << 0;
        try w.w8(flags0);
        try w.w8(flags1);

        if (o.properties.count() != 0) {
            try w.w8(obj_tag_properties);
            try self.writeValueMap(w, &o.properties);
        }
        if (o.property_flags.count() != 0) {
            try w.w8(obj_tag_property_flags);
            try self.writeFlagsMap(w, &o.property_flags);
        }
        if (o.shape) |s| {
            try w.w8(obj_tag_shape);
            const idx = self.shape_index.get(@intFromPtr(s)) orelse return error.SnapshotUnsupported;
            try w.w32(@intCast(idx));
        }
        if (o.slotCount() != 0) {
            try w.w8(obj_tag_slots);
            try w.w32(@intCast(o.slotCount()));
            for (0..o.slotCount()) |i| try w.w64(try self.encodeValue(o.slotAt(i)));
        }
        if (o.prototype) |p| {
            try w.w8(obj_tag_prototype);
            try w.w32(@intCast(try self.objectRef(p)));
        }
        if (o.prototype_fn) |p| {
            try w.w8(obj_tag_prototype_fn);
            try w.w32(@intCast(try self.functionRef(p)));
        }
        if (o.elements.items.len != 0) {
            try w.w8(obj_tag_elements);
            try w.w32(@intCast(o.elements.items.len));
            for (o.elements.items) |v| try w.w64(try self.encodeValue(v));
        }
        if (o.own_key_order.items.len != 0) {
            try w.w8(obj_tag_own_key_order);
            try self.writeKeyList(w, o.own_key_order.items);
        }
        if (o.extension) |ext| try self.serializeExtension(w, ext);
        if (o.regexp_source) |s| {
            try w.w8(obj_tag_regexp_source);
            try w.w32(@intCast(try self.stringRef(s)));
        }
        if (o.regexp_flags) |s| {
            try w.w8(obj_tag_regexp_flags);
            try w.w32(@intCast(try self.stringRef(s)));
        }
        try w.w8(obj_tag_end);
    }

    fn serializeExtension(self: *Capture, w: *Writer, ext: *JSObjectExtension) Snapshot.CaptureError!void {
        // Asserted-default extension fields (doc §6.1): only the
        // override-mistake accessors plus a handful of scalar slots
        // occur in a fresh realm.
        if (ext.private_properties.count() != 0 or ext.private_methods.count() != 0 or
            ext.private_accessors.count() != 0 or ext.namespace_redirects.count() != 0 or
            ext.ambiguous_namespace_keys.count() != 0 or ext.map_data != null or
            ext.set_data != null or ext.wasm_module != null or ext.wasm_global != null or
            ext.wasm_table != null or ext.wasm_memory != null or ext.wasm_tag != null or
            ext.wasm_exception != null or ext.capability_record != null or
            ext.generator_ref != null or ext.finally_callback != null or
            !ext.finally_value.isUndefined() or ext.finally_constructor != null or
            ext.instance_field_inits != null or ext.private_method_inits != null or
            ext.private_brand.len != 0 or ext.private_compile_prefix.len != 0 or
            !ext.weak_ref_target.isUndefined() or ext.finalization_cells != null or
            ext.array_buffer != null or ext.array_buffer_external or
            ext.shared_block != null or ext.array_buffer_max_byte_length != null or
            ext.typed_view != null or ext.data_view != null or ext.host_data != null or
            ext.shadow_realm_owner != null or ext.disposable_state != null or
            ext.disposable_resources.items.len != 0 or ext.async_dispose_walk != null or
            ext.temporal_record != null or ext.intl_record != null)
        {
            return error.SnapshotUnsupported;
        }
        if (ext.accessors.count() != 0) {
            try w.w8(obj_tag_accessors);
            try self.writeAccessorMap(w, &ext.accessors);
        }
        if (ext.boxed_primitive) |v| {
            try w.w8(obj_tag_boxed_primitive);
            try w.w64(try self.encodeValue(v));
        }
        if (ext.boxed_string) |s| {
            try w.w8(obj_tag_boxed_string);
            try w.w32(@intCast(try self.stringRef(s)));
        }
        if (ext.date_ms) |ms| {
            try w.w8(obj_tag_date_ms);
            try w.w64(@bitCast(ms));
        }
    }

    fn serializeFunction(self: *Capture, w: *Writer, f: *JSFunction) Snapshot.CaptureError!void {
        if (f.chunk != null or f.source != null or f.captured_env != null or
            f.owning_module != null or f.super_called_cell != null or
            f.bound_target != null or f.bound_args != null or f.wasm_export != null or
            !f.wrapped_target.isUndefined() or f.revocable_proxy != null or
            f.private_properties.count() != 0 or f.private_accessors.count() != 0 or
            f.private_methods.count() != 0 or f.private_brand.len != 0 or
            f.private_compile_prefix.len != 0)
        {
            return error.SnapshotUnsupported;
        }
        // §10.2.5 [[Realm]] — phase 1 is single-realm; a function
        // stamped with a sibling realm has no restore analogue.
        if (f.realm) |r| {
            if (r != self.realm) return error.SnapshotUnsupported;
        }

        var flags0: u8 = 0;
        if (f.is_arrow) flags0 |= 1 << 0;
        if (f.has_construct) flags0 |= 1 << 1;
        if (f.is_class_constructor) flags0 |= 1 << 2;
        if (f.defers_proto_lookup) flags0 |= 1 << 3;
        if (f.native_ordinary_function) flags0 |= 1 << 4;
        if (f.is_generator) flags0 |= 1 << 5;
        if (f.is_async) flags0 |= 1 << 6;
        if (f.extensible) flags0 |= 1 << 7;
        try w.w8(flags0);
        try w.w8(@intFromEnum(f.constructor_kind));
        try w.w8(f.param_count);
        try w.w32(if (f.native_callback) |cb| @intCast((try self.externRef(cb)) + 1) else 0);

        if (f.name) |n| {
            try w.w8(fn_tag_name);
            try self.writeKeyRef(w, n);
        }
        if (f.name_string) |s| {
            try w.w8(fn_tag_name_string);
            try w.w32(@intCast(try self.stringRef(s)));
        }
        if (f.prototype) |p| {
            try w.w8(fn_tag_prototype);
            try w.w32(@intCast(try self.objectRef(p)));
        }
        if (f.proto) |p| {
            try w.w8(fn_tag_proto);
            try w.w32(@intCast(try self.objectRef(p)));
        }
        if (f.home_object) |p| {
            try w.w8(fn_tag_home_object);
            try w.w32(@intCast(try self.objectRef(p)));
        }
        if (f.home_function) |p| {
            try w.w8(fn_tag_home_function);
            try w.w32(@intCast(try self.functionRef(p)));
        }
        if (f.static_parent) |p| {
            try w.w8(fn_tag_static_parent);
            try w.w32(@intCast(try self.functionRef(p)));
        }
        if (f.synth_accessor) |c| {
            try w.w8(fn_tag_synth_accessor);
            const idx = self.cell_index.get(@intFromPtr(c)) orelse return error.SnapshotUnsupported;
            try w.w32(@intCast(idx));
        }
        if (f.properties.count() != 0) {
            try w.w8(fn_tag_properties);
            try self.writeValueMap(w, &f.properties);
        }
        if (f.property_flags.count() != 0) {
            try w.w8(fn_tag_property_flags);
            try self.writeFlagsMap(w, &f.property_flags);
        }
        if (f.accessors.count() != 0) {
            try w.w8(fn_tag_accessors);
            try self.writeAccessorMap(w, &f.accessors);
        }
        if (f.own_key_order.items.len != 0) {
            try w.w8(fn_tag_own_key_order);
            try self.writeKeyList(w, f.own_key_order.items);
        }
        if (!f.captured_this.isUndefined()) {
            try w.w8(fn_tag_captured_this);
            try w.w64(try self.encodeValue(f.captured_this));
        }
        if (!f.captured_new_target.isUndefined()) {
            try w.w8(fn_tag_captured_new_target);
            try w.w64(try self.encodeValue(f.captured_new_target));
        }
        if (!f.bound_this.isUndefined()) {
            try w.w8(fn_tag_bound_this);
            try w.w64(try self.encodeValue(f.bound_this));
        }
        try w.w8(fn_tag_end);
    }

    fn serializeRealm(self: *Capture, w: *Writer) Snapshot.CaptureError!void {
        const realm = self.realm;
        const heap = realm.heap;
        // globalThis (must exist — checked in checkQuiescent).
        try w.w32(@intCast(try self.objectRef(realm.globals.target.?)));
        // heap.function_prototype.
        try w.w32(if (heap.function_prototype) |fp| @intCast((try self.objectRef(fp)) + 1) else 0);
        // Intrinsics — comptime field order, gated by build_id.
        const intr_names = comptime std.meta.fieldNames(Intrinsics);
        try w.w32(@intCast(intr_names.len));
        inline for (intr_names) |field_name| {
            const v = @field(realm.intrinsics, field_name);
            const T = @TypeOf(v);
            if (T == ?*JSObject) {
                if (v) |o| {
                    try w.w8(intr_object);
                    try w.w32(@intCast(try self.objectRef(o)));
                } else try w.w8(intr_null);
            } else if (T == ?*JSFunction) {
                if (v) |f| {
                    try w.w8(intr_function);
                    try w.w32(@intCast(try self.functionRef(f)));
                } else try w.w8(intr_null);
            } else if (T == Value) {
                try w.w8(intr_value);
                try w.w64(try self.encodeValue(v));
            } else {
                @compileError("snapshot.zig: unhandled Intrinsics field type for '" ++ field_name ++ "'");
            }
        }
        // small_int_strings cache (lazily populated — refs or 0).
        try w.w32(Heap.small_int_cache_max);
        for (heap.small_int_strings) |maybe| {
            try w.w32(if (maybe) |s| @intCast((try self.stringRef(s)) + 1) else 0);
        }
        // Symbol.for registry (§20.4.2.2) — empty at init, encoded
        // anyway so a warmup snapshot needs no format bump.
        try w.w32(@intCast(heap.symbol_registry.count()));
        var it = heap.symbol_registry.iterator();
        while (it.next()) |e| {
            try self.writeKeyRef(w, e.key_ptr.*);
            const idx = self.symbol_index.get(@intFromPtr(e.value_ptr.*)) orelse return error.SnapshotUnsupported;
            try w.w32(@intCast(idx));
        }
    }

    const Section = struct { tag: u32, data: []const u8 };

    fn assemble(self: *Capture, sections: []const Section) ![]u8 {
        const realm = self.realm;
        var out = Writer{ .allocator = self.allocator };
        errdefer out.deinit();

        try out.bytes(magic);
        try out.w32(format_version);
        try out.w64(build_id);
        for (layoutProbes()) |p| try out.w64(p);
        var flags: u64 = 0;
        if (realm.hardened) flags |= flag_hardened;
        if (realm.allow_eval) flags |= flag_allow_eval;
        if (realm.allow_wasm) flags |= flag_allow_wasm;
        if (realm.agent_can_block) flags |= flag_agent_can_block;
        if (realm.jit_enabled) flags |= flag_jit_enabled;
        try out.w64(flags);
        try out.w64(featureBits(realm.feature_flags));
        try out.w64(realm.proto_revision_counter);
        try out.w64(realm.heap.proto_struct_epoch);
        try out.w64(realm.heap.next_symbol_id);
        try out.w32(realm.heap.class_brand_counter);
        try out.w64(realm.globals.decl_revision);
        std.debug.assert(out.buf.items.len == off_section_count);
        try out.w32(@intCast(sections.len + 1)); // + CHCK

        // Section table, then payloads. CHCK is the final section:
        // a Wyhash over every prior section's payload bytes.
        var hasher = std.hash.Wyhash.init(0xC15A_C15A_C15A_C15A);
        var offset: u64 = header_len + (sections.len + 1) * section_entry_len;
        for (sections) |s| {
            try out.w32(s.tag);
            try out.w64(offset);
            try out.w64(s.data.len);
            offset += s.data.len;
            hasher.update(s.data);
        }
        try out.w32(tag_chck);
        try out.w64(offset);
        try out.w64(8);
        for (sections) |s| try out.bytes(s.data);
        try out.w64(hasher.final());

        return out.buf.toOwnedSlice(self.allocator);
    }
};

// ── Restore ─────────────────────────────────────────────────────────

const SectionSlices = struct {
    keys: []const u8,
    strs: []const u8,
    syms: []const u8,
    shap: []const u8,
    cell: []const u8,
    objs: []const u8,
    fncs: []const u8,
    extr: []const u8,
    relm: []const u8,
};

fn restoreImage(allocator: std.mem.Allocator, image: []const u8) Snapshot.RestoreError!*Realm {
    // ── Header gates (fail-closed; every read bounds-checked) ──
    if (image.len < header_len) return error.SnapshotCorrupt;
    if (!std.mem.eql(u8, image[0..4], magic)) return error.SnapshotVersionMismatch;
    if (std.mem.readInt(u32, image[off_version..][0..4], .little) != format_version)
        return error.SnapshotVersionMismatch;
    if (std.mem.readInt(u64, image[off_build_id..][0..8], .little) != build_id)
        return error.SnapshotBuildMismatch;
    const probes = layoutProbes();
    for (probes, 0..) |p, i| {
        if (std.mem.readInt(u64, image[off_probes + i * 8 ..][0..8], .little) != p)
            return error.SnapshotBuildMismatch;
    }
    const flags = std.mem.readInt(u64, image[off_flags..][0..8], .little);
    const feature_bits = std.mem.readInt(u64, image[off_features..][0..8], .little);
    const section_count = std.mem.readInt(u32, image[off_section_count..][0..4], .little);
    if (section_count > 64) return error.SnapshotCorrupt;

    // ── Section table + integrity hash ──
    const table_end = header_len + @as(usize, section_count) * section_entry_len;
    if (table_end > image.len) return error.SnapshotCorrupt;
    var sections: SectionSlices = undefined;
    var seen: u32 = 0;
    var chck: ?u64 = null;
    var hasher = std.hash.Wyhash.init(0xC15A_C15A_C15A_C15A);
    for (0..section_count) |i| {
        const entry = image[header_len + i * section_entry_len ..][0..section_entry_len];
        const tag = std.mem.readInt(u32, entry[0..4], .little);
        const off = std.mem.readInt(u64, entry[4..12], .little);
        const len = std.mem.readInt(u64, entry[12..20], .little);
        if (off > image.len or len > image.len - off) return error.SnapshotCorrupt;
        const data = image[@intCast(off)..][0..@intCast(len)];
        if (tag == tag_chck) {
            if (len != 8) return error.SnapshotCorrupt;
            chck = std.mem.readInt(u64, data[0..8], .little);
            continue;
        }
        hasher.update(data);
        seen += 1;
        if (tag == tag_keys) sections.keys = data else if (tag == tag_strs) sections.strs = data else if (tag == tag_syms) sections.syms = data else if (tag == tag_shap) sections.shap = data else if (tag == tag_cell) sections.cell = data else if (tag == tag_objs) sections.objs = data else if (tag == tag_fncs) sections.fncs = data else if (tag == tag_extr) sections.extr = data else if (tag == tag_relm) sections.relm = data else return error.SnapshotCorrupt;
    }
    if (seen != 9 or chck == null) return error.SnapshotCorrupt;
    if (hasher.final() != chck.?) return error.SnapshotCorrupt;

    // ── Fresh realm shell ──
    const realm = try allocator.create(Realm);
    errdefer allocator.destroy(realm);
    realm.* = Realm.init(allocator);
    errdefer realm.deinit();

    realm.hardened = flags & flag_hardened != 0;
    realm.allow_eval = flags & flag_allow_eval != 0;
    realm.allow_wasm = flags & flag_allow_wasm != 0;
    realm.agent_can_block = flags & flag_agent_can_block != 0;
    realm.jit_enabled = flags & flag_jit_enabled != 0;
    realm.feature_flags = featureSetFromBits(feature_bits);
    realm.proto_revision_counter = std.mem.readInt(u64, image[off_proto_rev..][0..8], .little);
    realm.globals.decl_revision = std.mem.readInt(u64, image[off_decl_revision..][0..8], .little);
    realm.heap.proto_struct_epoch = std.mem.readInt(u64, image[off_proto_epoch..][0..8], .little);
    realm.heap.next_symbol_id = std.mem.readInt(u64, image[off_next_symbol_id..][0..8], .little);
    realm.heap.class_brand_counter = std.mem.readInt(u32, image[off_class_brand..][0..4], .little);

    try realm.registerWithHeap();
    // §26.2 — mirror installBuiltins' finalization hook wiring.
    realm.heap.setFinalizationEnqueue(realm, restoredFinalizationEnqueue);

    // The realm owns one copy of the KEYS blob; every restored
    // borrowed key is a view into it (doc §5.3).
    realm.snapshot_key_bytes = try allocator.dupe(u8, sections.keys);

    var rst = Restore{
        .allocator = allocator,
        .realm = realm,
        .keys = realm.snapshot_key_bytes.?,
    };
    defer rst.deinit();
    try rst.run(&sections);
    return realm;
}

/// §26.2 FinalizationRegistry cleanup-job scheduler for restored
/// realms — mirrors the (private) hook `Realm.installBuiltins`
/// wires. OOM is swallowed: §26.2 permits skipping a cleanup job.
fn restoredFinalizationEnqueue(ctx: *anyopaque, callback: Value, held_value: Value) void {
    const realm: *Realm = @ptrCast(@alignCast(ctx));
    realm.enqueueMicrotask(callback, held_value) catch {};
}

const Restore = struct {
    allocator: std.mem.Allocator,
    realm: *Realm,
    keys: []const u8,

    strings: std.ArrayListUnmanaged(*JSString) = .empty,
    objects: std.ArrayListUnmanaged(*JSObject) = .empty,
    functions: std.ArrayListUnmanaged(*JSFunction) = .empty,
    symbols: std.ArrayListUnmanaged(*JSSymbol) = .empty,
    cells: std.ArrayListUnmanaged(*SyntheticAccessor) = .empty,
    shapes: std.ArrayListUnmanaged(*Shape) = .empty,
    externs: std.ArrayListUnmanaged(NativeFn) = .empty,

    fn deinit(self: *Restore) void {
        self.strings.deinit(self.allocator);
        self.objects.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.externs.deinit(self.allocator);
    }

    fn keyRef(self: *Restore, r: *Reader) ![]const u8 {
        const off = try r.r32();
        const len = try r.r32();
        if (off > self.keys.len or len > self.keys.len - off) return error.SnapshotCorrupt;
        return self.keys[off..][0..len];
    }

    fn decodeValue(self: *Restore, bits: u64) !Value {
        const tag: u16 = @intCast(bits >> 48);
        if (tag == Value.tag_string) {
            if ((bits >> ref_kind_shift) & 7 != ref_kind_string) return error.SnapshotCorrupt;
            const idx = bits & ref_index_mask;
            if (idx >= self.strings.items.len) return error.SnapshotCorrupt;
            return Value.fromString(self.strings.items[@intCast(idx)]);
        }
        if (tag == Value.tag_object) {
            const kind = (bits >> ref_kind_shift) & 7;
            const idx = bits & ref_index_mask;
            switch (kind) {
                heap_mod.kind_function => {
                    if (idx >= self.functions.items.len) return error.SnapshotCorrupt;
                    return heap_mod.taggedFunction(self.functions.items[@intCast(idx)]);
                },
                heap_mod.kind_object => {
                    if (idx >= self.objects.items.len) return error.SnapshotCorrupt;
                    return heap_mod.taggedObject(self.objects.items[@intCast(idx)]);
                },
                heap_mod.kind_symbol => {
                    if (idx >= self.symbols.items.len) return error.SnapshotCorrupt;
                    return heap_mod.taggedSymbol(self.symbols.items[@intCast(idx)]);
                },
                else => return error.SnapshotCorrupt,
            }
        }
        return .{ .bits = bits };
    }

    fn readValue(self: *Restore, r: *Reader) !Value {
        return self.decodeValue(try r.r64());
    }

    fn objectAt(self: *Restore, idx: u32) !*JSObject {
        if (idx >= self.objects.items.len) return error.SnapshotCorrupt;
        return self.objects.items[idx];
    }
    fn functionAt(self: *Restore, idx: u32) !*JSFunction {
        if (idx >= self.functions.items.len) return error.SnapshotCorrupt;
        return self.functions.items[idx];
    }
    fn stringAt(self: *Restore, idx: u32) !*JSString {
        if (idx >= self.strings.items.len) return error.SnapshotCorrupt;
        return self.strings.items[idx];
    }
    fn shapeAt(self: *Restore, idx: u32) !*Shape {
        if (idx >= self.shapes.items.len) return error.SnapshotCorrupt;
        return self.shapes.items[idx];
    }

    fn run(self: *Restore, sections: *const SectionSlices) !void {
        const heap = self.realm.heap;

        try self.restoreExterns(sections.extr);
        try self.restoreShapes(sections.shap);

        // ── Pass 1 — allocate headers through the ordinary pools
        // into the index→pointer tables. Every header is
        // default-initialized immediately so a mid-restore failure
        // tears down cleanly through the normal heap paths.
        var strs = Reader{ .data = sections.strs };
        const str_count = try strs.r32();
        try self.reserveCount(str_count, sections.strs.len);
        var syms = Reader{ .data = sections.syms };
        const sym_count = try syms.r32();
        try self.reserveCount(sym_count, sections.syms.len);
        var fncs = Reader{ .data = sections.fncs };
        const fn_count = try fncs.r32();
        try self.reserveCount(fn_count, sections.fncs.len);
        var objs = Reader{ .data = sections.objs };
        const obj_count = try objs.r32();
        try self.reserveCount(obj_count, sections.objs.len);

        try self.strings.ensureTotalCapacity(self.allocator, str_count);
        try heap.strings_mature.ensureUnusedCapacity(heap.allocator, str_count);
        for (0..str_count) |_| {
            const s = try heap.string_pool.create(heap.allocator);
            s.* = .{ .length_cu = 0, .byte_len = 0, .payload = .{ .flat = &.{} }, .generation = .mature, .mark_color = heap.live_color };
            heap.strings_mature.appendAssumeCapacity(s);
            self.strings.appendAssumeCapacity(s);
        }
        try self.symbols.ensureTotalCapacity(self.allocator, sym_count);
        try heap.symbols_mature.ensureUnusedCapacity(heap.allocator, sym_count);
        for (0..sym_count) |_| {
            const s = try heap.allocator.create(JSSymbol);
            s.* = .{ .description = null, .prop_key = &.{}, .generation = .mature, .mark_color = heap.live_color };
            heap.symbols_mature.appendAssumeCapacity(s);
            self.symbols.appendAssumeCapacity(s);
        }
        try self.functions.ensureTotalCapacity(self.allocator, fn_count);
        try heap.functions_mature.ensureUnusedCapacity(heap.allocator, fn_count);
        for (0..fn_count) |_| {
            const f = try heap.allocator.create(JSFunction);
            f.* = .{ .param_count = 0, .name = null, .generation = .mature, .mark_color = heap.live_color };
            f.heap = heap;
            f.realm = self.realm;
            heap.functions_mature.appendAssumeCapacity(f);
            self.functions.appendAssumeCapacity(f);
        }
        try self.objects.ensureTotalCapacity(self.allocator, obj_count);
        try heap.objects_mature.ensureUnusedCapacity(heap.allocator, obj_count);
        for (0..obj_count) |_| {
            const o = try heap.object_pool.create(heap.allocator);
            o.* = .{ .kind = .object, .generation = .mature, .mark_color = heap.live_color };
            o.heap = heap;
            heap.objects_mature.appendAssumeCapacity(o);
            self.objects.appendAssumeCapacity(o);
        }

        // Cells before functions (functions reference them); cell
        // values may reference any heap kind — tables exist now.
        try self.restoreCells(sections.cell);

        // ── Pass 2 — fill.
        for (0..str_count) |i| try self.fillString(&strs, self.strings.items[i]);
        if (!strs.atEnd()) return error.SnapshotCorrupt;
        for (0..sym_count) |i| try self.fillSymbol(&syms, self.symbols.items[i]);
        if (!syms.atEnd()) return error.SnapshotCorrupt;
        for (0..fn_count) |i| try self.fillFunction(&fncs, self.functions.items[i]);
        if (!fncs.atEnd()) return error.SnapshotCorrupt;
        for (0..obj_count) |i| try self.fillObject(&objs, self.objects.items[i]);
        if (!objs.atEnd()) return error.SnapshotCorrupt;

        try self.restoreRealmSection(sections.relm);
    }

    /// Cheap structural sanity bound: a count of N entries needs at
    /// least one byte each, so `count > section length` is corrupt —
    /// this keeps a hostile count from driving a huge allocation.
    fn reserveCount(self: *Restore, count: u32, section_len: usize) !void {
        _ = self;
        if (count > section_len) return error.SnapshotCorrupt;
    }

    fn restoreExterns(self: *Restore, data: []const u8) !void {
        var r = Reader{ .data = data };
        const count = try r.r32();
        if (count > data.len) return error.SnapshotCorrupt;
        try self.externs.ensureTotalCapacity(self.allocator, count);
        const anchor = anchorAddr();
        for (0..count) |_| {
            const off = try r.r64();
            // Build-gated (build_id + layout probes verified above):
            // within the same binary this reconstructs the exact
            // function address the capturing process held.
            const addr = anchor +% @as(usize, @intCast(off & std.math.maxInt(usize)));
            self.externs.appendAssumeCapacity(@ptrFromInt(addr));
        }
        if (!r.atEnd()) return error.SnapshotCorrupt;
    }

    fn restoreShapes(self: *Restore, data: []const u8) !void {
        const heap = self.realm.heap;
        var r = Reader{ .data = data };
        const count = try r.r32();
        if (count == 0 or count > data.len) return error.SnapshotCorrupt;
        try self.shapes.ensureTotalCapacity(self.allocator, count);
        const arena = heap.shapes.arena.allocator();
        for (0..count) |i| {
            const parent_idx = try r.r32();
            const key = try self.keyRef(&r);
            const attrs = flagsFromByte(try r.r8());
            const kind_byte = try r.r8();
            if (kind_byte > 1) return error.SnapshotCorrupt;
            const kind: shape_mod.PropKind = @enumFromInt(kind_byte);
            const slot = try r.r32();
            const property_count = try r.r32();
            if (i == 0) {
                // Node 0 is the root — maps onto the fresh tree's
                // root (allocated by Heap.init).
                if (parent_idx != std.math.maxInt(u32) or property_count != 0) return error.SnapshotCorrupt;
                self.shapes.appendAssumeCapacity(heap.shapes.root);
                continue;
            }
            if (parent_idx >= i) return error.SnapshotCorrupt; // parents precede children
            const parent = self.shapes.items[parent_idx];
            const owned_key = try arena.dupe(u8, key);
            const child = try arena.create(Shape);
            child.* = .{
                .parent = parent,
                .key = owned_key,
                .attrs = attrs,
                .kind = kind,
                .slot = slot,
                .property_count = property_count,
                .transitions = .empty,
            };
            // Register the transition edge so post-restore
            // transitions dedupe against this tree exactly as
            // against the original (doc §5.4).
            try parent.transitions.append(arena, .{
                .key = owned_key,
                .attrs = attrs,
                .kind = kind,
                .child = child,
            });
            self.shapes.appendAssumeCapacity(child);
        }
        if (!r.atEnd()) return error.SnapshotCorrupt;
    }

    fn restoreCells(self: *Restore, data: []const u8) !void {
        var r = Reader{ .data = data };
        const count = try r.r32();
        if (count > data.len) return error.SnapshotCorrupt;
        try self.cells.ensureTotalCapacity(self.allocator, count);
        try self.realm.synth_accessor_cells.ensureTotalCapacity(self.realm.allocator, count);
        for (0..count) |_| {
            const value = try self.readValue(&r);
            const key = try self.keyRef(&r);
            const is_setter = (try r.r8()) != 0;
            const cell = try self.realm.allocator.create(SyntheticAccessor);
            cell.* = .{ .value = value, .key = key, .is_setter = is_setter };
            self.realm.synth_accessor_cells.appendAssumeCapacity(cell);
            self.cells.appendAssumeCapacity(cell);
        }
        if (!r.atEnd()) return error.SnapshotCorrupt;
    }

    fn fillString(self: *Restore, r: *Reader, s: *JSString) !void {
        const heap = self.realm.heap;
        const pinned = (try r.r8()) != 0;
        const length_cu = try r.r32();
        const content = try self.keyRef(r);
        // JSString payloads are freed through `bytes_allocator` at
        // sweep/teardown, so they must be owned dupes, not KEYS
        // views (doc §5.3's owned-vs-borrowed rule).
        const owned = try heap.bytes_allocator.dupe(u8, content);
        s.pinned = pinned;
        s.length_cu = length_cu;
        s.byte_len = @intCast(owned.len);
        s.payload = .{ .flat = owned };
    }

    fn fillSymbol(self: *Restore, r: *Reader, s: *JSSymbol) !void {
        const allocator = self.realm.heap.allocator;
        const has_desc = (try r.r8()) != 0;
        if (has_desc) {
            const d = try self.keyRef(r);
            s.description = try allocator.dupe(u8, d);
        }
        const pk = try self.keyRef(r);
        s.prop_key = try allocator.dupe(u8, pk);
        s.is_registered = (try r.r8()) != 0;
        s.pinned = (try r.r8()) != 0;
    }

    fn readValueMap(self: *Restore, r: *Reader, map: *std.StringArrayHashMapUnmanaged(Value)) !void {
        const allocator = self.realm.allocator;
        const count = try r.r32();
        if (count > r.data.len) return error.SnapshotCorrupt;
        try map.ensureTotalCapacity(allocator, count);
        for (0..count) |_| {
            const key = try self.keyRef(r);
            const value = try self.readValue(r);
            map.putAssumeCapacity(key, value);
        }
    }

    fn readFlagsMap(self: *Restore, r: *Reader, map: *std.StringArrayHashMapUnmanaged(PropertyFlags)) !void {
        const allocator = self.realm.allocator;
        const count = try r.r32();
        if (count > r.data.len) return error.SnapshotCorrupt;
        try map.ensureTotalCapacity(allocator, count);
        for (0..count) |_| {
            const key = try self.keyRef(r);
            const flags = flagsFromByte(try r.r8());
            map.putAssumeCapacity(key, flags);
        }
    }

    fn readAccessorMap(self: *Restore, r: *Reader, map: *std.StringArrayHashMapUnmanaged(Accessor)) !void {
        const allocator = self.realm.allocator;
        const count = try r.r32();
        if (count > r.data.len) return error.SnapshotCorrupt;
        try map.ensureTotalCapacity(allocator, count);
        for (0..count) |_| {
            const key = try self.keyRef(r);
            const getter_idx = try r.r32();
            const setter_idx = try r.r32();
            const getter: ?*JSFunction = if (getter_idx == 0) null else try self.functionAt(getter_idx - 1);
            const setter: ?*JSFunction = if (setter_idx == 0) null else try self.functionAt(setter_idx - 1);
            map.putAssumeCapacity(key, .{ .getter = getter, .setter = setter });
        }
    }

    fn readKeyList(self: *Restore, r: *Reader, list: *std.ArrayListUnmanaged([]const u8)) !void {
        const allocator = self.realm.allocator;
        const count = try r.r32();
        if (count > r.data.len) return error.SnapshotCorrupt;
        try list.ensureTotalCapacity(allocator, count);
        for (0..count) |_| list.appendAssumeCapacity(try self.keyRef(r));
    }

    fn fillObject(self: *Restore, r: *Reader, o: *JSObject) !void {
        const allocator = self.realm.allocator;
        const flags0 = try r.r8();
        const flags1 = try r.r8();
        o.extensible = flags0 & (1 << 0) != 0;
        o.needs_internal_scan = flags0 & (1 << 1) != 0;
        const restored_pristine = flags0 & (1 << 2) != 0;
        o.proxy_callable = flags0 & (1 << 3) != 0;
        o.is_array_exotic = flags0 & (1 << 4) != 0;
        o.array_length_writable = flags0 & (1 << 5) != 0;
        o.is_arguments_exotic = flags0 & (1 << 6) != 0;
        o.is_raw_json = flags0 & (1 << 7) != 0;
        o.has_error_data = flags1 & (1 << 0) != 0;

        while (true) {
            const tag = try r.r8();
            switch (tag) {
                obj_tag_end => break,
                obj_tag_properties => try self.readValueMap(r, &o.properties),
                obj_tag_property_flags => try self.readFlagsMap(r, &o.property_flags),
                obj_tag_shape => o.shape = try self.shapeAt(try r.r32()),
                obj_tag_slots => {
                    const n = try r.r32();
                    if (n > r.data.len) return error.SnapshotCorrupt;
                    try o.resizeSlots(allocator, n);
                    for (0..n) |i| o.setSlot(i, try self.readValue(r));
                },
                obj_tag_prototype => o.prototype = try self.objectAt(try r.r32()),
                obj_tag_prototype_fn => o.prototype_fn = try self.functionAt(try r.r32()),
                obj_tag_elements => {
                    const n = try r.r32();
                    if (n > r.data.len) return error.SnapshotCorrupt;
                    try o.elements.ensureTotalCapacity(allocator, n);
                    for (0..n) |_| o.elements.appendAssumeCapacity(try self.readValue(r));
                },
                obj_tag_own_key_order => try self.readKeyList(r, &o.own_key_order),
                obj_tag_accessors => {
                    const ext = try o.getOrCreateExtension(allocator);
                    try self.readAccessorMap(r, &ext.accessors);
                },
                obj_tag_regexp_source => o.regexp_source = try self.stringAt(try r.r32()),
                obj_tag_regexp_flags => o.regexp_flags = try self.stringAt(try r.r32()),
                obj_tag_boxed_primitive => {
                    const ext = try o.getOrCreateExtension(allocator);
                    ext.boxed_primitive = try self.readValue(r);
                },
                obj_tag_boxed_string => {
                    const ext = try o.getOrCreateExtension(allocator);
                    ext.boxed_string = try self.stringAt(try r.r32());
                },
                obj_tag_date_ms => {
                    const ext = try o.getOrCreateExtension(allocator);
                    ext.date_ms = @bitCast(try r.r64());
                },
                else => return error.SnapshotCorrupt,
            }
        }
        // `is_pristine` round-trips last: the fills above cleared it
        // via markNonPristine for any object with attached state; a
        // truly pristine record had no tagged fields so restoring
        // `true` is consistent with the field contract either way.
        o.is_pristine = restored_pristine;
    }

    fn fillFunction(self: *Restore, r: *Reader, f: *JSFunction) !void {
        const flags0 = try r.r8();
        f.is_arrow = flags0 & (1 << 0) != 0;
        f.has_construct = flags0 & (1 << 1) != 0;
        f.is_class_constructor = flags0 & (1 << 2) != 0;
        f.defers_proto_lookup = flags0 & (1 << 3) != 0;
        f.native_ordinary_function = flags0 & (1 << 4) != 0;
        f.is_generator = flags0 & (1 << 5) != 0;
        f.is_async = flags0 & (1 << 6) != 0;
        f.extensible = flags0 & (1 << 7) != 0;
        const ctor_kind = try r.r8();
        if (ctor_kind > 1) return error.SnapshotCorrupt;
        f.constructor_kind = @enumFromInt(ctor_kind);
        f.param_count = try r.r8();
        const cb_idx = try r.r32();
        if (cb_idx != 0) {
            if (cb_idx - 1 >= self.externs.items.len) return error.SnapshotCorrupt;
            f.native_callback = self.externs.items[cb_idx - 1];
        }

        while (true) {
            const tag = try r.r8();
            switch (tag) {
                fn_tag_end => break,
                fn_tag_name => f.name = try self.keyRef(r),
                fn_tag_name_string => f.name_string = try self.stringAt(try r.r32()),
                fn_tag_prototype => f.prototype = try self.objectAt(try r.r32()),
                fn_tag_proto => f.proto = try self.objectAt(try r.r32()),
                fn_tag_home_object => f.home_object = try self.objectAt(try r.r32()),
                fn_tag_home_function => f.home_function = try self.functionAt(try r.r32()),
                fn_tag_static_parent => f.static_parent = try self.functionAt(try r.r32()),
                fn_tag_synth_accessor => {
                    const idx = try r.r32();
                    if (idx >= self.cells.items.len) return error.SnapshotCorrupt;
                    f.synth_accessor = self.cells.items[idx];
                },
                fn_tag_properties => try self.readValueMap(r, &f.properties),
                fn_tag_property_flags => try self.readFlagsMap(r, &f.property_flags),
                fn_tag_accessors => try self.readAccessorMap(r, &f.accessors),
                fn_tag_own_key_order => try self.readKeyList(r, &f.own_key_order),
                fn_tag_captured_this => f.captured_this = try self.readValue(r),
                fn_tag_captured_new_target => f.captured_new_target = try self.readValue(r),
                fn_tag_bound_this => f.bound_this = try self.readValue(r),
                else => return error.SnapshotCorrupt,
            }
        }
    }

    fn restoreRealmSection(self: *Restore, data: []const u8) !void {
        const realm = self.realm;
        const heap = realm.heap;
        var r = Reader{ .data = data };

        // globalThis — the realm's object env-record target.
        realm.globals.target = try self.objectAt(try r.r32());

        const fp_idx = try r.r32();
        heap.function_prototype = if (fp_idx == 0) null else try self.objectAt(fp_idx - 1);

        // Intrinsics — same comptime field order as capture
        // (build_id-gated).
        const intr_names = comptime std.meta.fieldNames(Intrinsics);
        const intr_count = try r.r32();
        if (intr_count != intr_names.len) return error.SnapshotCorrupt;
        inline for (intr_names) |field_name| {
            const T = @TypeOf(@field(realm.intrinsics, field_name));
            const type_byte = try r.r8();
            switch (type_byte) {
                intr_null => {
                    if (T == Value) return error.SnapshotCorrupt;
                },
                intr_object => {
                    if (T != ?*JSObject) return error.SnapshotCorrupt;
                    if (T == ?*JSObject) @field(realm.intrinsics, field_name) = try self.objectAt(try r.r32());
                },
                intr_function => {
                    if (T != ?*JSFunction) return error.SnapshotCorrupt;
                    if (T == ?*JSFunction) @field(realm.intrinsics, field_name) = try self.functionAt(try r.r32());
                },
                intr_value => {
                    if (T != Value) return error.SnapshotCorrupt;
                    if (T == Value) @field(realm.intrinsics, field_name) = try self.readValue(&r);
                },
                else => return error.SnapshotCorrupt,
            }
        }

        // small_int_strings cache.
        const sis_count = try r.r32();
        if (sis_count != Heap.small_int_cache_max) return error.SnapshotCorrupt;
        for (0..Heap.small_int_cache_max) |i| {
            const idx = try r.r32();
            heap.small_int_strings[i] = if (idx == 0) null else try self.stringAt(idx - 1);
        }

        // Symbol.for registry.
        const reg_count = try r.r32();
        if (reg_count > data.len) return error.SnapshotCorrupt;
        try heap.symbol_registry.ensureTotalCapacity(heap.allocator, reg_count);
        for (0..reg_count) |_| {
            const key = try self.keyRef(&r);
            const idx = try r.r32();
            if (idx >= self.symbols.items.len) return error.SnapshotCorrupt;
            heap.symbol_registry.putAssumeCapacity(key, self.symbols.items[idx]);
        }
        if (!r.atEnd()) return error.SnapshotCorrupt;
    }
};

// ────────────────────────────────────────────────────────────────────
// Tests (docs/handbook/tdd.md — tests live with the code).
// ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const lantern = @import("lantern/interpreter.zig");

fn makeInstalledRealm(allocator: std.mem.Allocator, hardened: bool) !*Realm {
    const realm = try allocator.create(Realm);
    realm.* = Realm.init(allocator);
    realm.hardened = hardened;
    try realm.installBuiltins();
    return realm;
}

fn destroyRealm(allocator: std.mem.Allocator, realm: *Realm) void {
    realm.deinit();
    allocator.destroy(realm);
}

/// Evaluate `src` and return the completion value; fails the test
/// on a thrown completion.
fn evalValue(realm: *Realm, src: []const u8) !Value {
    const result = try lantern.evaluateScript(testing.allocator, realm, src);
    return switch (result) {
        .value => |v| v,
        else => error.TestUnexpectedResult,
    };
}

/// Evaluate `src` (which must produce a string) and compare against
/// `expected`.
fn expectEvalString(realm: *Realm, src: []const u8, expected: []const u8) !void {
    const v = try evalValue(realm, src);
    if (!v.isString()) return error.TestUnexpectedResult;
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqualStrings(expected, s.flatBytes());
}

fn expectEvalBool(realm: *Realm, src: []const u8, expected: bool) !void {
    const v = try evalValue(realm, src);
    try testing.expect(v.isBool());
    try testing.expectEqual(expected, v.asBool());
}

test "snapshot: restore rejects a truncated buffer" {
    try testing.expectError(error.SnapshotCorrupt, Snapshot.restore(testing.allocator, &.{}));
    try testing.expectError(error.SnapshotCorrupt, Snapshot.restore(testing.allocator, "CYSN\x01\x00\x00\x00short"));
}

test "snapshot: restore rejects wrong magic and version" {
    var buf: [header_len]u8 = @splat(0);
    @memcpy(buf[0..4], "NOPE");
    try testing.expectError(error.SnapshotVersionMismatch, Snapshot.restore(testing.allocator, &buf));
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[off_version..][0..4], format_version + 1, .little);
    try testing.expectError(error.SnapshotVersionMismatch, Snapshot.restore(testing.allocator, &buf));
}

test "snapshot: restore rejects a build-id mismatch" {
    var buf: [header_len]u8 = @splat(0);
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[off_version..][0..4], format_version, .little);
    std.mem.writeInt(u64, buf[off_build_id..][0..8], build_id ^ 1, .little);
    try testing.expectError(error.SnapshotBuildMismatch, Snapshot.restore(testing.allocator, &buf));
}

test "snapshot: capture refuses a non-quiescent realm" {
    const realm = try makeInstalledRealm(testing.allocator, true);
    defer destroyRealm(testing.allocator, realm);
    try realm.enqueueMicrotask(Value.undefined_, Value.undefined_);
    try testing.expectError(error.RealmNotQuiescent, Snapshot.capture(realm, testing.allocator));
}

test "snapshot: corrupted payload byte fails the integrity check, flipped build-id byte fails the gate" {
    const realm = try makeInstalledRealm(testing.allocator, true);
    defer destroyRealm(testing.allocator, realm);
    const image = try Snapshot.capture(realm, testing.allocator);
    defer testing.allocator.free(image);

    // Flip one byte in the payload region (past header + table) —
    // CHCK must catch it.
    const mutable = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(mutable);
    mutable[mutable.len - 32] ^= 0x40;
    try testing.expectError(error.SnapshotCorrupt, Snapshot.restore(testing.allocator, mutable));

    // Flip a build-id byte — the gate must fire before anything is
    // decoded.
    const mutable2 = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(mutable2);
    mutable2[off_build_id] ^= 0xFF;
    try testing.expectError(error.SnapshotBuildMismatch, Snapshot.restore(testing.allocator, mutable2));
}

test "snapshot: hardened realm round-trip preserves per-kind heap counts" {
    const realm = try makeInstalledRealm(testing.allocator, true);
    const image = try Snapshot.capture(realm, testing.allocator);
    defer testing.allocator.free(image);
    // Counts post-capture (capture ran a full GC).
    const want_strings = realm.heap.stringCount();
    const want_objects = realm.heap.objectCount();
    const want_functions = realm.heap.functionCount();
    const want_symbols = realm.heap.symbolCount();
    const want_cells = realm.synth_accessor_cells.items.len;
    destroyRealm(testing.allocator, realm);

    const restored = try Snapshot.restore(testing.allocator, image);
    defer destroyRealm(testing.allocator, restored);
    try testing.expectEqual(want_strings, restored.heap.stringCount());
    try testing.expectEqual(want_objects, restored.heap.objectCount());
    try testing.expectEqual(want_functions, restored.heap.functionCount());
    try testing.expectEqual(want_symbols, restored.heap.symbolCount());
    try testing.expectEqual(want_cells, restored.synth_accessor_cells.items.len);
    try testing.expect(restored.hardened);
}

test "snapshot: restored hardened realm behaves like a fresh one" {
    // Capture a hardened realm, destroy the source, restore into a
    // fresh heap, and probe the restored realm's observable
    // behaviour against a fresh control realm.
    const source = try makeInstalledRealm(testing.allocator, true);
    const image = try Snapshot.capture(source, testing.allocator);
    defer testing.allocator.free(image);
    destroyRealm(testing.allocator, source);

    const restored = try Snapshot.restore(testing.allocator, image);
    defer destroyRealm(testing.allocator, restored);
    const control = try makeInstalledRealm(testing.allocator, true);
    defer destroyRealm(testing.allocator, control);

    for ([_]*Realm{ restored, control }) |realm| {
        // Hardened invariants: frozen primordials…
        try expectEvalBool(realm, "Object.isFrozen(Object.prototype)", true);
        try expectEvalBool(realm, "Object.isFrozen(Array.prototype)", true);
        // …that throw on monkey-patching…
        try expectEvalString(realm,
            \\(()=>{try{Array.prototype.push=1;return "no-throw"}catch(e){return e instanceof TypeError?"TypeError":"other"}})()
        , "TypeError");
        // …with the override-mistake fix intact (instance shadowing
        // over a frozen prototype slot succeeds).
        try expectEvalString(realm,
            \\(()=>{const o={};o.toString=()=>"shadowed";return String(o)})()
        , "shadowed");
        // A real workload through Array/Function/iterator machinery.
        try expectEvalString(realm, "[1,2,3].map(x=>x*2).join(\"-\")", "2-4-6");
        try expectEvalString(realm, "JSON.stringify({a:[1,{b:2}]})", "{\"a\":[1,{\"b\":2}]}");
        // Prototype-chain + well-known-symbol identity.
        try expectEvalBool(realm, "Object.getPrototypeOf([]) === Array.prototype", true);
        try expectEvalBool(realm, "[][Symbol.iterator] === Array.prototype.values", true);
        // Error classes intact.
        try expectEvalString(realm,
            \\(()=>{try{null.x}catch(e){return e.constructor.name}})()
        , "TypeError");
        try expectEvalBool(realm, "new RangeError(\"r\") instanceof RangeError", true);
        // No engine-internal `__cynic_*` keys reachable on globalThis.
        try expectEvalBool(realm,
            \\Object.getOwnPropertyNames(globalThis).some(k=>k.indexOf("__cynic")===0)
        , false);
    }

    // Same global surface, key for key.
    const restored_names = try evalValue(restored, "Object.getOwnPropertyNames(globalThis).sort().join(\",\")");
    const control_names = try evalValue(control, "Object.getOwnPropertyNames(globalThis).sort().join(\",\")");
    const rs: *JSString = @ptrCast(@alignCast(restored_names.asString()));
    const cs: *JSString = @ptrCast(@alignCast(control_names.asString()));
    try testing.expectEqualStrings(cs.flatBytes(), rs.flatBytes());
}

test "snapshot: restored realm survives GC and allocation pressure" {
    const source = try makeInstalledRealm(testing.allocator, true);
    const image = try Snapshot.capture(source, testing.allocator);
    defer testing.allocator.free(image);
    destroyRealm(testing.allocator, source);

    const restored = try Snapshot.restore(testing.allocator, image);
    defer destroyRealm(testing.allocator, restored);

    // Full collection immediately after restore: everything is
    // rooted through the realm, so counts must not collapse.
    const before = restored.heap.functionCount();
    restored.collectGarbage();
    try testing.expectEqual(before, restored.heap.functionCount());

    // Churn allocations through JS so young objects come and go
    // around the restored mature graph, then verify behaviour.
    try expectEvalString(restored,
        \\(()=>{let s="";for(let i=0;i<200;i++){s=[i,{x:i}].map(v=>typeof v).join("");}return s})()
    , "numberobject");
    restored.collectGarbage();
    try expectEvalString(restored, "[4,5,6].map(x=>x+1).join(\"\")", "567");
}

test "snapshot: unhardened realm round-trips with its posture" {
    const source = try makeInstalledRealm(testing.allocator, false);
    const image = try Snapshot.capture(source, testing.allocator);
    defer testing.allocator.free(image);
    destroyRealm(testing.allocator, source);

    const restored = try Snapshot.restore(testing.allocator, image);
    defer destroyRealm(testing.allocator, restored);
    try testing.expect(!restored.hardened);
    // Mutable primordials — the monkey-patch must succeed here.
    try expectEvalBool(restored,
        \\(()=>{Array.prototype.snapshotProbe=7;const ok=[].snapshotProbe===7;delete Array.prototype.snapshotProbe;return ok})()
    , true);
}
