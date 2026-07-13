# Unified Content Extraction and Injection

[简体中文原文](../../zh-CN/guides/content.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

ZiServer uses one representation layer for JSON, XML, HTML, TOML, arbitrary binary data, and application-defined formats:

- `core/http_config.zig` defines only `Representation` and `ContentPolicy`; it does not know parsers, codecs, or business objects.
- `compose/content.zig` validates media types and body bounds, turns a request into a borrowed `Document`, and writes responses according to route policy.
- app declares formats with route layers; handlers only read `Document` or call the unified injector.
- app injects custom codecs through `services.Registry`; core/compose never depend back on app.

`Document` does not copy the body or build XML/HTML/TOML ASTs by default. It stores the representation, custom codec id, and a slice borrowed from the request body, so it must not survive the request. This avoids unbounded allocations and a forced cross-format object model.

## App DSL

Declare extraction and injection together:

```zig
h.post("/api/echo", apiEcho)
    .withLayer(z.layer.content(.{
        .request = .json,
        .response = .json,
        .max_request_bytes = 1024,
    }));
```

Separate layers merge into the same route policy:

```zig
h.post("/content/xml", contentEcho)
    .withLayers(.{
        z.layer.extract(.xml, 4096),
        z.layer.inject(.xml),
        z.layer.cache(.no_cache),
    });
```

The fluent form is also available:

```zig
h.post("/content/toml", contentEcho)
    .extract(.toml, 4096)
    .inject(.toml);
```

All built-in representations share one handler interface:

```zig
pub fn contentEcho(ctx: *z.Context) !void {
    const doc = z.content.document(ctx) orelse
        return error.InvalidContentEncoding;

    // Echo bytes; route response policy chooses the target MIME type.
    try z.content.injectDocument(ctx, .ok, doc, .no_cache);
}
```

JSON may be parsed into a business type only when needed; the typed model stays outside compose:

```zig
const Payload = struct {
    message: []const u8,
    count: i64 = 0,
};

pub fn jsonHandler(ctx: *z.Context) !void {
    const doc = z.content.document(ctx) orelse
        return error.InvalidContentEncoding;
    var parsed = doc.parseJson(Payload, std.heap.page_allocator) catch
        return error.InvalidContentEncoding;
    defer parsed.deinit();

    // Serialize/escape the target bytes first, then inject them uniformly.
    try z.content.inject(ctx, .ok, "{\"ok\":true}\n", .no_cache);
}
```

## Built-in representation behavior

| Representation | Default request media type | Default response media type | `basic` validation |
|---|---|---|---|
| JSON | `application/json`, `application/*+json` | `application/json; charset=utf-8` | Full syntax validation by Zig's standard JSON parser |
| XML | `application/xml`, `text/xml`, `application/*+xml` | `application/xml; charset=utf-8` | UTF-8, controls, basic envelope; rejects DTD/ENTITY |
| HTML | `text/html`, `application/xhtml+xml` | `text/html; charset=utf-8` | UTF-8 and invalid controls; fragments allowed |
| TOML | `application/toml`, `text/toml` | `application/toml; charset=utf-8` | UTF-8 and invalid controls |
| binary | Any or absent | `application/octet-stream` | Opaque bytes |

XML/HTML/TOML `basic` validation is a bounded lexical defense, not a schema, DOM, or complete semantic parser. Strict business semantics require a dedicated library plus limits for node count, nesting depth, and string length. XML rejects `DOCTYPE`/`ENTITY` by default to prevent a downstream parser from accidentally enabling external entities.

Media types may be overridden and framework validation disabled:

```zig
z.layer.content(.{
    .request = .binary,
    .response = .binary,
    .max_request_bytes = 64 * 1024,
    .request_content_type = "application/x-protobuf",
    .response_content_type = "application/x-protobuf",
    .request_validation = .none,
    .response_validation = .none,
})
```

Disable validation only when a bounded downstream decoder exists. The response injector validates format and writes MIME; it never performs implicit JSON/XML/TOML transcoding.

## App-defined codecs

Custom codecs use a nonzero application-unique `u16` id. An extractor may return only a subslice of the request body. Allocation-heavy decoding belongs in the handler and must be released with `Context.registerCleanup` or `defer`.

```zig
const custom_codec_id: u16 = 41;

fn stripEnvelope(_: *z.Context, bytes: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, bytes, "v1:"))
        return error.InvalidContentEncoding;
    return bytes[3..];
}

fn writeEnvelope(
    ctx: *z.Context,
    status: z.Status,
    bytes: []const u8,
    cache: z.CachePolicy,
) !void {
    try ctx.writeBytes(status, "application/x-example", bytes, cache, &.{});
}

const codecs = [_]z.ContentCodec{.{
    .id = custom_codec_id,
    .request_content_types = &.{"application/x-example"},
    .response_content_type = "application/x-example",
    .extract = stripEnvelope,
    .inject = writeEnvelope,
}};

var content_runtime = z.ContentRuntime.init(&codecs) catch unreachable;
var service_entries = [_]z.services.Entry{
    z.content.service(&content_runtime),
};

const routes = z.routes(.{
    h.post("/custom", customHandler).withLayer(z.layer.content(.{
        .request = .custom,
        .response = .custom,
        .max_request_bytes = 4096,
        .request_codec = custom_codec_id,
        .response_codec = custom_codec_id,
    })),
});

pub const registration = registry.register(.{
    .routes = &routes,
    .services = .{ .entries = &service_entries },
});
```

`Runtime.init` rejects id 0 and duplicates. An unregistered id, missing runtime injection, or an extractor returning external memory fails closed with 500 rather than silently falling back to binary.

## Buffering, streaming, and performance boundaries

The unified `Document` is for bounded, buffered bodies; `max_request_bytes` also becomes the route body limit. It is not for huge objects. Routes declaring `streamingBody()` reject the content extractor and must consume `ctx.requestBodyStream()` with a streaming decoder and application limits for total bytes/depth. Large responses similarly use `beginResponseStream()`.

Recommendations:

1. Binary data, HTML fragments, or content already checked by a business decoder may cautiously use `.request_validation = .none`.
2. JSON `basic` validation parses once, and a later typed parse parses again. A throughput-critical handler may disable the first pass and make typed parsing the only validation, but must map parse errors to `InvalidContentEncoding`.
3. Never retain `Document.bytes` after the request. Persistence requires a bounded owned copy or streaming storage.
4. Never inject untrusted HTML into an admin page. `Content-Type`, CSP, and XSS observation do not replace context-aware output encoding.

The default application exposes `/content/json`, `/content/xml`, `/content/html`, `/content/toml`, and `/content/binary`; one echo handler verifies extraction, injection, and MIME behavior.
