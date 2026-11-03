//! Replaces bigquery-emulator's use of net/http + gorilla/mux — REDESIGNED,
//! not ported. dusty owns the sockets: accepting, HTTP/1.1 parsing,
//! keep-alive, chunked and gzip request bodies, and `Expect: 100-continue`.
//! This file turns each request dusty parses into a `Request` and writes the `Response` a
//! handler returns back. Two global middlewares run around every request: RequestScope settles
//! the Host-derived endpoint and EngineLock holds the handler's mutex.
//!
//! Routes come from the `Options.routes` hook. A request no route matches reaches `App.notFound`,
//! which hands it to the `Handler`.
//!
//! Differences from Go, by design: Go threads request-scoped values through context.Context with
//! eight keys (server/context.go) and eleven middlewares that populate them; here a `Request`
//! carries what handlers need as plain fields.
//!
//! HTTP/1.1 only, cleartext: the BigQuery REST clients speak plain HTTP/1.1
//! to an emulator.
// ephor:ignore-file ZA301 ZA302 ZT105

const std = @import("std");
const dusty = @import("dusty");

/// The 500 a failed handler answers with, spelled out rather than built: this
/// path runs after something already went wrong, so it must not allocate.
/// `error.zig` has a test pinning it to what `errors.body` produces.
pub const internal_error_body =
    \\{"error":{"errors":[{"reason":"internalError","location":"","debugInfo":"","message":"internal error"}],"code":500,"message":"internal error"}}
;
const http = std.http;

/// Largest request body accepted, after decompression. Go has no limit; this
/// one keeps a hostile client from exhausting the request arena.
pub const max_body_len = 64 * 1024 * 1024;

/// The request headers a handler can read.
///
/// An allow-list rather than the whole set keeps `Request` free of dusty's
/// types, so handlers and their tests build one from plain slices. Adding a
/// header is a field here and a line in `headersFrom`.
pub const Headers = struct {
    /// `multipart/related; boundary=...` on a multipart upload.
    content_type: ?[]const u8 = null,
    /// `bytes 0-524287/2000000`, or `bytes */2000000` on a status query.
    content_range: ?[]const u8 = null,
    /// What a resumable upload says its bytes will be.
    x_upload_content_length: ?[]const u8 = null,
};

pub const Request = struct {
    method: http.Method,
    /// Path with the query string removed, percent-decoding NOT applied.
    path: []const u8,
    /// Raw query string, without '?'. Empty when absent.
    query: []const u8,
    /// Decompressed request body. Empty when there is none.
    body: []const u8,
    headers: Headers = .{},
    /// host:port the client addressed, from a `Host` header that passed endpointFromHost.
    /// Null when there was none, which leaves the handler to use the address it bound.
    endpoint: ?[]const u8 = null,
    /// Per-request arena. Everything a handler allocates comes from here and
    /// dies when the request completes.
    arena: std.mem.Allocator,

    /// Value of the first matching query parameter, or null.
    ///
    /// Values are returned raw; callers that need percent-decoding must do it
    /// themselves. The emulator's own parameters (maxResults, prettyPrint,
    /// alt) are never encoded in practice.
    pub fn queryParam(r: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, r.query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                if (std.mem.eql(u8, pair, name)) return "";
                continue;
            };
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
};

pub const Response = struct {
    status: http.Status = .ok,
    /// Serialized body. Owned by the request arena.
    body: []const u8 = "",
    content_type: []const u8 = "application/json; charset=UTF-8",
    /// Headers beyond the content type. A resumable upload answers with `Location` when it
    /// opens a session and `Range` when it accepts a chunk. api-uploads
    extra_headers: []const http.Header = &.{},
};

/// A handler turns a request into a complete response. Returning an error
/// produces a 500 in the BigQuery error shape, mirroring Go's
/// recoveryMiddleware.
pub const HandlerFn = *const fn (ctx: *anyopaque, req: *const Request) anyerror!Response;

pub const Handler = struct {
    ctx: *anyopaque,
    func: HandlerFn,
    /// Serializes calls to `func`.
    ///
    /// Owned by the handler, not by this server, because it does not guard
    /// this transport — it guards the single engine connection behind `ctx`,
    /// which the Storage Read API's gRPC server reaches through the same
    /// `bqserver.Server` (see src/server/grpc/read_service.zig). A mutex per
    /// transport would serialize each of them against itself and neither
    /// against the other.
    mutex: *std.Io.Mutex,
    /// The `Io` the mutex is taken with. Only read under contention: an
    /// uncontended lock and unlock are a compare-exchange and a swap.
    io: std.Io,
};

