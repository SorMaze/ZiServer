# ZiServer Gaps and Implementation Roadmap

[简体中文原文](../../zh-CN/architecture/roadmap.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

This list is based on the current source, build options, tests, and public documentation. Priorities are ordered by resource exhaustion or incorrect semantics, protocol blockers, and production operability.

## P0: Resource and protocol correctness

1. **Coalesce same-key page-cache misses (complete)**
   - Fill leader/waiter handling, failure release, fixed-capacity degradation, bounded cancellable/configurable waiting, and the `/stats` `fill_wait_timeouts` metric are implemented.
   - The default wait is 100 ms; after timeout a request renders independently. Only stale-while-revalidate evaluation remains.
2. **True in-connection concurrent HTTP/2 dispatch (complete)**
   - Completed streams are deep-copied and submitted to concurrent Zig `std.Io` tasks. RST/session closure safely cancels and reclaims tasks.
   - The nghttp2 session thread only polls completions, submits responses, and writes sockets; handlers never invoke nghttp2 concurrently. `zibench` supports `--streams-per-connection=1..128`.
3. **Bidirectional streaming (complete)**
   - Strict chunked framing, extensions/trailers, CL/TE ambiguity prevention, `Expect: 100-continue`/417, and a unified absolute body deadline are supported.
   - A unified request Reader and response begin/write/finish API are available. HTTP/1.1 reads the socket/chunk decoder immediately after header routing and flushes chunked output in real time.
   - HTTP/2 starts the handler after HEADERS, passes incremental DATA through a bounded queue, and sends responses through a deferred provider/resume path with backpressure, RST cancellation, limit propagation, and GOAWAY draining.
4. **File persistence and database integration boundary (foundation complete)**
   - Small multipart files support validation followed by an atomic sink. Large uploads support one raw file per request, streaming persistence, random names, collision policy, and optional fsync.
   - A provider-neutral database pool/connection middleware, request cleanup, and PostgreSQL driver adapter are scaffolded. A real PostgreSQL driver, transactions, and metadata compensation remain.

## P1: Protocol and cache completeness

5. **Production HTTP/3**: expand the experimental single-active-connection adapter to CID-demultiplexed multiple connections, native incremental request/response streaming, Retry/address validation, validated path migration, graceful GOAWAY/close, and dedicated load testing. Router/middleware/cache/client-identity integration is complete for the buffered experimental path.
6. **Cache invalidation and representation dimensions**: add path/tag purge, allow only allowlisted `Vary` dimensions, and define multi-process consistency strategy.
7. **Static-resource HTTP semantics**: add ETag/Last-Modified, conditional requests, Range, and precompressed gzip/brotli selection.
8. **Real client identity boundary (complete)**: socket peer addresses flow through HTTP/1.1, HTTP/2, and the experimental HTTP/3 path; forwarded headers are ignored by default; explicit trusted-proxy CIDRs, bounded XFF parsing, normalized client IP, per-IP limiting, and aggregate metrics are integrated. HTTP/3 path migration remains disabled until ngtcp2-validated active-path updates can be propagated safely.

## P2: Production operations and quality gates

9. **Observability**: Prometheus/OpenTelemetry export, latency histograms by protocol/status/route, and an asynchronous structured-log sink.
10. **TLS lifecycle**: finish the SChannel provider, support certificate hot reload/rotation, and cover handshake failure, ALPN, and close paths.
11. **Configuration reload**: use atomic snapshots for safely reloadable timeout, rate-limit, logging, and cache policies; listener addresses and the thread model continue to require restart.
12. **Automated quality gates**: CI for Debug/ReleaseFast, TLS/HTTP2 switches, embedded static mode, and major platforms; parser fuzzing; long-connection and graceful-shutdown regressions; sanitizer/leak checks.

## Recommended order

If upload/database work continues next, prioritize the PostgreSQL driver, metadata transaction, and compensating cleanup. Add an event-driven multipart parser across Reader chunks only when large multi-file uploads are required. Otherwise, continue through P1 starting with production HTTP/3.
