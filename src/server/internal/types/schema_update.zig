//! The schema a tables.patch or tables.update body leaves a table with, or BigQuery's 400 for it.
//!
//! BigQuery matches each field of the current schema to a posted field by name, ignoring case,
//! and keeps the current order and spelling. Posted fields that match nothing are appended in the
//! order they were posted, at whatever depth they appear. For example, against a table holding
//!
//!     a INTEGER REQUIRED, r RECORD<x INTEGER>
//!
//! a patch posting
//!
//!     A INTEGER NULLABLE, c STRING, r RECORD<z STRING, x INTEGER>
//!
//! leaves the table with
//!
//!     a INTEGER NULLABLE, r RECORD<x INTEGER, z STRING>, c STRING
//!
//! A field may relax from REQUIRED to NULLABLE and may take a posted description; every other
//! change to a current field is refused, as is a new REQUIRED field.
//! https://cloud.google.com/bigquery/docs/managing-table-schemas
// ephor:ignore-file ZT105

const std = @import("std");
const schema_mod = @import("schema.zig");

/// The current and posted `fields` arrays, as parsed from the table's resource and the request.
pub const Schemas = struct {
    current: []const std.json.Value,
    posted: []const std.json.Value,
};

/// What a posted schema does to a table.
pub const Outcome = union(enum) {
    /// The schema to store, and whether it changes the columns the engine holds. A posted schema
    /// that only repeats the current one, or adds descriptions, leaves the columns as they are.
    accepted: struct { fields: std.json.Array, changes_columns: bool },
    /// The 400's message, worded as BigQuery words it.
    rejected: []const u8,
};

/// Merges posted into current, or returns BigQuery's reason for refusing it. table_label names
/// the table as BigQuery's mismatch message does: `project:dataset.table`.
pub fn merge(
    arena: std.mem.Allocator,
    schemas: Schemas,
    table_label: []const u8,
) error{OutOfMemory}!Outcome {
    var merger: Merger = .{ .arena = arena, .table_label = table_label };
    const fields = mergeFields(&merger, schemas.current, schemas.posted, "") catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Rejected => return .{ .rejected = merger.rejection },
        };
    return .{ .accepted = .{ .fields = fields, .changes_columns = merger.changes_columns } };
}

const Merger = struct {
    arena: std.mem.Allocator,
    table_label: []const u8,
    changes_columns: bool = false,
    rejection: []const u8 = "",
};

const MergeError = error{ OutOfMemory, Rejected };

/// The head of every refusal that compares the posted schema with the table's.
const mismatch = "Provided Schema does not match Table {s}. ";

fn mergeFields(
    m: *Merger,
    current: []const std.json.Value,
    posted: []const std.json.Value,
    parent_path: []const u8,
) MergeError!std.json.Array {
    // BigQuery checks a fields array for repeated names before comparing it with the table.
    if (firstRepeatedName(posted)) |name| return reject(m, "Field {s} already exists in schema", .{name});
    const used = try m.arena.alloc(bool, posted.len);
    @memset(used, false);
    var out: std.json.Array = .init(m.arena);
    for (current) |field| {
        const name = fieldString(field, "name");
        const path = try joinPath(m.arena, parent_path, name);
        const missing = mismatch ++ "Field {s} is missing in new schema";
        const index = findByName(posted, name) orelse
            return reject(m, missing, .{ m.table_label, path });
        used[index] = true;
        try out.append(try mergeField(m, field, posted[index], path));
    }
    const required = mismatch ++ "Cannot add required fields to an existing schema. (field: {s})";
    for (posted, used) |field, was_matched| {
        if (was_matched) continue;
        const path = try joinPath(m.arena, parent_path, fieldString(field, "name"));
        const is_required = std.mem.eql(u8, modeOf(field), "REQUIRED");
        if (is_required) return reject(m, required, .{ m.table_label, path });
        m.changes_columns = true;
        try out.append(field);
    }
    return out;
}

