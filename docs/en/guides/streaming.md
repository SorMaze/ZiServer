# Bidirectional HTTP/1 and HTTP/2 Streaming

[简体中文原文](../../zh-CN/guides/streaming.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

## Handler API

Consume request bodies in chunks through one Reader:

```zig
const input = ctx.requestBodyStream();
var buffer: [4096]u8 = undefined;
while (true) {
    const count = try input.read(&buffer);
    if (count == 0) break;
    // process buffer[0..count]
}
```

Responses use a begin/write/finish lifecycle:

```zig
var output = try ctx.beginResponseStream(
    .ok,
    z.http_config.ContentType.octet_stream,
    null, // unknown total length
    .no_cache,
);
errdefer output.abort();
try output.write("first\n");
try output.write("second\n");
try output.finish();
```

When `content_length` is set, the total bytes written are checked exactly. Unknown-length HTTP/1.1 responses use chunked framing; HTTP/1.0 uses close-delimited bodies; HTTP/2 uses a deferred DATA provider. HTTP/1 writes flush immediately. HTTP/2 request and response paths each use a fixed-capacity queue; a full queue blocks the producer until the consumer advances, preventing unbounded body accumulation.

## Current protocol integration

| Capability | HTTP/1.1 | HTTP/2 |
| --- | --- | --- |
| Unified request Reader | Integrated | Integrated |
| Chunked handler reads | Reads socket immediately after header routing | Consumes incremental DATA after HEADERS |
| Unified response begin/write/finish | Integrated | Integrated |
| Chunked wire output | Chunked with immediate flush | Deferred DATA provider resumed after writes |
| Dispatch while receiving | Integrated | Integrated |
| Backpressure/cancellation | Socket write blocks; connection closes if the body is not fully consumed | Bounded queues in both directions; RST/close cancels handler and queues |

Streaming routes must explicitly declare `z.layer.streamingBody()`. Ordinary routes still receive a complete `request.body` before middleware/handler execution, while streaming routes consume it through `requestBodyStream()`. HTTP/1 supports Content-Length and an incremental chunked decoder, retaining any bytes prefetched for the next request on the connection. If a handler does not consume the full body, the connection is not reused. HTTP/2 starts the handler after initial HEADERS, queues DATA from callbacks, submits response headers as soon as ready, returns deferred while the response queue is empty, and resumes when new output arrives.

A streaming body does not appear in `request.body`. Therefore full-body XSS scanning, JSON parsing, multipart parsing, and upload inspection do not run automatically on these routes. The streaming handler must perform equivalent incremental validation while consuming the Reader. Adding `streamingBody()` does not preserve buffered security checks.

Ordinary buffered routes retain the global 16 KiB limit. Explicit streaming routes use their DSL route body limit, with a 1 GiB framework ceiling and the body absolute deadline. Queue cancellation wakes blocked producers and consumers; closing an HTTP/2 stream cancels its asynchronous handler. An HTTP/2 body that exceeds its limit only after the response starts and has no Content-Length is reset with `ENHANCE_YOUR_CALM`; limits known before the response still return 413. Under TLS, short polling first checks `SSL_pending()`, then AFD/platform socket readability, and calls `SSL_read` only when data exists, preventing an unfinished TLS read from being interleaved with response writes.

## Runnable examples

- Browser: start the server and open `/stream-demo.html`. `/stream/demo` emits one response chunk every 250 ms; the upload button sends a `ReadableStream` to `/stream/echo`.
- Node.js HTTP/1.1: `node examples/duplex-client.mjs`
- Node.js HTTP/2 + TLS: `node examples/duplex-client.mjs --http2`
- Limit/RST test: `node examples/duplex-client.mjs --http2 --bytes=20480`

The Node example uploads one chunk every 300 ms and should receive the previous echo before sending the next. Browser Fetch commonly exposes half-duplex behavior and may not make the Response visible to JavaScript until upload completes; that is browser API behavior, not server buffering.

## Extension boundaries

1. `streamFileUpload()` already persists one raw file per request atomically. Multipart still requires a complete body; a future event-driven multipart parser may span Reader chunks.
2. nghttp2/session configuration currently controls the HTTP/2 receive window. If large-body limits increase, WINDOW_UPDATE should be tied explicitly to queue low-water marks.
3. Future work may add handler deadlines, per-route queue capacities, slow-consumer metrics, and long cancellation/GOAWAY soak tests.
