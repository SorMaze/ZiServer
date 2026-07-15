const std = @import("std");

const cache_control = @import("cache.zig");
const cache_prewarm = @import("../core/cache_prewarm.zig");
const Context = @import("../core/context.zig").Context;
const http = @import("../core/http.zig");
const middleware = @import("../core/middleware.zig");
const page_cache = @import("../core/page_cache.zig");
const request_mod = @import("../core/request.zig");
const router = @import("../core/router.zig");

pub fn apply(ctx: *Context) !middleware.Decision {
    const strategy_profile = if (ctx.route_options.cache_strategy) |strategy| strategy.profile() else null;
    const policy = if (strategy_profile) |profile| profile.policy else ctx.route_options.page_cache;
    if (policy == .none) {
        ctx.markPageCacheBypass();
        return .next;
    }
    const scope = if (strategy_profile) |profile|
        profile.scope
    else
        page_cache.Scope.cookie_partitioned;
    if (scope == .cookie_partitioned) try ctx.addTransportHeader("Vary", "Cookie");
    const store = ctx.page_cache_store orelse {
        ctx.markPageCacheBypass();
        return .next;
    };

    var key_buffer: [page_cache.max_key_bytes]u8 = undefined;
    const key = eligibleKey(ctx.request, ctx.route_options, &key_buffer) orelse {
        ctx.markPageCacheBypass();
        return .next;
    };
    const now_ns = std.Io.Clock.awake.now(ctx.io).nanoseconds;
    if (store.acquire(ctx.io, key, now_ns)) |hit| {
        try serveHit(ctx, store, hit);
        return .stop;
    }
    ctx.markPageCacheMiss();

    if (ctx.head) return .next;
    return switch (try store.beginFill(ctx.io, key, now_ns)) {
        .leader => |token| block: {
            ctx.enablePageCacheFill(policy, token);
            break :block .next;
        },
        .hit => |hit| block: {
            try serveHit(ctx, store, hit);
            break :block .stop;
        },
        .bypass => block: {
            ctx.markPageCacheBypass();
            break :block .next;
        },
    };
}

fn serveHit(ctx: *Context, store: *page_cache.Store, hit: page_cache.Handle) !void {
    defer hit.deinit();
    ctx.markPageCacheHit();
    if (store.responseHeaderEnabled()) try ctx.addHeader("X-Page-Cache", "HIT");
    try ctx.writeBytesHead(.ok, hit.contentType(), hit.body(), ctx.head, hit.cachePolicy(), &.{});
}

fn eligibleKey(request: request_mod.Request, options: router.Options, buffer: []u8) ?[]const u8 {
    if (request.method != .get and request.method != .head) return null;
    if (options.auth != .none or options.require_auth) return null;

    var rest = request.headers;
    while (rest.len != 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Authorization") or
                std.ascii.eqlIgnoreCase(name, "Origin") or
                std.ascii.eqlIgnoreCase(name, "Range"))
            {
                return null;
            } else if (std.ascii.eqlIgnoreCase(name, "Cache-Control")) {
                if (hasDirective(value, "no-cache") or hasDirective(value, "no-store")) return null;
            } else if (std.ascii.eqlIgnoreCase(name, "Pragma") and hasDirective(value, "no-cache")) {
                return null;
            }
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return page_cache.requestKeyForScope(
        request,
        if (options.cache_strategy) |strategy|
            strategy.profile().scope
        else
            .cookie_partitioned,
        buffer,
    );
}

test "page cache eligibility is conservative" {
    const plain = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\n\r\n");
    const head = try request_mod.Request.parse("HEAD / HTTP/1.1\r\nHost: test\r\n\r\n");
    const post = try request_mod.Request.parse("POST / HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n");
    const cookie = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nCookie: session=x\r\n\r\n");
    const reload = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nCache-Control: max-age=0, NO-CACHE\r\n\r\n");
    const pragma = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nPragma: no-cache\r\n\r\n");

    var key_buffer: [page_cache.max_key_bytes]u8 = undefined;
    try std.testing.expect(eligibleKey(plain, .{}, &key_buffer) != null);
    try std.testing.expect(eligibleKey(head, .{}, &key_buffer) != null);
    try std.testing.expect(eligibleKey(post, .{}, &key_buffer) == null);
    try std.testing.expect(eligibleKey(cookie, .{}, &key_buffer) != null);
    try std.testing.expect(eligibleKey(reload, .{}, &key_buffer) == null);
    try std.testing.expect(eligibleKey(pragma, .{}, &key_buffer) == null);
    try std.testing.expect(eligibleKey(plain, .{ .auth = .bearer }, &key_buffer) == null);
    try std.testing.expect(eligibleKey(plain, .{ .require_auth = true }, &key_buffer) == null);
}

