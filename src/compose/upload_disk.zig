const std = @import("std");

const Context = @import("../core/context.zig").Context;
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");

const upload = @import("upload.zig");

const max_filename_bytes = 240;
var result_local_key: u8 = 0;

pub const Result = struct {
    files: usize = 0,
    bytes: usize = 0,
};

pub fn apply(ctx: *Context) !middleware.Decision {
    switch (ctx.route_options.upload_landing) {
        .none => return .next,
        .small => |config| try storeSmall(ctx, config),
        .stream => |config| try storeStream(ctx, config),
    }
    return .next;
}

pub fn result(ctx: *const Context) ?Result {
    return ctx.local(&result_local_key, Result);
}

fn storeSmall(ctx: *Context, config: http_config.SmallFileUploadConfig) !void {
    try validateDiskConfig(config.storage);
    _ = try upload.inspect(ctx);
    const content_type = ctx.request.contentType() orelse return error.UnsupportedUploadType;
    var storage_dir = openStorageDir(ctx.io, config.storage) catch |err| return mapStorageError(err);
    defer storage_dir.close(ctx.io);

    var summary = Result{};
    var parts = try upload.MultipartIterator.init(content_type, ctx.request.body);
    while (try parts.next()) |part| {
        const filename = part.filename orelse continue;
        storeBytes(ctx.io, storage_dir, filename, part.data, config.storage) catch |err| return mapStorageError(err);
        summary.files += 1;
        summary.bytes += part.data.len;
    }
    try ctx.setLocal(&result_local_key, summary);
}

fn storeStream(ctx: *Context, config: http_config.StreamFileUploadConfig) !void {
    try validateStreamConfig(config);
    if (ctx.request.method != .post and ctx.request.method != .put and ctx.request.method != .patch) return error.InvalidUpload;
    if (!upload.allowedContentType(ctx.request.contentType(), config.allowed_content_types)) return error.UnsupportedUploadType;
    const filename = ctx.request.header(config.filename_header) orelse return error.InvalidUpload;
    if (!upload.safeFilename(filename)) return error.UnsafeUploadFilename;
    if (!upload.allowedExtension(filename, config.allowed_extensions)) return error.UnsupportedUploadType;

    var storage_dir = openStorageDir(ctx.io, config.storage) catch |err| return mapStorageError(err);
    defer storage_dir.close(ctx.io);
    const final_name = try chooseFilename(ctx.io, filename, config.storage.naming);
    var atomic = storage_dir.createFileAtomic(ctx.io, final_name.slice(), .{
        .replace = config.storage.collision == .replace,
    }) catch |err| return mapStorageError(err);
    defer atomic.deinit(ctx.io);

    var buffer: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    const reader = ctx.requestBodyStream();
    while (true) {
        const count = try reader.read(&buffer);
        if (count == 0) break;
        if (count > config.max_request_bytes -| total) return error.UploadFileTooLarge;
        atomic.file.writeStreamingAll(ctx.io, buffer[0..count]) catch |err| return mapStorageError(err);
        total += count;
    }
    if (config.require_nonempty and total == 0) return error.MissingUploadFile;
    if (config.storage.sync_on_finish) atomic.file.sync(ctx.io) catch |err| return mapStorageError(err);
    commitAtomic(&atomic, ctx.io, config.storage.collision) catch |err| return mapStorageError(err);
    try ctx.setLocal(&result_local_key, Result{ .files = 1, .bytes = total });
}

