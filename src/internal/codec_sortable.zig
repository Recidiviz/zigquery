//! A memcomparable encoding for the kinds that can have one.
//!
//! `memcmp` over two of these, of the same kind, gives the same answer as
//! `value.compareForCollation`. That matters because SQLite ignores collating
//! sequences on BLOBs — it always compares them byte by byte — so a BLOB column
//! can only be ordered correctly if the bytes themselves are ordered correctly.
//! Getting that right is what lets values leave base64 behind: the alternative
//! is a BLOB column whose ORDER BY is silently wrong, since zigquery_collate
//! is never consulted and nothing raises an error.
//!
//! Layout is `[tag][payload]`, and the payload simply runs to the end of the
//! buffer. No length prefixes, no terminators, no escaping — and that is not a
//! simplification, it is the point: a uvarint length prefix would sort by
//! *length* before content, which is exactly the bug this format exists to
//! avoid.
//!
//! It gets away with having no framing because only *top-level* values are
//! encoded here, so a variable-length payload can run to the buffer's end.
//! Nested values must be self-delimiting, so ARRAY and STRUCT carry their
//! elements in the self-delimiting codec instead — as do JSON and INTERVAL,
//! which have no order to preserve (`compareOp` errors on every operator).
//!
//! RANGE is the one kind that takes *both* codecs. It is ordered
//! (`Type::SupportsOrdering` excludes only GEOGRAPHY and TOKENLIST), so a
//! top-level range needs these bytes; but a range nested in an ARRAY — which
//! GENERATE_RANGE_ARRAY returns by the handful — needs to be self-delimiting,
//! so it has a tag in codec_binary.zig too.
//!
//! NUMERIC and BIGNUMERIC share one tag and one layout, so the two kinds
//! interleave by value. The kind rides in a trailing byte: decoding a UDF
//! argument has no static type to take it from, and at the end it is compared
//! only between equal values, where NUMERIC sorts first.

const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

/// Tags are ordered so that, if two kinds ever did meet in one column, the
/// byte order would at least be stable. Within a column only one occurs.
pub const tag_date: u8 = 0x40;
pub const tag_time: u8 = 0x48;
pub const tag_datetime: u8 = 0x50;
pub const tag_timestamp: u8 = 0x58;
pub const tag_string: u8 = 0x60;
pub const tag_bytes: u8 = 0x68;
pub const tag_numeric: u8 = 0x70;
pub const tag_range: u8 = 0x80;

/// The first tag this codec owns. `encoder.decodeRepr` splits the two codecs
/// on it, so the boundary lives here with the tags rather than as a literal at
/// the call site — everything below is codec_binary.zig's, including the room
/// between its highest tag and this one.
pub const tag_min: u8 = 0x40;

/// Fixed payload: element kind, then a presence byte and an 8-byte scalar per
/// bound. Fixed width because the format has no framing (see the header).
const range_bytes = 1 + 1 + 8 + 1 + 8;

/// An absent bound is not a missing value, it is an infinity — and which one
/// depends on the end it sits at. So the two presence bytes are deliberately
/// *inverted* relative to each other: an unbounded start writes 0x00 and sorts
/// below every bounded start, while an unbounded end writes 0x01 and sorts
/// above every bounded end. Reading these as one shared "is present" flag is
/// the easy mistake, and it silently mis-sorts `[x, UNBOUNDED)`.
const range_start_unbounded: u8 = 0x00;
const range_start_bounded: u8 = 0x01;
const range_end_bounded: u8 = 0x00;
const range_end_unbounded: u8 = 0x01;

/// Decimal payload: `[header][magnitude][kind]`, the value restated at
/// BIGNUMERIC's scale 38 so both kinds share one number line.
///
/// The magnitude is minimal-length big-endian, at most 32 bytes (BIGNUMERIC's
/// minimum is -2^255). The header is `decimal_zero` plus that length for a
/// positive value and minus it for a negative one, whose magnitude bytes are
/// inverted, so a longer magnitude sorts further from zero and a shorter one
/// nearer. The header fixes where the kind byte sits, so it is only ever
/// compared between equal values.
const decimal_zero: u8 = 0x80;
const decimal_max_bytes = 32;
const kind_numeric: u8 = 0x00;
const kind_bignumeric: u8 = 0x01;

