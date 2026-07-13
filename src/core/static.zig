const std = @import("std");

const build_options = @import("build_options");
const http_config = @import("http_config.zig");

pub const embedded_available = std.mem.eql(u8, build_options.static_mode, "embedded");

pub const Asset = struct {
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
    cache: http_config.CachePolicy,
    owned: bool = false,

    pub fn deinit(self: Asset, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
    }
};

pub const Store = struct {
    mode: http_config.StaticMode,
    root_dir: []const u8,
    io: ?std.Io = null,
    allocator: ?std.mem.Allocator = null,

    pub fn embedded() Store {
        return .{
            .mode = .embedded,
            .root_dir = "",
        };
    }

    pub fn filesystem(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8) Store {
        return .{
            .mode = .filesystem,
            .root_dir = root_dir,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn resolve(self: Store, path: []const u8) !?Asset {
        return switch (self.mode) {
            .embedded => findEmbedded(path),
            .filesystem => try self.findFilesystem(path),
        };
    }

    fn findFilesystem(self: Store, path: []const u8) !?Asset {
        const io = self.io.?;
        const allocator = self.allocator.?;
        var relative_buffer: [512]u8 = undefined;
        const relative_path = routeToRelativePath(path, &relative_buffer) orelse return null;

        var file_path_buffer: [1024]u8 = undefined;
        const file_path = try joinRoot(self.root_dir, relative_path, &file_path_buffer);
        const body = std.Io.Dir.cwd().readFileAlloc(
            io,
            file_path,
            allocator,
            .limited(http_config.max_static_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound,
            error.IsDir,
            error.NotDir,
            error.AccessDenied,
            error.StreamTooLong,
            => return null,
            else => return err,
        };

        return .{
            .path = path,
            .body = body,
            .content_type = contentTypeForPath(relative_path),
            .cache = cachePolicyForPath(relative_path),
            .owned = true,
        };
    }
};

pub fn findEmbedded(path: []const u8) ?Asset {
    if (!embedded_available) return null;

    const index_html = @embedFile("../public/index.html");
    const style_css = @embedFile("../public/assets/style.css");
    const app_js = @embedFile("../public/assets/app.js");
    const gsap_min_js = @embedFile("../public/assets/gsap.min.js");
    const scroll_trigger_min_js = @embedFile("../public/assets/ScrollTrigger.min.js");

    const assets = [_]Asset{
        .{
            .path = "/",
            .body = index_html,
            .content_type = http_config.ContentType.html,
            .cache = .no_cache,
        },
        .{
            .path = "/index.html",
            .body = index_html,
            .content_type = http_config.ContentType.html,
            .cache = .no_cache,
        },
        .{
            .path = "/assets/style.css",
            .body = style_css,
            .content_type = http_config.ContentType.css,
            .cache = .static_asset,
        },
        .{
            .path = "/assets/app.js",
            .body = app_js,
            .content_type = http_config.ContentType.javascript,
            .cache = .static_asset,
        },
        .{
            .path = "/assets/gsap.min.js",
            .body = gsap_min_js,
            .content_type = http_config.ContentType.javascript,
            .cache = .static_asset,
        },
        .{
            .path = "/assets/ScrollTrigger.min.js",
            .body = scroll_trigger_min_js,
            .content_type = http_config.ContentType.javascript,
            .cache = .static_asset,
        },
    };

    for (assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}

fn routeToRelativePath(path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;

    if (std.mem.eql(u8, path, "/")) return "index.html";
    const relative = path[1..];
    if (relative.len == 0 or relative.len > buffer.len) return null;
    @memcpy(buffer[0..relative.len], relative);
    return buffer[0..relative.len];
}

fn joinRoot(root_dir: []const u8, relative_path: []const u8, buffer: []u8) ![]const u8 {
    const trimmed_root = std.mem.trimEnd(u8, root_dir, "/\\");
    if (trimmed_root.len == 0 or std.mem.eql(u8, trimmed_root, ".")) {
        if (relative_path.len > buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..relative_path.len], relative_path);
        return buffer[0..relative_path.len];
    }
    return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ trimmed_root, relative_path });
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return http_config.ContentType.html;
    if (std.mem.endsWith(u8, path, ".css")) return http_config.ContentType.css;
    if (std.mem.endsWith(u8, path, ".js")) return http_config.ContentType.javascript;
    if (std.mem.endsWith(u8, path, ".json")) return http_config.ContentType.json;
    if (std.mem.endsWith(u8, path, ".svg")) return http_config.ContentType.svg;
    if (std.mem.endsWith(u8, path, ".png")) return http_config.ContentType.png;
    if (std.mem.endsWith(u8, path, ".ico")) return http_config.ContentType.icon;
    if (std.mem.endsWith(u8, path, ".txt")) return http_config.ContentType.plain;
    return http_config.ContentType.octet_stream;
}

fn cachePolicyForPath(path: []const u8) http_config.CachePolicy {
    if (std.mem.endsWith(u8, path, ".html")) return .no_cache;
    return .static_asset;
}

test "routeToRelativePath maps root and rejects unsafe paths" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("index.html", routeToRelativePath("/", &buffer).?);
    try std.testing.expectEqualStrings("assets/app.js", routeToRelativePath("/assets/app.js", &buffer).?);
    try std.testing.expect(routeToRelativePath("/../secret", &buffer) == null);
    try std.testing.expect(routeToRelativePath("/C:/secret", &buffer) == null);
    try std.testing.expect(routeToRelativePath("/assets\\app.js", &buffer) == null);
}
