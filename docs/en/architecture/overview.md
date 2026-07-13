# ZiServer Layer Boundaries

[简体中文原文](../../zh-CN/architecture/overview.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

ZiServer uses one-way dependencies:

```text
app  ->  ziserver public facade  ->  compose  ->  core
                                      |           |
                                      +-----------+
```

## Platform scope

Only **Windows x86_64** is currently considered usable: builds, functional regressions, long-running HTTP/2 tests, and memory-stability checks have all been completed on that platform. The validated Windows TLS/HTTP/2 combination is vcpkg-provided OpenSSL + nghttp2, with a Windows-specific AFD cancellable-read path for socket deadlines.

Linux, macOS, and other targets retain some portable `std.Io` paths, but lack equivalent CI, protocol regressions, long-running load tests, and release validation; they must not currently be presented as supported. The SChannel backend is a placeholder. Native HTTP/3 is still experimental single-connection work without completed multi-connection, GOAWAY, or full router/middleware integration.

`main.zig` is the minimal composition root. It calls `core/server.zig` directly and injects the concrete application factory as a callback. Core parses startup configuration, owns core resources, and runs the server. The factory lives in app and uses compose through the public facade. Core never imports compose/app, and compose never imports app.

## core

Core owns protocol and runtime mechanisms: sockets/TLS, HTTP/1/2/3, protocol correction on the wrong listener, request parsing, bidirectional streaming, response writing, routing tables, static resources, cache storage, queues, statistics, timeouts, and shutdown.

- It does not import `compose/` or `app/`.
- It contains no concrete endpoints, page copy, or business paths.
- It defines only reusable mechanisms and stable data contracts, such as `Context.runtimeSnapshot()`, the opaque application service registry, and request cleanup hooks.
- It does not choose middleware order or application routes.
- `core/server.zig` is the process startup service. It manages configuration, core resources, listeners, acceptors, workers, and graceful shutdown. A concrete application is injected through a `fn (Allocator, ApplicationStartupConfig) anyerror!ApplicationBundle` factory callback. The bundle's optional destructor runs before core service resources are released.
- `core/protocol_redirect.zig` handles dual-listener protocol-correction 308 responses before router/middleware execution. It isolates request authority through canonical/allowed/fallback Host policy and separates `Location` parsing from response transport. The bind host is normalized during configuration and shared by listeners, Host policy, and shutdown wakeups. `core/config.zig` rejects every spelling of a wildcard TLS bind when no explicit Host policy is present.

## compose

Compose combines core capabilities into reusable policies: the DSL, default middleware pipeline, auth/CORS/XSS/rate limiting, query validation, unified content extraction/injection, explicit file persistence, database connection borrowing, and page-cache policy.

- It may depend on core, but must not import app.
- Middleware may validate, transform, short-circuit, or manage bounded side effects according to explicit DSL policy. The content layer retains only a borrowed `Document`; app-owned services inject custom codecs; file persistence uses an atomic sink; and database connections return through request cleanup. Middleware does not contain site response logic.
- It does not read the entire application registry and contains no `/health`, `/stats`, or sample business responses.
- `core/config.zig` resolves CLI/environment precedence. Middleware receives already-parsed policy or credentials.

## app

App is the replaceable final application: handlers, page templates, endpoint responses, and route registration.

- Framework capabilities are accessed only through the `ziserver.zig` public facade, never by importing internal `core/` or `compose/` files directly.
- Files inside app may import one another.
- App registration provides the application factory injected by main into the core server. Through the public facade, the factory may combine compose capabilities and use an allocator to initialize dynamic routes, connection pools, template caches, or plugins. Initialization failures must return errors; long-lived resources belong to the `ApplicationBundle` state/deinit contract.
- App does not manage listeners, workers, TLS sessions, cache locks, or global middleware lifetime.
- Operational endpoints read public snapshots rather than reaching through `Context` into cache or statistics storage.

## Verification

`zig build test` builds `core-tests`, `compose-tests`, and `app-tests` separately. Dependency reviews should also verify:

```powershell
rg '@import\(".*(compose|app)' src/core
rg '@import\(".*app' src/compose
rg '\.\./(core|compose)' src/app
```

All three commands should return no matches when the architecture boundary is intact.
