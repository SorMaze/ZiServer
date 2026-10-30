const std = @import("std");
const builtin = @import("builtin");
const shutdown = @import("shutdown.zig");

const net = std.Io.net;

pub fn write(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []const u8,
    deadline_ns: i96,
) !usize {
    if (buffer.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        return writeWindows(io, socket_handle, buffer, deadline_ns);
    }

    const operation: std.Io.Operation = .{ .net_write = .{
        .socket_handle = socket_handle,
        .header = &.{},
        .data = &.{buffer},
        .splat = 1,
    } };
    while (true) {
        if (shutdown.requested()) return error.GracefulShutdown;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        if (deadline_ns != 0 and now_ns >= deadline_ns) return error.WriteTimeout;
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
        return result.net_write catch error.WriteFailed;
    }
}

fn writeWindows(
    io: std.Io,
    socket_handle: net.Socket.Handle,
    buffer: []const u8,
    deadline_ns: i96,
) !usize {
    const windows = std.os.windows;
    if (shutdown.requested()) return error.GracefulShutdown;
    if (deadline_ns != 0 and std.Io.Clock.awake.now(io).nanoseconds >= deadline_ns) return error.WriteTimeout;
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

    var socket_buffer = windows.AFD.WSABUF(.@"const"){
        .len = std.math.cast(windows.ULONG, buffer.len) orelse return error.BufferTooLarge,
        .buf = buffer.ptr,
    };
    const send_info = windows.AFD.SEND_INFO{
        .BufferArray = @ptrCast(&socket_buffer),
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const submit_status = windows.ntdll.NtDeviceIoControlFile(
        socket_handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.SEND,
        @ptrCast(&send_info),
        @sizeOf(windows.AFD.SEND_INFO),
        null,
        0,
    );

    switch (submit_status) {
        .SUCCESS => {},
        .PENDING => {
            while (true) {
                if (shutdown.requested()) {
                    cancelWindowsWrite(socket_handle, event, &iosb);
                    return error.GracefulShutdown;
                }
                const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
                if (deadline_ns != 0 and now_ns >= deadline_ns) {
                    cancelWindowsWrite(socket_handle, event, &iosb);
                    return error.WriteTimeout;
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
                    cancelWindowsWrite(socket_handle, event, &iosb);
                    return error.WriteFailed;
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
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.WriteTimeout,
        else => error.WriteFailed,
    };
}

fn cancelWindowsWrite(
    socket_handle: net.Socket.Handle,
    event: std.os.windows.HANDLE,
    iosb: *std.os.windows.IO_STATUS_BLOCK,
) void {
    const windows = std.os.windows;
    var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
    _ = windows.ntdll.NtCancelIoFileEx(socket_handle, iosb, &cancel_iosb);
    _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);
}
