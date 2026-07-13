const http_config = @import("http_config.zig");
const response = @import("response.zig");

pub const Kind = enum {
    bad_request,
    not_found,
    method_not_allowed,
    payload_too_large,
    header_too_large,
    unsupported_media_type,
    invalid_content_encoding,
    invalid_form_encoding,
    invalid_json_encoding,
    invalid_query_encoding,
    invalid_upload,
    missing_upload_file,
    unsafe_upload_filename,
    upload_file_too_large,
    too_many_upload_files,
    unsupported_upload_type,
    upload_already_exists,
    upload_storage_failed,
    unauthorized,
    request_timeout,
    expectation_failed,
    too_many_requests,
    http_version_not_supported,
    forbidden_suspected_xss,
    database_unavailable,
    unknown_handler,
    internal_server_error,
};

pub const Error = error{
    BadRequest,
    NotFound,
    MethodNotAllowed,
    PayloadTooLarge,
    HeaderTooLarge,
    UnsupportedMediaType,
    InvalidContentEncoding,
    InvalidFormEncoding,
    InvalidJsonEncoding,
    InvalidQueryEncoding,
    InvalidUpload,
    MissingUploadFile,
    UnsafeUploadFilename,
    UploadFileTooLarge,
    TooManyUploadFiles,
    UnsupportedUploadType,
    UploadAlreadyExists,
    UploadStorageFailed,
    Unauthorized,
    RequestTimeout,
    ExpectationFailed,
    TooManyRequests,
    HttpVersionNotSupported,
    ForbiddenSuspectedXss,
    DatabaseUnavailable,
    UnknownHandler,
};

pub const WriteSummary = struct {
    status: response.Status,
    body_bytes: usize,
};

const allow_headers = [_]response.Header{
    .{ .name = http_config.HeaderName.allow, .value = http_config.MethodSet.with_forms },
};

const auth_headers = [_]response.Header{
    .{ .name = http_config.HeaderName.www_authenticate, .value = "Bearer" },
};

const rate_limit_headers = [_]response.Header{
    .{ .name = http_config.HeaderName.retry_after, .value = "1" },
};

pub fn status(kind: Kind) response.Status {
    return switch (kind) {
        .bad_request, .invalid_content_encoding, .invalid_form_encoding, .invalid_json_encoding, .invalid_query_encoding, .invalid_upload, .missing_upload_file, .unsafe_upload_filename => .bad_request,
        .not_found => .not_found,
        .method_not_allowed => .method_not_allowed,
        .payload_too_large => .payload_too_large,
        .header_too_large => .request_header_fields_too_large,
        .unsupported_media_type => .unsupported_media_type,
        .unsupported_upload_type => .unsupported_media_type,
        .upload_already_exists => .conflict,
        .upload_storage_failed => .internal_server_error,
        .upload_file_too_large, .too_many_upload_files => .payload_too_large,
        .unauthorized => .unauthorized,
        .request_timeout => .request_timeout,
        .expectation_failed => .expectation_failed,
        .too_many_requests => .too_many_requests,
        .http_version_not_supported => .http_version_not_supported,
        .forbidden_suspected_xss => .forbidden,
        .database_unavailable => .service_unavailable,
        .unknown_handler, .internal_server_error => .internal_server_error,
    };
}

pub fn kindFromError(err: anyerror) Kind {
    return switch (err) {
        error.BadRequest => .bad_request,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.RequestBodyTooLarge,
        error.PayloadTooLarge,
        => .payload_too_large,
        error.RequestHeaderTooLarge,
        error.HeaderTooLarge,
        => .header_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.InvalidContentEncoding => .invalid_content_encoding,
        error.UnsupportedUploadType => .unsupported_upload_type,
        error.UploadAlreadyExists => .upload_already_exists,
        error.UploadStorageFailed => .upload_storage_failed,
        error.InvalidFormEncoding => .invalid_form_encoding,
        error.InvalidUpload => .invalid_upload,
        error.MissingUploadFile => .missing_upload_file,
        error.UnsafeUploadFilename => .unsafe_upload_filename,
        error.UploadFileTooLarge => .upload_file_too_large,
        error.TooManyUploadFiles => .too_many_upload_files,
        error.InvalidJsonEncoding => .invalid_json_encoding,
        error.InvalidQueryEncoding => .invalid_query_encoding,
        error.Unauthorized => .unauthorized,
        error.SlowRequest,
        error.RequestTimeout,
        => .request_timeout,
        error.ExpectationFailed => .expectation_failed,
        error.TooManyRequests => .too_many_requests,
        error.UnsupportedHttpVersion,
        error.HttpVersionNotSupported,
        => .http_version_not_supported,
        error.ForbiddenSuspectedXss => .forbidden_suspected_xss,
        error.DatabaseUnavailable => .database_unavailable,
        error.UnknownHandler => .unknown_handler,
        else => .internal_server_error,
    };
}

