const std = @import("std");

const request_mod = @import("request.zig");

pub const max_trusted_proxies = 32;
pub const max_forwarded_hops = 32;
pub const default_forwarded_max_hops: u8 = 16;
pub const max_forwarded_header_bytes = 2048;

pub const HeaderMode = enum {
    none,
    x_forwarded_for,

    pub fn parse(value: []const u8) !HeaderMode {
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.eql(u8, value, "x-forwarded-for")) return .x_forwarded_for;
        return error.InvalidClientIpHeader;
    }

    pub fn text(self: HeaderMode) []const u8 {
        return switch (self) {
            .none => "none",
            .x_forwarded_for => "x-forwarded-for",
        };
    }
};

pub const Family = enum(u8) {
    ip4 = 4,
    ip6 = 6,
};

/// Canonical IP address without a transport port. IPv4-mapped IPv6 addresses
/// are folded into IPv4 so one peer cannot acquire two limiter keys.
pub const IpKey = struct {
    family: Family,
    bytes: [16]u8,

    pub fn unspecified() IpKey {
        return .{ .family = .ip4, .bytes = @splat(0) };
    }

    pub fn loopback() IpKey {
        var bytes: [16]u8 = @splat(0);
        bytes[0..4].* = .{ 127, 0, 0, 1 };
        return .{ .family = .ip4, .bytes = bytes };
    }

    pub fn loopbackFor(family: Family) IpKey {
        if (family == .ip4) return loopback();
        var bytes: [16]u8 = @splat(0);
        bytes[15] = 1;
        return .{ .family = .ip6, .bytes = bytes };
    }

    pub fn fromAddress(address: std.Io.net.IpAddress) IpKey {
        const normalized = switch (address) {
            .ip4 => address,
            .ip6 => |ip6| std.Io.net.IpAddress.fromIp6(ip6),
        };
        var bytes: [16]u8 = @splat(0);
        return switch (normalized) {
            .ip4 => |ip4| block: {
                bytes[0..4].* = ip4.bytes;
                break :block .{ .family = .ip4, .bytes = bytes };
            },
            .ip6 => |ip6| .{ .family = .ip6, .bytes = ip6.bytes },
        };
    }

    pub fn parse(value: []const u8) !IpKey {
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, '%') != null) return error.InvalidClientIp;

        if (value[0] == '[') {
            const close = std.mem.indexOfScalar(u8, value, ']') orelse return error.InvalidClientIp;
            if (close == 1) return error.InvalidClientIp;
            const suffix = value[close + 1 ..];
            if (suffix.len != 0) {
                if (suffix[0] != ':' or suffix.len == 1) return error.InvalidClientIp;
                _ = std.fmt.parseInt(u16, suffix[1..], 10) catch return error.InvalidClientIp;
            }
            if (close + 1 + suffix.len != value.len) return error.InvalidClientIp;
            return fromAddress(std.Io.net.IpAddress.parseIp6(value[1..close], 0) catch return error.InvalidClientIp);
        }

        var colon_count: usize = 0;
        for (value) |byte| if (byte == ':') {
            colon_count += 1;
        };
        if (colon_count > 1) {
            return fromAddress(std.Io.net.IpAddress.parseIp6(value, 0) catch return error.InvalidClientIp);
        }
        if (colon_count == 1) {
            const colon = std.mem.indexOfScalar(u8, value, ':').?;
            if (std.mem.indexOfScalar(u8, value[0..colon], '.') == null or colon + 1 == value.len) return error.InvalidClientIp;
            _ = std.fmt.parseInt(u16, value[colon + 1 ..], 10) catch return error.InvalidClientIp;
            return fromAddress(std.Io.net.IpAddress.parseIp4(value[0..colon], 0) catch return error.InvalidClientIp);
        }
        return fromAddress(std.Io.net.IpAddress.parseIp4(value, 0) catch return error.InvalidClientIp);
    }

    pub fn eql(a: IpKey, b: IpKey) bool {
        return a.family == b.family and std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isUnspecified(self: IpKey) bool {
        const length: usize = if (self.family == .ip4) 4 else 16;
        for (self.bytes[0..length]) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    pub fn toAddress(self: IpKey, port: u16) std.Io.net.IpAddress {
        return switch (self.family) {
            .ip4 => .{ .ip4 = .{ .bytes = self.bytes[0..4].*, .port = port } },
            .ip6 => .{ .ip6 = .{ .bytes = self.bytes, .port = port } },
        };
    }

    pub fn hash(self: IpKey) u64 {
        var input: [17]u8 = undefined;
        input[0] = @intFromEnum(self.family);
        input[1..].* = self.bytes;
        return std.hash.Wyhash.hash(0, &input);
    }

    pub fn format(self: IpKey, buffer: []u8) ![]const u8 {
        return switch (self.family) {
            .ip4 => std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            }),
            .ip6 => std.fmt.bufPrint(buffer, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                std.mem.readInt(u16, self.bytes[0..2], .big),
                std.mem.readInt(u16, self.bytes[2..4], .big),
                std.mem.readInt(u16, self.bytes[4..6], .big),
                std.mem.readInt(u16, self.bytes[6..8], .big),
                std.mem.readInt(u16, self.bytes[8..10], .big),
                std.mem.readInt(u16, self.bytes[10..12], .big),
                std.mem.readInt(u16, self.bytes[12..14], .big),
                std.mem.readInt(u16, self.bytes[14..16], .big),
            }),
        };
    }
};

