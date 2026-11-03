//! Replaces bigquery-emulator's use of gorilla/mux — REDESIGNED, not ported.
//!
//! Differences from Go, by design:
//! - Captures bind **positionally**, not by name. The BigQuery discovery
//!   document names the same path variable inconsistently — some routes use
//!   `{projectId}/{datasetId}/{tableId}`, others `{projectsId}/{datasetsId}/
//!   {tablesId}` (compare handler_gen.go:14 with :79) — which forces Go to
//!   carry six near-identical `xIDFromParams` helpers
//!   (server/middleware.go:115-167) that try both spellings. Matching on
//!   position makes the spelling irrelevant and those helpers unnecessary.
//! - Every route is registered under both `/` and `/bigquery/v2`, matching
//!   server.go:92-97.
// ephor:ignore-file ZA302

const std = @import("std");
const http = std.http;

/// Path variables captured left to right. Four is the deepest the BigQuery
/// REST surface goes (project/dataset/table/row-policy).
pub const max_captures = 4;

pub const Captures = struct {
    items: [max_captures][]const u8 = @splat(""),
    len: usize = 0,

    pub fn get(c: *const Captures, i: usize) []const u8 {
        return if (i < c.len) c.items[i] else "";
    }
};

pub const Match = struct {
    route: Route.Id,
    captures: Captures,
};

pub const Route = struct {
    /// Stable identity for a (method, pattern) pair. Handlers switch on this.
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

    id: Id,
    method: http.Method,
    /// `*` marks a capture segment; every other segment matches literally.
    pattern: []const u8,
};

/// The implemented surface.
pub const routes = [_]Route{

    // The media upload endpoint. The discovery document gives the resumable protocol its own
    // `/resumable` prefix while the prose uses `/upload` with `uploadType=resumable`, so both
    // spellings reach the same handlers. api-uploads
    .{
        .id = .upload_jobs_insert,
        .method = .POST,
        .pattern = "/upload/bigquery/v2/projects/*/jobs",
    },
    .{
        .id = .upload_jobs_resume,
        .method = .PUT,
        .pattern = "/upload/bigquery/v2/projects/*/jobs",
    },
    .{
        .id = .upload_jobs_insert,
        .method = .POST,
        .pattern = "/resumable/upload/bigquery/v2/projects/*/jobs",
    },
    .{
        .id = .upload_jobs_resume,
        .method = .PUT,
        .pattern = "/resumable/upload/bigquery/v2/projects/*/jobs",
    },



};

/// Go registers every handler twice: bare, and under `/bigquery/v2`
/// (server.go:92-97). Clients configured with an `api_endpoint` use the
/// prefixed form.
const api_prefix = "/bigquery/v2";

pub const Outcome = union(enum) {
    matched: Match,
    /// Path matched some route but not with this method.
    method_not_allowed,
    not_found,
};

pub fn match(method: http.Method, path: []const u8) Outcome {
    const p = if (std.mem.startsWith(u8, path, api_prefix))
        path[api_prefix.len..]
    else
        path;

    var path_matched = false;
    for (routes) |route| {
        var captures: Captures = .{};
        if (!matchPattern(route.pattern, p, &captures)) continue;
        path_matched = true;
        if (route.method == method) return .{
            .matched = .{ .route = route.id, .captures = captures },
        };
    }
    return if (path_matched) .method_not_allowed else .not_found;
}

fn matchPattern(pattern: []const u8, path: []const u8, captures: *Captures) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pat = pat_it.next();
        const seg = path_it.next();
        if (pat == null and seg == null) return true;
        if (pat == null or seg == null) return false;

        if (pat.?.len == 1 and pat.?[0] == '*') {
            // A capture must not match an empty segment; `/projects//queries`
            // is not a valid project id.
            if (seg.?.len == 0) return false;
            if (captures.len >= max_captures) return false;
            captures.items[captures.len] = seg.?;
            captures.len += 1;
            continue;
        }
        if (!std.mem.eql(u8, pat.?, seg.?)) return false;
    }
}

const testing = std.testing;

test "all declared routes match their own patterns" {
    // Guards against a pattern that can never be reached.
    for (routes) |route| {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, route.pattern, '/');
        var first = true;
        while (it.next()) |seg| {
            if (first) {
                first = false;
                continue;
            }
            buf[len] = '/';
            len += 1;
            const concrete = if (seg.len == 1 and seg[0] == '*') "x" else seg;
            @memcpy(buf[len..][0..concrete.len], concrete);
            len += concrete.len;
        }
        const out = match(route.method, buf[0..len]);
        try testing.expect(out == .matched);
    }
}
