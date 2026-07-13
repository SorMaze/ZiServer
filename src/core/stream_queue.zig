const std = @import("std");

const stats_mod = @import("stats.zig");
const transport = @import("transport.zig");
const client_identity = @import("client_identity.zig");

pub const Security = enum {
    plain,
    tls,
};

pub const PendingConnection = struct {
    stream: transport.Stream,
    security: Security,
    peer_ip: client_identity.IpKey,
};

pub const StreamQueue = struct {
    io: std.Io,
    stats: *stats_mod.Stats,
    buffer: []PendingConnection,
    queue: std.Io.Queue(PendingConnection),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stats: *stats_mod.Stats,
        capacity: usize,
    ) !StreamQueue {
        const buffer = try allocator.alloc(PendingConnection, capacity);
        return .{
            .io = io,
            .stats = stats,
            .buffer = buffer,
            .queue = .init(buffer),
        };
    }

    pub fn deinit(self: *StreamQueue, allocator: std.mem.Allocator) void {
        self.close();
        allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn close(self: *StreamQueue) void {
        self.queue.close(self.io);
    }

    pub fn put(self: *StreamQueue, connection: PendingConnection) !void {
        self.stats.connectionQueued();
        errdefer self.stats.connectionDequeued();
        try self.queue.putOne(self.io, connection);
    }

    pub fn take(self: *StreamQueue) !PendingConnection {
        const connection = try self.queue.getOne(self.io);
        self.stats.connectionDequeued();
        return connection;
    }
};

pub const StreamQueueSet = struct {
    shards: []StreamQueue,
    next: std.atomic.Value(usize) = .init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stats: *stats_mod.Stats,
        shard_count: usize,
        total_capacity: usize,
    ) !StreamQueueSet {
        const shards = try allocator.alloc(StreamQueue, shard_count);
        errdefer allocator.free(shards);

        const per_shard_capacity = @max(1, (total_capacity + shard_count - 1) / shard_count);
        var initialized: usize = 0;
        errdefer {
            for (shards[0..initialized]) |*shard| {
                shard.deinit(allocator);
            }
        }

        for (shards) |*shard| {
            shard.* = try StreamQueue.init(allocator, io, stats, per_shard_capacity);
            initialized += 1;
        }

        return .{ .shards = shards, .next = .init(0) };
    }

    pub fn deinit(self: *StreamQueueSet, allocator: std.mem.Allocator) void {
        for (self.shards) |*shard| {
            shard.deinit(allocator);
        }
        allocator.free(self.shards);
        self.* = undefined;
    }

    pub fn close(self: *StreamQueueSet) void {
        for (self.shards) |*shard| shard.close();
    }

    pub fn shardCount(self: *const StreamQueueSet) usize {
        return self.shards.len;
    }

    pub fn put(self: *StreamQueueSet, connection: PendingConnection) !void {
        const index = self.next.fetchAdd(1, .monotonic) % self.shards.len;
        try self.shards[index].put(connection);
    }

    pub fn take(self: *StreamQueueSet, worker_index: usize) !PendingConnection {
        return self.shards[worker_index % self.shards.len].take();
    }
};
