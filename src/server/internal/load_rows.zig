//! Turning a load job's uploaded bytes into the schema and rows the content store writes.
//!
//! The rows come out in the shape `tabledata.insertAll` posts: one JSON object per row, keyed
//! by column name. That is what `contentdata.Repository.addTableData` already takes, so a load
//! and a streaming insert converge here rather than in two write paths.

const std = @import("std");
const zigquery = @import("zigquery");
const spec_mod = zigquery.spec;
const autodetect = @import("autodetect.zig");
const csv = @import("csv.zig");
const rowvalue = @import("types/rowvalue.zig");
const schema_mod = @import("types/schema.zig");
const load_handler = @import("../handler/jobs.load.zig");
const pb = @import("../proto/bigquery.zig");

pub const Error = error{
    /// Nothing said what the destination's columns are.
    NoSchema,
    /// A JSON line that is not an object, or a member this emulator does not read.
    NotAnObject,
    MalformedJson,
    MalformedCsv,
} || std.mem.Allocator.Error;

pub const Reading = struct {
    /// The destination's schema as a REST resource node, for the DDL and the metadata store.
    schema_node: std.json.Value,
    /// The same fields, as `addTableData` takes them.
    schema_fields: []const std.json.Value,
    columns: []const Column,
    /// The rows as they were read, turned into objects a batch at a time by `Batcher`.
    source: Source,
    /// Records rejected before any row was built.
    bad_records: u64,
    /// Leading rows a CSV source skipped before its data; zero for NEWLINE_DELIMITED_JSON.
    data_start: usize = 0,

    pub fn rowCount(r: Reading) usize {
        return switch (r.source) {
            .csv => |rows| rows.len,
            .json => |rows| rows.len,
        };
    }
};

/// Rows in the shape their format produced. A CSV row is cells to be named and typed; a JSON
/// line is already the object the content store takes.
pub const Source = union(enum) {
    csv: []const csv.Row,
    json: []const std.json.Value,
};

const Column = struct {
    name: []const u8,
    /// A legacy REST type name. For a REPEATED column, the element's name:
    /// ARRAY<RECORD<...>> is a RECORD the mode marks REPEATED, the way the
    /// REST API writes it.
    type_name: []const u8,
    /// NULLABLE, REQUIRED or REPEATED. NULLABLE when the source said nothing.
    mode: []const u8 = "NULLABLE",
    /// A RECORD column's members, as schema nodes. Empty for a scalar.
    fields: []const std.json.Value = &.{},
};

pub fn readErrorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NoSchema => "the load names no schema: supply one, enable autodetect, or " ++
            "load into an existing table",
        error.NotAnObject => "every line of NEWLINE_DELIMITED_JSON data must be an object",
        error.MalformedJson => "the data is not newline-delimited JSON",
        error.MalformedCsv => "the data is not readable as CSV",
        error.OutOfMemory => "out of memory",
    };
}

pub fn read(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) Error!Reading {
    return readOne(arena, media, spec, .{ .columns = try declaredColumns(arena, spec, existing) });
}

/// Reads several sources as one load, each source's rows in source order.
///
/// The first source with any content settles the columns and, for CSV, how many leading rows
/// every source skips, as a single source would on its own. The others are read under those,
/// so a shard holding only a header row yields no rows and an empty shard says nothing.
pub fn readMany(
    arena: std.mem.Allocator,
    sources: []const []const u8,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) Error!Reading {
    std.debug.assert(sources.len != 0);
    const leader = firstWithContent(sources);
    var reading = try readOne(arena, sources[leader], spec, .{
        .columns = try declaredColumns(arena, spec, existing),
    });
    if (sources.len == 1) return reading;

    const settled: Settled = .{ .columns = reading.columns, .data_start = reading.data_start };
    var csv_rows: std.ArrayList(csv.Row) = .empty;
    var json_rows: std.ArrayList(std.json.Value) = .empty;
    var bad_records: u64 = 0;
    for (sources, 0..) |media, i| {
        const part = if (i == leader) reading else try readOne(arena, media, spec, settled);
        switch (part.source) {
            .csv => |rows| try csv_rows.appendSlice(arena, rows),
            .json => |rows| try json_rows.appendSlice(arena, rows),
        }
        bad_records += part.bad_records;
    }
    reading.bad_records = bad_records;
    reading.source = switch (reading.source) {
        .csv => .{ .csv = csv_rows.items },
        .json => .{ .json = json_rows.items },
    };
    return reading;
}

