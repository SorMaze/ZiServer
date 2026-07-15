const std = @import("std");
const build_options = @import("build_options");
const client_identity = @import("client_identity.zig");
const http_config = @import("http_config.zig");
const log = @import("log.zig");
const page_cache = @import("page_cache.zig");
const protocol_redirect = @import("protocol_redirect.zig");
const rate_limiter = @import("rate_limiter.zig");
const tls = @import("tls.zig");

pub const default_host = "127.0.0.1";
pub const default_port: u16 = 18080;
pub const default_https_port: u16 = 18443;
pub const default_http3_port: u16 = 443;
pub const default_worker_count: usize = 0;
pub const default_acceptor_count: usize = 0;
pub const default_queue_capacity: usize = 0;
pub const default_backlog: u31 = 16384;
pub const default_keep_alive_requests: usize = 1000;
pub const default_queue_shards: usize = 0;
pub const default_tls_handshake_timeout_ms: u32 = 10_000;
pub const default_header_timeout_ms: u32 = 10_000;
pub const default_body_timeout_ms: u32 = 30_000;
pub const default_keep_alive_timeout_ms: u32 = 15_000;
pub const default_shutdown_grace_ms: u32 = 30_000;
pub const default_rate_limit_relaxed_rps: u32 = 0;
pub const default_rate_limit_strict_rps: u32 = 0;
pub const default_xss_mode: http_config.XssFilterMode = .off;
pub const env_tls_mode = "ZISERVER_TLS";
pub const env_tls_cert = "ZISERVER_TLS_CERT";
pub const env_tls_key = "ZISERVER_TLS_KEY";
pub const env_tls_min = "ZISERVER_TLS_MIN";
pub const env_http2_mode = "ZISERVER_HTTP2";
pub const env_log_level = "ZISERVER_LOG_LEVEL";
pub const env_log_format = "ZISERVER_LOG_FORMAT";
pub const env_log_color = "ZISERVER_LOG_COLOR";
pub const env_page_cache = "ZISERVER_PAGE_CACHE";
pub const env_page_cache_capacity = "ZISERVER_PAGE_CACHE_CAPACITY";
pub const env_page_cache_shards = "ZISERVER_PAGE_CACHE_SHARDS";
pub const env_page_cache_max_body = "ZISERVER_PAGE_CACHE_MAX_BODY";
pub const env_page_cache_ttl_percent = "ZISERVER_PAGE_CACHE_TTL_PERCENT";
pub const env_page_cache_header = "ZISERVER_PAGE_CACHE_HEADER";
pub const env_page_cache_fill_wait_timeout = "ZISERVER_PAGE_CACHE_FILL_WAIT_TIMEOUT";
pub const env_page_cache_prewarm = "ZISERVER_PAGE_CACHE_PREWARM";
pub const env_xss_mode = "ZISERVER_XSS_MODE";
pub const env_xss_scan_query = "ZISERVER_XSS_SCAN_QUERY";
pub const env_xss_scan_body = "ZISERVER_XSS_SCAN_BODY";
pub const env_bearer_token = "ZISERVER_BEARER_TOKEN";
pub const env_api_key = "ZISERVER_API_KEY";
pub const env_client_ip_header = "ZISERVER_CLIENT_IP_HEADER";
pub const env_trusted_proxies = "ZISERVER_TRUSTED_PROXIES";
pub const env_forwarded_max_hops = "ZISERVER_FORWARDED_MAX_HOPS";
pub const env_rate_limit_capacity = "ZISERVER_RATE_LIMIT_CAPACITY";
pub const env_rate_limit_shards = "ZISERVER_RATE_LIMIT_SHARDS";
pub const env_rate_limit_idle_ttl = "ZISERVER_RATE_LIMIT_IDLE_TTL_MS";
pub const env_canonical_host = "ZISERVER_CANONICAL_HOST";
pub const env_allowed_hosts = "ZISERVER_ALLOWED_HOSTS";

fn defaultStaticMode() http_config.StaticMode {
    if (std.mem.eql(u8, build_options.static_mode, "embedded")) return .embedded;
    return .filesystem;
}

