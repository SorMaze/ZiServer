const std = @import("std");

const http_config = @import("http_config.zig");
const transport = @import("transport.zig");
const streaming = @import("streaming.zig");

pub const Header = http_config.Header;
pub const Status = http_config.Status;
pub const CachePolicy = http_config.CachePolicy;

pub const max_capture_headers = 24;

const default_security_headers = [_]Header{
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
    .{ .name = "Permissions-Policy", .value = "camera=(), microphone=(), geolocation=()" },
    .{ .name = "Content-Security-Policy", .value = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:" },
    .{ .name = "Cross-Origin-Opener-Policy", .value = "same-origin" },
    .{ .name = "X-Permitted-Cross-Domain-Policies", .value = "none" },
};

const strict_transport_security_header: Header = .{
    .name = "Strict-Transport-Security",
    .value = "max-age=31536000",
};

const captured_default_security_headers = [_]Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=()" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "x-permitted-cross-domain-policies", .value = "none" },
};

const captured_strict_transport_security_header: Header = .{
    .name = "strict-transport-security",
    .value = "max-age=31536000",
};

pub const CapturedHeader = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
};

pub const Capture = extern struct {
    status: u16 = 500,
    content_type_ptr: ?[*]const u8 = null,
    content_type_len: usize = 0,
    content_length: usize = 0,
    body_ptr: ?[*]u8 = null,
    body_len: usize = 0,
    cache_ptr: ?[*]const u8 = null,
    cache_len: usize = 0,
    headers: [max_capture_headers]CapturedHeader = undefined,
    headers_len: usize = 0,
    streaming: u8 = 0,
    content_length_known: u8 = 1,

    pub fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        if (self.body_ptr) |body_ptr| allocator.free(body_ptr[0..self.body_len]);
        if (self.content_type_ptr) |content_type_ptr| allocator.free(content_type_ptr[0..self.content_type_len]);
        if (self.cache_ptr) |cache_ptr| allocator.free(cache_ptr[0..self.cache_len]);
        var owned_header_start: usize = @min(captured_default_security_headers.len, self.headers_len);
        if (self.headers_len > owned_header_start) {
            const candidate = self.headers[owned_header_start];
            if (candidate.name_ptr == captured_strict_transport_security_header.name.ptr and
                candidate.value_ptr == captured_strict_transport_security_header.value.ptr)
            {
                owned_header_start += 1;
            }
        }
        for (self.headers[owned_header_start..self.headers_len]) |header| {
            allocator.free(header.name_ptr[0..header.name_len]);
            allocator.free(header.value_ptr[0..header.value_len]);
        }
        self.body_ptr = null;
        self.body_len = 0;
        self.content_type_ptr = null;
        self.content_type_len = 0;
        self.cache_ptr = null;
        self.cache_len = 0;
        self.headers_len = 0;
        self.streaming = 0;
        self.content_length_known = 1;
    }
};

pub const H2Wake = *const fn (?*anyopaque) void;

pub const H2StreamTarget = struct {
    response: *Capture,
    allocator: std.mem.Allocator,
    secure: bool,
    io: std.Io,
    output: *streaming.ByteQueue,
    headers_ready: *std.atomic.Value(bool),
    wake_userdata: ?*anyopaque = null,
    wake: ?H2Wake = null,
};

pub const Target = union(enum) {
    http1: *transport.Writer,
    capture: struct {
        response: *Capture,
        allocator: std.mem.Allocator,
        secure: bool = false,
    },
    h2_stream: H2StreamTarget,
};

