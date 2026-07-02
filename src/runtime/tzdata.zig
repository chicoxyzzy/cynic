//! Embedded IANA zoneinfo for `-Dintl=full` builds.
//!
//! The blob is `vendor/tzdata/cynic_tzdb.bin` (CYTZ v1 — see
//! `tools/pack_tzdata.py`): an index of zone names pointing into
//! concatenated TZif payloads (RFC 8536 / `tzfile(5)`). Offset lookup
//! walks the 64-bit transition table in the second TZif section; when
//! `timecnt` is zero or the instant is past the last transition, the
//! first (only) `ttinfo` type is used. Leap-second TTIs and the POSIX
//! TZ footer are ignored — sufficient for Temporal's
//! `GetOffsetNanosecondsFor` (whole-second civil offsets in practice).
//!
//! At non-`full` tiers this module compiles to no-ops so off/stub
//! binaries do not embed the ~400 KiB database.

const std = @import("std");
const intl_config = @import("intl_config.zig");

/// True when this binary was built with `-Dintl=full` and the tzdb is linked.
pub const available: bool = intl_config.has_locale_data;

const ZoneEntry = struct {
    name: []const u8,
    data_off: u32,
    data_len: u32,
};

/// Max zones we index at runtime (host zoneinfo is ~600; headroom for growth).
const max_zones: usize = 1024;

/// Sorted by zone name (the packer emits alphabetical order).
var zone_storage: [max_zones]ZoneEntry = undefined;
var zone_count: usize = 0;
var body_base: []const u8 = &.{};
var init_done: bool = false;
var init_ok: bool = false;

fn embedBlob() []const u8 {
    if (!available) return &.{};
    // Anonymous import from build.zig only on `-Dintl=full`.
    return @embedFile("cynic_tzdb.bin");
}

fn ensureInit() bool {
    if (init_done) return init_ok;
    init_done = true;
    if (!available) return false;
    const blob = embedBlob();
    if (blob.len < 12) return false;
    if (!std.mem.eql(u8, blob[0..4], "CYTZ")) return false;
    if (blob[4] != 1) return false;
    const count = std.mem.readInt(u32, blob[8..12], .little);
    var off: usize = 12;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 2 > blob.len) return false;
        const name_len = std.mem.readInt(u16, blob[off..][0..2], .little);
        off += 2;
        if (off + name_len + 8 > blob.len) return false;
        const name = blob[off .. off + name_len];
        off += name_len;
        const data_off = std.mem.readInt(u32, blob[off..][0..4], .little);
        const data_len = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
        off += 8;
        if (n >= max_zones) return false;
        zone_storage[n] = .{ .name = name, .data_off = data_off, .data_len = data_len };
        n += 1;
    }
    if (off > blob.len) return false;
    body_base = blob[off..];
    zone_count = n;
    for (zone_storage[0..zone_count]) |z| {
        const end = @as(usize, z.data_off) + @as(usize, z.data_len);
        if (end > body_base.len) return false;
    }
    init_ok = true;
    return true;
}

fn zoneTable() []const ZoneEntry {
    return zone_storage[0..zone_count];
}

/// True when `name` is present in the embedded tzdb (case-sensitive IANA form).
pub fn hasZone(name: []const u8) bool {
    if (!available) return false;
    if (!ensureInit()) return false;
    return findZone(name) != null;
}

/// ECMA-402 GetAvailableNamedTimeZoneIdentifier: an ASCII-case-insensitive
/// lookup that returns the tzdb's stored (correctly-cased) identifier without
/// canonicalizing aliases — "africa/abidjan" → "Africa/Abidjan", "Etc/UTC"
/// stays "Etc/UTC" (not collapsed to "UTC"). Null when no zone matches.
/// §GetAvailableNamedTimeZoneIdentifier [[PrimaryIdentifier]]: resolve an
/// IANA link (alias) to its primary zone, folding the UTC-equivalent family
/// (Etc/UTC, Etc/GMT, GMT) to "UTC" as ECMA-402 requires. Falls back to the
/// input when it is already primary (or unknown).
pub fn primaryZoneName(name: []const u8) []const u8 {
    const links = @import("tzdata_links.zig").links;
    var resolved = name;
    for (links) |l| {
        if (std.ascii.eqlIgnoreCase(l.alias, name)) {
            resolved = l.primary;
            break;
        }
    }
    if (std.ascii.eqlIgnoreCase(resolved, "Etc/UTC") or
        std.ascii.eqlIgnoreCase(resolved, "Etc/GMT") or
        std.ascii.eqlIgnoreCase(resolved, "GMT"))
    {
        return "UTC";
    }
    return resolved;
}