pub const ServerConfig = struct {
    host: []const u8 = default_host,
    bind_ip: client_identity.IpKey = client_identity.IpKey.loopback(),
    port: u16 = default_port,
    https_port: u16 = default_https_port,
    workers: usize = default_worker_count,
    acceptors: usize = default_acceptor_count,
    queue_capacity: usize = default_queue_capacity,
    backlog: u31 = default_backlog,
    keep_alive_requests: usize = default_keep_alive_requests,
    queue_shards: usize = default_queue_shards,
    tls_handshake_timeout_ms: u32 = default_tls_handshake_timeout_ms,
    header_timeout_ms: u32 = default_header_timeout_ms,
    body_timeout_ms: u32 = default_body_timeout_ms,
    keep_alive_timeout_ms: u32 = default_keep_alive_timeout_ms,
    shutdown_grace_ms: u32 = default_shutdown_grace_ms,
    rate_limit_relaxed_rps: u32 = default_rate_limit_relaxed_rps,
    rate_limit_strict_rps: u32 = default_rate_limit_strict_rps,
    rate_limit_capacity: usize = rate_limiter.default_capacity,
    rate_limit_shards: usize = rate_limiter.default_shards,
    rate_limit_idle_ttl_ms: u32 = rate_limiter.default_idle_ttl_ms,
    client_ip_header: client_identity.HeaderMode = .none,
    forwarded_max_hops: u8 = client_identity.default_forwarded_max_hops,
    trusted_proxies: [client_identity.max_trusted_proxies][]const u8 = undefined,
    trusted_proxy_count: u8 = 0,
    canonical_host: ?[]const u8 = null,
    allowed_hosts: [protocol_redirect.max_allowed_hosts][]const u8 = undefined,
    allowed_host_count: u8 = 0,
    xss_mode: http_config.XssFilterMode = default_xss_mode,
    xss_scan_query: bool = true,
    xss_scan_body: bool = true,
    stats_enabled: bool = true,
    access_log_enabled: bool = true,
    log_level: log.Level = .info,
    log_format: log.Format = .pretty,
    log_color: log.ColorMode = .auto,
    page_cache_enabled: bool = true,
    page_cache_capacity: usize = page_cache.default_capacity,
    page_cache_shards: usize = page_cache.default_shards,
    page_cache_max_body_bytes: usize = page_cache.default_max_body_bytes,
    page_cache_ttl_percent: u16 = page_cache.default_ttl_percent,
    page_cache_response_header: bool = page_cache.default_response_header,
    page_cache_fill_wait_timeout_ms: u32 = page_cache.default_fill_wait_timeout_ms,
    page_cache_prewarm_enabled: bool = true,
    static_mode: http_config.StaticMode = defaultStaticMode(),
    static_dir: []const u8 = http_config.default_static_dir,
    auth_token: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    tls: http_config.TlsConfig = .{},
    http2: http_config.Http2Mode = .reject,
    http3: http_config.Http3Mode = .off,
    http3_port: u16 = default_http3_port,
    tls_mode_explicit: bool = false,
    tls_min_explicit: bool = false,
    http2_mode_explicit: bool = false,
    legacy_port_explicit: bool = false,
    https_port_explicit: bool = false,
    page_cache_enabled_explicit: bool = false,
    log_level_explicit: bool = false,
    log_format_explicit: bool = false,
    log_color_explicit: bool = false,
    page_cache_capacity_explicit: bool = false,
    page_cache_shards_explicit: bool = false,
    page_cache_max_body_explicit: bool = false,
    page_cache_ttl_explicit: bool = false,
    page_cache_header_explicit: bool = false,
    page_cache_fill_wait_timeout_explicit: bool = false,
    page_cache_prewarm_explicit: bool = false,
    xss_mode_explicit: bool = false,
    xss_scan_query_explicit: bool = false,
    xss_scan_body_explicit: bool = false,
    client_ip_header_explicit: bool = false,
    forwarded_max_hops_explicit: bool = false,
    trusted_proxies_explicit: bool = false,
    rate_limit_capacity_explicit: bool = false,
    rate_limit_shards_explicit: bool = false,
    rate_limit_idle_ttl_explicit: bool = false,
    canonical_host_explicit: bool = false,
    allowed_hosts_explicit: bool = false,

    pub fn tlsProvider(_: ServerConfig) tls.Provider {
        return tls.providerFromName(build_options.tls_provider) catch unreachable;
    }

    pub fn authCredentials(self: ServerConfig, environ: *const std.process.Environ.Map) http_config.AuthCredentials {
        return .{
            .bearer_token = firstNonEmpty(&.{ self.auth_token, environ.get(env_bearer_token) }),
            .api_key = firstNonEmpty(&.{ self.api_key, environ.get(env_api_key) }),
        };
    }

    pub fn actualWorkers(self: ServerConfig) usize {
        if (self.workers != 0) return self.workers;
        const cpus = std.Thread.getCpuCount() catch 1;
        return @min(128, @max(4, cpus * 4));
    }

    pub fn actualAcceptors(self: ServerConfig) usize {
        if (self.acceptors != 0) return self.acceptors;
        const cpus = std.Thread.getCpuCount() catch 1;
        return @min(8, @max(1, cpus));
    }

    pub fn actualQueueCapacity(self: ServerConfig, workers: usize) usize {
        if (self.queue_capacity != 0) return self.queue_capacity;
        return @max(4096, workers * 512);
    }

    pub fn actualQueueShards(self: ServerConfig, workers: usize) usize {
        if (self.queue_shards != 0) return self.queue_shards;
        return @min(workers, 4);
    }

    pub fn validateProtocolSupport(self: ServerConfig) !void {
        try tls.validate(.{ .provider = self.tlsProvider(), .tls = self.tls });
        if (self.tls.mode == .terminate and self.port == self.https_port) {
            std.debug.print("--port and --https-port must use different ports when TLS is enabled\n", .{});
            return error.InvalidProtocolConfig;
        }
        if (self.http2 == .on) {
            if (!std.mem.eql(u8, build_options.http2_provider, "nghttp2")) {
                std.debug.print("--http2=on requires a build with -Dhttp2=nghttp2\n", .{});
                return error.UnsupportedProtocol;
            }
            if (self.tls.mode != .terminate) {
                std.debug.print("--http2=on currently requires --tls=terminate\n", .{});
                return error.UnsupportedProtocol;
            }
        }
        if (self.http3 == .advertise) {
            if (self.tls.mode != .terminate) {
                std.debug.print("--http3=advertise currently requires --tls=terminate (Alt-Svc is only meaningful on HTTPS)\n", .{});
                return error.UnsupportedProtocol;
            }
        }
    }

    pub fn pageCacheConfig(self: ServerConfig) page_cache.Config {
        return .{
            .capacity = self.page_cache_capacity,
            .shards = self.page_cache_shards,
            .max_body_bytes = self.page_cache_max_body_bytes,
            .ttl_percent = self.page_cache_ttl_percent,
            .response_header = self.page_cache_response_header,
            .fill_wait_timeout_ms = self.page_cache_fill_wait_timeout_ms,
        };
    }

    pub fn validatePageCache(self: ServerConfig) !void {
        try self.pageCacheConfig().validate();
    }

    pub fn identityResolver(self: ServerConfig) !client_identity.Resolver {
        return client_identity.Resolver.init(
            self.client_ip_header,
            self.trusted_proxies[0..self.trusted_proxy_count],
            self.forwarded_max_hops,
        );
    }

    pub fn rateLimiterConfig(self: ServerConfig) rate_limiter.Config {
        return .{
            .relaxed_rps = self.rate_limit_relaxed_rps,
            .strict_rps = self.rate_limit_strict_rps,
            .capacity = self.rate_limit_capacity,
            .shards = self.rate_limit_shards,
            .idle_ttl_ms = self.rate_limit_idle_ttl_ms,
        };
    }

    pub fn redirectHostPolicy(self: *const ServerConfig) !protocol_redirect.HostPolicy {
        if (self.canonical_host) |host| try protocol_redirect.validateConfiguredHost(host);
        for (self.allowed_hosts[0..self.allowed_host_count]) |host| try protocol_redirect.validateConfiguredHost(host);

        const has_explicit_policy = self.canonical_host != null or self.allowed_host_count != 0;
        const wildcard_bind = self.bind_ip.isUnspecified();
        if (self.tls.mode == .terminate and !has_explicit_policy and wildcard_bind) {
            return error.RedirectHostPolicyRequired;
        }
        const fallback_host: ?[]const u8 = if (!has_explicit_policy and !wildcard_bind) self.host else null;
        if (fallback_host) |host| try protocol_redirect.validateConfiguredHost(host);
        return .{
            .canonical_host = self.canonical_host,
            .allowed_hosts = self.allowed_hosts[0..self.allowed_host_count],
            .fallback_host = fallback_host,
        };
    }

    pub fn validateRateLimitAndIdentity(self: ServerConfig) !void {
        try self.rateLimiterConfig().validate();
        _ = try self.identityResolver();
    }

    pub fn applyRuntimeEnvironment(
        self: *ServerConfig,
        environ: *const std.process.Environ.Map,
    ) !void {
        if (self.tls.cert_file == null) self.tls.cert_file = nonEmpty(environ.get(env_tls_cert));
        if (self.tls.key_file == null) self.tls.key_file = nonEmpty(environ.get(env_tls_key));

        if (!self.tls_mode_explicit) {
            if (nonEmpty(environ.get(env_tls_mode))) |value| {
                self.tls.mode = try parseTlsMode(value);
            } else if (self.tls.cert_file != null or self.tls.key_file != null) {
                self.tls.mode = .terminate;
            }
        }

        if (!self.tls_min_explicit) {
            if (nonEmpty(environ.get(env_tls_min))) |value| {
                self.tls.min_version = try parseTlsMinVersion(value);
            }
        }

        if (!self.http2_mode_explicit) {
            if (nonEmpty(environ.get(env_http2_mode))) |value| {
                self.http2 = try parseHttp2Mode(value);
            } else if (self.tls.mode == .terminate and
                std.mem.eql(u8, build_options.http2_provider, "nghttp2"))
            {
                self.http2 = .on;
            }
        }

        if (!self.log_level_explicit) {
            if (nonEmpty(environ.get(env_log_level))) |value| self.log_level = log.Level.parse(value) catch return error.InvalidLogLevel;
        }
        if (!self.log_format_explicit) {
            if (nonEmpty(environ.get(env_log_format))) |value| self.log_format = log.Format.parse(value) catch return error.InvalidLogFormat;
        }
        if (!self.log_color_explicit) {
            if (nonEmpty(environ.get(env_log_color))) |value| self.log_color = log.ColorMode.parse(value) catch return error.InvalidLogColor;
        }

        if (!self.page_cache_enabled_explicit) {
            if (nonEmpty(environ.get(env_page_cache))) |value| self.page_cache_enabled = try parseOnOff(value);
        }
        if (!self.page_cache_capacity_explicit) {
            if (nonEmpty(environ.get(env_page_cache_capacity))) |value| {
                self.page_cache_capacity = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageCacheCapacity;
            }
        }
        if (!self.page_cache_shards_explicit) {
            if (nonEmpty(environ.get(env_page_cache_shards))) |value| {
                self.page_cache_shards = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageCacheShards;
            }
        }
        if (!self.page_cache_max_body_explicit) {
            if (nonEmpty(environ.get(env_page_cache_max_body))) |value| {
                self.page_cache_max_body_bytes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageCacheBodyLimit;
            }
        }
        if (!self.page_cache_ttl_explicit) {
            if (nonEmpty(environ.get(env_page_cache_ttl_percent))) |value| {
                self.page_cache_ttl_percent = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPageCacheTtlPercent;
            }
        }
        if (!self.page_cache_header_explicit) {
            if (nonEmpty(environ.get(env_page_cache_header))) |value| {
                self.page_cache_response_header = parseOnOff(value) catch return error.InvalidPageCacheHeader;
            }
        }
        if (!self.page_cache_fill_wait_timeout_explicit) {
            if (nonEmpty(environ.get(env_page_cache_fill_wait_timeout))) |value| {
                self.page_cache_fill_wait_timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPageCacheFillWaitTimeout;
            }
        }
        if (!self.page_cache_prewarm_explicit) {
            if (nonEmpty(environ.get(env_page_cache_prewarm))) |value| {
                self.page_cache_prewarm_enabled = parseOnOff(value) catch return error.InvalidPageCachePrewarm;
            }
        }

        if (!self.xss_mode_explicit) {
            if (nonEmpty(environ.get(env_xss_mode))) |value| self.xss_mode = try parseXssMode(value);
        }
        if (!self.xss_scan_query_explicit) {
            if (nonEmpty(environ.get(env_xss_scan_query))) |value| {
                self.xss_scan_query = parseOnOff(value) catch return error.InvalidXssScanQuery;
            }
        }
        if (!self.xss_scan_body_explicit) {
            if (nonEmpty(environ.get(env_xss_scan_body))) |value| {
                self.xss_scan_body = parseOnOff(value) catch return error.InvalidXssScanBody;
            }
        }

        if (!self.client_ip_header_explicit) {
            if (nonEmpty(environ.get(env_client_ip_header))) |value| {
                self.client_ip_header = client_identity.HeaderMode.parse(value) catch return error.InvalidClientIpHeader;
            }
        }
        if (!self.forwarded_max_hops_explicit) {
            if (nonEmpty(environ.get(env_forwarded_max_hops))) |value| {
                self.forwarded_max_hops = std.fmt.parseInt(u8, value, 10) catch return error.InvalidForwardedMaxHops;
            }
        }
        if (!self.trusted_proxies_explicit) {
            if (nonEmpty(environ.get(env_trusted_proxies))) |value| {
                var values = std.mem.splitScalar(u8, value, ',');
                while (values.next()) |item| try appendTrustedProxy(self, std.mem.trim(u8, item, " \t"));
            }
        }
        if (!self.rate_limit_capacity_explicit) {
            if (nonEmpty(environ.get(env_rate_limit_capacity))) |value| {
                self.rate_limit_capacity = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRateLimitCapacity;
            }
        }
        if (!self.rate_limit_shards_explicit) {
            if (nonEmpty(environ.get(env_rate_limit_shards))) |value| {
                self.rate_limit_shards = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRateLimitShards;
            }
        }
        if (!self.rate_limit_idle_ttl_explicit) {
            if (nonEmpty(environ.get(env_rate_limit_idle_ttl))) |value| {
                self.rate_limit_idle_ttl_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidRateLimitIdleTtl;
            }
        }
        if (!self.canonical_host_explicit) {
            if (nonEmpty(environ.get(env_canonical_host))) |value| {
                protocol_redirect.validateConfiguredHost(value) catch return error.InvalidCanonicalHost;
                self.canonical_host = value;
            }
        }
        if (!self.allowed_hosts_explicit) {
            if (nonEmpty(environ.get(env_allowed_hosts))) |value| {
                var values = std.mem.splitScalar(u8, value, ',');
                while (values.next()) |item| try appendAllowedHost(self, std.mem.trim(u8, item, " \t"));
            }
        }

        if (self.tls.mode == .terminate and self.legacy_port_explicit and !self.https_port_explicit) {
            self.https_port = self.port;
            self.port = default_port;
        }
    }
};

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |maybe_value| {
        const value = maybe_value orelse continue;
        if (value.len != 0) return value;
    }
    return null;
}

