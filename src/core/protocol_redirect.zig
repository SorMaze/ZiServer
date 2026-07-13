const std = @import("std");

const client_identity = @import("client_identity.zig");
const http_config = @import("http_config.zig");
const response = @import("response.zig");

pub const max_allowed_hosts = 32;

pub const Scheme = enum {
    http,
    https,

    fn text(self: Scheme) []const u8 {
        return @tagName(self);
    }
};

pub const Destination = struct {
    scheme: Scheme,
    port: u16,
};

pub const HostPolicy = struct {
    canonical_host: ?[]const u8 = null,
    allowed_hosts: []const []const u8 = &.{},
    fallback_host: ?[]const u8 = null,
};

const body = "Permanent Redirect\n";

/// Writes a terminal 308 response after `resolveLocation` has completed all
/// request and policy validation. Errors from this function are response
/// construction or transport failures and must not be converted into a 400.
pub fn write(
    target: *response.Target,
    method: []const u8,
    location: []const u8,
) !usize {
    const headers = [_]http_config.Header{
        .{ .name = http_config.HeaderName.location, .value = location },
    };
    const head = std.ascii.eqlIgnoreCase(method, "HEAD");
    try response.writeBytes(
        target,
        .permanent_redirect,
        http_config.ContentType.plain,
        body,
        head,
        false,
        .no_cache,
        &headers,
    );
    return if (head) 0 else body.len;
}

/// Resolves a redirect Location without writing to the response transport.
/// Every error from this function describes invalid request/configuration
/// input and may safely be reported as a 400 by the protocol adapter.
pub fn resolveLocation(
    buffer: []u8,
    authority: []const u8,
    request_target: []const u8,
    destination: Destination,
    host_policy: HostPolicy,
) ![]const u8 {
    if (destination.port == 0) return error.InvalidRedirectDestination;
    if (request_target.len == 0 or request_target[0] != '/' or containsUnsafe(request_target)) {
        return error.InvalidRedirectTarget;
    }
    var host_buffer: [256]u8 = undefined;
    const host = try resolveHost(&host_buffer, authority, host_policy);
    return std.fmt.bufPrint(buffer, "{s}://{s}:{d}{s}", .{
        destination.scheme.text(),
        host,
        destination.port,
        request_target,
    }) catch error.RedirectLocationTooLong;
}

pub fn validateConfiguredHost(value: []const u8) !void {
    if (value.len == 0 or value.len > 253 or !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t")) or containsUnsafe(value)) {
        return error.InvalidRedirectHost;
    }
    if (try parseConfiguredIp(value) != null) return;
    try validateDnsName(value);
}

fn resolveHost(buffer: []u8, authority: []const u8, policy: HostPolicy) ![]const u8 {
    const request_host = try hostWithoutPort(authority);
    var matched_allowed: ?[]const u8 = null;
    for (policy.allowed_hosts) |allowed| {
        if (hostEql(request_host, allowed)) {
            matched_allowed = allowed;
            break;
        }
    }

    if (policy.allowed_hosts.len != 0 and matched_allowed == null) {
        const canonical_matches = if (policy.canonical_host) |canonical| hostEql(request_host, canonical) else false;
        if (!canonical_matches) return error.RedirectHostNotAllowed;
    }

    if (policy.canonical_host) |canonical| return formatConfiguredHost(buffer, canonical);
    if (matched_allowed) |allowed| return formatConfiguredHost(buffer, allowed);
    if (policy.fallback_host) |fallback| return formatConfiguredHost(buffer, fallback);
    return error.RedirectHostPolicyRequired;
}

fn hostWithoutPort(authority_value: []const u8) ![]const u8 {
    const authority = std.mem.trim(u8, authority_value, " \t");
    if (authority.len == 0 or containsUnsafe(authority)) return error.InvalidRedirectAuthority;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidRedirectAuthority;
        if (close == 1) return error.InvalidRedirectAuthority;
        const suffix = authority[close + 1 ..];
        if (suffix.len != 0 and (suffix[0] != ':' or !validPort(suffix[1..]))) {
            return error.InvalidRedirectAuthority;
        }
        const host = authority[0 .. close + 1];
        validateConfiguredHost(host) catch return error.InvalidRedirectAuthority;
        return host;
    }

    if (std.mem.indexOfScalar(u8, authority, '[') != null or
        std.mem.indexOfScalar(u8, authority, ']') != null or
        std.mem.count(u8, authority, ":") > 1)
    {
        return error.InvalidRedirectAuthority;
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| block: {
        if (!validPort(authority[index + 1 ..])) return error.InvalidRedirectAuthority;
        break :block authority[0..index];
    } else authority;
    validateConfiguredHost(host) catch return error.InvalidRedirectAuthority;
    return host;
}

