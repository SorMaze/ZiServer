const std = @import("std");
const logger = @import("log.zig");
const tls = @import("tls.zig");
const transport = @import("transport.zig");

const max_hashes = 64;
const Document = struct {
    revision: u64,
    revoked: bool = false,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    close_existing: bool = false,
    deny_cert_sha256: []const []const u8 = &.{},
    deny_spki_sha256: []const []const u8 = &.{},
    client_ca_file: ?[]const u8 = null,
    client_crl_file: ?[]const u8 = null,
    client_ocsp_files: []const []const u8 = &.{},
    disable_client_auth: bool = false,
};

const Hashes = struct {
    values: [max_hashes][32]u8 = undefined,
    len: usize = 0,

    fn parse(strings: []const []const u8) !Hashes {
        if (strings.len > max_hashes) return error.TooManyRevokedCertificates;
        var result: Hashes = .{};
        for (strings) |value| {
            if (value.len != 64) return error.InvalidCertificateFingerprint;
            _ = std.fmt.hexToBytes(&result.values[result.len], value) catch return error.InvalidCertificateFingerprint;
            result.len += 1;
        }
        return result;
    }

    fn slice(self: *const Hashes) []const [32]u8 {
        return self.values[0..self.len];
    }
};

pub const Controller = struct {
    path: []const u8,
    config: tls.Config,
    interval_ms: u32,
    next_poll_ns: i96 = 0,
    revision: u64 = 0,
    document_hash: ?[32]u8 = null,
    last_error: ?anyerror = null,
    last_error_revision: u64 = 0,

    pub fn init(path: []const u8, config: tls.Config, interval_ms: u32) Controller {
        return .{ .path = path, .config = config, .interval_ms = interval_ms };
    }

    pub fn tick(self: *Controller, io: std.Io, allocator: std.mem.Allocator, context: *tls.ServerContext, registry: *transport.ConnectionRegistry) void {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (now < self.next_poll_ns) return;
        self.next_poll_ns = now + @as(i96, self.interval_ms) * std.time.ns_per_ms;
        self.apply(io, allocator, context, registry) catch |err| {
            if (self.last_error == null or self.last_error.? != err or self.last_error_revision != self.revision)
                logger.message(io, .err, "tls_control_failed", "revision={d} error={t}", .{ self.revision, err });
            self.last_error = err;
            self.last_error_revision = self.revision;
            return;
        };
        self.last_error = null;
    }

    /// The operator atomically replaces this local desired-state document.
    /// Invalid files retain the last working state. A valid revocation is
    /// applied before attempting a replacement, so a bad replacement cannot
    /// keep a denied credential in service.
    pub fn apply(self: *Controller, io: std.Io, allocator: std.mem.Allocator, context: *tls.ServerContext, registry: *transport.ConnectionRegistry) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path, scratch, .limited(64 * 1024));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (self.document_hash) |previous| {
            if (std.mem.eql(u8, &previous, &digest)) return;
        }
        self.document_hash = digest;
        const parsed = try std.json.parseFromSlice(Document, scratch, bytes, .{});
        const document = parsed.value;
        if (document.revision == 0) return error.InvalidTlsControlRevision;
        if (document.revision <= self.revision) return;
        const cert_hashes = try Hashes.parse(document.deny_cert_sha256);
        const spki_hashes = try Hashes.parse(document.deny_spki_sha256);
        if (!document.revoked and (document.cert_file == null or document.key_file == null)) return error.MissingTlsControlCredential;
        if (document.client_ocsp_files.len > max_hashes) return error.TooManyOcspResponses;
        if (document.client_ca_file == null and (document.client_crl_file != null or document.client_ocsp_files.len != 0)) return error.MissingClientTrustStore;
        if (!document.revoked and document.client_ca_file != null and document.client_crl_file == null and document.client_ocsp_files.len == 0) return error.MissingClientRevocationPolicy;
        // Failed reload attempts also consume the revision: an older document
        // must never roll back a newer revocation. Retry with a new revision.
        self.revision = document.revision;
        if (document.revoked and document.client_ca_file != null) {
            context.mutex.lockUncancelable(io);
            context.client_auth_required = true;
            context.mutex.unlock(io);
        }
        if (document.revoked or try context.denied(cert_hashes.slice(), spki_hashes.slice())) {
            try publish(io, context, registry, null, true);
            logger.message(io, .warn, "tls_certificate_revoked", "revision={d} generation={d}", .{ self.revision, context.generation });
        }
        if (document.revoked) return;
        if (context.client_auth_required and document.client_ca_file == null and !document.disable_client_auth) return error.ClientAuthDowngrade;

        var replacement_config = self.config;
        const parent = std.fs.path.dirname(self.path) orelse ".";
        replacement_config.tls.cert_file = try credentialPath(scratch, parent, document.cert_file.?);
        replacement_config.tls.key_file = try credentialPath(scratch, parent, document.key_file.?);
        var replacement = try tls.initServerContext(scratch, replacement_config);
        defer replacement.deinit();
        if (try replacement.denied(cert_hashes.slice(), spki_hashes.slice())) return error.TlsCertificateRevoked;
        if (document.client_ca_file) |client_ca| {
            const ocsp_files = try scratch.alloc([]const u8, document.client_ocsp_files.len);
            for (document.client_ocsp_files, ocsp_files) |file, *target| target.* = try credentialPath(scratch, parent, file);
            try replacement.configureClientAuth(scratch, try credentialPath(scratch, parent, client_ca), if (document.client_crl_file) |crl| try credentialPath(scratch, parent, crl) else null, ocsp_files, cert_hashes.slice(), spki_hashes.slice());
        }
        try publish(io, context, registry, &replacement, document.close_existing or cert_hashes.len != 0 or spki_hashes.len != 0 or document.client_ca_file != null);
        logger.message(io, .info, "tls_certificate_replaced", "revision={d} generation={d}", .{ self.revision, context.generation });
    }
};

fn credentialPath(allocator: std.mem.Allocator, parent: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidTlsCredentialPath;
    return std.fs.path.resolve(allocator, &.{ parent, path });
}

fn publish(io: std.Io, context: *tls.ServerContext, registry: *transport.ConnectionRegistry, replacement: ?*tls.ServerContext, close_existing: bool) !void {
    context.mutex.lockUncancelable(io);
    defer context.mutex.unlock(io);
    if (context.generation == std.math.maxInt(u64)) return error.TlsGenerationExhausted;
    var retired: tls.ServerContext = .{ .provider = context.provider, .handle = context.handle };
    context.handle = if (replacement) |next| next.handle else null;
    if (replacement) |next| {
        context.client_auth_required = next.client_auth_required;
        next.handle = null;
    }
    context.generation += 1;
    // acquire() publishes the generation under this same lock. Shutting down
    // registered sockets also interrupts handshakes acquired before the swap.
    if (close_existing) registry.shutdownTlsBefore(context.generation);
    if (context.client_auth_required) registry.shutdownPlain();
    retired.deinit();
}

test "revocation hashes require complete SHA256 fingerprints" {
    const valid = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const hashes = try Hashes.parse(&.{valid});
    try std.testing.expectEqual(@as(u8, 0), hashes.values[0][0]);
    try std.testing.expectEqual(@as(u8, 31), hashes.values[0][31]);
    try std.testing.expectError(error.InvalidCertificateFingerprint, Hashes.parse(&.{"00"}));
    try std.testing.expectError(error.InvalidCertificateFingerprint, Hashes.parse(&.{"zz0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}));
}
