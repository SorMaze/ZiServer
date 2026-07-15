const std = @import("std");

const Context = @import("context.zig").Context;
const client_identity = @import("client_identity.zig");
const errors = @import("errors.zig");
const middleware = @import("middleware.zig");
const page_cache = @import("page_cache.zig");
const http_config = @import("http_config.zig");
const http2 = @import("http2.zig");
const http3 = @import("http3.zig");
const http1_body_stream = @import("http1_body_stream.zig");
const logger = @import("log.zig");
const protocol = @import("protocol.zig");
const protocol_redirect = @import("protocol_redirect.zig");
const request_mod = @import("request.zig");
const rate_limiter_mod = @import("rate_limiter.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const services = @import("services.zig");
const static = @import("static.zig");
const stats_mod = @import("stats.zig");
const streaming = @import("streaming.zig");
const tls = @import("tls.zig");
const transport = @import("transport.zig");

pub const DispatchFn = *const fn (*Context, router.Handler) anyerror!void;

pub const Application = struct {
    routes: router.Table,
    dispatch: DispatchFn,
    middleware_stack: []const middleware.Middleware = &.{},
    auth: http_config.AuthCredentials = .{},
    page_cache: ?*page_cache.Store = null,
    services: services.Registry = .{},
    rate_limiter: ?*rate_limiter_mod.Limiter = null,
};

/// Owns an application and any app-specific resources created alongside it.
/// The optional callback is invoked exactly once by the core server before
/// core-owned services and the process allocator are released.
pub const ApplicationBundle = struct {
    application: Application,
    state: ?*anyopaque = null,
    deinit_fn: ?DeinitFn = null,

    pub const DeinitFn = *const fn (*ApplicationBundle, std.Io, std.mem.Allocator) void;

    pub fn deinit(self: *ApplicationBundle, io: std.Io, allocator: std.mem.Allocator) void {
        const callback = self.deinit_fn orelse return;
        self.deinit_fn = null;
        callback(self, io, allocator);
    }
};

test "application bundle invokes its resource destructor once" {
    var calls: usize = 0;
    var bundle = ApplicationBundle{
        .application = .{
            .routes = .{ .entries = &.{} },
            .dispatch = struct {
                fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
            }.dispatch,
        },
        .state = &calls,
        .deinit_fn = struct {
            fn deinit(value: *ApplicationBundle, _: std.Io, _: std.mem.Allocator) void {
                const counter: *usize = @ptrCast(@alignCast(value.state orelse return));
                counter.* += 1;
                value.state = null;
            }
        }.deinit,
    };

    bundle.deinit(std.testing.io, std.testing.allocator);
    bundle.deinit(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(bundle.state == null);
}

pub const ProtocolRedirectPorts = struct {
    http: u16,
    https: u16,
};

pub const ServeOptions = struct {
    keep_alive_requests: usize = 0,
    http2: http_config.Http2Mode = .reject,
    tls_context: ?*const tls.ServerContext = null,
    http3: http_config.Http3Mode = .off,
    http3_port: u16 = 443,
    listener_tls: bool = false,
    protocol_redirect_ports: ?ProtocolRedirectPorts = null,
    protocol_redirect_host_policy: protocol_redirect.HostPolicy = .{},
    connection_is_tls: bool = false,
    tls_handshake_timeout_ms: u32 = 10_000,
    header_timeout_ms: u32 = 10_000,
    body_timeout_ms: u32 = 30_000,
    keep_alive_timeout_ms: u32 = 15_000,
    stopping: ?*const std.atomic.Value(bool) = null,
    connection_registry: ?*transport.ConnectionRegistry = null,
    worker_index: usize = 0,
    access_log_enabled: bool = true,
    peer_ip: client_identity.IpKey = client_identity.IpKey.unspecified(),
    identity_resolver: client_identity.Resolver = .{},
};

const RequestAction = enum {
    keep_alive,
    close,
};

const Http2DispatchState = struct {
    io: std.Io,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
    http3: http_config.Http3Mode,
    http3_port: u16,
    access_log_enabled: bool,
    peer_ip: client_identity.IpKey,
    identity_resolver: client_identity.Resolver,
    redirect_destination: ?protocol_redirect.Destination = null,
    redirect_host_policy: protocol_redirect.HostPolicy = .{},
};

pub const Http3DispatchState = struct {
    io: std.Io,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
    access_log_enabled: bool,
    identity_resolver: client_identity.Resolver,
};

pub fn serveConnection(
    io: std.Io,
    stream: transport.Stream,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
    options: ServeOptions,
) void {
    handleConnection(io, stream, stats, static_store, app, options) catch |err| {
        switch (err) {
            error.WriteFailed,
            error.ConnectionResetByPeer,
            error.Canceled,
            error.RequestHeaderTooLarge,
            => {},
            else => if (std.mem.eql(u8, @errorName(err), "TlsHandshakeTimeout"))
                logger.message(io, .warn, "tls_handshake_timeout", "deadline exceeded", .{})
            else
                logger.message(io, .err, "connection_failed", "error={t}", .{err}),
        }
    };
}

fn isSilentInitialConnectionEnd(err: anyerror) bool {
    return err == error.ReadTimeout or
        err == error.ConnectionResetByPeer or
        err == error.GracefulShutdown or
        err == error.Canceled;
}

test "an idle initial protocol probe is not a connection failure" {
    try std.testing.expect(isSilentInitialConnectionEnd(error.ReadTimeout));
    try std.testing.expect(isSilentInitialConnectionEnd(error.ConnectionResetByPeer));
    try std.testing.expect(!isSilentInitialConnectionEnd(error.RequestTimeout));
}

fn handleConnection(
    io: std.Io,
    stream: transport.Stream,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
    serve_opts: ServeOptions,
) !void {
    var connection = transport.Connection.init(io, stream);
    if (serve_opts.connection_registry) |registry| {
        registry.register(serve_opts.worker_index, &connection);
    }
    defer {
        if (serve_opts.connection_registry) |registry| {
            registry.unregister(serve_opts.worker_index, &connection);
        }
        connection.close();
    }

    if (isStopping(serve_opts.stopping)) return;

    const redirect_destination = if (serve_opts.protocol_redirect_ports) |ports| block: {
        connection.setReadTimeoutMs(if (serve_opts.listener_tls)
            serve_opts.tls_handshake_timeout_ms
        else
            serve_opts.header_timeout_ms);
        var probe: [8]u8 = undefined;
        const probe_len = connection.peek(&probe) catch |err| {
            // Browsers commonly open speculative connections for subresources,
            // then send no bytes when the request is satisfied elsewhere.
            // Before the first byte arrives this is an idle preconnect, not a
            // failed HTTP or TLS request.
            if (isSilentInitialConnectionEnd(err)) return;
            return err;
        };
        const incoming = protocol.detect(probe[0..probe_len]);
        if (serve_opts.listener_tls and incoming == .http1) {
            break :block protocol_redirect.Destination{ .scheme = .http, .port = ports.http };
        }
        if (!serve_opts.listener_tls and incoming == .tls_client_hello) {
            break :block protocol_redirect.Destination{ .scheme = .https, .port = ports.https };
        }
        break :block null;
    } else null;

    const is_tls = if (redirect_destination) |destination|
        destination.scheme == .https
    else
        serve_opts.listener_tls;
    if (is_tls) {
        connection.setReadTimeoutMs(serve_opts.tls_handshake_timeout_ms);
        const tls_context = serve_opts.tls_context orelse return error.TlsContextUnavailable;
        try connection.enableTls(tls_context);
    }

    const negotiated_protocol = connection.negotiatedProtocol();
    if (is_tls) {
        logTlsHandshake(
            io,
            connection.tlsVersionText() orelse "-",
            connection.tlsCipherText() orelse "-",
            negotiated_protocol,
            connection.tlsSessionReused(),
        );
    }

    if (negotiated_protocol == .h2) {
        if (redirect_destination == null and serve_opts.http2 != .on) return error.Http2ProviderUnavailable;
        var h2_state = Http2DispatchState{
            .io = io,
            .stats = stats,
            .static_store = static_store,
            .app = app,
            .http3 = serve_opts.http3,
            .http3_port = serve_opts.http3_port,
            .access_log_enabled = serve_opts.access_log_enabled,
            .peer_ip = serve_opts.peer_ip,
            .identity_resolver = serve_opts.identity_resolver,
            .redirect_destination = redirect_destination,
            .redirect_host_policy = serve_opts.protocol_redirect_host_policy,
        };
        const summary = try http2.serve(
            &connection,
            &h2_state,
            dispatchHttp2Request,
            serve_opts.keep_alive_requests,
            serve_opts.body_timeout_ms,
            serve_opts.keep_alive_timeout_ms,
            serve_opts.stopping,
        );
        logHttp2Session(io, summary);
        return;
    }

    if (redirect_destination) |destination| {
        try serveProtocolRedirectHttp1(
            io,
            &connection,
            destination,
            serve_opts.protocol_redirect_host_policy,
            serve_opts.header_timeout_ms,
            serve_opts.stopping,
            serve_opts.access_log_enabled,
            serve_opts.peer_ip,
        );
        return;
    }

    var writer_buffer: [4096]u8 = undefined;
    var writer = connection.writer(&writer_buffer);
    var response_target: response.Target = .{ .http1 = &writer };
    var request_buffer: [http_config.max_request_bytes]u8 = undefined;
    var buffered: usize = 0;
    var handled: usize = 0;
    const direct_identity = client_identity.ClientIdentity.direct(serve_opts.peer_ip);

    while (true) {
        if (isStopping(serve_opts.stopping)) return;
        if (serve_opts.keep_alive_requests != 0 and handled >= serve_opts.keep_alive_requests) return;

        const read_start_ns = nowNs(io);
        const read_result = (readRequest(
            &connection,
            &request_buffer,
            &buffered,
            app,
            handled == 0,
            serve_opts.header_timeout_ms,
            serve_opts.body_timeout_ms,
            serve_opts.keep_alive_timeout_ms,
            serve_opts.stopping,
        ) catch |err| switch (err) {
            error.BadRequest => {
                const summary = try errors.write(
                    &response_target,
                    .bad_request,
                    false,
                    false,
                );
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "BAD", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.RequestBodyTooLarge => {
                const summary = try errors.write(
                    &response_target,
                    .payload_too_large,
                    false,
                    false,
                );
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "BODY", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.RequestHeaderTooLarge => {
                const summary = try errors.write(
                    &response_target,
                    .header_too_large,
                    false,
                    false,
                );
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "HEADER", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.SlowRequest => {
                const summary = try errors.write(
                    &response_target,
                    .request_timeout,
                    false,
                    false,
                );
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "SLOW", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.RequestTimeout => {
                const summary = try errors.write(
                    &response_target,
                    .request_timeout,
                    false,
                    false,
                );
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "TIMEOUT", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.ExpectationFailed => {
                const summary = try errors.write(&response_target, .expectation_failed, false, false);
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "EXPECT", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.Http2Preface => {
                const kind: errors.Kind = if (http2.shouldRejectPreface(serve_opts.http2))
                    .http_version_not_supported
                else
                    .bad_request;
                const summary = try errors.write(&response_target, kind, false, false);
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "VERSION", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.UnsupportedHttpVersion => {
                const summary = try errors.write(&response_target, .http_version_not_supported, false, false);
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "VERSION", "-", summary.status, summary.body_bytes, read_start_ns, direct_identity);
                return;
            },
            error.TlsHandshakeOnPlainHttp => {
                logRequestParts(serve_opts.access_log_enabled, io, "http/1.1", "TLS", "-", .bad_request, 0, read_start_ns, direct_identity);
                return;
            },
            else => return err,
        }) orelse return;
        const close_due_to_limit = serve_opts.keep_alive_requests == 0 or
            handled + 1 >= serve_opts.keep_alive_requests;

        var per_request_opts = serve_opts;
        per_request_opts.connection_is_tls = is_tls;
        var live_source: http1_body_stream.Source = undefined;
        const body_reader: ?streaming.Reader = if (read_result.live_body) |plan| block: {
            live_source = http1_body_stream.Source.init(
                &connection,
                request_buffer[plan.header_bytes..buffered],
                plan.content_length,
                plan.chunked,
                plan.body_limit,
                serve_opts.stopping,
            );
            break :block streaming.Reader.pull(&live_source, http1_body_stream.Source.readerFn);
        } else null;
        const action = try serveRequest(
            &response_target,
            io,
            read_result.raw_request,
            read_result.handler,
            stats,
            static_store,
            app,
            serve_opts.keep_alive_requests != 0,
            close_due_to_limit,
            "http/1.1",
            per_request_opts,
            body_reader,
        );
        handled += 1;

        const consumed_bytes = if (read_result.live_body) |plan| block: {
            connection.setReadTimeoutMs(0);
            if (!live_source.finished) return;
            break :block plan.header_bytes + live_source.consumedInitial();
        } else read_result.consumed_bytes;

        switch (action) {
            .keep_alive => {
                consumeRequest(&request_buffer, &buffered, consumed_bytes);
                if (isStopping(serve_opts.stopping)) return;
                continue;
            },
            .close => return,
        }
    }
}

fn dispatchHttp2Request(
    userdata: ?*anyopaque,
    h2_request: *const http2.Request,
    captured_response: *response.Capture,
    body_reader: ?streaming.Reader,
    output_queue: *streaming.ByteQueue,
    headers_ready: *std.atomic.Value(bool),
    response_wake: ?response.H2Wake,
    response_wake_userdata: ?*anyopaque,
) !void {
    const state: *Http2DispatchState = @ptrCast(@alignCast(userdata orelse return error.Http2DispatchFailed));
    const method = h2_request.method();
    const path = h2_request.path();
    if (h2_request.error_status != 0) {
        return switch (h2_request.error_status) {
            413 => error.RequestBodyTooLarge,
            431 => error.RequestHeaderTooLarge,
            else => error.BadRequest,
        };
    }
    // The adapter starts dispatch as soon as HEADERS arrives and continues
    // feeding DATA into a bounded queue. Once that queue exists, every exit
    // path must consume it through END_STREAM; otherwise an early validation
    // failure can leave the session thread blocked in ByteQueue.push.
    defer drainHttp2RequestBody(state.io, body_reader);
    if (method.len == 0 or path.len == 0) return error.BadRequest;

    if (state.redirect_destination) |destination| {
        const start_ns = nowNs(state.io);
        const authority = h2_request.authority();
        if (authority.len == 0) return error.BadRequest;
        var target: response.Target = .{ .h2_stream = .{
            .response = captured_response,
            .allocator = http2.capture_allocator,
            .secure = true,
            .io = state.io,
            .output = output_queue,
            .headers_ready = headers_ready,
            .wake_userdata = response_wake_userdata,
            .wake = response_wake,
        } };
        var location_buffer: [http_config.max_header_bytes + 64]u8 = undefined;
        const location = protocol_redirect.resolveLocation(
            &location_buffer,
            authority,
            path,
            destination,
            state.redirect_host_policy,
        ) catch {
            const summary = try errors.write(&target, .bad_request, false, false);
            logRequestParts(
                state.access_log_enabled,
                state.io,
                "h2",
                method,
                path,
                summary.status,
                summary.body_bytes,
                start_ns,
                client_identity.ClientIdentity.direct(state.peer_ip),
            );
            return;
        };
        const body_bytes = try protocol_redirect.write(&target, method, location);
        logRequestPartsCached(
            state.access_log_enabled,
            state.io,
            "h2",
            method,
            path,
            .permanent_redirect,
            body_bytes,
            start_ns,
            .{ .response_policy = .no_cache },
            client_identity.ClientIdentity.direct(state.peer_ip),
        );
        return;
    }

    var raw_buffer: [http_config.max_request_bytes]u8 = undefined;
    var cursor: usize = 0;
    try appendFormatted(&raw_buffer, &cursor, "{s} {s} HTTP/1.1\r\n", .{ method, path });

    var has_host = false;
    var has_content_length = false;
    var declared_content_length: ?usize = null;
    for (h2_request.headers()) |header| {
        const name = header.name_ptr[0..header.name_len];
        const value = header.value_ptr[0..header.value_len];
        if (containsLineBreak(name) or containsLineBreak(value)) return error.BadRequest;
        if (std.ascii.eqlIgnoreCase(name, "host")) has_host = true;
        if (std.ascii.eqlIgnoreCase(name, http_config.HeaderName.content_length)) {
            if (has_content_length) return error.BadRequest;
            has_content_length = true;
            declared_content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        }
        if (isConnectionSpecificHeader(name)) continue;
        try appendFormatted(&raw_buffer, &cursor, "{s}: {s}\r\n", .{ name, value });
    }

    const authority = h2_request.authority();
    if (!has_host and authority.len != 0) {
        if (containsLineBreak(authority)) return error.BadRequest;
        try appendFormatted(&raw_buffer, &cursor, "Host: {s}\r\n", .{authority});
    }
    try appendSlice(&raw_buffer, &cursor, "\r\n");
    const header_bytes = cursor;
    const header_request = try request_mod.Request.parse(raw_buffer[0..header_bytes]);
    const resolved_handler = state.app.routes.resolveHandler(header_request);
    const live_body = resolved_handler != null and resolved_handler.?.options.streaming_body;
    var selected_reader: ?streaming.Reader = null;
    if (live_body) {
        selected_reader = body_reader;
    } else {
        const initial_body = h2_request.body();
        try appendSlice(&raw_buffer, &cursor, initial_body);
        var total_body = initial_body.len;
        if (body_reader) |reader_value| {
            var reader = reader_value;
            reader.setLimits(routeBodyLimit(resolved_handler), declared_content_length);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const amount = try reader.read(&chunk);
                if (amount == 0) break;
                try appendSlice(&raw_buffer, &cursor, chunk[0..amount]);
                total_body += amount;
            }
        }
        if (declared_content_length) |declared| {
            if (declared != total_body) return error.BadRequest;
        }
    }

    var target: response.Target = .{ .h2_stream = .{
        .response = captured_response,
        .allocator = http2.capture_allocator,
        .secure = true,
        .io = state.io,
        .output = output_queue,
        .headers_ready = headers_ready,
        .wake_userdata = response_wake_userdata,
        .wake = response_wake,
    } };
    _ = try serveRequest(
        &target,
        state.io,
        raw_buffer[0..cursor],
        resolved_handler,
        state.stats,
        state.static_store,
        state.app,
        false,
        true,
        "h2",
        .{
            .http3 = state.http3,
            .http3_port = state.http3_port,
            .connection_is_tls = true,
            .access_log_enabled = state.access_log_enabled,
            .peer_ip = state.peer_ip,
            .identity_resolver = state.identity_resolver,
        },
        selected_reader,
    );
}

pub fn dispatchHttp3Request(
    userdata: ?*anyopaque,
    h3_request: *const http3.Request,
    captured_response: *response.Capture,
    peer_ip: client_identity.IpKey,
) !void {
    const state: *Http3DispatchState = @ptrCast(@alignCast(userdata orelse return error.Http3DispatchFailed));
    if (h3_request.error_status != 0) {
        return switch (h3_request.error_status) {
            413 => error.RequestBodyTooLarge,
            431 => error.RequestHeaderTooLarge,
            else => error.BadRequest,
        };
    }

    const method = h3_request.method();
    const path = h3_request.path();
    const authority = h3_request.authority();
    if (method.len == 0 or path.len == 0 or authority.len == 0) return error.BadRequest;
    if (containsLineBreak(method) or containsLineBreak(path) or containsLineBreak(authority)) return error.BadRequest;

    var raw_buffer: [http_config.max_request_bytes]u8 = undefined;
    var cursor: usize = 0;
    try appendFormatted(&raw_buffer, &cursor, "{s} {s} HTTP/1.1\r\n", .{ method, path });

    var has_host = false;
    var declared_content_length: ?usize = null;
    for (h3_request.headers()) |header| {
        const name = header.name_ptr[0..header.name_len];
        const value = header.value_ptr[0..header.value_len];
        if (containsLineBreak(name) or containsLineBreak(value)) return error.BadRequest;
        if (name.len != 0 and name[0] == ':') return error.BadRequest;
        if (isConnectionSpecificHeader(name)) return error.BadRequest;
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (has_host or !std.ascii.eqlIgnoreCase(value, authority)) return error.BadRequest;
            has_host = true;
        }
        if (std.ascii.eqlIgnoreCase(name, http_config.HeaderName.content_length)) {
            if (declared_content_length != null) return error.BadRequest;
            declared_content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        }
        try appendFormatted(&raw_buffer, &cursor, "{s}: {s}\r\n", .{ name, value });
    }
    if (!has_host) try appendFormatted(&raw_buffer, &cursor, "Host: {s}\r\n", .{authority});
    try appendSlice(&raw_buffer, &cursor, "\r\n");

    const body = h3_request.body();
    if (declared_content_length) |declared| if (declared != body.len) return error.BadRequest;
    const header_request = try request_mod.Request.parse(raw_buffer[0..cursor]);
    const resolved_handler = state.app.routes.resolveHandler(header_request);
    const live_body = resolved_handler != null and resolved_handler.?.options.streaming_body;
    if (!live_body) try appendSlice(&raw_buffer, &cursor, body);

    var target: response.Target = .{ .capture = .{
        .response = captured_response,
        .allocator = http3.capture_allocator,
        .secure = true,
    } };
    _ = try serveRequest(
        &target,
        state.io,
        raw_buffer[0..cursor],
        resolved_handler,
        state.stats,
        state.static_store,
        state.app,
        false,
        true,
        "h3",
        .{
            .http3 = .off,
            .connection_is_tls = true,
            .access_log_enabled = state.access_log_enabled,
            .peer_ip = peer_ip,
            .identity_resolver = state.identity_resolver,
        },
        if (live_body) streaming.Reader.buffered(body) else null,
    );
}

fn http3DispatchTestState(
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
) Http3DispatchState {
    return .{
        .io = std.testing.io,
        .stats = stats,
        .static_store = static_store,
        .app = app,
        .access_log_enabled = false,
        .identity_resolver = .{},
    };
}

test "HTTP3 dispatch reaches the shared router and secure response capture" {
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.embedded();
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };
    var state = http3DispatchTestState(&stats, &static_store, &app);
    const method = "GET";
    const path = "/missing-over-h3";
    const authority = "example.test";
    const request = http3.Request{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .authority_ptr = authority.ptr,
        .authority_len = authority.len,
        .headers_ptr = null,
        .headers_len = 0,
        .body_ptr = null,
        .body_len = 0,
        .error_status = 0,
    };
    var captured = response.Capture{};
    defer captured.deinit(http3.capture_allocator);

    try dispatchHttp3Request(&state, &request, &captured, try client_identity.IpKey.parse("203.0.113.8"));

    try std.testing.expectEqual(@as(u16, 404), captured.status);
    var found_hsts = false;
    for (captured.headers[0..captured.headers_len]) |header| {
        if (std.mem.eql(u8, header.name_ptr[0..header.name_len], "strict-transport-security")) {
            found_hsts = true;
            break;
        }
    }
    try std.testing.expect(found_hsts);
}

test "HTTP3 dispatch rejects duplicate content length" {
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.embedded();
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };
    var state = http3DispatchTestState(&stats, &static_store, &app);
    const method = "POST";
    const path = "/submit";
    const authority = "example.test";
    const name = "content-length";
    const value = "0";
    const headers = [_]response.CapturedHeader{
        .{ .name_ptr = name.ptr, .name_len = name.len, .value_ptr = value.ptr, .value_len = value.len },
        .{ .name_ptr = name.ptr, .name_len = name.len, .value_ptr = value.ptr, .value_len = value.len },
    };
    const request = http3.Request{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .authority_ptr = authority.ptr,
        .authority_len = authority.len,
        .headers_ptr = &headers,
        .headers_len = headers.len,
        .body_ptr = null,
        .body_len = 0,
        .error_status = 0,
    };
    var captured = response.Capture{};
    defer captured.deinit(http3.capture_allocator);

    try std.testing.expectError(
        error.BadRequest,
        dispatchHttp3Request(&state, &request, &captured, client_identity.IpKey.loopback()),
    );
}

/// Dispatch starts as soon as request headers arrive, while the nghttp2
/// adapter continues streaming DATA into its bounded request queue. Keep
/// consuming until END_STREAM after success or failure so a handler that
/// returns early cannot block the session thread and multiplexed streams.
fn drainHttp2RequestBody(io: std.Io, maybe_reader: ?streaming.Reader) void {
    var reader = maybe_reader orelse return;
    var discard: [4096]u8 = undefined;
    while (true) {
        const amount = reader.read(&discard) catch |err| {
            logger.message(io, .debug, "http2_request_body_drain_stopped", "error={t}", .{err});
            return;
        };
        if (amount == 0) return;
    }
}

const Http2DrainTestHarness = struct {
    fn dispatch(
        state: *Http2DispatchState,
        request: *const http2.Request,
        captured: *response.Capture,
        reader: streaming.Reader,
        output_queue: *streaming.ByteQueue,
        headers_ready: *std.atomic.Value(bool),
        failure: *?anyerror,
    ) void {
        dispatchHttp2Request(state, request, captured, reader, output_queue, headers_ready, null, null) catch |err| {
            failure.* = err;
        };
    }

    fn produce(
        queue: *streaming.ByteQueue,
        finished: *std.atomic.Value(bool),
        failure: *?anyerror,
    ) void {
        var chunk: [8192]u8 = undefined;
        @memset(&chunk, 'x');
        for (0..8) |_| queue.push(std.testing.io, &chunk) catch |err| {
            failure.* = err;
            finished.store(true, .release);
            return;
        };
        queue.finish(std.testing.io);
        finished.store(true, .release);
    }
};

fn expectHttp2DispatchDrainsRequestBody(
    state: *Http2DispatchState,
    request: *const http2.Request,
    expected_failure: ?anyerror,
    expected_status: ?u16,
) !void {
    var request_queue = try streaming.ByteQueue.init(std.testing.allocator, http_config.max_form_body_bytes);
    defer request_queue.deinit(std.testing.io);
    var request_source = streaming.QueueSource{ .io = std.testing.io, .queue = &request_queue };
    const body_reader = streaming.Reader.pull(&request_source, streaming.QueueSource.readerFn);
    var response_queue = try streaming.ByteQueue.init(std.testing.allocator, 64 * 1024);
    defer response_queue.deinit(std.testing.io);
    var captured = response.Capture{};
    defer captured.deinit(http2.capture_allocator);
    var headers_ready = std.atomic.Value(bool).init(false);
    var dispatch_failure: ?anyerror = null;
    var producer_failure: ?anyerror = null;
    var producer_finished = std.atomic.Value(bool).init(false);

    var dispatch_future = std.testing.io.async(Http2DrainTestHarness.dispatch, .{
        state,
        request,
        &captured,
        body_reader,
        &response_queue,
        &headers_ready,
        &dispatch_failure,
    });
    var producer_future = std.testing.io.async(Http2DrainTestHarness.produce, .{
        &request_queue,
        &producer_finished,
        &producer_failure,
    });

    var attempts: usize = 0;
    while (!producer_finished.load(.acquire) and attempts < 500) : (attempts += 1) {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const drained_without_cancel = producer_finished.load(.acquire);
    if (!drained_without_cancel) request_queue.cancel(std.testing.io);
    producer_future.await(std.testing.io);
    dispatch_future.await(std.testing.io);

    try std.testing.expect(drained_without_cancel);
    try std.testing.expect(producer_failure == null);
    if (expected_failure) |expected| {
        try std.testing.expect(dispatch_failure != null);
        try std.testing.expect(dispatch_failure.? == expected);
    } else {
        try std.testing.expect(dispatch_failure == null);
    }
    if (expected_status) |status| try std.testing.expectEqual(status, captured.status);
}

fn http2DrainTestState(
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
) Http2DispatchState {
    return .{
        .io = std.testing.io,
        .stats = stats,
        .static_store = static_store,
        .app = app,
        .http3 = .off,
        .http3_port = 443,
        .access_log_enabled = false,
        .peer_ip = client_identity.IpKey.unspecified(),
        .identity_resolver = .{},
    };
}

test "HTTP2 redirect drains request bodies larger than its bounded queue" {
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.embedded();
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };
    var state = http2DrainTestState(&stats, &static_store, &app);
    state.redirect_destination = .{ .scheme = .https, .port = 18443 };
    state.redirect_host_policy = .{ .canonical_host = "example.test" };

    const method = "POST";
    const path = "/upload?redirect=yes";
    const authority = "example.test:18080";
    const request = http2.Request{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .authority_ptr = authority.ptr,
        .authority_len = authority.len,
        .headers_ptr = null,
        .headers_len = 0,
        .body_ptr = null,
        .body_len = 0,
        .error_status = 0,
    };
    try expectHttp2DispatchDrainsRequestBody(&state, &request, null, 308);
}

test "HTTP2 redirect drains body when authority validation returns early" {
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.embedded();
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };
    var state = http2DrainTestState(&stats, &static_store, &app);
    state.redirect_destination = .{ .scheme = .https, .port = 18443 };
    state.redirect_host_policy = .{ .canonical_host = "example.test" };

    const method = "POST";
    const path = "/upload";
    const request = http2.Request{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .authority_ptr = null,
        .authority_len = 0,
        .headers_ptr = null,
        .headers_len = 0,
        .body_ptr = null,
        .body_len = 0,
        .error_status = 0,
    };
    try expectHttp2DispatchDrainsRequestBody(&state, &request, error.BadRequest, null);
}

test "HTTP2 validation failures drain body on ordinary routes" {
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.embedded();
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };
    var state = http2DrainTestState(&stats, &static_store, &app);

    const method = "POST";
    const path = "/upload";
    const authority = "example.test";
    const header_name = "content-length";
    const header_value = "65536";
    const headers = [_]response.CapturedHeader{
        .{ .name_ptr = header_name.ptr, .name_len = header_name.len, .value_ptr = header_value.ptr, .value_len = header_value.len },
        .{ .name_ptr = header_name.ptr, .name_len = header_name.len, .value_ptr = header_value.ptr, .value_len = header_value.len },
    };
    const request = http2.Request{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .path_ptr = path.ptr,
        .path_len = path.len,
        .authority_ptr = authority.ptr,
        .authority_len = authority.len,
        .headers_ptr = &headers,
        .headers_len = headers.len,
        .body_ptr = null,
        .body_len = 0,
        .error_status = 0,
    };

    try expectHttp2DispatchDrainsRequestBody(&state, &request, error.BadRequest, null);
}

fn serveProtocolRedirectHttp1(
    io: std.Io,
    connection: *transport.Connection,
    destination: protocol_redirect.Destination,
    host_policy: protocol_redirect.HostPolicy,
    header_timeout_ms: u32,
    stopping: ?*const std.atomic.Value(bool),
    access_log_enabled: bool,
    peer_ip: client_identity.IpKey,
) !void {
    const start_ns = nowNs(io);
    var buffer: [http_config.max_header_bytes]u8 = undefined;
    var filled: usize = 0;
    connection.setReadTimeoutMs(header_timeout_ms);
    while (true) {
        if (isStopping(stopping)) return;
        if (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n")) |index| {
            const request = try request_mod.Request.parse(buffer[0 .. index + 4]);
            const authority = try uniqueAuthority(request);
            var writer_buffer: [4096]u8 = undefined;
            var writer = connection.writer(&writer_buffer);
            var target: response.Target = .{ .http1 = &writer };
            var location_buffer: [http_config.max_header_bytes + 64]u8 = undefined;
            const location = protocol_redirect.resolveLocation(
                &location_buffer,
                authority,
                request.target,
                destination,
                host_policy,
            ) catch {
                const summary = try errors.write(&target, .bad_request, false, false);
                logRequestParts(
                    access_log_enabled,
                    io,
                    "http/1.1",
                    request.method_text,
                    request.target,
                    summary.status,
                    summary.body_bytes,
                    start_ns,
                    client_identity.ClientIdentity.direct(peer_ip),
                );
                return;
            };
            const body_bytes = try protocol_redirect.write(&target, request.method_text, location);
            logRequestPartsCached(
                access_log_enabled,
                io,
                "http/1.1",
                request.method_text,
                request.target,
                .permanent_redirect,
                body_bytes,
                start_ns,
                .{ .response_policy = .no_cache },
                client_identity.ClientIdentity.direct(peer_ip),
            );
            return;
        }
        if (filled == buffer.len) return error.RequestHeaderTooLarge;
        var read_vec: [1][]u8 = .{buffer[filled..]};
        const amount = try connection.read(&read_vec);
        if (amount == 0) return;
        filled += amount;
    }
}

fn uniqueAuthority(request: request_mod.Request) ![]const u8 {
    var authority: ?[]const u8 = null;
    var rest = request.headers;
    while (rest.len != 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Host")) {
            if (authority != null) return error.BadRequest;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (value.len == 0) return error.BadRequest;
            authority = value;
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return authority orelse error.BadRequest;
}

fn statsRequestError(
    state: *Http2DispatchState,
    captured_response: *response.Capture,
    method: []const u8,
    path: []const u8,
    status_code: u16,
) void {
    state.stats.requestStarted();
    defer state.stats.requestFinished();
    const start_ns = nowNs(state.io);
    var target: response.Target = .{ .capture = .{
        .response = captured_response,
        .allocator = std.heap.page_allocator,
        .secure = true,
    } };
    const kind: errors.Kind = switch (status_code) {
        413 => .payload_too_large,
        431 => .header_too_large,
        else => .bad_request,
    };
    const summary = errors.write(&target, kind, false, false) catch return;
    logRequestParts(
        state.access_log_enabled,
        state.io,
        "h2",
        if (method.len == 0) "BAD" else method,
        if (path.len == 0) "-" else path,
        summary.status,
        summary.body_bytes,
        start_ns,
        client_identity.ClientIdentity.direct(state.peer_ip),
    );
}

fn logHttp2Session(io: std.Io, summary: http2.Summary) void {
    logger.message(io, .info, "http2_session_closed", "protocol=h2 requests={d} highest_stream_id={d} goaway={s}", .{
        summary.requests,
        summary.highest_stream_id,
        if (summary.sentGoaway()) "yes" else "no",
    });
}

fn logTlsHandshake(
    io: std.Io,
    version: []const u8,
    cipher: []const u8,
    negotiated_protocol: tls.NegotiatedProtocol,
    session_reused: bool,
) void {
    const alpn = switch (negotiated_protocol) {
        .none => "none",
        .http1_1 => "http/1.1",
        .h2 => "h2",
        .unknown => "unknown",
    };
    logger.message(io, .info, "tls_handshake", "version={s} cipher={s} alpn={s} session_reused={s}", .{
        version,
        cipher,
        alpn,
        if (session_reused) "yes" else "no",
    });
}

fn appendFormatted(buffer: []u8, cursor: *usize, comptime format: []const u8, args: anytype) !void {
    const written = std.fmt.bufPrint(buffer[cursor.*..], format, args) catch return error.RequestHeaderTooLarge;
    cursor.* += written.len;
}

fn appendSlice(buffer: []u8, cursor: *usize, value: []const u8) !void {
    if (value.len > buffer.len - cursor.*) return error.RequestBodyTooLarge;
    @memcpy(buffer[cursor.* .. cursor.* + value.len], value);
    cursor.* += value.len;
}

fn containsLineBreak(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") != null;
}

fn isConnectionSpecificHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "proxy-connection") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

const ReadRequestResult = struct {
    raw_request: []const u8,
    consumed_bytes: usize,
    handler: ?router.ResolvedHandler,
    live_body: ?LiveBodyPlan = null,
};

const LiveBodyPlan = struct {
    header_bytes: usize,
    content_length: usize,
    chunked: bool,
    body_limit: usize,
};

fn readRequest(
    connection: *transport.Connection,
    buffer: *[http_config.max_request_bytes]u8,
    buffered: *usize,
    app: *const Application,
    first_request: bool,
    header_timeout_ms: u32,
    body_timeout_ms: u32,
    keep_alive_timeout_ms: u32,
    stopping: ?*const std.atomic.Value(bool),
) !?ReadRequestResult {
    var filled = buffered.*;
    var header_end: ?usize = null;
    var header_reads: usize = 0;
    var waiting_for_keep_alive = !first_request and filled == 0;
    connection.setReadTimeoutMs(if (waiting_for_keep_alive) keep_alive_timeout_ms else header_timeout_ms);

    while (header_end == null) {
        if (isStopping(stopping)) return null;
        switch (protocol.detect(buffer[0..filled])) {
            .tls_client_hello => return error.TlsHandshakeOnPlainHttp,
            .http2_preface => return error.Http2Preface,
            .http1, .unknown => {},
        }
        if (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n")) |index| {
            header_end = index + 4;
            break;
        }
        if (filled >= http_config.max_header_bytes) return error.RequestHeaderTooLarge;
        if (header_reads >= http_config.max_header_read_ops) return error.SlowRequest;
        header_reads += 1;
        var read_vec: [1][]u8 = .{buffer[filled..http_config.max_header_bytes]};
        const n = connection.read(&read_vec) catch |err| switch (err) {
            error.ConnectionResetByPeer => return null,
            error.GracefulShutdown => return null,
            error.ReadTimeout => if (waiting_for_keep_alive) return null else return error.RequestTimeout,
            else => return err,
        };
        if (n == 0) return null;
        filled += n;
        if (waiting_for_keep_alive) {
            waiting_for_keep_alive = false;
            connection.setReadTimeoutMs(header_timeout_ms);
        }
    }

    const end_of_headers = header_end orelse return error.RequestHeaderTooLarge;
    if (end_of_headers > http_config.max_header_bytes) return error.RequestHeaderTooLarge;
    const header_request = request_mod.Request.parse(buffer[0..end_of_headers]) catch |err| switch (err) {
        error.UnsupportedHttpVersion => return error.UnsupportedHttpVersion,
        else => return error.BadRequest,
    };
    const handler = app.routes.resolveHandler(header_request);
    const body_limit = routeBodyLimit(handler);
    const content_length = header_request.contentLength() orelse 0;
    if (content_length > body_limit) return error.RequestBodyTooLarge;
    if (header_request.hasUnsupportedExpectation()) return error.ExpectationFailed;

    if (handler != null and handler.?.options.streaming_body) {
        if (header_request.expectsContinue() and (content_length != 0 or header_request.isChunked())) {
            try connection.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        }
        connection.setReadTimeoutMs(body_timeout_ms);
        buffered.* = filled;
        return .{
            .raw_request = buffer[0..end_of_headers],
            .consumed_bytes = end_of_headers,
            .handler = handler,
            .live_body = .{
                .header_bytes = end_of_headers,
                .content_length = content_length,
                .chunked = header_request.isChunked(),
                .body_limit = body_limit,
            },
        };
    }

    connection.setReadTimeoutMs(body_timeout_ms);
    var body_reads: usize = 0;

    if (header_request.isChunked()) {
        var parsed = try inspectChunkedBody(buffer[end_of_headers..filled], body_limit);
        if (header_request.expectsContinue() and parsed == .incomplete) {
            try connection.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        }
        while (parsed == .incomplete) {
            if (isStopping(stopping)) return null;
            if (body_reads >= http_config.max_body_read_ops) return error.SlowRequest;
            if (filled == buffer.len) return error.RequestBodyTooLarge;
            body_reads += 1;
            var read_vec: [1][]u8 = .{buffer[filled..]};
            const n = connection.read(&read_vec) catch |err| switch (err) {
                error.ConnectionResetByPeer, error.GracefulShutdown => return null,
                error.ReadTimeout => return error.RequestTimeout,
                else => return err,
            };
            if (n == 0) return null;
            filled += n;
            parsed = try inspectChunkedBody(buffer[end_of_headers..filled], body_limit);
        }
        const complete = parsed.complete;
        const decoded_len = try decodeChunkedBodyInPlace(buffer[end_of_headers .. end_of_headers + complete.wire_bytes]);
        const logical_len = end_of_headers + decoded_len;
        connection.setReadTimeoutMs(0);
        buffered.* = filled;
        return .{
            .raw_request = buffer[0..logical_len],
            .consumed_bytes = end_of_headers + complete.wire_bytes,
            .handler = handler,
        };
    }

    const request_len = end_of_headers + content_length;
    if (request_len > buffer.len) return error.RequestBodyTooLarge;

    if (header_request.expectsContinue() and content_length != 0 and filled < request_len) {
        try connection.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    }
    while (filled < request_len) {
        if (isStopping(stopping)) return null;
        if (body_reads >= http_config.max_body_read_ops) return error.SlowRequest;
        body_reads += 1;
        var read_vec: [1][]u8 = .{buffer[filled..request_len]};
        const n = connection.read(&read_vec) catch |err| switch (err) {
            error.ConnectionResetByPeer => return null,
            error.GracefulShutdown => return null,
            error.ReadTimeout => return error.RequestTimeout,
            else => return err,
        };
        if (n == 0) return null;
        filled += n;
    }

    connection.setReadTimeoutMs(0);
    buffered.* = filled;
    return .{
        .raw_request = buffer[0..request_len],
        .consumed_bytes = request_len,
        .handler = handler,
    };
}

const ChunkedInspection = union(enum) {
    incomplete,
    complete: struct {
        wire_bytes: usize,
        decoded_bytes: usize,
    },
};

fn inspectChunkedBody(input: []const u8, body_limit: usize) !ChunkedInspection {
    var cursor: usize = 0;
    var decoded: usize = 0;
    var chunks: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, input, cursor, "\r\n") orelse return .incomplete;
        const line = input[cursor..line_end];
        const extension = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size_text = line[0..extension];
        if (size_text.len == 0) return error.BadRequest;
        for (line) |byte| if (byte < 0x20 or byte == 0x7f) return error.BadRequest;
        const chunk_size = std.fmt.parseInt(usize, size_text, 16) catch return error.BadRequest;
        cursor = line_end + 2;
        if (chunk_size == 0) {
            // Consume bounded trailer fields until the terminating empty line.
            while (true) {
                const trailer_end = std.mem.indexOfPos(u8, input, cursor, "\r\n") orelse return .incomplete;
                if (trailer_end == cursor) {
                    if (trailer_end + 2 - decoded > http_config.max_chunk_overhead_bytes) return error.RequestBodyTooLarge;
                    return .{ .complete = .{ .wire_bytes = trailer_end + 2, .decoded_bytes = decoded } };
                }
                const trailer = input[cursor..trailer_end];
                const colon = std.mem.indexOfScalar(u8, trailer, ':') orelse return error.BadRequest;
                if (colon == 0 or trailer[0] == ' ' or trailer[0] == '\t') return error.BadRequest;
                if (!validTrailerName(trailer[0..colon]) or !validTrailerValue(trailer[colon + 1 ..])) return error.BadRequest;
                if (std.ascii.eqlIgnoreCase(trailer[0..colon], "Content-Length") or
                    std.ascii.eqlIgnoreCase(trailer[0..colon], "Transfer-Encoding") or
                    std.ascii.eqlIgnoreCase(trailer[0..colon], "Host")) return error.BadRequest;
                cursor = trailer_end + 2;
                if (cursor > http_config.max_request_bytes) return error.RequestBodyTooLarge;
            }
        }
        chunks += 1;
        if (chunks > http_config.max_body_read_ops) return error.SlowRequest;
        if (chunk_size > body_limit -| decoded) return error.RequestBodyTooLarge;
        if (chunk_size > input.len -| cursor or input.len - cursor < chunk_size + 2) return .incomplete;
        if (!std.mem.eql(u8, input[cursor + chunk_size .. cursor + chunk_size + 2], "\r\n")) return error.BadRequest;
        decoded += chunk_size;
        cursor += chunk_size + 2;
    }
}

