//! The Cloud Storage objects a load job reads from its gs:// sourceUris.
//!
//! The objects live in a Cloud Storage emulator such as fake-gcs-server, reached over plain
//! HTTP through the JSON API at the address STORAGE_EMULATOR_HOST names. There is no
//! authentication: real Cloud Storage is out of reach by design.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    NotFound,
    /// No connection, or one that broke before the answer arrived.
    Unreachable,
    TimedOut,
    /// The object is larger than the reader was allowed to take.
    TooLarge,
    /// An answer that is neither the object nor a not-found.
    BadResponse,
    /// The store has no way to perform the operation.
    Unsupported,
    OutOfMemory,
};

/// A bucket's objects. Load jobs get and list; extract jobs will put.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            object: Uri,
            limit: usize,
        ) Error![]const u8,
        list: *const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            bucket: []const u8,
            prefix: []const u8,
        ) Error![]const []const u8,
        put: *const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            object: Uri,
            bytes: []const u8,
        ) Error!void,
    };

    /// The object's bytes, or TooLarge when there are more than `limit` of them.
    pub fn get(s: Store, arena: std.mem.Allocator, object: Uri, limit: usize) Error![]const u8 {
        return s.vtable.get(s.ptr, arena, object, limit);
    }

    /// The names of the objects that start with `prefix`, in name order.
    pub fn list(
        s: Store,
        arena: std.mem.Allocator,
        bucket: []const u8,
        prefix: []const u8,
    ) Error![]const []const u8 {
        return s.vtable.list(s.ptr, arena, bucket, prefix);
    }

    pub fn put(s: Store, arena: std.mem.Allocator, object: Uri, bytes: []const u8) Error!void {
        return s.vtable.put(s.ptr, arena, object, bytes);
    }
};

/// `gs://bucket/object`. The object name may hold one `*`, which matches any run of characters,
/// `/` included. load-data-cloud-storage-csv#load-wildcards
pub const Uri = struct {
    bucket: []const u8,
    object: []const u8,

    pub fn parse(text: []const u8) ?Uri {
        const scheme = "gs://";
        if (!std.mem.startsWith(u8, text, scheme)) return null;
        const rest = text[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const uri: Uri = .{ .bucket = rest[0..slash], .object = rest[slash + 1 ..] };
        if (uri.bucket.len == 0 or uri.object.len == 0) return null;
        if (std.mem.indexOfScalar(u8, uri.bucket, '*') != null) return null;
        if (std.mem.count(u8, uri.object, "*") > 1) return null;
        return uri;
    }

    /// The text before and after the wildcard, or null when the name has none.
    pub fn wildcard(uri: Uri) ?struct { prefix: []const u8, suffix: []const u8 } {
        const star = std.mem.indexOfScalar(u8, uri.object, '*') orelse return null;
        return .{ .prefix = uri.object[0..star], .suffix = uri.object[star + 1 ..] };
    }
};

/// Where a Cloud Storage emulator listens, as a base URL: STORAGE_EMULATOR_HOST spells it
/// either `host:port` or `http://host:port`.
pub fn endpointFrom(arena: std.mem.Allocator, setting: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, setting, "/");
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return arena.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(arena, "http://{s}", .{trimmed});
}

