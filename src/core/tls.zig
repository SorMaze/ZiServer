const std = @import("std");
const build_options = @import("build_options");

const http_config = @import("http_config.zig");
const openssl_backend = @import("tls_backend/openssl.zig");
const schannel_backend = @import("tls_backend/schannel.zig");

pub const Provider = enum {
    none,
    openssl,
    schannel,

    pub fn supportsTerminate(self: Provider) bool {
        return switch (self) {
            .none => false,
            .openssl => openssl_backend.supportsTerminate(),
            .schannel => schannel_backend.supportsTerminate(),
        };
    }

    pub fn text(self: Provider) []const u8 {
        return switch (self) {
            .none => "none",
            .openssl => "openssl",
            .schannel => "schannel",
        };
    }
};

pub const Config = struct {
    provider: Provider = .none,
    tls: http_config.TlsConfig = .{},
    advertise_h2: bool = false,
};

pub const NegotiatedProtocol = enum {
    none,
    http1_1,
    h2,
    unknown,
};

pub const ServerContext = struct {
    provider: Provider,
    handle: ?*anyopaque = null,

    pub fn deinit(self: *ServerContext) void {
        switch (self.provider) {
            .openssl => openssl_backend.freeServerHandle(self.handle),
            .schannel => schannel_backend.freeServerHandle(self.handle),
            .none,
            => {},
        }
        self.* = undefined;
    }
};

pub const ClientContext = struct {
    provider: Provider,
    handle: ?*anyopaque = null,

    pub fn deinit(self: *ClientContext) void {
        switch (self.provider) {
            .openssl => openssl_backend.freeClientHandle(self.handle),
            .schannel, .none => {},
        }
        self.* = undefined;
    }
};

pub const Connection = struct {
    provider: Provider,
    handle: ?*anyopaque = null,

    pub fn deinit(self: *Connection) void {
        switch (self.provider) {
            .openssl => openssl_backend.freeConnectionHandle(self.handle),
            .schannel => schannel_backend.freeConnectionHandle(self.handle),
            .none => {},
        }
        self.* = undefined;
    }
};

pub fn linkedProvider(provider: Provider) bool {
    const selected = providerFromName(build_options.tls_provider) catch .none;
    return switch (provider) {
        .none => true,
        .openssl => selected == provider and openssl_backend.linked,
        .schannel => selected == provider and schannel_backend.linked,
    };
}

pub fn initConnection(
    server_context: *const ServerContext,
    io: std.Io,
    socket_handle: usize,
    read_deadline_ns: i64,
) !Connection {
    const server_handle = server_context.handle orelse return error.TlsProviderUnavailable;
    switch (server_context.provider) {
        .openssl => return .{
            .provider = .openssl,
            .handle = try openssl_backend.initConnectionHandle(server_handle, io, socket_handle, read_deadline_ns),
        },
        .schannel => return .{
            .provider = .schannel,
            .handle = try schannel_backend.initConnectionHandle(server_handle, socket_handle),
        },
        .none => return error.TlsProviderUnavailable,
    }
}

pub fn initClientConnection(
    allocator: std.mem.Allocator,
    client_context: *const ClientContext,
    io: std.Io,
    socket_handle: usize,
    read_deadline_ns: i64,
    server_name: []const u8,
    advertise_h2: bool,
) !Connection {
    const client_handle = client_context.handle orelse return error.TlsProviderUnavailable;
    return switch (client_context.provider) {
        .openssl => .{
            .provider = .openssl,
            .handle = try openssl_backend.initClientConnectionHandle(
                allocator,
                client_handle,
                io,
                socket_handle,
                read_deadline_ns,
                server_name,
                advertise_h2,
            ),
        },
        .schannel, .none => error.TlsProviderUnavailable,
    };
}

pub fn setReadDeadline(connection: *Connection, deadline_ns: i64) void {
    const handle = connection.handle orelse return;
    switch (connection.provider) {
        .openssl => openssl_backend.setReadDeadline(handle, deadline_ns),
        .schannel, .none => {},
    }
}

pub fn read(connection: *Connection, buffer: []u8) !usize {
    const handle = connection.handle orelse return error.TlsProviderUnavailable;
    return switch (connection.provider) {
        .openssl => openssl_backend.read(handle, buffer),
        .schannel => schannel_backend.read(handle, buffer),
        .none => error.TlsProviderUnavailable,
    };
}

pub fn hasPendingRead(connection: *Connection) bool {
    const handle = connection.handle orelse return false;
    return switch (connection.provider) {
        .openssl => openssl_backend.hasPendingRead(handle),
        .schannel, .none => false,
    };
}

pub fn write(connection: *Connection, buffer: []const u8) !usize {
    const handle = connection.handle orelse return error.TlsProviderUnavailable;
    return switch (connection.provider) {
        .openssl => openssl_backend.write(handle, buffer),
        .schannel => schannel_backend.write(handle, buffer),
        .none => error.TlsProviderUnavailable,
    };
}

