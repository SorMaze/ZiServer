const std = @import("std");

pub const max_pairs = 32;

pub const ParseError = error{
    InvalidEncoding,
    TooManyPairs,
};

pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

pub const View = struct {
    pairs: [max_pairs]Pair = undefined,
    len: usize = 0,
    valid: bool = true,

    pub fn empty() View {
        return .{};
    }

    pub fn invalid() View {
        return .{ .valid = false };
    }

    pub fn getFirst(self: View, name: []const u8) ?[]const u8 {
        for (self.pairs[0..self.len]) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }

    pub fn count(self: View, name: []const u8) usize {
        var total: usize = 0;
        for (self.pairs[0..self.len]) |pair| {
            if (std.mem.eql(u8, pair.name, name)) total += 1;
        }
        return total;
    }
};

pub fn parse(raw: []const u8) ParseError!View {
    var view = View.empty();
    if (raw.len == 0) return view;

    var parts = std.mem.splitScalar(u8, raw, '&');
    while (parts.next()) |part| {
        if (view.len >= max_pairs) return error.TooManyPairs;

        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const name = part[0..eq];
        const value = if (eq < part.len) part[eq + 1 ..] else "";
        try validateComponent(name);
        try validateComponent(value);

        view.pairs[view.len] = .{ .name = name, .value = value };
        view.len += 1;
    }
    return view;
}

pub fn decodeComponent(input: []const u8, output: []u8) ParseError![]const u8 {
    var in_index: usize = 0;
    var out_index: usize = 0;

    while (in_index < input.len) {
        const byte = input[in_index];
        if (byte == '+') {
            if (out_index >= output.len) return error.InvalidEncoding;
            output[out_index] = ' ';
            out_index += 1;
            in_index += 1;
            continue;
        }
        if (byte == '%') {
            if (in_index + 2 >= input.len) return error.InvalidEncoding;
            const hi = hexValue(input[in_index + 1]) orelse return error.InvalidEncoding;
            const lo = hexValue(input[in_index + 2]) orelse return error.InvalidEncoding;
            if (out_index >= output.len) return error.InvalidEncoding;
            output[out_index] = (hi << 4) | lo;
            out_index += 1;
            in_index += 3;
            continue;
        }

        if (out_index >= output.len) return error.InvalidEncoding;
        output[out_index] = byte;
        out_index += 1;
        in_index += 1;
    }

    return output[0..out_index];
}

fn validateComponent(input: []const u8) ParseError!void {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (input[index] != '%') continue;
        if (index + 2 >= input.len) return error.InvalidEncoding;
        if (hexValue(input[index + 1]) == null or hexValue(input[index + 2]) == null) {
            return error.InvalidEncoding;
        }
        index += 2;
    }
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "parse supports repeated keys empty values and encoded components" {
    const view = try parse("a=1&a=2&empty=&bare&encoded=hello%20world");
    try std.testing.expectEqual(@as(usize, 5), view.len);
    try std.testing.expectEqualStrings("1", view.getFirst("a").?);
    try std.testing.expectEqual(@as(usize, 2), view.count("a"));
    try std.testing.expectEqualStrings("", view.getFirst("empty").?);
    try std.testing.expectEqualStrings("", view.getFirst("bare").?);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello world", try decodeComponent(view.getFirst("encoded").?, &buffer));
}

test "parse rejects invalid percent encoding" {
    try std.testing.expectError(error.InvalidEncoding, parse("bad=%ZZ"));
    try std.testing.expectError(error.InvalidEncoding, parse("bad=%1"));
}
