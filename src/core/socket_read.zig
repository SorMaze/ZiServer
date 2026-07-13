const std = @import("std");
const builtin = @import("builtin");
const shutdown = @import("shutdown.zig");

const net = std.Io.net;

pub fn read(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []u8,
    deadline_ns: i96,
) !usize {
    if (buffer.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        return readWindows(io, socket_handle, buffer, deadline_ns, false);
    }

    var buffers: [1][]u8 = .{buffer};
    const operation: std.Io.Operation = .{ .net_read = .{
        .socket_handle = socket_handle,
        .data = &buffers,
    } };
    while (true) {
        if (shutdown.requested()) return error.GracefulShutdown;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        if (deadline_ns != 0 and now_ns >= deadline_ns) return error.ReadTimeout;
        const slice_deadline_ns = @min(
            if (deadline_ns == 0) std.math.maxInt(i96) else deadline_ns,
            now_ns + 50 * std.time.ns_per_ms,
        );
        const result = io.operateTimeout(operation, .{ .deadline = .{
            .raw = .{ .nanoseconds = slice_deadline_ns },
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return error.Canceled,
            error.ConcurrencyUnavailable => return error.TimeoutUnavailable,
        };
        return result.net_read;
    }
}

/// Reads early protocol bytes without consuming them. This is required before
/// choosing plaintext or TLS handling for wrong-listener redirects.
pub fn peek(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []u8,
    deadline_ns: i96,
) !usize {
    if (buffer.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        return readWindows(io, socket_handle, buffer, deadline_ns, true);
    }
    return peekPosix(io, socket_handle, buffer, deadline_ns);
}

pub fn waitReadable(socket_handle: net.Socket.Handle, timeout_ms: u32) !bool {
    if (builtin.os.tag == .windows) return waitReadableWindows(socket_handle, timeout_ms);
    var descriptor = std.posix.pollfd{
        .fd = socket_handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    return (try std.posix.poll((&descriptor)[0..1], @intCast(timeout_ms))) != 0;
}

fn waitReadableWindows(socket_handle: net.Socket.Handle, timeout_ms: u32) !bool {
    const windows = std.os.windows;
    var event: windows.HANDLE = undefined;
    const create_status = windows.ntdll.NtCreateEvent(
        &event,
        @bitCast(@as(u32, 0x001F0003)),
        null,
        .Synchronization,
        .FALSE,
    );
    if (create_status != .SUCCESS) return error.SystemResources;
    defer windows.CloseHandle(event);

    var byte: [1]u8 = undefined;
    var socket_buffer = windows.AFD.WSABUF(.@"var"){ .len = 1, .buf = &byte };
    const receive_info = windows.AFD.RECV_INFO{
        .BufferArray = @ptrCast(&socket_buffer),
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = true, .PEEK = true },
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const submit_status = windows.ntdll.NtDeviceIoControlFile(
        socket_handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.RECEIVE,
        @ptrCast(&receive_info),
        @sizeOf(windows.AFD.RECV_INFO),
        null,
        0,
    );
    if (submit_status == .SUCCESS) return true;
    if (submit_status != .PENDING) return true;

    var interval: windows.LARGE_INTEGER = -@as(i64, @intCast(@max(@as(u64, 1), @as(u64, timeout_ms) * std.time.ns_per_ms / 100)));
    const wait_status = windows.ntdll.NtWaitForSingleObject(event, .FALSE, &interval);
    if (wait_status == .SUCCESS) return true;
    if (wait_status != .TIMEOUT) {
        cancelWindowsRead(socket_handle, event, &iosb);
        return error.ReadFailed;
    }
    cancelWindowsRead(socket_handle, event, &iosb);
    return false;
}

fn readWindows(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []u8,
    deadline_ns: i96,
    peek_only: bool,
) !usize {
    const windows = std.os.windows;
    if (shutdown.requested()) return error.GracefulShutdown;
    var event: windows.HANDLE = undefined;
    const create_status = windows.ntdll.NtCreateEvent(
        &event,
        @bitCast(@as(u32, 0x001F0003)), // EVENT_ALL_ACCESS
        null,
        .Synchronization,
        .FALSE,
    );
    if (create_status != .SUCCESS) return error.SystemResources;
    defer windows.CloseHandle(event);

    var socket_buffer = windows.AFD.WSABUF(.@"var"){
        .len = std.math.cast(windows.ULONG, buffer.len) orelse return error.BufferTooLarge,
        .buf = buffer.ptr,
    };
    const receive_info = windows.AFD.RECV_INFO{
        .BufferArray = @ptrCast(&socket_buffer),
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = true, .PEEK = peek_only },
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const submit_status = windows.ntdll.NtDeviceIoControlFile(
        socket_handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.RECEIVE,
        @ptrCast(&receive_info),
        @sizeOf(windows.AFD.RECV_INFO),
        null,
        0,
    );

    switch (submit_status) {
        .SUCCESS => {},
        .PENDING => {
            while (true) {
                if (shutdown.requested()) {
                    cancelWindowsRead(socket_handle, event, &iosb);
                    return error.GracefulShutdown;
                }
                const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
                if (deadline_ns != 0 and now_ns >= deadline_ns) {
                    cancelWindowsRead(socket_handle, event, &iosb);
                    return error.ReadTimeout;
                }
                const remaining_ns = if (deadline_ns == 0)
                    50 * std.time.ns_per_ms
                else
                    @min(deadline_ns - now_ns, 50 * std.time.ns_per_ms);
                const hundred_ns = @max(@as(i96, 1), @divFloor(remaining_ns + 99, 100));
                var interval: windows.LARGE_INTEGER = -@as(i64, @intCast(hundred_ns));
                const wait_status = windows.ntdll.NtWaitForSingleObject(event, .FALSE, &interval);
                if (wait_status == .TIMEOUT) continue;
                if (wait_status != .SUCCESS) {
                    cancelWindowsRead(socket_handle, event, &iosb);
                    return error.ReadFailed;
                }
                break;
            }
        },
        else => |status| {
            iosb.u.Status = status;
        },
    }

    return switch (iosb.u.Status) {
        .SUCCESS => iosb.Information,
        .CANCELLED => error.Canceled,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        .CONNECTION_RESET => error.ConnectionResetByPeer,
        .END_OF_FILE, .PIPE_DISCONNECTED => 0,
        else => error.ReadFailed,
    };
}

fn peekPosix(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []u8,
    deadline_ns: i96,
) !usize {
    while (true) {
        if (shutdown.requested()) return error.GracefulShutdown;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        if (deadline_ns != 0 and now_ns >= deadline_ns) return error.ReadTimeout;
        const wait_ms: u32 = if (deadline_ns == 0)
            50
        else
            @intCast(@max(@as(i96, 1), @min(@as(i96, 50), @divFloor(deadline_ns - now_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms))));
        if (!try waitReadable(socket_handle, wait_ms)) continue;

        var iov = std.posix.iovec{ .base = buffer.ptr, .len = buffer.len };
        var message = std.posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const result = std.posix.system.recvmsg(socket_handle, &message, std.posix.MSG.PEEK);
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR, .AGAIN => continue,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.ReadFailed,
        }
    }
}

fn cancelWindowsRead(
    socket_handle: net.Socket.Handle,
    event: std.os.windows.HANDLE,
    iosb: *std.os.windows.IO_STATUS_BLOCK,
) void {
    const windows = std.os.windows;
    var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
    _ = windows.ntdll.NtCancelIoFileEx(socket_handle, iosb, &cancel_iosb);
    _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);
}
