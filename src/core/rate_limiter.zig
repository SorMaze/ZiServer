const std = @import("std");

const client_identity = @import("client_identity.zig");
const http_config = @import("http_config.zig");

pub const default_capacity: usize = 65_536;
pub const default_shards: usize = 64;
pub const default_idle_ttl_ms: u32 = 10 * 60 * 1000;
pub const max_capacity: usize = 1_048_576;
pub const max_shards: usize = 256;

pub const Config = struct {
    relaxed_rps: u32 = 0,
    strict_rps: u32 = 0,
    capacity: usize = default_capacity,
    shards: usize = default_shards,
    idle_ttl_ms: u32 = default_idle_ttl_ms,

    pub fn validate(self: Config) !void {
        if (self.capacity == 0 or self.capacity > max_capacity) return error.InvalidRateLimitCapacity;
        if (self.shards == 0 or self.shards > max_shards or self.shards > self.capacity) return error.InvalidRateLimitShards;
        if (self.idle_ttl_ms < 1000) return error.InvalidRateLimitIdleTtl;
    }

    pub fn threshold(self: Config, policy: http_config.RateLimitPolicy) u32 {
        return switch (policy) {
            .none => 0,
            .relaxed => self.relaxed_rps,
            .strict => self.strict_rps,
        };
    }
};

pub const Decision = enum {
    allowed,
    rejected,
    capacity_rejected,
};

pub const Snapshot = struct {
    entries: usize,
    allowed_relaxed: u64,
    allowed_strict: u64,
    rejected_relaxed: u64,
    rejected_strict: u64,
    expired: u64,
    capacity_rejections: u64,
};

const Key = struct {
    ip: client_identity.IpKey,
    policy: http_config.RateLimitPolicy,
};

const Entry = struct {
    window_start_ms: i64,
    last_seen_ms: i64,
    count: u64,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        return key.ip.hash() ^ (@as(u64, @intFromEnum(key.policy)) *% 0x9e3779b97f4a7c15);
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.policy == b.policy and a.ip.eql(b.ip);
    }
};

const Map = std.HashMap(Key, Entry, KeyContext, std.hash_map.default_max_load_percentage);

const Shard = struct {
    mutex: std.Io.Mutex = .init,
    entries: Map,
    capacity: usize,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    shards: []Shard,
    entry_count: std.atomic.Value(usize) = .init(0),
    allowed_relaxed: std.atomic.Value(u64) = .init(0),
    allowed_strict: std.atomic.Value(u64) = .init(0),
    rejected_relaxed: std.atomic.Value(u64) = .init(0),
    rejected_strict: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(u64) = .init(0),
    capacity_rejections: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, config: Config) !Limiter {
        try config.validate();
        const shards = try allocator.alloc(Shard, config.shards);
        var initialized: usize = 0;
        errdefer {
            for (shards[0..initialized]) |*shard| shard.entries.deinit();
            allocator.free(shards);
        }

        const base = config.capacity / config.shards;
        const remainder = config.capacity % config.shards;
        for (shards, 0..) |*shard, index| {
            const capacity = base + @as(usize, if (index < remainder) 1 else 0);
            shard.* = .{
                .entries = Map.init(allocator),
                .capacity = capacity,
            };
            try shard.entries.ensureTotalCapacity(@intCast(capacity));
            initialized += 1;
        }
        return .{ .allocator = allocator, .config = config, .shards = shards };
    }

    pub fn deinit(self: *Limiter, io: std.Io) void {
        for (self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            shard.entries.deinit();
            shard.mutex.unlock(io);
        }
        self.allocator.free(self.shards);
        self.shards = &.{};
    }

    pub fn check(
        self: *Limiter,
        io: std.Io,
        ip: client_identity.IpKey,
        policy: http_config.RateLimitPolicy,
    ) !Decision {
        const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
        return self.checkAt(io, ip, policy, now_ms);
    }

    pub fn checkAt(
        self: *Limiter,
        io: std.Io,
        ip: client_identity.IpKey,
        policy: http_config.RateLimitPolicy,
        now_ms: i64,
    ) !Decision {
        const threshold = self.config.threshold(policy);
        if (policy == .none or threshold == 0) {
            self.recordAllowed(policy);
            return .allowed;
        }

        const key = Key{ .ip = ip, .policy = policy };
        const shard = &self.shards[@intCast(KeyContext.hash(.{}, key) % self.shards.len)];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.entries.getPtr(key)) |entry| {
            if (now_ms < entry.window_start_ms or now_ms - entry.window_start_ms >= 1000) {
                entry.window_start_ms = now_ms;
                entry.count = 0;
            }
            entry.last_seen_ms = now_ms;
            if (entry.count >= threshold) {
                self.recordRejected(policy);
                return .rejected;
            }
            entry.count += 1;
            self.recordAllowed(policy);
            return .allowed;
        }

        if (shard.entries.count() >= shard.capacity) self.removeExpired(shard, now_ms);
        if (shard.entries.count() >= shard.capacity) {
            _ = self.capacity_rejections.fetchAdd(1, .monotonic);
            self.recordRejected(policy);
            return .capacity_rejected;
        }

        try shard.entries.put(key, .{
            .window_start_ms = now_ms,
            .last_seen_ms = now_ms,
            .count = 1,
        });
        _ = self.entry_count.fetchAdd(1, .monotonic);
        self.recordAllowed(policy);
        return .allowed;
    }

    pub fn snapshot(self: *const Limiter) Snapshot {
        return .{
            .entries = self.entry_count.load(.monotonic),
            .allowed_relaxed = self.allowed_relaxed.load(.monotonic),
            .allowed_strict = self.allowed_strict.load(.monotonic),
            .rejected_relaxed = self.rejected_relaxed.load(.monotonic),
            .rejected_strict = self.rejected_strict.load(.monotonic),
            .expired = self.expired.load(.monotonic),
            .capacity_rejections = self.capacity_rejections.load(.monotonic),
        };
    }

    fn removeExpired(self: *Limiter, shard: *Shard, now_ms: i64) void {
        while (true) {
            var expired_key: ?Key = null;
            var iterator = shard.entries.iterator();
            while (iterator.next()) |item| {
                if (now_ms < item.value_ptr.last_seen_ms or
                    now_ms - item.value_ptr.last_seen_ms >= self.config.idle_ttl_ms)
                {
                    expired_key = item.key_ptr.*;
                    break;
                }
            }
            const key = expired_key orelse return;
            if (shard.entries.remove(key)) {
                _ = self.entry_count.fetchSub(1, .monotonic);
                _ = self.expired.fetchAdd(1, .monotonic);
            }
        }
    }

    fn recordAllowed(self: *Limiter, policy: http_config.RateLimitPolicy) void {
        const counter = switch (policy) {
            .none => return,
            .relaxed => &self.allowed_relaxed,
            .strict => &self.allowed_strict,
        };
        _ = counter.fetchAdd(1, .monotonic);
    }

    fn recordRejected(self: *Limiter, policy: http_config.RateLimitPolicy) void {
        const counter = switch (policy) {
            .none => return,
            .relaxed => &self.rejected_relaxed,
            .strict => &self.rejected_strict,
        };
        _ = counter.fetchAdd(1, .monotonic);
    }
};

