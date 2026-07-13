# Database Middleware Abstraction

[简体中文原文](../../zh-CN/guides/database.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

Database integration has three layers:

- Core's `services.Registry` stores only application-owned opaque services and knows nothing about databases or PostgreSQL.
- `compose/database.zig` defines pools, connections, parameter values, and middleware that borrows/returns a connection per request.
- `compose/database/pgsql.zig` defines PostgreSQL configuration and the driver-adapter boundary. A concrete libpq or native wire driver remains future work.

## Route declaration

```zig
h.post("/files/metadata", metadataHandler)
    .withLayer(z.layer.database(.required));

pub fn metadataHandler(ctx: *z.Context) !void {
    const db = z.database.connection(ctx) orelse return error.DatabaseUnavailable;
    const result = try db.exec(
        "insert into uploads (object_key, size) values ($1, $2)",
        &.{
            .{ .text = "object-key" },
            .{ .integer = 4096 },
        },
    );
    _ = result;
    try ctx.json(.ok, "{\"saved\":true}\n");
}
```

`.required` returns 503 when no pool is registered or acquire fails. `.optional` continues without a pool so the handler can test `connection(ctx)`. `.none` does not touch the database.

## Startup-layer injection

```zig
var pool = try pg_driver.openPool(io, allocator, .{
    .connection_uri = "postgresql://user:password@127.0.0.1/app",
    .min_connections = 2,
    .max_connections = 16,
});

const service_entries = [_]z.services.Entry{
    z.database.service(&pool),
};

pub const registration = registry.register(.{
    .routes = &routes,
    .services = z.services.Registry{ .entries = &service_entries },
});
```

The composition root owns the pool and driver state, which must outlive every request. After acquire, middleware puts the `Connection` into request-local storage and registers end-of-request cleanup. Normal return, handler error, and middleware short-circuit all release it.

After the server stops accepting and active requests drain, the composition root should call `pool.deinit()`. Connection URIs may contain passwords and must not appear in access logs, error responses, or metric labels.

## Current PostgreSQL boundary

`z.pgsql.Config` includes URI, minimum/maximum connections, acquire timeout, and idle timeout. `z.pgsql.Driver` accepts an external driver's `open_pool_fn`. This repository does not currently link libpq and does not claim a working PostgreSQL wire protocol. The next adapter implementation should provide:

1. connection establishment, TLS, SCRAM-SHA-256, and cancellation;
2. a bounded pool, acquire deadline, idle/stale connection reclamation;
3. prepared-statement cache, typed row cursor, and transaction object;
4. database error classification, retry boundaries, and `/stats` pool metrics;
5. compensating cleanup between temporary upload files and metadata transactions.
