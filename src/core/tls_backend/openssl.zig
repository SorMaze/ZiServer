const std = @import("std");
const socket_read = @import("../socket_read.zig");
const build_options = @import("build_options");
const http_config = @import("../http_config.zig");

pub const linked = std.mem.eql(u8, build_options.tls_provider, "openssl");

extern fn ziserver_openssl_version_number() c_ulong;
extern fn ziserver_openssl_version_text() [*:0]const u8;
extern fn ziserver_openssl_server_ctx_new(
    cert_file: [*:0]const u8,
    key_file: [*:0]const u8,
    min_tls_version: c_int,
    advertise_h2: c_int,
) ?*anyopaque;
extern fn ziserver_openssl_server_ctx_free(ctx: ?*anyopaque) void;
extern fn ziserver_openssl_client_ctx_new(verify_peer: c_int) ?*anyopaque;
extern fn ziserver_openssl_client_ctx_free(ctx: ?*anyopaque) void;
extern fn ziserver_openssl_last_error() c_ulong;
const IoReadFn = *const fn (?*anyopaque, *const anyopaque, usize, [*]u8, c_int, i64) callconv(.c) c_int;
const IoWriteFn = *const fn (?*anyopaque, *const anyopaque, usize, [*]const u8, c_int) callconv(.c) c_int;

extern fn ziserver_openssl_server_conn_new(
    ctx: *anyopaque,
    userdata: ?*anyopaque,
    vtable: *const anyopaque,
    socket_handle: usize,
    read_deadline_ns: i64,
    read_fn: IoReadFn,
    write_fn: IoWriteFn,
) ?*anyopaque;
extern fn ziserver_openssl_server_conn_free(conn: ?*anyopaque) void;
extern fn ziserver_openssl_client_conn_new(
    ctx: *anyopaque,
    userdata: ?*anyopaque,
    vtable: *const anyopaque,
    socket_handle: usize,
    read_deadline_ns: i64,
    read_fn: IoReadFn,
    write_fn: IoWriteFn,
    server_name: [*:0]const u8,
    advertise_h2: c_int,
) ?*anyopaque;
extern fn ziserver_openssl_conn_read(conn: *anyopaque, buffer: [*]u8, len: c_int) c_int;
extern fn ziserver_openssl_conn_pending(conn: *anyopaque) c_int;
extern fn ziserver_openssl_conn_write(conn: *anyopaque, buffer: [*]const u8, len: c_int) c_int;
extern fn ziserver_openssl_last_ssl_error() c_int;
extern fn ziserver_openssl_last_io_error() c_int;
extern fn ziserver_openssl_last_error_text() [*:0]const u8;
extern fn ziserver_openssl_conn_alpn(conn: *anyopaque) c_int;
extern fn ziserver_openssl_conn_set_read_deadline(conn: *anyopaque, deadline_ns: i64) void;
extern fn ziserver_openssl_conn_version(conn: *anyopaque) [*:0]const u8;
extern fn ziserver_openssl_conn_cipher(conn: *anyopaque) [*:0]const u8;
extern fn ziserver_openssl_conn_session_reused(conn: *anyopaque) c_int;

pub const NegotiatedProtocol = enum {
    none,
    http1_1,
    h2,
    unknown,
};

pub fn supportsTerminate() bool {
    return linked;
}

pub fn versionNumber() ?c_ulong {
    if (!linked) return null;
    return ziserver_openssl_version_number();
}

pub fn versionText() ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_openssl_version_text());
}

pub fn lastError() ?c_ulong {
    if (!linked) return null;
    return ziserver_openssl_last_error();
}

pub fn lastSslError() ?c_int {
    if (!linked) return null;
    return ziserver_openssl_last_ssl_error();
}

pub fn lastIoError() ?c_int {
    if (!linked) return null;
    return ziserver_openssl_last_io_error();
}

pub fn lastErrorText() ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_openssl_last_error_text());
}

pub fn initServerHandle(
    allocator: std.mem.Allocator,
    cert_file: []const u8,
    key_file: []const u8,
    min_version: http_config.TlsMinVersion,
    advertise_h2: bool,
) !*anyopaque {
    if (!linked) return error.TlsProviderUnavailable;

    const cert_z = try allocator.allocSentinel(u8, cert_file.len, 0);
    defer allocator.free(cert_z);
    @memcpy(cert_z[0..cert_file.len], cert_file);
    const key_z = try allocator.allocSentinel(u8, key_file.len, 0);
    defer allocator.free(key_z);
    @memcpy(key_z[0..key_file.len], key_file);

    const min_tls_version: c_int = switch (min_version) {
        .tls12 => 12,
        .tls13 => 13,
    };
    return ziserver_openssl_server_ctx_new(
        cert_z.ptr,
        key_z.ptr,
        min_tls_version,
        @intFromBool(advertise_h2),
    ) orelse error.TlsContextInitFailed;
}

pub fn freeServerHandle(handle: ?*anyopaque) void {
    if (linked) ziserver_openssl_server_ctx_free(handle);
}

pub fn initClientHandle(verify_peer: bool) !*anyopaque {
    if (!linked) return error.TlsProviderUnavailable;
    return ziserver_openssl_client_ctx_new(@intFromBool(verify_peer)) orelse error.TlsContextInitFailed;
}

pub fn freeClientHandle(handle: ?*anyopaque) void {
    if (linked) ziserver_openssl_client_ctx_free(handle);
}

