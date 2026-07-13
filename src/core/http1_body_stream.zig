const std = @import("std");

const http_config = @import("http_config.zig");
const transport = @import("transport.zig");

pub const Source = struct {
    connection: *transport.Connection,
    initial: []const u8,
    initial_cursor: usize = 0,
    remaining: usize,
    body_limit: usize,
    chunked: bool,
    phase: Phase,
    chunk_remaining: usize = 0,
    decoded_bytes: usize = 0,
    overhead_bytes: usize = 0,
    chunks: usize = 0,
    network_reads: usize = 0,
    stopping: ?*const std.atomic.Value(bool),
    finished: bool = false,

    const Phase = enum { content_length, chunk_size, chunk_data, chunk_crlf, trailers, done };

    pub fn init(
        connection: *transport.Connection,
        initial: []const u8,
        content_length: usize,
        chunked: bool,
        body_limit: usize,
        stopping: ?*const std.atomic.Value(bool),
    ) Source {
        const finished = !chunked and content_length == 0;
        return .{
            .connection = connection,
            .initial = initial,
            .remaining = content_length,
            .body_limit = body_limit,
            .chunked = chunked,
            .phase = if (chunked) .chunk_size else if (finished) .done else .content_length,
            .stopping = stopping,
            .finished = finished,
        };
    }

    pub fn readerFn(userdata: ?*anyopaque, destination: []u8) anyerror!usize {
        const self: *Source = @ptrCast(@alignCast(userdata orelse return error.InvalidBodyStream));
        return self.read(destination);
    }

    pub fn consumedInitial(self: *const Source) usize {
        return self.initial_cursor;
    }

    fn read(self: *Source, destination: []u8) !usize {
        if (self.finished or destination.len == 0) return 0;
        if (!self.chunked) {
            const amount = @min(destination.len, self.remaining);
            const count = try self.readWire(destination[0..amount]);
            if (count == 0) return error.BadRequest;
            self.remaining -= count;
            self.decoded_bytes += count;
            if (self.remaining == 0) {
                self.phase = .done;
                self.finished = true;
            }
            return count;
        }

        while (true) switch (self.phase) {
            .chunk_size => {
                var line_buffer: [128]u8 = undefined;
                const line = try self.readLine(&line_buffer);
                const extension = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                const size_text = line[0..extension];
                if (size_text.len == 0) return error.BadRequest;
                for (line) |byte| if (byte < 0x20 or byte == 0x7f) return error.BadRequest;
                const size = std.fmt.parseInt(usize, size_text, 16) catch return error.BadRequest;
                self.overhead_bytes += line.len + 2;
                if (self.overhead_bytes > http_config.max_chunk_overhead_bytes) return error.RequestBodyTooLarge;
                if (size == 0) {
                    self.phase = .trailers;
                    continue;
                }
                self.chunks += 1;
                if (self.chunks > http_config.max_body_read_ops or size > self.body_limit -| self.decoded_bytes) return error.RequestBodyTooLarge;
                self.chunk_remaining = size;
                self.phase = .chunk_data;
            },
            .chunk_data => {
                const amount = @min(destination.len, self.chunk_remaining);
                const count = try self.readWire(destination[0..amount]);
                if (count == 0) return error.BadRequest;
                self.chunk_remaining -= count;
                self.decoded_bytes += count;
                if (self.chunk_remaining == 0) self.phase = .chunk_crlf;
                return count;
            },
            .chunk_crlf => {
                var suffix: [2]u8 = undefined;
                try self.readExact(&suffix);
                if (!std.mem.eql(u8, &suffix, "\r\n")) return error.BadRequest;
                self.overhead_bytes += 2;
                if (self.overhead_bytes > http_config.max_chunk_overhead_bytes) return error.RequestBodyTooLarge;
                self.phase = .chunk_size;
            },
            .trailers => {
                var line_buffer: [http_config.max_header_bytes]u8 = undefined;
                const line = try self.readLine(&line_buffer);
                self.overhead_bytes += line.len + 2;
                if (self.overhead_bytes > http_config.max_chunk_overhead_bytes) return error.RequestBodyTooLarge;
                if (line.len == 0) {
                    self.phase = .done;
                    self.finished = true;
                    return 0;
                }
                try validateTrailer(line);
            },
            .done => {
                self.finished = true;
                return 0;
            },
            .content_length => unreachable,
        };
    }

    fn readLine(self: *Source, buffer: []u8) ![]const u8 {
        var length: usize = 0;
        while (true) {
            if (length >= buffer.len) return error.BadRequest;
            var byte: [1]u8 = undefined;
            try self.readExact(&byte);
            if (byte[0] == '\n') {
                if (length == 0 or buffer[length - 1] != '\r') return error.BadRequest;
                return buffer[0 .. length - 1];
            }
            buffer[length] = byte[0];
            length += 1;
        }
    }

    fn readExact(self: *Source, destination: []u8) !void {
        var cursor: usize = 0;
        while (cursor < destination.len) {
            const amount = try self.readWire(destination[cursor..]);
            if (amount == 0) return error.BadRequest;
            cursor += amount;
        }
    }

    fn readWire(self: *Source, destination: []u8) !usize {
        if (destination.len == 0) return 0;
        if (self.initial_cursor < self.initial.len) {
            const amount = @min(destination.len, self.initial.len - self.initial_cursor);
            @memcpy(destination[0..amount], self.initial[self.initial_cursor .. self.initial_cursor + amount]);
            self.initial_cursor += amount;
            return amount;
        }
        if (self.stopping) |flag| if (flag.load(.acquire)) return error.GracefulShutdown;
        if (self.network_reads >= http_config.max_body_read_ops) return error.SlowRequest;
        self.network_reads += 1;
        var buffers: [1][]u8 = .{destination};
        return self.connection.read(&buffers) catch |err| switch (err) {
            error.ReadTimeout => error.RequestTimeout,
            else => err,
        };
    }
};

fn validateTrailer(line: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
    if (colon == 0 or line[0] == ' ' or line[0] == '\t') return error.BadRequest;
    const name = line[0..colon];
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => continue,
            else => return error.BadRequest,
        }
    }
    const value = line[colon + 1 ..];
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.BadRequest;
    if (std.ascii.eqlIgnoreCase(name, "Content-Length") or std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or std.ascii.eqlIgnoreCase(name, "Host")) return error.BadRequest;
}

test "live HTTP1 content-length source consumes only its body" {
    var source = Source.init(undefined, "bodyNEXT", 4, false, 16, null);
    var output: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try source.read(&output));
    try std.testing.expectEqualStrings("body", output[0..4]);
    try std.testing.expect(source.finished);
    try std.testing.expectEqual(@as(usize, 4), source.consumedInitial());
}

test "live HTTP1 chunked source decodes chunks and preserves pipeline bytes" {
    const wire = "3\r\nabc\r\n2\r\nde\r\n0\r\nX-Test: yes\r\n\r\nNEXT";
    var source = Source.init(undefined, wire, 0, true, 16, null);
    var output: [8]u8 = undefined;
    var collected: [5]u8 = undefined;
    var cursor: usize = 0;
    while (true) {
        const amount = try source.read(&output);
        if (amount == 0) break;
        @memcpy(collected[cursor .. cursor + amount], output[0..amount]);
        cursor += amount;
    }
    try std.testing.expectEqualStrings("abcde", &collected);
    try std.testing.expect(source.finished);
    try std.testing.expectEqual(wire.len - "NEXT".len, source.consumedInitial());
}