pub const ParseResult = union(enum) {
    config: ServerConfig,
    exit: u8,
};

pub fn parseArgs(
    args: *std.process.Args.Iterator,
    environ: *const std.process.Environ.Map,
) !ParseResult {
    var config = ServerConfig{};
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return .{ .exit = 0 };
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            config.host = arg["--host=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
            config.legacy_port_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--http-port=")) {
            config.port = try std.fmt.parseInt(u16, arg["--http-port=".len..], 10);
            config.legacy_port_explicit = false;
        } else if (std.mem.startsWith(u8, arg, "--https-port=")) {
            config.https_port = try std.fmt.parseInt(u16, arg["--https-port=".len..], 10);
            config.https_port_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            config.workers = try std.fmt.parseInt(usize, arg["--workers=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--acceptors=")) {
            config.acceptors = try std.fmt.parseInt(usize, arg["--acceptors=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--queue=")) {
            config.queue_capacity = try std.fmt.parseInt(usize, arg["--queue=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--backlog=")) {
            config.backlog = try std.fmt.parseInt(u31, arg["--backlog=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--keep-alive=")) {
            config.keep_alive_requests = try std.fmt.parseInt(usize, arg["--keep-alive=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tls-handshake-timeout=")) {
            config.tls_handshake_timeout_ms = try std.fmt.parseInt(u32, arg["--tls-handshake-timeout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--header-timeout=")) {
            config.header_timeout_ms = try std.fmt.parseInt(u32, arg["--header-timeout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--body-timeout=")) {
            config.body_timeout_ms = try std.fmt.parseInt(u32, arg["--body-timeout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--keep-alive-timeout=")) {
            config.keep_alive_timeout_ms = try std.fmt.parseInt(u32, arg["--keep-alive-timeout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--shutdown-grace=")) {
            config.shutdown_grace_ms = try std.fmt.parseInt(u32, arg["--shutdown-grace=".len..], 10);
        } else if (applyRateLimitArgument(&config, arg) catch |err| {
            std.debug.print("invalid rate limit argument {s}: {t}\n\n", .{ arg, err });
            printUsage();
            return .{ .exit = 2 };
        }) {} else if (applyClientIdentityArgument(&config, arg) catch |err| {
            std.debug.print("invalid client identity argument {s}: {t}\n\n", .{ arg, err });
            printUsage();
            return .{ .exit = 2 };
        }) {} else if (applyRedirectHostArgument(&config, arg) catch |err| {
            std.debug.print("invalid redirect host argument {s}: {t}\n\n", .{ arg, err });
            printUsage();
            return .{ .exit = 2 };
        }) {} else if (std.mem.startsWith(u8, arg, "--shards=")) {
            config.queue_shards = try std.fmt.parseInt(usize, arg["--shards=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--stats=")) {
            const value = arg["--stats=".len..];
            if (std.mem.eql(u8, value, "on")) {
                config.stats_enabled = true;
            } else if (std.mem.eql(u8, value, "off")) {
                config.stats_enabled = false;
            } else {
                std.debug.print("--stats must be on or off\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
        } else if (std.mem.eql(u8, arg, "--no-stats")) {
            config.stats_enabled = false;
        } else if (std.mem.startsWith(u8, arg, "--access-log=")) {
            const value = arg["--access-log=".len..];
            if (std.mem.eql(u8, value, "on")) {
                config.access_log_enabled = true;
            } else if (std.mem.eql(u8, value, "off")) {
                config.access_log_enabled = false;
            } else {
                std.debug.print("--access-log must be on or off\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
        } else if (std.mem.eql(u8, arg, "--no-access-log")) {
            config.access_log_enabled = false;
        } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
            config.log_level = log.Level.parse(arg["--log-level=".len..]) catch {
                std.debug.print("--log-level must be trace, debug, info, warn, or error\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            };
            config.log_level_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--log-format=")) {
            config.log_format = log.Format.parse(arg["--log-format=".len..]) catch {
                std.debug.print("--log-format must be pretty or json\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            };
            config.log_format_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--log-color=")) {
            config.log_color = log.ColorMode.parse(arg["--log-color=".len..]) catch {
                std.debug.print("--log-color must be auto, on, or off\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            };
            config.log_color_explicit = true;
        } else if (applyPageCacheArgument(&config, arg) catch |err| {
            std.debug.print("invalid page cache argument {s}: {t}\n\n", .{ arg, err });
            printUsage();
            return .{ .exit = 2 };
        }) {} else if (applyXssArgument(&config, arg) catch |err| {
            std.debug.print("invalid XSS argument {s}: {t}\n\n", .{ arg, err });
            printUsage();
            return .{ .exit = 2 };
        }) {} else if (std.mem.startsWith(u8, arg, "--static=")) {
            const value = arg["--static=".len..];
            if (std.mem.eql(u8, value, "embedded")) {
                if (!std.mem.eql(u8, build_options.static_mode, "embedded")) {
                    std.debug.print("embedded static assets are not available in this build; rebuild with -Dstatic=embedded\n\n", .{});
                    printUsage();
                    return .{ .exit = 2 };
                }
                config.static_mode = .embedded;
            } else if (std.mem.eql(u8, value, "filesystem")) {
                config.static_mode = .filesystem;
            } else {
                std.debug.print("--static must be embedded or filesystem\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
        } else if (std.mem.startsWith(u8, arg, "--static-dir=")) {
            config.static_dir = arg["--static-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--auth-token=")) {
            config.auth_token = arg["--auth-token=".len..];
        } else if (std.mem.startsWith(u8, arg, "--api-key=")) {
            config.api_key = arg["--api-key=".len..];
        } else if (std.mem.startsWith(u8, arg, "--tls=")) {
            const value = arg["--tls=".len..];
            if (std.mem.eql(u8, value, "off")) {
                config.tls.mode = .off;
            } else if (std.mem.eql(u8, value, "terminate")) {
                config.tls.mode = .terminate;
            } else {
                std.debug.print("--tls must be off or terminate\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
            config.tls_mode_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--tls-cert=")) {
            config.tls.cert_file = arg["--tls-cert=".len..];
        } else if (std.mem.startsWith(u8, arg, "--tls-key=")) {
            config.tls.key_file = arg["--tls-key=".len..];
        } else if (std.mem.startsWith(u8, arg, "--tls-min=")) {
            config.tls.min_version = parseTlsMinVersion(arg["--tls-min=".len..]) catch {
                std.debug.print("--tls-min must be 1.2 or 1.3\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            };
            config.tls_min_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--http2=")) {
            const value = arg["--http2=".len..];
            if (std.mem.eql(u8, value, "off")) {
                config.http2 = .off;
            } else if (std.mem.eql(u8, value, "reject")) {
                config.http2 = .reject;
            } else if (std.mem.eql(u8, value, "on")) {
                config.http2 = .on;
            } else {
                std.debug.print("--http2 must be off, reject, or on\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
            config.http2_mode_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--http3-port=")) {
            config.http3_port = try std.fmt.parseInt(u16, arg["--http3-port=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--http3=")) {
            const value = arg["--http3=".len..];
            if (std.mem.eql(u8, value, "off")) {
                config.http3 = .off;
            } else if (std.mem.eql(u8, value, "advertise")) {
                config.http3 = .advertise;
            } else {
                std.debug.print("--http3 must be off or advertise\n\n", .{});
                printUsage();
                return .{ .exit = 2 };
            }
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{arg});
            printUsage();
            return .{ .exit = 2 };
        }
    }

    config.applyRuntimeEnvironment(environ) catch |err| {
        switch (err) {
            error.InvalidTlsMode => std.debug.print("{s} must be off or terminate\n", .{env_tls_mode}),
            error.InvalidTlsMinVersion => std.debug.print("{s} must be 1.2 or 1.3\n", .{env_tls_min}),
            error.InvalidHttp2Mode => std.debug.print("{s} must be off, reject, or on\n", .{env_http2_mode}),
            error.InvalidLogLevel => std.debug.print("{s} must be trace, debug, info, warn, or error\n", .{env_log_level}),
            error.InvalidLogFormat => std.debug.print("{s} must be pretty or json\n", .{env_log_format}),
            error.InvalidLogColor => std.debug.print("{s} must be auto, on, or off\n", .{env_log_color}),
            error.InvalidPageCacheMode => std.debug.print("{s} must be on or off\n", .{env_page_cache}),
            error.InvalidPageCacheCapacity => std.debug.print("{s} must be an integer\n", .{env_page_cache_capacity}),
            error.InvalidPageCacheShards => std.debug.print("{s} must be an integer\n", .{env_page_cache_shards}),
            error.InvalidPageCacheBodyLimit => std.debug.print("{s} must be an integer\n", .{env_page_cache_max_body}),
            error.InvalidPageCacheTtlPercent => std.debug.print("{s} must be an integer\n", .{env_page_cache_ttl_percent}),
            error.InvalidPageCacheHeader => std.debug.print("{s} must be on or off\n", .{env_page_cache_header}),
            error.InvalidPageCacheFillWaitTimeout => std.debug.print("{s} must be an integer from 0 to 30000\n", .{env_page_cache_fill_wait_timeout}),
            error.InvalidPageCachePrewarm => std.debug.print("{s} must be on or off\n", .{env_page_cache_prewarm}),
            error.InvalidXssMode => std.debug.print("{s} must be off, observe, or block\n", .{env_xss_mode}),
            error.InvalidXssScanQuery => std.debug.print("{s} must be on or off\n", .{env_xss_scan_query}),
            error.InvalidXssScanBody => std.debug.print("{s} must be on or off\n", .{env_xss_scan_body}),
            error.InvalidClientIpHeader => std.debug.print("{s} must be none or x-forwarded-for\n", .{env_client_ip_header}),
            error.InvalidForwardedMaxHops => std.debug.print("{s} must be an integer from 1 to 32\n", .{env_forwarded_max_hops}),
            error.InvalidTrustedProxy, error.TooManyTrustedProxies => std.debug.print("{s} contains an invalid or excessive CIDR list\n", .{env_trusted_proxies}),
            error.InvalidRateLimitCapacity => std.debug.print("{s} must be a valid bounded integer\n", .{env_rate_limit_capacity}),
            error.InvalidRateLimitShards => std.debug.print("{s} must be a valid bounded integer\n", .{env_rate_limit_shards}),
            error.InvalidRateLimitIdleTtl => std.debug.print("{s} must be at least 1000\n", .{env_rate_limit_idle_ttl}),
            error.InvalidCanonicalHost => std.debug.print("{s} must be a hostname or IP literal without scheme, port, path, or userinfo\n", .{env_canonical_host}),
            error.InvalidAllowedHost, error.TooManyAllowedHosts => std.debug.print("{s} contains an invalid or excessive host list\n", .{env_allowed_hosts}),
        }
        printUsage();
        return .{ .exit = 2 };
    };
    config.validateProtocolSupport() catch {
        printUsage();
        return .{ .exit = 2 };
    };
    config.validatePageCache() catch |err| {
        std.debug.print("invalid page cache configuration: {t}\n", .{err});
        printUsage();
        return .{ .exit = 2 };
    };
    config.validateRateLimitAndIdentity() catch |err| {
        std.debug.print("invalid rate limit/client identity configuration: {t}\n", .{err});
        printUsage();
        return .{ .exit = 2 };
    };
    config.bind_ip = client_identity.IpKey.fromAddress(std.Io.net.IpAddress.parse(config.host, 0) catch |err| {
        std.debug.print("invalid bind host {s}: {t}\n", .{ config.host, err });
        printUsage();
        return .{ .exit = 2 };
    });
    _ = config.redirectHostPolicy() catch |err| {
        std.debug.print("invalid redirect host policy: {t}; wildcard TLS listeners require --canonical-host or --allowed-host\n", .{err});
        printUsage();
        return .{ .exit = 2 };
    };

    return .{ .config = config };
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  ziserver [--host=127.0.0.1] [--http-port=18080] [--https-port=18443] [--acceptors=N] [--workers=N] [--queue=N] [--shards=N] [--backlog=N]
        \\
        \\Options:
        \\  --port=N       compatibility primary port: HTTPS with certificates, otherwise HTTP
        \\  --http-port=N  plain HTTP port, default 18080
        \\  --https-port=N HTTPS port used when certificates are configured, default 18443
        \\  --acceptors=N  accept threads, default auto up to 8
        \\  --workers=N    fixed connection worker threads, default auto up to 128
        \\  --queue=N      pending accepted connection queue capacity, default auto
        \\  --shards=N     normal connection queue shards, default auto up to 4
        \\  --backlog=N    kernel listen backlog, default 16384
        \\  --keep-alive=N max requests per connection, 0 disables connection reuse
        \\  --tls-handshake-timeout=MS TLS handshake deadline, default 10000; 0 disables
        \\  --header-timeout=MS request header deadline, default 10000; 0 disables
        \\  --body-timeout=MS request body deadline, default 30000; 0 disables
        \\  --keep-alive-timeout=MS idle connection deadline, default 15000; 0 disables
        \\  --shutdown-grace=MS graceful drain deadline, default 30000
        \\  --stats=on|off enable or disable atomic live stats, default on
        \\  --no-stats     shorthand for --stats=off
        \\  --access-log=on|off enable or disable per-request logs, default on
        \\  --no-access-log shorthand for --access-log=off
        \\  --log-level=LEVEL trace|debug|info|warn|error, default info
        \\  --log-format=FORMAT pretty for PowerShell or json for collectors, default pretty
        \\  --log-color=MODE auto|on|off; auto colors only an interactive terminal
        \\  --page-cache=on|off enable dynamic page cache, default on
        \\  --no-page-cache shorthand for --page-cache=off
        \\  --page-cache-capacity=N total entries, default 256, max 16384
        \\  --page-cache-shards=N lock shards, default 16, max 64 and no greater than capacity
        \\  --page-cache-max-body=BYTES per-entry body limit, default 262144, max 1048576
        \\  --page-cache-ttl-percent=N scale route TTLs, default 100, range 1..1000
        \\  --page-cache-header=on|off emit X-Page-Cache on hits, default off
        \\  --page-cache-fill-wait-timeout=MS max coalesced miss wait, default 100; 0 bypasses
        \\  --page-cache-prewarm=on|off asynchronously render exact static-shared routes at startup, default on
        \\  --no-page-cache-prewarm shorthand for --page-cache-prewarm=off
        \\  --xss-mode=off|observe|block server-wide minimum XSS policy, default off
        \\  --xss-scan-query=on|off inspect query strings when XSS policy is active, default on
        \\  --xss-scan-body=on|off inspect request bodies when XSS policy is active, default on
        \\  --rate-limit-relaxed=N relaxed per-client requests per second; 0 disables
        \\  --rate-limit-strict=N strict per-client requests per second; 0 disables
        \\  --rate-limit-capacity=N maximum client/policy entries, default 65536
        \\  --rate-limit-shards=N limiter lock shards, default 64
        \\  --rate-limit-idle-ttl=MS idle entry retention, default 600000
        \\  --client-ip-header=none|x-forwarded-for forwarded identity mode, default none
        \\  --trusted-proxy=CIDR trusted direct proxy; repeat for multiple networks
        \\  --forwarded-max-hops=N maximum X-Forwarded-For addresses, default 16
        \\  --canonical-host=HOST fixed redirect Location host; no scheme, port, or path
        \\  --allowed-host=HOST allowed redirect request host; repeat for multiple hosts
        \\  --static=embedded|filesystem static asset provider
        \\  --static-dir=DIR static filesystem root, default public
        \\  --auth-token=TOKEN configure Bearer auth token
        \\  --api-key=KEY configure X-API-Key auth credential
        \\  --tls=off|terminate TLS mode; certificate configuration enables terminate by default
        \\  --tls-cert=FILE certificate chain; overrides ZISERVER_TLS_CERT
        \\  --tls-key=FILE private key; overrides ZISERVER_TLS_KEY
        \\  --tls-min=1.2|1.3 minimum TLS version; defaults to 1.2 with TLS 1.3 preferred
        \\  --http2=off|reject|on HTTP/2 handling; defaults to on when TLS certificates are configured
        \\  --http3=off|advertise advertise an external HTTP/3 endpoint via Alt-Svc on HTTPS responses
        \\  --http3-port=N  external QUIC/UDP port advertised in Alt-Svc, default 443
        \\
        \\Examples:
        \\  zig build run -- --port=8080
        \\  zig build run -- --acceptors=4 --workers=64 --queue=32768 --shards=4
        \\  zig build run -- --no-stats --keep-alive=2000
        \\  zig build -Doptimize=ReleaseFast
        \\
    , .{});
}

fn parseTlsMode(value: []const u8) !http_config.TlsMode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "terminate")) return .terminate;
    return error.InvalidTlsMode;
}

fn parseTlsMinVersion(value: []const u8) !http_config.TlsMinVersion {
    if (std.mem.eql(u8, value, "1.2")) return .tls12;
    if (std.mem.eql(u8, value, "1.3")) return .tls13;
    return error.InvalidTlsMinVersion;
}

fn parseHttp2Mode(value: []const u8) !http_config.Http2Mode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "reject")) return .reject;
    if (std.mem.eql(u8, value, "on")) return .on;
    return error.InvalidHttp2Mode;
}

fn parseOnOff(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return error.InvalidPageCacheMode;
}

fn parseXssMode(value: []const u8) !http_config.XssFilterMode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "observe")) return .observe;
    if (std.mem.eql(u8, value, "block")) return .block;
    return error.InvalidXssMode;
}

fn applyXssArgument(config: *ServerConfig, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--xss-mode=")) {
        config.xss_mode = try parseXssMode(arg["--xss-mode=".len..]);
        config.xss_mode_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--xss-scan-query=")) {
        config.xss_scan_query = parseOnOff(arg["--xss-scan-query=".len..]) catch return error.InvalidXssScanQuery;
        config.xss_scan_query_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--xss-scan-body=")) {
        config.xss_scan_body = parseOnOff(arg["--xss-scan-body=".len..]) catch return error.InvalidXssScanBody;
        config.xss_scan_body_explicit = true;
    } else {
        return false;
    }
    return true;
}

fn applyRateLimitArgument(config: *ServerConfig, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--rate-limit-relaxed=")) {
        config.rate_limit_relaxed_rps = try std.fmt.parseInt(u32, arg["--rate-limit-relaxed=".len..], 10);
    } else if (std.mem.startsWith(u8, arg, "--rate-limit-strict=")) {
        config.rate_limit_strict_rps = try std.fmt.parseInt(u32, arg["--rate-limit-strict=".len..], 10);
    } else if (std.mem.startsWith(u8, arg, "--rate-limit-capacity=")) {
        config.rate_limit_capacity = try std.fmt.parseInt(usize, arg["--rate-limit-capacity=".len..], 10);
        config.rate_limit_capacity_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--rate-limit-shards=")) {
        config.rate_limit_shards = try std.fmt.parseInt(usize, arg["--rate-limit-shards=".len..], 10);
        config.rate_limit_shards_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--rate-limit-idle-ttl=")) {
        config.rate_limit_idle_ttl_ms = try std.fmt.parseInt(u32, arg["--rate-limit-idle-ttl=".len..], 10);
        config.rate_limit_idle_ttl_explicit = true;
    } else {
        return false;
    }
    return true;
}

fn applyClientIdentityArgument(config: *ServerConfig, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--client-ip-header=")) {
        config.client_ip_header = try client_identity.HeaderMode.parse(arg["--client-ip-header=".len..]);
        config.client_ip_header_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--trusted-proxy=")) {
        try appendTrustedProxy(config, arg["--trusted-proxy=".len..]);
        config.trusted_proxies_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--forwarded-max-hops=")) {
        config.forwarded_max_hops = try std.fmt.parseInt(u8, arg["--forwarded-max-hops=".len..], 10);
        config.forwarded_max_hops_explicit = true;
    } else {
        return false;
    }
    return true;
}

fn appendTrustedProxy(config: *ServerConfig, value: []const u8) !void {
    if (value.len == 0) return error.InvalidTrustedProxy;
    if (config.trusted_proxy_count >= config.trusted_proxies.len) return error.TooManyTrustedProxies;
    _ = client_identity.Cidr.parse(value) catch return error.InvalidTrustedProxy;
    config.trusted_proxies[config.trusted_proxy_count] = value;
    config.trusted_proxy_count += 1;
}

fn applyRedirectHostArgument(config: *ServerConfig, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--canonical-host=")) {
        const value = arg["--canonical-host=".len..];
        protocol_redirect.validateConfiguredHost(value) catch return error.InvalidCanonicalHost;
        config.canonical_host = value;
        config.canonical_host_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--allowed-host=")) {
        try appendAllowedHost(config, arg["--allowed-host=".len..]);
        config.allowed_hosts_explicit = true;
    } else {
        return false;
    }
    return true;
}

fn appendAllowedHost(config: *ServerConfig, value: []const u8) !void {
    protocol_redirect.validateConfiguredHost(value) catch return error.InvalidAllowedHost;
    if (config.allowed_host_count >= config.allowed_hosts.len) return error.TooManyAllowedHosts;
    for (config.allowed_hosts[0..config.allowed_host_count]) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, value)) return;
    }
    config.allowed_hosts[config.allowed_host_count] = value;
    config.allowed_host_count += 1;
}

fn applyPageCacheArgument(config: *ServerConfig, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--page-cache=")) {
        config.page_cache_enabled = try parseOnOff(arg["--page-cache=".len..]);
        config.page_cache_enabled_explicit = true;
    } else if (std.mem.eql(u8, arg, "--no-page-cache")) {
        config.page_cache_enabled = false;
        config.page_cache_enabled_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-capacity=")) {
        config.page_cache_capacity = try std.fmt.parseInt(usize, arg["--page-cache-capacity=".len..], 10);
        config.page_cache_capacity_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-shards=")) {
        config.page_cache_shards = try std.fmt.parseInt(usize, arg["--page-cache-shards=".len..], 10);
        config.page_cache_shards_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-max-body=")) {
        config.page_cache_max_body_bytes = try std.fmt.parseInt(usize, arg["--page-cache-max-body=".len..], 10);
        config.page_cache_max_body_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-ttl-percent=")) {
        config.page_cache_ttl_percent = try std.fmt.parseInt(u16, arg["--page-cache-ttl-percent=".len..], 10);
        config.page_cache_ttl_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-header=")) {
        config.page_cache_response_header = try parseOnOff(arg["--page-cache-header=".len..]);
        config.page_cache_header_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-fill-wait-timeout=")) {
        config.page_cache_fill_wait_timeout_ms = try std.fmt.parseInt(u32, arg["--page-cache-fill-wait-timeout=".len..], 10);
        config.page_cache_fill_wait_timeout_explicit = true;
    } else if (std.mem.startsWith(u8, arg, "--page-cache-prewarm=")) {
        config.page_cache_prewarm_enabled = try parseOnOff(arg["--page-cache-prewarm=".len..]);
        config.page_cache_prewarm_explicit = true;
    } else if (std.mem.eql(u8, arg, "--no-page-cache-prewarm")) {
        config.page_cache_prewarm_enabled = false;
        config.page_cache_prewarm_explicit = true;
    } else {
        return false;
    }
    return true;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const resolved = value orelse return null;
    return if (resolved.len == 0) null else resolved;
}

test "runtime certificate environment enables TLS and compiled HTTP2" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_tls_cert, "cert.pem");
    try env.put(env_tls_key, "key.pem");
    try env.put(env_tls_min, "1.3");

    var config = ServerConfig{};
    try config.applyRuntimeEnvironment(&env);

    try std.testing.expectEqual(http_config.TlsMode.terminate, config.tls.mode);
    try std.testing.expectEqualStrings("cert.pem", config.tls.cert_file.?);
    try std.testing.expectEqualStrings("key.pem", config.tls.key_file.?);
    try std.testing.expectEqual(http_config.TlsMinVersion.tls13, config.tls.min_version);
    try std.testing.expectEqual(
        if (std.mem.eql(u8, build_options.http2_provider, "nghttp2")) http_config.Http2Mode.on else http_config.Http2Mode.reject,
        config.http2,
    );
}

test "runtime auth credentials prefer cli over environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_bearer_token, "env-token");
    try env.put(env_api_key, "env-key");

    const from_env = (ServerConfig{}).authCredentials(&env);
    try std.testing.expectEqualStrings("env-token", from_env.bearer_token.?);
    try std.testing.expectEqualStrings("env-key", from_env.api_key.?);

    const from_cli = (ServerConfig{
        .auth_token = "cli-token",
        .api_key = "cli-key",
    }).authCredentials(&env);
    try std.testing.expectEqualStrings("cli-token", from_cli.bearer_token.?);
    try std.testing.expectEqualStrings("cli-key", from_cli.api_key.?);

    var empty_env = std.process.Environ.Map.init(std.testing.allocator);
    defer empty_env.deinit();
    const unconfigured = (ServerConfig{}).authCredentials(&empty_env);
    try std.testing.expectEqual(@as(?[]const u8, null), unconfigured.bearer_token);
    try std.testing.expectEqual(@as(?[]const u8, null), unconfigured.api_key);
}

test "legacy port remains the HTTPS port when certificates enable TLS" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_tls_cert, "cert.pem");
    try env.put(env_tls_key, "key.pem");

    var config = ServerConfig{
        .port = 18443,
        .legacy_port_explicit = true,
    };
    try config.applyRuntimeEnvironment(&env);

    try std.testing.expectEqual(default_port, config.port);
    try std.testing.expectEqual(@as(u16, 18443), config.https_port);
}

test "explicit protocol and certificate values override environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_tls_mode, "terminate");
    try env.put(env_tls_cert, "env-cert.pem");
    try env.put(env_tls_key, "env-key.pem");
    try env.put(env_tls_min, "1.3");
    try env.put(env_http2_mode, "on");

    var config = ServerConfig{
        .tls = .{ .mode = .off, .min_version = .tls12, .cert_file = "cli-cert.pem", .key_file = "cli-key.pem" },
        .http2 = .off,
        .tls_mode_explicit = true,
        .tls_min_explicit = true,
        .http2_mode_explicit = true,
    };
    try config.applyRuntimeEnvironment(&env);

    try std.testing.expectEqual(http_config.TlsMode.off, config.tls.mode);
    try std.testing.expectEqual(http_config.TlsMinVersion.tls12, config.tls.min_version);
    try std.testing.expectEqual(http_config.Http2Mode.off, config.http2);
    try std.testing.expectEqualStrings("cli-cert.pem", config.tls.cert_file.?);
    try std.testing.expectEqualStrings("cli-key.pem", config.tls.key_file.?);
}

test "invalid protocol environment is rejected" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_tls_mode, "automatic");

    var config = ServerConfig{};
    try std.testing.expectError(error.InvalidTlsMode, config.applyRuntimeEnvironment(&env));
}

