const std = @import("std");

pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const tls = @import("core/tls.zig");
const transport = @import("core/transport.zig");
const net = std.Io.net;

const default_host = "127.0.0.1";
const default_port: u16 = 18080;
const default_https_port: u16 = 18443;
const default_path = "/";
const default_threads: usize = 8;
const default_duration_seconds: u64 = 10;
const default_keep_alive_requests: usize = 1000;
const default_timeout_ms: u32 = 5000;
const default_streams_per_connection: usize = 1;

const BenchMode = enum {
    http1,
    https1,
    http2,

    fn text(self: BenchMode) []const u8 {
        return switch (self) {
            .http1 => "HTTP/1.1",
            .https1 => "HTTPS/1.1",
            .http2 => "HTTP/2",
        };
    }

    fn usesTls(self: BenchMode) bool {
        return self != .http1;
    }
};

const BenchConfig = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    https_port: u16 = default_https_port,
    path: []const u8 = default_path,
    threads: usize = default_threads,
    duration_seconds: u64 = default_duration_seconds,
    keep_alive_requests: usize = default_keep_alive_requests,
    timeout_ms: u32 = default_timeout_ms,
    tls_verify: bool = false,
    json: bool = false,
    mode: BenchMode = .http1,
    streams_per_connection: usize = default_streams_per_connection,
    body: []const u8 = "",
    content_type: []const u8 = "",
};

const SharedBench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: net.IpAddress,
    request: []const u8,
    authority: []const u8,
    end_ns: i96,
    config: *const BenchConfig,
    tls_context: ?*const tls.ClientContext,
};

const WorkerResult = struct {
    requests: u64 = 0,
    success: u64 = 0,
    failed: u64 = 0,
    connections: u64 = 0,
    response_bytes: u64 = 0,
    latency_samples: u64 = 0,
    latency_ns: u128 = 0,
    min_latency_ns: u64 = std.math.maxInt(u64),
    max_latency_ns: u64 = 0,

    fn record(self: *WorkerResult, ok: bool, elapsed_ns: u64, response_bytes: usize) void {
        self.requests += 1;
        if (!ok) {
            self.failed += 1;
            return;
        }
        self.success += 1;
        self.response_bytes += response_bytes;
        self.latency_samples += 1;
        self.latency_ns += elapsed_ns;
        self.min_latency_ns = @min(self.min_latency_ns, elapsed_ns);
        self.max_latency_ns = @max(self.max_latency_ns, elapsed_ns);
    }

    fn merge(self: *WorkerResult, other: WorkerResult) void {
        self.requests += other.requests;
        self.success += other.success;
        self.failed += other.failed;
        self.connections += other.connections;
        self.response_bytes += other.response_bytes;
        self.latency_samples += other.latency_samples;
        self.latency_ns += other.latency_ns;
        self.min_latency_ns = @min(self.min_latency_ns, other.min_latency_ns);
        self.max_latency_ns = @max(self.max_latency_ns, other.max_latency_ns);
    }
};

