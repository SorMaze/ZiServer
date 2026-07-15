const std = @import("std");

const http_config = @import("http_config.zig");
const client_identity = @import("client_identity.zig");
const locals_mod = @import("locals.zig");
const log = @import("log.zig");
const page_cache = @import("page_cache.zig");
const query_mod = @import("query.zig");
const rate_limiter_mod = @import("rate_limiter.zig");
const request_mod = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const services_mod = @import("services.zig");
const static = @import("static.zig");
const stats_mod = @import("stats.zig");
const streaming = @import("streaming.zig");

const max_response_headers = 16;
const max_request_cleanups = 4;

pub const CleanupFn = *const fn (?*anyopaque, ?*anyopaque) void;

const Cleanup = struct {
    owner: ?*anyopaque,
    resource: ?*anyopaque,
    run: CleanupFn,
};

pub const RuntimeSnapshot = struct {
    server: stats_mod.Snapshot,
    page_cache: ?page_cache.Snapshot,
    rate_limit: ?rate_limiter_mod.Snapshot,
};

pub const ResponseStream = struct {
    ctx: *Context,
    output: response.Stream,
    status: response.Status,

    pub fn write(self: *ResponseStream, chunk: []const u8) !void {
        self.output.write(chunk) catch |err| {
            self.abort();
            return err;
        };
        self.ctx.response_body_bytes = self.output.bytes_written;
    }

    pub fn finish(self: *ResponseStream) !void {
        self.output.finish() catch |err| {
            self.abort();
            return err;
        };
        self.ctx.stream_open = false;
        self.ctx.recordResponse(self.status, if (self.ctx.head) 0 else self.output.bytes_written);
    }

    pub fn abort(self: *ResponseStream) void {
        self.ctx.stream_open = false;
        self.ctx.keep_alive = false;
    }
};

