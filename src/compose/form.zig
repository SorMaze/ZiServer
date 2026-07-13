const std = @import("std");

pub const ParseError = error{
    InvalidEncoding,
};

pub const Summary = struct {
    fields: usize = 0,
    empty_names: usize = 0,
    decoded_bytes: usize = 0,
};

pub const MultipartSummary = struct {
    parts: usize = 0,
    fields: usize = 0,
    files: usize = 0,
    bytes: usize = 0,
};

pub const MultipartParser = struct {
    const State = enum { first_boundary, headers, data, boundary, done };
    const max_part_header_bytes = 4096;

    marker: [72]u8 = undefined,
    marker_len: usize,
    buffer: [max_part_header_bytes + 80]u8 = undefined,
    buffered: usize = 0,
    state: State = .first_boundary,
    summary: MultipartSummary = .{},

    pub fn init(content_type: []const u8) ParseError!MultipartParser {
        const boundary = multipartBoundary(content_type) orelse return error.InvalidEncoding;
        if (boundary.len == 0 or boundary.len > 70) return error.InvalidEncoding;
        var parser = MultipartParser{ .marker_len = boundary.len + 2 };
        parser.marker[0] = '-';
        parser.marker[1] = '-';
        @memcpy(parser.marker[2..parser.marker_len], boundary);
        return parser;
    }

    pub fn feed(self: *MultipartParser, input: []const u8) ParseError!void {
        var rest = input;
        while (rest.len != 0) {
            if (self.buffered == self.buffer.len) {
                if (!try self.process()) return error.InvalidEncoding;
                continue;
            }
            const amount = @min(rest.len, self.buffer.len - self.buffered);
            @memcpy(self.buffer[self.buffered .. self.buffered + amount], rest[0..amount]);
            self.buffered += amount;
            rest = rest[amount..];
            while (try self.process()) {}
        }
    }

    pub fn finish(self: *MultipartParser) ParseError!MultipartSummary {
        while (try self.process()) {}
        if (self.state != .done) return error.InvalidEncoding;
        if (self.buffered != 0 and !std.mem.eql(u8, self.buffer[0..self.buffered], "\r\n")) return error.InvalidEncoding;
        return self.summary;
    }

    fn process(self: *MultipartParser) ParseError!bool {
        return switch (self.state) {
            .first_boundary, .boundary => self.processBoundary(),
            .headers => self.processHeaders(),
            .data => self.processData(),
            .done => false,
        };
    }

    fn processBoundary(self: *MultipartParser) ParseError!bool {
        if (self.buffered < self.marker_len + 2) return false;
        if (!std.mem.eql(u8, self.buffer[0..self.marker_len], self.marker[0..self.marker_len])) return error.InvalidEncoding;
        const suffix = self.buffer[self.marker_len .. self.marker_len + 2];
        if (std.mem.eql(u8, suffix, "--")) {
            self.consume(self.marker_len + 2);
            self.state = .done;
            return true;
        }
        if (!std.mem.eql(u8, suffix, "\r\n")) return error.InvalidEncoding;
        self.consume(self.marker_len + 2);
        self.state = .headers;
        return true;
    }

    fn processHeaders(self: *MultipartParser) ParseError!bool {
        const header_end = std.mem.indexOf(u8, self.buffer[0..self.buffered], "\r\n\r\n") orelse {
            if (self.buffered >= max_part_header_bytes) return error.InvalidEncoding;
            return false;
        };
        const headers = self.buffer[0..header_end];
        self.summary.parts += 1;
        if (isFilePart(headers)) self.summary.files += 1 else self.summary.fields += 1;
        self.consume(header_end + 4);
        self.state = .data;
        return true;
    }

    fn processData(self: *MultipartParser) ParseError!bool {
        var delimiter: [76]u8 = undefined;
        delimiter[0] = '\r';
        delimiter[1] = '\n';
        @memcpy(delimiter[2 .. self.marker_len + 2], self.marker[0..self.marker_len]);
        const delimiter_slice = delimiter[0 .. self.marker_len + 2];
        if (std.mem.indexOf(u8, self.buffer[0..self.buffered], delimiter_slice)) |index| {
            self.summary.bytes += index;
            self.consume(index + 2);
            self.state = .boundary;
            return true;
        }
        const keep = delimiter_slice.len - 1;
        if (self.buffered <= keep) return false;
        const safe = self.buffered - keep;
        self.summary.bytes += safe;
        self.consume(safe);
        return true;
    }

    fn consume(self: *MultipartParser, amount: usize) void {
        std.debug.assert(amount <= self.buffered);
        std.mem.copyForwards(u8, self.buffer[0 .. self.buffered - amount], self.buffer[amount..self.buffered]);
        self.buffered -= amount;
    }
};

