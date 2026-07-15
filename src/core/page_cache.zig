const std = @import("std");

const request_mod = @import("request.zig");
const response = @import("response.zig");

pub const Policy = enum {
    none,
    short,
    standard,
    long,

    pub fn ttlNs(self: Policy) i96 {
        const seconds: i96 = switch (self) {
            .none => 0,
            .short => 5,
            .standard => 30,
            .long => 300,
        };
        return seconds * std.time.ns_per_s;
    }
};

pub const Scope = enum {
    cookie_partitioned,
    shared,
};

pub const Strategy = enum {
    static_shared,
    recommended,
    discouraged,
    never,

    pub const Profile = struct {
        policy: Policy,
        scope: Scope,
        response_cache: response.CachePolicy,
    };

    pub fn profile(self: Strategy) Profile {
        return switch (self) {
            .static_shared => .{ .policy = .long, .scope = .shared, .response_cache = .static_asset },
            .recommended => .{ .policy = .standard, .scope = .cookie_partitioned, .response_cache = .api_short },
            .discouraged => .{ .policy = .none, .scope = .cookie_partitioned, .response_cache = .no_cache },
            .never => .{ .policy = .none, .scope = .cookie_partitioned, .response_cache = .no_store },
        };
    }
};

test "cache strategy arena maps every strategy atomically" {
    try std.testing.expectEqual(Policy.long, Strategy.static_shared.profile().policy);
    try std.testing.expectEqual(Scope.shared, Strategy.static_shared.profile().scope);
    try std.testing.expectEqual(response.CachePolicy.static_asset, Strategy.static_shared.profile().response_cache);
    try std.testing.expectEqual(Policy.standard, Strategy.recommended.profile().policy);
    try std.testing.expectEqual(Scope.cookie_partitioned, Strategy.recommended.profile().scope);
    try std.testing.expectEqual(response.CachePolicy.api_short, Strategy.recommended.profile().response_cache);
    try std.testing.expectEqual(Policy.none, Strategy.discouraged.profile().policy);
    try std.testing.expectEqual(response.CachePolicy.no_cache, Strategy.discouraged.profile().response_cache);
    try std.testing.expectEqual(Policy.none, Strategy.never.profile().policy);
    try std.testing.expectEqual(response.CachePolicy.no_store, Strategy.never.profile().response_cache);
    try std.testing.expectEqualStrings("no-store", Strategy.never.profile().response_cache.value().?);
}

pub const default_capacity: usize = 256;
pub const default_shards: usize = 16;
pub const default_max_body_bytes: usize = 256 * 1024;
pub const default_ttl_percent: u16 = 100;
pub const default_response_header = false;
pub const default_fill_wait_timeout_ms: u32 = 100;
pub const max_capacity: usize = 16 * 1024;
pub const max_shards: usize = 64;
pub const hard_max_body_bytes: usize = 1024 * 1024;
pub const max_key_bytes: usize = 8192;

pub const Config = struct {
    capacity: usize = default_capacity,
    shards: usize = default_shards,
    max_body_bytes: usize = default_max_body_bytes,
    ttl_percent: u16 = default_ttl_percent,
    response_header: bool = default_response_header,
    fill_wait_timeout_ms: u32 = default_fill_wait_timeout_ms,

    pub fn validate(self: Config) !void {
        if (self.capacity == 0 or self.capacity > max_capacity) return error.InvalidPageCacheCapacity;
        if (self.shards == 0 or self.shards > max_shards or self.shards > self.capacity) return error.InvalidPageCacheShards;
        if (self.max_body_bytes == 0 or self.max_body_bytes > hard_max_body_bytes) return error.InvalidPageCacheBodyLimit;
        if (self.ttl_percent == 0 or self.ttl_percent > 1000) return error.InvalidPageCacheTtlPercent;
        if (self.fill_wait_timeout_ms > 30_000) return error.InvalidPageCacheFillWaitTimeout;
    }
};

pub const Snapshot = struct {
    entries: usize,
    bytes: usize,
    hits: u64,
    misses: u64,
    inserts: u64,
    evictions: u64,
    expired: u64,
    fill_leaders: u64,
    coalesced_waits: u64,
    coalesced_hits: u64,
    fill_bypasses: u64,
    fill_wait_timeouts: u64,
};

