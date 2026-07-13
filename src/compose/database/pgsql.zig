const std = @import("std");

const database = @import("../database.zig");

pub const Config = struct {
    connection_uri: []const u8,
    min_connections: u16 = 1,
    max_connections: u16 = 16,
    acquire_timeout_ms: u32 = 5_000,
    idle_timeout_ms: u32 = 60_000,

    pub fn validate(self: Config) !void {
        if (self.connection_uri.len == 0) return error.InvalidPostgresConfig;
        if (self.min_connections > self.max_connections or self.max_connections == 0) return error.InvalidPostgresConfig;
        if (self.acquire_timeout_ms == 0) return error.InvalidPostgresConfig;
    }
};

/// Adapter boundary implemented by a future libpq or native PostgreSQL driver.
/// ZiServer owns middleware/lifecycle semantics; the driver owns sockets,
/// authentication, pooling and wire-protocol state.
pub const Driver = struct {
    context: *anyopaque,
    open_pool_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator, Config) anyerror!database.Pool,

    pub fn openPool(self: Driver, io: std.Io, allocator: std.mem.Allocator, config: Config) !database.Pool {
        try config.validate();
        return self.open_pool_fn(self.context, io, allocator, config);
    }
};

test "PostgreSQL adapter validates pool bounds before calling a driver" {
    const Stub = struct {
        fn open(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: Config) anyerror!database.Pool {
            return error.DriverShouldNotRun;
        }
    };
    var token: u8 = 0;
    const driver = Driver{ .context = &token, .open_pool_fn = Stub.open };
    try std.testing.expectError(error.InvalidPostgresConfig, driver.openPool(std.testing.io, std.testing.allocator, .{
        .connection_uri = "postgresql://localhost/test",
        .min_connections = 2,
        .max_connections = 1,
    }));
}
