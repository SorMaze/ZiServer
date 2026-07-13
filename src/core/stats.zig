const std = @import("std");

pub const Snapshot = struct {
    enabled: bool,
    active: usize,
    queued: usize,
    identity_peer: u64,
    identity_forwarded: u64,
    identity_header_missing: u64,
    identity_ignored_untrusted: u64,
    identity_invalid: u64,
};

pub const Stats = struct {
    enabled: bool = true,
    active_requests: std.atomic.Value(usize) = .init(0),
    queued_connections: std.atomic.Value(usize) = .init(0),
    identity_peer: std.atomic.Value(u64) = .init(0),
    identity_forwarded: std.atomic.Value(u64) = .init(0),
    identity_header_missing: std.atomic.Value(u64) = .init(0),
    identity_ignored_untrusted: std.atomic.Value(u64) = .init(0),
    identity_invalid: std.atomic.Value(u64) = .init(0),

    pub fn init(enabled: bool) Stats {
        return .{ .enabled = enabled };
    }

    pub fn requestStarted(self: *Stats) void {
        if (!self.enabled) return;
        _ = self.active_requests.fetchAdd(1, .monotonic);
    }

    pub fn requestFinished(self: *Stats) void {
        if (!self.enabled) return;
        _ = self.active_requests.fetchSub(1, .monotonic);
    }

    pub fn connectionQueued(self: *Stats) void {
        if (!self.enabled) return;
        _ = self.queued_connections.fetchAdd(1, .monotonic);
    }

    pub fn connectionDequeued(self: *Stats) void {
        if (!self.enabled) return;
        _ = self.queued_connections.fetchSub(1, .monotonic);
    }

    pub fn identityResolved(self: *Stats, resolution: @import("client_identity.zig").Resolution) void {
        if (!self.enabled) return;
        const counter = switch (resolution) {
            .peer => &self.identity_peer,
            .forwarded => &self.identity_forwarded,
            .header_missing => &self.identity_header_missing,
            .ignored_untrusted_peer => &self.identity_ignored_untrusted,
            .invalid_header => &self.identity_invalid,
        };
        _ = counter.fetchAdd(1, .monotonic);
    }

    pub fn snapshot(self: *Stats) Snapshot {
        if (!self.enabled) {
            return .{
                .enabled = false,
                .active = 0,
                .queued = 0,
                .identity_peer = 0,
                .identity_forwarded = 0,
                .identity_header_missing = 0,
                .identity_ignored_untrusted = 0,
                .identity_invalid = 0,
            };
        }

        return .{
            .enabled = true,
            .active = self.active_requests.load(.monotonic),
            .queued = self.queued_connections.load(.monotonic),
            .identity_peer = self.identity_peer.load(.monotonic),
            .identity_forwarded = self.identity_forwarded.load(.monotonic),
            .identity_header_missing = self.identity_header_missing.load(.monotonic),
            .identity_ignored_untrusted = self.identity_ignored_untrusted.load(.monotonic),
            .identity_invalid = self.identity_invalid.load(.monotonic),
        };
    }
};
