pub const h2c_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const max_header_bytes: usize = 4096;
pub const max_form_body_bytes: usize = 16 * 1024;
pub const max_stream_body_bytes: usize = 1024 * 1024 * 1024;
pub const max_chunk_overhead_bytes: usize = 8 * 1024;
pub const max_static_file_bytes: usize = 1024 * 1024;
pub const max_request_bytes: usize = max_header_bytes + max_form_body_bytes + max_chunk_overhead_bytes;
pub const max_header_read_ops: usize = 64;
pub const max_body_read_ops: usize = 256;
pub const default_static_dir = "public";

pub const StaticMode = enum {
    embedded,
    filesystem,
};

pub const MethodSet = struct {
    pub const safe = "GET, HEAD";
    pub const with_forms = "GET, HEAD, POST";
    pub const safe_with_options = "GET, HEAD, OPTIONS";
    pub const with_forms_and_options = "GET, HEAD, POST, OPTIONS";
};

pub const HeaderName = struct {
    pub const access_control_allow_headers = "Access-Control-Allow-Headers";
    pub const access_control_allow_methods = "Access-Control-Allow-Methods";
    pub const access_control_allow_origin = "Access-Control-Allow-Origin";
    pub const access_control_max_age = "Access-Control-Max-Age";
    pub const access_control_request_method = "Access-Control-Request-Method";
    pub const allow = "Allow";
    pub const cache_control = "Cache-Control";
    pub const connection = "Connection";
    pub const content_length = "Content-Length";
    pub const content_type = "Content-Type";
    pub const location = "Location";
    pub const transfer_encoding = "Transfer-Encoding";
    pub const authorization = "Authorization";
    pub const server = "Server";
    pub const www_authenticate = "WWW-Authenticate";
    pub const x_api_key = "X-API-Key";
    pub const retry_after = "Retry-After";
};

pub const HeaderValue = struct {
    pub const close = "close";
    pub const keep_alive = "keep-alive";
    pub const h2c = "h2c";
};

pub const ContentType = struct {
    pub const plain = "text/plain; charset=utf-8";
    pub const html = "text/html; charset=utf-8";
    pub const json = "application/json; charset=utf-8";
    pub const json_media = "application/json";
    pub const css = "text/css; charset=utf-8";
    pub const javascript = "application/javascript; charset=utf-8";
    pub const svg = "image/svg+xml";
    pub const png = "image/png";
    pub const icon = "image/x-icon";
    pub const octet_stream = "application/octet-stream";
    pub const form_urlencoded = "application/x-www-form-urlencoded";
    pub const multipart_form = "multipart/form-data";
    pub const xml = "application/xml; charset=utf-8";
    pub const xml_media = "application/xml";
    pub const toml = "application/toml; charset=utf-8";
    pub const toml_media = "application/toml";
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Status = struct {
    code: u16,
    reason: []const u8,

    pub const ok: Status = .{ .code = 200, .reason = "OK" };
    pub const no_content: Status = .{ .code = 204, .reason = "No Content" };
    pub const accepted: Status = .{ .code = 202, .reason = "Accepted" };
    pub const permanent_redirect: Status = .{ .code = 308, .reason = "Permanent Redirect" };
    pub const bad_request: Status = .{ .code = 400, .reason = "Bad Request" };
    pub const conflict: Status = .{ .code = 409, .reason = "Conflict" };
    pub const unauthorized: Status = .{ .code = 401, .reason = "Unauthorized" };
    pub const request_timeout: Status = .{ .code = 408, .reason = "Request Timeout" };
    pub const expectation_failed: Status = .{ .code = 417, .reason = "Expectation Failed" };
    pub const forbidden: Status = .{ .code = 403, .reason = "Forbidden" };
    pub const not_found: Status = .{ .code = 404, .reason = "Not Found" };
    pub const method_not_allowed: Status = .{ .code = 405, .reason = "Method Not Allowed" };
    pub const payload_too_large: Status = .{ .code = 413, .reason = "Payload Too Large" };
    pub const unsupported_media_type: Status = .{ .code = 415, .reason = "Unsupported Media Type" };
    pub const request_header_fields_too_large: Status = .{ .code = 431, .reason = "Request Header Fields Too Large" };
    pub const too_many_requests: Status = .{ .code = 429, .reason = "Too Many Requests" };
    pub const http_version_not_supported: Status = .{ .code = 505, .reason = "HTTP Version Not Supported" };
    pub const internal_server_error: Status = .{ .code = 500, .reason = "Internal Server Error" };
    pub const service_unavailable: Status = .{ .code = 503, .reason = "Service Unavailable" };
};

pub const TlsMode = enum {
    off,
    terminate,

    pub fn text(self: TlsMode) []const u8 {
        return switch (self) {
            .off => "off",
            .terminate => "terminate",
        };
    }
};

pub const TlsMinVersion = enum {
    tls12,
    tls13,

    pub fn text(self: TlsMinVersion) []const u8 {
        return switch (self) {
            .tls12 => "1.2",
            .tls13 => "1.3",
        };
    }
};

pub const Http2Mode = enum {
    off,
    reject,
    on,

    pub fn text(self: Http2Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .reject => "reject",
            .on => "on",
        };
    }
};