/// The index of the first source holding anything but whitespace, or 0 when none does.
fn firstWithContent(sources: []const []const u8) usize {
    for (sources, 0..) |media, i| {
        if (std.mem.trim(u8, media, " \t\r\n").len != 0) return i;
    }
    return 0;
}

/// What an earlier source of the same load settled for the ones read after it.
const Settled = struct {
    /// The columns the source is read under. Null leaves them to the source to detect.
    columns: ?[]const Column = null,
    /// Leading CSV rows the source skips. Null leaves them to skipLeadingRows and autodetect.
    data_start: ?usize = null,
};

fn readOne(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    settled: Settled,
) Error!Reading {
    return switch (spec.source_format) {
        .CSV => readCsv(arena, media, spec, settled),
        .NEWLINE_DELIMITED_JSON => readJson(arena, media, spec, settled.columns),
    };
}

/// The columns a job supplied, or the ones its destination already has. Null when neither did,
/// which leaves autodetect to decide.
fn declaredColumns(
    arena: std.mem.Allocator,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) !?[]const Column {
    if (spec.schema) |schema| return try schemaColumns(arena, schema);
    if (existing) |table| return try tableColumns(arena, table);
    return null;
}

fn schemaColumns(arena: std.mem.Allocator, schema: *const pb.TableSchema) ![]const Column {
    const out = try arena.alloc(Column, schema.fields.len);
    for (schema.fields, out) |field, *column| {
        column.* = .{
            .name = field.name orelse "",
            .type_name = field.type orelse "STRING",
            .mode = field.mode orelse "NULLABLE",
            .fields = try pbFieldNodes(arena, field.fields),
        };
    }
    return out;
}

/// A posted field's RECORD members as schema nodes, recursively.
fn pbFieldNodes(
    arena: std.mem.Allocator,
    fields: []const *pb.TableFieldSchema,
) std.mem.Allocator.Error![]const std.json.Value {
    const out = try arena.alloc(std.json.Value, fields.len);
    for (fields, out) |field, *node| {
        node.* = try columnNode(arena, .{
            .name = field.name orelse "",
            .type_name = field.type orelse "STRING",
            .mode = field.mode orelse "NULLABLE",
            .fields = try pbFieldNodes(arena, field.fields),
        });
    }
    return out;
}

fn tableColumns(arena: std.mem.Allocator, table: *const spec_mod.TableSpec) ![]const Column {
    const out = try arena.alloc(Column, table.columns.len);
    for (table.columns, out) |source, *column| {
        column.* = try specColumn(arena, source.name, source.type, source.is_not_null);
    }
    return out;
}

/// One column from a catalog type: an ARRAY unwraps to its element, marked
/// REPEATED, and a STRUCT's members come along as schema nodes.
fn specColumn(
    arena: std.mem.Allocator,
    name: []const u8,
    t: *const spec_mod.Type,
    required: bool,
) std.mem.Allocator.Error!Column {
    const repeated = t.isArray();
    const elem = if (repeated) (t.element_type orelse t) else t;
    return .{
        .name = name,
        .type_name = schema_mod.legacyTypeName(elem.typeKind()),
        .mode = if (repeated) "REPEATED" else if (required) "REQUIRED" else "NULLABLE",
        .fields = if (elem.isStruct()) try specFieldNodes(arena, elem) else &.{},
    };
}

/// A STRUCT's members as schema nodes, recursively.
fn specFieldNodes(
    arena: std.mem.Allocator,
    struct_type: *const spec_mod.Type,
) std.mem.Allocator.Error![]const std.json.Value {
    const out = try arena.alloc(std.json.Value, struct_type.field_types.len);
    for (struct_type.field_types, out) |member, *node| {
        const column = try specColumn(
            arena,
            member.name,
            member.type orelse struct_type,
            member.is_not_null,
        );
        node.* = try columnNode(arena, column);
    }
    return out;
}

/// One column as a schema node. The mode is written only when it is not
/// NULLABLE, the spelling the REST schema itself uses.
fn columnNode(arena: std.mem.Allocator, column: Column) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "name", .{ .string = column.name });
    try object.put(arena, "type", .{ .string = column.type_name });
    if (!std.mem.eql(u8, column.mode, "NULLABLE")) {
        try object.put(arena, "mode", .{ .string = column.mode });
    }
    if (column.fields.len > 0) {
        var subs = std.json.Array.init(arena);
        try subs.appendSlice(column.fields);
        try object.put(arena, "fields", .{ .array = subs });
    }
    return .{ .object = object };
}

