//! The REST routes, replacing bigquery-emulator's gorilla/mux table (server.go).
//!
//! Every route is registered twice, at `/` and under `/bigquery/v2`, as Go does
//! (server.go:92-97). A handler keeps the shape `fn (s, req, ids...) !http_server.Response`:
//! `bind` passes the pattern's named params to it in pattern order and times it under the
//! route's Id for /debug/stats. A request no route matches gets `Server.unexpectedPath`.
//!
//! Param names are this table's own, one spelling per id. The discovery document spells the
//! same path variable two ways (`{projectId}` and `{projectsId}`; handler_gen.go:14 and :79),
//! which is why Go carries six `xIDFromParams` helpers that try both
//! (server/middleware.go:115-167).

const std = @import("std");
const dusty = @import("dusty");
const http_server = @import("http/server.zig");
const Server = @import("server.zig").Server;

/// Which route a request matched: the name /debug/stats reports its timing under.
pub const Id = enum {
    discovery,
    jobs_query,
    jobs_get_query_results,
    jobs_insert,
    /// A load job's configuration and its bytes, together.
    upload_jobs_insert,
    /// A resumable session's bytes, or a query for how many of them landed.
    upload_jobs_resume,
    jobs_get,
    jobs_list,
    datasets_insert,
    datasets_list,
    datasets_get,
    datasets_delete,
    datasets_patch,
    tables_insert,
    tables_list,
    tables_get,
    tables_delete,
    tables_patch,
    tabledata_insert_all,
    tabledata_list,
    debug_stats,
};

/// The value-returning form of a route, with the request's path params.
pub const Call = *const fn (
    s: *Server,
    req: *const http_server.Request,
    params: *const dusty.Params,
) anyerror!http_server.Response;

pub const Entry = struct {
    method: std.http.Method,
    /// dusty syntax: `:name` binds one segment.
    pattern: []const u8,
    id: Id,
    call: Call,
};

const project = "/projects/:project";
const datasets = project ++ "/datasets";
const dataset = datasets ++ "/:dataset";
const tables = dataset ++ "/tables";
const one_table = tables ++ "/:table";
const queries = project ++ "/queries";
const jobs = project ++ "/jobs";
const upload_jobs = "/upload/bigquery/v2" ++ jobs;

pub const table = [_]Entry{
    route(.GET, "/discovery/v1/apis/bigquery/v2/rest", .discovery, Server.handleDiscovery),
    route(.GET, "/$discovery/rest", .discovery, Server.handleDiscovery),
    // Not part of the BigQuery API: per-route timing for this process.
    route(.GET, "/debug/stats", .debug_stats, Server.handleDebugStats),

    route(.POST, datasets, .datasets_insert, Server.handleDatasetsInsert),
    route(.GET, datasets, .datasets_list, Server.handleDatasetsList),
    route(.GET, dataset, .datasets_get, Server.handleDatasetsGet),
    route(.DELETE, dataset, .datasets_delete, Server.handleDatasetsDelete),
    route(.PATCH, dataset, .datasets_patch, Server.handleDatasetsPatch),

    route(.POST, tables, .tables_insert, Server.handleTablesInsert),
    route(.GET, tables, .tables_list, Server.handleTablesList),
    route(.GET, one_table, .tables_get, Server.handleTablesGet),
    route(.PATCH, one_table, .tables_patch, Server.handleTablesPatch),
    route(.DELETE, one_table, .tables_delete, Server.handleTablesDelete),
    route(.GET, one_table ++ "/data", .tabledata_list, Server.handleTabledataList),
    route(.POST, one_table ++ "/insertAll", .tabledata_insert_all, Server.handleTabledataInsertAll),

    route(.POST, queries, .jobs_query, Server.handleQuery),
    route(.GET, queries ++ "/:job", .jobs_get_query_results, Server.handleGetQueryResults),
    route(.POST, jobs, .jobs_insert, Server.handleJobsInsert),
    route(.GET, jobs, .jobs_list, Server.handleJobsList),
    route(.GET, jobs ++ "/:job", .jobs_get, Server.handleJobsGet),

    // The media upload endpoint. The discovery document gives the resumable protocol its own
    // `/resumable` prefix while the prose uses `/upload` with `uploadType=resumable`, so both
    // spellings reach the same handlers. api-uploads
    route(.POST, upload_jobs, .upload_jobs_insert, Server.handleUploadInsert),
    route(.PUT, upload_jobs, .upload_jobs_resume, Server.handleUploadResume),
    route(.POST, "/resumable" ++ upload_jobs, .upload_jobs_insert, Server.handleUploadInsert),
    route(.PUT, "/resumable" ++ upload_jobs, .upload_jobs_resume, Server.handleUploadResume),
};