/// NUMERIC's unscaled integer at BIGNUMERIC's scale. 10^38 - 1 times this is
/// under 2^223, so the product fits the u256 magnitude.
const numeric_common_shift = value_mod.bignumeric_scale - value_mod.numeric_scale;
const numeric_to_common: u256 = std.math.pow(u256, 10, numeric_common_shift);

/// Flips the sign bit so that two's-complement integers compare correctly as
/// unsigned big-endian bytes: negatives (sign bit 1) must sort below
/// non-negatives, which is the opposite of what the raw bit pattern does.
fn orderable(v: i64) u64 {
    return @as(u64, @bitCast(v)) ^ (@as(u64, 1) << 63);
}

fn unorderable(u: u64) i64 {
    return @bitCast(u ^ (@as(u64, 1) << 63));
}

/// Appends `v`'s memcomparable form to `buf`, or returns false for a kind with
/// no order to preserve, which keeps the self-delimiting codec in
/// codec_binary.zig instead.
///
/// Appending is the primitive rather than allocating, because the per-row
/// encode path writes into a scratch buffer it reuses across every value
/// (`encoder.Scratch`) instead of allocating one buffer per value. `encode`
/// below is the owning wrapper for callers that need to keep the bytes.
///
/// A failure mid-append leaves `buf` holding a partial value. Every caller
/// either discards the buffer or clears it before the next value, and the only
/// error reachable after the first byte is written is OutOfMemory.
pub fn encodeAppend(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    v: Value,
) ValueError!bool {
    switch (v) {
        .safe => |p| return encodeAppend(buf, alloc, p.*),
        .string, .bytes => |s| {
            // The payload is the raw bytes: compareOp compares strings and
            // bytes with std.mem.order (value.zig:658,668), and memcmp over
            // equal tags is exactly that, including the shorter-is-less rule
            // for a common prefix.
            const out = try buf.addManyAsSlice(alloc, 1 + s.len);
            out[0] = if (v == .string) tag_string else tag_bytes;
            @memcpy(out[1..], s);
        },
        .date, .time, .datetime, .timestamp => {
            const tag: u8, const n: i64 = switch (v) {
                .date => |d| .{ tag_date, d },
                .time => |t| .{ tag_time, t },
                .datetime => |d| .{ tag_datetime, d },
                .timestamp => |t| .{ tag_timestamp, t },
                else => unreachable,
            };
            const out = try buf.addManyAsArray(alloc, 9);
            out[0] = tag;
            std.mem.writeInt(u64, out[1..9], orderable(n), .big);
        },
        .numeric => |n| {
            // NUMERIC's bound holds by construction, but is checked rather than
            // assumed: past it the scale-38 product would overflow the magnitude
            // and land wherever the wrapped bits sort. Checked before anything
            // is appended, so a rejected value leaves no half-written tag.
            const abs: u256 = @abs(n.unscaled);
            if (!n.is_bignumeric and abs > value_mod.numeric_unscaled_max) {
                return error.NumericOutOfRange;
            }
            const mag = if (n.is_bignumeric) abs else abs * numeric_to_common;
            const len: u8 = @intCast((256 - @clz(mag) + 7) / 8);

            var be: [decimal_max_bytes]u8 = undefined;
            std.mem.writeInt(u256, &be, mag, .big);
            const out = try buf.addManyAsSlice(alloc, 3 + @as(usize, len));
            out[0] = tag_numeric;
            out[1] = if (n.unscaled < 0) decimal_zero - len else decimal_zero + len;
            const digits = out[2..][0..len];
            @memcpy(digits, be[decimal_max_bytes - len ..]);
            if (n.unscaled < 0) {
                for (digits) |*b| b.* = ~b.*;
            }
            out[2 + len] = if (n.is_bignumeric) kind_bignumeric else kind_numeric;
        },
        // The scalar slot under an absent bound is zero-filled rather than
        // left to chance: `rangeValue` already guarantees the struct field is
        // 0, but writing zeros explicitly means a hand-built Range cannot make
        // two equal ranges encode differently and break DISTINCT.
        .range => |r| {
            const out = try buf.addManyAsArray(alloc, 1 + range_bytes);
            out[0] = tag_range;
            out[1] = @backingInt(r.elem);
            out[2] = if (r.has_start) range_start_bounded else range_start_unbounded;
            std.mem.writeInt(u64, out[3..11], if (r.has_start) orderable(r.start) else 0, .big);
            out[11] = if (r.has_end) range_end_bounded else range_end_unbounded;
            std.mem.writeInt(u64, out[12..20], if (r.has_end) orderable(r.end) else 0, .big);
        },
        else => return false,
    }
    return true;
}