fn detectedColumns(arena: std.mem.Allocator, detection: autodetect.Detection) ![]const Column {
    const out = try arena.alloc(Column, detection.columns.len);
    for (detection.columns, out) |detected, *column| {
        column.* = .{
            .name = detected.name,
            .type_name = detected.kind.legacyTypeName(),
        };
    }
    return out;
}

fn schemaNodeFrom(arena: std.mem.Allocator, columns: []const Column) !std.json.Value {
    var fields = std.json.Array.init(arena);
    for (columns) |column| try fields.append(try columnNode(arena, column));
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "fields", .{ .array = fields });
    return .{ .object = root };
}

fn fieldsOf(schema_node: std.json.Value) []const std.json.Value {
    const fields = schema_node.object.get("fields") orelse return &.{};
    return if (fields == .array) fields.array.items else &.{};
}

/// The cells of only the rows detection reads: it samples, so copying the cells of a whole file
/// to hand it the first few hundred would cost more than the detection.
fn sampleTexts(
    arena: std.mem.Allocator,
    parsed: []const csv.Row,
    spec: load_handler.LoadSpec,
) ![]const []const []const u8 {
    const examined = @min(
        parsed.len,
        (spec.skip_leading_rows orelse 0) + autodetect.sample_rows + 1,
    );
    const texts = try arena.alloc([]const []const u8, examined);
    for (parsed[0..examined], texts) |row, *dst| {
        const cells = try arena.alloc([]const u8, row.len);
        for (row, cells) |field, *cell| cell.* = field.text;
        dst.* = cells;
    }
    return texts;
}

fn readCsv(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    settled: Settled,
) Error!Reading {
    const parsed = csv.parse(arena, media, .{
        .field_delimiter = spec.field_delimiter,
        .quote = spec.quote,
        .allow_quoted_newlines = spec.allow_quoted_newlines,
    }) catch return error.MalformedCsv;

    // Autodetect decides where the data starts even when the job supplied its own schema,
    // unless an earlier source of the load already did.
    const detection: ?autodetect.Detection = if (spec.autodetect and settled.data_start == null)
        try autodetect.detect(arena, try sampleTexts(arena, parsed, spec), spec.skip_leading_rows)
    else
        null;
    const data_start: usize = settled.data_start orelse if (detection) |d|
        d.data_start
    else if (spec.skip_leading_rows) |n| n else 0;

    const columns = settled.columns orelse
        try detectedColumns(arena, detection orelse return error.NoSchema);

    const schema_node = try schemaNodeFrom(arena, columns);
    const data = if (data_start < parsed.len) parsed[data_start..] else &.{};

    return .{
        .schema_node = schema_node,
        .schema_fields = fieldsOf(schema_node),
        .columns = columns,
        .source = .{ .csv = data },
        .bad_records = 0,
        .data_start = data_start,
    };
}

/// Rows per call to the content store. Large enough that the per-call overhead disappears,
/// small enough that the objects held at once do not scale with the file.
pub const batch_size = 4096;