/// A Cloud Storage emulator's JSON API, over HTTP. Every request has a deadline.
pub const HttpStore = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// A base URL, as endpointFrom gives it.
    endpoint: []const u8,
    timeout: Io.Duration = .fromSeconds(30),

    pub fn store(h: *HttpStore) Store {
        return .{ .ptr = h, .vtable = &.{ .get = get, .list = list, .put = put } };
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, object: Uri, limit: usize) Error![]const u8 {
        const h: *HttpStore = @ptrCast(@alignCast(ptr));
        var url: std.ArrayList(u8) = .empty;
        try url.print(arena, "{s}/storage/v1/b/", .{h.endpoint});
        try appendEscaped(arena, &url, object.bucket);
        try url.appendSlice(arena, "/o/");
        try appendEscaped(arena, &url, object.object);
        try url.appendSlice(arena, "?alt=media");

        const reply = try h.send(arena, url.items, limit);
        return switch (reply.status) {
            .ok => reply.body,
            .not_found => error.NotFound,
            else => error.BadResponse,
        };
    }

    /// Every page of objects.list for `prefix`. storage/docs/json_api/v1/objects/list
    fn list(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        bucket: []const u8,
        prefix: []const u8,
    ) Error![]const []const u8 {
        const h: *HttpStore = @ptrCast(@alignCast(ptr));
        var names: std.ArrayList([]const u8) = .empty;
        var page_token: ?[]const u8 = null;
        while (true) {
            var url: std.ArrayList(u8) = .empty;
            try url.print(arena, "{s}/storage/v1/b/", .{h.endpoint});
            try appendEscaped(arena, &url, bucket);
            try url.appendSlice(arena, "/o?prefix=");
            try appendEscaped(arena, &url, prefix);
            if (page_token) |token| {
                try url.appendSlice(arena, "&pageToken=");
                try appendEscaped(arena, &url, token);
            }

            const reply = try h.send(arena, url.items, list_page_limit);
            switch (reply.status) {
                .ok => {},
                .not_found => return error.NotFound,
                else => return error.BadResponse,
            }
            const page = std.json.parseFromSliceLeaky(ListPage, arena, reply.body, .{
                .ignore_unknown_fields = true,
            }) catch return error.BadResponse;
            for (page.items) |item| try names.append(arena, item.name);
            page_token = page.nextPageToken orelse break;
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        return names.items;
    }

    fn put(ptr: *anyopaque, arena: std.mem.Allocator, object: Uri, bytes: []const u8) Error!void {
        _ = .{ ptr, arena, object, bytes };
        return error.Unsupported;
    }

    const Reply = struct { status: std.http.Status, body: []const u8 };

    /// One GET, abandoned when `timeout` passes first. The request runs as its own task so the
    /// deadline covers connecting, waiting and reading alike.
    fn send(h: *HttpStore, arena: std.mem.Allocator, url: []const u8, limit: usize) Error!Reply {
        const Outcome = union(enum) {
            reply: Error!Reply,
            expired: Io.Cancelable!void,
        };
        var buffer: [2]Outcome = undefined;
        var select = Io.Select(Outcome).init(h.io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.reply, fetch, .{ h, arena, url, limit }) catch
            return fetch(h, arena, url, limit);
        select.async(.expired, Io.sleep, .{ h.io, h.timeout, .awake });
        const first = select.await() catch return error.TimedOut;
        return switch (first) {
            .reply => |reply| reply,
            .expired => error.TimedOut,
        };
    }

    fn fetch(h: *HttpStore, arena: std.mem.Allocator, url: []const u8, limit: usize) Error!Reply {
        var client: std.http.Client = .{ .allocator = h.gpa, .io = h.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return error.BadResponse;
        var request = client.request(.GET, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            // The bytes as stored, not a compressed transfer of them.
            .headers = .{ .accept_encoding = .omit },
        }) catch |err| return transportError(err);
        defer request.deinit();
        request.sendBodiless() catch |err| return transportError(err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(err);

        var transfer: [4096]u8 = undefined;
        const body = response.reader(&transfer).allocRemaining(arena, .limited(limit)) catch |err|
            switch (err) {
                error.StreamTooLong => return error.TooLarge,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unreachable,
            };
        return .{ .status = response.head.status, .body = body };
    }

    fn transportError(err: anyerror) Error {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unreachable;
    }
};

/// One objects.list response is a page of object resources; this cap only guards against an
/// answer that is not one.
const list_page_limit = 64 * 1024 * 1024;

const ListPage = struct {
    items: []const struct { name: []const u8 } = &.{},
    nextPageToken: ?[]const u8 = null,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Percent-encodes everything but RFC 3986's unreserved characters, so a `/` in an object
/// name stays inside its path segment.
fn appendEscaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (isUnreserved(c)) {
            try out.append(arena, c);
            continue;
        }
        try out.append(arena, '%');
        try out.append(arena, hex[c >> 4]);
        try out.append(arena, hex[c & 0xf]);
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Objects held in memory, for tests.
pub const MemoryStore = struct {
    arena: std.mem.Allocator,
    /// Keyed by `bucket/object`.
    objects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// When set, every operation fails with it.
    failure: ?Error = null,

    pub fn store(m: *MemoryStore) Store {
        return .{ .ptr = m, .vtable = &.{ .get = get, .list = list, .put = put } };
    }

    fn key(m: *MemoryStore, object: Uri) ![]const u8 {
        return std.fmt.allocPrint(m.arena, "{s}/{s}", .{ object.bucket, object.object });
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, object: Uri, limit: usize) Error![]const u8 {
        _ = arena;
        const m: *MemoryStore = @ptrCast(@alignCast(ptr));
        if (m.failure) |err| return err;
        const bytes = m.objects.get(try m.key(object)) orelse return error.NotFound;
        if (bytes.len > limit) return error.TooLarge;
        return bytes;
    }

    fn list(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        bucket: []const u8,
        prefix: []const u8,
    ) Error![]const []const u8 {
        const m: *MemoryStore = @ptrCast(@alignCast(ptr));
        if (m.failure) |err| return err;
        const start = try m.key(.{ .bucket = bucket, .object = prefix });
        var names: std.ArrayList([]const u8) = .empty;
        for (m.objects.keys()) |k| {
            if (std.mem.startsWith(u8, k, start)) try names.append(arena, k[bucket.len + 1 ..]);
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        return names.items;
    }

    fn put(ptr: *anyopaque, arena: std.mem.Allocator, object: Uri, bytes: []const u8) Error!void {
        _ = arena;
        const m: *MemoryStore = @ptrCast(@alignCast(ptr));
        if (m.failure) |err| return err;
        try m.objects.put(m.arena, try m.key(object), try m.arena.dupe(u8, bytes));
    }
};

/// Why a load could not read its sources, as the job's errorResult reports it.
pub const Failure = struct { reason: []const u8, message: []const u8 };

pub const Sources = union(enum) {
    /// Each object's bytes, in load order: the URIs in the order given, and a wildcard's
    /// matches in name order.
    read: []const []const u8,
    failed: Failure,
};

/// Where a load's sources are read from, and how much of them.
pub const Reader = struct {
    store: Store,
    /// The store's address, for the messages that name it.
    endpoint: []const u8,
    /// The most bytes read across every source of one load.
    limit: usize,
};

/// Reads every object `uris` names, gs:// URIs that Uri.parse accepts.
pub fn readSources(
    arena: std.mem.Allocator,
    reader: Reader,
    uris: []const []const u8,
) error{OutOfMemory}!Sources {
    var objects: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    for (uris) |text| {
        const uri = Uri.parse(text) orelse return .{ .failed = .{
            .reason = "invalid",
            .message = try std.fmt.allocPrint(arena, "Invalid source URI: {s}", .{text}),
        } };

        var names: []const []const u8 = &.{uri.object};
        if (uri.wildcard()) |w| {
            const listed = reader.store.list(arena, uri.bucket, w.prefix) catch |err|
                return failure(arena, err, text, reader);
            var matched: std.ArrayList([]const u8) = .empty;
            for (listed) |name| {
                if (name.len < w.prefix.len + w.suffix.len) continue;
                if (std.mem.endsWith(u8, name, w.suffix)) try matched.append(arena, name);
            }
            if (matched.items.len == 0) return failure(arena, error.NotFound, text, reader);
            names = matched.items;
        }

        for (names) |name| {
            const object: Uri = .{ .bucket = uri.bucket, .object = name };
            const bytes = reader.store.get(arena, object, reader.limit - total) catch |err| {
                const shown = try std.fmt.allocPrint(arena, "gs://{s}/{s}", .{ uri.bucket, name });
                return failure(arena, err, shown, reader);
            };
            total += bytes.len;
            try objects.append(arena, bytes);
        }
    }
    return .{ .read = objects.items };
}

fn failure(
    arena: std.mem.Allocator,
    err: Error,
    uri: []const u8,
    reader: Reader,
) error{OutOfMemory}!Sources {
    const endpoint = reader.endpoint;
    return .{ .failed = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotFound => .{
            .reason = "notFound",
            .message = try std.fmt.allocPrint(arena, "Not found: URI {s}", .{uri}),
        },
        error.TooLarge => .{
            .reason = "invalid",
            .message = try std.fmt.allocPrint(
                arena,
                "The sources of this load exceed the {d} bytes the emulator reads for one " ++
                    "load job, at {s}",
                .{ reader.limit, uri },
            ),
        },
        error.TimedOut => .{
            .reason = "backendError",
            .message = try std.fmt.allocPrint(
                arena,
                "The Cloud Storage emulator at {s} did not answer in time for {s}",
                .{ endpoint, uri },
            ),
        },
        error.Unreachable => .{
            .reason = "backendError",
            .message = try std.fmt.allocPrint(
                arena,
                "Could not reach the Cloud Storage emulator at {s} to read {s}",
                .{ endpoint, uri },
            ),
        },
        error.BadResponse, error.Unsupported => .{
            .reason = "backendError",
            .message = try std.fmt.allocPrint(
                arena,
                "The Cloud Storage emulator at {s} gave an unexpected answer for {s}",
                .{ endpoint, uri },
            ),
        },
    } };
}

const testing = std.testing;

test "a gs:// URI splits into bucket and object, with at most one wildcard" {
    const uri = Uri.parse("gs://staging/exports/part-*.csv").?;
    try testing.expectEqualStrings("staging", uri.bucket);
    try testing.expectEqualStrings("exports/part-*.csv", uri.object);
    try testing.expectEqualStrings("exports/part-", uri.wildcard().?.prefix);
    try testing.expectEqualStrings(".csv", uri.wildcard().?.suffix);
    try testing.expect(Uri.parse("gs://staging/people.csv").?.wildcard() == null);

    for ([_][]const u8{
        "s3://staging/people.csv",
        "gs://staging",
        "gs://staging/",
        "gs:///people.csv",
        "gs://stag*ing/people.csv",
        "gs://staging/*/part-*.csv",
    }) |bad| try testing.expect(Uri.parse(bad) == null);
}

test "STORAGE_EMULATOR_HOST takes either spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("http://fake-gcs:4443", try endpointFrom(arena, "fake-gcs:4443"));
    try testing.expectEqualStrings(
        "http://127.0.0.1:4443",
        try endpointFrom(arena, "http://127.0.0.1:4443/"),
    );
}

test "object names are percent-encoded into one path segment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try appendEscaped(arena, &out, "exports/part 1.csv");
    try testing.expectEqualStrings("exports%2Fpart%201.csv", out.items);
}