pub const Stream = struct {
    target: *Target,
    mode: Mode,
    head: bool,
    declared_length: ?usize,
    bytes_written: usize = 0,
    finished: bool = false,

    const Mode = enum { fixed, chunked, close_delimited, capture, h2_stream };

    pub fn begin(
        target: *Target,
        status: Status,
        content_type: []const u8,
        head: bool,
        keep_alive: bool,
        allow_chunked: bool,
        content_length: ?usize,
        cache: CachePolicy,
        extra_headers: []const Header,
    ) !Stream {
        if (status.code < 100 or status.code > 999 or !validHeaderValue(status.reason)) return error.InvalidResponseStatus;
        const mode: Mode = switch (target.*) {
            .http1 => |writer| block: {
                if (content_length) |length| {
                    try writeHead(writer, status, content_type, length, keep_alive, cache, extra_headers);
                    try writer.interface.flush();
                    break :block .fixed;
                }
                const chunked = allow_chunked;
                try writeStreamingHead(writer, status, content_type, keep_alive and chunked, chunked, cache, extra_headers);
                try writer.interface.flush();
                break :block if (chunked) .chunked else .close_delimited;
            },
            .capture => |capture_target| block: {
                try captureBytes(capture_target.response, capture_target.allocator, status, content_type, "", true, cache, extra_headers, capture_target.secure);
                capture_target.response.content_length = content_length orelse 0;
                break :block .capture;
            },
            .h2_stream => |stream_target| block: {
                try captureBytes(stream_target.response, stream_target.allocator, status, content_type, "", true, cache, extra_headers, stream_target.secure);
                stream_target.response.content_length = content_length orelse 0;
                stream_target.response.content_length_known = @intFromBool(content_length != null);
                stream_target.response.streaming = 1;
                stream_target.headers_ready.store(true, .release);
                signalH2Wake(stream_target);
                break :block .h2_stream;
            },
        };
        return .{ .target = target, .mode = mode, .head = head, .declared_length = content_length };
    }

    pub fn write(self: *Stream, chunk: []const u8) !void {
        if (self.finished) return error.ResponseStreamFinished;
        if (self.head or chunk.len == 0) return;
        if (self.declared_length) |declared| {
            if (chunk.len > declared -| self.bytes_written) return error.ResponseStreamLengthMismatch;
        }
        switch (self.mode) {
            .fixed, .close_delimited => switch (self.target.*) {
                .http1 => |writer| {
                    try writer.interface.writeAll(chunk);
                    try writer.interface.flush();
                },
                .capture => unreachable,
                .h2_stream => unreachable,
            },
            .chunked => switch (self.target.*) {
                .http1 => |writer| {
                    try writer.interface.print("{x}\r\n", .{chunk.len});
                    try writer.interface.writeAll(chunk);
                    try writer.interface.writeAll("\r\n");
                    try writer.interface.flush();
                },
                .capture => unreachable,
                .h2_stream => unreachable,
            },
            .capture => switch (self.target.*) {
                .capture => |capture_target| try appendCapturedBody(capture_target.response, capture_target.allocator, chunk),
                .http1 => unreachable,
                .h2_stream => unreachable,
            },
            .h2_stream => switch (self.target.*) {
                .h2_stream => |stream_target| try pushH2Bytes(stream_target.output, stream_target.io, chunk, stream_target),
                else => unreachable,
            },
        }
        self.bytes_written += chunk.len;
    }

    pub fn finish(self: *Stream) !void {
        if (self.finished) return;
        if (!self.head) {
            if (self.declared_length) |declared| {
                if (self.bytes_written != declared) return error.ResponseStreamLengthMismatch;
            }
            switch (self.mode) {
                .chunked => switch (self.target.*) {
                    .http1 => |writer| {
                        try writer.interface.writeAll("0\r\n\r\n");
                        try writer.interface.flush();
                    },
                    .capture => unreachable,
                    .h2_stream => unreachable,
                },
                .capture => switch (self.target.*) {
                    .capture => |capture_target| capture_target.response.content_length = self.declared_length orelse self.bytes_written,
                    .http1 => unreachable,
                    .h2_stream => unreachable,
                },
                .h2_stream => switch (self.target.*) {
                    .h2_stream => |stream_target| {
                        stream_target.response.content_length = self.declared_length orelse self.bytes_written;
                        stream_target.output.finish(stream_target.io);
                        signalH2Wake(stream_target);
                    },
                    else => unreachable,
                },
                .fixed, .close_delimited => {},
            }
        } else if (self.mode == .h2_stream) {
            switch (self.target.*) {
                .h2_stream => |stream_target| {
                    stream_target.output.finish(stream_target.io);
                    signalH2Wake(stream_target);
                },
                else => unreachable,
            }
        }
        self.finished = true;
    }
};

