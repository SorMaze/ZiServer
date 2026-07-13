const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");

pub fn limit(ctx: *Context) !middleware.Decision {
    const policy = ctx.route_options.rate_limit;
    if (policy == .none) return .next;
    const limiter = ctx.rate_limiter orelse return error.RateLimiterUnavailable;
    return switch (try limiter.check(ctx.io, ctx.clientIp(), policy)) {
        .allowed => .next,
        .rejected, .capacity_rejected => error.TooManyRequests,
    };
}
