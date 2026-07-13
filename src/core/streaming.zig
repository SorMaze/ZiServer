const std = @import("std");

pub const PullFn = *const fn (?*anyopaque, []u8) anyerror!usize;

pub const Reader = struct {
    source: Source,
    bytes_read: usize = 0,
    ended: bool = false,
    max_bytes: usize = std.math.maxInt(usize),
    expected_length: ?usize = null,

    const Source = union(enum) {
        buffered: struct {
            body: []const u8,
            cursor: usize = 0,
        },
        pull: struct {
            userdata: ?*anyopaque,
            read_fn: PullFn,
        },
    };

    pub fn buffered(body: []const u8) Reader {
        return .{ .source = .{ .buffered = .{ .body = body } } };
    }

    pub fn pull(userdata: ?*anyopaque, read_fn: PullFn) Reader {
        return .{ .source = .{ .pull = .{ .userdata = userdata, .read_fn = read_fn } } };
    }

    pub fn read(self: *Reader, destination: []u8) !usize {
        if (self.ended or destination.len == 0) return 0;
        const amount = switch (self.source) {
            .buffered => |*buffered_source| block: {
                const remaining = buffered_source.body.len - buffered_source.cursor;
                const count = @min(remaining, destination.len);
                @memcpy(destination[0..count], buffered_source.body[buffered_source.cursor .. buffered_source.cursor + count]);
                buffered_source.cursor += count;
                break :block count;
            },
            .pull => |pull_source| try pull_source.read_fn(pull_source.userdata, destination),
        };
        if (amount > destination.len) return error.InvalidStreamRead;
        if (amount > self.max_bytes -| self.bytes_read) return error.RequestBodyTooLarge;
        self.bytes_read += amount;
        self.ended = amount == 0;
        if (self.ended) {
            if (self.expected_length) |expected| if (self.bytes_read != expected) return error.BadRequest;
        }
        return amount;
    }

    pub fn setLimits(self: *Reader, max_bytes: usize, expected_length: ?usize) void {
        self.max_bytes = max_bytes;
        self.expected_length = expected_length;
    }
};

pub const QueueRead = union(enum) {
    data: usize,
    pending,
    end,
    canceled,
};

pub const ByteQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    read_index: usize = 0,
    write_index: usize = 0,
    size: usize = 0,
    ended: bool = false,
    canceled: bool = false,
    failure: ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    readable: std.Io.Condition = .init,
    writable: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ByteQueue {
        if (capacity == 0) return error.InvalidStreamCapacity;
        return .{ .allocator = allocator, .buffer = try allocator.alloc(u8, capacity) };
    }

    pub fn deinit(self: *ByteQueue, io: std.Io) void {
        self.cancel(io);
        self.allocator.free(self.buffer);
        self.buffer = &.{};
    }

    pub fn maxChunkBytes(self: *const ByteQueue) usize {
        return self.buffer.len;
    }

    pub fn push(self: *ByteQueue, io: std.Io, data: []const u8) !void {
        if (data.len > self.buffer.len) return error.StreamChunkTooLarge;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var cursor: usize = 0;
        while (cursor < data.len) {
            while (self.size == self.buffer.len and !self.canceled) self.writable.waitUncancelable(io, &self.mutex);
            if (self.canceled or self.ended) return error.StreamCanceled;
            const available = self.buffer.len - self.size;
            const contiguous = self.buffer.len - self.write_index;
            const amount = @min(data.len - cursor, @min(available, contiguous));
            @memcpy(self.buffer[self.write_index .. self.write_index + amount], data[cursor .. cursor + amount]);
            self.write_index = (self.write_index + amount) % self.buffer.len;
            self.size += amount;
            cursor += amount;
            self.readable.broadcast(io);
        }
    }

    pub fn readBlocking(self: *ByteQueue, io: std.Io, destination: []u8) !usize {
        if (destination.len == 0) return 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.size == 0 and !self.ended and !self.canceled) self.readable.waitUncancelable(io, &self.mutex);
        if (self.canceled) return error.StreamCanceled;
        if (self.failure) |err| return err;
        if (self.size == 0 and self.ended) return 0;
        return self.readLocked(io, destination);
    }

    pub fn readAvailable(self: *ByteQueue, io: std.Io, destination: []u8) QueueRead {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.canceled) return .canceled;
        if (self.failure != null) return .canceled;
        if (self.size == 0) return if (self.ended) .end else .pending;
        return .{ .data = self.readLocked(io, destination) };
    }

    pub fn finish(self: *ByteQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.ended = true;
        self.readable.broadcast(io);
        self.writable.broadcast(io);
        self.mutex.unlock(io);
    }

    pub fn cancel(self: *ByteQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.canceled = true;
        self.readable.broadcast(io);
        self.writable.broadcast(io);
        self.mutex.unlock(io);
    }

    pub fn fail(self: *ByteQueue, io: std.Io, err: anyerror) void {
        self.mutex.lockUncancelable(io);
        self.failure = err;
        self.ended = true;
        self.readable.broadcast(io);
        self.writable.broadcast(io);
        self.mutex.unlock(io);
    }

    pub fn hasReadableOrEnded(self: *ByteQueue, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.size != 0 or self.ended or self.canceled;
    }

    pub fn endedAndEmpty(self: *ByteQueue, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.ended and self.size == 0;
    }

    fn readLocked(self: *ByteQueue, io: std.Io, destination: []u8) usize {
        const contiguous = self.buffer.len - self.read_index;
        const amount = @min(destination.len, @min(self.size, contiguous));
        @memcpy(destination[0..amount], self.buffer[self.read_index .. self.read_index + amount]);
        self.read_index = (self.read_index + amount) % self.buffer.len;
        self.size -= amount;
        self.writable.broadcast(io);
        return amount;
    }
};

pub const QueueSource = struct {
    io: std.Io,
    queue: *ByteQueue,

    pub fn readerFn(userdata: ?*anyopaque, destination: []u8) anyerror!usize {
        const self: *QueueSource = @ptrCast(@alignCast(userdata orelse return error.InvalidBodyStream));
        return self.queue.readBlocking(self.io, destination);
    }
};

test "buffered stream reader yields bounded chunks" {
    var reader = Reader.buffered("abcdef");
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reader.read(&buffer));
    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&buffer));
    try std.testing.expectEqualStrings("ef", buffer[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try reader.read(&buffer));
    try std.testing.expectEqual(@as(usize, 6), reader.bytes_read);
}

test "bounded byte queue preserves wraparound and end" {
    var queue = try ByteQueue.init(std.testing.allocator, 5);
    defer queue.deinit(std.testing.io);
    try queue.push(std.testing.io, "abc");
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try queue.readBlocking(std.testing.io, output[0..2]));
    try std.testing.expectEqualStrings("ab", output[0..2]);
    try queue.push(std.testing.io, "de");
    try std.testing.expectEqual(@as(usize, 3), try queue.readBlocking(std.testing.io, output[0..3]));
    try std.testing.expectEqualStrings("cde", output[0..3]);
    queue.finish(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), try queue.readBlocking(std.testing.io, &output));
}

test "bounded byte queue propagates producer failure" {
    var queue = try ByteQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.io);
    queue.fail(std.testing.io, error.RequestBodyTooLarge);
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.RequestBodyTooLarge, queue.readBlocking(std.testing.io, &output));
}