const ResponseResult = struct { ok: bool, body_bytes: usize };

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    var config = BenchConfig{};
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            config.host = arg["--host=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--https-port=")) {
            config.https_port = try std.fmt.parseInt(u16, arg["--https-port=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            config.path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            config.threads = try std.fmt.parseInt(usize, arg["--threads=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            config.duration_seconds = try std.fmt.parseInt(u64, arg["--duration=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--keep-alive=")) {
            config.keep_alive_requests = try std.fmt.parseInt(usize, arg["--keep-alive=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            config.timeout_ms = try std.fmt.parseInt(u32, arg["--timeout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--streams-per-connection=")) {
            config.streams_per_connection = try std.fmt.parseInt(usize, arg["--streams-per-connection=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--body=")) {
            config.body = arg["--body=".len..];
        } else if (std.mem.startsWith(u8, arg, "--content-type=")) {
            config.content_type = arg["--content-type=".len..];
        } else if (std.mem.eql(u8, arg, "--no-keep-alive")) {
            config.keep_alive_requests = 0;
        } else if (std.mem.eql(u8, arg, "--https")) {
            config.mode = .https1;
        } else if (std.mem.eql(u8, arg, "--http2")) {
            config.mode = .http2;
        } else if (std.mem.eql(u8, arg, "--tls-verify")) {
            config.tls_verify = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{arg});
            printUsage();
            return 2;
        }
    }

    if (config.threads == 0 or config.duration_seconds == 0 or config.timeout_ms == 0) {
        std.debug.print("--threads, --duration and --timeout must be greater than zero\n", .{});
        return 2;
    }
    if (config.path.len == 0 or config.path[0] != '/' or config.path.len > 4096) {
        std.debug.print("--path must start with '/' and be at most 4096 bytes\n", .{});
        return 2;
    }
    if (config.streams_per_connection == 0 or config.streams_per_connection > 128) {
        std.debug.print("--streams-per-connection must be from 1 to 128\n", .{});
        return 2;
    }

    const io = init.io;
    const use_port = if (config.mode.usesTls()) config.https_port else config.port;
    const address = try net.IpAddress.resolve(io, config.host, use_port);
    const authority = try std.fmt.allocPrint(init.gpa, "{s}:{d}", .{ config.host, use_port });
    defer init.gpa.free(authority);
    const content_type_header = if (config.content_type.len == 0)
        ""
    else
        try std.fmt.allocPrint(init.gpa, "Content-Type: {s}\r\n", .{config.content_type});
    defer if (config.content_type.len != 0) init.gpa.free(content_type_header);
    const request = try std.fmt.allocPrint(
        init.gpa,
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: zibench/0.3\r\nAccept: */*\r\n{s}Content-Length: {d}\r\nConnection: {s}\r\n\r\n{s}",
        .{ if (config.body.len == 0) "GET" else "POST", config.path, authority, content_type_header, config.body.len, if (config.keep_alive_requests == 0) "close" else "keep-alive", config.body },
    );
    defer init.gpa.free(request);

    var tls_context: ?tls.ClientContext = if (config.mode.usesTls())
        tls.initClientContext(.openssl, config.tls_verify) catch |err| {
            std.debug.print("failed to initialize TLS client: {t}\n", .{err});
            return 2;
        }
    else
        null;
    defer if (tls_context) |*context| context.deinit();

    const start_ns = nowNs(io);
    const end_ns = start_ns + @as(i96, @intCast(config.duration_seconds)) * std.time.ns_per_s;
    var shared = SharedBench{
        .allocator = init.gpa,
        .io = io,
        .address = address,
        .request = request,
        .authority = authority,
        .end_ns = end_ns,
        .config = &config,
        .tls_context = if (tls_context) |*context| context else null,
    };

    std.debug.print(
        "zibench {s} {s}://{s}:{d}{s} threads={d} duration={d}s keep_alive={d} streams_per_connection={d} timeout={d}ms verify={s}\n",
        .{
            config.mode.text(),
            if (config.mode.usesTls()) "https" else "http",
            config.host,
            use_port,
            config.path,
            config.threads,
            config.duration_seconds,
            config.keep_alive_requests,
            config.streams_per_connection,
            config.timeout_ms,
            if (config.tls_verify) "on" else "off",
        },
    );

    const threads = try init.gpa.alloc(std.Thread, config.threads);
    defer init.gpa.free(threads);
    const results = try init.gpa.alloc(WorkerResult, config.threads);
    defer init.gpa.free(results);
    @memset(results, .{});
    for (threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, worker, .{ &shared, &results[i] });
    for (threads) |thread| thread.join();

    const finish_ns = nowNs(io);
    var total = WorkerResult{};
    for (results) |result| total.merge(result);
    const elapsed_ns = @as(u64, @intCast(@max(1, finish_ns - start_ns)));
    printReport(config, total, elapsed_ns);
    return if (total.success == 0) 1 else 0;
}

fn worker(shared: *const SharedBench, result: *WorkerResult) void {
    const requests_per_connection = if (shared.config.keep_alive_requests == 0) 1 else shared.config.keep_alive_requests;
    while (nowNs(shared.io) < shared.end_ns) {
        var connection = openConnection(shared, result) catch {
            result.record(false, 0, 0);
            continue;
        };

        if (shared.config.mode == .http2) {
            var h2 = H2Client.init(&connection) catch {
                result.record(false, 0, 0);
                connection.close();
                continue;
            };
            var count: usize = 0;
            while (nowNs(shared.io) < shared.end_ns and count < requests_per_connection) {
                connection.setReadTimeoutMs(shared.config.timeout_ms);
                const start_ns = nowNs(shared.io);
                const batch_count = @min(shared.config.streams_per_connection, requests_per_connection - count);
                var responses: [128]ResponseResult = undefined;
                h2.requestBatch(shared.authority, shared.config.path, shared.config.body, shared.config.content_type, responses[0..batch_count]) catch |err| {
                    std.debug.print("zibench h2 request failed: {t}\n", .{err});
                    result.record(false, elapsedSince(shared.io, start_ns), 0);
                    break;
                };
                const elapsed = elapsedSince(shared.io, start_ns);
                var batch_ok = true;
                for (responses[0..batch_count]) |response| {
                    result.record(response.ok, elapsed, response.body_bytes);
                    batch_ok = batch_ok and response.ok;
                }
                count += batch_count;
                if (!batch_ok or h2.goaway_received) break;
            }
            h2.close() catch {};
        } else {
            var writer_buffer: [1024]u8 = undefined;
            var writer = connection.writer(&writer_buffer);
            var response_buffer: [8192]u8 = undefined;
            var count: usize = 0;
            while (nowNs(shared.io) < shared.end_ns and count < requests_per_connection) : (count += 1) {
                connection.setReadTimeoutMs(shared.config.timeout_ms);
                const start_ns = nowNs(shared.io);
                writer.interface.writeAll(shared.request) catch {
                    result.record(false, elapsedSince(shared.io, start_ns), 0);
                    break;
                };
                writer.interface.flush() catch {
                    result.record(false, elapsedSince(shared.io, start_ns), 0);
                    break;
                };
                const response = readHttp1Response(&connection, &response_buffer) catch {
                    result.record(false, elapsedSince(shared.io, start_ns), 0);
                    break;
                };
                result.record(response.ok, elapsedSince(shared.io, start_ns), response.body_bytes);
                if (!response.ok) break;
            }
        }
        connection.close();
    }
}

fn openConnection(shared: *const SharedBench, result: *WorkerResult) !transport.Connection {
    const stream = try shared.address.connect(shared.io, .{ .mode = .stream });
    result.connections += 1;
    var connection = transport.Connection.init(shared.io, stream);
    errdefer connection.close();
    connection.setReadTimeoutMs(shared.config.timeout_ms);
    if (shared.config.mode.usesTls()) {
        try connection.enableTlsClient(
            shared.allocator,
            shared.tls_context.?,
            shared.config.host,
            shared.config.mode == .http2,
        );
        const negotiated = connection.negotiatedProtocol();
        if ((shared.config.mode == .http2 and negotiated != .h2) or
            (shared.config.mode == .https1 and negotiated != .http1_1))
        {
            return error.UnexpectedAlpn;
        }
    }
    return connection;
}

fn readHttp1Response(connection: *transport.Connection, buffer: *[8192]u8) !ResponseResult {
    var filled: usize = 0;
    var header_end: ?usize = null;
    while (filled < buffer.len) {
        var read_vec: [1][]u8 = .{buffer[filled..]};
        const n = try connection.read(&read_vec);
        if (n == 0) return error.EndOfStream;
        filled += n;
        if (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n")) |index| {
            header_end = index + 4;
            break;
        }
    }
    const end = header_end orelse return error.ResponseHeaderTooLarge;
    const header = buffer[0..end];
    const status_ok = std.mem.startsWith(u8, header, "HTTP/1.1 2") or std.mem.startsWith(u8, header, "HTTP/1.0 2");
    const content_length = parseContentLength(header) orelse return error.MissingContentLength;
    var body_read = filled - end;
    var discard: [8192]u8 = undefined;
    while (body_read < content_length) {
        const chunk_len = @min(content_length - body_read, discard.len);
        var read_vec: [1][]u8 = .{discard[0..chunk_len]};
        const n = try connection.read(&read_vec);
        if (n == 0) return error.EndOfStream;
        body_read += n;
    }
    return .{ .ok = status_ok, .body_bytes = content_length };
}

const H2Client = struct {
    connection: *transport.Connection,
    next_stream_id: u32 = 1,
    frame_buffer: [16384]u8 = undefined,
    goaway_received: bool = false,

    fn init(connection: *transport.Connection) !H2Client {
        var client = H2Client{ .connection = connection };
        try connection.writeAll("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
        // SETTINGS_ENABLE_PUSH = 0. zibench measures request/response traffic
        // only and deliberately rejects unsolicited server push.
        try client.writeFrame(4, 0, 0, &.{ 0, 2, 0, 0, 0, 0 });
        return client;
    }

    fn request(self: *H2Client, authority: []const u8, path: []const u8, body: []const u8, content_type: []const u8) !ResponseResult {
        var results: [1]ResponseResult = undefined;
        try self.requestBatch(authority, path, body, content_type, &results);
        return results[0];
    }

    fn requestBatch(self: *H2Client, authority: []const u8, path: []const u8, body: []const u8, content_type: []const u8, results: []ResponseResult) !void {
        if (results.len == 0 or results.len > 128) return error.InvalidStreamBatch;
        if (self.goaway_received) return error.GoAway;
        var stream_ids: [128]u32 = undefined;
        var saw_headers: [128]bool = @splat(false);
        var status_ok: [128]bool = @splat(false);
        var body_bytes: [128]usize = @splat(0);
        var complete: [128]bool = @splat(false);
        for (results, 0..) |_, index| {
            const stream_id = self.next_stream_id;
            if (stream_id > 0x7ffffffd) return error.StreamIdExhausted;
            self.next_stream_id += 2;
            stream_ids[index] = stream_id;
            var header_block: [8192]u8 = undefined;
            const encoded = try encodeRequestHeaders(&header_block, authority, path, body.len, content_type);
            try self.writeFrame(1, if (body.len == 0) 0x5 else 0x4, stream_id, encoded);
            if (body.len != 0) try self.writeFrame(0, 0x1, stream_id, body);
        }

        var completed: usize = 0;
        while (completed < results.len) {
            const frame = try self.readFrame();
            const index = for (stream_ids[0..results.len], 0..) |id, i| {
                if (id == frame.stream_id) break i;
            } else null;
            switch (frame.frame_type) {
                0 => if (index) |i| {
                    body_bytes[i] += dataLength(frame.flags, frame.payload) catch return error.InvalidDataFrame;
                    if (frame.payload.len != 0) try self.writeWindowUpdate(0, frame.payload.len);
                    if ((frame.flags & 0x1) != 0 and !complete[i]) {
                        complete[i] = true;
                        results[i] = .{ .ok = saw_headers[i] and status_ok[i], .body_bytes = body_bytes[i] };
                        completed += 1;
                    }
                },
                1 => if (index) |i| {
                    if (!saw_headers[i]) {
                        saw_headers[i] = true;
                        status_ok[i] = hpackStatusIsSuccess(frame.flags, frame.payload);
                    }
                    if ((frame.flags & 0x1) != 0 and !complete[i]) {
                        complete[i] = true;
                        results[i] = .{ .ok = status_ok[i], .body_bytes = body_bytes[i] };
                        completed += 1;
                    }
                },
                3 => if (index != null) return error.StreamReset,
                4 => if ((frame.flags & 0x1) == 0) try self.writeFrame(4, 0x1, 0, &.{}),
                6 => if ((frame.flags & 0x1) == 0) try self.writeFrame(6, 0x1, 0, frame.payload),
                7 => {
                    const last_stream_id = try goAwayLastStreamId(frame.payload);
                    self.goaway_received = true;
                    for (stream_ids[0..results.len]) |stream_id| if (last_stream_id < stream_id) return error.GoAway;
                },
                else => {},
            }
        }
    }

    const Frame = struct { frame_type: u8, flags: u8, stream_id: u32, payload: []const u8 };

    fn readFrame(self: *H2Client) !Frame {
        var header: [9]u8 = undefined;
        try readExact(self.connection, &header);
        const length = (@as(usize, header[0]) << 16) | (@as(usize, header[1]) << 8) | header[2];
        if (length > self.frame_buffer.len) return error.FrameTooLarge;
        try readExact(self.connection, self.frame_buffer[0..length]);
        const stream_id = (@as(u32, header[5] & 0x7f) << 24) |
            (@as(u32, header[6]) << 16) | (@as(u32, header[7]) << 8) | header[8];
        return .{ .frame_type = header[3], .flags = header[4], .stream_id = stream_id, .payload = self.frame_buffer[0..length] };
    }

    fn writeFrame(self: *H2Client, frame_type: u8, flags: u8, stream_id: u32, payload: []const u8) !void {
        if (payload.len > 0xffffff or stream_id > 0x7fffffff) return error.InvalidFrame;
        var header = [9]u8{
            @intCast((payload.len >> 16) & 0xff), @intCast((payload.len >> 8) & 0xff), @intCast(payload.len & 0xff),
            frame_type,                           flags,                               @intCast((stream_id >> 24) & 0x7f),
            @intCast((stream_id >> 16) & 0xff),   @intCast((stream_id >> 8) & 0xff),   @intCast(stream_id & 0xff),
        };
        try self.connection.writeAll(&header);
        try self.connection.writeAll(payload);
    }

    fn writeWindowUpdate(self: *H2Client, stream_id: u32, increment: usize) !void {
        if (increment == 0 or increment > 0x7fffffff) return;
        const value: u32 = @intCast(increment);
        const payload = [4]u8{
            @intCast((value >> 24) & 0x7f), @intCast((value >> 16) & 0xff),
            @intCast((value >> 8) & 0xff),  @intCast(value & 0xff),
        };
        try self.writeFrame(8, 0, stream_id, &payload);
    }

    fn close(self: *H2Client) !void {
        const last_stream_id = self.next_stream_id -| 2;
        const payload = [8]u8{
            @intCast((last_stream_id >> 24) & 0x7f), @intCast((last_stream_id >> 16) & 0xff),
            @intCast((last_stream_id >> 8) & 0xff),  @intCast(last_stream_id & 0xff),
            0, 0, 0, 0, // NO_ERROR
        };
        try self.writeFrame(7, 0, 0, &payload);
    }
};

fn goAwayLastStreamId(payload: []const u8) !u32 {
    if (payload.len < 8) return error.InvalidGoAway;
    return (@as(u32, payload[0] & 0x7f) << 24) |
        (@as(u32, payload[1]) << 16) |
        (@as(u32, payload[2]) << 8) |
        payload[3];
}

fn encodeRequestHeaders(buffer: []u8, authority: []const u8, path: []const u8, body_len: usize, content_type: []const u8) ![]const u8 {
    var used: usize = 0;
    try appendHpackInteger(buffer, &used, if (body_len == 0) 2 else 3, 7, 0x80); // :method GET/POST
    try appendHpackInteger(buffer, &used, 7, 7, 0x80); // :scheme https
    try appendHpackInteger(buffer, &used, 1, 4, 0x00); // :authority name
    try appendHpackString(buffer, &used, authority);
    if (std.mem.eql(u8, path, "/")) {
        try appendHpackInteger(buffer, &used, 4, 7, 0x80); // indexed :path /
    } else {
        try appendHpackInteger(buffer, &used, 4, 4, 0x00); // :path name
        try appendHpackString(buffer, &used, path);
    }
    if (body_len != 0) {
        try appendHpackInteger(buffer, &used, 28, 4, 0x00); // content-length name
        var length_buffer: [32]u8 = undefined;
        const length = try std.fmt.bufPrint(&length_buffer, "{d}", .{body_len});
        try appendHpackString(buffer, &used, length);
    }
    if (content_type.len != 0) {
        try appendHpackInteger(buffer, &used, 31, 4, 0x00); // content-type name
        try appendHpackString(buffer, &used, content_type);
    }
    return buffer[0..used];
}

fn appendHpackString(buffer: []u8, used: *usize, value: []const u8) !void {
    try appendHpackInteger(buffer, used, value.len, 7, 0x00);
    if (buffer.len - used.* < value.len) return error.HeaderBlockTooLarge;
    @memcpy(buffer[used.*..][0..value.len], value);
    used.* += value.len;
}

fn appendHpackInteger(buffer: []u8, used: *usize, initial: usize, prefix_bits: u3, mask: u8) !void {
    const prefix_max: usize = (@as(usize, 1) << prefix_bits) - 1;
    var value = initial;
    if (used.* >= buffer.len) return error.HeaderBlockTooLarge;
    if (value < prefix_max) {
        buffer[used.*] = mask | @as(u8, @intCast(value));
        used.* += 1;
        return;
    }
    buffer[used.*] = mask | @as(u8, @intCast(prefix_max));
    used.* += 1;
    value -= prefix_max;
    while (value >= 128) {
        if (used.* >= buffer.len) return error.HeaderBlockTooLarge;
        buffer[used.*] = @as(u8, @intCast(value & 0x7f)) | 0x80;
        used.* += 1;
        value >>= 7;
    }
    if (used.* >= buffer.len) return error.HeaderBlockTooLarge;
    buffer[used.*] = @intCast(value);
    used.* += 1;
}

fn hpackStatusIsSuccess(flags: u8, payload: []const u8) bool {
    var offset: usize = 0;
    var end = payload.len;
    if ((flags & 0x8) != 0) {
        if (payload.len == 0) return false;
        offset = 1;
        const padding = payload[0];
        if (padding > end - offset) return false;
        end -= padding;
    }
    if ((flags & 0x20) != 0) offset += 5;
    if (offset >= end) return false;
    const first = payload[offset];
    return (first & 0x80) != 0 and (first & 0x7f) >= 8 and (first & 0x7f) <= 10;
}

fn dataLength(flags: u8, payload: []const u8) !usize {
    if ((flags & 0x8) == 0) return payload.len;
    if (payload.len == 0) return error.InvalidPadding;
    const padding = payload[0];
    if (padding > payload.len - 1) return error.InvalidPadding;
    return payload.len - 1 - padding;
}

fn readExact(connection: *transport.Connection, output: []u8) !void {
    var filled: usize = 0;
    while (filled < output.len) {
        var read_vec: [1][]u8 = .{output[filled..]};
        const n = try connection.read(&read_vec);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

fn parseContentLength(header: []const u8) ?usize {
    var rest = header;
    while (std.mem.indexOf(u8, rest, "\r\n")) |line_end| {
        const line = rest[0..line_end];
        if (line.len == 0) return null;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
        rest = rest[line_end + 2 ..];
    }
    return null;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsedSince(io: std.Io, start_ns: i96) u64 {
    return @intCast(@max(0, nowNs(io) - start_ns));
}

fn printReport(config: BenchConfig, total: WorkerResult, elapsed_ns: u64) void {
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const rps_x100 = total.success * std.time.ns_per_s * 100 / elapsed_ns;
    const avg_latency_ns: u128 = if (total.latency_samples == 0) 0 else total.latency_ns / total.latency_samples;
    const min_latency_ns = if (total.latency_samples == 0) 0 else total.min_latency_ns;
    if (config.json) {
        std.debug.print(
            "{{\"mode\":\"{s}\",\"requests\":{d},\"success\":{d},\"failed\":{d},\"connections\":{d},\"response_bytes\":{d},\"elapsed_ms\":{d},\"rps_x100\":{d},\"latency_avg_ns\":{d},\"latency_min_ns\":{d},\"latency_max_ns\":{d}}}\n",
            .{ config.mode.text(), total.requests, total.success, total.failed, total.connections, total.response_bytes, elapsed_ms, rps_x100, avg_latency_ns, min_latency_ns, total.max_latency_ns },
        );
        return;
    }
    std.debug.print(
        \\result:
        \\  requests:       {d}
        \\  success:        {d}
        \\  failed:         {d}
        \\  connections:    {d}
        \\  response bytes: {d}
        \\  elapsed:        {d}.{d:0>3}s
        \\  success rps:    {d}.{d:0>2}
        \\  latency:        avg {d}.{d:0>3}ms, min {d}.{d:0>3}ms, max {d}.{d:0>3}ms
        \\
    , .{
        total.requests,                                           total.success,                       total.failed,                                             total.connections,                         total.response_bytes,
        elapsed_ms / 1000,                                        elapsed_ms % 1000,                   rps_x100 / 100,                                           rps_x100 % 100,                            avg_latency_ns / std.time.ns_per_ms,
        avg_latency_ns % std.time.ns_per_ms / std.time.ns_per_us, min_latency_ns / std.time.ns_per_ms, min_latency_ns % std.time.ns_per_ms / std.time.ns_per_us, total.max_latency_ns / std.time.ns_per_ms, total.max_latency_ns % std.time.ns_per_ms / std.time.ns_per_us,
    });
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zibench [--host=127.0.0.1] [--port=18080] [--https-port=18443] [--path=/]
        \\          [--threads=N] [--duration=SECONDS] [--keep-alive=N] [--timeout=MS]
        \\          [--streams-per-connection=N] [--body=TEXT] [--content-type=TYPE]
        \\          [--https|--http2] [--tls-verify] [--json]
        \\
        \\Modes:
        \\  default          plain HTTP/1.1
        \\  --https          TLS + ALPN HTTP/1.1
        \\  --http2          TLS + ALPN h2 with native HTTP/2 frames and HPACK requests
        \\
        \\Options:
        \\  --tls-verify     verify the certificate chain and server hostname (off for local dev by default)
        \\  --timeout=MS     TLS handshake and per-request read deadline, default 5000
        \\  --keep-alive=N   requests per connection, default 1000
        \\  --streams-per-connection=N concurrent HTTP/2 streams per batch, default 1, max 128
        \\  --body=TEXT      send POST with this request body
        \\  --content-type=T set Content-Type for POST bodies
        \\  --no-keep-alive  one request per connection
        \\  --json           emit a machine-readable result line
        \\
        \\Examples:
        \\  zig build bench -- --threads=16 --duration=30
        \\  zig build bench -- --https --threads=16 --duration=30
        \\  zig build bench -- --http2 --threads=16 --duration=30
        \\
    , .{});
}

test "HTTP/2 request headers use valid static HPACK entries" {
    var buffer: [128]u8 = undefined;
    const encoded = try encodeRequestHeaders(&buffer, "localhost:443", "/", 0, "");
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x87, 0x01, 13 }, encoded[0..4]);
    try std.testing.expectEqualSlices(u8, "localhost:443", encoded[4..17]);
    try std.testing.expectEqual(@as(u8, 0x84), encoded[17]);
}

test "HTTP/2 POST headers include content type" {
    var buffer: [128]u8 = undefined;
    const encoded = try encodeRequestHeaders(&buffer, "localhost:443", "/upload", 4, "text/plain");
    const content_type_name = std.mem.indexOf(u8, encoded, &.{ 0x0f, 0x10, 0x0a }) orelse return error.TestExpectedContentType;
    try std.testing.expectEqualSlices(u8, "text/plain", encoded[content_type_name + 3 ..]);
}

test "HTTP/2 GOAWAY parser preserves last accepted stream id" {
    try std.testing.expectEqual(@as(u32, 1999), try goAwayLastStreamId(&.{ 0, 0, 7, 207, 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidGoAway, goAwayLastStreamId(&.{ 0, 0, 0, 1 }));
}

test "HTTP/2 padded data length excludes padding" {
    try std.testing.expectEqual(@as(usize, 3), try dataLength(0, "abc"));
    try std.testing.expectEqual(@as(usize, 3), try dataLength(0x8, &.{ 2, 'a', 'b', 'c', 0, 0 }));
    try std.testing.expectError(error.InvalidPadding, dataLength(0x8, &.{3}));
}

test "failed benchmark attempts do not contaminate latency" {
    var result = WorkerResult{};
    result.record(false, 99, 10);
    try std.testing.expectEqual(@as(u64, 1), result.failed);
    try std.testing.expectEqual(@as(u64, 0), result.latency_samples);
    try std.testing.expectEqual(@as(u128, 0), result.latency_ns);
}
