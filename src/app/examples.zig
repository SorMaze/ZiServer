const std = @import("std");

const z = @import("../ziserver.zig");

const Context = z.Context;
const form = z.form;
const http_config = z.http_config;

pub const upload_policy: z.UploadPolicy = .{
    .max_request_bytes = http_config.max_form_body_bytes,
    .max_file_bytes = 8 * 1024,
    .max_files = 2,
    .allowed_content_types = &.{ "text/plain", "image/png" },
    .allowed_extensions = &.{ ".txt", ".png" },
};

pub const small_file_upload: z.SmallFileUploadConfig = .{
    .validation = upload_policy,
    .storage = .{
        .directory = "var/uploads/small",
        .naming = .random,
        .collision = .reject,
    },
};

pub const stream_file_upload: z.StreamFileUploadConfig = .{
    .max_request_bytes = 256 * 1024 * 1024,
    .allowed_content_types = &.{http_config.ContentType.octet_stream},
    .allowed_extensions = &.{ ".bin", ".txt", ".png" },
    .storage = .{
        .directory = "var/uploads/large",
        .naming = .random,
        .collision = .reject,
    },
};

pub fn submit(ctx: *Context) !void {
    if (!ctx.request.canSubmitForm()) {
        return error.UnsupportedMediaType;
    }

    if (ctx.request.hasContentType(http_config.ContentType.multipart_form)) {
        const content_type = ctx.request.contentType() orelse return error.UnsupportedMediaType;
        const summary = form.parseMultipart(content_type, ctx.request.body) catch return error.InvalidFormEncoding;
        var body_buffer: [220]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buffer,
            "{{\"status\":\"accepted\",\"received\":{d},\"parsed\":true,\"multipart\":true,\"parts\":{d},\"fields\":{d},\"files\":{d},\"part_bytes\":{d}}}\n",
            .{
                ctx.request.body.len,
                summary.parts,
                summary.fields,
                summary.files,
                summary.bytes,
            },
        );
        try ctx.json(.accepted, body);
        return;
    }

    const declared_length = ctx.request.contentLength() orelse ctx.request.body.len;
    var decode_buffer: [http_config.max_form_body_bytes]u8 = undefined;
    const summary = form.parseUrlEncoded(ctx.request.body, &decode_buffer) catch return error.InvalidFormEncoding;

    var body_buffer: [240]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"status\":\"accepted\",\"received\":{d},\"declared\":{d},\"parsed\":true,\"fields\":{d},\"empty_names\":{d},\"decoded_bytes\":{d}}}\n",
        .{
            ctx.request.body.len,
            declared_length,
            summary.fields,
            summary.empty_names,
            summary.decoded_bytes,
        },
    );

    try ctx.json(.accepted, body);
}

const EchoJson = struct {
    message: []const u8 = "",
    count: i64 = 0,
};

pub fn apiEcho(ctx: *Context) !void {
    var api = z.api.call(ctx);
    defer api.deinit();
    const input = try api.json(EchoJson);
    if (input.message.len > 512) return error.PayloadTooLarge;

    const EchoResponse = struct {
        status: []const u8,
        received: usize,
        message: []const u8,
        count: i64,
    };
    var output: [3400]u8 = undefined;
    try api.respondJson(.ok, EchoResponse{
        .status = "ok",
        .received = api.bodyBytes(),
        .message = input.message,
        .count = input.count,
    }, &output, .no_cache);
}

/// One handler can serve every built-in representation. The route DSL chooses
/// both the extracted request format and injected response format.
pub fn contentEcho(ctx: *Context) !void {
    const document = z.content.document(ctx) orelse return error.InvalidContentEncoding;
    try z.content.injectDocument(ctx, .ok, document, .no_cache);
}

pub fn upload(ctx: *Context) !void {
    const summary = try z.upload.inspect(ctx);
    var body_buffer: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"status\":\"accepted\",\"stored\":false,\"parts\":{d},\"fields\":{d},\"files\":{d},\"file_bytes\":{d}}}\n",
        .{ summary.parts, summary.fields, summary.files, summary.file_bytes },
    );
    try ctx.json(.ok, body);
}

pub fn uploadStored(ctx: *Context) !void {
    const stored = z.upload_storage.result(ctx) orelse return error.UploadStorageFailed;
    var body_buffer: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"status\":\"stored\",\"stored\":true,\"files\":{d},\"file_bytes\":{d}}}\n",
        .{ stored.files, stored.bytes },
    );
    try ctx.json(.ok, body);
}

pub fn streamEcho(ctx: *Context) !void {
    // Echo preserves a declared request length. Chunked/unknown input remains
    // an unknown-length response and exercises live framing on both protocols.
    var output = try ctx.beginResponseStream(.ok, http_config.ContentType.octet_stream, ctx.request.contentLength(), .no_cache);
    errdefer output.abort();
    var buffer: [1024]u8 = undefined;
    const input = ctx.requestBodyStream();
    while (true) {
        const count = try input.read(&buffer);
        if (count == 0) break;
        try output.write(buffer[0..count]);
    }
    try output.finish();
}

pub fn streamChunks(ctx: *Context) !void {
    var output = try ctx.beginResponseStream(.ok, http_config.ContentType.plain, null, .no_cache);
    errdefer output.abort();
    try output.write("chunk-one\n");
    try output.write("chunk-two\n");
    try output.write("chunk-three\n");
    try output.finish();
}

pub fn streamDemo(ctx: *Context) !void {
    var output = try ctx.beginResponseStream(.ok, http_config.ContentType.plain, null, .no_cache);
    errdefer output.abort();
    var buffer: [96]u8 = undefined;
    for (0..6) |index| {
        const chunk = try std.fmt.bufPrint(&buffer, "chunk={d} server_ns={d}\n", .{ index + 1, std.Io.Clock.awake.now(ctx.io).nanoseconds });
        try output.write(chunk);
        if (index != 5) try std.Io.sleep(ctx.io, .fromMilliseconds(250), .awake);
    }
    try output.finish();
}

pub fn cacheArena(ctx: *Context) !void {
    const prefix = "/cache-arena/";
    const strategy = if (std.mem.startsWith(u8, ctx.request.path, prefix))
        ctx.request.path[prefix.len..]
    else
        "unknown";
    var body_buffer: [192]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"arena\":\"page-cache\",\"strategy\":\"{s}\",\"path\":\"{s}\"}}\n",
        .{ strategy, ctx.request.path },
    );
    try ctx.json(.ok, body);
}
