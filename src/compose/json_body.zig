const std = @import("std");

const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");

pub const flag_validate_json_body: u32 = 1 << 8;

pub const ParseError = error{
    InvalidEncoding,
    UnsupportedMediaType,
};

pub fn validate(ctx: *Context) !middleware.Decision {
    if ((ctx.route_options.middleware_flags & flag_validate_json_body) == 0) return .next;
    if (!ctx.request.hasContentType(http_config.ContentType.json_media)) return error.UnsupportedMediaType;
    validateSlice(ctx.request.body) catch return error.InvalidJsonEncoding;
    return .next;
}

pub fn validateSlice(body: []const u8) ParseError!void {
    // Validation only needs the scanner. Building a std.json.Value allocates a
    // framework-owned AST and made every generic content request pay for an
    // allocation it immediately discarded.
    const valid = std.json.validate(std.heap.page_allocator, body) catch return error.InvalidEncoding;
    if (!valid) return error.InvalidEncoding;
}

pub fn parseFromContext(
    comptime T: type,
    allocator: std.mem.Allocator,
    ctx: *const Context,
) ParseError!std.json.Parsed(T) {
    if (!ctx.request.hasContentType(http_config.ContentType.json_media)) return error.UnsupportedMediaType;
    return parseFromSlice(T, allocator, ctx.request.body);
}

pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) ParseError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidEncoding;
}

test "validates json body" {
    try validateSlice("{\"message\":\"hello\",\"count\":2}");
    try std.testing.expectError(error.InvalidEncoding, validateSlice("{\"message\":"));
}

test "parses typed json body" {
    const Payload = struct {
        message: []const u8 = "",
        count: i64 = 0,
    };

    var parsed = try parseFromSlice(
        Payload,
        std.testing.allocator,
        "{\"message\":\"hello\",\"count\":2,\"ignored\":true}",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", parsed.value.message);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.count);
}
