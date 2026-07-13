const std = @import("std");

const Context = @import("../core/context.zig").Context;
const middleware = @import("../core/middleware.zig");
const request_mod = @import("../core/request.zig");

/// Reject ambiguous HTTP/1.1 authority before a dynamic handler runs.
pub fn validate(ctx: *Context) !middleware.Decision {
    if (!hasValidAuthority(ctx.request)) return error.BadRequest;
    return .next;
}

pub fn hasValidAuthority(request: request_mod.Request) bool {
    if (request.version != .http11) return true;

    var host_count: usize = 0;
    var rest = request.headers;
    while (rest.len != 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Host")) {
            host_count += 1;
            if (host_count != 1 or std.mem.trim(u8, line[colon + 1 ..], " \t").len == 0) return false;
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return host_count == 1;
}

test "authority validation follows HTTP version requirements" {
    const valid = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n");
    const missing = try request_mod.Request.parse("GET / HTTP/1.1\r\nUser-Agent: test\r\n\r\n");
    const empty = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: \r\n\r\n");
    const duplicate = try request_mod.Request.parse("GET / HTTP/1.1\r\nHost: one.test\r\nHost: two.test\r\n\r\n");
    const legacy = try request_mod.Request.parse("GET / HTTP/1.0\r\nUser-Agent: test\r\n\r\n");

    try std.testing.expect(hasValidAuthority(valid));
    try std.testing.expect(!hasValidAuthority(missing));
    try std.testing.expect(!hasValidAuthority(empty));
    try std.testing.expect(!hasValidAuthority(duplicate));
    try std.testing.expect(hasValidAuthority(legacy));
}