/// Contention accounting for the single handler mutex.
///
/// The question these answer: is the server the bottleneck, or is it waiting
/// on the client? If `wait` dominates `handle`, requests are queueing behind
/// the mutex and parallelism is the lever. If it does not, the client is not
/// offering work fast enough and a pool would buy nothing.
pub var stat_requests: std.atomic.Value(u64) = .init(0);
pub var stat_wait_ns: std.atomic.Value(u64) = .init(0);
pub var stat_handle_ns: std.atomic.Value(u64) = .init(0);
pub var stat_waiters_now: std.atomic.Value(u64) = .init(0);
pub var stat_waiters_max: std.atomic.Value(u64) = .init(0);

pub const Options = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 9050,
    /// Registers the routes dusty matches before falling back to `App.notFound`. Runs once the
    /// global middlewares are in place, because a route keeps the middlewares it was registered
    /// with.
    routes: ?*const fn (router: *dusty.Router(App)) void = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: App,
    listeners: [1]dusty.Listener,
    inner: dusty.Server(App),
    /// dusty's global middlewares, run in this order around every request.
    middlewares: [2]dusty.Middleware(App) = undefined,
    request_scope: RequestScope = .{},
    engine_lock: EngineLock,
    /// The task running `inner.run`, from `listen` until `serve` or `deinit`
    /// collects it.
    running: ?std.Io.Future(anyerror!void) = null,
    /// Set by the run task when `inner.run` returns before the listener was
    /// up, so `listen` can tell a failed bind from a ready one.
    failed: std.atomic.Value(bool) = .init(false),

    /// Binds `opts.address:opts.port` and starts serving on it.
    ///
    /// Returns once the socket accepts connections, or with the bind error,
    /// so a caller can announce readiness right after. Heap-allocated because
    /// dusty keeps a pointer to `app` for the server's life.
    pub fn listen(
        gpa: std.mem.Allocator,
        io: std.Io,
        opts: Options,
        handler: Handler,
    ) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .app = .{ .handler = handler },
            .engine_lock = .{ .mutex = handler.mutex, .io = handler.io },
            .listeners = .{.{
                .address = .{ .ip = try std.Io.net.IpAddress.parse(opts.address, opts.port) },
            }},
            .inner = undefined,
        };
        s.inner = .init(gpa, io, .{
            .listeners = &s.listeners,
            .timeout = .{
                // A query or load job runs inside its request, for as long as
                // the engine takes.
                .request = null,
                // Google's clients pool connections and reuse them after any
                // idle gap; closing one under them shows up as a reset on
                // their next call.
                .keepalive = null,
            },
            .request = .{
                .max_body_size = max_body_len,
                // dusty parses the query string up front and answers 400 past
                // this count. Handlers read it raw through Request.queryParam,
                // so the cap only has to admit what clients send.
                .max_query_count = 256,
                // Send 400, 413 and 415 through `App.uncaughtError`, so
                // they carry the BigQuery error shape like every other error.
                .answer_client_errors = false,
            },
        }, &s.app);
        errdefer s.inner.deinit();
        s.middlewares = .{ .init(&s.request_scope), .init(&s.engine_lock) };
        s.inner.router.middlewares = &s.middlewares;
        if (opts.routes) |register| register(&s.inner.router);

        s.running = try io.concurrent(runInner, .{s});
        s.inner.ready.waitUncancelable(io);
        if (s.failed.load(.acquire)) {
            const err = s.running.?.await(io);
            s.running = null;
            try err;
            unreachable;
        }
        return s;
    }

    fn runInner(s: *Server) anyerror!void {
        s.inner.run() catch |err| {
            // `ready` is only set once every listener is bound; wake `listen`
            // when the run ends before that.
            s.failed.store(true, .release);
            s.inner.ready.set(s.io);
            return err;
        };
    }

    /// Stops accepting, lets the requests in flight finish, and frees the
    /// server.
    pub fn deinit(s: *Server) void {
        if (s.running) |*running| {
            running.cancel(s.io) catch {};
        }
        s.inner.deinit();
        s.gpa.destroy(s);
    }

    /// Serves until the process ends or the run task is canceled.
    pub fn serve(s: *Server) !void {
        const running = &(s.running orelse return);
        const result = running.await(s.io);
        s.running = null;
        result catch |err| switch (err) {
            error.Canceled => return,
            else => return err,
        };
    }
};

