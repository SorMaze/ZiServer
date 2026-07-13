const std = @import("std");

const Context = @import("context.zig").Context;

pub const Decision = enum {
    next,
    stop,
};

pub const Handler = *const fn (*Context) anyerror!Decision;

pub const Middleware = struct {
    name: []const u8,
    run: Handler,
};

pub fn run(ctx: *Context, stack: []const Middleware) !Decision {
    for (stack) |item| {
        const decision = try item.run(ctx);
        if (decision == .stop) return .stop;
    }
    return .next;
}

test "empty middleware stack continues" {
    try std.testing.expectEqual(Decision.next, try run(undefined, &.{}));
}
