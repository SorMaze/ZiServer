const std = @import("std");
const http_config = @import("http_config.zig");

pub const ParseError = error{
    BadRequest,
    HeaderTooLarge,
    UnsupportedHttpVersion,
};

pub const Method = enum {
    get,
    head,
    post,
    put,
    delete,
    patch,
    options,
    unknown,
};

pub const Version = enum {
    http10,
    http11,
};

pub const Request = struct {
    raw: []const u8,
    method: Method,
    method_text: []const u8,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: Version,
    headers: []const u8,
    body: []const u8,
    declared_content_length: ?usize,
    transfer_chunked: bool,

    pub fn parse(raw: []const u8) ParseError!Request {
        if (isHttp2Preface(raw)) return error.UnsupportedHttpVersion;

        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
        const head = raw[0..header_end];
        const body = raw[header_end + 4 ..];
        const request_line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
        const request_line = head[0..request_line_end];
        const headers = head[request_line_end + 2 ..];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method_text = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        const version_text = parts.next() orelse return error.BadRequest;
        if (parts.next() != null or method_text.len == 0 or target.len == 0) return error.BadRequest;

        const version: Version = if (std.mem.eql(u8, version_text, "HTTP/1.1"))
            .http11
        else if (std.mem.eql(u8, version_text, "HTTP/1.0"))
            .http10
        else if (std.mem.startsWith(u8, version_text, "HTTP/2") or
            std.mem.startsWith(u8, version_text, "HTTP/3"))
            return error.UnsupportedHttpVersion
        else
            return error.BadRequest;

        const path, const query = splitTarget(target);
        if (!validPath(path)) return error.BadRequest;
        if (!validTarget(target)) return error.BadRequest;
        const framing = try validateHeaders(headers);

        return .{
            .raw = raw,
            .method = parseMethod(method_text),
            .method_text = method_text,
            .target = target,
            .path = path,
            .query = query,
            .version = version,
            .headers = headers,
            .body = body,
            .declared_content_length = framing.content_length,
            .transfer_chunked = framing.transfer_chunked,
        };
    }

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        var rest = self.headers;
        while (rest.len > 0) {
            const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
            const line = rest[0..line_end];
            if (line.len == 0) return null;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const header_name = std.mem.trim(u8, line[0..colon], " \t");
                if (std.ascii.eqlIgnoreCase(header_name, name)) {
                    return std.mem.trim(u8, line[colon + 1 ..], " \t");
                }
            }
            if (line_end == rest.len) break;
            rest = rest[line_end + 2 ..];
        }
        return null;
    }

    pub fn connectionContains(self: Request, token: []const u8) bool {
        const value = self.header(http_config.HeaderName.connection) orelse return false;
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
        }
        return false;
    }

    pub fn wantsKeepAlive(self: Request, server_keep_alive: bool, close_due_to_limit: bool) bool {
        if (!server_keep_alive or close_due_to_limit) return false;
        if (self.connectionContains(http_config.HeaderValue.close)) return false;
        return switch (self.version) {
            .http11 => true,
            .http10 => self.connectionContains(http_config.HeaderValue.keep_alive),
        };
    }

    pub fn allowsBodylessResponse(self: Request) bool {
        return self.method == .get or self.method == .head;
    }

    pub fn isHead(self: Request) bool {
        return self.method == .head;
    }

    pub fn contentLength(self: Request) ?usize {
        return self.declared_content_length;
    }

    pub fn isChunked(self: Request) bool {
        return self.transfer_chunked;
    }

    pub fn expectsContinue(self: Request) bool {
        const value = self.header("Expect") orelse return false;
        return std.ascii.eqlIgnoreCase(value, "100-continue");
    }

    pub fn hasUnsupportedExpectation(self: Request) bool {
        return self.header("Expect") != null and !self.expectsContinue();
    }

    pub fn contentType(self: Request) ?[]const u8 {
        return self.header(http_config.HeaderName.content_type);
    }

    pub fn hasContentType(self: Request, expected: []const u8) bool {
        const value = self.contentType() orelse return false;
        const media_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        const media = std.mem.trim(u8, value[0..media_end], " \t");
        return std.ascii.eqlIgnoreCase(media, expected);
    }

    pub fn canSubmitForm(self: Request) bool {
        return self.method == .post and
            (self.hasContentType(http_config.ContentType.form_urlencoded) or
                self.hasContentType(http_config.ContentType.multipart_form));
    }
};