fn parseConfiguredIp(value: []const u8) !?client_identity.IpKey {
    if (value[0] == '[') {
        if (value[value.len - 1] != ']') return error.InvalidRedirectHost;
        return client_identity.IpKey.parse(value) catch return error.InvalidRedirectHost;
    }
    const colon_count = std.mem.count(u8, value, ":");
    if (colon_count != 0) {
        if (colon_count == 1 and std.mem.indexOfScalar(u8, value, '.') != null) return error.InvalidRedirectHost;
        return client_identity.IpKey.parse(value) catch return error.InvalidRedirectHost;
    }
    var numeric = true;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '.') {
            numeric = false;
            break;
        }
    }
    if (!numeric) return null;
    return client_identity.IpKey.parse(value) catch return error.InvalidRedirectHost;
}

fn validateDnsName(value: []const u8) !void {
    var labels = std.mem.splitScalar(u8, value, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) {
            return error.InvalidRedirectHost;
        }
        if (label.len > 2) for (label[1 .. label.len - 1]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidRedirectHost;
        };
    }
}

fn hostEql(a: []const u8, b: []const u8) bool {
    const a_ip = parseConfiguredIp(a) catch null;
    const b_ip = parseConfiguredIp(b) catch null;
    if (a_ip != null or b_ip != null) return a_ip != null and b_ip != null and client_identity.IpKey.eql(a_ip.?, b_ip.?);
    return std.ascii.eqlIgnoreCase(a, b);
}

fn formatConfiguredHost(buffer: []u8, value: []const u8) ![]const u8 {
    try validateConfiguredHost(value);
    const ip = (try parseConfiguredIp(value)) orelse return value;
    var ip_buffer: [64]u8 = undefined;
    const text = try ip.format(&ip_buffer);
    return switch (ip.family) {
        .ip4 => std.fmt.bufPrint(buffer, "{s}", .{text}) catch error.RedirectLocationTooLong,
        .ip6 => std.fmt.bufPrint(buffer, "[{s}]", .{text}) catch error.RedirectLocationTooLong,
    };
}

fn validPort(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    const port = std.fmt.parseInt(u16, value, 10) catch return false;
    return port != 0;
}

fn containsUnsafe(value: []const u8) bool {
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\' or byte == '@' or byte == '#') return true;
    }
    return false;
}

test "redirect location replaces wrong listener port and preserves target" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.test:18443/products?q=zig",
        try resolveLocation(&buffer, "example.test:18080", "/products?q=zig", .{ .scheme = .https, .port = 18443 }, .{ .allowed_hosts = &.{"example.test"} }),
    );
    try std.testing.expectEqualStrings(
        "http://[2001:db8:0:0:0:0:0:1]:18080/",
        try resolveLocation(&buffer, "[2001:db8::1]:18443", "/", .{ .scheme = .http, .port = 18080 }, .{ .allowed_hosts = &.{"2001:db8::1"} }),
    );
}

test "redirect location rejects ambiguous authority and unsafe targets" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRedirectAuthority,
        resolveLocation(&buffer, "user@example.test", "/", .{ .scheme = .https, .port = 18443 }, .{ .canonical_host = "example.test" }),
    );
    try std.testing.expectError(
        error.InvalidRedirectTarget,
        resolveLocation(&buffer, "example.test", "/ok\r\nInjected: yes", .{ .scheme = .https, .port = 18443 }, .{ .canonical_host = "example.test" }),
    );
}

test "canonical host prevents attacker authority from controlling Location" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://app.example:443/login",
        try resolveLocation(&buffer, "attacker.example", "/login", .{ .scheme = .https, .port = 443 }, .{ .canonical_host = "app.example" }),
    );
}

test "specific bind fallback prevents request authority from controlling Location" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:18080/",
        try resolveLocation(&buffer, "attacker.example", "/", .{ .scheme = .http, .port = 18080 }, .{ .fallback_host = "127.0.0.1" }),
    );
}

test "allowed hosts reject unknown authority and preserve configured spelling" {
    var buffer: [256]u8 = undefined;
    const policy = HostPolicy{ .allowed_hosts = &.{ "app.example", "api.example" } };
    try std.testing.expectEqualStrings(
        "https://app.example:443/",
        try resolveLocation(&buffer, "APP.EXAMPLE:18080", "/", .{ .scheme = .https, .port = 443 }, policy),
    );
    try std.testing.expectError(
        error.RedirectHostNotAllowed,
        resolveLocation(&buffer, "attacker.example", "/", .{ .scheme = .https, .port = 443 }, policy),
    );
}

test "configured hosts reject ports and malformed DNS labels" {
    try std.testing.expectError(error.InvalidRedirectHost, validateConfiguredHost("app.example:443"));
    try std.testing.expectError(error.InvalidRedirectHost, validateConfiguredHost("-app.example"));
    try validateConfiguredHost("app.example");
    try validateConfiguredHost("::1");
}