test "log environment configures PowerShell and collector output" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_log_level, "debug");
    try env.put(env_log_format, "json");
    try env.put(env_log_color, "off");

    var config = ServerConfig{};
    try config.applyRuntimeEnvironment(&env);
    try std.testing.expectEqual(log.Level.debug, config.log_level);
    try std.testing.expectEqual(log.Format.json, config.log_format);
    try std.testing.expectEqual(log.ColorMode.off, config.log_color);
}

test "explicit log configuration overrides environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_log_level, "error");
    try env.put(env_log_format, "json");
    try env.put(env_log_color, "off");

    var config = ServerConfig{
        .log_level = .info,
        .log_format = .pretty,
        .log_color = .on,
        .log_level_explicit = true,
        .log_format_explicit = true,
        .log_color_explicit = true,
    };
    try config.applyRuntimeEnvironment(&env);
    try std.testing.expectEqual(log.Level.info, config.log_level);
    try std.testing.expectEqual(log.Format.pretty, config.log_format);
    try std.testing.expectEqual(log.ColorMode.on, config.log_color);
}

test "TLS minimum version parser accepts supported versions" {
    try std.testing.expectEqual(http_config.TlsMinVersion.tls12, try parseTlsMinVersion("1.2"));
    try std.testing.expectEqual(http_config.TlsMinVersion.tls13, try parseTlsMinVersion("1.3"));
    try std.testing.expectError(error.InvalidTlsMinVersion, parseTlsMinVersion("1.1"));
}

