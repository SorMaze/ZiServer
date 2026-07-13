const std = @import("std");

const http_config = @import("http_config.zig");
const page_cache = @import("page_cache.zig");
const request_mod = @import("request.zig");
const static = @import("static.zig");

pub const Handler = u16;

pub const PathKind = enum {
    auto,
    exact,
    dynamic,
};

pub const Options = struct {
    auth: http_config.AuthPolicy = .none,
    body_limit: ?usize = null,
    cache: ?http_config.CachePolicy = null,
    cors: http_config.CorsPolicy = .none,
    rate_limit: http_config.RateLimitPolicy = .none,
    require_auth: bool = false,
    middleware_flags: u32 = 0,
    page_cache: page_cache.Policy = .none,
    upload: ?http_config.UploadPolicy = null,
    upload_landing: http_config.UploadLanding = .none,
    streaming_body: bool = false,
    database: http_config.DatabasePolicy = .none,
    content: ?http_config.ContentPolicy = null,
};

pub const Entry = struct {
    method: request_mod.Method,
    path: []const u8,
    handler: Handler,
    options: Options = .{},
    path_kind: PathKind = .auto,
};

pub const max_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Params = struct {
    items: [max_params]Param = undefined,
    len: usize = 0,

    pub fn empty() Params {
        return .{};
    }

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |param| {
            if (std.mem.eql(u8, param.name, name)) return param.value;
        }
        return null;
    }
};

pub const ResolvedHandler = struct {
    id: Handler,
    options: Options = .{},
    params: Params = Params.empty(),
};

pub const Route = union(enum) {
    handler: ResolvedHandler,
    preflight: ResolvedHandler,
    static: static.Asset,
    not_found,
    method_not_allowed,
};

pub const Registry = struct {
    entries: []Entry,
    len: usize = 0,

    pub fn init(buffer: []Entry) Registry {
        return .{ .entries = buffer };
    }

    pub fn add(
        self: *Registry,
        method: request_mod.Method,
        path: []const u8,
        handler: Handler,
        options: Options,
    ) !void {
        if (self.len >= self.entries.len) return error.RouteTableFull;
        self.entries[self.len] = .{
            .method = method,
            .path = path,
            .handler = handler,
            .options = options,
            .path_kind = classifyPath(path),
        };
        self.len += 1;
    }

    pub fn table(self: *const Registry) Table {
        return .{ .entries = self.entries[0..self.len] };
    }
};

pub const Table = struct {
    entries: []const Entry,

    pub fn resolveHandler(self: Table, request: request_mod.Request) ?ResolvedHandler {
        for (self.entries) |entry| {
            if (!methodMatches(entry.method, request.method)) continue;
            if (matchEntryPath(entry, request.path)) |params| {
                return .{
                    .id = entry.handler,
                    .options = entry.options,
                    .params = params,
                };
            }
        }
        return null;
    }

    pub fn resolve(self: Table, store: *const static.Store, request: request_mod.Request) !Route {
        if (self.resolveHandler(request)) |handler| {
            return .{ .handler = handler };
        }

        if (self.resolvePreflight(request)) |handler| {
            return .{ .preflight = handler };
        }

        if (request.method == .get or request.method == .head) {
            if (try store.resolve(request.path)) |asset| return .{ .static = asset };
            return .not_found;
        }

        if (request.method == .post) return .not_found;
        return .method_not_allowed;
    }

    fn resolvePreflight(self: Table, request: request_mod.Request) ?ResolvedHandler {
        if (request.method != .options) return null;
        const requested_method = request.header(http_config.HeaderName.access_control_request_method) orelse return null;

        for (self.entries) |entry| {
            if (!std.ascii.eqlIgnoreCase(requested_method, methodName(entry.method))) continue;
            if (matchEntryPath(entry, request.path)) |params| {
                return .{
                    .id = entry.handler,
                    .options = entry.options,
                    .params = params,
                };
            }
        }
        return null;
    }
};

pub fn classifyPath(path: []const u8) PathKind {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len > 1 and (segment[0] == ':' or segment[0] == '*')) return .dynamic;
    }
    return .exact;
}

