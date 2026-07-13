# ZiServer

English | [简体中文](README.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese [`README.md`](README.md) is authoritative.

A high-concurrency HTTP server built with the Zig version currently installed on the development machine. ZiServer provides plaintext HTTP/1.0/1.1, TLS 1.2/1.3, HTTP/2 over ALPN, an experimental native HTTP/3 path, bounded streaming, middleware/route DSLs, dynamic page caching, trusted client identity, and graceful shutdown.

Detailed documentation is available in the [documentation center](docs/README.en.md).

## Platform support and current limits

**Windows x86_64** is the only platform currently validated through builds, functional regressions, HTTP/2 soak testing, and memory-stability checks. Windows uses vcpkg-provided OpenSSL/nghttp2 and includes the Windows-specific AFD cancellable socket-read path.

Linux, macOS, and other targets retain some portable code and `std.Io` deadline paths, but have not received equivalent CI, protocol regression, long-running load testing, or release validation. They must not currently be presented as supported platforms. The Windows SChannel provider is still a placeholder; the validated TLS/HTTP/2 combination is OpenSSL + nghttp2. Native HTTP/3 remains an experimental single-connection implementation without production multi-connection, GOAWAY, or complete router/middleware integration.

## Quick start

The default build compiles the OpenSSL TLS and nghttp2 providers. On Windows, install dependencies with vcpkg and set one supported vcpkg-root environment variable:

```powershell
vcpkg install openssl:x64-windows nghttp2:x64-windows ngtcp2[openssl]:x64-windows nghttp3:x64-windows
$env:VCPKG_ROOT="D:\path\to\vcpkg"
```

Start the plaintext development server:

```powershell
zig build run
```

Or start local TLS 1.3 with the ignored development certificate:

```powershell
zig build run -- --tls-cert=.dev-certs/localhost.pem --tls-key=.dev-certs/localhost.key --tls-min=1.3 --host=127.0.0.1 --canonical-host=localhost
```

Open <http://127.0.0.1:18080/> or <https://localhost:18443/>. The `localhost` certificate is for the local machine only; do not combine it with `--host=0.0.0.0` as a LAN TLS configuration.

The HTTP/2 provider is compiled by default, but without a certificate the process listens only for plaintext HTTP/1.1 and keeps HTTP/2 in `reject` mode. Once a certificate and key are configured, the same process listens on both `http://127.0.0.1:18080/` and `https://127.0.0.1:18443/`; HTTP/2 is enabled on HTTPS automatically. Repeating `-Dtls=openssl -Dhttp2=nghttp2` is unnecessary.

The `/` route is rendered dynamically. Static assets remain available under `/assets/`. `/stats` is a passive one-shot JSON endpoint that includes connection, client identity, rate-limit, and page-cache metrics.

The default static mode is filesystem. `zig build` installs `src/public/` to `zig-out/public/` and replaces a target file only when its content changes. `zig build run` uses `src/public/` during development. To run an installed binary:

```powershell
zig build
Set-Location zig-out
bin\ziserver.exe

# Or from the repository root
zig-out\bin\ziserver.exe --static-dir=zig-out\public
```

## Runtime options

### Listener and concurrency

- `--host=127.0.0.1`: bind address.
- `--port=N`: legacy primary-port option; HTTPS when certificates exist, otherwise HTTP.
- `--http-port=18080`: plaintext listener port.
- `--https-port=18443`: HTTPS listener port when certificates are configured; must differ from HTTP.
- `--acceptors=N`: total accept threads, automatic by default, maximum 8; dual listeners receive at least one each.
- `--workers=N`: fixed connection-worker count, automatic by default, maximum 128.
- `--queue=N`: capacity for accepted connections awaiting workers.
- `--shards=N`: ordinary connection-queue shards, automatic by default, maximum 4.
- `--backlog=N`: kernel listen backlog, default 16384.
- `--keep-alive=N`: connection reuse baseline, default 1000. HTTP/1.1 closes exactly at the limit; HTTP/2 reserves up to 128 already accepted streams for drain before GOAWAY. `0` disables reuse.

### Slow-client protection and shutdown

- `--tls-handshake-timeout=MS`: absolute TLS handshake timeout, default 10000; `0` disables.
- `--header-timeout=MS`: absolute header timeout, default 10000; `0` disables.
- `--body-timeout=MS`: absolute body timeout, default 30000; `0` disables.
- `--keep-alive-timeout=MS`: HTTP/1.1 and HTTP/2 idle timeout, default 15000; `0` disables.
- `--shutdown-grace=MS`: maximum drain after Ctrl+C, SIGINT, or SIGTERM, default 30000.

Slow-client defense combines absolute phase deadlines with a read-fragment budget. Sending one byte at a time never extends the current phase. Header/body timeout returns 408 when possible; idle connections close silently. On Windows, the project uses a cancellable `NtDeviceIoControlFile(AFD.RECEIVE)` event-wait path rather than Zig's `std.Io.Threaded`/IOCP socket timeout support. It has a local slow-header regression, but should be revalidated after Zig or Windows upgrades. Other platforms use `std.Io` deadlines.

Shutdown first marks the server stopping and stops dispatch, wakes/exits acceptors, and closes listeners. HTTP/2 sends `NO_ERROR` GOAWAY; HTTP/1.1 accepts no next keep-alive request. Remaining connections drain until the grace deadline, after which their sockets are shut down. `shutdown_complete` reports `forced_connections`.

### Client identity and rate limiting

- `--rate-limit-relaxed=N` / `--rate-limit-strict=N`: requests per second per normalized client IP; default 0 (unlimited).
- `--rate-limit-capacity=N`: maximum `(client IP, policy)` entries, default 65536, maximum 1048576.
- `--rate-limit-shards=N`: lock shards, default 64, maximum 256 and no greater than capacity.
- `--rate-limit-idle-ttl=MS`: idle-entry retention, default 600000, minimum 1000.
- `--client-ip-header=none|x-forwarded-for`: forwarded identity mode, default `none`.
- `--trusted-proxy=CIDR`: repeatable direct-proxy network allowed to supply XFF; at least one is required when XFF is enabled.
- `--forwarded-max-hops=N`: maximum XFF addresses, default 16, range 1–32.

Forwarded headers are ignored by default. See [trusted-proxy deployment](docs/en/operations/client-ip-rate-limit.md) before enabling XFF; a public client must never be able to bypass the proxy and connect directly to the ZiServer port.

### Host and security policy

- `--canonical-host=HOST`: fixed hostname/IP for protocol-correction redirects; no scheme, port, path, or userinfo.
- `--allowed-host=HOST`: repeatable Host allowed to trigger protocol correction; the canonical host is implicitly allowed.
- `--xss-mode=off|observe|block`: server-wide minimum XSS policy, default off; routes may strengthen but never weaken it.
- `--xss-scan-query=on|off` / `--xss-scan-body=on|off`: scan targets, both on by default when policy is active.
- `--auth-token=TOKEN`: Bearer token credential.
- `--api-key=KEY`: `X-API-Key` credential.

XSS input detection is defense in depth. It does not replace context-aware output encoding, JSON serialization, or CSP.

### Logging and statistics

- `--stats=on|off`, `--no-stats`: realtime atomic statistics, on by default.
- `--access-log=on|off`, `--no-access-log`: per-request access logging, on by default.
- `--log-level=trace|debug|info|warn|error`: minimum level, default `info`; 4xx is `warn`, 5xx is `error`.
- `--log-format=pretty|json`: PowerShell-friendly text or strict JSON Lines.
- `--log-color=auto|on|off`: ANSI color policy; `auto` enables color only for interactive output.

Pretty logs distinguish the server page-cache result from the client-visible response cache policy:

```text
[INFO] 1783923412704 HTTP[http/1.1] GET / 200 359us bytes=10234 client=127.0.0.1 source=peer cache=FILL enabled=yes response_cache=api-short
[INFO] 1783923412730 HTTP[http/1.1] GET / 200 120us bytes=10234 client=127.0.0.1 source=peer cache=HIT enabled=yes response_cache=api-short
[WARN] 1783923412744 HTTP[http/1.1] GET /missing 404 519us bytes=28 client=127.0.0.1 source=peer cache=BYPASS enabled=yes response_cache=no-cache
```

`cache` is `OFF`, `BYPASS`, `MISS`, `FILL`, or `HIT`; `enabled` reports whether the page-cache store exists; `response_cache` is the policy sent to browsers/proxies. For log collectors:

```powershell
zig-out\bin\ziserver.exe --log-format=json --log-color=off 2> .\ziserver.jsonl
```

JSON fields include `time_unix_ms`, `level`, `event`, `protocol`, `method`, `path`, `status`, `body_bytes`, `duration_us`, `cache_enabled`, `page_cache`, and `response_cache`.

### Page cache

- `--page-cache=on|off`, `--no-page-cache`: dynamic page cache, on by default.
- `--page-cache-capacity=N`: total entries, default 256, range 1–16384.
- `--page-cache-shards=N`: lock shards, default 16, range 1–64 and no greater than capacity.
- `--page-cache-max-body=BYTES`: per-entry body limit, default 262144, maximum 1048576.
- `--page-cache-ttl-percent=N`: global DSL TTL scaling, default 100, range 1–1000.
- `--page-cache-header=on|off`: emit `X-Page-Cache: HIT`, off by default.
- `--page-cache-fill-wait-timeout=MS`: maximum same-key miss coalescing wait, default 100; `0` bypasses immediately.

Use `z.layer.pageCache(...)` only for deterministic anonymous GET pages with meaningful generation cost. `z.layer.cache(...)` controls browser/proxy `Cache-Control`; the two layers have separate responsibilities. Query strings are part of the key. Authentication, Cookie, Origin, Range, `no-cache/no-store`, and custom response headers conservatively bypass. Watch `/stats` hit ratio, evictions, bytes, fill leaders/waits/hits/bypasses/timeouts. Full behavior is documented in [page-cache design](docs/en/architecture/page-cache.md).

For throughput tests, use `--no-access-log --page-cache-header=off` so synchronous logs and diagnostic headers are not counted as generation cost.

### Static, TLS, HTTP/2, and HTTP/3

- `--static=embedded|filesystem`: static provider mode, default selected at build time.
- `--static-dir=DIR`: filesystem static root, default `public`.
- `--tls=off|terminate`: TLS termination. It defaults off without certificates and terminate when a certificate/key is configured.
- `--tls-cert=FILE` / `--tls-key=FILE`: certificate chain and private key; CLI overrides `ZISERVER_TLS_CERT` / `ZISERVER_TLS_KEY`.
- `--tls-min=1.2|1.3`: minimum version; default permits TLS 1.2 and prefers 1.3.
- `--http2=off|reject|on`: HTTP/2 mode. Default is reject without TLS and on with certificates. h2c remains closed.
- `--http3=off|advertise`: advertise h3 through `Alt-Svc`; requires TLS. With `-Dhttp3=nghttp3`, native QUIC/HTTP/3 is started; otherwise an external proxy must own the endpoint.
- `--http3-port=N`: QUIC/UDP port advertised in Alt-Svc, default 443.

CLI takes precedence over corresponding environment variables. Important groups include `ZISERVER_LOG_*`, `ZISERVER_PAGE_CACHE_*`, `ZISERVER_XSS_*`, `ZISERVER_CLIENT_IP_HEADER`, `ZISERVER_TRUSTED_PROXIES`, `ZISERVER_FORWARDED_MAX_HOPS`, `ZISERVER_RATE_LIMIT_*`, `ZISERVER_CANONICAL_HOST`, and `ZISERVER_ALLOWED_HOSTS`.

## LAN binding and redirect safety

Plaintext LAN access:

```powershell
zig build run -- --host=0.0.0.0 --http-port=18080 --https-port=18443
```

LAN TLS requires a certificate whose SAN includes the real LAN IP/name plus a safe redirect Host policy:

```powershell
zig build run -- --host=0.0.0.0 --http-port=18080 --https-port=18443 --tls-cert=.dev-certs/lan.pem --tls-key=.dev-certs/lan-key.pem --tls-min=1.3 --allowed-host=192.168.31.47 --allowed-host=server.lan
```

Use `--canonical-host=server.lan` for one public name or repeat `--allowed-host` for several. Wildcard detection uses parsed address semantics, so all spellings of the IPv6 unspecified address are equivalent. A wildcard TLS bind without canonical/allowed policy fails startup to prevent attacker-controlled redirect `Location`. A concrete bind address is the fallback when no policy is given. See [redirect Host policy](docs/en/operations/redirect-host-policy.md).

On Windows, a policy or reserved port may make a `0.0.0.0` bind fail with `ACCESS_DENIED`. Validate on `127.0.0.1:18080` first or run the public bind from an elevated PowerShell.

## Release builds and dependencies

```powershell
$env:ZIG_GLOBAL_CACHE_DIR="$PWD\.zig-cache\global"
zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/ziserver.exe`.

```powershell
# Runtime files, default
zig build -Dstatic=filesystem

# Single-file static assets
zig build -Dstatic=embedded

# Default OpenSSL + nghttp2
zig build

# HTTP/1.1 + HTTP/2 + experimental native HTTP/3
zig build -Dhttp3=nghttp3

# Minimal HTTP/1 without OpenSSL/nghttp2
zig build -Dtls=none

# Placeholder provider; HTTP/2 is disabled with non-OpenSSL TLS
zig build -Dtls=schannel
```

| Library | vcpkg package | Purpose | Required |
|---|---|---|---|
| OpenSSL | `openssl:x64-windows` | TLS 1.2/1.3, crypto, ALPN | Default |
| nghttp2 | `nghttp2:x64-windows` | HTTP/2 frames, HPACK, streams | Default |
| ngtcp2 | `ngtcp2[openssl]:x64-windows` | QUIC transport | `-Dhttp3=nghttp3` |
| ngtcp2_crypto_openssl | installed with ngtcp2 | QUIC/OpenSSL bridge | `-Dhttp3=nghttp3` |
| nghttp3 | `nghttp3:x64-windows` | HTTP/3 frames, QPACK, streams | `-Dhttp3=nghttp3` |

C adapters expose stable extern functions to Zig. There are no pure-Zig third-party dependencies beyond the standard library. vcpkg roots are resolved in this order: `-Dvcpkg-root`, `VCPKG_ROOT`, `VCPKG_INSTALLATION_ROOT`, `VCPKG_HOME`, `Vcpkg_home`. Runtime DLLs are installed next to `ziserver.exe`.

Certificates and keys are loaded at process startup and never compiled into the executable. Runtime precedence is CLI > environment > absent. Replacement currently requires restart; hot reload is not implemented.

## Architecture

The runtime is dual listener + acceptors + sharded bounded connection queues + a fixed worker pool. The strict dependency direction is:

```text
app -> ziserver public facade -> compose -> core
```

- `src/main.zig`: minimal entry point; injects the concrete application factory into core.
- `src/ziserver.zig`: public application facade exporting the DSL, `Context`, `ApplicationBundle`, HTTP types, and compose builders.
- `src/core/`: protocol/runtime mechanisms only—listeners, TLS, HTTP/1/2/3, parsing, routing, streaming, queues, cache storage, statistics, deadlines, shutdown.
- `src/compose/`: reusable application policy—DSL, middleware stack, auth, CORS, XSS, rate limiting, content codecs, uploads, database borrowing, and page cache.
- `src/app/`: replaceable handlers, templates, endpoint responses, and route registration.

Core never imports compose/app; compose never imports app; app accesses framework capabilities through `ziserver.zig`. See [layer boundaries](docs/en/architecture/overview.md) and the [roadmap](docs/en/architecture/roadmap.md).

## Routing and application DSL

The DSL compiles user declarations to `router.Entry` and uses the existing router/pipeline:

```zig
const z = @import("../ziserver.zig");
const Context = z.Context;

pub const registry = z.handlers(.{ home, submit, apiEcho, uploadHandler });

const public_pages = z.group(.{
    .layers = z.layers(.{
        z.layer.cache(.api_short),
        z.layer.pageCache(.standard),
        z.layer.cors(.public_read),
        z.layer.rate(.relaxed),
    }),
    .routes = .{
        registry.get("/", home),
        registry.get("/about", home),
    },
});

const routes = z.routes(.{
    public_pages,
    registry.post("/api/echo", apiEcho).withLayers(.{
        z.layer.content(.{
            .request = .json,
            .response = .json,
            .max_request_bytes = 1024,
        }),
        z.layer.cors(.public_form),
        z.layer.rate(.strict),
    }),
});

pub const registration = registry.register(.{ .routes = &routes });

pub fn home(ctx: *Context) !void {
    try ctx.html(.ok, "<h1>Hello ZiServer</h1>");
}
```

Feature-layer constructors live in `compose/layers.zig`; the generic DSL merges `router.Options`. Middleware flags combine with bitwise OR. Prefer `content()` or composable `extract()` / `inject()` for new routes. Use `smallFileUpload()` for buffered multipart atomic persistence and `streamFileUpload()` for one-file-per-request streaming persistence. Detailed guides cover [content](docs/en/guides/content.md), [uploads](docs/en/guides/upload.md), [streaming](docs/en/guides/streaming.md), and [database middleware](docs/en/guides/database.md).

The typed JSON API uses `apiJson()` and `z.api.call(ctx)` for one typed parse and fixed-buffer serialization:

```zig
const Input = struct { message: []const u8 = "", count: i64 = 0 };

pub fn echo(ctx: *z.Context) !void {
    var api = z.api.call(ctx);
    defer api.deinit();
    const input = try api.json(Input);

    var output: [1024]u8 = undefined;
    try api.respondJson(.ok, .{
        .ok = true,
        .message = input.message,
        .count = input.count,
    }, &output, .no_cache);
}
```

Use `apiJson(max_bytes)` when the handler itself parses/responds through `z.api`. Use content extract/inject for transparent forwarding, generic format validation, or custom codecs.

Application resources are returned in `ApplicationBundle`; core calls the optional application destructor before core caches, limiters, and the process allocator are released. Partially initialized factories should use `errdefer`.

No default auth credentials exist. Configure `ZISERVER_BEARER_TOKEN` / `ZISERVER_API_KEY` or `--auth-token` / `--api-key`; otherwise protected routes remain 401.

## Request and protocol behavior

The body parser supports strict decimal `Content-Length`, bounded `Transfer-Encoding: chunked`, and `Expect: 100-continue`. CL/TE conflicts, duplicate framing, invalid chunks/trailers, and unsupported transfer codings are rejected. Buffered bodies have a 16 KiB hard limit. Explicit streaming routes use a DSL body limit up to the 1 GiB framework ceiling. Chunk metadata has an additional fixed 8 KiB ceiling; body paths share an absolute deadline and read-count budget.

`z.layer.streamingBody()` and `z.layer.streamFileUpload()` dispatch immediately after headers. HTTP/1 handlers pull directly from the socket/chunk decoder. HTTP/2 handlers consume a bounded DATA queue after HEADERS. The unified response lifecycle produces HTTP/1.1 chunked output or HTTP/2 deferred DATA with backpressure and cancellation.

The active protocol surface is plaintext HTTP/1.0/1.1, HTTPS/HTTP/1.1, HTTPS/HTTP/2, and native HTTPS/HTTP/3 when compiled with `-Dhttp3=nghttp3`:

- HTTP and HTTPS listeners share queues, workers, router, middleware, static resources, and metrics.
- Wrong-port protocol correction returns 308 while preserving path/query; Host comes from canonical/allowed/fallback policy before router/middleware.
- OpenSSL permits TLS 1.2 by default and prefers TLS 1.3; `--tls-min=1.3` enforces 1.3-only. TLS 1.3 prefers X25519 and AEAD suites; TLS 1.2 keeps ECDHE + AEAD only. 0-RTT is disabled to avoid replay.
- h2c and `HTTP/2.0` request lines return 505. ALPN selects `h2` only when TLS termination and nghttp2 are active; clients otherwise fall back to HTTP/1.1.
- HTTP/2 advertises a 4 KiB HPACK table, 128 concurrent streams, a 256 KiB initial per-stream receive window, and a 4 KiB header-list limit. Bodies still flow through a bounded 16 KiB queue.
- HTTP/2 requests are copied into Zig concurrent tasks while all nghttp2 session submission/socket writes stay on one session thread. Stream-local 431/413, RST cancellation, early-response DATA drain, request-count GOAWAY, and graceful shutdown are supported.
- Native HTTP/3 currently uses a single-connection mode through ngtcp2/nghttp3 and OpenSSL QUIC TLS 1.3. Multi-connection production hardening, GOAWAY, and full router integration remain roadmap items.

An external Caddy, nginx, HAProxy, or Envoy may continue to terminate TLS/ALPN/HTTP2/HTTP3 and forward HTTP/1.1 to ZiServer.

## Built-in routes

- Dynamic pages: `/`, `/about`, `/products`, `/security`, `/contact`, `/site`, `/site/:page`.
- Static fallback/assets: `/index.html`, `/assets/*`.
- Operations: `/health`, `/stats`, authenticated `/admin/stats`.
- Forms/APIs: `POST /submit`, `POST /api/echo`, `/content/{json,xml,html,toml,binary}`.
- Uploads: `POST /upload` (validate only), `POST /upload/store` (small multipart to disk), `PUT /upload/stream` (large raw stream to disk).
- Streaming: `POST /stream/echo`, `GET /stream/chunks`, `GET /stream/demo`, `/stream-demo.html`.

## Benchmarks and stability

Build the server and bundled `zibench`:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR="$PWD\.zig-cache\global"
zig build -Dartifact=all -Doptimize=ReleaseFast
zig build bench -- --threads=16 --duration=30
zig build bench -- --https --threads=16 --duration=30
zig build bench -- --http2 --threads=16 --duration=30
```

`zibench` supports HTTP/1.1, TLS + ALPN HTTP/1.1, and native HTTP/2 with reuse or one-request connections. Key options include `--path`, `--body`, `--content-type`, `--threads`, `--duration`, `--keep-alive`, `--https`, `--http2`, `--streams-per-connection=1..128`, `--timeout`, `--tls-verify`, and `--json`.

### Current local ReleaseFast results

Local Windows `/about`, access logging disabled, isolated ports (2026-07-12). These numbers are relative evidence for this revision, not cross-machine promises:

| Mode | Connections | Page cache | req/s | Failures |
|---|---:|---|---:|---:|
| HTTP/1.1 | 16 | off | ~144k | 0 |
| HTTP/1.1 | 16 | on | ~147k | 0 |
| HTTP/2 before optimization | 8 | off | ~18.1k | 0 |
| HTTP/2 after optimization | 8 | off | ~35.6k | 0 |
| HTTP/2 after optimization | 8 | on | ~36.7k | 0 |
| HTTPS/1.1 | 8 | on | ~64.8k | 0 |

The HTTP/2 optimization borrowed static default security headers and transferred captured-body ownership directly to nghttp2 streams, removing eight small header allocations and a second body allocation/copy per request. Median no-cache throughput improved about 96.5%; mean latency fell from ~441 µs to ~224 µs. With cache on, 1/4/8/16/32 connections produced approximately 6.9k/23.1k/35.8k/55.3k/60.0k req/s; 32 connections maximized throughput but mean latency was ~530 µs.

On 2026-07-13, `/api/echo` with a 30-byte JSON body, TLS 1.3, page cache/access log disabled produced ~108.8k req/s on eight HTTP/1.1 keep-alive connections. Node HTTP/2 at one connection × eight streams produced 87,031 successful requests, zero HTTP/session errors, and ~17.3k req/s.

Small multipart parsing of one 2 KiB `.txt` file improved from 113,532 req/s / 69.7 µs to a three-run median 117,689 req/s / 67.0 µs after reusing the request-local Summary: about 3.7%, with zero failures. This excludes persistence, object storage, and scanning.

### HTTP/2 soak and memory stability

Use the dependency-free Node soak plus PowerShell process monitor:

```powershell
$server = Start-Process .\zig-out\bin\ziserver.exe -ArgumentList @(
  '--http-port=18090', '--https-port=18490',
  '--tls-cert=.dev-certs/localhost.pem', '--tls-key=.dev-certs/localhost.key',
  '--tls-min=1.3', '--http2=on', '--page-cache=off', '--no-access-log'
) -PassThru
.\scripts\monitor-process.ps1 -ProcessId $server.Id -DurationSeconds 135 -OutFile .\soak.csv
node .\scripts\http2-soak.mjs --origin=https://127.0.0.1:18490 --path=/about --connections=8 --streams=8 --duration=120
Stop-Process -Id $server.Id
```

The 2026-07-13 ReleaseFast rerun completed 1,917,123 successful `/about` requests in 120 seconds at 8 connections × 8 streams (~15.97k req/s), with zero HTTP status/session errors. After warm-up, private memory/handles/threads moved from 1.365 GiB/189/85 to a high-water 1.383 GiB/191/86 and converged to 1.380 GiB/175/86; no sustained growth was observed. An earlier 120-second run had one status error that did not reproduce after status-code collection was added, so this is not a universal zero-error claim.

In a separate ReleaseSafe sequence, the first heavy HTTP/2 round added about 66 MiB of private memory for thread pools, TLS/nghttp2, and allocator high-water expansion. Nine later rounds fluctuated within about 1 MiB, while handle/thread counts stayed stable. Alternating HTTP/1.1 samples also stabilized. This is load-sampling evidence, not a replacement for Application Verifier, Dr. Memory, sanitizers, or longer soak tests.

`zibench` fixed-duration HTTP/2 tests may report one `ReadTimeout` per worker at the stopping boundary even when server session logs show no `http2_session_failed`. Keep the signal for investigation, but cross-check with the Node script's complete status/session accounting.

External tools can also be used:

```powershell
wrk -t8 -c1000 -d30s http://127.0.0.1:18080/
bombardier -c 1000 -d 30s http://127.0.0.1:18080/
```

## License

ZiServer's original source, documentation, and examples are licensed under the [BSD 2-Clause License](LICENSE).

OpenSSL, nghttp2, ngtcp2, nghttp3, and the GSAP/ScrollTrigger demo assets retain their upstream licenses. See [third-party notices](THIRD_PARTY_NOTICES.md) and [`LICENSES/`](LICENSES/). GSAP 3.12.5 and ScrollTrigger 3.12.5 are separately licensed GreenSock demo assets and are not covered by ZiServer's BSD-2-Clause license. Source and binary redistributions must retain the project license, third-party notices, and applicable third-party license texts.