pub fn writeBytes(
    target: *Target,
    status: Status,
    content_type: []const u8,
    body: []const u8,
    head: bool,
    keep_alive: bool,
    cache: CachePolicy,
    extra_headers: []const Header,
) !void {
    if (status.code < 100 or status.code > 999 or !validHeaderValue(status.reason)) {
        return error.InvalidResponseStatus;
    }
    switch (target.*) {
        .http1 => |writer| {
            try writeHead(writer, status, content_type, body.len, keep_alive, cache, extra_headers);
            if (!head and body.len != 0) try writer.interface.writeAll(body);
            try writer.interface.flush();
        },
        .capture => |capture_target| try captureBytes(
            capture_target.response,
            capture_target.allocator,
            status,
            content_type,
            body,
            head,
            cache,
            extra_headers,
            capture_target.secure,
        ),
        .h2_stream => |stream_target| {
            try captureBytes(stream_target.response, stream_target.allocator, status, content_type, "", true, cache, extra_headers, stream_target.secure);
            stream_target.response.content_length = body.len;
            stream_target.response.content_length_known = 1;
            stream_target.response.streaming = 1;
            // Publish metadata before a body larger than the bounded queue is
            // pushed so the nghttp2 consumer can drain chunks concurrently.
            stream_target.headers_ready.store(true, .release);
            signalH2Wake(stream_target);
            if (!head and body.len != 0) try pushH2Bytes(stream_target.output, stream_target.io, body, stream_target);
            stream_target.output.finish(stream_target.io);
            signalH2Wake(stream_target);
        },
    }
}

fn signalH2Wake(stream_target: H2StreamTarget) void {
    const wake = stream_target.wake orelse return;
    wake(stream_target.wake_userdata);
}

fn pushH2Bytes(queue: *streaming.ByteQueue, io: std.Io, body: []const u8, stream_target: H2StreamTarget) !void {
    const chunk_capacity = queue.maxChunkBytes();
    if (chunk_capacity == 0) return error.InvalidStreamCapacity;
    var cursor: usize = 0;
    while (cursor < body.len) {
        const amount = @min(chunk_capacity, body.len - cursor);
        try queue.push(io, body[cursor .. cursor + amount]);
        signalH2Wake(stream_target);
        cursor += amount;
    }
}

fn captureBytes(
    capture: *Capture,
    allocator: std.mem.Allocator,
    status: Status,
    content_type: []const u8,
    body: []const u8,
    head: bool,
    cache: CachePolicy,
    extra_headers: []const Header,
    secure: bool,
) !void {
    const security_header_count = default_security_headers.len + @intFromBool(secure);
    if (extra_headers.len + security_header_count > capture.headers.len) return error.ResponseHeaderOverflow;
    if (!validHeaderValue(content_type)) return error.InvalidResponseHeader;
    for (extra_headers) |header| try validateHeader(header.name, header.value);

    capture.status = status.code;
    const owned_content_type = try allocator.dupe(u8, content_type);
    capture.content_type_ptr = owned_content_type.ptr;
    capture.content_type_len = owned_content_type.len;
    capture.content_length = body.len;
    capture.cache_ptr = null;
    capture.cache_len = 0;
    if (cache.value()) |cache_value| {
        const owned_cache = allocator.dupe(u8, cache_value) catch |err| {
            allocator.free(owned_content_type);
            capture.content_type_ptr = null;
            capture.content_type_len = 0;
            return err;
        };
        capture.cache_ptr = owned_cache.ptr;
        capture.cache_len = owned_cache.len;
    }

    capture.headers_len = 0;
    errdefer capture.deinit(allocator);
    for (captured_default_security_headers) |header| {
        capture.headers[capture.headers_len] = .{
            .name_ptr = header.name.ptr,
            .name_len = header.name.len,
            .value_ptr = header.value.ptr,
            .value_len = header.value.len,
        };
        capture.headers_len += 1;
    }
    if (secure) {
        const header = captured_strict_transport_security_header;
        capture.headers[capture.headers_len] = .{
            .name_ptr = header.name.ptr,
            .name_len = header.name.len,
            .value_ptr = header.value.ptr,
            .value_len = header.value.len,
        };
        capture.headers_len += 1;
    }
    for (extra_headers) |header| try captureHeader(capture, allocator, header);

    if (!head and body.len != 0) {
        const owned_body = try allocator.dupe(u8, body);
        capture.body_ptr = owned_body.ptr;
        capture.body_len = owned_body.len;
    }
}

fn captureHeader(capture: *Capture, allocator: std.mem.Allocator, header: Header) !void {
    const owned_name = try allocator.dupe(u8, header.name);
    for (owned_name) |*byte| byte.* = std.ascii.toLower(byte.*);
    const owned_value = allocator.dupe(u8, header.value) catch |err| {
        allocator.free(owned_name);
        return err;
    };
    capture.headers[capture.headers_len] = .{
        .name_ptr = owned_name.ptr,
        .name_len = owned_name.len,
        .value_ptr = owned_value.ptr,
        .value_len = owned_value.len,
    };
    capture.headers_len += 1;
}

