# User Upload Interception and Handling

[简体中文原文](../../zh-CN/guides/upload.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

Upload support has three explicit route policies:

- `z.layer.upload(...)`: parse and validate small `multipart/form-data` without persistence.
- `z.layer.smallFileUpload(...)`: validate a complete multipart body, then persist one or more small files atomically.
- `z.layer.streamFileUpload(...)`: one file per request, written to a temporary file as it arrives and atomically committed on completion.

Only the last two DSL forms declare disk side effects. Plain `upload(...)` only checks. A handler may also avoid disk layers and choose object storage or an asynchronous job.

Upload policy constructors live in `compose/layers.zig`; the generic routing DSL only merges `Layer` values and does not know upload, JSON, or XSS details.

## Current capabilities

### Validate without persistence

```zig
const policy: z.UploadPolicy = .{
    .max_request_bytes = 16 * 1024,
    .max_file_bytes = 8 * 1024,
    .max_files = 2,
    .allowed_content_types = &.{ "text/plain", "image/png" },
    .allowed_extensions = &.{ ".txt", ".png" },
};

h.post("/upload", uploadHandler)
    .withLayers(.{
        z.layer.upload(policy),
        z.layer.cache(.no_cache),
        z.layer.rate(.strict),
    });

pub fn uploadHandler(ctx: *z.Context) !void {
    const summary = try z.upload.inspect(ctx);
    _ = summary;
    try ctx.json(.ok, "{\"stored\":false}\n");
}
```

### Persist small multipart files

```zig
const small_upload: z.SmallFileUploadConfig = .{
    .validation = .{
        .max_request_bytes = 16 * 1024,
        .max_file_bytes = 8 * 1024,
        .max_files = 2,
        .allowed_content_types = &.{ "text/plain", "image/png" },
        .allowed_extensions = &.{ ".txt", ".png" },
    },
    .storage = .{
        .directory = "var/uploads/small",
        .naming = .random,
        .collision = .reject,
        .create_directory = true,
        .sync_on_finish = false,
    },
};

h.post("/upload/store", storedHandler)
    .withLayer(z.layer.smallFileUpload(small_upload));
```

Small files are fully buffered and multipart-validated before temporary-file writes. `.random` uses a 128-bit random hexadecimal name and keeps only a validated extension; `.original` uses a safety-checked original name. `.reject` never overwrites; `.replace` performs atomic replacement. `sync_on_finish` fsyncs the file before commit for stronger durability at significant latency cost. The parent directory is not additionally fsynced, so absolute post-power-loss directory-entry durability is not claimed.

### Stream large files to disk

```zig
const large_upload: z.StreamFileUploadConfig = .{
    .max_request_bytes = 256 * 1024 * 1024,
    .filename_header = "X-Upload-Filename",
    .allowed_content_types = &.{z.http_config.ContentType.octet_stream},
    .allowed_extensions = &.{ ".bin", ".txt", ".png" },
    .storage = .{
        .directory = "var/uploads/large",
        .naming = .random,
        .collision = .reject,
    },
};

h.put("/upload/stream", storedHandler)
    .withLayer(z.layer.streamFileUpload(large_upload));

pub fn storedHandler(ctx: *z.Context) !void {
    const stored = z.upload_storage.result(ctx) orelse return error.UploadStorageFailed;
    _ = stored;
    try ctx.json(.ok, "{\"stored\":true}\n");
}
```

The large-file protocol carries one raw file body per request. It defaults to `Content-Type: application/octet-stream`; `X-Upload-Filename` supplies the display name. It is intentionally not streaming multipart, avoiding delimiter parsing across DATA/chunk boundaries and avoiding body reassembly in memory. HTTP/1.1 supports Content-Length and chunked transfer; HTTP/2 uses a bounded DATA queue and socket/flow-control backpressure.

Runnable clients:

```powershell
node examples/upload-client.mjs
node examples/upload-client.mjs --http2
```

The interceptor checks request method and multipart boundary; multipart structure, part headers, and `Content-Disposition`; request/file/count bounds; MIME and extension allowlists; empty or missing files; and dangerous names such as `../a.txt`, absolute/backslash paths, control characters, Windows device names, or leading/trailing dots and spaces.

`z.upload.inspect(ctx)` returns part, field, file, and byte totals. Middleware calls it first and caches the Summary in request-local storage, so the handler does not rescan. `z.upload.inspectRequest()` is the context-free low-level entry for standalone parsing, tests, or custom pipelines. Normal handlers should prefer `inspect(ctx)`.

After validation, app may iterate `z.upload.MultipartIterator` and read each `Part.name`, `filename`, `content_type`, and `data`. The default `/upload` validates only, `/upload/store` demonstrates small-file persistence, and `PUT /upload/stream` demonstrates large-file streaming.

## Current performance

On 2026-07-13, local Windows ReleaseFast with access logging disabled and eight HTTP/1.1 connections benchmarked `/upload` using multipart with a 2 KiB `.txt` file:

| Implementation | req/s | Mean latency | Failures |
| --- | ---: | ---: | ---: |
| Middleware and handler each parse once | 113,532 | 69.7 us | 0 |
| Reuse one request-local parse, median of three runs | 117,689 | 67.0 us | 0 |

Representative throughput improved about 3.7%. This measures small-file in-memory parsing and policy validation only, excluding disk, object storage, virus scanning, and large-file streaming I/O.

The same HTTP/2 load passed functional TLS 1.3 + ALPN `h2` validation with zero failures for one stream. Under many concurrent body streams, DATA flow-control/session polling costs are higher than bodyless GET, and a few read timeouts still appeared during final drain, so no potentially misleading stable HTTP/2 upload throughput is published.

## Security boundary

Browser-supplied filename, extension, and `Content-Type` are untrusted. Before durable publication:

1. generate a random server-side storage name and keep the encoded original only as display metadata;
2. identify type from file signatures rather than MIME/extension alone;
3. write outside the web root into an isolated temporary directory with exclusive creation;
4. run virus scanning or asynchronous content review before making it downloadable;
5. enforce user, tenant, and total-storage quotas;
6. force `Content-Disposition: attachment` and disable MIME sniffing on download.

Buffered routes retain a 16 KiB hard limit. Only explicit streaming routes may raise the route limit, up to a 1 GiB framework ceiling. Large-file writes never retain the full body; failure, cancellation, or limits trigger atomic-file temporary cleanup. Each file commit is atomic, but multi-file multipart is not a cross-file transaction: if the second file fails, an already committed first file is not rolled back.

Persistence is only the receive stage. Store original filename, owner, hash, review state, and final object key in a database; never expose the file before scanning/review succeeds. See the [database middleware interface](database.md).
