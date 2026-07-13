pub const linked = false;

pub fn supportsTerminate() bool {
    return false;
}

pub fn versionText() ?[:0]const u8 {
    return null;
}

pub fn lastError() ?c_ulong {
    return null;
}

pub fn initServerHandle(_: anytype, _: []const u8, _: []const u8) !*anyopaque {
    return error.TlsProviderUnavailable;
}

pub fn freeServerHandle(_: ?*anyopaque) void {}

pub fn initConnectionHandle(_: *anyopaque, _: usize) !*anyopaque {
    return error.TlsProviderUnavailable;
}

pub fn freeConnectionHandle(_: ?*anyopaque) void {}

pub fn read(_: *anyopaque, _: []u8) !usize {
    return error.TlsReadFailed;
}

pub fn write(_: *anyopaque, _: []const u8) !usize {
    return error.TlsWriteFailed;
}
