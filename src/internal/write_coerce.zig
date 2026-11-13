//! Coercing a NULL in a REPEATED column to an empty array on writes.
//!
//! BigQuery never stores a NULL array: a NULL `ARRAY` value written to a
//! table comes back as `[]`, and the same applies to an array nested inside
//! a `STRUCT` (issue #114). zigquery stores the NULL, so reads of the stored
//! column diverge: `ARRAY_LENGTH` returns NULL instead of `0`, and `IS NULL`
//! returns `true` instead of `false`.
//!
//! SQL writes (INSERT ... SELECT, INSERT ... VALUES, CREATE TABLE AS, and
//! the destination-table DDL a query job generates) run as translated SQLite
//! statements, so no Value-level hook sees the rows. The driver therefore
//! runs one fix-up UPDATE per affected column right after a successful
//! write, generated here from the destination table's `ColumnSpec` types.
//! Only columns whose type contains an ARRAY get a statement; everything
//! else is left untouched, and in-query NULL arrays are unaffected because
//! the fix-up only runs on statements that wrote rows to a table.
//!
//! The expressions use only functions the engine already registers:
//! `zigquery_make_array()` for the empty array, `zigquery_make_struct` /
//! `zigquery_get_struct_field` to rebuild a STRUCT field by field, and
//! `zigquery_unnest` + `zigquery_array_agg` (ordered by the unnest key, so
//! element order survives) to rebuild an ARRAY of STRUCTs. A NULL array
//! unnests to zero rows, so the rebuild's COALESCE turns both a NULL array
//! and an empty one into `[]`; a NULL STRUCT is left NULL, and a NULL
//! element of an ARRAY of STRUCTs stays a NULL element.

const std = @import("std");
const spec = @import("spec.zig");

/// True when a stored value of this type can carry a NULL array: the type
/// itself is an ARRAY, or a STRUCT with such a type anywhere below it.
pub fn needsCoercion(t: *const spec.Type) bool {
    if (t.isArray()) return true;
    if (t.isStruct()) {
        for (t.field_types) |field| {
            const ft = field.type orelse continue;
            if (needsCoercion(ft)) return true;
        }
    }
    return false;
}

/// The fix-up UPDATEs for one table, or empty when no column needs one.
/// `table_name` is the table's canonical dotted name (`p.d.t`, or the bare
/// name for a TEMP table); it is quoted as one identifier, the way the
/// engine's own INSERT rendering quotes it.
pub fn fixupStatements(
    alloc: std.mem.Allocator,
    table_name: []const u8,
    columns: []const *spec.ColumnSpec,
) std.mem.Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const table = try sqlIdent(alloc, table_name);
    for (columns) |col| {
        if (!needsCoercion(col.type)) continue;
        try out.append(alloc, try fixupForColumn(alloc, table, col));
    }
    return out.toOwnedSlice(alloc);
}

