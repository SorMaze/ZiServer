const std = @import("std");

const client_identity = @import("client_identity.zig");
const config_mod = @import("config.zig");
const http = @import("http.zig");
const http2 = @import("http2.zig");
const http3 = @import("http3.zig");
const http_config = @import("http_config.zig");
const logger = @import("log.zig");
const page_cache = @import("page_cache.zig");
const protocol_redirect = @import("protocol_redirect.zig");
const quic_transport = @import("quic_transport.zig");
const rate_limiter_mod = @import("rate_limiter.zig");
const shutdown = @import("shutdown.zig");
const static = @import("static.zig");
const stats_mod = @import("stats.zig");
const stream_queue = @import("stream_queue.zig");
const tls = @import("tls.zig");
const transport = @import("transport.zig");

const worker_thread_stack_size = 2 * 1024 * 1024;
const acceptor_thread_stack_size = 512 * 1024;
const quic_thread_stack_size = 2 * 1024 * 1024;

const net = std.Io.net;

pub const ApplicationFactory = *const fn (
    std.mem.Allocator,
    http_config.ApplicationStartupConfig,
) anyerror!http.ApplicationBundle;

const SharedServer = struct {
    io: std.Io,
    normal_queues: *stream_queue.StreamQueueSet,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    application: *const http.Application,
    tls_context: ?*const tls.ServerContext,
    keep_alive_requests: usize,
    http2: http_config.Http2Mode,
    http3: http_config.Http3Mode,
    http_port: u16,
    https_port: u16,
    http3_port: u16,
    stopping: *std.atomic.Value(bool),
    connection_registry: *transport.ConnectionRegistry,
    tls_handshake_timeout_ms: u32,
    header_timeout_ms: u32,
    body_timeout_ms: u32,
    keep_alive_timeout_ms: u32,
    access_log_enabled: bool,
    identity_resolver: client_identity.Resolver,
    redirect_host_policy: protocol_redirect.HostPolicy,
};

const Acceptor = struct {
    shared: *SharedServer,
    server: *net.Server,
    security: stream_queue.Security,
    label: []const u8,
};

/// Process entry for the core server. Concrete app/compose construction is
/// supplied as a callback, so core never imports either higher layer.
pub fn start(init: std.process.Init, application_factory: ApplicationFactory) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    const parse_result = try config_mod.parseArgs(&args, init.environ_map);
    const config = switch (parse_result) {
        .config => |value| value,
        .exit => |code| return code,
    };

    logger.init(init.io, .{
        .min_level = config.log_level,
        .format = config.log_format,
        .color = config.log_color,
    }, if (init.environ_map.get("NO_COLOR")) |value| value.len != 0 else false);

    const identity_resolver = try config.identityResolver();
    var page_cache_store: ?page_cache.Store = if (config.page_cache_enabled)
        try page_cache.Store.init(init.gpa, config.pageCacheConfig())
    else
        null;
    defer if (page_cache_store) |*store| store.deinit(init.io);

    var rate_limiter = try rate_limiter_mod.Limiter.init(init.gpa, config.rateLimiterConfig());
    defer rate_limiter.deinit(init.io);

    shutdown.install() catch |err| {
        logger.message(init.io, .err, "shutdown_handler_install_failed", "error={t}", .{err});
        return 1;
    };

    var application_bundle = application_factory(init.gpa, .{
        .auth = config.authCredentials(init.environ_map),
        .xss_mode = config.xss_mode,
        .xss_scan_query = config.xss_scan_query,
        .xss_scan_body = config.xss_scan_body,
    }) catch |err| {
        logger.message(init.io, .err, "application_init_failed", "error={t}", .{err});
        return 1;
    };
    defer application_bundle.deinit(init.io, init.gpa);

    var application = &application_bundle.application;
    application.page_cache = if (page_cache_store) |*store| store else null;
    application.rate_limiter = &rate_limiter;

    return run(init.io, init.gpa, config, application, identity_resolver);
}