test "page cache environment configures runtime store" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_page_cache, "off");
    try env.put(env_page_cache_capacity, "512");
    try env.put(env_page_cache_shards, "32");
    try env.put(env_page_cache_max_body, "65536");
    try env.put(env_page_cache_ttl_percent, "150");
    try env.put(env_page_cache_header, "on");
    try env.put(env_page_cache_fill_wait_timeout, "250");
    try env.put(env_page_cache_prewarm, "off");

    var config = ServerConfig{};
    try config.applyRuntimeEnvironment(&env);
    try config.validatePageCache();
    try std.testing.expect(!config.page_cache_enabled);
    try std.testing.expectEqual(@as(usize, 512), config.page_cache_capacity);
    try std.testing.expectEqual(@as(usize, 32), config.page_cache_shards);
    try std.testing.expectEqual(@as(usize, 65536), config.page_cache_max_body_bytes);
    try std.testing.expectEqual(@as(u16, 150), config.page_cache_ttl_percent);
    try std.testing.expect(config.page_cache_response_header);
    try std.testing.expectEqual(@as(u32, 250), config.page_cache_fill_wait_timeout_ms);
    try std.testing.expect(!config.page_cache_prewarm_enabled);
}

test "explicit page cache config overrides environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_page_cache, "off");
    try env.put(env_page_cache_capacity, "1");

    var config = ServerConfig{
        .page_cache_enabled = true,
        .page_cache_capacity = 64,
        .page_cache_shards = 8,
        .page_cache_enabled_explicit = true,
        .page_cache_capacity_explicit = true,
    };
    try config.applyRuntimeEnvironment(&env);
    try config.validatePageCache();
    try std.testing.expect(config.page_cache_enabled);
    try std.testing.expectEqual(@as(usize, 64), config.page_cache_capacity);
}

