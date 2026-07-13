const std = @import("std");

const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");
const response = @import("../core/response.zig");
const services = @import("../core/services.zig");
const json_body = @import("json_body.zig");

var document_local_key: u8 = 0;
var runtime_service_key: u8 = 0;

/// A request-scoped, allocation-free view over the normalized request body.
/// Built-in codecs keep bytes borrowed from Request; typed parsing remains an
/// explicit application concern so compose does not own an unbounded AST.
pub const Document = struct {
    format: http_config.Representation,
    codec_id: u16 = 0,
    bytes: []const u8,

    pub fn asBytes(self: Document) []const u8 {
        return self.bytes;
    }

    pub fn asText(self: Document) ![]const u8 {
        if (self.format == .binary) return error.BinaryDocument;
        return self.bytes;
    }

    pub fn parseJson(
        self: Document,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) json_body.ParseError!std.json.Parsed(T) {
        if (self.format != .json) return error.UnsupportedMediaType;
        return json_body.parseFromSlice(T, allocator, self.bytes);
    }
};

pub const ExtractFn = *const fn (*Context, []const u8) anyerror![]const u8;
pub const InjectFn = *const fn (*Context, response.Status, []const u8, response.CachePolicy) anyerror!void;

/// App-owned custom codec. Extractors may select or normalize only by returning
/// a subslice of the request body; allocating transforms belong in app code and
/// can be released with Context.registerCleanup.
pub const Codec = struct {
    id: u16,
    request_content_types: []const []const u8 = &.{},
    response_content_type: []const u8 = http_config.ContentType.octet_stream,
    extract: ?ExtractFn = null,
    inject: ?InjectFn = null,
};

pub const Runtime = struct {
    codecs: []const Codec,

    pub fn init(codecs: []const Codec) !Runtime {
        for (codecs, 0..) |codec, index| {
            if (codec.id == 0) return error.InvalidContentCodecId;
            for (codecs[0..index]) |previous| {
                if (previous.id == codec.id) return error.DuplicateContentCodecId;
            }
        }
        return .{ .codecs = codecs };
    }

    pub fn find(self: *const Runtime, id: u16) ?*const Codec {
        for (self.codecs) |*codec| {
            if (codec.id == id) return codec;
        }
        return null;
    }
};

pub fn service(runtime: *Runtime) services.Entry {
    return .{ .key = &runtime_service_key, .value = runtime };
}

/// Default compose middleware entry point. It validates media type and size,
/// then stores one borrowed Document in Context locals.
pub fn extract(ctx: *Context) !middleware.Decision {
    const policy = ctx.route_options.content orelse return .next;
    if (policy.request == .none) return .next;
    if (ctx.route_options.streaming_body) return error.StreamingContentRequiresAppReader;

    const max_bytes = policy.max_request_bytes orelse http_config.max_form_body_bytes;
    if (ctx.request.body.len > max_bytes) return error.PayloadTooLarge;

    var bytes = ctx.request.body;
    var codec_id: u16 = 0;
    if (policy.request == .custom) {
        codec_id = policy.request_codec;
        const codec = try resolveCodec(ctx, codec_id);
        try requireCustomMediaType(ctx, policy.request_content_type, codec.request_content_types);
        if (codec.extract) |run| {
            bytes = try run(ctx, bytes);
            if (!isBorrowedSubslice(ctx.request.body, bytes)) return error.CustomContentMustBorrowRequestBody;
        }
    } else {
        try requireBuiltinMediaType(ctx, policy.request, policy.request_content_type);
        try validate(policy.request, bytes, policy.request_validation);
    }

    try ctx.setLocal(&document_local_key, Document{
        .format = policy.request,
        .codec_id = codec_id,
        .bytes = bytes,
    });
    return .next;
}

pub fn document(ctx: *const Context) ?Document {
    return ctx.local(&document_local_key, Document);
}

/// Writes bytes according to the route's response representation. This is an
/// injector, not a transcoder: callers explicitly supply the target bytes.
pub fn inject(
    ctx: *Context,
    status: response.Status,
    bytes: []const u8,
    cache: response.CachePolicy,
) !void {
    const policy = ctx.route_options.content orelse return error.ContentResponseNotConfigured;
    if (policy.response == .none) return error.ContentResponseNotConfigured;

    if (policy.response == .custom) {
        const codec = try resolveCodec(ctx, policy.response_codec);
        if (codec.inject) |run| return run(ctx, status, bytes, cache);
        const content_type = policy.response_content_type orelse codec.response_content_type;
        return ctx.writeBytes(status, content_type, bytes, cache, &.{});
    }

    try validate(policy.response, bytes, policy.response_validation);
    const content_type = policy.response_content_type orelse defaultContentType(policy.response);
    try ctx.writeBytes(status, content_type, bytes, cache, &.{});
}

