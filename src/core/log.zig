const std = @import("std");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn text(self: Level) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn parse(value: []const u8) !Level {
        if (std.ascii.eqlIgnoreCase(value, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(value, "warn") or std.ascii.eqlIgnoreCase(value, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
        return error.InvalidLogLevel;
    }
};

pub const Format = enum {
    pretty,
    json,

    pub fn text(self: Format) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Format {
        if (std.ascii.eqlIgnoreCase(value, "pretty")) return .pretty;
        if (std.ascii.eqlIgnoreCase(value, "json")) return .json;
        return error.InvalidLogFormat;
    }
};

pub const ColorMode = enum {
    auto,
    on,
    off,

    pub fn text(self: ColorMode) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !ColorMode {
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "on")) return .on;
        if (std.ascii.eqlIgnoreCase(value, "off")) return .off;
        return error.InvalidLogColor;
    }
};

pub const Config = struct {
    min_level: Level = .info,
    format: Format = .pretty,
    color: ColorMode = .auto,
};

pub const CacheStatus = enum {
    disabled,
    bypass,
    miss,
    fill,
    hit,

    pub fn text(self: CacheStatus) []const u8 {
        return @tagName(self);
    }

    fn label(self: CacheStatus) []const u8 {
        return switch (self) {
            .disabled => "OFF",
            .bypass => "BYPASS",
            .miss => "MISS",
            .fill => "FILL",
            .hit => "HIT",
        };
    }
};

pub const Access = struct {
    protocol: []const u8,
    method: []const u8,
    target: []const u8,
    status: u16,
    body_bytes: usize,
    duration_us: i96,
    cache_enabled: bool,
    cache_status: CacheStatus,
    response_cache: []const u8,
    client_ip: []const u8,
    client_ip_source: []const u8,
};

const RuntimeConfig = struct {
    min_level: Level = .info,
    format: Format = .pretty,
    colors: bool = false,
};

var runtime_config: RuntimeConfig = .{};

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const bright_black = "\x1b[90m";
    const bright_red = "\x1b[91m";
    const bright_green = "\x1b[92m";
    const bright_yellow = "\x1b[93m";
    const bright_cyan = "\x1b[96m";
};

/// Configure logging before worker threads start. In auto mode, ANSI is only
/// enabled for an interactive stderr terminal; redirected output remains clean.
pub fn init(io: std.Io, config: Config, no_color: bool) void {
    const colors = switch (config.color) {
        .off => false,
        .on => true,
        .auto => if (no_color)
            false
        else block: {
            std.Io.File.stderr().enableAnsiEscapeCodes(io) catch break :block false;
            break :block true;
        },
    };
    runtime_config = .{
        .min_level = config.min_level,
        .format = config.format,
        .colors = colors and config.format == .pretty,
    };
}

pub fn enabled(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(runtime_config.min_level);
}

pub fn message(io: std.Io, level: Level, event: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;

    var detail_buffer: [8192]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, fmt, args) catch "log_detail_truncated";
    const time_unix_ms = unixTimeMs(io);
    if (runtime_config.format == .json) {
        var event_buffer: [256]u8 = undefined;
        var message_buffer: [16384]u8 = undefined;
        const escaped_event = escapeJson(event, &event_buffer);
        const escaped_message = escapeJson(detail, &message_buffer);
        std.debug.print(
            "{{\"time_unix_ms\":{d},\"level\":\"{s}\",\"event\":\"{s}\",\"message\":\"{s}\"}}\n",
            .{ time_unix_ms, level.text(), escaped_event, escaped_message },
        );
        return;
    }

    var safe_detail_buffer: [8192]u8 = undefined;
    const safe_detail = sanitizeConsole(detail, &safe_detail_buffer);
    const color = if (runtime_config.colors) levelColor(level) else "";
    const reset = if (runtime_config.colors) ansi.reset else "";
    std.debug.print("{s}[{s}]{s} {d} {s}: {s}\n", .{ color, level.label(), reset, time_unix_ms, event, safe_detail });
}