/// Owns listener, worker, transport, and graceful-shutdown lifecycle.
fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: config_mod.ServerConfig,
    application: *const http.Application,
    identity_resolver: client_identity.Resolver,
) !u8 {
    const workers = config.actualWorkers();
    const queue_capacity = config.actualQueueCapacity(workers);
    const queue_shards = config.actualQueueShards(workers);
    const redirect_host_policy = try config.redirectHostPolicy();

    var tls_context: ?tls.ServerContext = if (config.tls.mode == .terminate)
        tls.initServerContext(allocator, .{
            .provider = config.tlsProvider(),
            .tls = config.tls,
            .advertise_h2 = config.http2 == .on,
        }) catch |err| {
            logger.message(io, .err, "tls_provider_init_failed", "provider={s} error={t}", .{ config.tlsProvider().text(), err });
            if (config.tlsProvider() == .openssl) {
                if (tls.opensslLastErrorText()) |text| {
                    if (text.len != 0) logger.message(io, .err, "openssl_error", "detail={s}", .{text});
                }
            }
            return 1;
        }
    else
        null;
    defer if (tls_context) |*context| context.deinit();

    var http_server = openListener(io, config.bind_ip, config.port, config.backlog) catch |err| {
        logListenFailure(io, "HTTP", config.host, config.port, err);
        return 1;
    };
    var http_listener_open = true;
    defer if (http_listener_open) http_server.deinit(io);

    const https_enabled = tls_context != null;
    var https_server: net.Server = undefined;
    if (https_enabled) {
        https_server = openListener(io, config.bind_ip, config.https_port, config.backlog) catch |err| {
            logListenFailure(io, "HTTPS", config.host, config.https_port, err);
            return 1;
        };
    }
    var https_listener_open = https_enabled;
    defer if (https_listener_open) https_server.deinit(io);

    const http3_enabled = config.http3 == .advertise and config.tls.mode == .terminate;
    var http3_socket: quic_transport.Socket = undefined;
    if (http3_enabled and http3.linked) {
        http3_socket = quic_transport.Socket.init(io, config.bind_ip.toAddress(config.http3_port)) catch |err| {
            logListenFailure(io, "QUIC", config.host, config.http3_port, err);
            return 1;
        };
    }
    var http3_socket_open = http3_enabled and http3.linked;
    defer if (http3_socket_open) http3_socket.deinit();

    const listener_count: usize = if (https_enabled) 2 else 1;
    const acceptors = @max(config.actualAcceptors(), listener_count);
    const http_acceptors = if (https_enabled) (acceptors + 1) / 2 else acceptors;
    const https_acceptors = if (https_enabled) acceptors - http_acceptors else 0;

    var stats = stats_mod.Stats.init(config.stats_enabled);
    var static_store = switch (config.static_mode) {
        .embedded => static.Store.embedded(),
        .filesystem => static.Store.filesystem(io, allocator, config.static_dir),
    };
    var normal_queues = try stream_queue.StreamQueueSet.init(
        allocator,
        io,
        &stats,
        queue_shards,
        queue_capacity,
    );
    defer normal_queues.deinit(allocator);
    const connection_slots = try allocator.alloc(?*transport.Connection, workers);
    defer allocator.free(connection_slots);
    var connection_registry = transport.ConnectionRegistry.init(io, connection_slots);
    var stopping: std.atomic.Value(bool) = .init(false);

    logStartup(
        io,
        config,
        identity_resolver,
        https_enabled,
        http3_enabled,
        acceptors,
        http_acceptors,
        https_acceptors,
        workers,
        normal_queues.shardCount(),
        queue_capacity,
    );

    var shared = SharedServer{
        .io = io,
        .normal_queues = &normal_queues,
        .stats = &stats,
        .static_store = &static_store,
        .application = application,
        .tls_context = if (tls_context) |*context| context else null,
        .keep_alive_requests = config.keep_alive_requests,
        .http2 = config.http2,
        .http3 = config.http3,
        .http_port = config.port,
        .https_port = config.https_port,
        .http3_port = config.http3_port,
        .stopping = &stopping,
        .connection_registry = &connection_registry,
        .tls_handshake_timeout_ms = config.tls_handshake_timeout_ms,
        .header_timeout_ms = config.header_timeout_ms,
        .body_timeout_ms = config.body_timeout_ms,
        .keep_alive_timeout_ms = config.keep_alive_timeout_ms,
        .access_log_enabled = config.access_log_enabled,
        .identity_resolver = identity_resolver,
        .redirect_host_policy = redirect_host_policy,
    };

    var http_acceptor = Acceptor{
        .shared = &shared,
        .server = &http_server,
        .security = .plain,
        .label = "HTTP",
    };
    var https_acceptor = Acceptor{
        .shared = &shared,
        .server = &https_server,
        .security = .tls,
        .label = "HTTPS",
    };

    const acceptor_threads = try allocator.alloc(std.Thread, acceptors);
    defer allocator.free(acceptor_threads);
    const worker_threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(worker_threads);

    var started_workers: usize = 0;
    var started_http_acceptors: usize = 0;
    var started_https_acceptors: usize = 0;
    var startup_complete = false;
    errdefer if (!startup_complete) {
        stopping.store(true, .release);
        normal_queues.close();
        wakeAcceptors(io, config.bind_ip, config.port, started_http_acceptors);
        if (https_enabled) wakeAcceptors(io, config.bind_ip, config.https_port, started_https_acceptors);
        for (acceptor_threads[0 .. started_http_acceptors + started_https_acceptors]) |thread| thread.join();
        for (worker_threads[0..started_workers]) |thread| thread.join();
    };

    for (worker_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{ .stack_size = worker_thread_stack_size }, workerLoop, .{ &shared, i });
        started_workers += 1;
    }
    var acceptor_index: usize = 0;
    for (0..http_acceptors) |_| {
        acceptor_threads[acceptor_index] = try std.Thread.spawn(.{ .stack_size = acceptor_thread_stack_size }, acceptLoop, .{&http_acceptor});
        acceptor_index += 1;
        started_http_acceptors += 1;
    }
    for (0..https_acceptors) |_| {
        acceptor_threads[acceptor_index] = try std.Thread.spawn(.{ .stack_size = acceptor_thread_stack_size }, acceptLoop, .{&https_acceptor});
        acceptor_index += 1;
        started_https_acceptors += 1;
    }

    var quic_thread: std.Thread = undefined;
    if (http3_socket_open) {
        quic_thread = try std.Thread.spawn(.{ .stack_size = quic_thread_stack_size }, quicAcceptLoop, .{ &shared, &http3_socket });
    }
    startup_complete = true;

    while (!shutdown.requested()) {
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }

    const shutdown_start_ns = std.Io.Clock.awake.now(io).nanoseconds;
    stopping.store(true, .release);
    logger.message(io, .info, "shutdown_started", "grace_ms={d} active_connections={d}", .{
        config.shutdown_grace_ms,
        connection_registry.activeCount(),
    });

    normal_queues.close();

    // Zig's Windows threaded I/O backend treats closing a socket underneath a
    // blocking accept as unreachable. Wake each acceptor with a local TCP
    // connection instead; the stopping flag makes it close that stream without
    // dispatching work, then return.
    wakeAcceptors(io, config.bind_ip, config.port, http_acceptors);
    if (https_enabled) wakeAcceptors(io, config.bind_ip, config.https_port, https_acceptors);

    for (acceptor_threads) |thread| thread.join();
    http_server.deinit(io);
    http_listener_open = false;
    if (https_enabled) {
        https_server.deinit(io);
        https_listener_open = false;
    }
    if (http3_socket_open) {
        quic_thread.join();
        http3_socket.deinit();
        http3_socket_open = false;
    }

    const grace_ns = @as(i96, config.shutdown_grace_ms) * std.time.ns_per_ms;
    while (connection_registry.activeCount() != 0 and
        std.Io.Clock.awake.now(io).nanoseconds - shutdown_start_ns < grace_ns)
    {
        std.Io.sleep(io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch {};
    }

    const forced_connections = connection_registry.activeCount();
    if (forced_connections != 0) connection_registry.shutdownAll();
    for (worker_threads) |thread| thread.join();

    const elapsed_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds - shutdown_start_ns, std.time.ns_per_ms);
    logger.message(io, .info, "shutdown_complete", "duration_ms={d} forced_connections={d}", .{ elapsed_ms, forced_connections });

    return 0;
}