pub fn isHttp2Preface(raw: []const u8) bool {
    return raw.len >= http_config.h2c_preface.len and
        std.mem.eql(u8, raw[0..http_config.h2c_preface.len], http_config.h2c_preface);
}

fn splitTarget(target: []const u8) struct { []const u8, []const u8 } {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return .{ target, "" };
    return .{ target[0..query_start], target[query_start + 1 ..] };
}

fn parseMethod(method: []const u8) Method {
    if (std.mem.eql(u8, method, "GET")) return .get;
    if (std.mem.eql(u8, method, "HEAD")) return .head;
    if (std.mem.eql(u8, method, "POST")) return .post;
    if (std.mem.eql(u8, method, "PUT")) return .put;
    if (std.mem.eql(u8, method, "DELETE")) return .delete;
    if (std.mem.eql(u8, method, "PATCH")) return .patch;
    if (std.mem.eql(u8, method, "OPTIONS")) return .options;
    return .unknown;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    return true;
}

fn validTarget(target: []const u8) bool {
    for (target) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

const Framing = struct {
    content_length: ?usize = null,
    transfer_chunked: bool = false,
};

fn validateHeaders(headers: []const u8) ParseError!Framing {
    var content_length: ?usize = null;
    var transfer_chunked = false;
    var expect_seen = false;
    var rest = headers;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return error.BadRequest;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        if (name.len == 0 or !isHeaderName(name)) return error.BadRequest;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!isHeaderValue(value)) return error.BadRequest;

        if (std.ascii.eqlIgnoreCase(name, http_config.HeaderName.content_length)) {
            if (content_length != null or transfer_chunked) return error.BadRequest;
            content_length = try parseContentLength(value);
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (transfer_chunked or content_length != null or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.BadRequest;
            transfer_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Expect")) {
            if (expect_seen) return error.BadRequest;
            expect_seen = true;
        }

        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return .{ .content_length = content_length, .transfer_chunked = transfer_chunked };
}

fn isHeaderName(name: []const u8) bool {
    for (name) |byte| {
        if (!isTokenByte(byte)) return false;
    }
    return true;
}

fn isTokenByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn isHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn parseContentLength(value: []const u8) ParseError!usize {
    if (value.len == 0) return error.BadRequest;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.BadRequest;
    }
    return std.fmt.parseInt(usize, value, 10) catch error.BadRequest;
}

test "parses HTTP/1.1 request" {
    const request = try Request.parse("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(Method.get, request.method);
    try std.testing.expectEqual(Version.http11, request.version);
    try std.testing.expectEqualStrings("/health", request.path);
}

test "rejects HTTP/2 connection preface" {
    try std.testing.expectError(
        error.UnsupportedHttpVersion,
        Request.parse(http_config.h2c_preface),
    );
}

test "rejects unsupported HTTP major versions" {
    try std.testing.expectError(
        error.UnsupportedHttpVersion,
        Request.parse("GET / HTTP/2.0\r\nHost: localhost\r\n\r\n"),
    );
    try std.testing.expectError(
        error.UnsupportedHttpVersion,
        Request.parse("GET / HTTP/3.0\r\nHost: localhost\r\n\r\n"),
    );
}

test "rejects ambiguous request framing and malformed headers" {
    try std.testing.expectError(
        error.BadRequest,
        Request.parse("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"),
    );
    const chunked = try Request.parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nhello");
    try std.testing.expect(chunked.isChunked());
    try std.testing.expectEqualStrings("hello", chunked.body);
    try std.testing.expectError(error.BadRequest, Request.parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx"));
    try std.testing.expectError(error.BadRequest, Request.parse("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"));
    try std.testing.expectError(
        error.BadRequest,
        Request.parse("GET / HTTP/1.1\r\nBad Header: value\r\n\r\n"),
    );
    try std.testing.expectError(
        error.BadRequest,
        Request.parse("GET /bad path HTTP/1.1\r\nHost: test\r\n\r\n"),
    );
}
