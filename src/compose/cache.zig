const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");

pub fn apply(ctx: *Context) !middleware.Decision {
    if (ctx.route_options.cache) |policy| {
        ctx.setCachePolicy(policy);
    }
    return .next;
}