fn fixupForColumn(
    alloc: std.mem.Allocator,
    table: []const u8,
    col: *const spec.ColumnSpec,
) std.mem.Allocator.Error![]const u8 {
    const col_ref = try sqlIdent(alloc, col.name);
    const t = col.type;
    // A plain ARRAY column only needs its NULL rows fixed; the value
    // itself is already right for every non-NULL row.
    if (t.isArray()) {
        const elem = t.element_type orelse return try std.fmt.allocPrint(
            alloc,
            "UPDATE {s} SET {s} = zigquery_make_array() WHERE {s} IS NULL",
            .{ table, col_ref, col_ref },
        );
        if (!needsCoercion(elem)) {
            return try std.fmt.allocPrint(
                alloc,
                "UPDATE {s} SET {s} = zigquery_make_array() WHERE {s} IS NULL",
                .{ table, col_ref, col_ref },
            );
        }
    }
    var aliases: usize = 0;
    const expr = try coerceValueExpr(alloc, col_ref, t, &aliases);
    // A NULL STRUCT stays NULL, so its rows need no rewrite; an ARRAY
    // column's NULL rows become [] through the rebuild's COALESCE.
    if (t.isStruct()) {
        return try std.fmt.allocPrint(
            alloc,
            "UPDATE {s} SET {s} = {s} WHERE {s} IS NOT NULL",
            .{ table, col_ref, expr, col_ref },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "UPDATE {s} SET {s} = {s}",
        .{ table, col_ref, expr },
    );
}

/// The SQL expression for `expr` (a column reference or a value already in
/// SQL form) with every NULL array at or below `t` replaced by `[]`.
/// `aliases` hands out the unnest aliases so nested array rebuilds never
/// collide. Scalars pass through unchanged.
fn coerceValueExpr(
    alloc: std.mem.Allocator,
    expr: []const u8,
    t: *const spec.Type,
    aliases: *usize,
) std.mem.Allocator.Error![]const u8 {
    if (t.isArray()) {
        const elem = t.element_type orelse return try alloc.dupe(u8, expr);
        if (!needsCoercion(elem)) {
            return try std.fmt.allocPrint(
                alloc,
                "CASE WHEN {s} IS NULL THEN zigquery_make_array() ELSE {s} END",
                .{ expr, expr },
            );
        }
        // The elements themselves need coercion: rebuild the array from
        // its unnested elements, ordered by offset so order survives.
        const alias = try std.fmt.allocPrint(alloc, "w{d}", .{aliases.*});
        aliases.* += 1;
        const value_ref = try std.fmt.allocPrint(alloc, "`{s}`.`value`", .{alias});
        const key_ref = try std.fmt.allocPrint(alloc, "`{s}`.`key`", .{alias});
        const elem_expr = try coerceElementExpr(alloc, value_ref, elem, aliases);
        return try std.fmt.allocPrint(
            alloc,
            "COALESCE((SELECT zigquery_array_agg({s}, zigquery_order_by({s}, 1)) FROM zigquery_unnest({s}) AS `{s}`), zigquery_make_array())",
            .{ elem_expr, key_ref, expr, alias },
        );
    }
    if (t.isStruct()) {
        var parts: std.ArrayList([]const u8) = .empty;
        for (t.field_types, 0..) |field, i| {
            const ft = field.type orelse continue;
            const name = try sqlString(alloc, field.name);
            const member = try std.fmt.allocPrint(
                alloc,
                "zigquery_get_struct_field({s}, {d})",
                .{ expr, i },
            );
            const value = try coerceValueExpr(alloc, member, ft, aliases);
            try parts.append(alloc, try std.fmt.allocPrint(alloc, "{s}, {s}", .{ name, value }));
        }
        const joined = try std.mem.join(alloc, ", ", parts.items);
        return try std.fmt.allocPrint(
            alloc,
            "CASE WHEN {s} IS NULL THEN NULL ELSE zigquery_make_struct({s}) END",
            .{ expr, joined },
        );
    }
    return try alloc.dupe(u8, expr);
}

/// The coerced form of one element of an ARRAY rebuild: a NULL element
/// stays a NULL element, anything else is coerced by its own type.
fn coerceElementExpr(
    alloc: std.mem.Allocator,
    value_ref: []const u8,
    elem: *const spec.Type,
    aliases: *usize,
) std.mem.Allocator.Error![]const u8 {
    if (elem.isStruct()) {
        const rebuilt = try coerceValueExpr(alloc, value_ref, elem, aliases);
        // coerceValueExpr on a STRUCT already guards NULL with its own
        // CASE, so the element form needs no second one.
        return rebuilt;
    }
    return try coerceValueExpr(alloc, value_ref, elem, aliases);
}

/// Backtick-quoted identifier; a backtick inside doubles, as SQLite reads it.
fn sqlIdent(alloc: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '`');
    for (name) |c| {
        if (c == '`') try out.append(alloc, '`');
        try out.append(alloc, c);
    }
    try out.append(alloc, '`');
    return out.toOwnedSlice(alloc);
}