fn storeBytes(
    io: std.Io,
    storage_dir: std.Io.Dir,
    original_filename: []const u8,
    bytes: []const u8,
    config: http_config.UploadDiskConfig,
) !void {
    const final_name = try chooseFilename(io, original_filename, config.naming);
    var atomic = try storage_dir.createFileAtomic(io, final_name.slice(), .{
        .replace = config.collision == .replace,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    if (config.sync_on_finish) try atomic.file.sync(io);
    try commitAtomic(&atomic, io, config.collision);
}

fn commitAtomic(atomic: *std.Io.File.Atomic, io: std.Io, collision: http_config.UploadCollision) !void {
    switch (collision) {
        .reject => try atomic.link(io),
        .replace => try atomic.replace(io),
    }
}

fn openStorageDir(io: std.Io, config: http_config.UploadDiskConfig) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    if (config.create_directory) try cwd.createDirPath(io, config.directory);
    return cwd.openDir(io, config.directory, .{});
}

const ChosenFilename = struct {
    buffer: [max_filename_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const ChosenFilename) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn chooseFilename(io: std.Io, original: []const u8, naming: http_config.UploadNaming) !ChosenFilename {
    if (!upload.safeFilename(original) or original.len > max_filename_bytes) return error.UnsafeUploadFilename;
    var chosen = ChosenFilename{};
    switch (naming) {
        .original => {
            @memcpy(chosen.buffer[0..original.len], original);
            chosen.len = original.len;
        },
        .random => {
            var random_bytes: [16]u8 = undefined;
            io.random(&random_bytes);
            const encoded = std.fmt.bytesToHex(random_bytes, .lower);
            const extension = std.fs.path.extension(original);
            if (encoded.len + extension.len > chosen.buffer.len) return error.UnsafeUploadFilename;
            @memcpy(chosen.buffer[0..encoded.len], &encoded);
            @memcpy(chosen.buffer[encoded.len .. encoded.len + extension.len], extension);
            chosen.len = encoded.len + extension.len;
        },
    }
    return chosen;
}

fn validateDiskConfig(config: http_config.UploadDiskConfig) !void {
    if (config.directory.len == 0 or std.mem.indexOfScalar(u8, config.directory, 0) != null) return error.InvalidUploadPolicy;
}

fn validateStreamConfig(config: http_config.StreamFileUploadConfig) !void {
    try validateDiskConfig(config.storage);
    if (config.max_request_bytes == 0 or config.max_request_bytes > http_config.max_stream_body_bytes) return error.InvalidUploadPolicy;
    if (config.filename_header.len == 0 or std.mem.indexOfAny(u8, config.filename_header, "\r\n") != null) return error.InvalidUploadPolicy;
    for (config.allowed_content_types) |value| if (value.len == 0) return error.InvalidUploadPolicy;
    for (config.allowed_extensions) |value| if (value.len < 2 or value[0] != '.') return error.InvalidUploadPolicy;
}

fn mapStorageError(err: anyerror) anyerror {
    return switch (err) {
        error.PathAlreadyExists => error.UploadAlreadyExists,
        error.InvalidUploadPolicy,
        error.UnsafeUploadFilename,
        error.UnsupportedUploadType,
        error.MissingUploadFile,
        error.UploadFileTooLarge,
        => err,
        else => error.UploadStorageFailed,
    };
}

test "atomic storage rejects collisions and preserves file data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = http_config.UploadDiskConfig{
        .directory = "unused",
        .naming = .original,
        .collision = .reject,
    };
    try storeBytes(std.testing.io, tmp.dir, "note.txt", "first", config);
    try std.testing.expectError(error.PathAlreadyExists, storeBytes(std.testing.io, tmp.dir, "note.txt", "second", config));
    const body = try tmp.dir.readFileAlloc(std.testing.io, "note.txt", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("first", body);
}

test "random storage names retain only the validated extension" {
    const chosen = try chooseFilename(std.testing.io, "photo.PNG", .random);
    try std.testing.expectEqual(@as(usize, 36), chosen.len);
    try std.testing.expectEqualStrings(".PNG", chosen.slice()[32..]);
}

test "stream upload middleware consumes the request reader into an atomic file" {
    const request_mod = @import("../core/request.zig");
    const response = @import("../core/response.zig");
    const router = @import("../core/router.zig");
    const services = @import("../core/services.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const body = "streamed-body";
    var raw_buffer: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buffer,
        "PUT /upload/stream HTTP/1.1\r\nHost: test\r\nContent-Type: application/octet-stream\r\nX-Upload-Filename: large.txt\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const request = try request_mod.Request.parse(raw);
    const config = http_config.StreamFileUploadConfig{
        .max_request_bytes = 1024,
        .allowed_extensions = &.{".txt"},
        .storage = .{ .directory = directory, .naming = .original },
    };
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{
            .body_limit = config.max_request_bytes,
            .streaming_body = true,
            .upload_landing = .{ .stream = config },
        },
        router.Params.empty(),
        .{},
        services.Registry{},
        null,
    );
    try std.testing.expectEqual(middleware.Decision.next, try apply(&ctx));
    try std.testing.expectEqual(@as(usize, body.len), result(&ctx).?.bytes);
    const stored = try tmp.dir.readFileAlloc(std.testing.io, "large.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings(body, stored);
}