/// Hands out one batch of rows at a time, reusing the objects it built for the last one.
///
/// A row is a `std.json.ObjectMap`, which allocates its own storage: one per row costs several
/// hundred bytes whatever the row holds, and a file's worth of them is what made a load cost
/// tens of times its own size. The maps here are cleared and refilled instead, so a load
/// allocates `batch_size` of them however many rows it carries.
pub const Batcher = struct {
    arena: std.mem.Allocator,
    reading: Reading,
    spec: load_handler.LoadSpec,
    pos: usize = 0,
    /// Rows the engine was never asked to store, because they did not fit their columns.
    bad_records: u64 = 0,
    maps: []std.json.ObjectMap,
    values: []std.json.Value,

    pub fn init(
        arena: std.mem.Allocator,
        reading: Reading,
        spec: load_handler.LoadSpec,
    ) !Batcher {
        const maps = try arena.alloc(std.json.ObjectMap, batch_size);
        // `alloc` hands back uninitialised memory, and a map is cleared before it is filled.
        for (maps) |*map| map.* = .empty;
        return .{
            .arena = arena,
            .reading = reading,
            .spec = spec,
            .maps = maps,
            .values = try arena.alloc(std.json.Value, batch_size),
        };
    }

    /// The next batch, or null when the rows run out. The slice is valid until the next call.
    pub fn next(b: *Batcher) !?[]const std.json.Value {
        switch (b.reading.source) {
            // A JSON line is already the object, so a batch is a window onto what was parsed.
            .json => |rows| {
                if (b.pos >= rows.len) return null;
                const end = @min(b.pos + batch_size, rows.len);
                const batch = rows[b.pos..end];
                b.pos = end;
                return batch;
            },
            .csv => |rows| return b.nextCsv(rows),
        }
    }

    fn nextCsv(b: *Batcher, rows: []const csv.Row) !?[]const std.json.Value {
        var built: usize = 0;
        while (b.pos < rows.len and built < batch_size) : (b.pos += 1) {
            if (!try b.build(rows[b.pos], &b.maps[built])) continue;
            b.values[built] = .{ .object = b.maps[built] };
            built += 1;
        }
        return if (built == 0) null else b.values[0..built];
    }

    /// Fills one pooled map from one CSV row. False when the row is a bad record.
    fn build(b: *Batcher, row: csv.Row, into: *std.json.ObjectMap) !bool {
        const columns = b.reading.columns;
        // A row with fewer fields than the schema is short; with more it is long. Each is a
        // bad record unless the job asked for it to be tolerated.
        if (row.len < columns.len and !b.spec.allow_jagged_rows) {
            b.bad_records += 1;
            return false;
        }
        if (row.len > columns.len and !b.spec.ignore_unknown_values) {
            b.bad_records += 1;
            return false;
        }

        into.clearRetainingCapacity();
        // Sized once rather than grown a column at a time. The map reallocates without ever
        // trying to extend in place, so each growth step abandons its previous buffer in the
        // arena, and a map crossing eight entries also allocates a hash index mid-loop.
        try into.ensureTotalCapacity(b.arena, columns.len);
        for (columns, 0..) |column, i| {
            const cell: ?csv.Field = if (i < row.len) row[i] else null;
            const value = (try cellValue(b.arena, cell, column, b.spec)) orelse {
                b.bad_records += 1;
                return false;
            };
            try into.put(b.arena, column.name, value);
        }
        return true;
    }
};

/// One cell as the JSON the content store expects, or null when it does not fit its column.
fn cellValue(
    arena: std.mem.Allocator,
    cell: ?csv.Field,
    column: Column,
    spec: load_handler.LoadSpec,
) !?std.json.Value {
    const field = cell orelse return .null;
    // A bare field equal to the null marker is null; a quoted one is that text.
    if (!field.quoted and std.mem.eql(u8, field.text, spec.null_marker)) return .null;
    const text = field.text;

    if (std.mem.eql(u8, column.type_name, "INTEGER")) {
        const n = std.fmt.parseInt(i64, text, 10) catch return null;
        return .{ .integer = n };
    }
    if (std.mem.eql(u8, column.type_name, "FLOAT")) {
        const f = std.fmt.parseFloat(f64, text) catch return null;
        return .{ .float = f };
    }
    if (std.mem.eql(u8, column.type_name, "BOOLEAN")) {
        return .{ .bool = parseBool(text) orelse return null };
    }
    if (std.mem.eql(u8, column.type_name, "DATE")) {
        return .{ .string = try autodetect.normalizeDate(arena, text) };
    }
    // TIME, TIMESTAMP and STRING all reach the engine as text, which casts them.
    return .{ .string = text };
}

fn parseBool(text: []const u8) ?bool {
    const truths = [_][]const u8{ "true", "t", "yes", "y" };
    const falsehoods = [_][]const u8{ "false", "f", "no", "n" };
    for (truths) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    for (falsehoods) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return false;
    }
    return null;
}

fn readJson(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    declared: ?[]const Column,
) Error!Reading {
    var objects = std.json.Array.init(arena);
    var bad: u64 = 0;
    var lines = std.mem.splitScalar(u8, media, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            bad += 1;
            continue;
        };
        if (value != .object) return error.NotAnObject;
        try objects.append(value);
    }

    const columns = declared orelse blk: {
        if (!spec.autodetect) return error.NoSchema;
        break :blk try jsonColumns(arena, objects.items);
    };

    const schema_node = try schemaNodeFrom(arena, columns);
    const schema_fields = fieldsOf(schema_node);
    for (objects.items) |*row| {
        try normalizeJsonRow(arena, &row.object, schema_fields);
    }
    return .{
        .schema_node = schema_node,
        .schema_fields = schema_fields,
        .columns = columns,
        .source = .{ .json = objects.items },
        .bad_records = bad,
    };
}