pub fn initConnectionHandle(
    server_handle: *anyopaque,
    io: std.Io,
    socket_handle: usize,
    read_deadline_ns: i64,
) !*anyopaque {
    if (!linked) return error.TlsProviderUnavailable;
    return ziserver_openssl_server_conn_new(
        server_handle,
        io.userdata,
        @ptrCast(io.vtable),
        socket_handle,
        read_deadline_ns,
        tlsIoRead,
        tlsIoWrite,
    ) orelse if (lastIoError() == -2) error.TlsHandshakeTimeout else error.TlsHandshakeFailed;
}

pub fn initClientConnectionHandle(
    allocator: std.mem.Allocator,
    client_handle: *anyopaque,
    io: std.Io,
    socket_handle: usize,
    read_deadline_ns: i64,
    server_name: []const u8,
    advertise_h2: bool,
) !*anyopaque {
    if (!linked) return error.TlsProviderUnavailable;
    const server_name_z = try allocator.allocSentinel(u8, server_name.len, 0);
    defer allocator.free(server_name_z);
    @memcpy(server_name_z[0..server_name.len], server_name);
    return ziserver_openssl_client_conn_new(
        client_handle,
        io.userdata,
        @ptrCast(io.vtable),
        socket_handle,
        read_deadline_ns,
        tlsIoRead,
        tlsIoWrite,
        server_name_z.ptr,
        @intFromBool(advertise_h2),
    ) orelse if (lastIoError() == -2) error.TlsHandshakeTimeout else error.TlsHandshakeFailed;
}

pub fn freeConnectionHandle(handle: ?*anyopaque) void {
    if (linked) ziserver_openssl_server_conn_free(handle);
}

pub fn read(handle: *anyopaque, buffer: []u8) !usize {
    if (!linked) return error.TlsProviderUnavailable;
    if (buffer.len == 0) return 0;
    const max_len: usize = @intCast(std.math.maxInt(c_int));
    const len: c_int = @intCast(@min(buffer.len, max_len));
    const n = ziserver_openssl_conn_read(handle, buffer.ptr, len);
    if (n < 0) return switch (lastIoError() orelse 0) {
        -2 => error.ReadTimeout,
        -4 => error.GracefulShutdown,
        else => error.TlsReadFailed,
    };
    return @intCast(n);
}

pub fn hasPendingRead(handle: *anyopaque) bool {
    return linked and ziserver_openssl_conn_pending(handle) > 0;
}

pub fn setReadDeadline(handle: *anyopaque, deadline_ns: i64) void {
    if (linked) ziserver_openssl_conn_set_read_deadline(handle, deadline_ns);
}

pub fn write(handle: *anyopaque, buffer: []const u8) !usize {
    if (!linked) return error.TlsProviderUnavailable;
    if (buffer.len == 0) return 0;
    const max_len: usize = @intCast(std.math.maxInt(c_int));
    const len: c_int = @intCast(@min(buffer.len, max_len));
    const n = ziserver_openssl_conn_write(handle, buffer.ptr, len);
    if (n <= 0) return error.TlsWriteFailed;
    return @intCast(n);
}

pub fn negotiatedProtocol(handle: *anyopaque) NegotiatedProtocol {
    if (!linked) return .none;
    return switch (ziserver_openssl_conn_alpn(handle)) {
        0 => .none,
        1 => .http1_1,
        2 => .h2,
        else => .unknown,
    };
}

pub fn protocolVersionText(handle: *anyopaque) ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_openssl_conn_version(handle));
}

pub fn cipherText(handle: *anyopaque) ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_openssl_conn_cipher(handle));
}

pub fn sessionReused(handle: *anyopaque) bool {
    return linked and ziserver_openssl_conn_session_reused(handle) != 0;
}

fn tlsIoRead(
    userdata: ?*anyopaque,
    vtable_ptr: *const anyopaque,
    socket_handle: usize,
    buffer: [*]u8,
    len: c_int,
    read_deadline_ns: i64,
) callconv(.c) c_int {
    if (len <= 0) return 0;
    const io = ioFromParts(userdata, vtable_ptr);
    const bytes_read = socket_read.read(
        io,
        handleFromValue(socket_handle),
        buffer[0..@intCast(len)],
        read_deadline_ns,
    ) catch |err| switch (err) {
        // A peer can close an HTTP/2 connection without a TLS close_notify
        // after receiving GOAWAY. Surface it as EOF so the protocol adapter
        // drains the session normally instead of reporting a callback error.
        error.ConnectionResetByPeer => return 0,
        error.ReadTimeout => return -2,
        error.Canceled => return -3,
        error.GracefulShutdown => return -4,
        else => return -1,
    };
    return @intCast(bytes_read);
}

fn tlsIoWrite(
    userdata: ?*anyopaque,
    vtable_ptr: *const anyopaque,
    socket_handle: usize,
    buffer: [*]const u8,
    len: c_int,
) callconv(.c) c_int {
    if (len <= 0) return 0;
    const io = ioFromParts(userdata, vtable_ptr);
    const bytes = buffer[0..@intCast(len)];
    const written = io.vtable.netWrite(
        io.userdata,
        handleFromValue(socket_handle),
        &.{},
        &.{bytes},
        1,
    ) catch return -1;
    return @intCast(written);
}

fn ioFromParts(userdata: ?*anyopaque, vtable_ptr: *const anyopaque) std.Io {
    const vtable: *const std.Io.VTable = @ptrCast(@alignCast(vtable_ptr));
    return .{ .userdata = userdata, .vtable = vtable };
}

fn handleFromValue(value: usize) std.Io.net.Socket.Handle {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @ptrFromInt(value),
        .int => @intCast(value),
        .comptime_int => @intCast(value),
        else => @compileError("unsupported socket handle type"),
    };
}