pub fn canonicalZoneName(name: []const u8) ?[]const u8 {
    if (!available or !ensureInit()) return null;
    for (zoneTable()) |ent| {
        if (std.ascii.eqlIgnoreCase(ent.name, name)) return ent.name;
    }
    return null;
}

fn findZone(name: []const u8) ?ZoneEntry {
    const table = zoneTable();
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = std.mem.order(u8, table[mid].name, name);
        switch (ord) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return table[mid],
        }
    }
    return null;
}

fn zoneTzif(name: []const u8) ?[]const u8 {
    if (!ensureInit()) return null;
    const ent = findZone(name) orelse return null;
    const start: usize = ent.data_off;
    const end = start + ent.data_len;
    if (end > body_base.len) return null;
    return body_base[start..end];
}

/// UTC offset in nanoseconds east of UTC at `epoch_ns` for a named zone.
/// Returns 0 when the zone is missing or the TZif payload is unusable
/// (callers treat that as UTC — same as structural stub behaviour).
pub fn offsetNanosecondsFor(zone_name: []const u8, epoch_ns: i128) i64 {
    if (!available) return 0;
    const data = zoneTzif(zone_name) orelse return 0;
    return tzifOffsetNs(data, epoch_ns) orelse 0;
}

// ── TZif (RFC 8536) ────────────────────────────────────────────────────────

const TzifHeader = struct {
    version: u8,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
    /// Byte offset of the transition times array (after the 44-byte header).
    section_start: usize,
    time_size: usize, // 4 (v1 section) or 8 (v2+ second section)
};

fn readBeU32(buf: []const u8, off: usize) ?u32 {
    if (off + 4 > buf.len) return null;
    return std.mem.readInt(u32, buf[off..][0..4], .big);
}

fn readBeI32(buf: []const u8, off: usize) ?i32 {
    if (off + 4 > buf.len) return null;
    return std.mem.readInt(i32, buf[off..][0..4], .big);
}

fn readBeI64(buf: []const u8, off: usize) ?i64 {
    if (off + 8 > buf.len) return null;
    return std.mem.readInt(i64, buf[off..][0..8], .big);
}

fn parseHeader(data: []const u8, start: usize) ?TzifHeader {
    if (start + 44 > data.len) return null;
    if (!std.mem.eql(u8, data[start .. start + 4], "TZif")) return null;
    const version = data[start + 4];
    const timecnt = readBeU32(data, start + 32) orelse return null;
    const typecnt = readBeU32(data, start + 36) orelse return null;
    const charcnt = readBeU32(data, start + 40) orelse return null;
    if (typecnt == 0) return null;
    return .{
        .version = version,
        .timecnt = timecnt,
        .typecnt = typecnt,
        .charcnt = charcnt,
        .section_start = start + 44,
        .time_size = 4,
    };
}

/// Locate the primary section: prefer the 64-bit (v2+) section when present.
fn primarySection(data: []const u8) ?TzifHeader {
    const h1 = parseHeader(data, 0) orelse return null;
    if (h1.version == 0 or h1.version == '1') return h1;

    // Skip the entire v1 body to find the second header.
    const tsize: usize = 4;
    const leapcnt = readBeU32(data, 28) orelse return null;
    const ttisstdcnt = readBeU32(data, 20) orelse return null;
    const ttisutcnt = readBeU32(data, 24) orelse return null;
    const body_v1 = h1.timecnt * tsize +
        h1.timecnt + // type indices
        h1.typecnt * 6 +
        h1.charcnt +
        leapcnt * 8 +
        ttisstdcnt +
        ttisutcnt;
    const sec2 = h1.section_start + body_v1;
    const h2 = parseHeader(data, sec2) orelse return h1;
    return .{
        .version = h2.version,
        .timecnt = h2.timecnt,
        .typecnt = h2.typecnt,
        .charcnt = h2.charcnt,
        .section_start = h2.section_start,
        .time_size = 8,
    };
}

