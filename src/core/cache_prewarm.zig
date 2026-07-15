const std = @import("std");

const Context = @import("context.zig").Context;
const client_identity = @import("client_identity.zig");
const config_mod = @import("config.zig");
const http = @import("http.zig");
const logger = @import("log.zig");
const middleware = @import("middleware.zig");
const page_cache = @import("page_cache.zig");
const protocol_redirect = @import("protocol_redirect.zig");
const request_mod = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const static = @import("static.zig");
const stats_mod = @import("stats.zig");

pub const Outcome = enum {
    cached,
    already_cached,
    not_cached,
};

pub const RunArgs = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const config_mod.ServerConfig,
    application: *const http.Application,
    static_store: *const static.Store,
    stopping: *const std.atomic.Value(bool),
};

const Summary = struct {
    attempted: usize = 0,
    cached: usize = 0,
    already_cached: usize = 0,
    not_cached: usize = 0,
    failed: usize = 0,
};

pub fn eligibleRoute(entry: router.Entry) bool {
    const path_kind = if (entry.path_kind == .auto) router.classifyPath(entry.path) else entry.path_kind;
    return entry.method == .get and
        path_kind == .exact and
        entry.options.cache_strategy == .static_shared and
        entry.options.auth == .none and
        !entry.options.require_auth;
}

pub fn eligibleRouteCount(application: *const http.Application) usize {
    var count: usize = 0;
    for (application.routes.entries) |entry| {
        if (eligibleRoute(entry)) count += 1;
    }
    return count;
}

pub fn hostCount(config: *const config_mod.ServerConfig) usize {
    if (config.canonical_host != null) return 1;
    if (config.allowed_host_count != 0) return config.allowed_host_count;
    return @intFromBool(!config.bind_ip.isUnspecified());
}

pub fn run(args: RunArgs) void {
    const route_count = eligibleRouteCount(args.application);
    const configured_host_count = hostCount(args.config);
    if (route_count == 0) {
        logger.message(args.io, .info, "page_cache_prewarm_skipped", "reason=no_static_shared_routes", .{});
        return;
    }
    if (configured_host_count == 0) {
        logger.message(args.io, .warn, "page_cache_prewarm_skipped", "reason=no_resolvable_host routes={d}", .{route_count});
        return;
    }

    const start_ns = std.Io.Clock.awake.now(args.io).nanoseconds;
    logger.message(args.io, .info, "page_cache_prewarm_started", "routes={d} hosts={d}", .{ route_count, configured_host_count });
    var summary = Summary{};

    if (args.config.canonical_host) |host| {
        warmHost(args, host, &summary);
    } else if (args.config.allowed_host_count != 0) {
        for (args.config.allowed_hosts[0..args.config.allowed_host_count]) |host| {
            if (args.stopping.load(.acquire)) break;
            warmHost(args, host, &summary);
        }
    } else {
        warmHost(args, args.config.host, &summary);
    }

    const elapsed_ms = @divFloor(std.Io.Clock.awake.now(args.io).nanoseconds - start_ns, std.time.ns_per_ms);
    logger.message(
        args.io,
        if (summary.failed == 0 and summary.not_cached == 0) .info else .warn,
        "page_cache_prewarm_complete",
        "attempted={d} cached={d} already_cached={d} not_cached={d} failed={d} duration_ms={d}",
        .{ summary.attempted, summary.cached, summary.already_cached, summary.not_cached, summary.failed, elapsed_ms },
    );
}