/// Single-quoted string literal; a quote inside doubles.
fn sqlString(alloc: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.append(alloc, '\'');
        try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

fn scalarType() spec.Type {
    // The exact scalar kind is irrelevant here: only ARRAY and STRUCT are
    // ever inspected, so any other kind stands in for one.
    return .{ .kind = 0 };
}

fn arrayOf(elem: *spec.Type) spec.Type {
    return .{ .kind = 16, .element_type = elem };
}

fn structOf(fields: []const *spec.NameWithType) spec.Type {
    return .{ .kind = 17, .field_types = fields };
}

test "needsCoercion: scalars no, arrays yes, structs only when nested" {
    var scalar = scalarType();
    try testing.expect(!needsCoercion(&scalar));

    var arr = arrayOf(&scalar);
    try testing.expect(needsCoercion(&arr));

    var f_a = spec.NameWithType{ .name = "a", .type = &scalar };
    var fields = [_]*spec.NameWithType{&f_a};
    var plain_struct = structOf(&fields);
    try testing.expect(!needsCoercion(&plain_struct));

    var f_xs = spec.NameWithType{ .name = "xs", .type = &arr };
    var nested_fields = [_]*spec.NameWithType{&f_xs};
    var nested_struct = structOf(&nested_fields);
    try testing.expect(needsCoercion(&nested_struct));
}

test "fixupStatements skips clean tables and fixes a plain ARRAY column" {
    var scalar = scalarType();
    var arr = arrayOf(&scalar);
    var c_id = spec.ColumnSpec{ .name = "id", .type = &scalar };
    var c_xs = spec.ColumnSpec{ .name = "xs", .type = &arr };
    var cols = [_]*spec.ColumnSpec{ &c_id, &c_xs };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const stmts = try fixupStatements(arena_state.allocator(), "p.d.t", &cols);
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings(
        "UPDATE `p.d.t` SET `xs` = zigquery_make_array() WHERE `xs` IS NULL",
        stmts[0],
    );

    const clean = try fixupStatements(arena_state.allocator(), "p.d.t", cols[0..1]);
    try testing.expectEqual(@as(usize, 0), clean.len);
}

test "fixup for the issue repro: top-level array plus array inside a struct" {
    var scalar = scalarType();
    var arr = arrayOf(&scalar);
    var f_inner = spec.NameWithType{ .name = "inner_arr", .type = &arr };
    var inner = [_]*spec.NameWithType{&f_inner};
    var s = structOf(&inner);
    var c_arr = spec.ColumnSpec{ .name = "arr", .type = &arr };
    var c_s = spec.ColumnSpec{ .name = "s", .type = &s };
    var cols = [_]*spec.ColumnSpec{ &c_arr, &c_s };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const stmts = try fixupStatements(arena_state.allocator(), "p.d.t", &cols);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings(
        "UPDATE `p.d.t` SET `arr` = zigquery_make_array() WHERE `arr` IS NULL",
        stmts[0],
    );
    try testing.expectEqualStrings(
        "UPDATE `p.d.t` SET `s` = CASE WHEN `s` IS NULL THEN NULL ELSE zigquery_make_struct('inner_arr', CASE WHEN zigquery_get_struct_field(`s`, 0) IS NULL THEN zigquery_make_array() ELSE zigquery_get_struct_field(`s`, 0) END) END WHERE `s` IS NOT NULL",
        stmts[1],
    );
}

test "fixup rebuilds an ARRAY of STRUCTs through unnest, order kept" {
    var scalar = scalarType();
    var arr = arrayOf(&scalar);
    var f_exs = spec.NameWithType{ .name = "xs", .type = &arr };
    var elem_fields = [_]*spec.NameWithType{&f_exs};
    var elem = structOf(&elem_fields);
    var col_type = arrayOf(&elem);
    var c_items = spec.ColumnSpec{ .name = "items", .type = &col_type };
    var cols = [_]*spec.ColumnSpec{&c_items};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const stmts = try fixupStatements(arena_state.allocator(), "p.d.t", &cols);
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings(
        "UPDATE `p.d.t` SET `items` = COALESCE((SELECT zigquery_array_agg(CASE WHEN `w0`.`value` IS NULL THEN NULL ELSE zigquery_make_struct('xs', CASE WHEN zigquery_get_struct_field(`w0`.`value`, 0) IS NULL THEN zigquery_make_array() ELSE zigquery_get_struct_field(`w0`.`value`, 0) END) END, zigquery_order_by(`w0`.`key`, 1)) FROM zigquery_unnest(`items`) AS `w0`), zigquery_make_array())",
        stmts[0],
    );
}
