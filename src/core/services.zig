const std = @import("std");

pub const Entry = struct {
    key: *const anyopaque,
    value: *anyopaque,
};

/// Immutable application service registry. Values are owned by application
/// startup code and must outlive all requests using the registry.
pub const Registry = struct {
    entries: []const Entry = &.{},

    pub fn get(self: Registry, key: *const anyopaque, comptime T: type) ?*T {
        for (self.entries) |entry| {
            if (entry.key == key) return @ptrCast(@alignCast(entry.value));
        }
        return null;
    }
};

test "application services resolve opaque typed values" {
    var key: u8 = 0;
    var value: u32 = 42;
    const entries = [_]Entry{.{ .key = &key, .value = &value }};
    const registry = Registry{ .entries = &entries };
    try std.testing.expectEqual(@as(u32, 42), registry.get(&key, u32).?.*);
}