fn decodeChunkedBodyInPlace(input: []u8) !usize {
    var cursor: usize = 0;
    var written: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, input, cursor, "\r\n") orelse return error.BadRequest;
        const line = input[cursor..line_end];
        const extension = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const chunk_size = std.fmt.parseInt(usize, line[0..extension], 16) catch return error.BadRequest;
        cursor = line_end + 2;
        if (chunk_size == 0) return written;
        std.mem.copyForwards(u8, input[written .. written + chunk_size], input[cursor .. cursor + chunk_size]);
        written += chunk_size;
        cursor += chunk_size + 2;
    }
}

fn validTrailerName(name: []const u8) bool {
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => continue,
            else => return false,
        }
    }
    return name.len != 0;
}

fn validTrailerValue(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

fn isStopping(stopping: ?*const std.atomic.Value(bool)) bool {
    const flag = stopping orelse return false;
    return flag.load(.acquire);
}

fn consumeRequest(
    buffer: *[http_config.max_request_bytes]u8,
    buffered: *usize,
    consumed: usize,
) void {
    std.debug.assert(consumed <= buffered.*);
    const remaining = buffered.* - consumed;
    std.mem.copyForwards(u8, buffer[0..remaining], buffer[consumed..buffered.*]);
    buffered.* = remaining;
}

test "consumeRequest preserves bytes read for the next persistent request" {
    var buffer: [http_config.max_request_bytes]u8 = undefined;
    const first = "GET /one HTTP/1.1\r\n\r\n";
    const second = "GET /two HTTP/1.1\r\n\r\n";
    @memcpy(buffer[0..first.len], first);
    @memcpy(buffer[first.len .. first.len + second.len], second);
    var buffered = first.len + second.len;

    consumeRequest(&buffer, &buffered, first.len);

    try std.testing.expectEqual(second.len, buffered);
    try std.testing.expectEqualStrings(second, buffer[0..buffered]);
}

fn serveRequest(
    writer: *response.Target,
    io: std.Io,
    raw_request: []const u8,
    resolved_handler: ?router.ResolvedHandler,
    stats: *stats_mod.Stats,
    static_store: *const static.Store,
    app: *const Application,
    server_keep_alive: bool,
    close_due_to_limit: bool,
    protocol_name: []const u8,
    options: ServeOptions,
    body_reader: ?streaming.Reader,
) !RequestAction {
    stats.requestStarted();
    defer stats.requestFinished();
    const start_ns = nowNs(io);

    var alt_svc_buf: [64]u8 = undefined;
    var transport_header_buf: [1]response.Header = undefined;
    const transport_headers: []const response.Header = if (options.http3 == .advertise and options.connection_is_tls) block: {
        const value = std.fmt.bufPrint(&alt_svc_buf, "h3=\":{d}\"", .{options.http3_port}) catch break :block &.{};
        transport_header_buf[0] = .{ .name = "Alt-Svc", .value = value };
        break :block transport_header_buf[0..1];
    } else &.{};

    const request = request_mod.Request.parse(raw_request) catch {
        const summary = try errors.writeExtra(writer, .bad_request, false, false, transport_headers);
        logRequestParts(options.access_log_enabled, io, protocol_name, "BAD", "-", summary.status, summary.body_bytes, start_ns, client_identity.ClientIdentity.direct(options.peer_ip));
        return .close;
    };
    const identity = options.identity_resolver.resolve(options.peer_ip, request);
    stats.identityResolved(identity.resolution);

    const body_limit = routeBodyLimit(resolved_handler);
    if (request.body.len > body_limit) {
        const summary = try errors.writeExtra(writer, .payload_too_large, request.isHead(), false, transport_headers);
        logRequest(options.access_log_enabled, io, protocol_name, request, summary.status, summary.body_bytes, start_ns, identity);
        return .close;
    }
    if (request.contentLength()) |declared| {
        if (declared > body_limit) {
            const summary = try errors.writeExtra(writer, .payload_too_large, request.isHead(), false, transport_headers);
            logRequest(options.access_log_enabled, io, protocol_name, request, summary.status, summary.body_bytes, start_ns, identity);
            return .close;
        }
    }

    const keep_alive = request.wantsKeepAlive(server_keep_alive, close_due_to_limit);
    var reusable = keep_alive;
    const head = request.isHead();
    var log_status = response.Status.internal_server_error;
    var log_body_bytes: usize = 0;
    var log_cache = RequestCacheLog{
        .enabled = app.page_cache != null,
        .status = if (app.page_cache == null) .disabled else .bypass,
    };

    const route: router.Route = if (resolved_handler) |handler|
        .{ .handler = handler }
    else
        app.routes.resolve(static_store, request) catch .not_found;
    switch (route) {
        .handler => |handler| {
            var ctx = Context.init(
                io,
                writer,
                request,
                stats,
                static_store,
                keep_alive,
                handler.options,
                handler.params,
                app.auth,
                app.services,
                app.page_cache,
            );
            ctx.setClientIdentity(identity);
            ctx.setRateLimiter(app.rate_limiter);
            defer ctx.deinit();
            if (body_reader) |reader_value| {
                var reader = reader_value;
                reader.setLimits(body_limit, request.contentLength());
                ctx.setRequestBodyStream(reader);
            }
            defer ctx.finishPageCacheFill();
            for (transport_headers) |header| try ctx.addTransportHeader(header.name, header.value);
            const middleware_decision = middleware.run(&ctx, app.middleware_stack) catch |err| block: {
                try writeContextError(&ctx, err);
                break :block .stop;
            };
            if (middleware_decision == .next) {
                app.dispatch(&ctx, handler.id) catch |err| {
                    try writeContextError(&ctx, err);
                };
            }
            log_status = ctx.response_status orelse response.Status.internal_server_error;
            log_body_bytes = ctx.response_body_bytes;
            log_cache.status = ctx.page_cache_status;
            log_cache.response_policy = ctx.response_cache_policy;
            reusable = ctx.keep_alive;
        },
        .preflight => |handler| {
            var ctx = Context.init(
                io,
                writer,
                request,
                stats,
                static_store,
                keep_alive,
                handler.options,
                handler.params,
                app.auth,
                app.services,
                app.page_cache,
            );
            ctx.setClientIdentity(identity);
            ctx.setRateLimiter(app.rate_limiter);
            defer ctx.deinit();
            for (transport_headers) |header| try ctx.addTransportHeader(header.name, header.value);
            const middleware_decision = middleware.run(&ctx, app.middleware_stack) catch |err| block: {
                try writeContextError(&ctx, err);
                break :block .stop;
            };
            if (middleware_decision == .next and !ctx.response_written) {
                const summary = try errors.writeExtra(
                    writer,
                    .method_not_allowed,
                    head,
                    keep_alive,
                    ctx.pendingHeaders(),
                );
                ctx.recordResponse(summary.status, summary.body_bytes);
                ctx.response_cache_policy = .no_cache;
            }
            log_status = ctx.response_status orelse response.Status.internal_server_error;
            log_body_bytes = ctx.response_body_bytes;
            log_cache.status = ctx.page_cache_status;
            log_cache.response_policy = ctx.response_cache_policy;
            reusable = ctx.keep_alive;
        },
        .method_not_allowed => {
            const summary = try errors.writeExtra(
                writer,
                .method_not_allowed,
                head,
                keep_alive,
                transport_headers,
            );
            log_status = summary.status;
            log_body_bytes = summary.body_bytes;
            log_cache.response_policy = .no_cache;
        },
        .static => |asset| {
            defer asset.deinit(static_store.allocator orelse std.heap.page_allocator);
            try response.writeBytes(
                writer,
                .ok,
                asset.content_type,
                asset.body,
                head,
                keep_alive,
                asset.cache,
                transport_headers,
            );
            log_status = .ok;
            log_body_bytes = if (head) 0 else asset.body.len;
            log_cache.response_policy = asset.cache;
        },
        .not_found => {
            const summary = try errors.writeExtra(
                writer,
                .not_found,
                head,
                keep_alive,
                transport_headers,
            );
            log_status = summary.status;
            log_body_bytes = summary.body_bytes;
            log_cache.response_policy = .no_cache;
        },
    }

    logRequestCached(options.access_log_enabled, io, protocol_name, request, log_status, log_body_bytes, start_ns, log_cache, identity);
    return if (reusable) .keep_alive else .close;
}

fn writeContextError(ctx: *Context, err: anyerror) !void {
    if (ctx.response_written) {
        ctx.abortResponseStream();
        return;
    }
    const summary = try errors.writeExtra(
        ctx.writer,
        errors.kindFromError(err),
        ctx.head,
        ctx.keep_alive,
        ctx.pendingHeaders(),
    );
    ctx.recordResponse(summary.status, summary.body_bytes);
    ctx.response_cache_policy = .no_cache;
}

fn routeBodyLimit(resolved_handler: ?router.ResolvedHandler) usize {
    const handler = resolved_handler orelse return http_config.max_form_body_bytes;
    const hard_limit = if (handler.options.streaming_body)
        http_config.max_stream_body_bytes
    else
        http_config.max_form_body_bytes;
    return @min(handler.options.body_limit orelse http_config.max_form_body_bytes, hard_limit);
}

test "HTTPS static responses advertise the native HTTP3 endpoint" {
    var captured = response.Capture{};
    defer captured.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{
        .response = &captured,
        .allocator = std.testing.allocator,
        .secure = true,
    } };
    var stats = stats_mod.Stats.init(false);
    const static_store = static.Store.filesystem(std.testing.io, std.testing.allocator, "src/public");
    const app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn dispatch(_: *Context, _: router.Handler) anyerror!void {}
        }.dispatch,
    };

    _ = try serveRequest(
        &target,
        std.testing.io,
        "GET /index.html HTTP/1.1\r\nHost: example.test\r\n\r\n",
        null,
        &stats,
        &static_store,
        &app,
        true,
        false,
        "h2",
        .{
            .http3 = .advertise,
            .http3_port = 8443,
            .connection_is_tls = true,
            .access_log_enabled = false,
        },
        null,
    );

    try std.testing.expectEqual(@as(u16, 200), captured.status);
    var found_alt_svc = false;
    for (captured.headers[0..captured.headers_len]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name_ptr[0..header.name_len], "Alt-Svc") and
            std.mem.eql(u8, header.value_ptr[0..header.value_len], "h3=\":8443\""))
        {
            found_alt_svc = true;
            break;
        }
    }
    try std.testing.expect(found_alt_svc);
}