fn ttinfoGmtoff(data: []const u8, types_off: usize, type_idx: u32) ?i32 {
    const off = types_off + @as(usize, type_idx) * 6;
    return readBeI32(data, off);
}

/// TZif v2+ footer: newline-terminated POSIX TZ string after the second
/// section. Modern `zic` often stops the transition table ~2007 and relies
/// on this rule for later instants (RFC 8536 §3.3).
fn posixTzFooter(data: []const u8) ?[]const u8 {
    if (data.len < 2) return null;
    // Footer is the last non-empty line: …\nTZSTRING\n
    if (data[data.len - 1] != '\n') return null;
    const end = data.len - 1;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (data[i - 1] == '\n') {
            const s = data[i..end];
            if (s.len == 0) return null;
            return s;
        }
    }
    return null;
}

/// Minimal POSIX TZ parser for the common IANA footer forms:
///   `EST5EDT,M3.2.0,M11.1.0`  (US/EU style with `Mm.n.d` rules)
///   `JST-9` / `<+0530>-5:30`  (fixed offset, no DST)
/// Returns gmtoff in seconds east of UTC. Not a full `tzset(3)` clone —
/// enough for Temporal's offset seam on current tzdata footers.
fn posixTzOffsetAt(tz_str: []const u8, epoch_sec: i64) ?i32 {
    // Split std / dst / rules at first comma pair.
    const comma1 = std.mem.indexOfScalar(u8, tz_str, ',');
    const std_dst = if (comma1) |c| tz_str[0..c] else tz_str;
    const rules = if (comma1) |c| tz_str[c + 1 ..] else "";

    const sd = parsePosixStdDst(std_dst) orelse return null;

    if (sd.dst_off == null or rules.len == 0) return sd.std_off;

    const comma2 = std.mem.indexOfScalar(u8, rules, ',') orelse return sd.std_off;
    const start_rule = rules[0..comma2];
    const end_rule = rules[comma2 + 1 ..];

    // Evaluate in the civil year of `epoch_sec` in standard time (approx).
    const ymd = civilYmdFromEpochSec(epoch_sec + sd.std_off);
    const start_sec = ruleToUtcSec(start_rule, ymd.year, sd.std_off) orelse return sd.std_off;
    const end_sec = ruleToUtcSec(end_rule, ymd.year, sd.dst_off.?) orelse return sd.std_off;

    // Northern hemisphere: start < end in the same year. Southern: end < start.
    const in_dst = if (start_sec < end_sec)
        epoch_sec >= start_sec and epoch_sec < end_sec
    else
        epoch_sec >= start_sec or epoch_sec < end_sec;

    return if (in_dst) sd.dst_off.? else sd.std_off;
}

fn parsePosixStdDst(s: []const u8) ?struct { std_off: i32, dst_off: ?i32 } {
    // std offset [dst [offset]]
    var i: usize = 0;
    // Skip std name (quoted `<…>` or alpha).
    if (i < s.len and s[i] == '<') {
        i += 1;
        while (i < s.len and s[i] != '>') : (i += 1) {}
        if (i < s.len) i += 1;
    } else {
        while (i < s.len and ((s[i] >= 'A' and s[i] <= 'Z') or (s[i] >= 'a' and s[i] <= 'z'))) : (i += 1) {}
    }
    const std_off = parsePosixOffset(s[i..]) orelse return null;
    i += posixOffsetLen(s[i..]);

    if (i >= s.len) return .{ .std_off = std_off, .dst_off = null };

    // dst name
    if (s[i] == '<') {
        i += 1;
        while (i < s.len and s[i] != '>') : (i += 1) {}
        if (i < s.len) i += 1;
    } else {
        while (i < s.len and ((s[i] >= 'A' and s[i] <= 'Z') or (s[i] >= 'a' and s[i] <= 'z'))) : (i += 1) {}
    }
    if (i >= s.len) {
        // DST with no offset ⇒ one hour ahead of standard (POSIX).
        return .{ .std_off = std_off, .dst_off = std_off + 3600 };
    }
    if (s[i] == ',') return .{ .std_off = std_off, .dst_off = std_off + 3600 };
    const dst_off = parsePosixOffset(s[i..]) orelse return .{ .std_off = std_off, .dst_off = std_off + 3600 };
    return .{ .std_off = std_off, .dst_off = dst_off };
}