fn logStartup(
    io: std.Io,
    config: config_mod.ServerConfig,
    identity_resolver: client_identity.Resolver,
    https_enabled: bool,
    http3_enabled: bool,
    acceptors: usize,
    http_acceptors: usize,
    https_acceptors: usize,
    workers: usize,
    queue_shards: usize,
    queue_capacity: usize,
) void {
    const static_mode_text = switch (config.static_mode) {
        .embedded => "embedded",
        .filesystem => "filesystem",
    };
    const tls_backend_text = tls.backendVersionText(config.tlsProvider()) orelse "-";
    const http2_backend_text = http2.versionText() orelse "-";
    const http3_backend_text = http3.versionText() orelse "-";
    var https_address_buffer: [256]u8 = undefined;
    const https_address = if (https_enabled)
        std.fmt.bufPrint(&https_address_buffer, "https://{s}:{d}/", .{ config.host, config.https_port }) catch "enabled"
    else
        "off";
    var http3_address_buffer: [256]u8 = undefined;
    const http3_address = if (http3_enabled)
        std.fmt.bufPrint(&http3_address_buffer, "advertise:{d}", .{config.http3_port}) catch "advertise"
    else
        "off";

    logger.message(
        io,
        .info,
        "server_started",
        "http=http://{s}:{d}/ https={s} http3={s} acceptors={d} http_acceptors={d} https_acceptors={d} workers={d} shards={d} queue={d} keep_alive={d} stats={s} access_log={s} log_level={s} log_format={s} log_color={s}",
        .{
            config.host,
            config.port,
            https_address,
            http3_address,
            acceptors,
            http_acceptors,
            https_acceptors,
            workers,
            queue_shards,
            queue_capacity,
            config.keep_alive_requests,
            if (config.stats_enabled) "on" else "off",
            if (config.access_log_enabled) "on" else "off",
            config.log_level.text(),
            config.log_format.text(),
            config.log_color.text(),
        },
    );
    logger.message(
        io,
        .info,
        "timeout_config",
        "tls_handshake_ms={d} header_ms={d} body_ms={d} keep_alive_idle_ms={d} shutdown_grace_ms={d}",
        .{
            config.tls_handshake_timeout_ms,
            config.header_timeout_ms,
            config.body_timeout_ms,
            config.keep_alive_timeout_ms,
            config.shutdown_grace_ms,
        },
    );
    logger.message(
        io,
        .info,
        "page_cache_config",
        "enabled={s} capacity={d} shards={d} max_body_bytes={d} ttl_percent={d} response_header={s} fill_wait_timeout_ms={d}",
        .{
            if (config.page_cache_enabled) "on" else "off",
            config.page_cache_capacity,
            config.page_cache_shards,
            config.page_cache_max_body_bytes,
            config.page_cache_ttl_percent,
            if (config.page_cache_response_header) "on" else "off",
            config.page_cache_fill_wait_timeout_ms,
        },
    );
    logger.message(
        io,
        .info,
        "rate_limit_config",
        "relaxed_rps={d} strict_rps={d} capacity={d} shards={d} idle_ttl_ms={d}",
        .{
            config.rate_limit_relaxed_rps,
            config.rate_limit_strict_rps,
            config.rate_limit_capacity,
            config.rate_limit_shards,
            config.rate_limit_idle_ttl_ms,
        },
    );
    logger.message(
        io,
        .info,
        "client_identity_config",
        "header={s} trusted_proxies={d} forwarded_max_hops={d}",
        .{ config.client_ip_header.text(), identity_resolver.trustedCount(), config.forwarded_max_hops },
    );
    const redirect_policy = config.redirectHostPolicy() catch protocol_redirect.HostPolicy{};
    logger.message(
        io,
        .info,
        "redirect_host_config",
        "canonical={s} allowed={d} fallback={s}",
        .{
            redirect_policy.canonical_host orelse "-",
            redirect_policy.allowed_hosts.len,
            redirect_policy.fallback_host orelse "-",
        },
    );
    logger.message(
        io,
        .info,
        "protocol_config",
        "xss_mode={s} xss_scan_query={s} xss_scan_body={s} static={s} static_dir={s} tls={s} tls_min={s} tls_provider={s} tls_backend=\"{s}\" http2={s} http2_backend=\"{s}\" http3={s} http3_backend=\"{s}\" protocol_redirect={s}",
        .{
            config.xss_mode.text(),
            if (config.xss_scan_query) "on" else "off",
            if (config.xss_scan_body) "on" else "off",
            static_mode_text,
            if (config.static_mode == .filesystem) config.static_dir else "embedded",
            config.tls.mode.text(),
            config.tls.min_version.text(),
            config.tlsProvider().text(),
            tls_backend_text,
            config.http2.text(),
            http2_backend_text,
            config.http3.text(),
            http3_backend_text,
            if (https_enabled) "on" else "off",
        },
    );
}

