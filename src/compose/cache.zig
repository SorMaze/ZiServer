const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");

pub fn apply(ctx: *Context) !middleware.Decision {
    if (ctx.request.header("Authorization") != null) {
        ctx.setCachePolicy(.no_store);
    } else if (ctx.route_options.cache_strategy) |strategy| {
        ctx.setCachePolicy(strategy.profile().response_cache);
    } else if (ctx.route_options.cache) |policy| {
        ctx.setCachePolicy(policy);
    }
    return .next;
}
