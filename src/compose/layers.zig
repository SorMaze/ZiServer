const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware_mod = @import("../core/middleware.zig");
const page_cache = @import("../core/page_cache.zig");
const router = @import("../core/router.zig");

const json_body = @import("json_body.zig");
const xss = @import("xss.zig");

/// A declarative route contribution. Feature-specific constructors live in
/// this module; the generic DSL only knows how to merge Layer values.
pub const Layer = struct {
    name: []const u8,
    options: router.Options = .{},
    middleware: ?middleware_mod.Middleware = null,
};

pub fn auth(value: http_config.AuthPolicy) Layer {
    return .{ .name = "auth", .options = .{ .auth = value } };
}

pub fn requireAuth() Layer {
    return .{ .name = "require_auth", .options = .{ .require_auth = true } };
}

pub fn bodyLimit(value: usize) Layer {
    return .{ .name = "body_limit", .options = .{ .body_limit = value } };
}

pub fn streamingBody() Layer {
    return .{ .name = "streaming_body", .options = .{ .streaming_body = true } };
}

pub fn jsonBody() Layer {
    return middlewareFlags("json_body", json_body.flag_validate_json_body);
}

pub fn jsonBodyLimit(value: usize) Layer {
    var result = middlewareFlags("json_body_limit", json_body.flag_validate_json_body);
    result.options.body_limit = value;
    return result;
}

pub fn cache(value: http_config.CachePolicy) Layer {
    return .{ .name = "cache", .options = .{ .cache = value } };
}

pub fn pageCache(value: page_cache.Policy) Layer {
    return .{ .name = "page_cache", .options = .{ .page_cache = value } };
}

pub fn upload(value: http_config.UploadPolicy) Layer {
    return .{
        .name = "upload",
        .options = .{ .body_limit = value.max_request_bytes, .upload = value },
    };
}

pub fn smallFileUpload(value: http_config.SmallFileUploadConfig) Layer {
    return .{
        .name = "small_file_upload",
        .options = .{
            .body_limit = value.validation.max_request_bytes,
            .upload = value.validation,
            .upload_landing = .{ .small = value },
        },
    };
}

pub fn streamFileUpload(value: http_config.StreamFileUploadConfig) Layer {
    return .{
        .name = "stream_file_upload",
        .options = .{
            .body_limit = value.max_request_bytes,
            .upload_landing = .{ .stream = value },
            .streaming_body = true,
        },
    };
}

pub fn database(value: http_config.DatabasePolicy) Layer {
    return .{ .name = "database", .options = .{ .database = value } };
}

pub fn content(value: http_config.ContentPolicy) Layer {
    var result = Layer{ .name = "content", .options = .{ .content = value } };
    if (value.request != .none) {
        result.options.body_limit = value.max_request_bytes orelse http_config.max_form_body_bytes;
    }
    return result;
}

/// JSON API routes parse typed input and serialize typed output in the handler.
/// The API façade therefore owns the one required parse and serialization is
/// already valid JSON; do not run generic validation a second time.
pub fn apiJson(max_request_bytes: usize) Layer {
    return content(.{
        .request = .json,
        .response = .json,
        .max_request_bytes = max_request_bytes,
        .request_validation = .none,
        .response_validation = .none,
    });
}

pub fn extract(format: http_config.Representation, max_request_bytes: usize) Layer {
    return content(.{ .request = format, .max_request_bytes = max_request_bytes });
}

pub fn inject(format: http_config.Representation) Layer {
    return content(.{ .response = format });
}

pub fn cors(value: http_config.CorsPolicy) Layer {
    return .{ .name = "cors", .options = .{ .cors = value } };
}

pub fn rate(value: http_config.RateLimitPolicy) Layer {
    return .{ .name = "rate_limit", .options = .{ .rate_limit = value } };
}

pub fn middlewareFlags(name: []const u8, value: u32) Layer {
    return .{ .name = name, .options = .{ .middleware_flags = value } };
}

pub fn xssObserve() Layer {
    return middlewareFlags("xss_observe", xss.flag_observe);
}

pub fn xssBlock() Layer {
    return middlewareFlags("xss_block", xss.flag_block);
}

pub fn middleware(comptime name: []const u8, run: *const fn (*Context) anyerror!middleware_mod.Decision) Layer {
    return .{ .name = name, .middleware = .{ .name = name, .run = run } };
}