/// BigQuery reads an omitted or null REPEATED field as an empty array, at
/// every depth of a row, where an omitted or null RECORD is the NULL the row
/// already says. The parsed rows are rewritten to the REPEATED rule, so the
/// write path stores what BigQuery stores. The same rule on the streaming
/// write path is #114.
fn normalizeJsonRow(
    arena: std.mem.Allocator,
    object: *std.json.ObjectMap,
    fields: []const std.json.Value,
) std.mem.Allocator.Error!void {
    for (fields) |field| {
        const name = rowvalue.stringOf(field, "name");
        const subs = rowvalue.fieldsOf(field);
        if (std.mem.eql(u8, rowvalue.stringOf(field, "mode"), "REPEATED")) {
            const held = object.getPtr(name);
            if (held == null or held.?.* == .null) {
                try object.put(arena, name, .{ .array = std.json.Array.init(arena) });
                continue;
            }
            if (held.?.* == .array and subs.len > 0) {
                for (held.?.array.items) |*item| {
                    if (item.* == .object) {
                        try normalizeJsonRow(arena, &item.object, subs);
                    }
                }
            }
            continue;
        }
        if (subs.len > 0) {
            if (object.getPtr(name)) |held| {
                if (held.* == .object) {
                    try normalizeJsonRow(arena, &held.object, subs);
                }
            }
        }
    }
}

/// The shape the values under one name give it: a scalar kind, a RECORD with
/// a shape per member, or a REPEATED with one shape for its elements.
const JsonShape = struct {
    kind: autodetect.Kind = .unknown,
    record: bool = false,
    repeated: bool = false,
    fields: []const SeenField = &.{},
    elem: ?*JsonShape = null,
};

const SeenField = struct {
    name: []const u8,
    shape: JsonShape,
};

/// Column names in the order they first appear, typed from the values under them.
fn jsonColumns(arena: std.mem.Allocator, rows: []const std.json.Value) ![]const Column {
    var seen: std.ArrayList(SeenField) = .empty;
    for (rows) |row| {
        var it = row.object.iterator();
        while (it.next()) |entry| {
            const shape = try jsonShape(arena, entry.value_ptr.*);
            var merged = false;
            for (seen.items) |*column| {
                if (!std.mem.eql(u8, column.name, entry.key_ptr.*)) continue;
                column.shape = try mergeShapes(arena, column.shape, shape);
                merged = true;
                break;
            }
            if (!merged) {
                try seen.append(arena, .{ .name = entry.key_ptr.*, .shape = shape });
            }
        }
    }
    const out = try arena.alloc(Column, seen.items.len);
    for (out, seen.items) |*column, s| {
        column.* = try shapeColumn(arena, s.name, s.shape);
    }
    return out;
}

fn jsonShape(arena: std.mem.Allocator, value: std.json.Value) !JsonShape {
    switch (value) {
        .object => |object| {
            var fields: std.ArrayList(SeenField) = .empty;
            var it = object.iterator();
            while (it.next()) |entry| {
                try fields.append(arena, .{
                    .name = entry.key_ptr.*,
                    .shape = try jsonShape(arena, entry.value_ptr.*),
                });
            }
            return .{ .record = true, .fields = fields.items };
        },
        .array => |array| {
            var elem: JsonShape = .{};
            for (array.items) |item| {
                elem = try mergeShapes(arena, elem, try jsonShape(arena, item));
            }
            const held = try arena.create(JsonShape);
            held.* = elem;
            return .{ .repeated = true, .elem = held };
        },
        else => return .{ .kind = jsonKind(value) },
    }
}

/// The one shape that takes both: an unseen value yields, two RECORDs union
/// their members, two REPEATEDs merge their elements, and two scalars widen
/// the way CSV detection widens. Shapes no single column holds — an object
/// against a scalar, an array against a non-array, an array of arrays, which
/// BigQuery has no column for — fall back to STRING, and the values are left
/// to the write path's checks, as a mismatched CSV cell is.
fn mergeShapes(
    arena: std.mem.Allocator,
    a: JsonShape,
    b: JsonShape,
) std.mem.Allocator.Error!JsonShape {
    if (isUnknownShape(a)) return b;
    if (isUnknownShape(b)) return a;
    if (a.repeated and b.repeated) {
        const elem = try arena.create(JsonShape);
        elem.* = try mergeShapes(arena, a.elem.?.*, b.elem.?.*);
        return .{ .repeated = true, .elem = elem };
    }
    if (a.record and b.record) {
        var fields: std.ArrayList(SeenField) = .empty;
        try fields.appendSlice(arena, a.fields);
        for (b.fields) |bf| {
            var merged = false;
            for (fields.items) |*af| {
                if (!std.mem.eql(u8, af.name, bf.name)) continue;
                af.shape = try mergeShapes(arena, af.shape, bf.shape);
                merged = true;
                break;
            }
            if (!merged) try fields.append(arena, bf);
        }
        return .{ .record = true, .fields = fields.items };
    }
    if (!a.record and !a.repeated and !b.record and !b.repeated) {
        return .{ .kind = autodetect.merge(a.kind, b.kind) };
    }
    return .{ .kind = .string };
}