pub const Cidr = struct {
    network: IpKey,
    prefix: u8,

    pub fn parse(value: []const u8) !Cidr {
        const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return error.InvalidTrustedProxy;
        const address_text = value[0..slash];
        const network = IpKey.parse(address_text) catch return error.InvalidTrustedProxy;
        const prefix = std.fmt.parseInt(u8, value[slash + 1 ..], 10) catch return error.InvalidTrustedProxy;
        const max_prefix: u8 = if (network.family == .ip4) 32 else 128;
        if (prefix > max_prefix) return error.InvalidTrustedProxy;
        return .{ .network = network, .prefix = prefix };
    }

    pub fn contains(self: Cidr, address: IpKey) bool {
        if (self.network.family != address.family) return false;
        const byte_count = self.prefix / 8;
        const remainder = self.prefix % 8;
        if (!std.mem.eql(u8, self.network.bytes[0..byte_count], address.bytes[0..byte_count])) return false;
        if (remainder == 0) return true;
        const mask: u8 = @as(u8, 0xff) << @intCast(8 - remainder);
        return (self.network.bytes[byte_count] & mask) == (address.bytes[byte_count] & mask);
    }
};

pub const Source = enum {
    peer,
    x_forwarded_for,

    pub fn text(self: Source) []const u8 {
        return switch (self) {
            .peer => "peer",
            .x_forwarded_for => "x-forwarded-for",
        };
    }
};

pub const Resolution = enum {
    peer,
    forwarded,
    header_missing,
    ignored_untrusted_peer,
    invalid_header,
};

pub const ClientIdentity = struct {
    peer_ip: IpKey,
    client_ip: IpKey,
    source: Source = .peer,
    resolution: Resolution = .peer,
    trusted_hops: u8 = 0,

    pub fn direct(peer_ip: IpKey) ClientIdentity {
        return .{ .peer_ip = peer_ip, .client_ip = peer_ip };
    }
};

