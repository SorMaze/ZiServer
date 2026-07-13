const std = @import("std");

const Context = @import("../core/context.zig").Context;
const logger = @import("../core/log.zig");
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");
const request_mod = @import("../core/request.zig");

pub const flag_observe: u32 = 1 << 0;
pub const flag_block: u32 = 1 << 1;
pub const FilterMode = http_config.XssFilterMode;

pub const Config = struct {
    /// Server-wide minimum. Routes can strengthen but cannot weaken it.
    mode: FilterMode = .off,
    scan_query: bool = true,
    scan_body: bool = true,
};

pub const Policy = struct {
    mode: FilterMode = .off,
    scan_query: bool = true,
    scan_body: bool = true,
};

pub const Violation = enum {
    suspected_xss,
};

var runtime_config: Config = .{};

/// Configure once during startup before worker dispatch begins.
pub fn init(config: Config) void {
    runtime_config = config;
}

pub fn filter(ctx: *Context) !middleware.Decision {
    const policy = resolvePolicy(ctx.route_options.middleware_flags, runtime_config);
    const violation = inspectRequest(ctx.request, policy) orelse return .next;

    switch (policy.mode) {
        .off => return .next,
        .observe => {
            logger.message(ctx.io, .warn, "xss_observed", "violation={t} path={s}", .{ violation, ctx.request.path });
            return .next;
        },
        .block => return error.ForbiddenSuspectedXss,
    }
}

pub fn policyFromFlags(flags: u32) Policy {
    if ((flags & flag_block) != 0) return .{ .mode = .block };
    if ((flags & flag_observe) != 0) return .{ .mode = .observe };
    return .{};
}

pub fn resolvePolicy(flags: u32, config: Config) Policy {
    const route_policy = policyFromFlags(flags);
    return .{
        .mode = stricterMode(route_policy.mode, config.mode),
        .scan_query = config.scan_query,
        .scan_body = config.scan_body,
    };
}

pub fn inspectRequest(request: request_mod.Request, policy: Policy) ?Violation {
    if (policy.mode == .off) return null;
    if (policy.scan_query and containsSuspiciousInput(request.query)) return .suspected_xss;
    if (policy.scan_body and containsSuspiciousInput(request.body)) return .suspected_xss;
    return null;
}

pub fn containsSuspiciousInput(input: []const u8) bool {
    if (containsDangerousSyntax(input)) return true;

    // Bounded canonicalization catches common percent and numeric entity
    // obfuscation without heap allocation on the request hot path.
    var first_buffer: [16 * 1024]u8 = undefined;
    const first = canonicalize(input, &first_buffer) orelse return false;
    if (containsDangerousSyntax(first)) return true;

    var second_buffer: [16 * 1024]u8 = undefined;
    const second = canonicalize(first, &second_buffer) orelse return false;
    return containsDangerousSyntax(second);
}

fn containsDangerousSyntax(input: []const u8) bool {
    const needles = [_][]const u8{
        "<script",
        "</script",
        "<iframe",
        "<object",
        "<embed",
        "javascript:",
        "vbscript:",
        "data:text/html",
        "srcdoc=",
        "expression(",
    };
    for (needles) |needle| {
        if (indexOfIgnoreCase(input, needle) != null) return true;
    }
    return containsEventHandler(input);
}

