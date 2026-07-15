# Page Response Cache Design

[简体中文原文](../../zh-CN/architecture/page-cache.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

The page response cache has a separate responsibility from the existing caches:

- `z.layer.cache(...)` controls client-visible `Cache-Control`.
- `core/static.zig` serves disk or embedded static files and does not retain dynamic handler output.
- `z.layer.pageCache(...)` explicitly caches server-generated dynamic page bodies.

## Request flow

1. The router stores `PageCachePolicy` in route options.
2. Auth, rate limiting, query validation, and security filtering still run first; a hit never bypasses these policies.
3. `compose/page_cache.zig` looks up normalized Host plus the complete request target (path and query). Cookie-sensitive routes add a SHA-256 Cookie partition, preventing cross-Host and cross-session reuse without retaining raw Cookie values in cache keys.
4. On hit, it writes through `Context.writeBytesHead()`; diagnostic mode adds `X-Page-Cache: HIT`.
5. On miss, the first request for the key becomes the fill leader and runs the handler; later requests wait and reuse the successful fill.
6. A successful GET 200 response is inserted by `Context` after sending completes. Handler failure or an uncacheable response also releases the fill token so waiters can retry or become the next leader.

HEAD and GET share keys. HEAD can read the body length of a GET-filled entry, but a HEAD miss never creates an incomplete entry.

## Security boundary

GET/HEAD routes are Cookie-partitioned by default. The same Cookie state can reuse a server-cache entry, while different Cookie states receive distinct keys. These responses carry `Vary: Cookie` so conforming downstream caches retain the same boundary.

The high-level DSL exposes an atomic strategy instead of requiring callers to coordinate client and server cache settings manually:

```zig
h.get("/about", site.handle)
    .cacheStrategy(.static_shared)
```

| Strategy | Process cache | Cookie boundary | Client `Cache-Control` |
| --- | --- | --- | --- |
| `.static_shared` | long (300 s) | shared/ignored | `public, max-age=3600` |
| `.recommended` | standard (30 s) | SHA-256 partitioned | `public, max-age=30` + `Vary: Cookie` |
| `.discouraged` | disabled | n/a | `no-cache` |
| `.never` | disabled | n/a | `no-store` |

`.static_shared` is a developer contract: the handler must not read Cookie state or emit user-specific content. It removes the Cookie partition and `Vary: Cookie`, allowing anonymous and Cookie-bearing requests to share one hot entry. `.recommended` is the safe default for pages that may vary by Cookie. The lower-level `cache(...)` and `pageCache(...)` layers remain available for specialized policies.

The demo cache arena exposes `/cache-arena/static-shared`, `/cache-arena/recommended`, `/cache-arena/discouraged`, and `/cache-arena/never`. Start with `--page-cache-header=on` and send repeated requests with different Cookie values to observe shared HITs, partitioned FILL/HIT behavior, and permanent bypass modes.

## Startup prewarming

Startup prewarming is enabled by default and can be controlled with `--page-cache-prewarm=on|off`, `--no-page-cache-prewarm`, or `ZISERVER_PAGE_CACHE_PREWARM=on|off`. After listeners and workers are ready, one managed background thread scans the route table and renders every exact, unauthenticated GET route declared as `.static_shared`. Successful cacheable responses enter the same sharded Store used by live requests, so the first client can receive a HIT instead of becoming the fill leader.

Prewarming uses the normal application middleware and handler pipeline but clears the route rate-limit policy for the synthetic request, so startup work does not consume a client IP budget. A prewarm fill still appears as a cache miss/insert in cache metrics. Existing entries are detected without manufacturing hit/miss metrics, and normal fill coalescing resolves races with early live traffic.

Cache keys remain Host-isolated. The prewarmer selects the canonical host when configured, otherwise every allowed host, otherwise a concrete bind host. A wildcard bind without canonical/allowed hosts is skipped because no meaningful client authority can be inferred. Dynamic routes, HEAD-only routes, authenticated routes, streaming/non-cacheable responses, and responses with custom headers are skipped or reported as not cacheable. Dynamic pages can expose explicit exact aliases when they need startup prewarming.

The cache still always bypasses when:

- the route uses auth or `requireAuth`;
- the request contains `Authorization`, `Origin`, or `Range`;
- request `Cache-Control` asks for `no-cache` or `no-store`;
- the response is not 200, exceeds the configured per-entry body limit (256 KiB by default), or carries handler-defined custom headers.

Handler-defined custom response headers, including `Set-Cookie`, prevent a miss from being inserted. These restrictions and the default Cookie partition avoid sharing user-specific pages, cross-origin variants, or partial content with other requests.

## Storage and concurrency

- Shard count and total entries are allocated at startup: 16 shards / 256 entries by default.
- Wyhash selects a shard; each shard uses a small linear table and shared read lock.
- A full shard evicts the least recently used entry; lookup also removes expired entries.
- Only one in every 64 hits samples and updates the LRU clock, reducing atomic-write contention for hot keys.
- Reference-counted entries allow eviction to overlap safely with concurrent response sending.
- Each shard has a fixed-capacity fill coordinator that coalesces same-key misses. When full, it conservatively bypasses without increasing the memory bound.
- `.short`, `.standard`, and `.long` TTLs are 5, 30, and 300 seconds.

Capacity, shard count, per-entry body limit, and global TTL percentage are configurable through CLI or environment. Capacity stays fixed after initialization for predictable memory use and no runtime resize/global cache lock. Entries disappear on restart by design: this is a process-local L1 cache.

## External configuration

| CLI | Environment variable | Default |
| --- | --- | ---: |
| `--page-cache=on|off` | `ZISERVER_PAGE_CACHE` | `on` |
| `--page-cache-capacity=N` | `ZISERVER_PAGE_CACHE_CAPACITY` | `256` |
| `--page-cache-shards=N` | `ZISERVER_PAGE_CACHE_SHARDS` | `16` |
| `--page-cache-max-body=BYTES` | `ZISERVER_PAGE_CACHE_MAX_BODY` | `262144` |
| `--page-cache-ttl-percent=N` | `ZISERVER_PAGE_CACHE_TTL_PERCENT` | `100` |
| `--page-cache-header=on|off` | `ZISERVER_PAGE_CACHE_HEADER` | `off` |
| `--page-cache-fill-wait-timeout=MS` | `ZISERVER_PAGE_CACHE_FILL_WAIT_TIMEOUT` | `100` |

Same-key miss waiting is cancellable. On timeout, the request bypasses and renders independently. `0` disables waiting; the maximum is 30000 ms. CLI takes precedence over environment. Capacity is 1–16384, shards are 1–64 and no greater than capacity, body size is at most 1 MiB, and TTL scaling is 1–1000%. For example, `50` reduces `.standard` from 30 to 15 seconds.

The `/stats` `page_cache` object reports `entries`, `bytes`, `hits`, `misses`, `inserts`, `evictions`, `expired`, `fill_leaders`, `coalesced_waits`, `coalesced_hits`, `fill_bypasses`, and `fill_wait_timeouts`. These counters do not depend on the general `--stats` switch so cache tuning remains observable.

Coalesced waits use a cancellable condition variable and the timeout above. A timeout renders independently instead of being held forever by a slow leader. High `coalesced_waits` around hot-key expiry suggests increasing worker count, extending TTL, or introducing jittered refresh.

`X-Page-Cache` is diagnostic and off by default. Stable benchmarks should use `--page-cache-header=off --no-access-log` so synchronous logging and extra response headers are not counted as page-generation cost.

## Later stages

- Evaluate stale-while-revalidate to reduce duplicate rendering after wait timeout.
- Support explicit tag/path invalidation.
- Evaluate additional allowlisted `Vary` dimensions when justified.