pub const Resolver = struct {
    mode: HeaderMode = .none,
    forwarded_max_hops: u8 = default_forwarded_max_hops,
    trusted_proxy_count: u8 = 0,
    trusted_proxies: [max_trusted_proxies]Cidr = undefined,

    pub fn init(mode: HeaderMode, trusted_values: []const []const u8, forwarded_max_hops: u8) !Resolver {
        if (forwarded_max_hops == 0 or forwarded_max_hops > max_forwarded_hops) return error.InvalidForwardedMaxHops;
        if (trusted_values.len > max_trusted_proxies) return error.TooManyTrustedProxies;
        if (mode != .none and trusted_values.len == 0) return error.ClientIpHeaderRequiresTrustedProxy;

        var resolver = Resolver{
            .mode = mode,
            .forwarded_max_hops = forwarded_max_hops,
            .trusted_proxy_count = @intCast(trusted_values.len),
        };
        for (trusted_values, 0..) |value, index| resolver.trusted_proxies[index] = try Cidr.parse(value);
        return resolver;
    }

    pub fn trustedCount(self: *const Resolver) usize {
        return self.trusted_proxy_count;
    }

    pub fn resolve(self: *const Resolver, peer_ip: IpKey, request: request_mod.Request) ClientIdentity {
        if (self.mode == .none) return ClientIdentity.direct(peer_ip);

        const header = uniqueHeader(request, "X-Forwarded-For") catch {
            return .{ .peer_ip = peer_ip, .client_ip = peer_ip, .resolution = .invalid_header };
        };
        if (!self.isTrusted(peer_ip)) {
            var identity = ClientIdentity.direct(peer_ip);
            if (header != null) identity.resolution = .ignored_untrusted_peer;
            return identity;
        }
        const value = header orelse return .{
            .peer_ip = peer_ip,
            .client_ip = peer_ip,
            .resolution = .header_missing,
        };
        if (value.len == 0 or value.len > max_forwarded_header_bytes) return .{
            .peer_ip = peer_ip,
            .client_ip = peer_ip,
            .resolution = .invalid_header,
        };

        var chain: [max_forwarded_hops]IpKey = undefined;
        var chain_len: usize = 0;
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            if (chain_len >= self.forwarded_max_hops) return .{
                .peer_ip = peer_ip,
                .client_ip = peer_ip,
                .resolution = .invalid_header,
            };
            const token = std.mem.trim(u8, part, " \t");
            chain[chain_len] = IpKey.parse(token) catch return .{
                .peer_ip = peer_ip,
                .client_ip = peer_ip,
                .resolution = .invalid_header,
            };
            chain_len += 1;
        }
        if (chain_len == 0) return .{ .peer_ip = peer_ip, .client_ip = peer_ip, .resolution = .invalid_header };

        var index = chain_len;
        var trusted_hops: u8 = 1; // The directly connected peer is trusted here.
        while (index != 0) {
            index -= 1;
            const candidate = chain[index];
            if (!self.isTrusted(candidate)) return .{
                .peer_ip = peer_ip,
                .client_ip = candidate,
                .source = .x_forwarded_for,
                .resolution = .forwarded,
                .trusted_hops = trusted_hops,
            };
            trusted_hops +|= 1;
        }
        return .{
            .peer_ip = peer_ip,
            .client_ip = chain[0],
            .source = .x_forwarded_for,
            .resolution = .forwarded,
            .trusted_hops = trusted_hops,
        };
    }

    fn isTrusted(self: *const Resolver, address: IpKey) bool {
        for (self.trusted_proxies[0..self.trusted_proxy_count]) |network| {
            if (network.contains(address)) return true;
        }
        return false;
    }
};

fn uniqueHeader(request: request_mod.Request, name: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var rest = request.headers;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, name)) {
            if (found != null) return error.DuplicateHeader;
            found = std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return found;
}

test "IP keys normalize mapped IPv6 and omit ports" {
    const ip4 = try IpKey.parse("192.0.2.4:443");
    const mapped = try IpKey.parse("::ffff:192.0.2.4");
    try std.testing.expect(ip4.eql(mapped));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.0.2.4", try ip4.format(&buffer));
    try std.testing.expectError(error.InvalidClientIp, IpKey.parse("fe80::1%4"));
}

test "IP keys identify unspecified addresses by value" {
    try std.testing.expect((try IpKey.parse("0.0.0.0")).isUnspecified());
    try std.testing.expect((try IpKey.parse("::")).isUnspecified());
    try std.testing.expect((try IpKey.parse("0:0:0:0:0:0:0:0")).isUnspecified());
    try std.testing.expect(!(try IpKey.parse("::1")).isUnspecified());
    try std.testing.expect(IpKey.loopbackFor(.ip6).eql(try IpKey.parse("::1")));
}

test "CIDR matches IPv4 and IPv6 prefix boundaries" {
    const ip4 = try Cidr.parse("10.0.0.0/8");
    try std.testing.expect(ip4.contains(try IpKey.parse("10.255.255.255")));
    try std.testing.expect(!ip4.contains(try IpKey.parse("11.0.0.0")));
    const ip6 = try Cidr.parse("2001:db8::/32");
    try std.testing.expect(ip6.contains(try IpKey.parse("2001:db8::1")));
    try std.testing.expect(!ip6.contains(try IpKey.parse("2001:db9::1")));
}

test "resolver ignores spoofed headers from untrusted peers" {
    const resolver = try Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, 8);
    const request = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9\r\n\r\n");
    const peer = try IpKey.parse("203.0.113.8");
    const identity = resolver.resolve(peer, request);
    try std.testing.expect(identity.client_ip.eql(peer));
    try std.testing.expectEqual(Resolution.ignored_untrusted_peer, identity.resolution);
}

test "default resolver ignores every forwarding header" {
    const resolver = Resolver{};
    const request = try request_mod.Request.parse(
        "GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9\r\nForwarded: for=198.51.100.10\r\nX-Real-IP: 198.51.100.11\r\n\r\n",
    );
    const peer = try IpKey.parse("203.0.113.8");
    const identity = resolver.resolve(peer, request);
    try std.testing.expect(identity.client_ip.eql(peer));
    try std.testing.expectEqual(Resolution.peer, identity.resolution);
}