pub fn access(io: std.Io, value: Access) void {
    const level = levelForStatus(value.status);
    if (!enabled(level)) return;
    const time_unix_ms = unixTimeMs(io);

    if (runtime_config.format == .json) {
        var protocol_buffer: [64]u8 = undefined;
        var method_buffer: [64]u8 = undefined;
        var target_buffer: [8192]u8 = undefined;
        var response_cache_buffer: [256]u8 = undefined;
        var client_ip_buffer: [128]u8 = undefined;
        var client_ip_source_buffer: [64]u8 = undefined;
        std.debug.print(
            "{{\"time_unix_ms\":{d},\"level\":\"{s}\",\"event\":\"request\",\"protocol\":\"{s}\",\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"body_bytes\":{d},\"duration_us\":{d},\"client_ip\":\"{s}\",\"client_ip_source\":\"{s}\",\"cache_enabled\":{s},\"page_cache\":\"{s}\",\"response_cache\":\"{s}\"}}\n",
            .{
                time_unix_ms,
                level.text(),
                escapeJson(value.protocol, &protocol_buffer),
                escapeJson(value.method, &method_buffer),
                escapeJson(value.target, &target_buffer),
                value.status,
                value.body_bytes,
                value.duration_us,
                escapeJson(value.client_ip, &client_ip_buffer),
                escapeJson(value.client_ip_source, &client_ip_source_buffer),
                if (value.cache_enabled) "true" else "false",
                value.cache_status.text(),
                escapeJson(value.response_cache, &response_cache_buffer),
            },
        );
        return;
    }

    const use_color = runtime_config.colors;
    const level_color = if (use_color) levelColor(level) else "";
    const status_color = if (use_color) statusColor(value.status) else "";
    const cache_color = if (use_color) cacheColor(value.cache_status) else "";
    const dim = if (use_color) ansi.dim else "";
    const reset = if (use_color) ansi.reset else "";
    var method_buffer: [128]u8 = undefined;
    var target_buffer: [8192]u8 = undefined;
    const safe_method = sanitizeConsole(value.method, &method_buffer);
    const safe_target = sanitizeConsole(value.target, &target_buffer);
    std.debug.print(
        "{s}[{s}]{s} {d} HTTP[{s}] {s} {s} {s}{d}{s} {s}{d}us{s} bytes={d} client={s} source={s} cache={s}{s}{s} enabled={s} response_cache={s}\n",
        .{
            level_color,
            level.label(),
            reset,
            time_unix_ms,
            value.protocol,
            safe_method,
            safe_target,
            status_color,
            value.status,
            reset,
            dim,
            value.duration_us,
            reset,
            value.body_bytes,
            value.client_ip,
            value.client_ip_source,
            cache_color,
            value.cache_status.label(),
            reset,
            if (value.cache_enabled) "yes" else "no",
            value.response_cache,
        },
    );
}

pub fn levelForStatus(status: u16) Level {
    if (status >= 500) return .err;
    if (status >= 400) return .warn;
    return .info;
}

fn unixTimeMs(io: std.Io) i96 {
    return @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
}

fn levelColor(level: Level) []const u8 {
    return switch (level) {
        .trace => ansi.bright_black,
        .debug => ansi.cyan,
        .info => ansi.bright_cyan,
        .warn => ansi.bright_yellow,
        .err => ansi.bright_red,
    };
}

fn statusColor(status: u16) []const u8 {
    if (status >= 500) return ansi.bright_red;
    if (status >= 400) return ansi.bright_yellow;
    if (status >= 300) return ansi.cyan;
    return ansi.bright_green;
}

fn cacheColor(status: CacheStatus) []const u8 {
    return switch (status) {
        .disabled => ansi.bright_black,
        .bypass => ansi.dim,
        .miss => ansi.yellow,
        .fill => ansi.cyan,
        .hit => ansi.green,
    };
}

fn escapeJson(input: []const u8, buffer: []u8) []const u8 {
    var out: usize = 0;
    for (input) |byte| {
        const replacement: []const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11...12, 14...0x1f => "?",
            else => &.{byte},
        };
        if (replacement.len > buffer.len - out) break;
        @memcpy(buffer[out .. out + replacement.len], replacement);
        out += replacement.len;
    }
    return buffer[0..out];
}

fn sanitizeConsole(input: []const u8, buffer: []u8) []const u8 {
    const count = @min(input.len, buffer.len);
    for (input[0..count], 0..) |byte, index| {
        buffer[index] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return buffer[0..count];
}

test "log configuration parsers and status levels" {
    try std.testing.expectEqual(Level.debug, try Level.parse("DEBUG"));
    try std.testing.expectEqual(Format.json, try Format.parse("json"));
    try std.testing.expectEqual(ColorMode.auto, try ColorMode.parse("auto"));
    try std.testing.expectError(error.InvalidLogLevel, Level.parse("verbose"));
    try std.testing.expectEqual(Level.info, levelForStatus(304));
    try std.testing.expectEqual(Level.warn, levelForStatus(404));
    try std.testing.expectEqual(Level.err, levelForStatus(503));
}

test "JSON escaping keeps access fields on one line" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/a\\\"b\\nc", escapeJson("/a\"b\nc", &buffer));
}

test "pretty output strips terminal control bytes" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/safe?[31m?next", sanitizeConsole("/safe\x1b[31m\nnext", &buffer));
}
