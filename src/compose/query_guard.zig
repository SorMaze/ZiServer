const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");

pub fn validate(ctx: *Context) !middleware.Decision {
    if (ctx.query.valid) return .next;
    return error.InvalidQueryEncoding;
}