/// `encodeAppend` into a buffer of its own, for callers that need to own the
/// bytes rather than consume them before the next value. Null carries the same
/// "not my kind" signal as `false` there.
pub fn encode(alloc: std.mem.Allocator, v: Value) ValueError!?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    if (!try encodeAppend(&buf, alloc, v)) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}

/// 10^29 = 2^29 * 5^29, and 5^29 is odd, so it has an inverse mod 2^256.
const five_pow_inverse: u256 = blk: {
    const d: u256 = std.math.pow(u256, 5, numeric_common_shift);
    // Newton's iteration doubles the correct low bits each step: 3 -> 768.
    var x: u256 = d;
    for (0..8) |_| x = x *% (2 -% d *% x);
    break :blk x;
};

/// A scale-38 magnitude back to NUMERIC's scale 9, or CorruptData when it is
/// off NUMERIC's grid or past its 38 digits.
///
/// Division by multiplication: for odd `d`, `n * inverse(d) mod 2^256` is
/// `n / d` when `d` divides `n`, and lands above `(2^256 - 1) / d` when it
/// does not. NUMERIC's bound is far below that, so one comparison rejects both.
fn numericFromCommon(mag: u256) ValueError!u256 {
    const low_mask = (@as(u256, 1) << numeric_common_shift) - 1;
    if (mag & low_mask != 0) return error.CorruptData;
    const q = (mag >> numeric_common_shift) *% five_pow_inverse;
    if (q > value_mod.numeric_unscaled_max) return error.CorruptData;
    return q;
}

/// The decimal payload after the tag, back to a numeric Value. Only the
/// canonical form is accepted: DISTINCT and index lookups rely on one value
/// having one encoding, so a non-minimal magnitude or an off-grid NUMERIC is
/// corrupt rather than another spelling.
fn decodeDecimal(alloc: std.mem.Allocator, payload: []const u8) ValueError!Value {
    if (payload.len < 2) return error.CorruptData;
    const header = payload[0];
    const negative = header < decimal_zero;
    const len: usize = if (negative) decimal_zero - header else header - decimal_zero;
    if (len > decimal_max_bytes or payload.len != 2 + len) return error.CorruptData;

    var be: [decimal_max_bytes]u8 = @splat(0);
    const digits = be[decimal_max_bytes - len ..];
    for (payload[1..][0..len], digits) |stored, *d| d.* = if (negative) ~stored else stored;
    if (len > 0 and digits[0] == 0) return error.CorruptData;
    const mag = std.mem.readInt(u256, &be, .big);

    const is_bignumeric = switch (payload[1 + len]) {
        kind_numeric => false,
        kind_bignumeric => true,
        else => return error.CorruptData,
    };
    // |unscaled| at the kind's own scale. BIGNUMERIC reaches -2^255 but not +2^255.
    const abs: u256 = if (is_bignumeric) mag else try numericFromCommon(mag);
    const big_max: u256 = if (negative) 1 << 255 else (1 << 255) - 1;
    if (is_bignumeric and abs > big_max) return error.CorruptData;
    const unscaled: i256 = if (negative) -%@as(i256, @bitCast(abs)) else @bitCast(abs);
    return value_mod.numericFromUnscaled(alloc, unscaled, is_bignumeric);
}