const Entry = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    content_type: []u8,
    body: []u8,
    cache_policy: response.CachePolicy,
    expires_ns: i96,
    last_used: std.atomic.Value(u64),
    refs: std.atomic.Value(usize) = .init(1),

    fn sizeBytes(self: *const Entry) usize {
        return self.key.len + self.content_type.len + self.body.len;
    }

    fn release(self: *Entry) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    fn destroy(self: *Entry) void {
        const allocator = self.allocator;
        allocator.free(self.key);
        allocator.free(self.content_type);
        allocator.free(self.body);
        allocator.destroy(self);
    }
};

const Shard = struct {
    lock: std.Io.RwLock = .init,
    entries: []?*Entry = &.{},
    fill_mutex: std.Io.Mutex = .init,
    fill_condition: std.Io.Condition = .init,
    inflight: []?Inflight = &.{},
};

const Inflight = struct {
    key: []u8,
    generation: u64,
};

pub const Handle = struct {
    entry: *Entry,

    pub fn deinit(self: Handle) void {
        self.entry.release();
    }

    pub fn contentType(self: Handle) []const u8 {
        return self.entry.content_type;
    }

    pub fn body(self: Handle) []const u8 {
        return self.entry.body;
    }

    pub fn cachePolicy(self: Handle) response.CachePolicy {
        return self.entry.cache_policy;
    }
};

pub const FillToken = struct {
    store: *Store,
    shard_index: usize,
    slot_index: usize,
    generation: u64,
    active: bool = true,

    pub fn complete(self: *FillToken, io: std.Io) void {
        if (!self.active) return;
        self.active = false;
        const shard = &self.store.shards[self.shard_index];
        shard.fill_mutex.lockUncancelable(io);
        if (shard.inflight[self.slot_index]) |fill| {
            if (fill.generation == self.generation) {
                self.store.allocator.free(fill.key);
                shard.inflight[self.slot_index] = null;
                shard.fill_condition.broadcast(io);
            }
        }
        shard.fill_mutex.unlock(io);
    }
};