/// The current field as posted, keeping its name, or a rejection when the type or the mode
/// changed in a way BigQuery refuses.
fn mergeField(
    m: *Merger,
    current: std.json.Value,
    posted: std.json.Value,
    path: []const u8,
) MergeError!std.json.Value {
    const current_type = canonicalType(fieldString(current, "type"));
    const posted_type = canonicalType(fieldString(posted, "type"));
    if (!std.mem.eql(u8, current_type, posted_type)) {
        const retyped = mismatch ++ "Field {s} has changed type from {s} to {s}";
        return reject(m, retyped, .{ m.table_label, path, current_type, posted_type });
    }
    const current_mode = modeOf(current);
    const posted_mode = modeOf(posted);
    const relaxes = std.mem.eql(u8, current_mode, "REQUIRED") and
        std.mem.eql(u8, posted_mode, "NULLABLE");
    if (!relaxes and !std.mem.eql(u8, current_mode, posted_mode)) {
        const remoded = mismatch ++ "Field {s} has changed mode from {s} to {s}";
        return reject(m, remoded, .{ m.table_label, path, current_mode, posted_mode });
    }
    if (relaxes) m.changes_columns = true;

    var merged: std.json.ObjectMap = .empty;
    var it = posted.object.iterator();
    while (it.next()) |kv| try merged.put(m.arena, kv.key_ptr.*, kv.value_ptr.*);
    try merged.put(m.arena, "name", current.object.get("name").?);
    if (std.mem.eql(u8, current_type, "RECORD")) {
        const fields = try mergeFields(m, subFields(current), subFields(posted), path);
        try merged.put(m.arena, "fields", .{ .array = fields });
    }
    return .{ .object = merged };
}

/// The first name in `fields` that an earlier field already has, ignoring case.
fn firstRepeatedName(fields: []const std.json.Value) ?[]const u8 {
    for (fields, 0..) |field, i| {
        const name = fieldString(field, "name");
        if (findByName(fields[0..i], name) != null) return name;
    }
    return null;
}

fn reject(m: *Merger, comptime fmt: []const u8, args: anytype) MergeError {
    m.rejection = try std.fmt.allocPrint(m.arena, fmt, args);
    return error.Rejected;
}

/// The index of the field named `name`, compared as BigQuery compares field names: ignoring case.
fn findByName(fields: []const std.json.Value, name: []const u8) ?usize {
    for (fields, 0..) |field, i| {
        if (std.ascii.eqlIgnoreCase(fieldString(field, "name"), name)) return i;
    }
    return null;
}

fn joinPath(
    arena: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) error{OutOfMemory}![]const u8 {
    if (parent.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, name });
}

/// A string member of a field object, or "" when it is absent or not a string.
fn fieldString(field: std.json.Value, key: []const u8) []const u8 {
    if (field != .object) return "";
    const v = field.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// A field's mode, NULLABLE when the field leaves it out, as the REST API defaults it.
fn modeOf(field: std.json.Value) []const u8 {
    const mode = fieldString(field, "mode");
    return if (mode.len == 0) "NULLABLE" else mode;
}

fn subFields(field: std.json.Value) []const std.json.Value {
    if (field != .object) return &.{};
    const fields = field.object.get("fields") orelse return &.{};
    return if (fields == .array) fields.array.items else &.{};
}

/// The legacy name BigQuery's messages use for a type however the client spelled it: INT64 and
/// INTEGER are both INTEGER, STRUCT and RECORD are both RECORD. An unknown name passes through,
/// so two different unknown names still compare unequal.
fn canonicalType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "STRUCT") or std.mem.eql(u8, name, "RECORD")) return "RECORD";
    const standard = schema_mod.googleSqlTypeName(name) orelse return name;
    const legacy = std.StaticStringMap([]const u8).initComptime(.{
        .{ "INT64", "INTEGER" },
        .{ "FLOAT64", "FLOAT" },
        .{ "BOOL", "BOOLEAN" },
    });
    return legacy.get(standard) orelse standard;
}