/// Decodes a memcomparable buffer. Strings and bytes alias `buf` — no copy and no
/// allocation — so `buf` must outlive the returned Value. (NUMERIC is the one
/// kind that must allocate, for its bigint.) That holds at
/// every call site: the buffer is SQLite's, valid for the statement step or UDF
/// call that produced it, and every caller consumes the Value before returning.
pub fn decode(alloc: std.mem.Allocator, buf: []const u8) ValueError!Value {
    if (buf.len == 0) return error.CorruptData;
    const payload = buf[1..];
    switch (buf[0]) {
        tag_string => return Value{ .string = payload },
        tag_bytes => return Value{ .bytes = payload },
        tag_date, tag_time, tag_datetime, tag_timestamp => {
            if (payload.len != 8) return error.CorruptData;
            const n = unorderable(std.mem.readInt(u64, payload[0..8], .big));
            return switch (buf[0]) {
                tag_date => Value{ .date = n },
                tag_time => Value{ .time = n },
                tag_datetime => Value{ .datetime = n },
                else => Value{ .timestamp = n },
            };
        },
        tag_numeric => return decodeDecimal(alloc, payload),
        tag_range => {
            if (payload.len != range_bytes) return error.CorruptData;
            const kind = std.enums.fromInt(value_mod.Range.ElemKind, payload[0]) orelse
                return error.CorruptData;
            const start: ?i64 = switch (payload[1]) {
                range_start_bounded => unorderable(std.mem.readInt(u64, payload[2..10], .big)),
                range_start_unbounded => null,
                else => return error.CorruptData,
            };
            const end: ?i64 = switch (payload[10]) {
                range_end_bounded => unorderable(std.mem.readInt(u64, payload[11..19], .big)),
                range_end_unbounded => null,
                else => return error.CorruptData,
            };
            return value_mod.rangeValue(kind, start, end);
        },
        else => return error.CorruptData, // unexpected tag
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "round trips every eligible kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const vals = [_]Value{
        .{ .string = "" },
        .{ .string = "hello" },
        .{ .string = "\x00\xff" },
        .{ .bytes = "" },
        .{ .bytes = "\x00\x01\xff" },
        .{ .date = 0 },
        .{ .date = -719162 },
        .{ .date = 100000 },
        .{ .time = 0 },
        .{ .datetime = -1 },
        .{ .timestamp = std.math.minInt(i64) },
        .{ .timestamp = std.math.maxInt(i64) },
        // All four boundedness combinations, at every element kind: the
        // presence bytes and the zero-fill under an absent bound are what
        // these check survive a round trip.
        value_mod.rangeValue(.date, 100, 200),
        value_mod.rangeValue(.date, null, 200),
        value_mod.rangeValue(.date, 100, null),
        value_mod.rangeValue(.date, null, null),
        value_mod.rangeValue(.datetime, -5, 5),
        value_mod.rangeValue(.timestamp, std.math.minInt(i64), std.math.maxInt(i64)),
    };
    for (vals) |v| {
        const enc = (try encode(alloc, v)).?;
        try value_mod.expectValueEqual(v, try decode(alloc, enc));
    }
}

/// `n` copies of one hex-encoded byte.
fn hexBytes(comptime byte: *const [2]u8, comptime n: u8) *const [2 * @as(usize, n)]u8 {
    return comptime blk: {
        var out: [2 * @as(usize, n)]u8 = undefined;
        for (0..n) |i| out[2 * i ..][0..2].* = byte.*;
        const result = out;
        break :blk &result;
    };
}