pub const FillDecision = union(enum) {
    leader: FillToken,
    hit: Handle,
    bypass,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    config: Config,
    shards: []Shard,
    access_clock: std.atomic.Value(u64) = .init(1),
    entry_count: std.atomic.Value(usize) = .init(0),
    byte_count: std.atomic.Value(usize) = .init(0),
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    inserts: std.atomic.Value(u64) = .init(0),
    evictions: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(u64) = .init(0),
    fill_generation: std.atomic.Value(u64) = .init(1),
    fill_leaders: std.atomic.Value(u64) = .init(0),
    coalesced_waits: std.atomic.Value(u64) = .init(0),
    coalesced_hits: std.atomic.Value(u64) = .init(0),
    fill_bypasses: std.atomic.Value(u64) = .init(0),
    fill_wait_timeouts: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, config: Config) !Store {
        try config.validate();
        const shards = try allocator.alloc(Shard, config.shards);
        var initialized: usize = 0;
        errdefer {
            for (shards[0..initialized]) |shard| {
                allocator.free(shard.entries);
                allocator.free(shard.inflight);
            }
            allocator.free(shards);
        }

        const base = config.capacity / config.shards;
        const remainder = config.capacity % config.shards;
        for (shards, 0..) |*shard, index| {
            shard.* = .{};
            const count = base + @as(usize, if (index < remainder) 1 else 0);
            shard.entries = try allocator.alloc(?*Entry, count);
            @memset(shard.entries, null);
            shard.inflight = allocator.alloc(?Inflight, count) catch |err| {
                allocator.free(shard.entries);
                return err;
            };
            @memset(shard.inflight, null);
            initialized += 1;
        }

        return .{ .allocator = allocator, .config = config, .shards = shards };
    }

    pub fn deinit(self: *Store, io: std.Io) void {
        for (self.shards) |*shard| {
            shard.lock.lockUncancelable(io);
            for (shard.entries) |*slot| self.remove(slot, .shutdown);
            shard.lock.unlock(io);
            shard.fill_mutex.lockUncancelable(io);
            for (shard.inflight) |maybe_fill| {
                if (maybe_fill) |fill| self.allocator.free(fill.key);
            }
            shard.fill_condition.broadcast(io);
            shard.fill_mutex.unlock(io);
            self.allocator.free(shard.entries);
            self.allocator.free(shard.inflight);
        }
        self.allocator.free(self.shards);
        self.shards = &.{};
    }

    pub fn acquire(self: *Store, io: std.Io, key: []const u8, now_ns: i96) ?Handle {
        const shard = &self.shards[self.shardIndex(key)];
        shard.lock.lockSharedUncancelable(io);

        var saw_expired = false;
        for (shard.entries) |slot| {
            const entry = slot orelse continue;
            if (entry.expires_ns <= now_ns) {
                saw_expired = true;
                continue;
            }
            if (!std.mem.eql(u8, entry.key, key)) continue;
            _ = entry.refs.fetchAdd(1, .monotonic);
            const hit_number = self.hits.fetchAdd(1, .monotonic) + 1;
            if ((hit_number & 63) == 0) entry.last_used.store(self.access_clock.fetchAdd(1, .monotonic), .monotonic);
            shard.lock.unlockShared(io);
            return .{ .entry = entry };
        }
        shard.lock.unlockShared(io);
        if (saw_expired) self.removeExpired(shard, io, now_ns);
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    /// Checks for a live entry without changing hit/miss or recency metrics.
    pub fn contains(self: *Store, io: std.Io, key: []const u8, now_ns: i96) bool {
        const shard = &self.shards[self.shardIndex(key)];
        shard.lock.lockSharedUncancelable(io);
        defer shard.lock.unlockShared(io);

        for (shard.entries) |slot| {
            const entry = slot orelse continue;
            if (entry.expires_ns > now_ns and std.mem.eql(u8, entry.key, key)) return true;
        }
        return false;
    }

    pub fn put(
        self: *Store,
        io: std.Io,
        key: []const u8,
        content_type: []const u8,
        body: []const u8,
        cache_policy: response.CachePolicy,
        now_ns: i96,
        policy: Policy,
    ) !void {
        if (policy == .none or body.len > self.config.max_body_bytes or key.len == 0 or key.len > max_key_bytes) return;

        const ttl_ns = @divFloor(policy.ttlNs() * self.config.ttl_percent, 100);
        const entry = try self.createEntry(key, content_type, body, cache_policy, now_ns + ttl_ns);
        errdefer entry.release();

        const shard = &self.shards[self.shardIndex(key)];
        shard.lock.lockUncancelable(io);
        defer shard.lock.unlock(io);

        var target_index: ?usize = null;
        var reason: RemoveReason = .replacement;
        var oldest_index: usize = 0;
        var oldest_use: u64 = std.math.maxInt(u64);
        for (shard.entries, 0..) |*slot, index| {
            const current = slot.* orelse {
                target_index = index;
                reason = .empty;
                break;
            };
            if (current.expires_ns <= now_ns) {
                target_index = index;
                reason = .expired;
                break;
            }
            if (std.mem.eql(u8, current.key, key)) {
                target_index = index;
                reason = .replacement;
                break;
            }
            const last_used = current.last_used.load(.monotonic);
            if (last_used < oldest_use) {
                oldest_use = last_used;
                oldest_index = index;
            }
        }

        const index = target_index orelse oldest_index;
        if (shard.entries[index] != null) self.remove(&shard.entries[index], if (target_index == null) .evicted else reason);
        entry.last_used.store(self.access_clock.fetchAdd(1, .monotonic), .monotonic);
        shard.entries[index] = entry;
        _ = self.entry_count.fetchAdd(1, .monotonic);
        _ = self.byte_count.fetchAdd(entry.sizeBytes(), .monotonic);
        _ = self.inserts.fetchAdd(1, .monotonic);
    }

    pub fn beginFill(self: *Store, io: std.Io, key: []const u8, now_ns: i96) !FillDecision {
        const shard_index = self.shardIndex(key);
        const shard = &self.shards[shard_index];
        while (true) {
            shard.fill_mutex.lockUncancelable(io);
            var matching = false;
            var free_slot: ?usize = null;
            for (shard.inflight, 0..) |maybe_fill, index| {
                if (maybe_fill) |fill| {
                    if (std.mem.eql(u8, fill.key, key)) matching = true;
                } else if (free_slot == null) {
                    free_slot = index;
                }
            }

            if (matching) {
                _ = self.coalesced_waits.fetchAdd(1, .monotonic);
                if (self.config.fill_wait_timeout_ms == 0) {
                    shard.fill_mutex.unlock(io);
                    _ = self.fill_wait_timeouts.fetchAdd(1, .monotonic);
                    return .bypass;
                }
                shard.fill_condition.waitTimeout(
                    io,
                    &shard.fill_mutex,
                    .{ .duration = .{
                        .raw = .fromMilliseconds(self.config.fill_wait_timeout_ms),
                        .clock = .awake,
                    } },
                ) catch |err| switch (err) {
                    error.Timeout => {
                        // waitTimeout reacquires the mutex before returning.
                        shard.fill_mutex.unlock(io);
                        _ = self.fill_wait_timeouts.fetchAdd(1, .monotonic);
                        return .bypass;
                    },
                    error.Canceled => {
                        shard.fill_mutex.unlock(io);
                        return error.Canceled;
                    },
                };
                shard.fill_mutex.unlock(io);
                const refreshed_now_ns = std.Io.Clock.awake.now(io).nanoseconds;
                if (self.acquire(io, key, @max(now_ns, refreshed_now_ns))) |hit| {
                    _ = self.coalesced_hits.fetchAdd(1, .monotonic);
                    return .{ .hit = hit };
                }
                continue;
            }

            const slot_index = free_slot orelse {
                shard.fill_mutex.unlock(io);
                _ = self.fill_bypasses.fetchAdd(1, .monotonic);
                return .bypass;
            };
            const owned_key = self.allocator.dupe(u8, key) catch |err| {
                shard.fill_mutex.unlock(io);
                return err;
            };
            const generation = self.fill_generation.fetchAdd(1, .monotonic);
            shard.inflight[slot_index] = .{ .key = owned_key, .generation = generation };
            shard.fill_mutex.unlock(io);
            _ = self.fill_leaders.fetchAdd(1, .monotonic);
            return .{ .leader = .{
                .store = self,
                .shard_index = shard_index,
                .slot_index = slot_index,
                .generation = generation,
            } };
        }
    }

    pub fn snapshot(self: *const Store) Snapshot {
        return .{
            .entries = self.entry_count.load(.monotonic),
            .bytes = self.byte_count.load(.monotonic),
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .inserts = self.inserts.load(.monotonic),
            .evictions = self.evictions.load(.monotonic),
            .expired = self.expired.load(.monotonic),
            .fill_leaders = self.fill_leaders.load(.monotonic),
            .coalesced_waits = self.coalesced_waits.load(.monotonic),
            .coalesced_hits = self.coalesced_hits.load(.monotonic),
            .fill_bypasses = self.fill_bypasses.load(.monotonic),
            .fill_wait_timeouts = self.fill_wait_timeouts.load(.monotonic),
        };
    }

    pub fn responseHeaderEnabled(self: *const Store) bool {
        return self.config.response_header;
    }

    fn createEntry(
        self: *Store,
        key: []const u8,
        content_type: []const u8,
        body: []const u8,
        cache_policy: response.CachePolicy,
        expires_ns: i96,
    ) !*Entry {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_content_type = try self.allocator.dupe(u8, content_type);
        errdefer self.allocator.free(owned_content_type);
        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);
        const entry = try self.allocator.create(Entry);
        entry.* = .{
            .allocator = self.allocator,
            .key = owned_key,
            .content_type = owned_content_type,
            .body = owned_body,
            .cache_policy = cache_policy,
            .expires_ns = expires_ns,
            .last_used = .init(0),
        };
        return entry;
    }

    fn shardIndex(self: *const Store, key: []const u8) usize {
        return @intCast(std.hash.Wyhash.hash(0, key) % self.shards.len);
    }

    fn remove(self: *Store, slot: *?*Entry, reason: RemoveReason) void {
        const entry = slot.* orelse return;
        slot.* = null;
        _ = self.entry_count.fetchSub(1, .monotonic);
        _ = self.byte_count.fetchSub(entry.sizeBytes(), .monotonic);
        switch (reason) {
            .expired => _ = self.expired.fetchAdd(1, .monotonic),
            .evicted => _ = self.evictions.fetchAdd(1, .monotonic),
            .empty, .replacement, .shutdown => {},
        }
        entry.release();
    }

    fn removeExpired(self: *Store, shard: *Shard, io: std.Io, now_ns: i96) void {
        shard.lock.lockUncancelable(io);
        defer shard.lock.unlock(io);
        for (shard.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.expires_ns <= now_ns) self.remove(slot, .expired);
        }
    }
};