/// POSIX offset: `[±]hh[:mm[:ss]]`. Sign is *west* of UTC in the TZ string
/// (`EST5` ⇒ −5h). We return seconds *east* of UTC (opposite sign).
fn parsePosixOffset(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var sign: i32 = 1; // POSIX: positive = west of UTC = negative gmtoff
    if (s[0] == '+') {
        i = 1;
    } else if (s[0] == '-') {
        sign = -1;
        i = 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var hours: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        hours = hours * 10 + (s[i] - '0');
    }
    var mins: i32 = 0;
    var secs: i32 = 0;
    if (i < s.len and s[i] == ':') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            mins = mins * 10 + (s[i] - '0');
        }
        if (i < s.len and s[i] == ':') {
            i += 1;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                secs = secs * 10 + (s[i] - '0');
            }
        }
    }
    const west_secs = sign * (hours * 3600 + mins * 60 + secs);
    return -west_secs; // east of UTC
}

fn posixOffsetLen(s: []const u8) usize {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i < s.len and s[i] == ':') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (i < s.len and s[i] == ':') {
            i += 1;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        }
    }
    return i;
}

const CivilYmd = struct { year: i32, month: u8, day: u8 };

fn civilYmdFromEpochSec(sec: i64) CivilYmd {
    // Howard Hinnant civil_from_days (UTC).
    const z = @divFloor(sec, 86400) + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    y += if (m <= 2) @as(i64, 1) else 0;
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    var y: i64 = y_in;
    const mo: i64 = m;
    const da: i64 = d;
    y -= if (mo <= 2) @as(i64, 1) else 0;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * (if (mo > 2) mo - 3 else mo + 9) + 2, 5) + da - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// `Mmonth.week.dow` at 02:00 local standard time → UTC seconds.
fn ruleToUtcSec(rule: []const u8, year: i32, local_off_east: i32) ?i64 {
    if (rule.len == 0 or rule[0] != 'M') return null;
    var i: usize = 1;
    var month: i32 = 0;
    while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
        month = month * 10 + (rule[i] - '0');
    }
    if (i >= rule.len or rule[i] != '.') return null;
    i += 1;
    var week: i32 = 0;
    while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
        week = week * 10 + (rule[i] - '0');
    }
    if (i >= rule.len or rule[i] != '.') return null;
    i += 1;
    var dow: i32 = 0;
    while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
        dow = dow * 10 + (rule[i] - '0');
    }
    // Optional `/time` — default 02:00.
    var hour: i32 = 2;
    var minute: i32 = 0;
    var second: i32 = 0;
    if (i < rule.len and rule[i] == '/') {
        i += 1;
        hour = 0;
        while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
            hour = hour * 10 + (rule[i] - '0');
        }
        if (i < rule.len and rule[i] == ':') {
            i += 1;
            minute = 0;
            while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
                minute = minute * 10 + (rule[i] - '0');
            }
            if (i < rule.len and rule[i] == ':') {
                i += 1;
                second = 0;
                while (i < rule.len and rule[i] >= '0' and rule[i] <= '9') : (i += 1) {
                    second = second * 10 + (rule[i] - '0');
                }
            }
        }
    }
    if (month < 1 or month > 12 or week < 1 or week > 5 or dow > 6) return null;

    // Day-of-week of the 1st of `month` (0=Sun … 6=Sat), Unix epoch was Thursday.
    const first_epoch_days = daysFromCivil(year, @intCast(month), 1);
    const first_dow: i32 = @intCast(@mod(first_epoch_days + 4, 7));
    var day: i32 = 1 + @mod(dow - first_dow + 7, 7);
    if (week == 5) {
        // Last `dow` in the month.
        while (day + 7 <= daysInMonth(year, @intCast(month))) day += 7;
    } else {
        day += (week - 1) * 7;
    }
    const local_sec = daysFromCivil(year, @intCast(month), @intCast(day)) * 86400 +
        hour * 3600 + minute * 60 + second;
    return local_sec - local_off_east;
}

fn daysInMonth(year: i32, month: u8) i32 {
    const lens = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    if (month < 1 or month > 12) return 30;
    return lens[month - 1];
}

