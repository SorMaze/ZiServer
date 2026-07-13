const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");

// Public routes do not need credentials. Keeping authorization fields out of
// wildcard CORS responses prevents accidentally widening a protected route.
const allowed_headers = "Content-Type";
const max_age_seconds = "600";

pub fn apply(ctx: *Context) !middleware.Decision {
    const policy = ctx.route_options.cors;
    if (policy == .none) return .next;

    if (ctx.request.header("Origin") != null) {
        try addSimpleHeaders(ctx);
    }

    if (ctx.request.method == .options) {
        if (ctx.request.header("Origin") == null) return .next;
        try addPreflightHeaders(ctx, policy);
        try ctx.writeBytesHead(
            .no_content,
            http_config.ContentType.plain,
            "",
            false,
            .no_cache,
            &.{},
        );
        return .stop;
    }

    return .next;
}

fn addSimpleHeaders(ctx: *Context) !void {
    try ctx.addHeader(http_config.HeaderName.access_control_allow_origin, "*");
}

fn addPreflightHeaders(ctx: *Context, policy: http_config.CorsPolicy) !void {
    try ctx.addHeader(http_config.HeaderName.access_control_allow_methods, allowedMethods(policy));
    try ctx.addHeader(http_config.HeaderName.access_control_allow_headers, allowed_headers);
    try ctx.addHeader(http_config.HeaderName.access_control_max_age, max_age_seconds);
}

fn allowedMethods(policy: http_config.CorsPolicy) []const u8 {
    return switch (policy) {
        .none => "",
        .public_read => http_config.MethodSet.safe_with_options,
        .public_form => http_config.MethodSet.with_forms_and_options,
    };
}