fn seeded(arena: std.mem.Allocator) !MemoryStore {
    var memory: MemoryStore = .{ .arena = arena };
    const s = memory.store();
    try s.put(arena, .{ .bucket = "staging", .object = "shards/part-001.csv" }, "2,SOUTH\n");
    try s.put(arena, .{ .bucket = "staging", .object = "shards/part-000.csv" }, "1,NORTH\n");
    try s.put(arena, .{ .bucket = "staging", .object = "shards/sub/part-002.csv" }, "3,EAST\n");
    try s.put(arena, .{ .bucket = "staging", .object = "shards/manifest.json" }, "{}\n");
    return memory;
}

test "a wildcard reads its matches in name order, across slashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = try seeded(arena);

    const reader: Reader = .{ .store = memory.store(), .endpoint = "", .limit = 1024 };
    const got = try readSources(arena, reader, &.{"gs://staging/shards/*.csv"});
    try testing.expectEqual(@as(usize, 3), got.read.len);
    try testing.expectEqualStrings("1,NORTH\n", got.read[0]);
    try testing.expectEqualStrings("2,SOUTH\n", got.read[1]);
    try testing.expectEqualStrings("3,EAST\n", got.read[2]);
}

test "URIs are read in the order given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = try seeded(arena);

    const reader: Reader = .{ .store = memory.store(), .endpoint = "", .limit = 1024 };
    const got = try readSources(arena, reader, &.{
        "gs://staging/shards/part-001.csv",
        "gs://staging/shards/part-000.csv",
    });
    try testing.expectEqualStrings("2,SOUTH\n", got.read[0]);
    try testing.expectEqualStrings("1,NORTH\n", got.read[1]);
}