/// Every entry of `table` under each prefix it is registered at, path included.
const registered = blk: {
    @setEvalBranchQuota(20_000);
    const prefixes = [_][]const u8{ "", "/bigquery/v2" };
    var out: [prefixes.len * table.len]struct { path: []const u8, entry: Entry } = undefined;
    for (prefixes, 0..) |prefix, p| {
        for (table, 0..) |e, i| {
            out[p * table.len + i] = .{ .path = prefix ++ e.pattern, .entry = e };
        }
    }
    break :blk out;
};

/// Registers every route in `table`, for `http_server.Options.routes`.
pub fn register(router: *dusty.Router(http_server.App)) void {
    inline for (registered) |r| add(router, r.entry.method, r.path, r.entry.call);
}

/// The entry registered at `path` for `method`, which dusty matched a request to.
fn entryAt(path: []const u8, method: std.http.Method) Entry {
    for (registered) |r| {
        const answers = r.entry.method == method or (r.entry.method == .GET and method == .HEAD);
        if (answers and std.mem.eql(u8, r.path, path)) return r.entry;
    }
    unreachable;
}

/// Matches `method path` against `table` as the server does. Null when nothing matches.
fn match(
    arena: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    out: *dusty.Request,
) !?Entry {
    var router = dusty.Router(http_server.App).init(arena);
    register(&router);
    out.* = .{
        .method = http_server.dustyMethod(method),
        .url = path,
        .arena = arena,
        .parser = undefined,
        .transport = undefined,
    };
    try out.splitTarget();
    _ = try router.findHandler(out) orelse return null;
    return entryAt(out.route.?.path, method);
}

fn add(
    router: *dusty.Router(http_server.App),
    comptime method: std.http.Method,
    comptime path: []const u8,
    comptime call: Call,
) void {
    const action = actionFor(call);
    switch (method) {
        .GET => router.get(path, action),
        .POST => router.post(path, action),
        .PUT => router.put(path, action),
        .PATCH => router.patch(path, action),
        .DELETE => router.delete(path, action),
        else => @compileError("no BigQuery route uses " ++ @tagName(method)),
    }
}

/// The dusty handler for `call`: builds the Request, runs the call, writes the Response.
fn actionFor(comptime call: Call) fn (
    *http_server.App,
    *dusty.Request,
    *dusty.Response,
    *const http_server.App.RequestContext,
) anyerror!void {
    return struct {
        fn action(
            app: *http_server.App,
            req: *dusty.Request,
            res: *dusty.Response,
            ctx: *const http_server.App.RequestContext,
        ) anyerror!void {
            const s: *Server = @ptrCast(@alignCast(app.handler.ctx));
            // Every method a route is registered for, and HEAD, which dusty answers with the
            // GET route, has a methodFrom mapping.
            const r = (try http_server.requestFrom(req, ctx)).?;
            try http_server.respond(res, try call(s, &r, &req.params));
        }
    }.action;
}

fn route(
    comptime method: std.http.Method,
    comptime pattern: []const u8,
    comptime id: Id,
    comptime handler: anytype,
) Entry {
    return .{ .method = method, .pattern = pattern, .id = id, .call = bind(pattern, id, handler) };
}

/// Adapts `handler` to Call. Its parameters after `s` and `req` take the pattern's params in
/// pattern order; a count that does not match is a compile error.
fn bind(comptime pattern: []const u8, comptime id: Id, comptime handler: anytype) Call {
    const names = comptime paramNames(pattern);
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    // Zig 0.17 replaced `params` with `param_types`.
    const arity = if (@hasField(@TypeOf(info), "params")) info.params.len else info.param_types.len;
    if (arity != names.len + 2) {
        @compileError(std.fmt.comptimePrint(
            "{s} takes {d} ids, but {s} binds {d}",
            .{ @tagName(id), arity - 2, pattern, names.len },
        ));
    }
    return struct {
        fn call(
            s: *Server,
            req: *const http_server.Request,
            params: *const dusty.Params,
        ) anyerror!http_server.Response {
            const t0 = Server.routeClock();
            defer s.recordRoute(id, t0);
            var ids: [names.len][]const u8 = undefined;
            inline for (names, &ids) |name, *slot| slot.* = params.get(name).?;
            return switch (names.len) {
                0 => handler(s, req),
                1 => handler(s, req, ids[0]),
                2 => handler(s, req, ids[0], ids[1]),
                3 => handler(s, req, ids[0], ids[1], ids[2]),
                else => @compileError(pattern ++ " binds more ids than any BigQuery route"),
            };
        }
    }.call;
}