test "streaming routes may exceed the buffered body ceiling" {
    const streaming_route = router.ResolvedHandler{
        .id = 1,
        .options = .{ .body_limit = 64 * 1024 * 1024, .streaming_body = true },
    };
    const buffered_route = router.ResolvedHandler{
        .id = 2,
        .options = .{ .body_limit = 64 * 1024 * 1024 },
    };
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), routeBodyLimit(streaming_route));
    try std.testing.expectEqual(http_config.max_form_body_bytes, routeBodyLimit(buffered_route));
}

test "request middleware can isolate clients through verified identity" {
    // Keep this integration test inside core by using a core-owned test
    // middleware. The production rate-limit policy remains in compose; core
    // must not import compose, including from test declarations.
    const test_rate_limit = struct {
        fn run(ctx: *Context) !middleware.Decision {
            const policy = ctx.route_options.rate_limit;
            if (policy == .none) return .next;
            const limiter = ctx.rate_limiter orelse return error.RateLimiterUnavailable;
            return switch (try limiter.check(ctx.io, ctx.clientIp(), policy)) {
                .allowed => .next,
                .rejected, .capacity_rejected => error.TooManyRequests,
            };
        }
    }.run;
    var limiter = try rate_limiter_mod.Limiter.init(std.testing.allocator, .{
        .strict_rps = 1,
        .capacity = 8,
        .shards = 2,
    });
    defer limiter.deinit(std.testing.io);
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    const stack = [_]middleware.Middleware{.{ .name = "test_rate_limit", .run = test_rate_limit }};
    var app = Application{
        .routes = .{ .entries = &.{} },
        .dispatch = struct {
            fn run(ctx: *Context, _: router.Handler) anyerror!void {
                try ctx.text(.ok, "ok");
            }
        }.run,
        .middleware_stack = &stack,
        .rate_limiter = &limiter,
    };
    const resolved = router.ResolvedHandler{ .id = 1, .options = .{ .rate_limit = .strict } };
    const Runner = struct {
        fn run(
            application: *const Application,
            runtime_stats: *stats_mod.Stats,
            store: *const static.Store,
            handler: router.ResolvedHandler,
            peer_ip: client_identity.IpKey,
            raw_request: []const u8,
            resolver: client_identity.Resolver,
        ) !u16 {
            var captured = response.Capture{};
            defer captured.deinit(std.testing.allocator);
            var target: response.Target = .{ .capture = .{
                .response = &captured,
                .allocator = std.testing.allocator,
            } };
            _ = try serveRequest(
                &target,
                std.testing.io,
                raw_request,
                handler,
                runtime_stats,
                store,
                application,
                false,
                true,
                "http/1.1",
                .{ .access_log_enabled = false, .peer_ip = peer_ip, .identity_resolver = resolver },
                null,
            );
            return captured.status;
        }
    };
    const client_a = try client_identity.IpKey.parse("192.0.2.1");
    const client_b = try client_identity.IpKey.parse("192.0.2.2");
    const direct_request = "GET /limited HTTP/1.1\r\nHost: test\r\n\r\n";
    try std.testing.expectEqual(@as(u16, 200), try Runner.run(&app, &stats, &static_store, resolved, client_a, direct_request, .{}));
    try std.testing.expectEqual(@as(u16, 429), try Runner.run(&app, &stats, &static_store, resolved, client_a, direct_request, .{}));
    try std.testing.expectEqual(@as(u16, 200), try Runner.run(&app, &stats, &static_store, resolved, client_b, direct_request, .{}));

    const untrusted_peer = try client_identity.IpKey.parse("203.0.113.50");
    const spoof_a = "GET /limited HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 1.1.1.1\r\n\r\n";
    const spoof_b = "GET /limited HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 2.2.2.2\r\n\r\n";
    try std.testing.expectEqual(@as(u16, 200), try Runner.run(&app, &stats, &static_store, resolved, untrusted_peer, spoof_a, .{}));
    try std.testing.expectEqual(@as(u16, 429), try Runner.run(&app, &stats, &static_store, resolved, untrusted_peer, spoof_b, .{}));

    const proxy = try client_identity.IpKey.parse("10.0.0.10");
    const resolver = try client_identity.Resolver.init(.x_forwarded_for, &.{"10.0.0.10/32"}, 4);
    const forwarded_a = "GET /limited HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.1\r\n\r\n";
    const forwarded_b = "GET /limited HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.2\r\n\r\n";
    try std.testing.expectEqual(@as(u16, 200), try Runner.run(&app, &stats, &static_store, resolved, proxy, forwarded_a, resolver));
    try std.testing.expectEqual(@as(u16, 429), try Runner.run(&app, &stats, &static_store, resolved, proxy, forwarded_a, resolver));
    try std.testing.expectEqual(@as(u16, 200), try Runner.run(&app, &stats, &static_store, resolved, proxy, forwarded_b, resolver));
}