fn containsEventHandler(input: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < input.len) : (i += 1) {
        if (std.ascii.toLower(input[i]) != 'o' or std.ascii.toLower(input[i + 1]) != 'n') continue;
        if (i != 0 and isIdentifierByte(input[i - 1])) continue;

        var cursor = i + 2;
        const name_start = cursor;
        while (cursor < input.len and std.ascii.isAlphabetic(input[cursor])) : (cursor += 1) {}
        if (cursor == name_start) continue;
        while (cursor < input.len and (input[cursor] == ' ' or input[cursor] == '\t')) : (cursor += 1) {}
        if (cursor < input.len and input[cursor] == '=') return true;
    }
    return false;
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn canonicalize(input: []const u8, buffer: []u8) ?[]const u8 {
    if (input.len > buffer.len) return null;
    var read: usize = 0;
    var written: usize = 0;
    while (read < input.len) {
        if (input[read] == '%' and read + 2 < input.len) {
            const high = std.fmt.charToDigit(input[read + 1], 16) catch null;
            const low = std.fmt.charToDigit(input[read + 2], 16) catch null;
            if (high != null and low != null) {
                buffer[written] = @intCast(high.? * 16 + low.?);
                written += 1;
                read += 3;
                continue;
            }
        }
        if (input[read] == '&' and read + 3 < input.len and input[read + 1] == '#') {
            if (decodeNumericEntity(input[read..])) |decoded| {
                buffer[written] = decoded.byte;
                written += 1;
                read += decoded.consumed;
                continue;
            }
        }
        buffer[written] = if (input[read] == '+') ' ' else input[read];
        written += 1;
        read += 1;
    }
    return buffer[0..written];
}

fn decodeNumericEntity(input: []const u8) ?struct { byte: u8, consumed: usize } {
    if (!std.mem.startsWith(u8, input, "&#")) return null;
    var cursor: usize = 2;
    var base: u8 = 10;
    if (cursor < input.len and (input[cursor] == 'x' or input[cursor] == 'X')) {
        base = 16;
        cursor += 1;
    }
    const digits_start = cursor;
    var value: u16 = 0;
    while (cursor < input.len and input[cursor] != ';') : (cursor += 1) {
        const digit = std.fmt.charToDigit(input[cursor], base) catch return null;
        value = std.math.mul(u16, value, base) catch return null;
        value = std.math.add(u16, value, digit) catch return null;
    }
    if (cursor == digits_start or cursor >= input.len or value > 0x7f) return null;
    return .{ .byte = @intCast(value), .consumed = cursor + 1 };
}

fn stricterMode(left: FilterMode, right: FilterMode) FilterMode {
    return if (@intFromEnum(left) >= @intFromEnum(right)) left else right;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "detects dangerous syntax and common encodings" {
    try std.testing.expect(containsSuspiciousInput("name=<script>alert(1)</script>"));
    try std.testing.expect(containsSuspiciousInput("url=javascript:alert(1)"));
    try std.testing.expect(containsSuspiciousInput("img=%3Cscript%3Ealert(1)"));
    try std.testing.expect(containsSuspiciousInput("img=%253Cscript%253Ealert(1)"));
    try std.testing.expect(containsSuspiciousInput("img src=x onfocus = alert(1)"));
    try std.testing.expect(containsSuspiciousInput("url=java&#x73;cript&#58;alert(1)"));
    try std.testing.expect(containsSuspiciousInput("style=expression(alert(1))"));
    try std.testing.expect(!containsSuspiciousInput("name=normal&message=hello"));
    try std.testing.expect(!containsSuspiciousInput("discussion=online"));
}

test "runtime policy is a minimum and scan targets are configurable" {
    const route_observe = resolvePolicy(flag_observe, .{
        .mode = .block,
        .scan_query = false,
        .scan_body = true,
    });
    try std.testing.expectEqual(FilterMode.block, route_observe.mode);
    try std.testing.expect(!route_observe.scan_query);
    try std.testing.expect(route_observe.scan_body);

    const route_block = resolvePolicy(flag_block, .{ .mode = .off });
    try std.testing.expectEqual(FilterMode.block, route_block.mode);
}

test "policy can disable request inspection" {
    const request = try request_mod.Request.parse(
        "POST /submit?q=<script HTTP/1.1\r\nContent-Length: 18\r\n\r\nname=<script>x</script>",
    );
    try std.testing.expectEqual(@as(?Violation, null), inspectRequest(request, .{}));
    try std.testing.expectEqual(Violation.suspected_xss, inspectRequest(request, .{ .mode = .observe }));
}
