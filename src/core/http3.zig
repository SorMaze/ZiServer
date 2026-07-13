const std = @import("std");
const build_options = @import("build_options");

const http_config = @import("http_config.zig");
const http2 = @import("http2.zig");
const quic_transport = @import("quic_transport.zig");
const response = @import("response.zig");

pub const linked = std.mem.eql(u8, build_options.http3_provider, "nghttp3");

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

pub const DispatchFn = http2.DispatchFn;

const ReadFn = *const fn (*anyopaque, [*]u8, usize, ?*anyopaque, *usize) callconv(.c) isize;
const WriteFn = *const fn (*anyopaque, [*]const u8, usize, ?*const anyopaque, usize) callconv(.c) c_int;
const DispatchBridgeFn = *const fn (*anyopaque, *const Request, *response.Capture) callconv(.c) c_int;
const ReleaseFn = *const fn (*anyopaque, *response.Capture) callconv(.c) void;

extern fn ziserver_nghttp3_version_text() [*:0]const u8;
extern fn ziserver_nghttp3_serve(
    userdata: *anyopaque,
    read_fn: ReadFn,
    write_fn: WriteFn,
    dispatch_fn: DispatchBridgeFn,
    release_fn: ReleaseFn,
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
) !Summary {
    if (!linked) return error.Http3ProviderUnavailable;

    var bridge = Bridge{
        .socket = socket,
        .userdata = userdata,
        .dispatch = dispatch,
    };
    var summary = Summary{};
    const result = ziserver_nghttp3_serve(
        &bridge,
        readBridge,
        writeBridge,
        dispatchBridge,
        releaseBridge,
        ssl_ctx,
        http_config.max_header_bytes,
        http_config.max_form_body_bytes,
        max_requests,
        &summary,
    );
    if (result != 0) {
        return error.Http3SessionFailed;
    }
    return summary;
}

fn readBridge(userdata: *anyopaque, buffer: [*]u8, len: usize, addr_out: ?*anyopaque, addrlen_out: *usize) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const datagram = bridge.socket.recvFrom() catch {
        // Sleep briefly on error (wouldBlock etc.) to avoid busy-spinning
        std.Io.sleep(bridge.socket.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
        return -1;
    };
    if (datagram.len > len) return -1;
    @memcpy(buffer[0..datagram.len], bridge.socket.recv_buf[0..datagram.len]);
    // Write back source address as platform sockaddr_in (16 bytes, AF_INET)
    if (addr_out) |out_ptr| {
        const family: u16 = 2; // AF_INET
        const port: u16 = std.mem.nativeToBig(u16, datagram.from.getPort());
        const ip_bytes: [4]u8 = switch (datagram.from) {
            .ip4 => |v4| v4.bytes,
            .ip6 => return -1, // IPv6 not yet supported in C adapter paths
        };
        const sockaddr_bytes = [_]u8{
            @intCast(family & 0xff), @intCast(family >> 8), // sin_family (little-endian short)
            @intCast(port & 0xff), @intCast(port >> 8), // sin_port (already big-endian, store LE)
            ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], // sin_addr
            0, 0, 0, 0, 0, 0, 0, 0, // sin_zero[8]
        };
        @memcpy(@as([*]u8, @ptrCast(out_ptr)), &sockaddr_bytes);
        addrlen_out.* = 16;
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
    bridge.dispatch(bridge.userdata, request, captured_response) catch return -1;
    return 0;
}

fn releaseBridge(_: *anyopaque, captured_response: *response.Capture) callconv(.c) void {
    captured_response.deinit(std.heap.page_allocator);
}