pub fn parseUrlEncoded(body: []const u8, scratch: []u8) ParseError!Summary {
    var summary = Summary{};
    if (body.len == 0) return summary;

    var parts = std.mem.splitScalar(u8, body, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;

        const equals = std.mem.indexOfScalar(u8, part, '=');
        const name_raw = if (equals) |index| part[0..index] else part;
        const value_raw = if (equals) |index| part[index + 1 ..] else "";

        const name_len = try decodeComponent(name_raw, scratch);
        const value_len = try decodeComponent(value_raw, scratch);

        summary.fields += 1;
        if (name_len == 0) summary.empty_names += 1;
        summary.decoded_bytes += name_len + value_len;
    }

    return summary;
}

pub fn parseMultipart(content_type: []const u8, body: []const u8) ParseError!MultipartSummary {
    var parser = try MultipartParser.init(content_type);
    // Exercise the streaming path even for already-buffered callers.
    var cursor: usize = 0;
    while (cursor < body.len) {
        const end = @min(body.len, cursor + 1024);
        try parser.feed(body[cursor..end]);
        cursor = end;
    }
    return parser.finish();
}

pub fn multipartBoundary(content_type: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, content_type, ';');
    const media = std.mem.trim(u8, parts.next() orelse return null, " \t");
    if (!std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return null;

    var found: ?[]const u8 = null;
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "boundary")) continue;
        if (found != null) return null;
        var value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (!validMultipartBoundary(value)) return null;
        found = value;
    }
    return found;
}

fn validMultipartBoundary(value: []const u8) bool {
    if (value.len == 0 or value.len > 70 or value[value.len - 1] == ' ') return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == ' ') continue;
        switch (byte) {
            '\'', '(', ')', '+', '_', ',', '-', '.', '/', ':', '=', '?' => continue,
            else => return false,
        }
    }
    return true;
}

fn isFilePart(headers: []const u8) bool {
    var rest = headers;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        if (std.ascii.startsWithIgnoreCase(line, "Content-Disposition:") and
            std.mem.indexOf(u8, line, "filename=") != null)
        {
            return true;
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return false;
}

fn decodeComponent(input: []const u8, scratch: []u8) ParseError!usize {
    var read_index: usize = 0;
    var write_index: usize = 0;

    while (read_index < input.len) {
        const byte = input[read_index];
        if (byte == '+') {
            scratch[write_index] = ' ';
            read_index += 1;
        } else if (byte == '%') {
            if (read_index + 2 >= input.len) return error.InvalidEncoding;
            const high = hexValue(input[read_index + 1]) orelse return error.InvalidEncoding;
            const low = hexValue(input[read_index + 2]) orelse return error.InvalidEncoding;
            scratch[write_index] = (high << 4) | low;
            read_index += 3;
        } else {
            scratch[write_index] = byte;
            read_index += 1;
        }
        write_index += 1;
    }

    return write_index;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test parseUrlEncoded {
    var scratch: [256]u8 = undefined;
    const summary = try parseUrlEncoded("name=zi+server&encoded=%E4%B8%AD&empty=", &scratch);
    try std.testing.expectEqual(@as(usize, 3), summary.fields);
    try std.testing.expectEqual(@as(usize, 0), summary.empty_names);
    try std.testing.expectEqual(@as(usize, 28), summary.decoded_bytes);
}

test "parseUrlEncoded skips empty pairs and tracks empty names" {
    var scratch: [64]u8 = undefined;
    const summary = try parseUrlEncoded("&&=value&flag&&", &scratch);
    try std.testing.expectEqual(@as(usize, 2), summary.fields);
    try std.testing.expectEqual(@as(usize, 1), summary.empty_names);
    try std.testing.expectEqual(@as(usize, 9), summary.decoded_bytes);
}

test "parseUrlEncoded rejects invalid percent encoding" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, parseUrlEncoded("bad=%ZZ", &scratch));
    try std.testing.expectError(error.InvalidEncoding, parseUrlEncoded("bad=%A", &scratch));
}

test "parseMultipart counts fields and files" {
    const body =
        "--abc\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--abc\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file-body\r\n" ++
        "--abc--\r\n";
    const summary = try parseMultipart("multipart/form-data; boundary=abc", body);
    try std.testing.expectEqual(@as(usize, 2), summary.parts);
    try std.testing.expectEqual(@as(usize, 1), summary.fields);
    try std.testing.expectEqual(@as(usize, 1), summary.files);
    try std.testing.expectEqual(@as(usize, 14), summary.bytes);
}

test "parseMultipart rejects missing boundary" {
    try std.testing.expectError(error.InvalidEncoding, parseMultipart("multipart/form-data", ""));
    try std.testing.expectError(error.InvalidEncoding, parseMultipart("multipart/form-data; boundary=abc; boundary=def", ""));
    try std.testing.expectError(error.InvalidEncoding, parseMultipart("multipart/form-data; boundary=bad@value", ""));
}

test "multipart parser handles boundaries split across feeds" {
    const body = "--xyz\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--xyz--\r\n";
    var parser = try MultipartParser.init("multipart/form-data; boundary=xyz");
    for (body) |byte| try parser.feed(&.{byte});
    const summary = try parser.finish();
    try std.testing.expectEqual(@as(usize, 1), summary.parts);
    try std.testing.expectEqual(@as(usize, 1), summary.fields);
    try std.testing.expectEqual(@as(usize, 5), summary.bytes);
}