test "page cache environment rejects invalid values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_page_cache, "maybe");
    var config = ServerConfig{};
    try std.testing.expectError(error.InvalidPageCacheMode, config.applyRuntimeEnvironment(&env));
}

test "page cache CLI arguments set values and explicit precedence" {
    var config = ServerConfig{};
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache=off"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-capacity=128"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-shards=8"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-max-body=32768"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-ttl-percent=75"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-header=on"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-fill-wait-timeout=75"));
    try std.testing.expect(try applyPageCacheArgument(&config, "--page-cache-prewarm=off"));
    try std.testing.expect(!(try applyPageCacheArgument(&config, "--unrelated=value")));
    try config.validatePageCache();
    try std.testing.expect(!config.page_cache_enabled);
    try std.testing.expectEqual(@as(usize, 128), config.page_cache_capacity);
    try std.testing.expectEqual(@as(usize, 8), config.page_cache_shards);
    try std.testing.expectEqual(@as(usize, 32768), config.page_cache_max_body_bytes);
    try std.testing.expectEqual(@as(u16, 75), config.page_cache_ttl_percent);
    try std.testing.expect(config.page_cache_ttl_explicit);
    try std.testing.expect(config.page_cache_response_header);
    try std.testing.expectEqual(@as(u32, 75), config.page_cache_fill_wait_timeout_ms);
    try std.testing.expect(!config.page_cache_prewarm_enabled);
    try std.testing.expect(config.page_cache_prewarm_explicit);
}