fn isLeapYear(y: i32) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn tzifOffsetNs(data: []const u8, epoch_ns: i128) ?i64 {
    const sec = primarySection(data) orelse return null;
    const tsize = sec.time_size;
    const times_off = sec.section_start;
    const types_idx_off = times_off + @as(usize, sec.timecnt) * tsize;
    const ttinfo_off = types_idx_off + sec.timecnt;

    const epoch_sec_i128 = @divFloor(epoch_ns, 1_000_000_000);
    const epoch_sec: i64 = if (epoch_sec_i128 > std.math.maxInt(i64))
        std.math.maxInt(i64)
    else if (epoch_sec_i128 < std.math.minInt(i64))
        std.math.minInt(i64)
    else
        @intCast(epoch_sec_i128);

    // Past the last transition ⇒ prefer POSIX TZ footer (RFC 8536 §3.3).
    if (sec.timecnt > 0) {
        const last_off = times_off + @as(usize, sec.timecnt - 1) * tsize;
        const last_tr: i64 = if (tsize == 8)
            (readBeI64(data, last_off) orelse return null)
        else
            @as(i64, readBeI32(data, last_off) orelse return null);
        if (epoch_sec >= last_tr) {
            if (posixTzFooter(data)) |footer| {
                if (posixTzOffsetAt(footer, epoch_sec)) |gmtoff| {
                    return @as(i64, gmtoff) * 1_000_000_000;
                }
            }
        }
    } else if (sec.timecnt == 0) {
        if (posixTzFooter(data)) |footer| {
            if (posixTzOffsetAt(footer, epoch_sec)) |gmtoff| {
                return @as(i64, gmtoff) * 1_000_000_000;
            }
        }
    }

    var type_idx: u32 = 0;
    if (sec.timecnt == 0) {
        type_idx = 0;
    } else {
        var lo: u32 = 0;
        var hi: u32 = sec.timecnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const t_off = times_off + @as(usize, mid) * tsize;
            const tr: i64 = if (tsize == 8)
                (readBeI64(data, t_off) orelse return null)
            else
                @as(i64, readBeI32(data, t_off) orelse return null);
            if (tr <= epoch_sec) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) {
            type_idx = 0;
        } else {
            const prev = lo - 1;
            if (types_idx_off + prev >= data.len) return null;
            type_idx = data[types_idx_off + prev];
            if (type_idx >= sec.typecnt) return null;
        }
    }

    const gmtoff = ttinfoGmtoff(data, ttinfo_off, type_idx) orelse return null;
    return @as(i64, gmtoff) * 1_000_000_000;
}

// ── Tests (full tier only; skipped elsewhere) ──────────────────────────────

const testing = std.testing;

test "tzdata: America/New_York offset at known instants" {
    if (!available) return error.SkipZigTest;
    try testing.expect(hasZone("America/New_York"));
    try testing.expect(!hasZone("Not/AZone"));

    // 2024-01-15 12:00:00 UTC — EST = UTC-5 = -18000 s
    const jan_utc: i128 = 1_705_320_000; // approx; compute precisely below
    _ = jan_utc;
    // 2024-01-01T00:00:00Z = 1704067200
    const winter: i128 = 1_704_067_200 * 1_000_000_000;
    const summer: i128 = 1_719_792_000 * 1_000_000_000; // 2024-07-01T00:00:00Z
    const off_w = offsetNanosecondsFor("America/New_York", winter);
    const off_s = offsetNanosecondsFor("America/New_York", summer);
    try testing.expectEqual(@as(i64, -5 * 3600) * 1_000_000_000, off_w);
    try testing.expectEqual(@as(i64, -4 * 3600) * 1_000_000_000, off_s);
}

test "tzdata: Europe/Vienna CET/CEST" {
    if (!available) return error.SkipZigTest;
    try testing.expect(hasZone("Europe/Vienna"));
    const winter: i128 = 1_704_067_200 * 1_000_000_000;
    const summer: i128 = 1_719_792_000 * 1_000_000_000;
    try testing.expectEqual(@as(i64, 3600) * 1_000_000_000, offsetNanosecondsFor("Europe/Vienna", winter));
    try testing.expectEqual(@as(i64, 7200) * 1_000_000_000, offsetNanosecondsFor("Europe/Vienna", summer));
}

test "tzdata: Asia/Tokyo fixed offset" {
    if (!available) return error.SkipZigTest;
    const any: i128 = 0;
    try testing.expectEqual(@as(i64, 9 * 3600) * 1_000_000_000, offsetNanosecondsFor("Asia/Tokyo", any));
}