fn matchEntryPath(entry: Entry, path: []const u8) ?Params {
    return switch (entry.path_kind) {
        .exact => if (std.mem.eql(u8, entry.path, path)) Params.empty() else null,
        .dynamic => matchPath(entry.path, path),
        .auto => switch (classifyPath(entry.path)) {
            .exact => if (std.mem.eql(u8, entry.path, path)) Params.empty() else null,
            .dynamic => matchPath(entry.path, path),
            .auto => unreachable,
        },
    };
}

fn methodMatches(route_method: request_mod.Method, request_method: request_mod.Method) bool {
    return route_method == request_method or
        (request_method == .head and route_method == .get);
}

fn methodName(method: request_mod.Method) []const u8 {
    return switch (method) {
        .get => "GET",
        .head => "HEAD",
        .post => "POST",
        .put => "PUT",
        .delete => "DELETE",
        .patch => "PATCH",
        .options => "OPTIONS",
        .unknown => "",
    };
}

fn matchPath(pattern: []const u8, path: []const u8) ?Params {
    if (std.mem.eql(u8, pattern, path)) return Params.empty();

    var params = Params.empty();
    var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
    var path_parts = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pattern_part = pattern_parts.next();
        const path_part = path_parts.next();
        if (pattern_part == null and path_part == null) return params;
        if (pattern_part == null or path_part == null) return null;

        const pattern_segment = pattern_part.?;
        const path_segment = path_part.?;

        if (pattern_segment.len > 1 and pattern_segment[0] == ':') {
            if (path_segment.len == 0 or params.len >= max_params) return null;
            params.items[params.len] = .{
                .name = pattern_segment[1..],
                .value = path_segment,
            };
            params.len += 1;
            continue;
        }

        if (pattern_segment.len > 1 and pattern_segment[0] == '*') {
            if (params.len >= max_params) return null;
            if (pattern_parts.next() != null) return null;
            const wildcard_start = @intFromPtr(path_segment.ptr) - @intFromPtr(path.ptr);
            params.items[params.len] = .{
                .name = pattern_segment[1..],
                .value = path[wildcard_start..],
            };
            params.len += 1;
            return params;
        }

        if (!std.mem.eql(u8, pattern_segment, path_segment)) return null;
    }
}

test "match dynamic get routes" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .get, .path = "/health", .handler = 1 },
        .{ .method = .get, .path = "/stats", .handler = 2 },
    };
    const table = Table{ .entries = &entries };
    const health = try request_mod.Request.parse("GET /health HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(@as(Handler, 1), (try table.resolve(&store, health)).handler.id);

    const stats = try request_mod.Request.parse("HEAD /stats HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(@as(Handler, 2), (try table.resolve(&store, stats)).handler.id);
}

test "match dynamic path parameters" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .get, .path = "/site", .handler = 4 },
        .{ .method = .get, .path = "/site/:page", .handler = 4 },
    };
    const table = Table{ .entries = &entries };
    const page = try request_mod.Request.parse("GET /site/products HTTP/1.1\r\nHost: test\r\n\r\n");
    const route = (try table.resolve(&store, page)).handler;
    try std.testing.expectEqual(@as(Handler, 4), route.id);
    try std.testing.expectEqualStrings("products", route.params.get("page").?);

    const head = try request_mod.Request.parse("HEAD /site/about HTTP/1.1\r\nHost: test\r\n\r\n");
    const head_route = (try table.resolve(&store, head)).handler;
    try std.testing.expectEqual(@as(Handler, 4), head_route.id);
    try std.testing.expectEqualStrings("about", head_route.params.get("page").?);
}