fn isUnknownShape(shape: JsonShape) bool {
    return !shape.record and !shape.repeated and shape.kind == .unknown;
}

fn shapeColumn(
    arena: std.mem.Allocator,
    name: []const u8,
    shape: JsonShape,
) std.mem.Allocator.Error!Column {
    if (shape.repeated) {
        const elem = shape.elem.?.*;
        if (elem.repeated) return .{ .name = name, .type_name = "STRING" };
        if (elem.record) {
            return .{
                .name = name,
                .type_name = "RECORD",
                .mode = "REPEATED",
                .fields = try shapeFieldNodes(arena, elem.fields),
            };
        }
        return .{
            .name = name,
            .type_name = elem.kind.legacyTypeName(),
            .mode = "REPEATED",
        };
    }
    if (shape.record) {
        return .{
            .name = name,
            .type_name = "RECORD",
            .fields = try shapeFieldNodes(arena, shape.fields),
        };
    }
    return .{ .name = name, .type_name = shape.kind.legacyTypeName() };
}

fn shapeFieldNodes(
    arena: std.mem.Allocator,
    fields: []const SeenField,
) std.mem.Allocator.Error![]const std.json.Value {
    const out = try arena.alloc(std.json.Value, fields.len);
    for (fields, out) |field, *node| {
        node.* = try columnNode(arena, try shapeColumn(arena, field.name, field.shape));
    }
    return out;
}

fn jsonKind(value: std.json.Value) autodetect.Kind {
    return switch (value) {
        .null => .unknown,
        .bool => .boolean,
        .integer, .number_string => .integer,
        .float => .float,
        // A string is read for a date or a number the way a CSV cell is. schema-detect
        .string => |text| autodetect.inferValue(text),
        else => .string,
    };
}

const testing = std.testing;

fn readFrom(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
) !Reading {
    return read(arena, media, spec, null);
}

/// Every row the batcher yields, gathered so a test can look at them all at once. A deep copy,
/// because the batcher reuses its objects between batches.
const Collected = struct {
    rows: []const std.json.Value,
    bad_records: u64,
};

fn collect(
    arena: std.mem.Allocator,
    reading: Reading,
    spec: load_handler.LoadSpec,
) !Collected {
    var batcher = try Batcher.init(arena, reading, spec);
    var out = std.json.Array.init(arena);
    while (try batcher.next()) |batch| {
        for (batch) |row| try out.append(.{ .object = try row.object.clone(arena) });
    }
    return .{ .rows = out.items, .bad_records = reading.bad_records + batcher.bad_records };
}

fn columnTypes(arena: std.mem.Allocator, reading: Reading) ![]const []const u8 {
    const fields = reading.schema_fields;
    const out = try arena.alloc([]const u8, fields.len);
    for (fields, out) |field, *dst| dst.* = field.object.get("type").?.string;
    return out;
}

test "a detected CSV yields its columns and rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const reading = try readFrom(arena, "name,age\nAlice,30\nBob,25\n", spec);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "STRING", "INTEGER" }),
        try columnTypes(arena, reading),
    );
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(usize, 2), got.rows.len);
    try testing.expectEqualStrings("Alice", got.rows[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), got.rows[0].object.get("age").?.integer);
}

test "an empty cell is null, a quoted empty cell is a string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const reading = try readFrom(arena, "a,b\nx,\ny,\"\"\n", spec);
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(std.json.Value.null, got.rows[0].object.get("b").?);
    try testing.expectEqualStrings("", got.rows[1].object.get("b").?.string);
}

test "a short row is bad unless the job allows jagged rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const strict_spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const strict = try readFrom(arena, "a,b\n1,2\n3\n", strict_spec);
    const strict_rows = try collect(arena, strict, strict_spec);
    try testing.expectEqual(@as(u64, 1), strict_rows.bad_records);
    try testing.expectEqual(@as(usize, 1), strict_rows.rows.len);

    const lenient_spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
        .allow_jagged_rows = true,
    };
    const lenient = try readFrom(arena, "a,b\n1,2\n3\n", lenient_spec);
    const lenient_rows = try collect(arena, lenient, lenient_spec);
    try testing.expectEqual(@as(u64, 0), lenient_rows.bad_records);
    try testing.expectEqual(@as(usize, 2), lenient_rows.rows.len);
}