pub fn opensslVersionNumber() ?c_ulong {
    return openssl_backend.versionNumber();
}

pub fn opensslVersionText() ?[:0]const u8 {
    return openssl_backend.versionText();
}

pub fn opensslLastError() ?c_ulong {
    return openssl_backend.lastError();
}

pub fn opensslLastSslError() ?c_int {
    return openssl_backend.lastSslError();
}

pub fn opensslLastIoError() ?c_int {
    return openssl_backend.lastIoError();
}

pub fn opensslLastErrorText() ?[:0]const u8 {
    return openssl_backend.lastErrorText();
}

pub fn negotiatedProtocol(connection: *const Connection) NegotiatedProtocol {
    const handle = connection.handle orelse return .none;
    return switch (connection.provider) {
        .openssl => switch (openssl_backend.negotiatedProtocol(handle)) {
            .none => .none,
            .http1_1 => .http1_1,
            .h2 => .h2,
            .unknown => .unknown,
        },
        .schannel, .none => .none,
    };
}

pub fn protocolVersionText(connection: *const Connection) ?[:0]const u8 {
    const handle = connection.handle orelse return null;
    return switch (connection.provider) {
        .openssl => openssl_backend.protocolVersionText(handle),
        .schannel, .none => null,
    };
}

pub fn cipherText(connection: *const Connection) ?[:0]const u8 {
    const handle = connection.handle orelse return null;
    return switch (connection.provider) {
        .openssl => openssl_backend.cipherText(handle),
        .schannel, .none => null,
    };
}

pub fn sessionReused(connection: *const Connection) bool {
    const handle = connection.handle orelse return false;
    return switch (connection.provider) {
        .openssl => openssl_backend.sessionReused(handle),
        .schannel, .none => false,
    };
}

pub fn backendVersionText(provider: Provider) ?[:0]const u8 {
    return switch (provider) {
        .none => null,
        .openssl => openssl_backend.versionText(),
        .schannel => schannel_backend.versionText(),
    };
}

pub fn initServerContext(allocator: std.mem.Allocator, config: Config) !ServerContext {
    if (config.tls.mode == .off) return error.TlsDisabled;
    const cert_file = config.tls.cert_file orelse return error.InvalidProtocolConfig;
    const key_file = config.tls.key_file orelse return error.InvalidProtocolConfig;
    if (cert_file.len == 0 or key_file.len == 0) return error.InvalidProtocolConfig;

    switch (config.provider) {
        .openssl => {
            const handle = try openssl_backend.initServerHandle(
                allocator,
                cert_file,
                key_file,
                config.tls.min_version,
                config.advertise_h2,
            );
            return .{ .provider = .openssl, .handle = handle };
        },
        .schannel => {
            const handle = try schannel_backend.initServerHandle(allocator, cert_file, key_file);
            return .{ .provider = .schannel, .handle = handle };
        },
        .none,
        => return error.TlsProviderUnavailable,
    }
}

pub fn initClientContext(provider: Provider, verify_peer: bool) !ClientContext {
    return switch (provider) {
        .openssl => .{ .provider = .openssl, .handle = try openssl_backend.initClientHandle(verify_peer) },
        .schannel, .none => error.TlsProviderUnavailable,
    };
}

pub fn validate(config: Config) !void {
    if (config.tls.mode == .off) return;
    const cert_file = config.tls.cert_file orelse "";
    const key_file = config.tls.key_file orelse "";
    if (cert_file.len == 0 or key_file.len == 0) {
        std.debug.print(
            "TLS termination requires both --tls-cert/--tls-key or ZISERVER_TLS_CERT/ZISERVER_TLS_KEY\n",
            .{},
        );
        return error.InvalidProtocolConfig;
    }
    if (!config.provider.supportsTerminate()) {
        std.debug.print(
            "TLS termination requested with provider={s}, linked={s}, but this provider does not support server TLS termination.\n",
            .{ config.provider.text(), if (linkedProvider(config.provider)) "true" else "false" },
        );
        return error.UnsupportedProtocol;
    }
}

pub fn providerFromName(name: []const u8) !Provider {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "openssl")) return .openssl;
    if (std.mem.eql(u8, name, "schannel")) return .schannel;
    return error.InvalidTlsProvider;
}

test "tls provider names are parsed" {
    try std.testing.expectEqual(Provider.none, try providerFromName("none"));
    try std.testing.expectEqual(Provider.openssl, try providerFromName("openssl"));
    try std.testing.expectEqual(Provider.schannel, try providerFromName("schannel"));
    try std.testing.expectError(error.InvalidTlsProvider, providerFromName("boring"));
}

test "tls linked provider follows build option" {
    const selected = providerFromName(build_options.tls_provider) catch .none;
    try std.testing.expectEqual(selected == .openssl, linkedProvider(.openssl));
    try std.testing.expect(!Provider.schannel.supportsTerminate());
}
