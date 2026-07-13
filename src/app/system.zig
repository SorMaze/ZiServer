const std = @import("std");

const z = @import("../ziserver.zig");

const Context = z.Context;

const health_body = "{\"status\":\"ok\"}\n";

pub fn health(ctx: *Context) !void {
    try ctx.json(.ok, health_body);
}

pub fn stats(ctx: *Context) !void {
    const snapshot = ctx.runtimeSnapshot();
    var body_buffer: [1024]u8 = undefined;
    const body = try formatStats(&body_buffer, snapshot);

    try ctx.json(.ok, body);
}

fn formatStats(body_buffer: []u8, snapshot: z.RuntimeSnapshot) ![]const u8 {
    const active = snapshot.server.active -| 1;
    const cache_snapshot = snapshot.page_cache;
    const limiter_snapshot = snapshot.rate_limit;
    const body = try std.fmt.bufPrint(
        body_buffer,
        "{{\"stats\":{s},\"active\":{d},\"queued\":{d},\"client_identity\":{{\"peer\":{d},\"forwarded\":{d},\"header_missing\":{d},\"ignored_untrusted\":{d},\"invalid\":{d}}},\"rate_limit\":{{\"enabled\":{s},\"entries\":{d},\"allowed_relaxed\":{d},\"allowed_strict\":{d},\"rejected_relaxed\":{d},\"rejected_strict\":{d},\"expired\":{d},\"capacity_rejections\":{d}}},\"page_cache\":{{\"enabled\":{s},\"entries\":{d},\"bytes\":{d},\"hits\":{d},\"misses\":{d},\"inserts\":{d},\"evictions\":{d},\"expired\":{d},\"fill_leaders\":{d},\"coalesced_waits\":{d},\"coalesced_hits\":{d},\"fill_bypasses\":{d},\"fill_wait_timeouts\":{d}}}}}\n",
        .{
            if (snapshot.server.enabled) "true" else "false",
            active,
            snapshot.server.queued,
            snapshot.server.identity_peer,
            snapshot.server.identity_forwarded,
            snapshot.server.identity_header_missing,
            snapshot.server.identity_ignored_untrusted,
            snapshot.server.identity_invalid,
            if (limiter_snapshot != null) "true" else "false",
            if (limiter_snapshot) |value| value.entries else 0,
            if (limiter_snapshot) |value| value.allowed_relaxed else 0,
            if (limiter_snapshot) |value| value.allowed_strict else 0,
            if (limiter_snapshot) |value| value.rejected_relaxed else 0,
            if (limiter_snapshot) |value| value.rejected_strict else 0,
            if (limiter_snapshot) |value| value.expired else 0,
            if (limiter_snapshot) |value| value.capacity_rejections else 0,
            if (cache_snapshot != null) "true" else "false",
            if (cache_snapshot) |value| value.entries else 0,
            if (cache_snapshot) |value| value.bytes else 0,
            if (cache_snapshot) |value| value.hits else 0,
            if (cache_snapshot) |value| value.misses else 0,
            if (cache_snapshot) |value| value.inserts else 0,
            if (cache_snapshot) |value| value.evictions else 0,
            if (cache_snapshot) |value| value.expired else 0,
            if (cache_snapshot) |value| value.fill_leaders else 0,
            if (cache_snapshot) |value| value.coalesced_waits else 0,
            if (cache_snapshot) |value| value.coalesced_hits else 0,
            if (cache_snapshot) |value| value.fill_bypasses else 0,
            if (cache_snapshot) |value| value.fill_wait_timeouts else 0,
        },
    );

    return body;
}

test "stats exposes page cache metrics" {
    var buffer: [1024]u8 = undefined;
    const body = try formatStats(&buffer, .{
        .server = .{
            .enabled = true,
            .active = 1,
            .queued = 2,
            .identity_peer = 1,
            .identity_forwarded = 2,
            .identity_header_missing = 3,
            .identity_ignored_untrusted = 4,
            .identity_invalid = 5,
        },
        .page_cache = .{
            .entries = 1,
            .bytes = 4,
            .hits = 1,
            .misses = 0,
            .inserts = 1,
            .evictions = 0,
            .expired = 0,
            .fill_leaders = 1,
            .coalesced_waits = 0,
            .coalesced_hits = 0,
            .fill_bypasses = 0,
            .fill_wait_timeouts = 0,
        },
        .rate_limit = .{
            .entries = 2,
            .allowed_relaxed = 3,
            .allowed_strict = 4,
            .rejected_relaxed = 5,
            .rejected_strict = 6,
            .expired = 7,
            .capacity_rejections = 8,
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"page_cache\":{\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"queued\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"hits\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"inserts\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"coalesced_hits\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"forwarded\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"capacity_rejections\":8") != null);
}