pub fn writeHead(
    writer: *transport.Writer,
    status: Status,
    content_type: []const u8,
    content_length: usize,
    keep_alive: bool,
    cache: CachePolicy,
    extra_headers: []const Header,
) !void {
    if (!validHeaderValue(content_type)) return error.InvalidResponseHeader;
    for (extra_headers) |header| try validateHeader(header.name, header.value);

    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "{s}: {s}\r\n" ++
            "{s}: {d}\r\n" ++
            "{s}: {s}\r\n",
        .{
            status.code,
            status.reason,
            http_config.HeaderName.content_type,
            content_type,
            http_config.HeaderName.content_length,
            content_length,
            http_config.HeaderName.connection,
            if (keep_alive) http_config.HeaderValue.keep_alive else http_config.HeaderValue.close,
        },
    );

    if (cache.value()) |cache_value| {
        try writer.interface.print("{s}: {s}\r\n", .{ http_config.HeaderName.cache_control, cache_value });
    }

    for (default_security_headers) |header| {
        try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    if (writer.connection.mode == .tls) {
        try writer.interface.print("{s}: {s}\r\n", .{ strict_transport_security_header.name, strict_transport_security_header.value });
    }

    for (extra_headers) |header| {
        try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try writer.interface.writeAll("\r\n");
}

fn writeStreamingHead(
    writer: *transport.Writer,
    status: Status,
    content_type: []const u8,
    keep_alive: bool,
    chunked: bool,
    cache: CachePolicy,
    extra_headers: []const Header,
) !void {
    if (!validHeaderValue(content_type)) return error.InvalidResponseHeader;
    for (extra_headers) |header| try validateHeader(header.name, header.value);
    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\n{s}: {s}\r\n{s}: {s}\r\n",
        .{
            status.code,
            status.reason,
            http_config.HeaderName.content_type,
            content_type,
            http_config.HeaderName.connection,
            if (keep_alive) http_config.HeaderValue.keep_alive else http_config.HeaderValue.close,
        },
    );
    if (chunked) try writer.interface.print("{s}: chunked\r\n", .{http_config.HeaderName.transfer_encoding});
    if (cache.value()) |cache_value| try writer.interface.print("{s}: {s}\r\n", .{ http_config.HeaderName.cache_control, cache_value });
    for (default_security_headers) |header| try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    if (writer.connection.mode == .tls) try writer.interface.print("{s}: {s}\r\n", .{ strict_transport_security_header.name, strict_transport_security_header.value });
    for (extra_headers) |header| try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    try writer.interface.writeAll("\r\n");
}

fn appendCapturedBody(capture: *Capture, allocator: std.mem.Allocator, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const next_len = std.math.add(usize, capture.body_len, chunk.len) catch return error.ResponseBodyTooLarge;
    const body = if (capture.body_ptr) |ptr|
        try allocator.realloc(ptr[0..capture.body_len], next_len)
    else
        try allocator.alloc(u8, next_len);
    @memcpy(body[capture.body_len..next_len], chunk);
    capture.body_ptr = body.ptr;
    capture.body_len = body.len;
}

pub fn validateHeader(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidResponseHeader;
    for (name) |byte| {
        if (!isTokenByte(byte)) return error.InvalidResponseHeader;
    }
    if (!validHeaderValue(value)) return error.InvalidResponseHeader;
}

fn isTokenByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

test "capture target preserves HTTP response metadata and body" {
    var header_name = [_]u8{ 'X', '-', 'T', 'e', 's', 't' };
    var header_value = [_]u8{ 'c', 'a', 'p', 't', 'u', 'r', 'e', 'd' };
    const extra_headers = [_]Header{
        .{ .name = &header_name, .value = &header_value },
    };
    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: Target = .{ .capture = .{
        .response = &capture,
        .allocator = std.testing.allocator,
    } };

    try writeBytes(
        &target,
        .ok,
        http_config.ContentType.json,
        "{\"ok\":true}\n",
        false,
        false,
        .no_cache,
        &extra_headers,
    );
    @memset(&header_name, 'n');
    @memset(&header_value, 'v');

    try std.testing.expectEqual(@as(u16, 200), capture.status);
    try std.testing.expectEqual(@as(usize, 12), capture.content_length);
    try std.testing.expectEqualStrings(
        "{\"ok\":true}\n",
        capture.body_ptr.?[0..capture.body_len],
    );
    try std.testing.expectEqual(@as(usize, default_security_headers.len + 1), capture.headers_len);
    const captured = capture.headers[default_security_headers.len];
    try std.testing.expectEqualStrings("x-test", captured.name_ptr[0..captured.name_len]);
    try std.testing.expectEqualStrings("captured", captured.value_ptr[0..captured.value_len]);
}

