//! The SQLite statements that move a table's rows from its current columns to a new layout.
//!
//! A layout lists the table's columns after the change, each either continuing a current column
//! or new. For a table `t (a INT64, r STRUCT<x INT64>)` and the layout
//!
//!     a (continues a), r STRUCT<x INT64, z STRING> (continues r), c STRING (new)
//!
//! the plan is in place:
//!
//!     ALTER TABLE `t` ADD COLUMN `c` TEXT
//!     UPDATE `t` SET `r` = zigquery_widen(`r`,'','z',NULL)
//!
//! A layout that drops, renames, reorders or relaxes a column instead rebuilds the table from a
//! SELECT with one expression per new column: the current column, widened when its STRUCT type
//! gained fields, or what an existing row reads for a new one, which is NULL or an empty array.
//! SQLite's own DROP COLUMN and RENAME COLUMN refuse to run while any view in the database fails
//! to resolve, which BigQuery allows.

const std = @import("std");
const spec = @import("spec.zig");
const pb = @import("../proto/resolved_ast.zig");

/// One column of the layout a change leaves a table with.
pub const ColumnChange = struct {
    column: *const spec.ColumnSpec,
    /// The index of the current column this one continues, or null for a new column, which
    /// reads NULL in every existing row.
    from: ?u32 = null,
};

pub const Plan = union(enum) {
    in_place: struct {
        /// Appended with ALTER TABLE ADD COLUMN, in order.
        added: []const *const spec.ColumnSpec,
        /// UPDATE assignments, `column = expression`, for current columns whose STRUCT types
        /// gained fields.
        rewrites: []const []const u8,
    },
    /// The SELECT list that fills the rebuilt table, one expression per layout column.
    rebuild: []const []const u8,
};

pub const Error = error{
    OutOfMemory,
    /// A column continues one whose type it does not extend.
    IncompatibleType,
    InvalidType,
};

pub fn plan(
    arena: std.mem.Allocator,
    current: []const *const spec.ColumnSpec,
    layout: []const ColumnChange,
) Error!Plan {
    var p: Planner = .{ .arena = arena, .current = current };
    for (layout) |change| {
        if (change.from) |from| {
            try continueColumn(&p, change.column, from);
        } else {
            try addColumn(&p, change.column);
        }
    }
    const kept = layout.len - p.added.items.len;
    if (!p.is_in_place or kept != current.len) return .{ .rebuild = p.exprs.items };
    return .{ .in_place = .{ .added = p.added.items, .rewrites = p.rewrites.items } };
}

/// Both plans at once, one layout column at a time, until a column rules the in-place one out.
const Planner = struct {
    arena: std.mem.Allocator,
    current: []const *const spec.ColumnSpec,
    exprs: std.ArrayList([]const u8) = .empty,
    rewrites: std.ArrayList([]const u8) = .empty,
    added: std.ArrayList(*const spec.ColumnSpec) = .empty,
    is_in_place: bool = true,
};

fn addColumn(p: *Planner, column: *const spec.ColumnSpec) Error!void {
    const value = emptyValueSql(column.type);
    try p.exprs.append(p.arena, value);
    try p.added.append(p.arena, column);
    if (!column.type.isArray()) return;
    const rewrite = try std.fmt.allocPrint(p.arena, "`{s}` = {s}", .{ column.name, value });
    try p.rewrites.append(p.arena, rewrite);
}

fn continueColumn(p: *Planner, column: *const spec.ColumnSpec, from: u32) Error!void {
    if (from >= p.current.len) return error.IncompatibleType;
    const old = p.current[from];
    const quoted = try std.fmt.allocPrint(p.arena, "`{s}`", .{old.name});
    const widened = try widenCall(p.arena, quoted, old.type, column.type);
    const position = p.exprs.items.len;
    try p.exprs.append(p.arena, widened orelse quoted);
    const keeps_place = p.added.items.len == 0 and from == position and
        try sameDeclaration(p.arena, old, column);
    if (!keeps_place) {
        p.is_in_place = false;
        return;
    }
    const expr = widened orelse return;
    try p.rewrites.append(p.arena, try std.fmt.allocPrint(p.arena, "{s} = {s}", .{ quoted, expr }));
}

/// Whether a continued column keeps its name, its NOT NULL and its SQLite declaration, so its
/// stored values need no copy.
fn sameDeclaration(
    arena: std.mem.Allocator,
    old: *const spec.ColumnSpec,
    new: *const spec.ColumnSpec,
) Error!bool {
    if (!std.mem.eql(u8, old.name, new.name) or old.is_not_null != new.is_not_null) return false;
    const old_sql = old.declarationSql(arena) catch |err| return declarationError(err);
    const new_sql = new.declarationSql(arena) catch |err| return declarationError(err);
    return std.mem.eql(u8, old_sql, new_sql);
}