pub fn contentType(kind: Kind) []const u8 {
    return switch (kind) {
        .bad_request,
        .not_found,
        .method_not_allowed,
        .payload_too_large,
        .header_too_large,
        .request_timeout,
        .expectation_failed,
        .too_many_requests,
        .http_version_not_supported,
        .internal_server_error,
        => http_config.ContentType.html,
        else => http_config.ContentType.json,
    };
}

pub fn body(kind: Kind) []const u8 {
    return switch (kind) {
        .bad_request => "<!doctype html><h1>400</h1>\n",
        .not_found => "<!doctype html><h1>404</h1>\n",
        .method_not_allowed => "<!doctype html><h1>405</h1>\n",
        .payload_too_large => "<!doctype html><h1>413</h1>\n",
        .header_too_large => "<!doctype html><h1>431</h1>\n",
        .unsupported_media_type => "{\"error\":\"unsupported_media_type\"}\n",
        .invalid_content_encoding => "{\"error\":\"invalid_content_encoding\"}\n",
        .invalid_form_encoding => "{\"error\":\"invalid_form_encoding\"}\n",
        .invalid_json_encoding => "{\"error\":\"invalid_json_encoding\"}\n",
        .invalid_query_encoding => "{\"error\":\"invalid_query_encoding\"}\n",
        .invalid_upload => "{\"error\":\"invalid_upload\"}\n",
        .missing_upload_file => "{\"error\":\"missing_upload_file\"}\n",
        .unsafe_upload_filename => "{\"error\":\"unsafe_upload_filename\"}\n",
        .upload_file_too_large => "{\"error\":\"upload_file_too_large\"}\n",
        .too_many_upload_files => "{\"error\":\"too_many_upload_files\"}\n",
        .unsupported_upload_type => "{\"error\":\"unsupported_upload_type\"}\n",
        .upload_already_exists => "{\"error\":\"upload_already_exists\"}\n",
        .upload_storage_failed => "{\"error\":\"upload_storage_failed\"}\n",
        .unauthorized => "{\"error\":\"unauthorized\"}\n",
        .request_timeout => "<!doctype html><h1>408</h1>\n",
        .expectation_failed => "<!doctype html><h1>417</h1>\n",
        .too_many_requests => "<!doctype html><h1>429</h1>\n",
        .http_version_not_supported => "<!doctype html><h1>505</h1>\n",
        .forbidden_suspected_xss => "{\"error\":\"request_rejected\",\"reason\":\"suspected_xss\"}\n",
        .database_unavailable => "{\"error\":\"database_unavailable\"}\n",
        .unknown_handler => "{\"error\":\"unknown_handler\"}\n",
        .internal_server_error => "<!doctype html><h1>500</h1>\n",
    };
}

pub fn headers(kind: Kind) []const response.Header {
    return switch (kind) {
        .method_not_allowed => &allow_headers,
        .unauthorized => &auth_headers,
        .too_many_requests => &rate_limit_headers,
        else => &.{},
    };
}

pub fn write(
    writer: *response.Target,
    kind: Kind,
    head: bool,
    keep_alive: bool,
) !WriteSummary {
    return writeExtra(writer, kind, head, keep_alive, &.{});
}

pub fn writeExtra(
    writer: *response.Target,
    kind: Kind,
    head: bool,
    keep_alive: bool,
    extra_headers: []const response.Header,
) !WriteSummary {
    const response_body = body(kind);
    const response_status = status(kind);
    var header_buffer: [16]response.Header = undefined;
    const base_headers = headers(kind);
    if (base_headers.len + extra_headers.len > header_buffer.len) return error.ResponseHeaderOverflow;
    @memcpy(header_buffer[0..base_headers.len], base_headers);
    @memcpy(header_buffer[base_headers.len .. base_headers.len + extra_headers.len], extra_headers);

    try response.writeBytes(
        writer,
        response_status,
        contentType(kind),
        response_body,
        head,
        keep_alive,
        .no_cache,
        header_buffer[0 .. base_headers.len + extra_headers.len],
    );
    return .{
        .status = response_status,
        .body_bytes = if (head) 0 else response_body.len,
    };
}