test "resolver walks trusted proxy chain from right to left" {
    const resolver = try Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, 8);
    const request = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9, 10.0.0.20\r\n\r\n");
    const identity = resolver.resolve(try IpKey.parse("10.0.0.10"), request);
    try std.testing.expect(identity.client_ip.eql(try IpKey.parse("198.51.100.9")));
    try std.testing.expectEqual(Source.x_forwarded_for, identity.source);
    try std.testing.expectEqual(@as(u8, 2), identity.trusted_hops);
}

test "resolver accepts one hop and uses the leftmost address when all hops are trusted" {
    const resolver = try Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, 8);
    const single = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9\r\n\r\n");
    try std.testing.expect(
        resolver.resolve(try IpKey.parse("10.0.0.10"), single).client_ip.eql(try IpKey.parse("198.51.100.9")),
    );
    const all_trusted = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 10.1.0.1, 10.2.0.1\r\n\r\n");
    const identity = resolver.resolve(try IpKey.parse("10.3.0.1"), all_trusted);
    try std.testing.expect(identity.client_ip.eql(try IpKey.parse("10.1.0.1")));
    try std.testing.expectEqual(@as(u8, 3), identity.trusted_hops);
}

test "resolver fails safely on duplicate malformed and oversized chains" {
    const resolver = try Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, 1);
    const peer = try IpKey.parse("10.0.0.10");
    const duplicate = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9\r\nX-Forwarded-For: 198.51.100.10\r\n\r\n");
    try std.testing.expectEqual(Resolution.invalid_header, resolver.resolve(peer, duplicate).resolution);
    const malformed = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: unknown\r\n\r\n");
    try std.testing.expectEqual(Resolution.invalid_header, resolver.resolve(peer, malformed).resolution);
    const too_many = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: 198.51.100.9, 198.51.100.10\r\n\r\n");
    try std.testing.expectEqual(Resolution.invalid_header, resolver.resolve(peer, too_many).resolution);
}

test "resolver rejects bounded malformed header corpus" {
    const resolver = try Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, 8);
    const peer = try IpKey.parse("10.0.0.10");
    const malformed = [_][]const u8{
        "",
        "unknown",
        "198.51.100.1,",
        ",198.51.100.1",
        "fe80::1%4",
        "[2001:db8::1",
        "[2001:db8::1]junk",
        "198.51.100.1:99999",
    };
    for (malformed) |value| {
        var raw_buffer: [256]u8 = undefined;
        const raw = try std.fmt.bufPrint(
            &raw_buffer,
            "GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: {s}\r\n\r\n",
            .{value},
        );
        const request = try request_mod.Request.parse(raw);
        try std.testing.expectEqual(Resolution.invalid_header, resolver.resolve(peer, request).resolution);
    }

    var long_value: [max_forwarded_header_bytes + 1]u8 = @splat('1');
    var raw_buffer: [max_forwarded_header_bytes + 128]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buffer,
        "GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: {s}\r\n\r\n",
        .{&long_value},
    );
    const request = try request_mod.Request.parse(raw);
    try std.testing.expectEqual(Resolution.invalid_header, resolver.resolve(peer, request).resolution);
}

test "client identity header parser fuzz target" {
    try std.testing.fuzz({}, fuzzIdentityHeader, .{});
}

fn fuzzIdentityHeader(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var value_buffer: [max_forwarded_header_bytes + 1]u8 = undefined;
    const value_len = smith.sliceWeightedBytes(&value_buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, ',', 4),
        .value(u8, ':', 4),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
    });
    var raw_buffer: [max_forwarded_header_bytes + 128]u8 = undefined;
    const raw = std.fmt.bufPrint(
        &raw_buffer,
        "GET / HTTP/1.1\r\nHost: test\r\nX-Forwarded-For: {s}\r\n\r\n",
        .{value_buffer[0..value_len]},
    ) catch return;
    const request = request_mod.Request.parse(raw) catch return;
    const resolver = Resolver.init(.x_forwarded_for, &.{"10.0.0.0/8"}, max_forwarded_hops) catch unreachable;
    _ = resolver.resolve(IpKey.parse("10.0.0.1") catch unreachable, request);
}

test "forwarded mode requires a bounded explicit trust list" {
    try std.testing.expectError(
        error.ClientIpHeaderRequiresTrustedProxy,
        Resolver.init(.x_forwarded_for, &.{}, default_forwarded_max_hops),
    );
    try std.testing.expectError(error.InvalidForwardedMaxHops, Resolver.init(.none, &.{}, 0));
}