fn logRequest(
    enabled: bool,
    io: std.Io,
    protocol_name: []const u8,
    request: request_mod.Request,
    status: response.Status,
    body_bytes: usize,
    start_ns: i96,
    identity: client_identity.ClientIdentity,
) void {
    logRequestCached(enabled, io, protocol_name, request, status, body_bytes, start_ns, .{}, identity);
}

const RequestCacheLog = struct {
    enabled: bool = false,
    status: logger.CacheStatus = .disabled,
    response_policy: response.CachePolicy = .none,
};

fn logRequestCached(
    enabled: bool,
    io: std.Io,
    protocol_name: []const u8,
    request: request_mod.Request,
    status: response.Status,
    body_bytes: usize,
    start_ns: i96,
    cache: RequestCacheLog,
    identity: client_identity.ClientIdentity,
) void {
    logRequestPartsCached(enabled, io, protocol_name, request.method_text, request.target, status, body_bytes, start_ns, cache, identity);
}

fn logRequestParts(
    enabled: bool,
    io: std.Io,
    protocol_name: []const u8,
    method: []const u8,
    target: []const u8,
    status: response.Status,
    body_bytes: usize,
    start_ns: i96,
    identity: client_identity.ClientIdentity,
) void {
    logRequestPartsCached(enabled, io, protocol_name, method, target, status, body_bytes, start_ns, .{}, identity);
}