test "shared page cache scope ignores Cookie state" {
    const plain = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: test\r\n\r\n");
    const cookie = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: test\r\nCookie: session=x\r\n\r\n");
    const options = router.Options{ .cache_strategy = .static_shared };
    var plain_buffer: [page_cache.max_key_bytes]u8 = undefined;
    var cookie_buffer: [page_cache.max_key_bytes]u8 = undefined;
    const plain_key = eligibleKey(plain, options, &plain_buffer).?;
    const cookie_key = eligibleKey(cookie, options, &cookie_buffer).?;
    try std.testing.expectEqualStrings(plain_key, cookie_key);
}

test "page cache middleware serves hit without handler" {
    const response = @import("../core/response.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    var store = try page_cache.Store.init(std.testing.allocator, .{ .response_header = true });
    defer store.deinit(std.testing.io);
    const request = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: Test\r\n\r\n");
    var key_buffer: [page_cache.max_key_bytes]u8 = undefined;
    const key = page_cache.requestKey(request, &key_buffer).?;
    const now_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try store.put(std.testing.io, key, "text/html", "cached", .api_short, now_ns, .standard);

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

    try std.testing.expectEqual(middleware.Decision.stop, try apply(&ctx));
    try std.testing.expectEqual(.hit, ctx.page_cache_status);
    try std.testing.expectEqual(response.CachePolicy.api_short, ctx.response_cache_policy);
    try std.testing.expectEqualStrings("cached", capture.body_ptr.?[0..capture.body_len]);
    var found_hit = false;
    for (capture.headers[0..capture.headers_len]) |header| {
        if (std.mem.eql(u8, header.name_ptr[0..header.name_len], "x-page-cache") and
            std.mem.eql(u8, header.value_ptr[0..header.value_len], "HIT")) found_hit = true;
    }
    try std.testing.expect(found_hit);
    var found_vary_cookie = false;
    for (capture.headers[0..capture.headers_len]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name_ptr[0..header.name_len], "Vary") and
            std.ascii.eqlIgnoreCase(header.value_ptr[0..header.value_len], "Cookie")) found_vary_cookie = true;
    }
    try std.testing.expect(found_vary_cookie);
}

test "startup prewarm renders static-shared route once without synthetic hit metrics" {
    const static = @import("../core/static.zig");

    var store = try page_cache.Store.init(std.testing.allocator, .{});
    defer store.deinit(std.testing.io);
    const entries = [_]router.Entry{.{
        .method = .get,
        .path = "/warm",
        .handler = 1,
        .options = .{ .cache_strategy = .static_shared },
        .path_kind = .exact,
    }};
    const stack = [_]middleware.Middleware{.{ .name = "prewarm-test", .run = runPrewarmTestMiddleware }};
    const application = http.Application{
        .routes = .{ .entries = &entries },
        .dispatch = dispatchPrewarmTest,
        .middleware_stack = &stack,
        .page_cache = &store,
    };
    const static_store = static.Store.embedded();

    try std.testing.expectEqual(
        cache_prewarm.Outcome.cached,
        try cache_prewarm.prewarmOne(
            std.testing.io,
            std.testing.allocator,
            &application,
            &static_store,
            entries[0],
            "example.test:18080",
            false,
        ),
    );
    try std.testing.expectEqual(
        cache_prewarm.Outcome.already_cached,
        try cache_prewarm.prewarmOne(
            std.testing.io,
            std.testing.allocator,
            &application,
            &static_store,
            entries[0],
            "example.test:18080",
            false,
        ),
    );
    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries);
    try std.testing.expectEqual(@as(u64, 1), snapshot.inserts);
    try std.testing.expectEqual(@as(u64, 0), snapshot.hits);
    try std.testing.expectEqual(@as(u64, 1), snapshot.misses);
}

fn runPrewarmTestMiddleware(ctx: *Context) !middleware.Decision {
    _ = try cache_control.apply(ctx);
    return apply(ctx);
}

fn dispatchPrewarmTest(ctx: *Context, _: router.Handler) anyerror!void {
    try ctx.text(.ok, "prewarmed");
}

fn hasDirective(value: []const u8, expected: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const directive = std.mem.trim(u8, part, " \t");
        const name_end = std.mem.indexOfScalar(u8, directive, '=') orelse directive.len;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, directive[0..name_end], " \t"), expected)) return true;
    }
    return false;
}