test "decimals encode to the shared header, magnitude and kind vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Both kinds at scale 38: NUMERIC 1.5 and BIGNUMERIC 1.5 differ only in the
    // trailing kind byte, and a negative inverts its magnitude under a header
    // below 0x80.
    const ten38: i256 = 100000000000000000000000000000000000000;
    const cases = [_]struct { unscaled: i256, big: bool, hex: []const u8 }{
        .{
            .unscaled = std.math.minInt(i256),
            .big = true,
            .hex = "60" ++ "7f" ++ hexBytes("ff", 31) ++ "01",
        },
        .{ .unscaled = -1_500_000_000, .big = false, .hex = "708f270d037835d948f1b0cc9fffffffff00" },
        .{ .unscaled = -1, .big = true, .hex = "7ffe01" },
        .{ .unscaled = 0, .big = false, .hex = "8000" },
        .{ .unscaled = 0, .big = true, .hex = "8001" },
        .{ .unscaled = 1, .big = true, .hex = "810101" },
        .{ .unscaled = 1, .big = false, .hex = "8d01431e0fae6d7217caa000000000" },
        .{ .unscaled = 1_500_000_000, .big = false, .hex = "9070d8f2fc87ca26b70e4f33600000000000" },
        .{ .unscaled = ten38 * 3 / 2, .big = true, .hex = "9070d8f2fc87ca26b70e4f33600000000001" },
        .{
            .unscaled = value_mod.numeric_unscaled_max,
            .big = false,
            .hex = "9c5ef4a74721e864761ea977768e5f518a736b0c39928de8356000000000",
        },
        .{
            .unscaled = std.math.maxInt(i256),
            .big = true,
            .hex = "a0" ++ "7f" ++ hexBytes("ff", 31) ++ "01",
        },
    };
    for (cases) |tc| {
        const v = try value_mod.numericFromUnscaled(alloc, tc.unscaled, tc.big);
        const enc = (try encode(alloc, v)).?;
        try testing.expectEqual(tag_numeric, enc[0]);
        const hex = try std.fmt.allocPrint(alloc, "{x}", .{enc[1..]});
        try testing.expectEqualStrings(tc.hex, hex);
        // And back, so the vectors pin decode too.
        try value_mod.expectValueEqual(v, try decode(alloc, enc));
    }

    // Past NUMERIC's 38 digits is rejected rather than wrapped into the
    // magnitude.
    var too_wide: value_mod.Numeric = .{ .unscaled = value_mod.numeric_unscaled_max + 1 };
    try testing.expectError(error.NumericOutOfRange, encode(alloc, .{ .numeric = &too_wide }));
}

test "decimal decode accepts only the canonical encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const corrupt = [_][]const u8{
        &.{tag_numeric},
        &.{ tag_numeric, decimal_zero },
        // Length disagrees with the header.
        &.{ tag_numeric, 0x82, 0x01, kind_bignumeric },
        &.{ tag_numeric, 0x81, 0x01, kind_bignumeric, 0x00 },
        // Non-minimal magnitude, positive and negative.
        &.{ tag_numeric, 0x82, 0x00, 0x01, kind_bignumeric },
        &.{ tag_numeric, 0x7e, 0xff, 0xfe, kind_bignumeric },
        // Unknown kind.
        &.{ tag_numeric, 0x81, 0x01, 0x02 },
        // A NUMERIC off its scale-9 grid: 10^-38 is not a multiple of 10^-9.
        &.{ tag_numeric, 0x81, 0x01, kind_numeric },
        // 2^29 clears the factor of two in 10^29 but not the 5^29.
        &.{ tag_numeric, 0x84, 0x20, 0x00, 0x00, 0x00, kind_numeric },
        // Longer than any magnitude.
        &(.{ tag_numeric, 0xa1 } ++ @as([33]u8, @splat(0x01)) ++ .{kind_bignumeric}),
        // +2^255 is one past BIGNUMERIC's maximum.
        &(.{ tag_numeric, 0xa0, 0x80 } ++ @as([31]u8, @splat(0x00)) ++ .{kind_bignumeric}),
        // 10^38 at NUMERIC's scale: one past its 38 digits.
        &(.{ tag_numeric, 0x9c } ++ numericTooLarge() ++ .{kind_numeric}),
    };
    for (corrupt) |bytes| {
        try testing.expectError(error.CorruptData, decode(alloc, bytes));
    }
}

/// 10^38 * 10^29, NUMERIC's first out-of-range magnitude at the common scale.
fn numericTooLarge() [28]u8 {
    var be: [32]u8 = undefined;
    std.mem.writeInt(u256, &be, (value_mod.numeric_unscaled_max + 1) * numeric_to_common, .big);
    return be[4..].*;
}