const testing = std.testing;

fn parseFields(arena: std.mem.Allocator, text: []const u8) ![]const std.json.Value {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return v.array.items;
}

fn mergeText(arena: std.mem.Allocator, current: []const u8, posted: []const u8) !Outcome {
    return merge(arena, .{
        .current = try parseFields(arena, current),
        .posted = try parseFields(arena, posted),
    }, "p:d.t");
}

fn expectRejected(current: []const u8, posted: []const u8, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try mergeText(arena_state.allocator(), current, posted);
    try testing.expectEqualStrings(message, outcome.rejected);
}

fn expectAccepted(current: []const u8, posted: []const u8, want: []const u8, changes: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = try mergeText(arena, current, posted);
    const accepted = outcome.accepted;
    const fields: std.json.Value = .{ .array = accepted.fields };
    const got = try std.json.Stringify.valueAlloc(arena, fields, .{});
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(changes, accepted.changes_columns);
}

const table_fields =
    \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING"},
    \\ {"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"REQUIRED"}]}]
;

test "an unchanged schema, however it is spelled, changes no columns" {
    try expectAccepted(table_fields,
        \\[{"name":"r","type":"STRUCT","mode":"NULLABLE","fields":[{"name":"y","type":"STRING","mode":"REQUIRED"},{"name":"X","type":"INT64"}]},
        \\ {"name":"B","type":"STRING","description":"names"},{"name":"a","type":"INT64","mode":"REQUIRED"}]
    ,
        \\[{"name":"a","type":"INT64","mode":"REQUIRED"},{"name":"b","type":"STRING","description":"names"},{"name":"r","type":"STRUCT","mode":"NULLABLE","fields":[{"name":"x","type":"INT64"},{"name":"y","type":"STRING","mode":"REQUIRED"}]}]
    , false);
}

test "new fields are appended at the end of their RECORD, in posted order" {
    try expectAccepted(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"c","type":"STRING"},{"name":"b","type":"STRING"},
        \\ {"name":"r","type":"RECORD","fields":[{"name":"z","type":"DATE","mode":"REPEATED"},{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"REQUIRED"}]},
        \\ {"name":"q","type":"RECORD","fields":[{"name":"q1","type":"STRING","mode":"REQUIRED"}]}]
    ,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING"},{"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"REQUIRED"},{"name":"z","type":"DATE","mode":"REPEATED"}]},{"name":"c","type":"STRING"},{"name":"q","type":"RECORD","fields":[{"name":"q1","type":"STRING","mode":"REQUIRED"}]}]
    , true);
}

test "REQUIRED relaxes to NULLABLE at any depth" {
    try expectAccepted(table_fields,
        \\[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"},
        \\ {"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"NULLABLE"}]}]
    ,
        \\[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"},{"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"NULLABLE"}]}]
    , true);
}

test "a missing, retyped, tightened or new REQUIRED field is refused with BigQuery's message" {
    const prefix = "Provided Schema does not match Table p:d.t. ";
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"bb","type":"STRING"},{"name":"r","type":"RECORD","fields":[]}]
    , prefix ++ "Field b is missing in new schema");
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING"},{"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"}]}]
    , prefix ++ "Field r.y is missing in new schema");
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"INT64"}]
    , prefix ++ "Field b has changed type from STRING to INTEGER");
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING","mode":"REPEATED"}]
    , prefix ++ "Field b has changed mode from NULLABLE to REPEATED");
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING"},
        \\ {"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING","mode":"REQUIRED"},{"name":"z","type":"STRING","mode":"REQUIRED"}]}]
    , prefix ++ "Cannot add required fields to an existing schema. (field: r.z)");
}

test "a repeated posted name is refused before anything is compared" {
    try expectRejected(table_fields,
        \\[{"name":"a","type":"INTEGER","mode":"REQUIRED"},{"name":"b","type":"STRING"},{"name":"B","type":"INT64"}]
    , "Field B already exists in schema");
}
