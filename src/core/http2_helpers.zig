const std = @import("std");

pub const H2Header = extern struct {
    name_ptr: ?[*]const u8,
    name_len: usize,
    value_ptr: ?[*]const u8,
    value_len: usize,
};

pub const AppendBodyResult = enum(c_int) {
    success = 0,
    body_too_large = 1,
    out_of_memory = -1,
};

/// Allocates a byte-for-byte copy with the C allocator so ownership can cross
/// the nghttp2 C ABI. Empty values are represented by a null pointer.
pub export fn ziserver_h2_copy_zig(value_ptr: [*]const u8, len: usize) ?[*]u8 {
    if (len == 0) return null;
    const copy = std.heap.c_allocator.alloc(u8, len) catch return null;
    @memcpy(copy, value_ptr[0..len]);
    return copy.ptr;
}

/// Frees memory returned by the helpers in this module. The length is retained
/// in the ABI even though the C allocator itself does not require it.
pub export fn ziserver_h2_free_zig(value_ptr: ?[*]u8, len: usize) void {
    const ptr = value_ptr orelse return;
    std.heap.c_allocator.free(ptr[0..len]);
}

/// Replaces an owned field atomically from the C caller's perspective: the new
/// copy is allocated before the previous value is released.
pub export fn ziserver_h2_replace_zig(
    destination_ptr: *?[*]u8,
    destination_len: *usize,
    value_ptr: [*]const u8,
    len: usize,
) c_int {
    const copy = ziserver_h2_copy_zig(value_ptr, len);
    if (len != 0 and copy == null) return -1;
    ziserver_h2_free_zig(destination_ptr.*, destination_len.*);
    destination_ptr.* = copy;
    destination_len.* = len;
    return 0;
}

/// Appends a DATA chunk while enforcing the route body limit. Capacity growth,
/// overflow checks and reset-on-limit all live on the Zig side.
pub export fn ziserver_h2_append_body_zig(
    body_ptr: *?[*]u8,
    body_len: *usize,
    body_capacity: *usize,
    data_ptr: [*]const u8,
    data_len: usize,
    max_body_bytes: usize,
) c_int {
    if (data_len > max_body_bytes or body_len.* > max_body_bytes - data_len) {
        ziserver_h2_free_zig(body_ptr.*, body_capacity.*);
        body_ptr.* = null;
        body_len.* = 0;
        body_capacity.* = 0;
        return @intFromEnum(AppendBodyResult.body_too_large);
    }
    if (data_len == 0) return @intFromEnum(AppendBodyResult.success);

    const required = body_len.* + data_len;
    if (required > body_capacity.*) {
        var next_capacity: usize = if (body_capacity.* == 0) @min(@as(usize, 4096), max_body_bytes) else body_capacity.*;
        while (next_capacity < required) {
            next_capacity = @min(max_body_bytes, std.math.mul(usize, next_capacity, 2) catch max_body_bytes);
            if (next_capacity < required and next_capacity == max_body_bytes) {
                return @intFromEnum(AppendBodyResult.body_too_large);
            }
        }

        const resized = if (body_ptr.*) |ptr|
            std.heap.c_allocator.realloc(ptr[0..body_capacity.*], next_capacity) catch return @intFromEnum(AppendBodyResult.out_of_memory)
        else
            std.heap.c_allocator.alloc(u8, next_capacity) catch return @intFromEnum(AppendBodyResult.out_of_memory);
        body_ptr.* = resized.ptr;
        body_capacity.* = resized.len;
    }

    const body = body_ptr.* orelse return @intFromEnum(AppendBodyResult.out_of_memory);
    @memcpy(body[body_len.*..][0..data_len], data_ptr[0..data_len]);
    body_len.* += data_len;
    return @intFromEnum(AppendBodyResult.success);
}

/// Releases all allocations owned by an HTTP/2 stream. The stream node itself
/// remains C-owned because nghttp2 stores its address as stream user data.
pub export fn ziserver_h2_stream_fields_free_zig(
    method: ?[*]u8,
    method_len: usize,
    path: ?[*]u8,
    path_len: usize,
    authority: ?[*]u8,
    authority_len: usize,
    headers_ptr: [*]const H2Header,
    headers_len: usize,
    body: ?[*]u8,
    body_capacity: usize,
    response_body: ?[*]u8,
    response_body_len: usize,
) void {
    ziserver_h2_free_zig(method, method_len);
    ziserver_h2_free_zig(path, path_len);
    ziserver_h2_free_zig(authority, authority_len);
    for (headers_ptr[0..headers_len]) |header| {
        ziserver_h2_free_zig(if (header.name_ptr) |ptr| @constCast(ptr) else null, header.name_len);
        ziserver_h2_free_zig(if (header.value_ptr) |ptr| @constCast(ptr) else null, header.value_len);
    }
    ziserver_h2_free_zig(body, body_capacity);
    ziserver_h2_free_zig(response_body, response_body_len);
}

test "HTTP/2 body helper grows and preserves data" {
    var body: ?[*]u8 = null;
    var len: usize = 0;
    var capacity: usize = 0;
    defer ziserver_h2_free_zig(body, capacity);

    try std.testing.expectEqual(
        @intFromEnum(AppendBodyResult.success),
        ziserver_h2_append_body_zig(&body, &len, &capacity, "abc", 3, 8192),
    );
    try std.testing.expectEqual(
        @intFromEnum(AppendBodyResult.success),
        ziserver_h2_append_body_zig(&body, &len, &capacity, "def", 3, 8192),
    );
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqualSlices(u8, "abcdef", body.?[0..len]);
}

test "HTTP/2 body helper resets allocation on limit" {
    var body: ?[*]u8 = null;
    var len: usize = 0;
    var capacity: usize = 0;
    try std.testing.expectEqual(
        @intFromEnum(AppendBodyResult.success),
        ziserver_h2_append_body_zig(&body, &len, &capacity, "abc", 3, 4),
    );
    try std.testing.expectEqual(
        @intFromEnum(AppendBodyResult.body_too_large),
        ziserver_h2_append_body_zig(&body, &len, &capacity, "de", 2, 4),
    );
    try std.testing.expect(body == null);
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expectEqual(@as(usize, 0), capacity);
}