const RemoveReason = enum { empty, replacement, expired, evicted, shutdown };

pub fn requestKey(request: request_mod.Request, buffer: []u8) ?[]const u8 {
    const host = request.header("Host") orelse "";
    return buildKey(host, request.target, buffer);
}

pub fn requestKeyForScope(request: request_mod.Request, scope: Scope, buffer: []u8) ?[]const u8 {
    const host = request.header("Host") orelse "";
    if (scope == .shared) return buildKey(host, request.target, buffer);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (!cookieDigest(request, &digest)) return buildKey(host, request.target, buffer);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return buildPartitionedKey(host, request.target, &encoded, buffer);
}

pub fn buildKey(host: []const u8, target: []const u8, buffer: []u8) ?[]const u8 {
    const required = host.len + 1 + target.len;
    if (required > buffer.len or required > max_key_bytes) return null;
    for (host, 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    buffer[host.len] = '\n';
    @memcpy(buffer[host.len + 1 .. required], target);
    return buffer[0..required];
}

fn buildPartitionedKey(host: []const u8, target: []const u8, partition: []const u8, buffer: []u8) ?[]const u8 {
    const marker = "\ncookie-sha256=";
    const required = host.len + 1 + target.len + marker.len + partition.len;
    if (required > buffer.len or required > max_key_bytes) return null;
    for (host, 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    buffer[host.len] = '\n';
    var cursor = host.len + 1;
    @memcpy(buffer[cursor..][0..target.len], target);
    cursor += target.len;
    @memcpy(buffer[cursor..][0..marker.len], marker);
    cursor += marker.len;
    @memcpy(buffer[cursor..][0..partition.len], partition);
    return buffer[0..required];
}

fn cookieDigest(request: request_mod.Request, digest: *[std.crypto.hash.sha2.Sha256.digest_length]u8) bool {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var found = false;
    var rest = request.headers;
    while (rest.len != 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Cookie")) {
                if (found) hasher.update("\x00");
                hasher.update(std.mem.trim(u8, line[colon + 1 ..], " \t"));
                found = true;
            }
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    if (found) hasher.final(digest);
    return found;
}

test "page cache keys partition cookies unless the route is shared" {
    const plain = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: Example.COM\r\n\r\n");
    const cookie_a = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: example.com\r\nCookie: session=a\r\n\r\n");
    const cookie_a_again = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: EXAMPLE.COM\r\nCookie: session=a\r\n\r\n");
    const cookie_b = try request_mod.Request.parse("GET /about HTTP/1.1\r\nHost: example.com\r\nCookie: session=b\r\n\r\n");

    var plain_buffer: [max_key_bytes]u8 = undefined;
    var cookie_a_buffer: [max_key_bytes]u8 = undefined;
    var cookie_a_again_buffer: [max_key_bytes]u8 = undefined;
    var cookie_b_buffer: [max_key_bytes]u8 = undefined;
    var shared_buffer: [max_key_bytes]u8 = undefined;
    const plain_key = requestKeyForScope(plain, .cookie_partitioned, &plain_buffer).?;
    const cookie_a_key = requestKeyForScope(cookie_a, .cookie_partitioned, &cookie_a_buffer).?;
    const cookie_a_again_key = requestKeyForScope(cookie_a_again, .cookie_partitioned, &cookie_a_again_buffer).?;
    const cookie_b_key = requestKeyForScope(cookie_b, .cookie_partitioned, &cookie_b_buffer).?;
    const shared_key = requestKeyForScope(cookie_b, .shared, &shared_buffer).?;

    try std.testing.expectEqualStrings(cookie_a_key, cookie_a_again_key);
    try std.testing.expect(!std.mem.eql(u8, plain_key, cookie_a_key));
    try std.testing.expect(!std.mem.eql(u8, cookie_a_key, cookie_b_key));
    try std.testing.expectEqualStrings(plain_key, shared_key);
}

test "page cache stores, hits, replaces, and expires entries" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit(std.testing.io);

    try store.put(std.testing.io, "/", "text/html", "first", .api_short, 100, .short);
    const first = store.acquire(std.testing.io, "/", 101).?;
    try std.testing.expectEqualStrings("first", first.body());
    first.deinit();

    try store.put(std.testing.io, "/", "text/html", "second", .api_short, 200, .short);
    const second = store.acquire(std.testing.io, "/", 201).?;
    try std.testing.expectEqualStrings("second", second.body());
    second.deinit();

    try std.testing.expect(store.acquire(std.testing.io, "/", 200 + Policy.short.ttlNs()) == null);
    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.hits);
    try std.testing.expectEqual(@as(u64, 1), snapshot.misses);
    try std.testing.expectEqual(@as(u64, 1), snapshot.expired);
}

