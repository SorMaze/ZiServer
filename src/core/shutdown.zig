const std = @import("std");
const builtin = @import("builtin");

var stop_requested: std.atomic.Value(bool) = .init(false);

pub fn install() !void {
    stop_requested.store(false, .release);
    if (builtin.os.tag == .windows) {
        if (SetConsoleCtrlHandler(handleWindowsConsoleEvent, .TRUE) == .FALSE) {
            return error.ConsoleControlHandlerInstallFailed;
        }
        return;
    }

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handlePosixSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

pub fn requested() bool {
    return stop_requested.load(.acquire);
}

pub fn request() void {
    stop_requested.store(true, .release);
}

fn handlePosixSignal(_: c_int) callconv(.c) void {
    request();
}

const WindowsHandler = *const fn (event: u32) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?WindowsHandler,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

fn handleWindowsConsoleEvent(event: u32) callconv(.winapi) std.os.windows.BOOL {
    return switch (event) {
        0, // CTRL_C_EVENT
        1, // CTRL_BREAK_EVENT
        2, // CTRL_CLOSE_EVENT
        5, // CTRL_LOGOFF_EVENT
        6, // CTRL_SHUTDOWN_EVENT
        => blk: {
            request();
            break :blk .TRUE;
        },
        else => .FALSE,
    };
}

test "shutdown request is observable" {
    stop_requested.store(false, .release);
    try std.testing.expect(!requested());
    request();
    try std.testing.expect(requested());
    stop_requested.store(false, .release);
}