pub fn injectDocument(
    ctx: *Context,
    status: response.Status,
    value: Document,
    cache: response.CachePolicy,
) !void {
    try inject(ctx, status, value.bytes, cache);
}

pub fn validate(
    format: http_config.Representation,
    bytes: []const u8,
    mode: http_config.RepresentationValidation,
) !void {
    if (mode == .none or format == .binary or format == .custom or format == .none) return;

    switch (format) {
        .json => json_body.validateSlice(bytes) catch return error.InvalidContentEncoding,
        .xml => {
            try validateText(bytes);
            const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
            if (trimmed.len < 3 or trimmed[0] != '<' or trimmed[trimmed.len - 1] != '>') {
                return error.InvalidContentEncoding;
            }
            // The framework does not expand entities. Reject declarations here
            // so a later application parser cannot accidentally enable XXE.
            if (containsIgnoreCase(bytes, "<!doctype") or containsIgnoreCase(bytes, "<!entity")) {
                return error.InvalidContentEncoding;
            }
        },
        .html, .toml => try validateText(bytes),
        .none, .binary, .custom => unreachable,
    }
}

fn validateText(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidContentEncoding;
    for (bytes) |byte| {
        if ((byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n') or byte == 0x7f) {
            return error.InvalidContentEncoding;
        }
    }
}

fn resolveCodec(ctx: *const Context, id: u16) !*const Codec {
    if (id == 0) return error.InvalidContentCodecId;
    const runtime = ctx.service(&runtime_service_key, Runtime) orelse return error.ContentCodecRuntimeMissing;
    return runtime.find(id) orelse error.ContentCodecNotFound;
}

fn requireBuiltinMediaType(
    ctx: *const Context,
    format: http_config.Representation,
    override: ?[]const u8,
) !void {
    if (override) |expected| {
        if (!ctx.request.hasContentType(expected)) return error.UnsupportedMediaType;
        return;
    }

    const actual = requestMediaType(ctx) orelse {
        if (format == .binary) return;
        return error.UnsupportedMediaType;
    };
    const matches = switch (format) {
        .json => mediaEquals(actual, http_config.ContentType.json_media) or mediaHasSuffix(actual, "+json"),
        .xml => mediaEquals(actual, http_config.ContentType.xml_media) or
            mediaEquals(actual, "text/xml") or mediaHasSuffix(actual, "+xml"),
        .html => mediaEquals(actual, "text/html") or mediaEquals(actual, "application/xhtml+xml"),
        .toml => mediaEquals(actual, http_config.ContentType.toml_media) or mediaEquals(actual, "text/toml"),
        .binary => true,
        .none, .custom => false,
    };
    if (!matches) return error.UnsupportedMediaType;
}

fn requireCustomMediaType(
    ctx: *const Context,
    override: ?[]const u8,
    accepted: []const []const u8,
) !void {
    if (override) |expected| {
        if (!ctx.request.hasContentType(expected)) return error.UnsupportedMediaType;
        return;
    }
    if (accepted.len == 0) return;
    const actual = requestMediaType(ctx) orelse return error.UnsupportedMediaType;
    for (accepted) |expected| {
        if (mediaEquals(actual, expected)) return;
    }
    return error.UnsupportedMediaType;
}

fn requestMediaType(ctx: *const Context) ?[]const u8 {
    const value = ctx.request.contentType() orelse return null;
    const media_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.mem.trim(u8, value[0..media_end], " \t");
}

fn defaultContentType(format: http_config.Representation) []const u8 {
    return switch (format) {
        .json => http_config.ContentType.json,
        .xml => http_config.ContentType.xml,
        .html => http_config.ContentType.html,
        .toml => http_config.ContentType.toml,
        .binary => http_config.ContentType.octet_stream,
        .none, .custom => unreachable,
    };
}

fn mediaEquals(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, expected);
}

