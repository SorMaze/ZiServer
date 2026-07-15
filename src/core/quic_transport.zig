const std = @import("std");
const socket_read = @import("socket_read.zig");

pub const net = std.Io.net;

pub const Datagram = struct {
    len: usize,
    from: net.IpAddress,
};

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

    pub fn recvFrom(self: *Socket) !Datagram {
        const msg = self.inner.receive(self.io, self.recv_buf[0..]) catch |err| {
            return err;
        };
        self.last_peer = msg.from;
        return .{ .len = msg.data.len, .from = msg.from };
    }

    pub fn recvFromTimeout(self: *Socket, timeout_ms: u32) !?Datagram {
        if (!try socket_read.waitReadable(self.inner.handle, @max(timeout_ms, 1))) return null;
        return try self.recvFrom();
    }

    pub fn sendTo(self: *Socket, data: []const u8, dest: net.IpAddress) !void {
        try self.inner.send(self.io, &dest, data);
    }
};