fn warmHost(args: RunArgs, host: []const u8, summary: *Summary) void {
    const secure = args.config.tls.mode == .terminate;
    const port = if (secure) args.config.https_port else args.config.port;
    const omit_port = (secure and port == 443) or (!secure and port == 80);
    var authority_buffer: [320]u8 = undefined;
    const authority = protocol_redirect.formatConfiguredAuthority(&authority_buffer, host, port, omit_port) catch |err| {
        summary.failed += eligibleRouteCount(args.application);
        logger.message(args.io, .warn, "page_cache_prewarm_host_failed", "host={s} error={t}", .{ host, err });
        return;
    };

    for (args.application.routes.entries) |entry| {
        if (args.stopping.load(.acquire)) return;
        if (!eligibleRoute(entry)) continue;
        summary.attempted += 1;
        const outcome = prewarmOne(
            args.io,
            args.allocator,
            args.application,
            args.static_store,
            entry,
            authority,
            secure,
        ) catch |err| {
            summary.failed += 1;
            logger.message(args.io, .warn, "page_cache_prewarm_path_failed", "host={s} path={s} error={t}", .{ authority, entry.path, err });
            continue;
        };
        switch (outcome) {
            .cached => summary.cached += 1,
            .already_cached => summary.already_cached += 1,
            .not_cached => {
                summary.not_cached += 1;
                logger.message(args.io, .warn, "page_cache_prewarm_path_skipped", "host={s} path={s} reason=response_not_cacheable", .{ authority, entry.path });
            },
        }
    }
}

pub fn prewarmOne(
    io: std.Io,
    allocator: std.mem.Allocator,
    application: *const http.Application,
    static_store: *const static.Store,
    entry: router.Entry,
    authority: []const u8,
    secure: bool,
) !Outcome {
    if (!eligibleRoute(entry)) return error.RouteNotPrewarmable;
    const store = application.page_cache orelse return error.PageCacheDisabled;

    var raw_buffer: [page_cache.max_key_bytes + 512]u8 = undefined;
    const raw = std.fmt.bufPrint(
        &raw_buffer,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: ZiServer-Prewarm/1\r\n\r\n",
        .{ entry.path, authority },
    ) catch return error.PrewarmRequestTooLarge;
    const request = try request_mod.Request.parse(raw);
    var key_buffer: [page_cache.max_key_bytes]u8 = undefined;
    const key = page_cache.requestKeyForScope(request, .shared, &key_buffer) orelse return error.PrewarmCacheKeyTooLarge;
    const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
    if (store.contains(io, key, now_ns)) return .already_cached;

    var capture = response.Capture{};
    defer capture.deinit(allocator);
    var target: response.Target = .{ .capture = .{
        .response = &capture,
        .allocator = allocator,
        .secure = secure,
    } };
    var prewarm_stats = stats_mod.Stats.init(false);
    var options = entry.options;
    options.rate_limit = .none;
    var ctx = Context.init(
        io,
        &target,
        request,
        &prewarm_stats,
        static_store,
        false,
        options,
        router.Params.empty(),
        application.auth,
        application.services,
        store,
    );
    ctx.setClientIdentity(client_identity.ClientIdentity.direct(client_identity.IpKey.loopback()));
    ctx.setRateLimiter(application.rate_limiter);
    defer ctx.deinit();
    defer ctx.finishPageCacheFill();

    const decision = try middleware.run(&ctx, application.middleware_stack);
    if (decision == .next) try application.dispatch(&ctx, entry.handler);

    if (store.contains(io, key, std.Io.Clock.awake.now(io).nanoseconds)) {
        return if (ctx.page_cache_status == .hit) .already_cached else .cached;
    }
    return .not_cached;
}

test "prewarm route selection is limited to exact public static-shared GET routes" {
    const eligible = router.Entry{
        .method = .get,
        .path = "/about",
        .handler = 1,
        .options = .{ .cache_strategy = .static_shared },
        .path_kind = .exact,
    };
    try std.testing.expect(eligibleRoute(eligible));

    var dynamic = eligible;
    dynamic.path_kind = .dynamic;
    try std.testing.expect(!eligibleRoute(dynamic));
    var inferred_exact = eligible;
    inferred_exact.path_kind = .auto;
    try std.testing.expect(eligibleRoute(inferred_exact));
    var authenticated = eligible;
    authenticated.options.require_auth = true;
    try std.testing.expect(!eligibleRoute(authenticated));
    var recommended = eligible;
    recommended.options.cache_strategy = .recommended;
    try std.testing.expect(!eligibleRoute(recommended));
}
