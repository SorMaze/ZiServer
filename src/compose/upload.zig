const std = @import("std");

const Context = @import("../core/context.zig").Context;
const form = @import("form.zig");
const http_config = @import("../core/http_config.zig");
const middleware = @import("../core/middleware.zig");
const request_mod = @import("../core/request.zig");

const max_part_header_bytes = 4096;

pub const Summary = struct {
    parts: usize = 0,
    fields: usize = 0,
    files: usize = 0,
    file_bytes: usize = 0,
};

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

var summary_local_key: u8 = 0;

/// Returns the upload validation result for this request. The default upload
/// middleware populates the allocation-free request local, so handlers reuse
/// the result without parsing multipart framing a second time.
pub fn inspect(ctx: *Context) !Summary {
    if (ctx.local(&summary_local_key, Summary)) |summary| return summary;
    const policy = ctx.route_options.upload orelse return error.UploadPolicyMissing;
    const summary = try inspectRequest(ctx.request, policy);
    try ctx.setLocal(&summary_local_key, summary);
    return summary;
}

pub fn validate(ctx: *Context) !middleware.Decision {
    if (ctx.route_options.upload == null) return .next;
    if (ctx.request.method == .options) return .next;
    _ = try inspect(ctx);
    return .next;
}

pub fn inspectRequest(request: request_mod.Request, policy: http_config.UploadPolicy) !Summary {
    try validatePolicy(policy);
    if (request.method != .post and request.method != .put and request.method != .patch) return error.InvalidUpload;
    const content_type = request.contentType() orelse return error.UnsupportedUploadType;
    if (!request.hasContentType(http_config.ContentType.multipart_form)) return error.UnsupportedUploadType;
    if (request.body.len > policy.max_request_bytes) return error.UploadFileTooLarge;

    var iterator = try MultipartIterator.init(content_type, request.body);
    var summary = Summary{};
    while (try iterator.next()) |part| {
        summary.parts += 1;
        const filename = part.filename orelse {
            summary.fields += 1;
            continue;
        };
        // Browsers use filename="" when a file input is left empty.
        if (filename.len == 0) {
            if (part.data.len != 0) return error.InvalidUpload;
            continue;
        }
        if (!safeFilename(filename)) return error.UnsafeUploadFilename;
        if (summary.files >= policy.max_files) return error.TooManyUploadFiles;
        if (part.data.len > policy.max_file_bytes) return error.UploadFileTooLarge;
        if (!allowedExtension(filename, policy.allowed_extensions)) return error.UnsupportedUploadType;
        if (!allowedContentType(part.content_type, policy.allowed_content_types)) return error.UnsupportedUploadType;
        summary.files += 1;
        summary.file_bytes += part.data.len;
    }
    if (policy.require_file and summary.files == 0) return error.MissingUploadFile;
    return summary;
}

fn validatePolicy(policy: http_config.UploadPolicy) !void {
    if (policy.max_request_bytes == 0 or policy.max_request_bytes > http_config.max_form_body_bytes or
        policy.max_file_bytes == 0 or policy.max_file_bytes > policy.max_request_bytes or policy.max_files == 0)
    {
        return error.InvalidUploadPolicy;
    }
    for (policy.allowed_extensions) |extension| {
        if (extension.len < 2 or extension[0] != '.' or std.mem.indexOfAny(u8, extension, "/\\\x00") != null) {
            return error.InvalidUploadPolicy;
        }
    }
    for (policy.allowed_content_types) |content_type| {
        if (content_type.len == 0 or std.mem.indexOfAny(u8, content_type, "\r\n") != null) return error.InvalidUploadPolicy;
    }
}

pub fn allowedExtension(filename: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return false;
    const extension = filename[dot..];
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

pub fn allowedContentType(content_type: ?[]const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    const value = content_type orelse return false;
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..semicolon], " \t");
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(media, candidate)) return true;
    }
    return false;
}

pub fn safeFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename.len > 255 or std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..")) return false;
    if (filename[0] == '.' or filename[0] == ' ' or filename[filename.len - 1] == '.' or filename[filename.len - 1] == ' ') return false;
    for (filename) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        switch (byte) {
            '/', '\\', ':', '\x00' => return false,
            else => {},
        }
    }

    const dot = std.mem.indexOfScalar(u8, filename, '.') orelse filename.len;
    const stem = filename[0..dot];
    const reserved = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };
    for (reserved) |name| if (std.ascii.eqlIgnoreCase(stem, name)) return false;
    return true;
}