fn mediaHasSuffix(actual: []const u8, suffix: []const u8) bool {
    return actual.len > suffix.len and std.ascii.eqlIgnoreCase(actual[actual.len - suffix.len ..], suffix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn isBorrowedSubslice(source: []const u8, candidate: []const u8) bool {
    if (candidate.len == 0) return true;
    if (source.len == 0) return false;
    const source_start = @intFromPtr(source.ptr);
    const source_end = source_start + source.len;
    const candidate_start = @intFromPtr(candidate.ptr);
    const candidate_end = candidate_start + candidate.len;
    return candidate_start >= source_start and candidate_end <= source_end;
}

test "built-in validation keeps documents borrowed and bounded" {
    try validate(.json, "{\"ok\":true}", .basic);
    try validate(.xml, "<root>ok</root>", .basic);
    try validate(.html, "<p>fragment</p>", .basic);
    try validate(.toml, "enabled = true\n", .basic);
    try validate(.binary, &.{ 0, 255, 1 }, .basic);
    try std.testing.expectError(error.InvalidContentEncoding, validate(.json, "{", .basic));
    try std.testing.expectError(error.InvalidContentEncoding, validate(.xml, "<!DOCTYPE root><root/>", .basic));
    try std.testing.expectError(error.InvalidContentEncoding, validate(.toml, "bad\x00value", .basic));
}

test "document exposes bytes and typed json parsing" {
    const value = Document{ .format = .json, .bytes = "{\"name\":\"zig\"}" };
    var parsed = try value.parseJson(struct { name: []const u8 }, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("zig", parsed.value.name);
    try std.testing.expectEqualStrings(value.bytes, try value.asText());

    const binary = Document{ .format = .binary, .bytes = &.{0} };
    try std.testing.expectError(error.BinaryDocument, binary.asText());
}

test "codec runtime rejects invalid and duplicate ids" {
    try std.testing.expectError(error.InvalidContentCodecId, Runtime.init(&.{.{ .id = 0 }}));
    try std.testing.expectError(error.DuplicateContentCodecId, Runtime.init(&.{ .{ .id = 7 }, .{ .id = 7 } }));
    const runtime = try Runtime.init(&.{.{ .id = 7 }});
    try std.testing.expectEqual(@as(u16, 7), runtime.find(7).?.id);
    try std.testing.expect(runtime.find(8) == null);
}

test "middleware extracts json and injector writes configured representation" {
    const request_mod = @import("../core/request.zig");
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const request = try request_mod.Request.parse(
        "POST /content HTTP/1.1\r\nHost: test\r\nContent-Type: application/problem+json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}",
    );
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .content = .{ .request = .json, .response = .toml, .max_request_bytes = 64 } },
        router.Params.empty(),
        .{},
        .{},
        null,
    );

    try std.testing.expectEqual(middleware.Decision.next, try extract(&ctx));
    const extracted = document(&ctx).?;
    try std.testing.expectEqual(http_config.Representation.json, extracted.format);
    try std.testing.expectEqualStrings(request.body, extracted.bytes);

    try inject(&ctx, .ok, "ok = true\n", .no_cache);
    try std.testing.expectEqualStrings("ok = true\n", capture.body_ptr.?[0..capture.body_len]);
    try std.testing.expectEqualStrings(
        http_config.ContentType.toml,
        capture.content_type_ptr.?[0..capture.content_type_len],
    );
}

test "custom extractor is resolved through app services and must borrow" {
    const request_mod = @import("../core/request.zig");
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const Custom = struct {
        fn stripPrefix(_: *Context, bytes: []const u8) ![]const u8 {
            if (!std.mem.startsWith(u8, bytes, "v1:")) return error.InvalidContentEncoding;
            return bytes[3..];
        }

        fn write(
            ctx: *Context,
            status: response.Status,
            bytes: []const u8,
            cache: response.CachePolicy,
        ) !void {
            try ctx.writeBytes(status, "application/x-ziserver-test", bytes, cache, &.{});
        }
    };

    const codecs = [_]Codec{.{
        .id = 17,
        .request_content_types = &.{"application/x-ziserver-test"},
        .extract = Custom.stripPrefix,
        .inject = Custom.write,
    }};
    var runtime = try Runtime.init(&codecs);
    const entries = [_]services.Entry{service(&runtime)};
    const request = try request_mod.Request.parse(
        "POST /custom HTTP/1.1\r\nHost: test\r\nContent-Type: application/x-ziserver-test\r\nContent-Length: 7\r\n\r\nv1:data",
    );
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .content = .{ .request = .custom, .response = .custom, .request_codec = 17, .response_codec = 17 } },
        router.Params.empty(),
        .{},
        .{ .entries = &entries },
        null,
    );

    try std.testing.expectEqual(middleware.Decision.next, try extract(&ctx));
    try std.testing.expectEqualStrings("data", document(&ctx).?.bytes);
    try std.testing.expectEqual(@as(u16, 17), document(&ctx).?.codec_id);
    try inject(&ctx, .ok, "reply", .no_cache);
    try std.testing.expectEqualStrings("reply", capture.body_ptr.?[0..capture.body_len]);
    try std.testing.expectEqualStrings(
        "application/x-ziserver-test",
        capture.content_type_ptr.?[0..capture.content_type_len],
    );
}