test "memcmp over encodings matches compareForCollation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // This is the invariant the whole format exists for. If it ever fails,
    // BLOB columns of that kind sort wrongly with no error anywhere.
    const groups = [_][]const Value{
        &.{
            .{ .string = "" },   .{ .string = "a" }, .{ .string = "aa" },
            .{ .string = "ab" }, .{ .string = "b" }, .{ .string = "\xff" },
        },
        &.{ .{ .bytes = "" }, .{ .bytes = "\x00" }, .{ .bytes = "\x00\x00" }, .{ .bytes = "\xff" } },
        // Pre-epoch values are the ones a naive big-endian encoding gets wrong:
        // the sign bit makes them sort above everything unless it is flipped.
        &.{
            .{ .date = -719162 }, .{ .date = -1 },     .{ .date = 0 },
            .{ .date = 1 },       .{ .date = 100000 },
        },
        &.{
            .{ .timestamp = std.math.minInt(i64) }, .{ .timestamp = -1 },
            .{ .timestamp = 0 },                    .{ .timestamp = 1 },
            .{ .timestamp = std.math.maxInt(i64) },
        },
        &.{ .{ .datetime = -5 }, .{ .datetime = 0 }, .{ .datetime = 5 } },
        &.{ .{ .time = 0 }, .{ .time = 1 }, .{ .time = 86_399_999_999 } },
        // RANGE, listed in ascending order by hand. This is the group that
        // pins the two presence bytes being *inverted* relative to each other:
        // an unbounded start is -inf and must come first, an unbounded end is
        // +inf and must come last within a shared start. Read them as one
        // shared "is present" flag and [x, UNBOUNDED) silently sorts below
        // [x, anything), which nothing else here would catch.
        &.{
            value_mod.rangeValue(.date, null, 100),
            value_mod.rangeValue(.date, null, 200),
            value_mod.rangeValue(.date, null, null),
            value_mod.rangeValue(.date, 100, 150),
            value_mod.rangeValue(.date, 100, 200),
            value_mod.rangeValue(.date, 100, null),
            value_mod.rangeValue(.date, 200, 250),
        },
        &.{
            value_mod.rangeValue(.timestamp, null, null),
            value_mod.rangeValue(.timestamp, -1, 0),
            value_mod.rangeValue(.timestamp, 0, 1),
            value_mod.rangeValue(.timestamp, 0, null),
        },
        // Cross-kind. Unreachable through analyzed SQL — a column carries one
        // static element type — but total anyway, which is why RANGE needs no
        // documented divergence of the kind NUMERIC/BIGNUMERIC has above.
        &.{
            value_mod.rangeValue(.date, 0, 1),
            value_mod.rangeValue(.datetime, 0, 1),
            value_mod.rangeValue(.timestamp, 0, 1),
        },
    };
    // Numerics are constructed, not written as literals. One group with both
    // kinds interleaved: BIGNUMERICs below NUMERIC's resolution fall between
    // NUMERIC neighbours, and at an equal value NUMERIC comes first.
    const n = value_mod.numericFromUnscaled;
    const ten29: i256 = 100000000000000000000000000000;
    const numeric_groups = [_][]const Value{&.{
        try n(alloc, std.math.minInt(i256), true),
        try n(alloc, -value_mod.numeric_unscaled_max, false),
        try n(alloc, -1_500_000_000, false),
        try n(alloc, -1_500_000_000 * ten29, true),
        try n(alloc, -1, false),
        try n(alloc, -ten29, true),
        try n(alloc, -1, true),
        try n(alloc, 0, false),
        try n(alloc, 0, true),
        try n(alloc, 1, true),
        try n(alloc, ten29 / 2, true),
        try n(alloc, 1, false),
        try n(alloc, ten29, true),
        try n(alloc, 1_500_000_000, false),
        try n(alloc, 1_500_000_000 * ten29, true),
        try n(alloc, value_mod.numeric_unscaled_max, false),
        try n(alloc, std.math.maxInt(i256), true),
    }};

    var checked: usize = 0;
    for (groups ++ numeric_groups) |group| {
        for (group) |a| {
            for (group) |b| {
                const ea = (try encode(alloc, a)).?;
                const eb = (try encode(alloc, b)).?;
                const want = value_mod.compareForCollation(a, b) catch .lt;
                try testing.expectEqual(want, std.mem.order(u8, ea, eb));
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 100);

    // The numeric group is listed in ascending order, so each encoding sorts
    // strictly below the next.
    const ordered = numeric_groups[0];
    for (ordered[0 .. ordered.len - 1], ordered[1..]) |a, b| {
        const ea = (try encode(alloc, a)).?;
        const eb = (try encode(alloc, b)).?;
        try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, ea, eb));
    }
}
