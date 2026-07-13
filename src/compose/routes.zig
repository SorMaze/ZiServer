const core_http = @import("../core/http.zig");
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");
const router = @import("../core/router.zig");
const services = @import("../core/services.zig");

const auth = @import("auth.zig");
const cache = @import("cache.zig");
const cors = @import("cors.zig");
const content = @import("content.zig");
const database = @import("database.zig");
const json_body = @import("json_body.zig");
const host_guard = @import("host_guard.zig");
const page_cache = @import("page_cache.zig");
const query_guard = @import("query_guard.zig");
const rate_limit = @import("rate_limit.zig");
const upload = @import("upload.zig");
const upload_disk = @import("upload_disk.zig");
const xss = @import("xss.zig");

pub const Registration = struct {
    routes: []const router.Entry,
    dispatch: core_http.DispatchFn,
    auth_credentials: http_config.AuthCredentials = .{},
    services: services.Registry = .{},
    middleware_stack: []const middleware.Middleware = &default_middleware_stack,
};

pub const default_middleware_stack = [_]middleware.Middleware{
    .{ .name = "ziserver_defaults", .run = runDefaults },
};

fn runDefaults(ctx: *@import("../core/context.zig").Context) !middleware.Decision {
    if (try host_guard.validate(ctx) == .stop) return .stop;
    if (try cache.apply(ctx) == .stop) return .stop;
    if (try cors.apply(ctx) == .stop) return .stop;
    if (try rate_limit.limit(ctx) == .stop) return .stop;
    if (try query_guard.validate(ctx) == .stop) return .stop;
    if (try auth.requireAuth(ctx) == .stop) return .stop;
    if (try content.extract(ctx) == .stop) return .stop;
    if (try json_body.validate(ctx) == .stop) return .stop;
    if (try upload.validate(ctx) == .stop) return .stop;
    if (try xss.filter(ctx) == .stop) return .stop;
    if (try database.attach(ctx) == .stop) return .stop;
    if (try upload_disk.apply(ctx) == .stop) return .stop;
    return page_cache.apply(ctx);
}

pub fn buildApplication(registration: Registration) core_http.Application {
    return .{
        .routes = .{ .entries = registration.routes },
        .dispatch = registration.dispatch,
        .middleware_stack = registration.middleware_stack,
        .auth = registration.auth_credentials,
        .services = registration.services,
    };
}

test "buildApplication wires registration through compose middleware" {
    const routes = [_]router.Entry{
        .{ .method = .get, .path = "/health", .handler = 1 },
    };
    const application = buildApplication(.{
        .routes = &routes,
        .dispatch = testDispatch,
    });

    try @import("std").testing.expectEqual(@as(usize, 1), application.routes.entries.len);
    try @import("std").testing.expect(application.middleware_stack.len != 0);
}

fn testDispatch(_: *@import("../core/context.zig").Context, _: router.Handler) anyerror!void {}