pub const Context = struct {
    io: std.Io,
    writer: *response.Target,
    request: request_mod.Request,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    keep_alive: bool,
    head: bool,
    route_options: router.Options,
    auth_credentials: http_config.AuthCredentials,
    services: services_mod.Registry,
    params: router.Params,
    query: query_mod.View,
    request_stream: streaming.Reader,
    response_status: ?response.Status = null,
    response_body_bytes: usize = 0,
    response_cache_policy: response.CachePolicy = .none,
    response_written: bool = false,
    response_headers: [max_response_headers]response.Header = undefined,
    response_headers_len: usize = 0,
    cache_transparent_headers_len: usize = 0,
    cache_override: ?response.CachePolicy = null,
    page_cache_store: ?*page_cache.Store,
    page_cache_policy: page_cache.Policy = .none,
    page_cache_fill: bool = false,
    page_cache_fill_token: ?page_cache.FillToken = null,
    page_cache_status: log.CacheStatus = .disabled,
    stream_open: bool = false,
    locals: locals_mod.Store = .{},
    cleanups: [max_request_cleanups]Cleanup = undefined,
    cleanups_len: usize = 0,
    identity: client_identity.ClientIdentity = client_identity.ClientIdentity.direct(client_identity.IpKey.unspecified()),
    rate_limiter: ?*rate_limiter_mod.Limiter = null,

    pub fn init(
        io: std.Io,
        writer: *response.Target,
        request: request_mod.Request,
        stats: *stats_mod.Stats,
        static_store: *const static.Store,
        keep_alive: bool,
        route_options: router.Options,
        params: router.Params,
        auth_credentials: http_config.AuthCredentials,
        services: services_mod.Registry,
        page_cache_store: ?*page_cache.Store,
    ) Context {
        return .{
            .io = io,
            .writer = writer,
            .request = request,
            .stats = stats,
            .static_store = static_store,
            .keep_alive = keep_alive,
            .head = request.isHead(),
            .route_options = route_options,
            .auth_credentials = auth_credentials,
            .services = services,
            .params = params,
            .query = query_mod.parse(request.query) catch query_mod.View.invalid(),
            .request_stream = streaming.Reader.buffered(request.body),
            .page_cache_store = page_cache_store,
            .page_cache_status = if (page_cache_store == null) .disabled else .bypass,
        };
    }

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn queryParam(self: *const Context, name: []const u8) ?[]const u8 {
        if (!self.query.valid) return null;
        return self.query.getFirst(name);
    }

    pub fn setClientIdentity(self: *Context, identity: client_identity.ClientIdentity) void {
        self.identity = identity;
    }

    pub fn clientIp(self: *const Context) client_identity.IpKey {
        return self.identity.client_ip;
    }

    pub fn peerIp(self: *const Context) client_identity.IpKey {
        return self.identity.peer_ip;
    }

    pub fn clientIdentity(self: *const Context) client_identity.ClientIdentity {
        return self.identity;
    }

    pub fn setRateLimiter(self: *Context, limiter: ?*rate_limiter_mod.Limiter) void {
        self.rate_limiter = limiter;
    }

    pub fn setLocal(self: *Context, key: *const anyopaque, value: anytype) !void {
        try self.locals.put(key, value);
    }

    pub fn local(self: *const Context, key: *const anyopaque, comptime T: type) ?T {
        return self.locals.get(key, T);
    }

    pub fn service(self: *const Context, key: *const anyopaque, comptime T: type) ?*T {
        return self.services.get(key, T);
    }

    pub fn registerCleanup(self: *Context, owner: ?*anyopaque, resource: ?*anyopaque, run: CleanupFn) !void {
        if (self.cleanups_len == self.cleanups.len) return error.RequestCleanupsFull;
        self.cleanups[self.cleanups_len] = .{ .owner = owner, .resource = resource, .run = run };
        self.cleanups_len += 1;
    }

    pub fn deinit(self: *Context) void {
        while (self.cleanups_len != 0) {
            self.cleanups_len -= 1;
            const cleanup = self.cleanups[self.cleanups_len];
            cleanup.run(cleanup.owner, cleanup.resource);
        }
    }

    pub fn requestBodyStream(self: *Context) *streaming.Reader {
        return &self.request_stream;
    }

    pub fn setRequestBodyStream(self: *Context, reader: streaming.Reader) void {
        self.request_stream = reader;
    }

    pub fn beginResponseStream(
        self: *Context,
        status: response.Status,
        content_type: []const u8,
        content_length: ?usize,
        cache: response.CachePolicy,
    ) !ResponseStream {
        if (self.response_written) return error.ResponseAlreadyWritten;
        var header_buffer: [max_response_headers + 8]response.Header = undefined;
        const headers = try self.mergeHeaders(&header_buffer, &.{});
        if (content_length == null and self.request.version == .http10) self.keep_alive = false;
        self.finishPageCacheFill();
        self.page_cache_policy = .none;
        const effective_cache = self.cache_override orelse cache;
        const output = try response.Stream.begin(
            self.writer,
            status,
            content_type,
            self.head,
            self.keep_alive,
            self.request.version == .http11,
            content_length,
            effective_cache,
            headers,
        );
        self.response_status = status;
        self.response_body_bytes = 0;
        self.response_cache_policy = effective_cache;
        self.response_written = true;
        self.stream_open = true;
        return .{ .ctx = self, .output = output, .status = status };
    }

    pub fn abortResponseStream(self: *Context) void {
        if (!self.stream_open) return;
        self.stream_open = false;
        self.keep_alive = false;
        switch (self.writer.*) {
            .capture => |capture_target| {
                capture_target.response.deinit(capture_target.allocator);
                self.response_status = null;
                self.response_body_bytes = 0;
                self.response_written = false;
            },
            .http1 => {},
            .h2_stream => |stream_target| {
                stream_target.output.cancel(stream_target.io);
                stream_target.response.deinit(stream_target.allocator);
                self.response_status = null;
                self.response_body_bytes = 0;
                self.response_written = false;
            },
        }
    }

    pub fn runtimeSnapshot(self: *Context) RuntimeSnapshot {
        return .{
            .server = self.stats.snapshot(),
            .page_cache = if (self.page_cache_store) |store| store.snapshot() else null,
            .rate_limit = if (self.rate_limiter) |limiter| limiter.snapshot() else null,
        };
    }

    pub fn addHeader(self: *Context, name: []const u8, value: []const u8) !void {
        try response.validateHeader(name, value);
        if (self.response_headers_len >= self.response_headers.len) return error.ResponseHeaderOverflow;
        self.response_headers[self.response_headers_len] = .{ .name = name, .value = value };
        self.response_headers_len += 1;
    }

    /// Adds a connection-level header that is regenerated for cache hits and
    /// therefore does not make an otherwise cacheable response vary.
    pub fn addTransportHeader(self: *Context, name: []const u8, value: []const u8) !void {
        try self.addHeader(name, value);
        self.cache_transparent_headers_len += 1;
    }

    pub fn setCachePolicy(self: *Context, cache: response.CachePolicy) void {
        self.cache_override = cache;
    }

    pub fn enablePageCacheFill(self: *Context, policy: page_cache.Policy, token: page_cache.FillToken) void {
        self.page_cache_policy = policy;
        self.page_cache_fill = policy != .none;
        self.page_cache_fill_token = token;
        if (self.page_cache_fill) self.page_cache_status = .miss;
    }

    pub fn markPageCacheHit(self: *Context) void {
        self.page_cache_status = .hit;
    }

    pub fn markPageCacheMiss(self: *Context) void {
        self.page_cache_status = .miss;
    }

    pub fn markPageCacheBypass(self: *Context) void {
        self.page_cache_status = if (self.page_cache_store == null) .disabled else .bypass;
    }

    pub fn finishPageCacheFill(self: *Context) void {
        if (self.page_cache_fill_token) |*token| token.complete(self.io);
        self.page_cache_fill_token = null;
        self.page_cache_fill = false;
    }

    pub fn pendingHeaders(self: *const Context) []const response.Header {
        return self.response_headers[0..self.response_headers_len];
    }

    pub fn writeBytes(
        self: *Context,
        status: response.Status,
        content_type: []const u8,
        body: []const u8,
        cache: response.CachePolicy,
        extra_headers: []const response.Header,
    ) !void {
        try self.writeBytesHead(status, content_type, body, self.head, cache, extra_headers);
    }

    pub fn writeBytesHead(
        self: *Context,
        status: response.Status,
        content_type: []const u8,
        body: []const u8,
        head: bool,
        cache: response.CachePolicy,
        extra_headers: []const response.Header,
    ) !void {
        if (self.response_written) return error.ResponseAlreadyWritten;
        var header_buffer: [max_response_headers + 8]response.Header = undefined;
        const merged_headers = try self.mergeHeaders(&header_buffer, extra_headers);
        const effective_cache = self.cache_override orelse cache;
        try response.writeBytes(
            self.writer,
            status,
            content_type,
            body,
            head,
            self.keep_alive,
            effective_cache,
            merged_headers,
        );
        self.response_cache_policy = effective_cache;
        self.recordResponse(status, if (head) 0 else body.len);
        if (self.page_cache_fill and !head and status.code == response.Status.ok.code and
            self.pendingHeaders().len == self.cache_transparent_headers_len and extra_headers.len == 0)
        {
            self.page_cache_fill = false;
            if (self.page_cache_store) |store| {
                var key_buffer: [page_cache.max_key_bytes]u8 = undefined;
                const key = page_cache.requestKey(self.request, &key_buffer) orelse return;
                store.put(
                    self.io,
                    key,
                    content_type,
                    body,
                    effective_cache,
                    std.Io.Clock.awake.now(self.io).nanoseconds,
                    self.page_cache_policy,
                ) catch {
                    self.finishPageCacheFill();
                    return;
                };
                self.page_cache_status = .fill;
                self.finishPageCacheFill();
            }
        }
    }

    pub fn writeJson(
        self: *Context,
        status: response.Status,
        body: []const u8,
        cache: response.CachePolicy,
    ) !void {
        try self.writeBytes(status, http_config.ContentType.json, body, cache, &.{});
    }

    pub fn writeJsonHead(
        self: *Context,
        status: response.Status,
        body: []const u8,
        head: bool,
        cache: response.CachePolicy,
    ) !void {
        try self.writeBytesHead(status, http_config.ContentType.json, body, head, cache, &.{});
    }

    pub fn html(self: *Context, status: response.Status, body: []const u8) !void {
        try self.writeBytes(status, http_config.ContentType.html, body, .no_cache, &.{});
    }

    pub fn htmlCached(
        self: *Context,
        status: response.Status,
        body: []const u8,
        cache: response.CachePolicy,
    ) !void {
        try self.writeBytes(status, http_config.ContentType.html, body, cache, &.{});
    }

    pub fn json(self: *Context, status: response.Status, body: []const u8) !void {
        try self.writeJson(status, body, .no_cache);
    }

    pub fn jsonCached(
        self: *Context,
        status: response.Status,
        body: []const u8,
        cache: response.CachePolicy,
    ) !void {
        try self.writeJson(status, body, cache);
    }

    pub fn text(self: *Context, status: response.Status, body: []const u8) !void {
        try self.writeBytes(status, http_config.ContentType.plain, body, .no_cache, &.{});
    }

    pub fn textCached(
        self: *Context,
        status: response.Status,
        body: []const u8,
        cache: response.CachePolicy,
    ) !void {
        try self.writeBytes(status, http_config.ContentType.plain, body, cache, &.{});
    }

    pub fn recordResponse(self: *Context, status: response.Status, body_bytes: usize) void {
        self.response_status = status;
        self.response_body_bytes = body_bytes;
        self.response_written = true;
    }

    fn mergeHeaders(
        self: *const Context,
        buffer: []response.Header,
        extra_headers: []const response.Header,
    ) ![]const response.Header {
        const pending = self.pendingHeaders();
        if (pending.len + extra_headers.len > buffer.len) return error.ResponseHeaderOverflow;
        @memcpy(buffer[0..pending.len], pending);
        @memcpy(buffer[pending.len .. pending.len + extra_headers.len], extra_headers);
        return buffer[0 .. pending.len + extra_headers.len];
    }
};

