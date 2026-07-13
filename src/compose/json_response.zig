const std = @import("std");

pub fn escapeString(input: []const u8, buffer: []u8) ![]const u8 {
    var out: usize = 0;
    for (input) |byte| {
        const replacement = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };

        if (replacement) |text| {
            if (out + text.len > buffer.len) return error.PayloadTooLarge;
            @memcpy(buffer[out .. out + text.len], text);
            out += text.len;
            continue;
        }

        if (byte < 0x20) {
            if (out + 6 > buffer.len) return error.PayloadTooLarge;
            const hex = "0123456789abcdef";
            @memcpy(buffer[out .. out + 4], "\\u00");
            buffer[out + 4] = hex[@as(usize, byte >> 4)];
            buffer[out + 5] = hex[@as(usize, byte & 0x0f)];
            out += 6;
            continue;
        }

        if (out + 1 > buffer.len) return error.PayloadTooLarge;
        buffer[out] = byte;
        out += 1;
    }
    return buffer[0..out];
}

test "escapes json string control characters" {
    var buffer: [128]u8 = undefined;
    const escaped = try escapeString("hello \"zig\"\n", &buffer);
    try std.testing.expectEqualStrings("hello \\\"zig\\\"\\n", escaped);
}