test "page cache evicts LRU while acquired entry remains valid" {
    var store = try Store.init(std.testing.allocator, .{ .capacity = 1, .shards = 1 });
    defer store.deinit(std.testing.io);
    try store.put(std.testing.io, "one", "text/plain", "held", .no_cache, 0, .long);
    const held = store.acquire(std.testing.io, "one", 1).?;
    defer held.deinit();

    try store.put(std.testing.io, "two", "text/plain", "next", .no_cache, 2, .long);
    try std.testing.expectEqualStrings("held", held.body());
    try std.testing.expect(store.acquire(std.testing.io, "one", 3) == null);
    const next = store.acquire(std.testing.io, "two", 3).?;
    defer next.deinit();
    try std.testing.expectEqualStrings("next", next.body());
    try std.testing.expectEqual(@as(u64, 1), store.snapshot().evictions);
}

test "page cache enforces runtime body limit and TTL scale" {
    var store = try Store.init(std.testing.allocator, .{
        .capacity = 2,
        .shards = 1,
        .max_body_bytes = 4,
        .ttl_percent = 200,
    });
    defer store.deinit(std.testing.io);

    try store.put(std.testing.io, "large", "text/plain", "12345", .no_cache, 0, .short);
    try std.testing.expect(store.acquire(std.testing.io, "large", 1) == null);
    try store.put(std.testing.io, "scaled", "text/plain", "1234", .no_cache, 0, .short);
    const before_expiry = store.acquire(std.testing.io, "scaled", 9 * std.time.ns_per_s).?;
    before_expiry.deinit();
    try std.testing.expect(store.acquire(std.testing.io, "scaled", 10 * std.time.ns_per_s) == null);
}