test "a value that does not fit its column is a bad record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var int_field = pb.TableFieldSchema{ .name = "a", .type = "INTEGER" };
    var fields = [_]*pb.TableFieldSchema{&int_field};
    const schema = pb.TableSchema{ .fields = &fields };

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .schema = &schema,
        .skip_leading_rows = 0,
    };
    const reading = try readFrom(arena, "1\nnot a number\n3\n", spec);
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(u64, 1), got.bad_records);
    try testing.expectEqual(@as(usize, 2), got.rows.len);
}

test "newline-delimited JSON takes its columns from the values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reading = try readFrom(arena,
        \\{"name":"Alice","id":12}
        \\{"name":"Bob","id":13}
        \\
    , .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .autodetect = true,
    });
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "STRING", "INTEGER" }),
        try columnTypes(arena, reading),
    );
    try testing.expectEqual(@as(usize, 2), reading.rowCount());
}

test "a declared RECORD schema reaches the reading with its mode and members" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var n_field = pb.TableFieldSchema{ .name = "n", .type = "INTEGER" };
    var ts_field = pb.TableFieldSchema{ .name = "ts", .type = "TIMESTAMP" };
    var members = [_]*pb.TableFieldSchema{ &n_field, &ts_field };
    var entries_field = pb.TableFieldSchema{
        .name = "entries",
        .type = "RECORD",
        .mode = "REPEATED",
        .fields = &members,
    };
    var id_field = pb.TableFieldSchema{ .name = "id", .type = "INTEGER" };
    var fields = [_]*pb.TableFieldSchema{ &id_field, &entries_field };
    const schema = pb.TableSchema{ .fields = &fields };

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .schema = &schema,
    };
    const reading = try readFrom(arena, "{\"id\":1}\n", spec);
    const entries = reading.schema_fields[1];
    try testing.expectEqualStrings("RECORD", entries.object.get("type").?.string);
    try testing.expectEqualStrings("REPEATED", entries.object.get("mode").?.string);
    const subs = entries.object.get("fields").?.array.items;
    try testing.expectEqual(@as(usize, 2), subs.len);
    try testing.expectEqualStrings("ts", subs[1].object.get("name").?.string);
}

/// The shape of #119's table: an INTEGER, a REPEATED RECORD, and a RECORD
/// holding a REPEATED member of its own.
fn nestedSchema(arena: std.mem.Allocator) !*const pb.TableSchema {
    const n = try arena.create(pb.TableFieldSchema);
    n.* = .{ .name = "n", .type = "INTEGER" };
    const ts = try arena.create(pb.TableFieldSchema);
    ts.* = .{ .name = "ts", .type = "TIMESTAMP" };
    const entries = try arena.create(pb.TableFieldSchema);
    entries.* = .{
        .name = "entries",
        .type = "RECORD",
        .mode = "REPEATED",
        .fields = try arena.dupe(*pb.TableFieldSchema, &.{ n, ts }),
    };
    const city = try arena.create(pb.TableFieldSchema);
    city.* = .{ .name = "city", .type = "STRING" };
    const aliases = try arena.create(pb.TableFieldSchema);
    aliases.* = .{ .name = "aliases", .type = "STRING", .mode = "REPEATED" };
    const profile = try arena.create(pb.TableFieldSchema);
    profile.* = .{
        .name = "profile",
        .type = "RECORD",
        .fields = try arena.dupe(*pb.TableFieldSchema, &.{ city, aliases }),
    };
    const id = try arena.create(pb.TableFieldSchema);
    id.* = .{ .name = "id", .type = "INTEGER" };
    const schema = try arena.create(pb.TableSchema);
    schema.* = .{
        .fields = try arena.dupe(*pb.TableFieldSchema, &.{ id, entries, profile }),
    };
    return schema;
}

