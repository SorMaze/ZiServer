const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const http_config = @import("http_config.zig");
const http2 = @import("http2.zig");
const client_identity = @import("client_identity.zig");
const errors = @import("errors.zig");
const logger = @import("log.zig");
const quic_transport = @import("quic_transport.zig");
const response = @import("response.zig");

pub const linked = std.mem.eql(u8, build_options.http3_provider, "nghttp3");
pub const capture_allocator = if (linked) std.heap.c_allocator else std.heap.page_allocator;

/// Reuses HTTP/2's Request structure — layout-compatible with the C adapter.
pub const Request = http2.Request;

pub const Summary = extern struct {
    requests: u64 = 0,
    highest_stream_id: u32 = 0,
    goaway_sent: u8 = 0,

    pub fn sentGoaway(self: Summary) bool {
        return self.goaway_sent != 0;
    }
};

pub const DispatchFn = *const fn (
    ?*anyopaque,
    *const Request,
    *response.Capture,
    client_identity.IpKey,
) anyerror!void;

const ReadFn = *const fn (*anyopaque, [*]u8, usize, ?*anyopaque, *usize, u32) callconv(.c) isize;
const WriteFn = *const fn (*anyopaque, [*]const u8, usize, ?*const anyopaque, usize) callconv(.c) c_int;
const DispatchBridgeFn = *const fn (*anyopaque, *const Request, *response.Capture) callconv(.c) c_int;
const ReleaseFn = *const fn (*anyopaque, *response.Capture) callconv(.c) void;
const StopFn = *const fn (*anyopaque) callconv(.c) c_int;
const NowFn = *const fn (*anyopaque) callconv(.c) u64;

extern fn ziserver_nghttp3_version_text() [*:0]const u8;
extern fn ziserver_nghttp3_serve(
    userdata: *anyopaque,
    read_fn: ReadFn,
    write_fn: WriteFn,
    dispatch_fn: DispatchBridgeFn,
    release_fn: ReleaseFn,
    stop_fn: StopFn,
    now_fn: NowFn,
    ssl_ctx: ?*anyopaque,
    max_header_bytes: usize,
    max_body_bytes: usize,
    max_requests: usize,
    summary: *Summary,
) c_int;

const Bridge = struct {
    socket: *quic_transport.Socket,
    userdata: ?*anyopaque,
    dispatch: DispatchFn,
    stopping: ?*const std.atomic.Value(bool),
    last_now_ns: u64 = 0,
};

pub fn versionText() ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_nghttp3_version_text());
}

pub fn serve(
    socket: *quic_transport.Socket,
    userdata: ?*anyopaque,
    dispatch: DispatchFn,
    max_requests: usize,
    ssl_ctx: ?*anyopaque,
    stopping: ?*const std.atomic.Value(bool),
) !Summary {
    if (!linked) return error.Http3ProviderUnavailable;

    var bridge = Bridge{
        .socket = socket,
        .userdata = userdata,
        .dispatch = dispatch,
        .stopping = stopping,
    };
    var summary = Summary{};
    const result = ziserver_nghttp3_serve(
        &bridge,
        readBridge,
        writeBridge,
        dispatchBridge,
        releaseBridge,
        stopBridge,
        nowBridge,
        ssl_ctx,
        http_config.max_header_bytes,
        http_config.max_form_body_bytes,
        max_requests,
        &summary,
    );
    if (result != 0) return switch (result) {
        -2 => error.Http3ConnectionInitFailed,
        -3 => error.Http3SocketReadFailed,
        -4 => error.Http3TimerFailed,
        -5 => error.Http3PacketReadFailed,
        -6 => error.Http3PacketWriteFailed,
        else => error.Http3SessionFailed,
    };
    return summary;
}

fn readBridge(userdata: *anyopaque, buffer: [*]u8, len: usize, addr_out: ?*anyopaque, addrlen_out: *usize, timeout_ms: u32) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const datagram = (bridge.socket.recvFromTimeout(@max(timeout_ms, 1)) catch |err| {
        logger.message(bridge.socket.io, .warn, "http3_socket_read_failed", "error={t}", .{err});
        return -1;
    }) orelse return 0;
    if (datagram.len > len) return -1;
    @memcpy(buffer[0..datagram.len], bridge.socket.recv_buf[0..datagram.len]);
    // Write back the source address in the platform sockaddr layout expected by ngtcp2.
    if (addr_out) |out_ptr| {
        writeSockaddr(out_ptr, addrlen_out, datagram.from) catch return -1;
    }
    return @intCast(datagram.len);
}

