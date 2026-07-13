const std = @import("std");

const app_registration = @import("app/register.zig");
const server = @import("core/server.zig");

pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

pub fn main(init: std.process.Init) !u8 {
    return server.start(init, app_registration.buildApplication);
}
