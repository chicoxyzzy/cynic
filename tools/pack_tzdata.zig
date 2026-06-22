//! Pack a zoneinfo tree of TZif files into `vendor/tzdata/cynic_tzdb.bin` (CYTZ v1).
//!
//! Normal workflow (IANA sources, not host zoneinfo — mirrors `vendor/unicode/`):
//!
//!     tools/fetch-tzdata.sh            # download IANA release → vendor/tzdata/iana/
//!     zig build pack-tzdata            # zic compile + this tool (via compile-iana-tzdata.sh)
//!
//! Direct use (advanced): pass an existing zoneinfo tree with `--zoneinfo-root`.
//!
//! Format (little-endian index; TZif bodies keep on-disk big-endian layout):
//!
//!     magic "CYTZ"
//!     u8  version = 1
//!     u8  pad[3]
//!     u32 zone_count
//!     repeated zone_count times:
//!         u16 name_len
//!         u8  name[name_len]   # UTF-8 IANA id
//!         u32 data_off         # into the body region (after the index)
//!         u32 data_len
//!     then concatenated TZif payloads (identical bodies share offsets)

const std = @import("std");

const skip_names = [_][]const u8{
    "+VERSION",
    "leapseconds",
    "tzdata.zi",
    "zone.tab",
    "zone1970.tab",
    "iso3166.tab",
    "leap-seconds.list",
};

const skip_top = [_][]const u8{ "posix", "right" };

const ZoneRec = struct {
    name: []const u8,
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var zoneinfo_root: ?[]const u8 = null;
    var out_path: []const u8 = "vendor/tzdata/cynic_tzdb.bin";
    var version_path: []const u8 = "vendor/tzdata/VERSION";

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // argv[0]
    while (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "--zoneinfo-root")) {
            zoneinfo_root = args_iter.next() orelse fatal("missing value for --zoneinfo-root", .{});
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            out_path = args_iter.next() orelse fatal("missing value for -o", .{});
        } else if (std.mem.eql(u8, a, "--version-file")) {
            version_path = args_iter.next() orelse fatal("missing value for --version-file", .{});
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            const help =
                \\usage: pack_tzdata [--zoneinfo-root <dir>] [-o <path>] [--version-file <path>]
                \\
                \\Walk a zoneinfo tree and emit CYTZ v1 for Cynic -Dintl=full embeds.
                \\Usually invoked via `zig build pack-tzdata` (IANA sources in
                \\vendor/tzdata/iana/, compiled with zic first). Refresh sources:
                \\  tools/fetch-tzdata.sh [version]
                \\
            ;
            try std.Io.File.stdout().writeStreamingAll(io, help);
            return;
        } else {
            fatal("unknown arg: {s}", .{a});
        }
    }

    const root_path = zoneinfo_root orelse try findDefaultZoneinfo(allocator, io);
    defer if (zoneinfo_root == null) allocator.free(root_path);

    var zones: std.ArrayListUnmanaged(ZoneRec) = .empty;
    defer {
        for (zones.items) |z| {
            allocator.free(z.name);
            allocator.free(z.data);
        }
        zones.deinit(allocator);
    }

    try walkZoneinfo(allocator, io, root_path, &zones);
    if (zones.items.len == 0) fatal("no TZif files under {s}", .{root_path});

    std.mem.sort(ZoneRec, zones.items, {}, struct {
        fn less(_: void, a: ZoneRec, b: ZoneRec) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    const blob = try pack(allocator, zones.items);
    defer allocator.free(blob);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = blob });

    var ver_buf: [64]u8 = undefined;
    const ver = readHostVersion(io, root_path, &ver_buf) orelse "host-zoneinfo";
    const vtext = try std.fmt.allocPrint(allocator, "{s}\n# Packed from {s} via tools/pack_tzdata.zig\n# zones={d} total_bytes={d}\n", .{
        ver,
        root_path,
        zones.items.len,
        blob.len,
    });
    defer allocator.free(vtext);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = version_path, .data = vtext });

    const msg = try std.fmt.allocPrint(allocator, "wrote {s} zones={d} bytes={d} ver={s}\n", .{
        out_path,
        zones.items.len,
        blob.len,
        ver,
    });
    defer allocator.free(msg);
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

fn findDefaultZoneinfo(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const candidates = [_][]const u8{
        "/usr/share/zoneinfo",
        "/var/db/timezone/zoneinfo",
    };
    for (candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return try allocator.dupe(u8, c);
    }
    fatal("no zoneinfo directory found; pass --zoneinfo-root", .{});
}

