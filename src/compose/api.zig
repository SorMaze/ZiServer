const std = @import("std");

const Context = @import("../core/context.zig").Context;
const request_mod = @import("../core/request.zig");
const response = @import("../core/response.zig");
const content = @import("content.zig");

/// A request-scoped API façade. It keeps typed JSON parsing, request metadata,
/// and response injection in compose while the core Context remains protocol
/// and transport focused.
///
/// The arena lives in the handler stack frame and is released at the end of
/// that handler. Parsed strings borrow the request body whenever possible, so
/// scalar JSON APIs normally make no heap allocation.
pub const Call = struct {
    ctx: *Context,
    arena: std.heap.ArenaAllocator,

    pub fn init(ctx: *Context) Call {
        return .{
            .ctx = ctx,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *Call) void {
        self.arena.deinit();
    }

    pub fn context(self: *const Call) *Context {
        return self.ctx;
    }

    pub fn method(self: *const Call) request_mod.Method {
        return self.ctx.request.method;
    }

    pub fn param(self: *const Call, name: []const u8) ?[]const u8 {
        return self.ctx.param(name);
    }

    pub fn queryParam(self: *const Call, name: []const u8) ?[]const u8 {
        return self.ctx.queryParam(name);
    }

    pub fn bodyBytes(self: *const Call) usize {
        return self.document().bytes.len;
    }

    pub fn document(self: *const Call) content.Document {
        return content.document(self.ctx) orelse .{
            .format = .none,
            .bytes = &.{},
        };
    }

    /// Parses the document extracted by the route's API layer. The arena owns
    /// any arrays/maps needed by the decoded value, so the value stays valid
    /// until Call.deinit(). Unknown JSON fields are intentionally ignored to
    /// make additive API evolution backward compatible.
    pub fn json(self: *Call, comptime T: type) !T {
        const input = self.document();
        if (input.format != .json) return error.UnsupportedMediaType;
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), input.bytes, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidJsonEncoding;
    }

    /// Serializes a Zig value to a caller-owned fixed buffer, then injects it
    /// through the route's configured JSON representation. This avoids a
    /// temporary heap buffer and avoids validating framework-generated JSON a
    /// second time. A too-small output buffer is a normal 413 response.
    pub fn respondJson(
        self: *Call,
        status: response.Status,
        value: anytype,
        output: []u8,
        cache: response.CachePolicy,
    ) !void {
        var writer: std.Io.Writer = .fixed(output);
        std.json.Stringify.value(value, .{}, &writer) catch |err| switch (err) {
            error.WriteFailed => return error.PayloadTooLarge,
        };
        try content.inject(self.ctx, status, writer.buffered(), cache);
    }
};

pub fn call(ctx: *Context) Call {
    return Call.init(ctx);
}

test "API call parses once and injects a fixed-buffer JSON response" {
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const Payload = struct { message: []const u8, count: i64 };
    const Output = struct { ok: bool, message: []const u8, count: i64 };

    const request = try request_mod.Request.parse(
        "POST /api HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 29\r\n\r\n{\"message\":\"hello\",\"count\":2}",
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
        .{ .content = .{ .request = .json, .response = .json, .request_validation = .none, .response_validation = .none } },
        router.Params.empty(),
        .{},
        .{},
        null,
    );
    _ = try content.extract(&ctx);

    var api = call(&ctx);
    defer api.deinit();
    const payload = try api.json(Payload);
    var output: [128]u8 = undefined;
    try api.respondJson(.ok, Output{ .ok = true, .message = payload.message, .count = payload.count }, &output, .no_cache);

    try std.testing.expectEqualStrings("application/json; charset=utf-8", capture.content_type_ptr.?[0..capture.content_type_len]);
    try std.testing.expectEqualStrings("{\"ok\":true,\"message\":\"hello\",\"count\":2}", capture.body_ptr.?[0..capture.body_len]);
}

test "API call maps decode and response capacity failures to semantic errors" {
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const request = try request_mod.Request.parse(
        "POST /api HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 1\r\n\r\n{",
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
        .{ .content = .{ .request = .json, .response = .json, .request_validation = .none, .response_validation = .none } },
        router.Params.empty(),
        .{},
        .{},
        null,
    );
    _ = try content.extract(&ctx);

    var api = call(&ctx);
    defer api.deinit();
    try std.testing.expectError(error.InvalidJsonEncoding, api.json(struct { value: u8 }));
    var output: [2]u8 = undefined;
    try std.testing.expectError(error.PayloadTooLarge, api.respondJson(.ok, .{ .value = "long" }, &output, .no_cache));
}
