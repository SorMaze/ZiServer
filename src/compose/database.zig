const std = @import("std");

const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");
const services = @import("../core/services.zig");

var pool_service_key: u8 = 0;
var connection_local_key: u8 = 0;

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    text: []const u8,
    bytes: []const u8,
};

pub const CommandResult = struct {
    rows_affected: u64 = 0,
};

pub const Connection = struct {
    handle: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (*anyopaque, []const u8, []const Value) anyerror!CommandResult,
    };

    pub fn exec(self: Connection, statement: []const u8, params: []const Value) !CommandResult {
        return self.vtable.exec(self.handle, statement, params);
    }
};

pub const Pool = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        acquire: *const fn (*anyopaque, std.Io) anyerror!Connection,
        release: *const fn (*anyopaque, *anyopaque) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn acquire(self: *Pool, io: std.Io) !Connection {
        return self.vtable.acquire(self.context, io);
    }

    pub fn release(self: *Pool, value: Connection) void {
        self.vtable.release(self.context, value.handle);
    }

    pub fn deinit(self: *Pool) void {
        self.vtable.deinit(self.context);
    }
};

/// Registers a pool as an application-owned service. The pool and driver state
/// must outlive every request served by the application.
pub fn service(pool: *Pool) services.Entry {
    return .{ .key = &pool_service_key, .value = pool };
}

pub fn attach(ctx: *Context) !middleware.Decision {
    const policy = ctx.route_options.database;
    if (policy == .none or ctx.request.method == .options) return .next;
    const pool = ctx.service(&pool_service_key, Pool) orelse {
        return if (policy == .optional) .next else error.DatabaseUnavailable;
    };
    const acquired = pool.acquire(ctx.io) catch return error.DatabaseUnavailable;
    ctx.setLocal(&connection_local_key, acquired) catch |err| {
        pool.release(acquired);
        return err;
    };
    ctx.registerCleanup(pool, acquired.handle, releaseConnection) catch |err| {
        pool.release(acquired);
        return err;
    };
    return .next;
}

pub fn connection(ctx: *const Context) ?Connection {
    return ctx.local(&connection_local_key, Connection);
}

fn releaseConnection(owner: ?*anyopaque, resource: ?*anyopaque) void {
    const pool: *Pool = @ptrCast(@alignCast(owner orelse return));
    const handle = resource orelse return;
    pool.vtable.release(pool.context, handle);
}

test "database middleware acquires and request cleanup releases" {
    const request_mod = @import("../core/request.zig");
    const response = @import("../core/response.zig");
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const State = struct {
        acquired: usize = 0,
        released: usize = 0,
        connection_token: u8 = 0,

        fn acquire(raw: *anyopaque, _: std.Io) anyerror!Connection {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.acquired += 1;
            return .{ .handle = &self.connection_token, .vtable = &connection_vtable };
        }

        fn release(raw: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.released += 1;
        }

        fn exec(_: *anyopaque, _: []const u8, _: []const Value) anyerror!CommandResult {
            return .{ .rows_affected = 1 };
        }

        fn deinit(_: *anyopaque) void {}

        const connection_vtable = Connection.VTable{ .exec = exec };
        const pool_vtable = Pool.VTable{ .acquire = acquire, .release = release, .deinit = deinit };
    };

    var state = State{};
    var pool = Pool{ .context = &state, .vtable = &State.pool_vtable };
    const service_entries = [_]services.Entry{service(&pool)};
    const request = try request_mod.Request.parse("GET /db HTTP/1.1\r\nHost: test\r\n\r\n");
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .database = .required },
        router.Params.empty(),
        .{},
        .{ .entries = &service_entries },
        null,
    );
    try std.testing.expectEqual(middleware.Decision.next, try attach(&ctx));
    try std.testing.expectEqual(@as(usize, 1), state.acquired);
    try std.testing.expectEqual(@as(u64, 1), (try connection(&ctx).?.exec("update test", &.{})).rows_affected);
    ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.released);
}

test "required database fails closed when no pool is registered" {
    const request_mod = @import("../core/request.zig");
    const response = @import("../core/response.zig");
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const request = try request_mod.Request.parse("GET /db HTTP/1.1\r\nHost: test\r\n\r\n");
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .database = .required },
        router.Params.empty(),
        .{},
        services.Registry{},
        null,
    );
    try std.testing.expectError(error.DatabaseUnavailable, attach(&ctx));
}