/// The `:name` segments of `pattern`, in order. Called at comptime.
fn paramNames(pattern: []const u8) []const []const u8 {
    @setEvalBranchQuota(20_000);
    var names: []const []const u8 = &.{};
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    while (it.next()) |segment| {
        if (segment[0] == ':') names = names ++ .{segment[1..]};
    }
    return names;
}

/// Runs `req` through the routes in `table` the way the server matches them, without a socket.
/// Null when no route matches.
pub fn callMatching(s: *Server, req: *const http_server.Request) !?http_server.Response {
    // dusty's Request points its params into itself, so it stays here while the call runs.
    var dreq: dusty.Request = undefined;
    const e = try match(req.arena, req.method, req.path, &dreq) orelse return null;
    return try e.call(s, req, &dreq.params);
}

const testing = std.testing;

/// The id of the route `method path` matches, or null.
fn matchedId(arena: std.mem.Allocator, method: std.http.Method, path: []const u8) !?Id {
    var dreq: dusty.Request = undefined;
    const e = try match(arena, method, path, &dreq) orelse return null;
    return e.id;
}

test "every route matches its own pattern, at / and under /bigquery/v2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (table) |e| {
        try testing.expectEqual(e.id, (try matchedId(arena, e.method, e.pattern)).?);
        const prefixed = try std.fmt.allocPrint(arena, "/bigquery/v2{s}", .{e.pattern});
        try testing.expectEqual(e.id, (try matchedId(arena, e.method, prefixed)).?);
    }
}

test "a trailing slash and an empty segment match the route" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(Id.debug_stats, (try matchedId(arena, .GET, "/debug/stats/")).?);
    try testing.expectEqual(Id.debug_stats, (try matchedId(arena, .GET, "/debug//stats")).?);
}

test "HEAD is answered by the GET route" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(
        Id.discovery,
        (try matchedId(arena, .HEAD, "/discovery/v1/apis/bigquery/v2/rest")).?,
    );
}

test "a method a path has no route for, or an unknown path, matches nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(?Id, null), try matchedId(arena, .POST, "/debug/stats"));
    try testing.expectEqual(@as(?Id, null), try matchedId(arena, .GET, "/no/such/path"));
}

test "insertAll and data sit under the table path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(
        Id.tabledata_insert_all,
        (try matchedId(arena, .POST, "/projects/p/datasets/ds/tables/t/insertAll")).?,
    );
    try testing.expectEqual(
        Id.tabledata_list,
        (try matchedId(arena, .GET, "/projects/p/datasets/ds/tables/t/data")).?,
    );
}

test "a table literally named insertAll is a table GET" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(
        Id.tables_get,
        (try matchedId(arena_state.allocator(), .GET, "/projects/p/datasets/ds/tables/insertAll")).?,
    );
}

test "params bind by name and arrive percent-decoded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var dreq: dusty.Request = undefined;
    // BigQuery decodes path ids: tables/t%5Fx answers for table t_x.
    const e = (try match(arena_state.allocator(), .GET, "/projects/p/datasets/d/tables/t%5Fx", &dreq)).?;
    try testing.expectEqual(Id.tables_get, e.id);
    try testing.expectEqualStrings("p", dreq.params.get("project").?);
    try testing.expectEqualStrings("d", dreq.params.get("dataset").?);
    try testing.expectEqualStrings("t_x", dreq.params.get("table").?);
}

test "the same path under different methods is different routes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(Id.jobs_insert, (try matchedId(arena, .POST, "/projects/p/jobs")).?);
    try testing.expectEqual(Id.jobs_list, (try matchedId(arena, .GET, "/projects/p/jobs")).?);
}

test "a missing id or an extra segment matches nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(?Id, null), try matchedId(arena, .DELETE, "/projects/p/queries"));
    try testing.expectEqual(@as(?Id, null), try matchedId(arena, .POST, "/projects//queries"));
    try testing.expectEqual(@as(?Id, null), try matchedId(arena, .POST, "/projects/p"));
    try testing.expectEqual(
        @as(?Id, null),
        try matchedId(arena, .GET, "/projects/p/queries/job/extra"),
    );
}

test "paramNames lists the bound segments in order" {
    const names = comptime paramNames("/projects/:project/datasets/:dataset/tables/:table");
    try testing.expectEqual(3, names.len);
    try testing.expectEqualStrings("project", names[0]);
    try testing.expectEqualStrings("dataset", names[1]);
    try testing.expectEqualStrings("table", names[2]);
}