/// The app dusty hands every request to. dusty has no routes registered, so
/// each request reaches `notFound`, which is the dispatch entry point.
pub const App = struct {
    handler: Handler,

    /// What the middlewares settle once per request, for the handler and the error hook.
    pub const RequestContext = struct {
        /// See Request.endpoint.
        endpoint: ?[]const u8 = null,
    };

    pub fn notFound(
        e: *App,
        req: *dusty.Request,
        res: *dusty.Response,
        ctx: *const RequestContext,
    ) !void {
        const r = try requestFrom(req, ctx) orelse {
            res.status = .method_not_allowed;
            return;
        };
        try respond(res, try e.handler.func(e.handler.ctx, &r));
    }

    pub fn uncaughtError(
        req: *dusty.Request,
        res: *dusty.Response,
        ctx: *const RequestContext,
        err: anyerror,
    ) void {
        res.header("Content-Type", "application/json; charset=UTF-8") catch |header_err|
            std.log.warn("error response sent without a content type: {t}", .{header_err});
        if (req.clientErrorStatus()) |status| {
            res.status = status;
            res.body = switch (status) {
                .payload_too_large => too_large_body,
                .unsupported_media_type => unsupported_encoding_body,
                else => bad_request_body,
            };
            return;
        }
        // Mirrors Go's recoveryMiddleware: report, answer, keep the
        // connection.
        std.log.err("request failed: {t} {s} (host {s}): {t}", .{
            req.method,
            req.url,
            ctx.endpoint orelse "unset",
            err,
        });
        res.status = .internal_server_error;
        res.body = internal_error_body;
    }
};

/// The handler's view of a request dusty parsed, or null for a method outside methodFrom.
pub fn requestFrom(req: *dusty.Request, ctx: *const App.RequestContext) !?Request {
    const method = methodFrom(req.method) orelse return null;
    // dusty's own `path` is percent-decoded; the router.zig fallback matches the encoded form,
    // so split the raw target instead.
    const q = std.mem.indexOfScalar(u8, req.url, '?');
    return .{
        .method = method,
        .path = if (q) |i| req.url[0..i] else req.url,
        .query = if (q) |i| req.url[i + 1 ..] else "",
        .body = try req.body() orelse "",
        .headers = headersFrom(req),
        .endpoint = ctx.endpoint,
        .arena = req.arena,
    };
}

/// Writes a handler's response into dusty's.
pub fn respond(res: *dusty.Response, out: Response) !void {
    res.status = std.enums.fromInt(dusty.Status, @intFromEnum(out.status)) orelse
        return error.UnsupportedStatus;
    try res.header("Content-Type", out.content_type);
    for (out.extra_headers) |h| try res.header(h.name, h.value);
    res.body = out.body;
}

/// Settles RequestContext.endpoint from the `Host` header.
const RequestScope = struct {
    pub fn execute(
        _: *const RequestScope,
        req: *dusty.Request,
        _: *dusty.Response,
        executor: anytype,
    ) !void {
        executor.ctx.endpoint = if (req.headers.get("host")) |host| endpointFromHost(host) else null;
        return executor.next();
    }
};

/// Holds the handler's mutex across the rest of the request, recording how long the request
/// waited for it and how long it held it.
const EngineLock = struct {
    mutex: *std.Io.Mutex,
    io: std.Io,

    pub fn execute(
        l: *const EngineLock,
        _: *dusty.Request,
        _: *dusty.Response,
        executor: anytype,
    ) !void {
        const waiting = stat_waiters_now.fetchAdd(1, .monotonic) + 1;
        if (waiting > stat_waiters_max.load(.monotonic)) {
            stat_waiters_max.store(waiting, .monotonic);
        }
        const t_arrive = std.Io.Clock.awake.now(l.io);

        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        const t_locked = std.Io.Clock.awake.now(l.io);
        _ = stat_waiters_now.fetchSub(1, .monotonic);
        // Runs before the unlock above, on success and on error alike.
        defer {
            const t_done = std.Io.Clock.awake.now(l.io);
            _ = stat_requests.fetchAdd(1, .monotonic);
            _ = stat_wait_ns.fetchAdd(
                @intCast(t_arrive.durationTo(t_locked).nanoseconds),
                .monotonic,
            );
            _ = stat_handle_ns.fetchAdd(
                @intCast(t_locked.durationTo(t_done).nanoseconds),
                .monotonic,
            );
        }
        return executor.next();
    }
};

/// The `Host` header as an endpoint for URLs, or null when it is not a plain
/// `name[:port]` or `[ipv6][:port]` this server can echo back.
pub fn endpointFromHost(host: []const u8) ?[]const u8 {
    if (host.len == 0 or host.len > 255) return null;
    const authority_end = if (host[0] == '[')
        (std.mem.indexOfScalar(u8, host, ']') orelse return null) + 1
    else
        std.mem.indexOfScalar(u8, host, ':') orelse host.len;
    const authority = host[0..authority_end];
    const rest = host[authority_end..];
    if (!validHostName(authority) and !validIpv6Literal(authority)) return null;
    if (rest.len > 0 and (rest[0] != ':' or !validPort(rest[1..]))) return null;
    return host;
}