test "context fills page cache with a cache-transparent transport header" {
    const page_cache_mod = @import("page_cache.zig");

    var store = try page_cache_mod.Store.init(std.testing.allocator, .{});
    defer store.deinit(std.testing.io);
    const request = try request_mod.Request.parse("GET /cached HTTP/1.1\r\nHost: test\r\n\r\n");
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .page_cache = .standard },
        router.Params.empty(),
        .{},
        .{},
        &store,
    );
    var key_buffer_for_fill: [page_cache_mod.max_key_bytes]u8 = undefined;
    const fill_key = page_cache_mod.requestKey(request, &key_buffer_for_fill).?;
    const fill = try store.beginFill(std.testing.io, fill_key, std.Io.Clock.awake.now(std.testing.io).nanoseconds);
    ctx.enablePageCacheFill(.standard, fill.leader);
    try ctx.addTransportHeader("Alt-Svc", "h3=\":443\"");
    try std.testing.expectEqual(log.CacheStatus.miss, ctx.page_cache_status);
    try ctx.html(.ok, "body");
    try std.testing.expectEqual(log.CacheStatus.fill, ctx.page_cache_status);
    try std.testing.expectEqual(response.CachePolicy.no_cache, ctx.response_cache_policy);

    var key_buffer: [page_cache_mod.max_key_bytes]u8 = undefined;
    const key = page_cache_mod.requestKey(request, &key_buffer).?;
    const hit = store.acquire(std.testing.io, key, std.Io.Clock.awake.now(std.testing.io).nanoseconds).?;
    defer hit.deinit();
    try std.testing.expectEqualStrings("body", hit.body());

    var found_alt_svc = false;
    for (capture.headers[0..capture.headers_len]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name_ptr[0..header.name_len], "Alt-Svc")) {
            found_alt_svc = true;
            break;
        }
    }
    try std.testing.expect(found_alt_svc);
}