fn logRequestPartsCached(
    enabled: bool,
    io: std.Io,
    protocol_name: []const u8,
    method: []const u8,
    target: []const u8,
    status: response.Status,
    body_bytes: usize,
    start_ns: i96,
    cache: RequestCacheLog,
    identity: client_identity.ClientIdentity,
) void {
    if (!enabled) return;
    const elapsed_ns = nowNs(io) - start_ns;
    const elapsed_us = @divFloor(elapsed_ns, 1000);
    var client_ip_buffer: [64]u8 = undefined;
    const client_ip = identity.client_ip.format(&client_ip_buffer) catch "invalid";
    logger.access(io, .{
        .protocol = protocol_name,
        .method = method,
        .target = target,
        .status = status.code,
        .body_bytes = body_bytes,
        .duration_us = elapsed_us,
        .cache_enabled = cache.enabled,
        .cache_status = cache.status,
        .response_cache = cache.response_policy.text(),
        .client_ip = client_ip,
        .client_ip_source = identity.source.text(),
    });
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

test "chunked framing decodes extensions and trailers in place" {
    var wire = [_]u8{
        '4',  ';',  'x',  '=', '1', '\r', '\n', 'W', 'i',  'k',  'i',  '\r', '\n',
        '5',  '\r', '\n', 'p', 'e', 'd',  'i',  'a', '\r', '\n', '0',  '\r', '\n',
        'X',  '-',  'T',  'e', 's', 't',  ':',  ' ', 'o',  'k',  '\r', '\n', '\r',
        '\n',
    };
    const inspection = try inspectChunkedBody(&wire, 32);
    const complete = switch (inspection) {
        .complete => |value| value,
        .incomplete => return error.ExpectedCompleteChunkedBody,
    };
    try std.testing.expectEqual(@as(usize, wire.len), complete.wire_bytes);
    try std.testing.expectEqual(@as(usize, 9), complete.decoded_bytes);
    const decoded_len = try decodeChunkedBodyInPlace(&wire);
    try std.testing.expectEqualStrings("Wikipedia", wire[0..decoded_len]);
}

test "chunked framing is incremental and bounded" {
    try std.testing.expectEqual(ChunkedInspection.incomplete, try inspectChunkedBody("4\r\nWi", 16));
    try std.testing.expectError(error.RequestBodyTooLarge, inspectChunkedBody("4\r\nWiki\r\n0\r\n\r\n", 3));
    try std.testing.expectError(error.BadRequest, inspectChunkedBody("Z\r\n", 16));
    try std.testing.expectError(error.BadRequest, inspectChunkedBody("1\r\naX\n0\r\n\r\n", 16));
}