test "a missing object and an empty wildcard are both not found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = try seeded(arena);

    const reader: Reader = .{ .store = memory.store(), .endpoint = "", .limit = 1024 };
    const missing = try readSources(arena, reader, &.{"gs://staging/absent.csv"});
    try testing.expectEqualStrings("notFound", missing.failed.reason);
    try testing.expectEqualStrings("Not found: URI gs://staging/absent.csv", missing.failed.message);

    const empty = try readSources(arena, reader, &.{"gs://staging/none-*.csv"});
    try testing.expectEqualStrings("notFound", empty.failed.reason);
    try testing.expectEqualStrings("Not found: URI gs://staging/none-*.csv", empty.failed.message);
}

test "the byte limit covers every source together" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = try seeded(arena);

    const reader: Reader = .{ .store = memory.store(), .endpoint = "", .limit = 12 };
    const got = try readSources(arena, reader, &.{"gs://staging/shards/part-*.csv"});
    try testing.expectEqualStrings("invalid", got.failed.reason);
    try testing.expect(std.mem.indexOf(u8, got.failed.message, "12 bytes") != null);
}

test "an unreachable emulator fails the read and names its address" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = try seeded(arena);
    memory.failure = error.Unreachable;

    const reader: Reader = .{
        .store = memory.store(),
        .endpoint = "http://fake-gcs:4443",
        .limit = 1024,
    };
    const got = try readSources(arena, reader, &.{"gs://staging/shards/part-000.csv"});
    try testing.expectEqualStrings("backendError", got.failed.reason);
    try testing.expect(std.mem.indexOf(u8, got.failed.message, "http://fake-gcs:4443") != null);
}

test "an emulator that accepts and never answers times out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The server's own Io, which runs the request and its deadline concurrently.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Listening without accepting: the connection completes in the backlog and nothing replies.
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const endpoint = try std.fmt.allocPrint(
        arena,
        "http://127.0.0.1:{d}",
        .{listener.socket.address.getPort()},
    );

    var http: HttpStore = .{
        .gpa = testing.allocator,
        .io = io,
        .endpoint = endpoint,
        .timeout = .fromMilliseconds(200),
    };
    const object: Uri = .{ .bucket = "staging", .object = "a.csv" };
    try testing.expectError(error.TimedOut, http.store().get(arena, object, 1024));
}

test "an HTTP store against a closed port is unreachable, not a hang" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Port 1 is reserved and nothing listens on it.
    var http: HttpStore = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .endpoint = "http://127.0.0.1:1",
    };
    const object: Uri = .{ .bucket = "staging", .object = "a.csv" };
    try testing.expectError(error.Unreachable, http.store().get(arena, object, 1024));
}