test "XSS environment and CLI configuration use explicit precedence" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_xss_mode, "observe");
    try env.put(env_xss_scan_query, "off");
    try env.put(env_xss_scan_body, "off");

    var config = ServerConfig{};
    try std.testing.expect(try applyXssArgument(&config, "--xss-mode=block"));
    try std.testing.expect(try applyXssArgument(&config, "--xss-scan-body=on"));
    try config.applyRuntimeEnvironment(&env);

    try std.testing.expectEqual(http_config.XssFilterMode.block, config.xss_mode);
    try std.testing.expect(!config.xss_scan_query);
    try std.testing.expect(config.xss_scan_body);
    try std.testing.expectError(error.InvalidXssMode, parseXssMode("filter"));
}

test "client identity CLI requires explicit trusted proxy and compiles CIDRs" {
    var config = ServerConfig{};
    try std.testing.expect(try applyClientIdentityArgument(&config, "--client-ip-header=x-forwarded-for"));
    try std.testing.expectError(error.ClientIpHeaderRequiresTrustedProxy, config.validateRateLimitAndIdentity());
    try std.testing.expect(try applyClientIdentityArgument(&config, "--trusted-proxy=10.0.0.0/8"));
    try std.testing.expect(try applyClientIdentityArgument(&config, "--trusted-proxy=2001:db8::/32"));
    try std.testing.expect(try applyClientIdentityArgument(&config, "--forwarded-max-hops=8"));
    try config.validateRateLimitAndIdentity();
    const resolver = try config.identityResolver();
    try std.testing.expectEqual(@as(usize, 2), resolver.trustedCount());
    try std.testing.expectEqual(@as(u8, 8), resolver.forwarded_max_hops);
}