pub const Http3Mode = enum {
    off,
    advertise,

    pub fn text(self: Http3Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .advertise => "advertise",
        };
    }
};

pub const TlsConfig = struct {
    mode: TlsMode = .off,
    min_version: TlsMinVersion = .tls12,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
};

pub const CachePolicy = enum {
    none,
    no_cache,
    static_asset,
    api_short,

    pub fn value(self: CachePolicy) ?[]const u8 {
        return switch (self) {
            .none => null,
            .no_cache => "no-cache",
            .static_asset => "public, max-age=3600",
            .api_short => "public, max-age=30",
        };
    }

    pub fn text(self: CachePolicy) []const u8 {
        return switch (self) {
            .none => "none",
            .no_cache => "no-cache",
            .static_asset => "static-asset",
            .api_short => "api-short",
        };
    }
};

pub const CorsPolicy = enum {
    none,
    public_read,
    public_form,
};

pub const AuthPolicy = enum {
    none,
    bearer,
    api_key,
    bearer_or_api_key,
};

pub const AuthCredentials = struct {
    bearer_token: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

pub const UploadPolicy = struct {
    max_request_bytes: usize = max_form_body_bytes,
    max_file_bytes: usize = 8 * 1024,
    max_files: usize = 1,
    require_file: bool = true,
    allowed_content_types: []const []const u8 = &.{},
    allowed_extensions: []const []const u8 = &.{},
};

pub const UploadNaming = enum {
    random,
    original,
};

pub const UploadCollision = enum {
    reject,
    replace,
};

pub const UploadDiskConfig = struct {
    directory: []const u8,
    naming: UploadNaming = .random,
    collision: UploadCollision = .reject,
    create_directory: bool = true,
    sync_on_finish: bool = false,
};

pub const SmallFileUploadConfig = struct {
    validation: UploadPolicy = .{},
    storage: UploadDiskConfig,
};

/// A large streaming upload is one raw file per request. The client supplies
/// the untrusted display filename in `filename_header`; middleware validates
/// it before choosing the final server-side name.
pub const StreamFileUploadConfig = struct {
    max_request_bytes: usize = 256 * 1024 * 1024,
    require_nonempty: bool = true,
    filename_header: []const u8 = "X-Upload-Filename",
    allowed_content_types: []const []const u8 = &.{ContentType.octet_stream},
    allowed_extensions: []const []const u8 = &.{},
    storage: UploadDiskConfig,
};

pub const UploadLanding = union(enum) {
    none,
    small: SmallFileUploadConfig,
    stream: StreamFileUploadConfig,
};

pub const DatabasePolicy = enum {
    none,
    optional,
    required,
};

pub const Representation = enum {
    none,
    json,
    xml,
    html,
    toml,
    binary,
    custom,
};

/// Built-in textual formats use bounded lexical validation. JSON uses the
/// standard parser; XML/HTML/TOML remain borrowed document views rather than
/// allocating a framework-owned syntax tree.
pub const RepresentationValidation = enum {
    none,
    basic,
};

pub const ContentPolicy = struct {
    request: Representation = .none,
    response: Representation = .none,
    max_request_bytes: ?usize = null,
    request_validation: RepresentationValidation = .basic,
    response_validation: RepresentationValidation = .basic,
    request_content_type: ?[]const u8 = null,
    response_content_type: ?[]const u8 = null,
    request_codec: u16 = 0,
    response_codec: u16 = 0,
};

pub const RateLimitPolicy = enum {
    none,
    relaxed,
    strict,
};

pub const XssFilterMode = enum {
    off,
    observe,
    block,

    pub fn text(self: XssFilterMode) []const u8 {
        return switch (self) {
            .off => "off",
            .observe => "observe",
            .block => "block",
        };
    }
};

/// Narrow application-construction input passed by the core startup service.
/// It keeps core independent from the concrete app and compose modules.
pub const ApplicationStartupConfig = struct {
    auth: AuthCredentials = .{},
    xss_mode: XssFilterMode = .off,
    xss_scan_query: bool = true,
    xss_scan_body: bool = true,
};