test "different client IPs have independent fixed-window budgets" {
    var limiter = try Limiter.init(std.testing.allocator, .{
        .strict_rps = 2,
        .capacity = 8,
        .shards = 2,
    });
    defer limiter.deinit(std.testing.io);
    const a = try client_identity.IpKey.parse("192.0.2.1");
    const b = try client_identity.IpKey.parse("192.0.2.2");
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, a, .strict, 1000));
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, a, .strict, 1001));
    try std.testing.expectEqual(Decision.rejected, try limiter.checkAt(std.testing.io, a, .strict, 1002));
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, b, .strict, 1002));
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, a, .strict, 2000));
}

test "policy budgets are independent and disabled policies allocate nothing" {
    var limiter = try Limiter.init(std.testing.allocator, .{
        .relaxed_rps = 1,
        .strict_rps = 1,
        .capacity = 4,
        .shards = 1,
    });
    defer limiter.deinit(std.testing.io);
    const ip = try client_identity.IpKey.parse("192.0.2.1");
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, ip, .relaxed, 1));
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, ip, .strict, 1));
    try std.testing.expectEqual(Decision.rejected, try limiter.checkAt(std.testing.io, ip, .relaxed, 2));

    var disabled = try Limiter.init(std.testing.allocator, .{ .capacity = 1, .shards = 1 });
    defer disabled.deinit(std.testing.io);
    try std.testing.expectEqual(Decision.allowed, try disabled.checkAt(std.testing.io, ip, .strict, 1));
    try std.testing.expectEqual(@as(usize, 0), disabled.snapshot().entries);
}

test "full limiter expires idle entries then fails closed" {
    var limiter = try Limiter.init(std.testing.allocator, .{
        .strict_rps = 1,
        .capacity = 1,
        .shards = 1,
        .idle_ttl_ms = 1000,
    });
    defer limiter.deinit(std.testing.io);
    const a = try client_identity.IpKey.parse("192.0.2.1");
    const b = try client_identity.IpKey.parse("192.0.2.2");
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, a, .strict, 1000));
    try std.testing.expectEqual(Decision.capacity_rejected, try limiter.checkAt(std.testing.io, b, .strict, 1001));
    try std.testing.expectEqual(Decision.allowed, try limiter.checkAt(std.testing.io, b, .strict, 2000));
    try std.testing.expectEqual(@as(usize, 1), limiter.snapshot().entries);
    try std.testing.expectEqual(@as(u64, 1), limiter.snapshot().expired);
}

test "concurrent requests cannot exceed one IP budget" {
    var limiter = try Limiter.init(std.heap.page_allocator, .{
        .strict_rps = 8,
        .capacity = 8,
        .shards = 1,
    });
    defer limiter.deinit(std.testing.io);
    const ip = try client_identity.IpKey.parse("192.0.2.1");
    var allowed: std.atomic.Value(usize) = .init(0);
    const Runner = struct {
        fn run(store: *Limiter, address: client_identity.IpKey, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
            if ((store.checkAt(std.testing.io, address, .strict, 1000) catch @panic("limiter allocation failed")) == .allowed) {
                _ = count.fetchAdd(1, .monotonic);
            }
        }
    };
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    for (0..32) |_| group.async(std.testing.io, Runner.run, .{ &limiter, ip, &allowed });
    try group.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 8), allowed.load(.monotonic));
}

test "independent limiter instances do not share state" {
    var first = try Limiter.init(std.testing.allocator, .{ .strict_rps = 1, .capacity = 1, .shards = 1 });
    defer first.deinit(std.testing.io);
    var second = try Limiter.init(std.testing.allocator, .{ .strict_rps = 1, .capacity = 1, .shards = 1 });
    defer second.deinit(std.testing.io);
    const ip = try client_identity.IpKey.parse("192.0.2.1");
    try std.testing.expectEqual(Decision.allowed, try first.checkAt(std.testing.io, ip, .strict, 1));
    try std.testing.expectEqual(Decision.rejected, try first.checkAt(std.testing.io, ip, .strict, 2));
    try std.testing.expectEqual(Decision.allowed, try second.checkAt(std.testing.io, ip, .strict, 2));
}