fn shouldSkipName(name: []const u8) bool {
    for (skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn walkZoneinfo(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, zones: *std.ArrayListUnmanaged(ZoneRec)) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer root_dir.close(io);
    try walkDir(allocator, io, root_dir, "", zones);
}

fn walkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    zones: *std.ArrayListUnmanaged(ZoneRec),
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // `entry.path` is relative to `dir` (the zoneinfo root).
        const rel = entry.path;
        // Skip posix/ and right/ trees at the top level.
        if (std.mem.startsWith(u8, rel, "posix/") or std.mem.eql(u8, rel, "posix")) continue;
        if (std.mem.startsWith(u8, rel, "right/") or std.mem.eql(u8, rel, "right")) continue;

        switch (entry.kind) {
            .file => {
                if (shouldSkipName(entry.basename)) continue;
                const data = dir.readFileAlloc(io, rel, allocator, .limited(1024 * 1024)) catch continue;
                errdefer allocator.free(data);
                if (data.len < 4 or !std.mem.eql(u8, data[0..4], "TZif")) {
                    allocator.free(data);
                    continue;
                }
                const name = try allocator.dupe(u8, rel);
                errdefer allocator.free(name);
                // Normalise separators to '/' for the IANA id form.
                for (name) |*c| {
                    if (c.* == '\\') c.* = '/';
                }
                try zones.append(allocator, .{ .name = name, .data = data });
            },
            else => {},
        }
    }
    _ = rel_prefix;
}

fn pack(allocator: std.mem.Allocator, zones: []const ZoneRec) ![]u8 {
    var body_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var kit = body_map.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        body_map.deinit(allocator);
    }

    var bodies: std.ArrayListUnmanaged(u8) = .empty;
    defer bodies.deinit(allocator);

    const IndexEnt = struct { name: []const u8, off: u32, len: u32 };
    var index: std.ArrayListUnmanaged(IndexEnt) = .empty;
    defer index.deinit(allocator);

    for (zones) |z| {
        var hash_buf: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(z.data, &hash_buf, .{});
        // Key is the first 8 hash bytes + length; collisions re-hash as a
        // new body entry (rare; SHA-1 prefix is only for dedupe speed).
        var key_buf: [8 + 1 + 20]u8 = undefined;
        @memcpy(key_buf[0..8], hash_buf[0..8]);
        key_buf[8] = ':';
        const len_part = try std.fmt.bufPrint(key_buf[9..], "{d}", .{z.data.len});
        const key_slice = key_buf[0 .. 9 + len_part.len];
        const key = try allocator.dupe(u8, key_slice);
        errdefer allocator.free(key);

        const gop = try body_map.getOrPut(allocator, key);
        const off: u32 = if (gop.found_existing) blk: {
            allocator.free(key);
            break :blk gop.value_ptr.*;
        } else blk: {
            const o: u32 = @intCast(bodies.items.len);
            try bodies.appendSlice(allocator, z.data);
            gop.value_ptr.* = o;
            break :blk o;
        };
        try index.append(allocator, .{ .name = z.name, .off = off, .len = @intCast(z.data.len) });
    }

    var header: std.ArrayListUnmanaged(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, "CYTZ");
    try header.append(allocator, 1);
    try header.appendSlice(allocator, &[_]u8{ 0, 0, 0 });
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(index.items.len), .little);
    try header.appendSlice(allocator, &count_buf);

    for (index.items) |ent| {
        if (ent.name.len > 0xFFFF) fatal("zone name too long: {s}", .{ent.name});
        var nl: [2]u8 = undefined;
        std.mem.writeInt(u16, &nl, @intCast(ent.name.len), .little);
        try header.appendSlice(allocator, &nl);
        try header.appendSlice(allocator, ent.name);
        var nums: [8]u8 = undefined;
        std.mem.writeInt(u32, nums[0..4], ent.off, .little);
        std.mem.writeInt(u32, nums[4..8], ent.len, .little);
        try header.appendSlice(allocator, &nums);
    }

    const total = header.items.len + bodies.items.len;
    const out = try allocator.alloc(u8, total);
    @memcpy(out[0..header.items.len], header.items);
    @memcpy(out[header.items.len..], bodies.items);
    return out;
}

fn readHostVersion(io: std.Io, root_path: []const u8, buf: *[64]u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{}) catch return null;
    defer dir.close(io);
    const data = dir.readFileAlloc(io, "+VERSION", std.heap.page_allocator, .limited(64)) catch return null;
    defer std.heap.page_allocator.free(data);
    const n = @min(data.len, buf.len);
    @memcpy(buf[0..n], data[0..n]);
    const slice = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (slice.len == 0) return null;
    return slice;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("pack_tzdata: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