test "nested values land as they were written, with BigQuery's null rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .schema = try nestedSchema(arena),
    };
    const reading = try readFrom(arena,
        \\{"id":1,"entries":[{"n":1,"ts":"2026-01-15T00:00:00Z"},{"n":2,"ts":"2026-01-16T00:00:00Z"}],"profile":{"city":"SF"}}
        \\{"id":2,"entries":[]}
        \\{"id":3,"entries":null,"profile":null}
        \\
    , spec);
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(u64, 0), got.bad_records);
    try testing.expectEqual(@as(usize, 3), got.rows.len);

    const first = got.rows[0];
    const entries = first.object.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(i64, 1), entries[0].object.get("n").?.integer);
    try testing.expectEqualStrings(
        "2026-01-16T00:00:00Z",
        entries[1].object.get("ts").?.string,
    );
    const profile = first.object.get("profile").?.object;
    try testing.expectEqualStrings("SF", profile.get("city").?.string);
    // A REPEATED member the object omits is an empty array, not a NULL.
    try testing.expectEqual(
        @as(usize, 0),
        profile.get("aliases").?.array.items.len,
    );

    // An empty array stays empty; a null REPEATED reads as one too, and a
    // null or absent RECORD stays null.
    try testing.expectEqual(
        @as(usize, 0),
        got.rows[1].object.get("entries").?.array.items.len,
    );
    try testing.expectEqual(
        std.json.Value.null,
        got.rows[1].object.get("profile") orelse .null,
    );
    try testing.expectEqual(
        @as(usize, 0),
        got.rows[2].object.get("entries").?.array.items.len,
    );
    try testing.expectEqual(
        std.json.Value.null,
        got.rows[2].object.get("profile").?,
    );
}

test "autodetect types a nested object as RECORD and an array as REPEATED" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .autodetect = true,
    };
    const reading = try readFrom(arena,
        \\{"id":1,"entries":[{"n":1}],"tags":["a","b"]}
        \\{"id":2,"entries":[],"tags":[]}
        \\
    , spec);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "INTEGER", "RECORD", "STRING" }),
        try columnTypes(arena, reading),
    );
    const entries = reading.schema_fields[1];
    try testing.expectEqualStrings("REPEATED", entries.object.get("mode").?.string);
    const member = entries.object.get("fields").?.array.items[0];
    try testing.expectEqualStrings("n", member.object.get("name").?.string);
    try testing.expectEqualStrings("INTEGER", member.object.get("type").?.string);
    try testing.expectEqualStrings(
        "REPEATED",
        reading.schema_fields[2].object.get("mode").?.string,
    );

    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(usize, 2), got.rows.len);
    try testing.expectEqual(
        @as(usize, 0),
        got.rows[1].object.get("entries").?.array.items.len,
    );
}

test "a load that names no schema at all cannot proceed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NoSchema, readFrom(arena, "1,2\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
    }));
}

test "several sources each skip their own header and take the first one's columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec: load_handler.LoadSpec = .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
        .skip_leading_rows = 1,
    };
    const reading = try readMany(arena, &.{
        "person_id,district\n1,NORTH\n",
        "person_id,district\n2,SOUTH\n3,EAST",
        "person_id,district\n4,WEST\n",
    }, spec, null);
    const collected = try collect(arena, reading, spec);
    try testing.expectEqual(@as(usize, 4), collected.rows.len);
    try testing.expectEqual(@as(u64, 0), collected.bad_records);
    try testing.expectEqualStrings("SOUTH", collected.rows[1].object.get("district").?.string);
    try testing.expectEqualStrings("EAST", collected.rows[2].object.get("district").?.string);
    try testing.expectEqual(@as(i64, 4), collected.rows[3].object.get("person_id").?.integer);
}

test "bad records count across every source of a load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec: load_handler.LoadSpec = .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .autodetect = true,
    };
    const reading = try readMany(arena, &.{
        "{\"n\":1}\nnot json\n",
        "{\"n\":2}\n{oops\n",
    }, spec, null);
    try testing.expectEqual(@as(usize, 2), reading.rowCount());
    try testing.expectEqual(@as(u64, 2), reading.bad_records);
}

test "an empty shard and a header-only shard do not unsettle an autodetected load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec: load_handler.LoadSpec = .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const reading = try readMany(arena, &.{
        "",
        "person_id,district\n1,NORTH\n2,SOUTH\n",
        "person_id,district\n",
        "person_id,district\n3,EAST\n",
    }, spec, null);
    const collected = try collect(arena, reading, spec);
    try testing.expectEqual(@as(u64, 0), collected.bad_records);
    try testing.expectEqual(@as(usize, 3), collected.rows.len);
    try testing.expectEqualStrings("INTEGER", (try columnTypes(arena, reading))[0]);
    try testing.expectEqual(@as(i64, 3), collected.rows[2].object.get("person_id").?.integer);
}

test "every read error has a message of its own" {
    const names = @typeInfo(Error).error_set.error_names.?;
    inline for (names, 0..) |a, i| {
        const message = readErrorMessage(@field(Error, a));
        try testing.expect(message.len > 0);
        inline for (names[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, message, readErrorMessage(@field(Error, b))));
        }
    }
}
