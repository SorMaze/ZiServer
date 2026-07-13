const std = @import("std");

pub const max_slots = 4;
pub const max_value_bytes = 4 * @sizeOf(usize);

const Slot = struct {
    key: ?*const anyopaque = null,
    value_len: u8 = 0,
    value: [max_value_bytes]u8 = @splat(0),
};

/// Small, allocation-free per-request storage for compose middleware.
/// Keys are module-owned token addresses, so core never needs to know the
/// semantic type of a middleware result.
pub const Store = struct {
    slots: [max_slots]Slot = @splat(.{}),

    pub fn put(self: *Store, key: *const anyopaque, value: anytype) !void {
        const T = @TypeOf(value);
        comptime {
            if (@sizeOf(T) == 0 or @sizeOf(T) > max_value_bytes) {
                @compileError("request local value must occupy 1..max_value_bytes bytes");
            }
        }
        var target: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot.key == key) {
                target = slot;
                break;
            }
            if (target == null and slot.key == null) target = slot;
        }
        const slot = target orelse return error.RequestLocalsFull;
        var copy = value;
        const bytes = std.mem.asBytes(&copy);
        @memcpy(slot.value[0..bytes.len], bytes);
        if (bytes.len < slot.value.len) @memset(slot.value[bytes.len..], 0);
        slot.value_len = @intCast(bytes.len);
        slot.key = key;
    }

    pub fn get(self: *const Store, key: *const anyopaque, comptime T: type) ?T {
        comptime {
            if (@sizeOf(T) == 0 or @sizeOf(T) > max_value_bytes) {
                @compileError("request local value must occupy 1..max_value_bytes bytes");
            }
        }
        for (&self.slots) |*slot| {
            if (slot.key != key) continue;
            if (slot.value_len != @sizeOf(T)) return null;
            var result: T = undefined;
            @memcpy(std.mem.asBytes(&result), slot.value[0..@sizeOf(T)]);
            return result;
        }
        return null;
    }
};

test "request locals store typed values by opaque module key" {
    var first_key: u8 = 0;
    var second_key: u8 = 0;
    var store = Store{};
    const Value = struct { files: usize, bytes: usize };
    try store.put(&first_key, Value{ .files = 2, .bytes = 4096 });
    try store.put(&second_key, @as(u32, 7));
    try std.testing.expectEqual(@as(usize, 2), store.get(&first_key, Value).?.files);
    try std.testing.expectEqual(@as(usize, 4096), store.get(&first_key, Value).?.bytes);
    try std.testing.expectEqual(@as(u32, 7), store.get(&second_key, u32).?);
    try std.testing.expectEqual(@as(?u64, null), store.get(&second_key, u64));
}