fn openListener(io: std.Io, bind_ip: client_identity.IpKey, port: u16, backlog: u31) !net.Server {
    return bind_ip.toAddress(port).listen(io, .{
        .kernel_backlog = backlog,
        .reuse_address = true,
    });
}

fn logListenFailure(io: std.Io, label: []const u8, host: []const u8, port: u16, err: anyerror) void {
    logger.message(
        io,
        .err,
        "listen_failed",
        "listener={s} address={s}:{d} error={t}; Windows hint: try another port or an elevated PowerShell when binding a reserved/public address",
        .{ label, host, port, err },
    );
}

fn acceptLoop(acceptor: *Acceptor) void {
    const shared = acceptor.shared;
    while (true) {
        const stream = acceptor.server.accept(shared.io) catch |err| {
            if (shared.stopping.load(.acquire)) return;
            logger.message(shared.io, .err, "accept_failed", "listener={s} error={t}", .{ acceptor.label, err });
            continue;
        };
        if (shared.stopping.load(.acquire)) {
            transport.closeStream(shared.io, stream);
            return;
        }
        shared.normal_queues.put(.{
            .stream = stream,
            .security = acceptor.security,
            .peer_ip = client_identity.IpKey.fromAddress(stream.socket.address),
        }) catch |err| {
            transport.closeStream(shared.io, stream);
            switch (err) {
                error.Closed => return,
                error.Canceled => continue,
            }
        };
    }
}