pub const MultipartIterator = struct {
    body: []const u8,
    marker: [72]u8 = undefined,
    marker_len: usize,
    cursor: usize = 0,
    done: bool = false,

    pub fn init(content_type: []const u8, body: []const u8) !MultipartIterator {
        const boundary = form.multipartBoundary(content_type) orelse return error.InvalidUpload;
        if (boundary.len == 0 or boundary.len > 70) return error.InvalidUpload;
        var result = MultipartIterator{ .body = body, .marker_len = boundary.len + 2 };
        result.marker[0] = '-';
        result.marker[1] = '-';
        @memcpy(result.marker[2..result.marker_len], boundary);
        return result;
    }

    pub fn next(self: *MultipartIterator) !?Part {
        if (self.done) return null;
        if (!startsAt(self.body, self.cursor, self.marker[0..self.marker_len])) return error.InvalidUpload;
        self.cursor += self.marker_len;
        if (startsAt(self.body, self.cursor, "--")) {
            self.cursor += 2;
            if (startsAt(self.body, self.cursor, "\r\n")) self.cursor += 2;
            if (self.cursor != self.body.len) return error.InvalidUpload;
            self.done = true;
            return null;
        }
        if (!startsAt(self.body, self.cursor, "\r\n")) return error.InvalidUpload;
        self.cursor += 2;

        const header_end = std.mem.indexOfPos(u8, self.body, self.cursor, "\r\n\r\n") orelse return error.InvalidUpload;
        if (header_end - self.cursor > max_part_header_bytes) return error.InvalidUpload;
        const headers = self.body[self.cursor..header_end];
        const data_start = header_end + 4;
        var delimiter: [76]u8 = undefined;
        delimiter[0] = '\r';
        delimiter[1] = '\n';
        @memcpy(delimiter[2 .. self.marker_len + 2], self.marker[0..self.marker_len]);
        const data_end = std.mem.indexOfPos(u8, self.body, data_start, delimiter[0 .. self.marker_len + 2]) orelse return error.InvalidUpload;
        self.cursor = data_end + 2;
        return try parsePart(headers, self.body[data_start..data_end]);
    }
};

fn parsePart(headers: []const u8, data: []const u8) !Part {
    const disposition = try uniqueHeader(headers, "Content-Disposition") orelse return error.InvalidUpload;
    const name = try dispositionParameter(disposition, "name") orelse return error.InvalidUpload;
    if (name.len == 0) return error.InvalidUpload;
    const filename = try dispositionParameter(disposition, "filename");
    const content_type = try uniqueHeader(headers, "Content-Type");
    return .{ .name = name, .filename = filename, .content_type = content_type, .data = data };
}

fn uniqueHeader(headers: []const u8, wanted: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var rest = headers;
    while (rest.len != 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidUpload;
        if (colon == 0 or line[0] == ' ' or line[0] == '\t') return error.InvalidUpload;
        const name = line[0..colon];
        if (!validHeaderName(name)) return error.InvalidUpload;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidUpload;
        if (std.ascii.eqlIgnoreCase(name, wanted)) {
            if (found != null) return error.InvalidUpload;
            found = value;
        }
        if (line_end == rest.len) break;
        rest = rest[line_end + 2 ..];
    }
    return found;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => continue,
            else => return false,
        }
    }
    return true;
}

fn dispositionParameter(disposition: []const u8, wanted: []const u8) !?[]const u8 {
    var segments = std.mem.splitScalar(u8, disposition, ';');
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, segments.next() orelse return error.InvalidUpload, " \t"), "form-data")) {
        return error.InvalidUpload;
    }
    var found: ?[]const u8 = null;
    while (segments.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidUpload;
        const name = std.mem.trim(u8, trimmed[0..equals], " \t");
        var value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
            if (std.mem.indexOfAny(u8, value, "\"\\\r\n") != null) return error.InvalidUpload;
        } else if (std.mem.indexOfAny(u8, value, " \t\"\r\n") != null) {
            return error.InvalidUpload;
        }
        if (std.ascii.eqlIgnoreCase(name, wanted)) {
            if (found != null) return error.InvalidUpload;
            found = value;
        }
    }
    return found;
}

