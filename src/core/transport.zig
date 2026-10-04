const std = @import("std");

const tls = @import("tls.zig");
const logger = @import("log.zig");
const socket_read = @import("socket_read.zig");

pub const net = std.Io.net;

pub const Stream = net.Stream;

pub const Mode = enum {
    plain,
    tls,

    pub fn text(self: Mode) []const u8 {
        return switch (self) {
            .plain => "plain",
            .tls => "tls",
        };
    }
};

pub const Connection = struct {
    io: std.Io,
    stream: Stream,
    mode: Mode = .plain,
    tls_connection: ?tls.Connection = null,
    timeout_mutex: std.Io.Mutex = .init,
    read_deadline_ns: i96 = 0,

    pub fn init(io: std.Io, stream: Stream) Connection {
        return .{ .io = io, .stream = stream };
    }

    pub fn initTls(io: std.Io, stream: Stream, server_context: *const tls.ServerContext) !Connection {
        var connection = init(io, stream);
        try connection.enableTls(server_context);
        return connection;
    }

    pub fn enableTls(self: *Connection, server_context: *const tls.ServerContext) !void {
        const read_deadline_ns = self.readDeadlineNs();
        const tls_connection = tls.initConnection(
            server_context,
            self.io,
            socketHandleValue(self.stream),
            @intCast(read_deadline_ns),
        ) catch |err| {
            if (server_context.provider == .openssl) {
                logger.message(
                    self.io,
                    .warn,
                    "tls_handshake_failed",
                    "provider=openssl ssl_error={?d} openssl_error={?d} io_error={?d} socket_handle={d}",
                    .{
                        tls.opensslLastSslError(),
                        tls.opensslLastError(),
                        tls.opensslLastIoError(),
                        socketHandleValue(self.stream),
                    },
                );
                if (tls.opensslLastErrorText()) |text| {
                    if (text.len != 0) logger.message(self.io, .warn, "openssl_error", "detail={s}", .{text});
                }
            }
            return err;
        };
        self.mode = .tls;
        self.tls_connection = tls_connection;
    }

    pub fn enableTlsClient(
        self: *Connection,
        allocator: std.mem.Allocator,
        client_context: *const tls.ClientContext,
        server_name: []const u8,
        advertise_h2: bool,
    ) !void {
        const tls_connection = try tls.initClientConnection(
            allocator,
            client_context,
            self.io,
            socketHandleValue(self.stream),
            @intCast(self.readDeadlineNs()),
            server_name,
            advertise_h2,
        );
        self.mode = .tls;
        self.tls_connection = tls_connection;
    }

    pub fn negotiatedProtocol(self: *const Connection) tls.NegotiatedProtocol {
        const tls_connection = &(self.tls_connection orelse return .none);
        return tls.negotiatedProtocol(tls_connection);
    }

    pub fn tlsVersionText(self: *const Connection) ?[:0]const u8 {
        const tls_connection = &(self.tls_connection orelse return null);
        return tls.protocolVersionText(tls_connection);
    }

    pub fn tlsCipherText(self: *const Connection) ?[:0]const u8 {
        const tls_connection = &(self.tls_connection orelse return null);
        return tls.cipherText(tls_connection);
    }

    pub fn tlsSessionReused(self: *const Connection) bool {
        const tls_connection = &(self.tls_connection orelse return false);
        return tls.sessionReused(tls_connection);
    }

    pub fn close(self: *Connection) void {
        if (self.tls_connection) |*tls_connection| {
            tls_connection.deinit();
            self.tls_connection = null;
        }
        self.stream.close(self.io);
    }

    pub fn shutdown(self: *Connection) void {
        self.stream.shutdown(self.io, .both) catch {};
    }

    pub fn setReadTimeoutMs(self: *Connection, timeout_ms: u32) void {
        self.timeout_mutex.lockUncancelable(self.io);
        defer self.timeout_mutex.unlock(self.io);
        self.read_deadline_ns = if (timeout_ms == 0)
            0
        else
            std.Io.Clock.awake.now(self.io).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
        if (self.tls_connection) |*tls_connection| {
            tls.setReadDeadline(tls_connection, @intCast(self.read_deadline_ns));
        }
    }

    pub fn writer(self: *Connection, buffer: []u8) Writer {
        return Writer.init(self, buffer);
    }

    pub fn read(self: *Connection, buffers: [][]u8) !usize {
        if (self.tls_connection) |*tls_connection| {
            if (buffers.len == 0) return 0;
            const bytes_read = tls.read(tls_connection, buffers[0]) catch |err| {
                const error_name = @errorName(err);
                if (!std.mem.eql(u8, error_name, "ReadTimeout") and
                    !std.mem.eql(u8, error_name, "GracefulShutdown"))
                {
                    logTlsOperationError(self.io, "read");
                }
                return err;
            };
            return bytes_read;
        }
        for (buffers) |buffer| {
            if (buffer.len != 0) {
                return socket_read.read(self.io, self.stream.socket.handle, buffer, self.readDeadlineNs());
            }
        }
        return 0;
    }

    pub fn peek(self: *Connection, buffer: []u8) !usize {
        if (self.tls_connection != null) return error.PeekAfterTlsHandshake;
        return socket_read.peek(self.io, self.stream.socket.handle, buffer, self.readDeadlineNs());
    }

    pub fn waitReadable(self: *Connection, timeout_ms: u32) !bool {
        if (self.tls_connection) |*tls_connection| {
            if (tls.hasPendingRead(tls_connection)) return true;
        }
        return socket_read.waitReadable(self.stream.socket.handle, timeout_ms);
    }

    fn write(self: *Connection, buffer: []const u8) !usize {
        if (buffer.len == 0) return 0;
        if (self.tls_connection) |*tls_connection| {
            return tls.write(tls_connection, buffer) catch |err| {
                logTlsOperationError(self.io, "write");
                return err;
            };
        }
        const handle = self.stream.socket.handle;
        const result = self.io.operate(.{ .net_write = .{
            .socket_handle = handle,
            .header = &.{},
            .data = &.{buffer},
            .splat = 1,
        } }) catch return error.WriteFailed;
        return result.net_write catch error.WriteFailed;
    }

    pub fn writeAll(self: *Connection, buffer: []const u8) !void {
        var cursor: usize = 0;
        while (cursor < buffer.len) {
            const n = try self.write(buffer[cursor..]);
            if (n == 0) return error.WriteFailed;
            cursor += n;
        }
    }

    fn readDeadlineNs(self: *Connection) i96 {
        self.timeout_mutex.lockUncancelable(self.io);
        defer self.timeout_mutex.unlock(self.io);
        return self.read_deadline_ns;
    }
};