fn declarationError(err: spec.Error) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidType;
}

/// The zigquery_widen call that reads `column`, of `old_type`, as `new_type`, with one position
/// and name per STRUCT field `new_type` adds; null when `new_type` adds none.
fn widenCall(
    arena: std.mem.Allocator,
    column: []const u8,
    old_type: *const spec.Type,
    new_type: *const spec.Type,
) Error!?[]const u8 {
    var collector: AddedFields = .{ .arena = arena };
    try collectAddedFields(&collector, old_type, new_type, "");
    if (collector.args.items.len == 0) return null;
    const args = collector.args.items;
    return try std.fmt.allocPrint(arena, "zigquery_widen({s}{s})", .{ column, args });
}

/// zigquery_widen's arguments after the column: `,'<position>','<name>',<value>` for each field
/// a new type has past the end of a STRUCT in the old one, at any depth. Positions are as
/// codec_binary.appendMember reads them.
const AddedFields = struct {
    arena: std.mem.Allocator,
    args: std.ArrayList(u8) = .empty,
};

fn collectAddedFields(
    c: *AddedFields,
    old: *const spec.Type,
    new: *const spec.Type,
    position: []const u8,
) Error!void {
    if (old.kind != new.kind) return error.IncompatibleType;
    if (old.isArray()) {
        const old_elem = old.element_type orelse return error.InvalidType;
        const new_elem = new.element_type orelse return error.InvalidType;
        const inner = try childPosition(c.arena, position, "[]");
        return collectAddedFields(c, old_elem, new_elem, inner);
    }
    if (!old.isStruct()) return;
    if (new.field_types.len < old.field_types.len) return error.IncompatibleType;
    for (old.field_types, new.field_types[0..old.field_types.len], 0..) |of, nf, i| {
        const old_field = of.type orelse return error.InvalidType;
        const new_field = nf.type orelse return error.InvalidType;
        const index = try std.fmt.allocPrint(c.arena, "{d}", .{i});
        const child = try childPosition(c.arena, position, index);
        try collectAddedFields(c, old_field, new_field, child);
    }
    for (new.field_types[old.field_types.len..]) |field| {
        const field_type = field.type orelse return error.InvalidType;
        try c.args.append(c.arena, ',');
        try appendSqlString(c.arena, &c.args, position);
        try c.args.append(c.arena, ',');
        try appendSqlString(c.arena, &c.args, field.name);
        try c.args.append(c.arena, ',');
        try c.args.appendSlice(c.arena, emptyValueSql(field_type));
    }
}

/// What an existing row reads for a column or STRUCT field it never had: an empty array for an
/// ARRAY, since BigQuery has no NULL arrays, else NULL.
fn emptyValueSql(t: *const spec.Type) []const u8 {
    return if (t.isArray()) empty_array_sql else "NULL";
}

/// An empty ARRAY in the binary codec.
const empty_array_sql = "x'0e00'";

fn childPosition(
    arena: std.mem.Allocator,
    position: []const u8,
    segment: []const u8,
) error{OutOfMemory}![]const u8 {
    if (position.len == 0) return segment;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ position, segment });
}

fn appendSqlString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) error{OutOfMemory}!void {
    try out.append(arena, '\'');
    for (text) |ch| {
        if (ch == '\'') try out.append(arena, '\'');
        try out.append(arena, ch);
    }
    try out.append(arena, '\'');
}

const testing = std.testing;

test "an empty ARRAY's literal matches the binary codec" {
    const codec_binary = @import("codec_binary.zig");
    const value_mod = @import("value.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const empty = try value_mod.arrayValue(alloc, &.{});
    const encoded = try codec_binary.encodeBinaryValue(alloc, empty);
    const hex = try std.fmt.allocPrint(alloc, "x'{x}'", .{encoded});
    try testing.expectEqualStrings(empty_array_sql, hex);
}

const Fixture = struct {
    arena: std.mem.Allocator,

    fn leaf(f: Fixture, kind: pb.TypeKind) !*spec.Type {
        return spec.newSimpleType(f.arena, kind);
    }

    fn record(f: Fixture, names: []const []const u8, types: []const *spec.Type) !*spec.Type {
        const fields = try f.arena.alloc(*spec.NameWithType, names.len);
        for (names, types, fields) |name, t, *field| {
            field.* = try f.arena.create(spec.NameWithType);
            field.*.* = .{ .name = name, .type = t };
        }
        const t = try f.arena.create(spec.Type);
        t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = fields };
        return t;
    }

    fn array(f: Fixture, elem: *spec.Type) !*spec.Type {
        const t = try f.arena.create(spec.Type);
        t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_ARRAY), .element_type = elem };
        return t;
    }

    fn column(f: Fixture, name: []const u8, t: *spec.Type) !*const spec.ColumnSpec {
        const col = try f.arena.create(spec.ColumnSpec);
        col.* = .{ .name = name, .type = t };
        return col;
    }
};