fn startsAt(haystack: []const u8, offset: usize, needle: []const u8) bool {
    return offset <= haystack.len and needle.len <= haystack.len - offset and std.mem.eql(u8, haystack[offset .. offset + needle.len], needle);
}

fn inspectMultipart(body: []const u8, policy: http_config.UploadPolicy) !Summary {
    var raw_buffer: [4096]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buffer,
        "POST /upload HTTP/1.1\r\nHost: test\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const request = try request_mod.Request.parse(raw);
    return inspectRequest(request, policy);
}

test "upload accepts allowlisted files and reports fields" {
    const body =
        "--abc\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n" ++
        "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.TXT\"\r\nContent-Type: text/plain\r\n\r\npayload\r\n" ++
        "--abc--\r\n";
    const summary = try inspectMultipart(body, .{
        .allowed_extensions = &.{".txt"},
        .allowed_content_types = &.{"text/plain"},
    });
    try std.testing.expectEqual(@as(usize, 2), summary.parts);
    try std.testing.expectEqual(@as(usize, 1), summary.fields);
    try std.testing.expectEqual(@as(usize, 1), summary.files);
    try std.testing.expectEqual(@as(usize, 7), summary.file_bytes);
}

test "upload rejects traversal names and unsupported types" {
    const traversal_body = "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"../secret.txt\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--abc--\r\n";
    try std.testing.expectError(error.UnsafeUploadFilename, inspectMultipart(traversal_body, .{}));

    const type_body = "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"run.exe\"\r\nContent-Type: application/octet-stream\r\n\r\nx\r\n--abc--\r\n";
    try std.testing.expectError(error.UnsupportedUploadType, inspectMultipart(type_body, .{
        .allowed_extensions = &.{".txt"},
        .allowed_content_types = &.{"text/plain"},
    }));
}

test "upload enforces file count and per-file limit" {
    const two_files =
        "--abc\r\nContent-Disposition: form-data; name=\"a\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\na\r\n" ++
        "--abc\r\nContent-Disposition: form-data; name=\"b\"; filename=\"b.txt\"\r\nContent-Type: text/plain\r\n\r\nb\r\n" ++
        "--abc--\r\n";
    try std.testing.expectError(error.TooManyUploadFiles, inspectMultipart(two_files, .{ .max_files = 1 }));

    const large = "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nlarge\r\n--abc--\r\n";
    try std.testing.expectError(error.UploadFileTooLarge, inspectMultipart(large, .{ .max_file_bytes = 4 }));
}

test "upload requires a selected file by default" {
    const fields_only = "--abc\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--abc--\r\n";
    try std.testing.expectError(error.MissingUploadFile, inspectMultipart(fields_only, .{}));
    const summary = try inspectMultipart(fields_only, .{ .require_file = false });
    try std.testing.expectEqual(@as(usize, 1), summary.fields);
    try std.testing.expectEqual(@as(usize, 0), summary.files);
}

test "upload middleware caches summary for the handler" {
    const response = @import("../core/response.zig");
    const router = @import("../core/router.zig");
    const static = @import("../core/static.zig");
    const stats_mod = @import("../core/stats.zig");

    const body = "--abc\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\ndata\r\n--abc--\r\n";
    var raw_buffer: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buffer,
        "POST /upload HTTP/1.1\r\nHost: test\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const request = try request_mod.Request.parse(raw);
    var capture = response.Capture{};
    defer capture.deinit(std.testing.allocator);
    var target: response.Target = .{ .capture = .{ .response = &capture, .allocator = std.testing.allocator } };
    var stats = stats_mod.Stats.init(true);
    const static_store = static.Store.embedded();
    const policy = http_config.UploadPolicy{
        .allowed_extensions = &.{".txt"},
        .allowed_content_types = &.{"text/plain"},
    };
    var ctx = Context.init(
        std.testing.io,
        &target,
        request,
        &stats,
        &static_store,
        true,
        .{ .upload = policy, .body_limit = policy.max_request_bytes },
        router.Params.empty(),
        .{},
        .{},
        null,
    );

    try std.testing.expectEqual(middleware.Decision.next, try validate(&ctx));
    const cached = ctx.local(&summary_local_key, Summary).?;
    try std.testing.expectEqual(@as(usize, 1), cached.files);
    try std.testing.expectEqual(cached, try inspect(&ctx));
}