pub const ConnectionRegistry = struct {
    io: std.Io,
    slots: []?*Connection,
    mutex: std.Io.Mutex = .init,
    active: std.atomic.Value(usize) = .init(0),

    pub fn init(io: std.Io, slots: []?*Connection) ConnectionRegistry {
        @memset(slots, null);
        return .{ .io = io, .slots = slots };
    }

    pub fn register(self: *ConnectionRegistry, worker_index: usize, connection: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.slots[worker_index] == null);
        self.slots[worker_index] = connection;
        _ = self.active.fetchAdd(1, .release);
    }

    pub fn unregister(self: *ConnectionRegistry, worker_index: usize, connection: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.slots[worker_index] == connection);
        self.slots[worker_index] = null;
        _ = self.active.fetchSub(1, .release);
    }

    pub fn activeCount(self: *const ConnectionRegistry) usize {
        return self.active.load(.acquire);
    }

    pub fn shutdownAll(self: *ConnectionRegistry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.slots) |maybe_connection| {
            if (maybe_connection) |connection| connection.shutdown();
        }
    }
};

fn logTlsOperationError(io: std.Io, operation: []const u8) void {
    const detail = tls.opensslLastErrorText() orelse "-";
    logger.message(
        io,
        .warn,
        "tls_io_failed",
        "operation={s} ssl_error={?d} openssl_error={?d} io_error={?d} openssl_text=\"{s}\"",
        .{ operation, tls.opensslLastSslError(), tls.opensslLastError(), tls.opensslLastIoError(), detail },
    );
}

pub const Writer = struct {
    interface: std.Io.Writer,
    connection: *Connection,
    err: ?anyerror = null,

    pub fn init(connection: *Connection, buffer: []u8) Writer {
        return .{
            .connection = connection,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = buffer,
            },
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered_len = io_w.end;

        writer.connection.writeAll(io_w.buffered()) catch |err| {
            writer.err = err;
            return error.WriteFailed;
        };

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |item| {
            writer.connection.writeAll(item) catch |err| {
                writer.err = err;
                return error.WriteFailed;
            };
            consumed += item.len;
        }

        const last = data[data.len - 1];
        var repeated: usize = 0;
        while (repeated < splat) : (repeated += 1) {
            writer.connection.writeAll(last) catch |err| {
                writer.err = err;
                return error.WriteFailed;
            };
            consumed += last.len;
        }

        return io_w.consume(buffered_len + consumed);
    }
};

pub fn closeStream(io: std.Io, stream: Stream) void {
    stream.close(io);
}

fn socketHandleValue(stream: Stream) usize {
    const handle = stream.socket.handle;
    return switch (@typeInfo(@TypeOf(handle))) {
        .pointer => @intFromPtr(handle),
        .int => @intCast(handle),
        .comptime_int => @intCast(handle),
        else => @compileError("unsupported socket handle type"),
    };
}