test "rejects response header injection" {
    try std.testing.expectError(error.InvalidResponseHeader, validateHeader("X-Test\r\nInjected", "value"));
    try std.testing.expectError(error.InvalidResponseHeader, validateHeader("X-Test", "value\r\nInjected: true"));

    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: Target = .{ .capture = .{
        .response = &capture,
        .allocator = std.testing.allocator,
    } };
    try std.testing.expectError(
        error.InvalidResponseStatus,
        writeBytes(&target, .{ .code = 200, .reason = "OK\r\nInjected: true" }, "text/plain", "", false, false, .none, &.{}),
    );
}

test "capture adds HSTS only for secure transports" {
    var plain_capture = Capture{};
    defer plain_capture.deinit(std.testing.allocator);
    var plain_target: Target = .{ .capture = .{
        .response = &plain_capture,
        .allocator = std.testing.allocator,
    } };
    try writeBytes(&plain_target, .ok, http_config.ContentType.plain, "", false, false, .none, &.{});
    try std.testing.expectEqual(default_security_headers.len, plain_capture.headers_len);

    var secure_capture = Capture{};
    defer secure_capture.deinit(std.testing.allocator);
    var secure_target: Target = .{ .capture = .{
        .response = &secure_capture,
        .allocator = std.testing.allocator,
        .secure = true,
    } };
    try writeBytes(&secure_target, .ok, http_config.ContentType.plain, "", false, false, .none, &.{});
    try std.testing.expectEqual(default_security_headers.len + 1, secure_capture.headers_len);
    const hsts = secure_capture.headers[default_security_headers.len];
    try std.testing.expectEqualStrings("strict-transport-security", hsts.name_ptr[0..hsts.name_len]);
    try std.testing.expectEqualStrings("max-age=31536000", hsts.value_ptr[0..hsts.value_len]);
}

test "response stream appends chunks into HTTP2 capture target" {
    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: Target = .{ .capture = .{
        .response = &capture,
        .allocator = std.testing.allocator,
        .secure = true,
    } };
    var stream = try Stream.begin(&target, .ok, http_config.ContentType.plain, false, true, true, null, .no_cache, &.{});
    try stream.write("one");
    try stream.write("two");
    try stream.finish();
    try std.testing.expectEqualStrings("onetwo", capture.body_ptr.?[0..capture.body_len]);
    try std.testing.expectEqual(@as(usize, 6), capture.content_length);
}

test "HTTP2 buffered response spans bounded output queue" {
    const Writer = struct {
        fn run(target: *Target, body: []const u8, failure: *?anyerror) void {
            writeBytes(target, .ok, http_config.ContentType.javascript, body, false, true, .static_asset, &.{}) catch |err| {
                failure.* = err;
            };
        }
    };

    const body = "0123456789abcdefghijklmnop";
    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);
    var queue = try streaming.ByteQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.io);
    var headers_ready = std.atomic.Value(bool).init(false);
    var target: Target = .{ .h2_stream = .{
        .response = &capture,
        .allocator = std.testing.allocator,
        .secure = true,
        .io = std.testing.io,
        .output = &queue,
        .headers_ready = &headers_ready,
    } };
    var failure: ?anyerror = null;
    var future = std.testing.io.async(Writer.run, .{ &target, body, &failure });

    var received: [body.len]u8 = undefined;
    var cursor: usize = 0;
    var chunk: [5]u8 = undefined;
    while (true) {
        const amount = try queue.readBlocking(std.testing.io, &chunk);
        if (amount == 0) break;
        @memcpy(received[cursor .. cursor + amount], chunk[0..amount]);
        cursor += amount;
    }
    future.await(std.testing.io);

    try std.testing.expect(failure == null);
    try std.testing.expect(headers_ready.load(.acquire));
    try std.testing.expectEqual(body.len, cursor);
    try std.testing.expectEqualStrings(body, &received);
    try std.testing.expectEqual(body.len, capture.content_length);
    try std.testing.expectEqual(@as(u8, 1), capture.streaming);
}