test "page cache validates runtime configuration" {
    try std.testing.expectError(error.InvalidPageCacheCapacity, Config.validate(.{ .capacity = 0 }));
    try std.testing.expectError(error.InvalidPageCacheShards, Config.validate(.{ .capacity = 2, .shards = 3 }));
    try std.testing.expectError(error.InvalidPageCacheBodyLimit, Config.validate(.{ .max_body_bytes = 0 }));
    try std.testing.expectError(error.InvalidPageCacheTtlPercent, Config.validate(.{ .ttl_percent = 0 }));
    try std.testing.expectError(error.InvalidPageCacheFillWaitTimeout, Config.validate(.{ .fill_wait_timeout_ms = 30_001 }));
}

test "page cache coalesces concurrent fills for the same key" {
    var store = try Store.init(std.heap.page_allocator, .{
        .capacity = 4,
        .shards = 1,
        .fill_wait_timeout_ms = 5_000,
    });
    defer store.deinit(std.testing.io);
    var leader = switch (try store.beginFill(std.testing.io, "same", 0)) {
        .leader => |token| token,
        else => return error.ExpectedFillLeader,
    };

    const Completer = struct {
        fn run(cache: *Store, token: *FillToken) !void {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            const now_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
            try cache.put(std.testing.io, "same", "text/plain", "rendered", .no_cache, now_ns, .standard);
            token.complete(std.testing.io);
        }
    };
    var completer = std.testing.io.async(Completer.run, .{ &store, &leader });
    defer completer.cancel(std.testing.io) catch {};
    const decision = try store.beginFill(std.testing.io, "same", std.Io.Clock.awake.now(std.testing.io).nanoseconds);
    const hit = switch (decision) {
        .hit => |value| value,
        else => return error.ExpectedCoalescedHit,
    };
    defer hit.deinit();
    try completer.await(std.testing.io);
    try std.testing.expectEqualStrings("rendered", hit.body());
    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.fill_leaders);
    try std.testing.expectEqual(@as(u64, 1), snapshot.coalesced_waits);
    try std.testing.expectEqual(@as(u64, 1), snapshot.coalesced_hits);
}

