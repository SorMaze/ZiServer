test {
    _ = @import("layering_tests.zig");
    _ = @import("core/config.zig");
    _ = @import("core/client_identity.zig");
    _ = @import("core/rate_limiter.zig");
    _ = @import("core/protocol_redirect.zig");
    _ = @import("core/request.zig");
    _ = @import("core/locals.zig");
    _ = @import("core/services.zig");
    _ = @import("core/router.zig");
    _ = @import("core/response.zig");
    _ = @import("core/streaming.zig");
}