test "match trailing wildcard path parameters" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .get, .path = "/files/*path", .handler = 5 },
    };
    const table = Table{ .entries = &entries };
    const nested = try request_mod.Request.parse("GET /files/docs/readme.txt HTTP/1.1\r\nHost: test\r\n\r\n");
    const route = (try table.resolve(&store, nested)).handler;
    try std.testing.expectEqual(@as(Handler, 5), route.id);
    try std.testing.expectEqualStrings("docs/readme.txt", route.params.get("path").?);

    const root = try request_mod.Request.parse("GET /files/ HTTP/1.1\r\nHost: test\r\n\r\n");
    const root_route = (try table.resolve(&store, root)).handler;
    try std.testing.expectEqualStrings("", root_route.params.get("path").?);

    const missing_prefix = try request_mod.Request.parse("GET /other/docs/readme.txt HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(Route.not_found, try table.resolve(&store, missing_prefix));
}

test "match submit route" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .get, .path = "/health", .handler = 1 },
        .{ .method = .post, .path = "/submit", .handler = 3, .options = .{ .middleware_flags = 1 } },
    };
    const table = Table{ .entries = &entries };
    const submit = try request_mod.Request.parse(
        "POST /submit HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    );
    const submit_route = (try table.resolve(&store, submit)).handler;
    try std.testing.expectEqual(@as(Handler, 3), submit_route.id);
    try std.testing.expectEqual(@as(u32, 1), submit_route.options.middleware_flags);

    const unknown_post = try request_mod.Request.parse(
        "POST /missing HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    );
    try std.testing.expectEqual(Route.not_found, try table.resolve(&store, unknown_post));

    const post_health = try request_mod.Request.parse(
        "POST /health HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    );
    try std.testing.expectEqual(Route.not_found, try table.resolve(&store, post_health));
}

test "match cors preflight target route" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .post, .path = "/submit", .handler = 3, .options = .{ .cors = .public_form } },
    };
    const table = Table{ .entries = &entries };
    const preflight = try request_mod.Request.parse(
        "OPTIONS /submit HTTP/1.1\r\nOrigin: http://example.test\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    const route = try table.resolve(&store, preflight);
    try std.testing.expectEqual(@as(Handler, 3), route.preflight.id);
    try std.testing.expectEqual(http_config.CorsPolicy.public_form, route.preflight.options.cors);

    const missing_method = try request_mod.Request.parse(
        "OPTIONS /submit HTTP/1.1\r\nOrigin: http://example.test\r\n\r\n",
    );
    try std.testing.expectEqual(Route.method_not_allowed, try table.resolve(&store, missing_method));
}

test "match static and unsupported methods" {
    const store = static.Store.embedded();
    const entries = [_]Entry{
        .{ .method = .get, .path = "/health", .handler = 1 },
    };
    const table = Table{ .entries = &entries };
    const index = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\n\r\n");
    const route = try table.resolve(&store, index);
    if (static.embedded_available) {
        try std.testing.expectEqualStrings("/", route.static.path);
    } else {
        try std.testing.expectEqual(Route.not_found, route);
    }

    const put = try request_mod.Request.parse("PUT /health HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(Route.method_not_allowed, try table.resolve(&store, put));

    const put_missing = try request_mod.Request.parse("PUT /missing HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(Route.method_not_allowed, try table.resolve(&store, put_missing));
}

test "registry add builds exact-match route table" {
    const store = static.Store.embedded();
    var entries: [2]Entry = undefined;
    var registry = Registry.init(&entries);
    try registry.add(.get, "/custom", 2, .{ .body_limit = 128 });

    const request = try request_mod.Request.parse("GET /custom HTTP/1.1\r\nHost: test\r\n\r\n");
    const route = try registry.table().resolve(&store, request);
    try std.testing.expectEqual(@as(Handler, 2), route.handler.id);
    try std.testing.expectEqual(@as(usize, 128), route.handler.options.body_limit.?);
    try std.testing.expectEqual(PathKind.exact, entries[0].path_kind);

    const put = try request_mod.Request.parse("PUT /custom HTTP/1.1\r\nHost: test\r\n\r\n");
    try std.testing.expectEqual(Route.method_not_allowed, try registry.table().resolve(&store, put));
}

test "registry reports full table" {
    var entries: [1]Entry = undefined;
    var registry = Registry.init(&entries);
    try registry.add(.get, "/one", 1, .{});
    try std.testing.expectError(error.RouteTableFull, registry.add(.get, "/two", 2, .{}));
}
