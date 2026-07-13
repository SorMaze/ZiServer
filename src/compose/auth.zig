const std = @import("std");

const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");
const request_mod = @import("../core/request.zig");

const bearer_scheme = "Bearer";

pub fn requireAuth(ctx: *Context) !middleware.Decision {
    const policy = effectivePolicy(ctx.route_options.auth, ctx.route_options.require_auth);
    if (policy == .none) return .next;

    if (!authenticateRequest(ctx.request, policy, ctx.auth_credentials)) return error.Unauthorized;

    return .next;
}

pub fn authenticateRequest(
    request: request_mod.Request,
    policy: http_config.AuthPolicy,
    credentials: http_config.AuthCredentials,
) bool {
    return switch (policy) {
        .none => true,
        .bearer => hasBearer(request, credentials.bearer_token),
        .api_key => hasApiKey(request, credentials.api_key),
        .bearer_or_api_key => hasBearer(request, credentials.bearer_token) or
            hasApiKey(request, credentials.api_key),
    };
}

fn effectivePolicy(policy: http_config.AuthPolicy, require_auth: bool) http_config.AuthPolicy {
    if (policy != .none) return policy;
    if (require_auth) return .bearer;
    return .none;
}

fn hasBearer(request: request_mod.Request, expected_token: ?[]const u8) bool {
    const token = expected_token orelse return false;
    if (token.len == 0) return false;
    const value = request.header(http_config.HeaderName.authorization) orelse return false;
    if (value.len <= bearer_scheme.len or
        !std.ascii.eqlIgnoreCase(value[0..bearer_scheme.len], bearer_scheme) or
        value[bearer_scheme.len] != ' ')
    {
        return false;
    }
    const supplied = std.mem.trimStart(u8, value[bearer_scheme.len + 1 ..], " ");
    return secureEql(supplied, token);
}

fn hasApiKey(request: request_mod.Request, expected_key: ?[]const u8) bool {
    const key = expected_key orelse return false;
    if (key.len == 0) return false;
    const value = request.header(http_config.HeaderName.x_api_key) orelse return false;
    return secureEql(value, key);
}

fn secureEql(supplied: []const u8, expected: []const u8) bool {
    var supplied_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var expected_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(supplied, &supplied_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(expected, &expected_hash, .{});
    return std.crypto.timing_safe.eql(@TypeOf(supplied_hash), supplied_hash, expected_hash);
}

test "auth policies validate bearer and api key" {
    const credentials = http_config.AuthCredentials{
        .bearer_token = "test-token",
        .api_key = "test-key",
    };

    const bearer = try request_mod.Request.parse(
        "GET /admin/stats HTTP/1.1\r\nAuthorization: Bearer test-token\r\n\r\n",
    );
    const api_key = try request_mod.Request.parse(
        "GET /admin/stats HTTP/1.1\r\nX-API-Key: test-key\r\n\r\n",
    );
    const missing = try request_mod.Request.parse("GET /admin/stats HTTP/1.1\r\nHost: test\r\n\r\n");

    try std.testing.expect(authenticateRequest(bearer, .bearer, credentials));
    const mixed_case_bearer = try request_mod.Request.parse(
        "GET /admin/stats HTTP/1.1\r\nAuthorization: bEaReR test-token\r\n\r\n",
    );
    try std.testing.expect(authenticateRequest(mixed_case_bearer, .bearer, credentials));
    try std.testing.expect(!authenticateRequest(api_key, .bearer, credentials));
    try std.testing.expect(authenticateRequest(api_key, .api_key, credentials));
    try std.testing.expect(authenticateRequest(bearer, .bearer_or_api_key, credentials));
    try std.testing.expect(authenticateRequest(api_key, .bearer_or_api_key, credentials));
    try std.testing.expect(!authenticateRequest(missing, .bearer_or_api_key, credentials));
}

test "auth rejects when credentials are not configured" {
    const empty = http_config.AuthCredentials{};
    const bearer = try request_mod.Request.parse(
        "GET /admin/stats HTTP/1.1\r\nAuthorization: Bearer test-token\r\n\r\n",
    );
    try std.testing.expect(!authenticateRequest(bearer, .bearer_or_api_key, empty));
}
