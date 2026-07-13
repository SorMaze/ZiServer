const std = @import("std");

const http_config = @import("http_config.zig");

pub const Kind = enum {
    unknown,
    http1,
    http2_preface,
    tls_client_hello,
};

pub fn detect(input: []const u8) Kind {
    if (looksLikeTlsClientHello(input)) return .tls_client_hello;
    if (std.mem.startsWith(u8, http_config.h2c_preface, input)) {
        if (input.len >= http_config.h2c_preface.len) return .http2_preface;
        return .unknown;
    }
    if (looksLikeHttp1(input)) return .http1;
    return .unknown;
}

pub fn looksLikeTlsClientHello(input: []const u8) bool {
    if (input.len == 0 or input[0] != 0x16) return false;
    if (input.len == 1) return true;
    if (input[1] != 0x03) return false;
    return input.len == 2 or input[2] <= 0x04;
}

fn looksLikeHttp1(input: []const u8) bool {
    if (input.len == 0) return false;
    const methods = [_][]const u8{
        "GET ",
        "HEAD ",
        "POST ",
        "PUT ",
        "DELETE ",
        "PATCH ",
        "OPTIONS ",
        "CONNECT ",
        "TRACE ",
    };
    for (methods) |method| {
        if (std.mem.startsWith(u8, input, method) or std.mem.startsWith(u8, method, input)) return true;
    }
    return false;
}

test "detects protocol hints from early bytes" {
    try std.testing.expectEqual(Kind.http1, detect("GET / HTTP/1.1\r\n"));
    try std.testing.expectEqual(Kind.http1, detect("G"));
    try std.testing.expectEqual(Kind.tls_client_hello, detect(&.{ 0x16, 0x03, 0x03 }));
    try std.testing.expectEqual(Kind.tls_client_hello, detect(&.{0x16}));
    try std.testing.expectEqual(Kind.unknown, detect("PRI *"));
    try std.testing.expectEqual(Kind.http2_preface, detect(http_config.h2c_preface));
}