fn wakeAcceptors(io: std.Io, bind_ip: client_identity.IpKey, port: u16, count: usize) void {
    const wake_ip = acceptorWakeIp(bind_ip);
    const address = wake_ip.toAddress(port);
    var wake_host_buffer: [64]u8 = undefined;
    const wake_host = wake_ip.format(&wake_host_buffer) catch "invalid";
    for (0..count) |_| {
        const stream = address.connect(io, .{ .mode = .stream }) catch |err| {
            logger.message(io, .warn, "acceptor_wake_failed", "address={s}:{d} error={t}", .{ wake_host, port, err });
            return;
        };
        transport.closeStream(io, stream);
    }
}

fn acceptorWakeIp(bind_ip: client_identity.IpKey) client_identity.IpKey {
    return if (bind_ip.isUnspecified()) client_identity.IpKey.loopbackFor(bind_ip.family) else bind_ip;
}

test "acceptor wake maps every unspecified spelling to same-family loopback" {
    const expanded = try client_identity.IpKey.parse("0:0:0:0:0:0:0:0");
    const wake_ip = acceptorWakeIp(expanded);
    try std.testing.expectEqual(client_identity.Family.ip6, wake_ip.family);
    try std.testing.expect(wake_ip.eql(try client_identity.IpKey.parse("::1")));
    try std.testing.expect(acceptorWakeIp(try client_identity.IpKey.parse("0.0.0.0")).eql(client_identity.IpKey.loopback()));
}

fn workerLoop(shared: *SharedServer, worker_index: usize) void {
    while (true) {
        const pending = shared.normal_queues.take(worker_index) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => continue,
        };
        if (shared.stopping.load(.acquire)) {
            transport.closeStream(shared.io, pending.stream);
            continue;
        }
        const use_tls = pending.security == .tls;
        http.serveConnection(shared.io, pending.stream, shared.stats, shared.static_store, shared.application, .{
            .keep_alive_requests = shared.keep_alive_requests,
            .http2 = if (use_tls) shared.http2 else .reject,
            .tls_context = shared.tls_context,
            .http3 = shared.http3,
            .http3_port = shared.http3_port,
            .listener_tls = use_tls,
            .protocol_redirect_ports = if (shared.tls_context != null) .{
                .http = shared.http_port,
                .https = shared.https_port,
            } else null,
            .protocol_redirect_host_policy = shared.redirect_host_policy,
            .tls_handshake_timeout_ms = shared.tls_handshake_timeout_ms,
            .header_timeout_ms = shared.header_timeout_ms,
            .body_timeout_ms = shared.body_timeout_ms,
            .keep_alive_timeout_ms = shared.keep_alive_timeout_ms,
            .stopping = shared.stopping,
            .connection_registry = shared.connection_registry,
            .worker_index = worker_index,
            .access_log_enabled = shared.access_log_enabled,
            .peer_ip = pending.peer_ip,
            .identity_resolver = shared.identity_resolver,
        });
    }
}

fn quicAcceptLoop(shared: *SharedServer, socket: *quic_transport.Socket) void {
    const ssl_handle: ?*anyopaque = if (shared.tls_context) |ctx| ctx.handle else null;
    var dispatch_state = http.Http3DispatchState{
        .io = shared.io,
        .stats = shared.stats,
        .static_store = shared.static_store,
        .app = shared.application,
        .access_log_enabled = shared.access_log_enabled,
        .identity_resolver = shared.identity_resolver,
    };

    while (!shared.stopping.load(.acquire)) {
        const summary = http3.serve(
            socket,
            &dispatch_state,
            http.dispatchHttp3Request,
            shared.keep_alive_requests,
            ssl_handle,
            shared.stopping,
        ) catch {
            std.Io.sleep(shared.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        logger.message(shared.io, .info, "http3_session_closed", "protocol=h3 requests={d} highest_stream_id={d} goaway={s}", .{
            summary.requests,
            summary.highest_stream_id,
            if (summary.sentGoaway()) "yes" else "no",
        });
    }
}