test "page cache releases a failed fill so the next request can lead" {
    var store = try Store.init(std.testing.allocator, .{ .capacity = 2, .shards = 1 });
    defer store.deinit(std.testing.io);

    var failed = switch (try store.beginFill(std.testing.io, "same", 0)) {
        .leader => |token| token,
        else => return error.ExpectedFillLeader,
    };
    failed.complete(std.testing.io);

    var retry = switch (try store.beginFill(std.testing.io, "same", 1)) {
        .leader => |token| token,
        else => return error.ExpectedRetryLeader,
    };
    retry.complete(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), store.snapshot().fill_leaders);
}

test "page cache bypasses when a shard fill coordinator is full" {
    var store = try Store.init(std.testing.allocator, .{ .capacity = 1, .shards = 1 });
    defer store.deinit(std.testing.io);

    var leader = switch (try store.beginFill(std.testing.io, "first", 0)) {
        .leader => |token| token,
        else => return error.ExpectedFillLeader,
    };
    defer leader.complete(std.testing.io);

    switch (try store.beginFill(std.testing.io, "second", 0)) {
        .bypass => {},
        else => return error.ExpectedFillBypass,
    }
    try std.testing.expectEqual(@as(u64, 1), store.snapshot().fill_bypasses);
}

test "page cache fill wait is bounded" {
    var store = try Store.init(std.testing.allocator, .{
        .capacity = 2,
        .shards = 1,
        .fill_wait_timeout_ms = 1,
    });
    defer store.deinit(std.testing.io);

    var leader = switch (try store.beginFill(std.testing.io, "slow", 0)) {
        .leader => |token| token,
        else => return error.ExpectedFillLeader,
    };
    defer leader.complete(std.testing.io);

    switch (try store.beginFill(std.testing.io, "slow", 0)) {
        .bypass => {},
        else => return error.ExpectedTimedOutBypass,
    }
    try std.testing.expectEqual(@as(u64, 1), store.snapshot().fill_wait_timeouts);
}

test "page cache fill wait propagates cancellation" {
    var store = try Store.init(std.testing.allocator, .{
        .capacity = 2,
        .shards = 1,
        .fill_wait_timeout_ms = 5_000,
    });
    defer store.deinit(std.testing.io);
    var leader = switch (try store.beginFill(std.testing.io, "cancel", 0)) {
        .leader => |token| token,
        else => return error.ExpectedFillLeader,
    };
    defer leader.complete(std.testing.io);

    const Waiter = struct {
        fn run(cache: *Store) !FillDecision {
            return cache.beginFill(std.testing.io, "cancel", 0);
        }
    };
    var waiter = std.testing.io.async(Waiter.run, .{&store});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    try std.testing.expectError(error.Canceled, waiter.cancel(std.testing.io));
}

test "request cache key separates hosts and preserves query" {
    const request = try request_mod.Request.parse("GET /about?v=1 HTTP/1.1\r\nHost: Example.COM\r\n\r\n");
    var buffer: [max_key_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("example.com\n/about?v=1", requestKey(request, &buffer).?);
}
