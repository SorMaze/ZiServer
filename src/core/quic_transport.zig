const std = @import("std");

pub const net = std.Io.net;

pub const Socket = struct {
    io: std.Io,
    inner: net.Socket,
    recv_buf: [65536]u8 = undefined,
    last_peer: net.IpAddress = undefined,

    pub fn init(io: std.Io, address: net.IpAddress) !Socket {
        const inner = try address.bind(io, .{ .mode = .dgram });
        return .{ .io = io, .inner = inner };
    }

    pub fn deinit(self: *Socket) void {
        self.inner.close(self.io);
        self.* = undefined;
    }

    pub fn recvFrom(self: *Socket) !struct { len: usize, from: net.IpAddress } {
        const msg = self.inner.receive(self.io, self.recv_buf[0..]) catch |err| {
            return err;
        };
        self.last_peer = msg.from;
        return .{ .len = msg.data.len, .from = msg.from };
    }

    pub fn sendTo(self: *Socket, data: []const u8, dest: net.IpAddress) !void {
        try self.inner.send(self.io, &dest, data);
    }
};