fn writeBridge(
    userdata: *anyopaque,
    buffer: [*]const u8,
    len: usize,
    addr: ?*const anyopaque,
    addrlen: usize,
) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    _ = addr;
    _ = addrlen;
    // The QUIC C adapter writes all packets to the same peer that sent
    // the last datagram. For a single-connection model this works;
    // multi-peer routing needs addr from ngtcp2's path output.
    const data = buffer[0..len];
    bridge.socket.sendTo(data, bridge.socket.last_peer) catch return -1;
    return 0;
}

fn dispatchBridge(
    userdata: *anyopaque,
    request: *const Request,
    captured_response: *response.Capture,
) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const peer_ip = client_identity.IpKey.fromAddress(bridge.socket.last_peer);
    bridge.dispatch(bridge.userdata, request, captured_response, peer_ip) catch |err| {
        logger.message(bridge.socket.io, .warn, "http3_dispatch_failed", "method={s} path={s} error={t}", .{
            request.method(),
            request.path(),
            err,
        });
        captured_response.deinit(capture_allocator);
        captured_response.* = .{};
        var target: response.Target = .{ .capture = .{
            .response = captured_response,
            .allocator = capture_allocator,
            .secure = true,
        } };
        _ = errors.write(&target, errors.kindFromError(err), false, false) catch return -1;
    };
    return 0;
}

fn releaseBridge(_: *anyopaque, captured_response: *response.Capture) callconv(.c) void {
    captured_response.deinit(capture_allocator);
}

fn stopBridge(userdata: *anyopaque) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const stopping = bridge.stopping orelse return 0;
    return @intFromBool(stopping.load(.acquire));
}

fn nowBridge(userdata: *anyopaque) callconv(.c) u64 {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const value = std.Io.Clock.awake.now(bridge.socket.io).nanoseconds;
    return monotonicTimestamp(&bridge.last_now_ns, @intCast(@max(value, 0)));
}

fn monotonicTimestamp(last: *u64, candidate: u64) u64 {
    last.* = @max(last.*, candidate);
    return last.*;
}

test "HTTP3 clock bridge never moves backwards" {
    var last: u64 = 100;
    try std.testing.expectEqual(@as(u64, 100), monotonicTimestamp(&last, 99));
    try std.testing.expectEqual(@as(u64, 100), monotonicTimestamp(&last, 100));
    try std.testing.expectEqual(@as(u64, 101), monotonicTimestamp(&last, 101));
}

fn writeSockaddr(out_ptr: *anyopaque, addrlen_out: *usize, address: std.Io.net.IpAddress) !void {
    const out: [*]u8 = @ptrCast(out_ptr);
    switch (address) {
        .ip4 => |ip4| {
            if (addrlen_out.* < 16) return error.AddressBufferTooSmall;
            const port = std.mem.nativeToBig(u16, ip4.port);
            const bytes = [_]u8{
                2,                     0,
                @intCast(port & 0xff), @intCast(port >> 8),
                ip4.bytes[0],          ip4.bytes[1],
                ip4.bytes[2],          ip4.bytes[3],
                0,                     0,
                0,                     0,
                0,                     0,
                0,                     0,
            };
            @memcpy(out[0..bytes.len], &bytes);
            addrlen_out.* = bytes.len;
        },
        .ip6 => |ip6| {
            if (addrlen_out.* < 28) return error.AddressBufferTooSmall;
            @memset(out[0..28], 0);
            out[0] = if (builtin.os.tag == .windows) 23 else 10;
            const port = std.mem.nativeToBig(u16, ip6.port);
            out[2] = @intCast(port & 0xff);
            out[3] = @intCast(port >> 8);
            @memcpy(out[8..24], &ip6.bytes);
            addrlen_out.* = 28;
        },
    }
}

test "HTTP3 sockaddr bridge preserves IPv4 peer address" {
    var bytes: [128]u8 = @splat(0);
    var len = bytes.len;
    const address = try std.Io.net.IpAddress.parseIp4("192.0.2.44", 18443);
    try writeSockaddr(&bytes, &len, address);
    try std.testing.expectEqual(@as(usize, 16), len);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 44 }, bytes[4..8]);
    try std.testing.expectEqual(@as(u8, 0x48), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x0b), bytes[3]);
}