test "appending columns and STRUCT fields changes the table in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f: Fixture = .{ .arena = arena_state.allocator() };

    const a = try f.column("a", try f.leaf(.TYPE_INT64));
    const x = try f.record(&.{"x"}, &.{try f.leaf(.TYPE_INT64)});
    const items = try f.column("items", try f.array(x));
    const wider_items = try f.column("items", try f.array(try f.record(
        &.{ "x", "y's" },
        &.{ try f.leaf(.TYPE_INT64), try f.leaf(.TYPE_STRING) },
    )));
    const c = try f.column("c", try f.leaf(.TYPE_STRING));

    const got = try plan(f.arena, &.{ a, items }, &.{
        .{ .column = a, .from = 0 },
        .{ .column = wider_items, .from = 1 },
        .{ .column = c },
    });
    try testing.expectEqual(@as(usize, 1), got.in_place.added.len);
    try testing.expectEqualStrings("c", got.in_place.added[0].name);
    try testing.expectEqual(@as(usize, 1), got.in_place.rewrites.len);
    try testing.expectEqualStrings(
        "`items` = zigquery_widen(`items`,'[]','y''s',NULL)",
        got.in_place.rewrites[0],
    );
}

test "an ARRAY column or field that a row never had reads as empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f: Fixture = .{ .arena = arena_state.allocator() };

    const r = try f.column("r", try f.record(&.{"x"}, &.{try f.leaf(.TYPE_INT64)}));
    const wider_r = try f.column("r", try f.record(
        &.{ "x", "tags" },
        &.{ try f.leaf(.TYPE_INT64), try f.array(try f.leaf(.TYPE_STRING)) },
    ));
    const top = try f.column("top", try f.array(try f.leaf(.TYPE_STRING)));
    const got = try plan(f.arena, &.{r}, &.{
        .{ .column = wider_r, .from = 0 },
        .{ .column = top },
    });
    try testing.expectEqualStrings(
        "`r` = zigquery_widen(`r`,'','tags',x'0e00')",
        got.in_place.rewrites[0],
    );
    try testing.expectEqualStrings("`top` = x'0e00'", got.in_place.rewrites[1]);
}

test "dropping, renaming or relaxing a column rebuilds from one expression per new column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f: Fixture = .{ .arena = arena_state.allocator() };

    const a = try f.column("a", try f.leaf(.TYPE_INT64));
    const b = try f.column("b", try f.leaf(.TYPE_STRING));
    const r = try f.column("r", try f.record(&.{"x"}, &.{try f.leaf(.TYPE_INT64)}));
    const renamed = try f.column("b2", try f.leaf(.TYPE_STRING));
    const wider_r = try f.column("r", try f.record(
        &.{ "x", "z" },
        &.{ try f.leaf(.TYPE_INT64), try f.leaf(.TYPE_DATE) },
    ));

    const got = try plan(f.arena, &.{ a, b, r }, &.{
        .{ .column = renamed, .from = 1 },
        .{ .column = wider_r, .from = 2 },
    });
    try testing.expectEqual(@as(usize, 2), got.rebuild.len);
    try testing.expectEqualStrings("`b`", got.rebuild[0]);
    try testing.expectEqualStrings("zigquery_widen(`r`,'','z',NULL)", got.rebuild[1]);

    const relaxed_a = try f.arena.create(spec.ColumnSpec);
    relaxed_a.* = a.*;
    const required_a = try f.arena.create(spec.ColumnSpec);
    required_a.* = a.*;
    required_a.is_not_null = true;
    const relaxed = try plan(f.arena, &.{required_a}, &.{.{ .column = relaxed_a, .from = 0 }});
    try testing.expectEqualStrings("`a`", relaxed.rebuild[0]);
}

test "a column that does not extend the type it continues is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f: Fixture = .{ .arena = arena_state.allocator() };

    const r = try f.column("r", try f.record(
        &.{ "x", "y" },
        &.{ try f.leaf(.TYPE_INT64), try f.leaf(.TYPE_INT64) },
    ));
    const narrower = try f.column("r", try f.record(&.{"x"}, &.{try f.leaf(.TYPE_INT64)}));
    const retyped = try f.column("r", try f.leaf(.TYPE_STRING));
    try testing.expectError(error.IncompatibleType, plan(f.arena, &.{r}, &.{
        .{ .column = narrower, .from = 0 },
    }));
    try testing.expectError(error.IncompatibleType, plan(f.arena, &.{r}, &.{
        .{ .column = retyped, .from = 0 },
    }));
}