/// A DNS name or IPv4 address: letters, digits, dots and hyphens.
fn validHostName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') return false;
    }
    return true;
}

/// `[` hex digits, colons and dots `]`. A zone index (`%en0`) is refused.
fn validIpv6Literal(literal: []const u8) bool {
    if (literal.len < 3 or literal[0] != '[' or literal[literal.len - 1] != ']') return false;
    for (literal[1 .. literal.len - 1]) |ch| {
        if (!std.ascii.isHex(ch) and ch != ':' and ch != '.') return false;
    }
    return true;
}

/// Decimal digits naming a port from 0 to 65535.
fn validPort(digits: []const u8) bool {
    if (digits.len == 0) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    _ = std.fmt.parseInt(u16, digits, 10) catch return false;
    return true;
}

/// The 4xx bodies for what the client got wrong before a handler ran. Spelled
/// out for the same reason as `internal_error_body`.
const bad_request_body =
    \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"malformed request"}],"code":400,"message":"malformed request"}}
;
const too_large_body =
    \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"request body too large"}],"code":413,"message":"request body too large"}}
;
const unsupported_encoding_body =
    \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"unsupported content encoding"}],"code":415,"message":"unsupported content encoding"}}
;

/// The RFC 9110 methods plus PATCH; the router answers those it has no route for. Any other
/// (WebDAV and the like) is a 405.
fn methodFrom(m: dusty.Method) ?http.Method {
    return switch (m) {
        .get => .GET,
        .head => .HEAD,
        .post => .POST,
        .put => .PUT,
        .patch => .PATCH,
        .delete => .DELETE,
        .options => .OPTIONS,
        .connect => .CONNECT,
        .trace => .TRACE,
        else => null,
    };
}

/// dusty's spelling of `m`, for matching a Request built without a socket.
pub fn dustyMethod(m: http.Method) dusty.Method {
    return switch (m) {
        inline else => |tag| comptime blk: {
            const name = @tagName(tag);
            var lower: [name.len]u8 = undefined;
            _ = std.ascii.lowerString(&lower, name);
            const spelled = lower;
            break :blk @field(dusty.Method, &spelled);
        },
    };
}

/// The allow-listed headers, borrowed from the request head, which outlives
/// the handler.
fn headersFrom(req: *const dusty.Request) Headers {
    return .{
        .content_type = req.headers.get("content-type"),
        .content_range = req.headers.get("content-range"),
        .x_upload_content_length = req.headers.get("x-upload-content-length"),
    };
}

test "queryParam parses the forms the emulator actually receives" {
    const r = Request{
        .method = .GET,
        .path = "/projects/p/queries",
        .query = "maxResults=10&prettyPrint=false&flag&alt=json",
        .body = "",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("10", r.queryParam("maxResults").?);
    try std.testing.expectEqualStrings("false", r.queryParam("prettyPrint").?);
    try std.testing.expectEqualStrings("json", r.queryParam("alt").?);
    // Valueless parameter.
    try std.testing.expectEqualStrings("", r.queryParam("flag").?);
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("missing"));
    // Must not match on a prefix.
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("max"));
}

test "empty query string yields no parameters" {
    const r = Request{
        .method = .POST,
        .path = "/projects/p/queries",
        .query = "",
        .body = "",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("maxResults"));
}

test "endpointFromHost admits host names, IPv4 and bracketed IPv6, with or without a port" {
    const ok = [_][]const u8{
        "bigquery-emulator:9050",
        "localhost",
        "127.0.0.1:60050",
        "[::1]:9050",
        "[::1]",
        "bq.example.internal",
    };
    for (ok) |host| try std.testing.expectEqualStrings(host, endpointFromHost(host).?);
}

test "endpointFromHost rejects what cannot be echoed into a URL" {
    const long: [256]u8 = @splat('a');
    const bad = [_][]const u8{
        "",
        &long,
        "evil/path",
        "a b",
        "host:",
        ":9050",
        "host:99999",
        "host:9a",
        "[::1",
        "[]:9050",
        "[::1]x",
        "[fe80::1%en0]",
        "user@host",
        "host\r\nX-Injected: 1",
    };
    for (bad) |host| try std.testing.expectEqual(@as(?[]const u8, null), endpointFromHost(host));
}