test "client identity and limiter environment are bounded" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_client_ip_header, "x-forwarded-for");
    try env.put(env_trusted_proxies, "10.0.0.0/8, 2001:db8::/32");
    try env.put(env_forwarded_max_hops, "4");
    try env.put(env_rate_limit_capacity, "128");
    try env.put(env_rate_limit_shards, "8");
    try env.put(env_rate_limit_idle_ttl, "5000");

    var config = ServerConfig{};
    try config.applyRuntimeEnvironment(&env);
    try config.validateRateLimitAndIdentity();
    try std.testing.expectEqual(client_identity.HeaderMode.x_forwarded_for, config.client_ip_header);
    try std.testing.expectEqual(@as(u8, 2), config.trusted_proxy_count);
    try std.testing.expectEqual(@as(usize, 128), config.rate_limit_capacity);
    try std.testing.expectEqual(@as(usize, 8), config.rate_limit_shards);
    try std.testing.expectEqual(@as(u32, 5000), config.rate_limit_idle_ttl_ms);
}

test "rate limiter CLI validates capacity shard and TTL" {
    var config = ServerConfig{};
    try std.testing.expect(try applyRateLimitArgument(&config, "--rate-limit-relaxed=10"));
    try std.testing.expect(try applyRateLimitArgument(&config, "--rate-limit-strict=2"));
    try std.testing.expect(try applyRateLimitArgument(&config, "--rate-limit-capacity=64"));
    try std.testing.expect(try applyRateLimitArgument(&config, "--rate-limit-shards=4"));
    try std.testing.expect(try applyRateLimitArgument(&config, "--rate-limit-idle-ttl=1000"));
    try config.validateRateLimitAndIdentity();
    const limiter_config = config.rateLimiterConfig();
    try std.testing.expectEqual(@as(u32, 10), limiter_config.relaxed_rps);
    try std.testing.expectEqual(@as(u32, 2), limiter_config.strict_rps);
    try std.testing.expectEqual(@as(usize, 64), limiter_config.capacity);
}

test "redirect host CLI builds canonical and allowed policy" {
    var config = ServerConfig{};
    try std.testing.expect(try applyRedirectHostArgument(&config, "--canonical-host=app.example"));
    try std.testing.expect(try applyRedirectHostArgument(&config, "--allowed-host=app.example"));
    try std.testing.expect(try applyRedirectHostArgument(&config, "--allowed-host=api.example"));
    try std.testing.expect(!(try applyRedirectHostArgument(&config, "--unrelated=value")));
    const policy = try config.redirectHostPolicy();
    try std.testing.expectEqualStrings("app.example", policy.canonical_host.?);
    try std.testing.expectEqual(@as(usize, 2), policy.allowed_hosts.len);
    try std.testing.expectError(error.InvalidCanonicalHost, applyRedirectHostArgument(&config, "--canonical-host=https://app.example"));
    try std.testing.expectError(error.InvalidAllowedHost, applyRedirectHostArgument(&config, "--allowed-host=app.example:443"));
}

test "wildcard TLS bind requires explicit safe redirect host policy" {
    const unsafe = ServerConfig{
        .host = "0.0.0.0",
        .bind_ip = client_identity.IpKey.unspecified(),
        .tls = .{ .mode = .terminate },
    };
    try std.testing.expectError(error.RedirectHostPolicyRequired, unsafe.redirectHostPolicy());

    var canonical = unsafe;
    canonical.canonical_host = "lan.example";
    try std.testing.expectEqualStrings("lan.example", (try canonical.redirectHostPolicy()).canonical_host.?);

    const loopback = ServerConfig{};
    try std.testing.expectEqualStrings("127.0.0.1", (try loopback.redirectHostPolicy()).fallback_host.?);

    const expanded_ipv6 = ServerConfig{
        .host = "0:0:0:0:0:0:0:0",
        .bind_ip = try client_identity.IpKey.parse("0:0:0:0:0:0:0:0"),
        .tls = .{ .mode = .terminate },
    };
    try std.testing.expectError(error.RedirectHostPolicyRequired, expanded_ipv6.redirectHostPolicy());
}

test "redirect host environment parses a bounded comma-separated allowlist" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(env_canonical_host, "app.example");
    try env.put(env_allowed_hosts, "app.example, api.example");

    var config = ServerConfig{};
    try config.applyRuntimeEnvironment(&env);
    const policy = try config.redirectHostPolicy();
    try std.testing.expectEqualStrings("app.example", policy.canonical_host.?);
    try std.testing.expectEqual(@as(usize, 2), policy.allowed_hosts.len);
}
