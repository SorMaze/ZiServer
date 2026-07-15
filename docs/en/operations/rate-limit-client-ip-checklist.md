# Per-Client-IP Rate Limiting and Trusted-Proxy Boundary Checklist

[简体中文原文](../../zh-CN/operations/rate-limit-client-ip-checklist.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

This phased implementation, test, and rollout checklist addresses two coupled problems:

- The old limiter was a process-level fixed window shared by policy rather than by client, allowing one source to consume everyone else's budget.
- Request context lacked the socket peer address, trusted-proxy configuration, and a normalized client IP. Trusting `Forwarded`, `X-Forwarded-For`, or `X-Real-IP` directly would let clients forge identities and bypass limiting.

## Completion status (2026-07-13)

The core fix is implemented. `client_identity.zig` establishes bounded trust among socket peers, trusted-proxy CIDRs, and XFF; `rate_limiter.zig` provides a server-owned bounded sharded per-IP limiter. HTTP/1.1, HTTP/2, the buffered experimental HTTP/3 path, Context, access logs, `/stats`, CLI/environment configuration, and deployment documentation are integrated. Remaining work: validated HTTP/3 path migration, RFC 7239 `Forwarded`, token bucket, parser fuzzing, protocol-level HTTP/2/TLS/QUIC load testing, and real production canaries.

## Historical pre-implementation source review

- `src/compose/rate_limit.zig:21-23` held module-global `relaxed`, `strict`, and `rate_config`; `limit()` at `:37-38` selected only one shared policy window.
- The effective key space had only two windows; all routes and clients on one policy consumed the same budget.
- The old implementation used a one-second fixed window and one mutex. Tests covered threshold/recovery only, not client isolation, concurrency, or proxy forgery.
- `Context`, `PendingConnection`, accept, and HTTP/2 dispatch state did not carry peer/client identity.
- Native HTTP/3 historically bypassed middleware. The experimental adapter now uses the UDP/QUIC peer and shared identity resolver; path migration remains disabled until active paths are validated and propagated by ngtcp2.
- `Request.header()` returns only the first repeated header and was unsuitable for identity parsing without duplicate, merge, and length rules.
- 429 already carried `Retry-After: 1`, appropriate while the first implementation remains a one-second window.

## Security semantics that had to be fixed first

- [x] Define the direct socket/QUIC peer as `peer_ip`, the root trust fact independent of HTTP headers.
- [x] Define normalized `client_ip` for rate limiting, audit, and future IP-aware auth; individual features never parse identity headers independently.
- [x] Default to `client_ip_header=none`, so `client_ip = peer_ip` and every forwarded header is ignored.
- [x] Parse only the selected forwarded header when `peer_ip` matches an explicitly trusted proxy CIDR. Loopback/private binding is not automatic trust.
- [x] Initially support only `none|x-forwarded-for`. A future RFC 7239 `Forwarded` mode must be a separate parser, never mixed by guessed precedence.
- [x] Do not use `X-Real-IP` as an implicit fallback. Any future support must be explicit, mutually exclusive, and guarded by the same proxy trust.
- [x] Logically append `peer_ip` to the right of a trusted-proxy chain, remove trusted proxies right to left, and choose the first untrusted address. If every address is trusted, choose the leftmost source.
- [x] Require the outermost proxy to overwrite or strictly sanitize public identity headers; merely appending can retain an attacker-forged leftmost value.
- [x] Define deterministic handling for missing, duplicate, oversized, over-hop, empty, invalid, zone-id, `unknown`, or obfuscated values. Failure falls back to `peer_ip` and increments a reason counter.
- [x] Do not discard addresses based on public/private/reserved class; real internal topologies may use them. Trust comes only from configured CIDRs and chain position.
- [x] State clearly that this is per-IP limiting within one process. Multi-process/replica aggregation belongs at the trusted edge or a future shared backend.

Examples:

| `peer_ip` | Trusted proxy | `X-Forwarded-For` | Result |
| --- | --- | --- | --- |
| `203.0.113.8` | No | `1.1.1.1` | `203.0.113.8`; forged header ignored |
| `10.0.0.10` | Yes | `203.0.113.8` | `203.0.113.8` |
| `10.0.0.10` | Yes | `203.0.113.8, 10.0.0.20` | `203.0.113.8`; two trusted proxies stripped right to left |
| `10.0.0.10` | Yes | Invalid | Fallback `10.0.0.10`; parse-failure metric increments |

## P0: Establish the real client-identity boundary

### Address type and parser

- [x] Add `src/core/client_identity.zig`; proxy trust is not part of rate-limit middleware.
- [x] Define a normalized portless `IpKey` with family plus fixed 4/16 bytes; fold IPv4-mapped IPv6 to IPv4.
- [x] Define value-semantic `ClientIdentity` with peer, client, source, trusted-hop count, and parse status.
- [x] Parse CIDRs once at startup and match only compiled results per request.
- [x] Implement a bounded allocation-free XFF parser with byte/hop limits and strict tokens.
- [x] Reject duplicate XFF and safely fall back rather than taking the first value.
- [x] Use pure parsing functions and a monotonic clock, independent of wall time or global configuration.

### Transport through Context

- [x] Accept stores the remote socket address without port in `PendingConnection` rather than guessing from headers.
- [x] Extend `PendingConnection` and `ServeOptions`; all HTTP/1.1 keep-alive requests retain the correct peer.
- [x] Put the same peer in `Http2DispatchState`; each HTTP/2 stream resolves its own client from its headers.
- [x] Populate identity before middleware and expose read-only `ctx.clientIp()` / `ctx.peerIp()`.
- [x] Preflight and ordinary handlers use the same identity path; access logs see the same result.
- [x] Experimental HTTP/3 uses the initial QUIC connection peer and the shared resolver; packets from another peer are rejected for the single-connection session.
- [ ] NAT rebinding/path migration must update identity only from an ngtcp2-validated active path before migration is enabled.
- [x] Keep explicit identity injection for tests/embedded calls; no module-global “current client.”

### Configuration boundary

- [x] Add `--client-ip-header`, repeatable `--trusted-proxy`, and `--forwarded-max-hops`.
- [x] Default to `none` with an empty trust list; forwarded mode without a trusted proxy fails startup.
- [x] Invalid CIDR, hop, and capacity configuration fails at startup with a clear error.
- [x] Add environment variables, CLI precedence, and configuration tests.
- [x] Startup logs only mode, trusted-network count, and hop limit—not full chains.
- [x] The [deployment guide](client-ip-rate-limit.md) documents proxy sanitization and network constraints.

## P0: Bucket rate limits by client IP

### Ownership and key semantics

- [x] Replace module-global windows with a server-owned `RateLimiter` initialized/deinitialized by main; tests create isolated instances.
- [x] Key by `(client_ip, RateLimitPolicy)` to preserve policy semantics while isolating clients.
- [x] Do not silently change to route scope; any future route scope requires stable route IDs and explicit configuration.
- [x] `limit(ctx)` reads only verified `ctx.clientIp()` and the injected limiter; it never parses HTTP headers.
- [x] Threshold 0 means unlimited and creates no entry.

### Concurrency, time, and memory bounds

- [x] Use sharded maps/locks hashed by normalized binary IP and policy.
- [x] Keep the one-second fixed window and use the monotonic `Clock.awake`; token/sliding buckets remain separate work.
- [x] Bound entries and idle TTL; under pressure, remove all expired entries without unbounded growth.
- [x] If still full, fail new keys closed with 429 and increment `capacity_rejections`.
- [x] Update windows and cleanup inside the shard lock; retain no entry pointer after unlocking.
- [x] Counters do not exceed a u32 threshold, clock rollback resets the window, and concurrent same-IP success never exceeds budget.
- [x] Configuration is immutable after startup and requires restart.

### 429 semantics

- [x] Keep 429 plus `Retry-After: 1` for the one-second window.
- [ ] Optionally add standardized `RateLimit-Limit`, `RateLimit-Remaining`, and `RateLimit-Reset`, but never publish misleading unsynchronized values.
- [x] Never echo client IP, proxy chain, or trusted-proxy configuration in 429.

## P1: Observability and privacy

- [x] Access logs add normalized client IP and source, never raw XFF.
- [x] JSON and pretty logs share one portless IP rendering.
- [x] `/stats` adds low-cardinality counters for policy, identity source, parsing failure, entries, expiry, and capacity rejection.
- [x] Client IP is not a metric label; individual investigation uses access logs.
- [x] Startup logs summarize configuration; untrusted forwarded headers only increment aggregates rather than per-request warnings.

## Test checklist

### Client-identity unit tests

- [x] In no-proxy mode, XFF/`Forwarded`/`X-Real-IP` cannot change the peer.
- [x] Ignore XFF from untrusted peers; accept a one-hop XFF from trusted peers.
- [x] Cover multi-proxy first-untrusted and all-trusted chains.
- [x] Cover IPv4, IPv6, mapped IPv6, CIDR edges, optional ports, and normalized equality.
- [x] Cover duplicate, empty, invalid, oversized, over-hop, `unknown`, zone-id, and malformed bracket/port input; all safely fall back without panic.
- [x] Add a bounded identity-header parser fuzz target.

### Limiter unit/concurrency tests

- [x] Exhausting IP A's strict budget does not block IP B's first request.
- [x] One IP returns 429 at the threshold and recovers after window reset.
- [x] Relaxed/strict budgets are independent; threshold 0 creates no entry.
- [x] Concurrent success for one key never exceeds the threshold; sharding avoids a global lock.
- [x] Test idle reclamation, capacity, fail-closed behavior, metrics, and recovery.
- [x] Two limiter instances never share state.

### Protocol/integration tests

- [x] Direct forged XFF cannot switch buckets; two trusted XFF clients receive independent budgets.
- [ ] Multiple requests on one keep-alive connection share the peer but resolve each verified forwarded header independently.
- [ ] HTTP/2 multi-stream matches HTTP/1.1 and never crosses identities.
- [ ] TLS and plaintext peer acquisition match; proxy TLS termination uses XFF only from a trusted proxy.
- [x] Route experimental HTTP/3 through middleware/client identity and document the remaining migration and protocol-load-test gaps.
- [ ] Regress `Retry-After`, HEAD/preflight, error responses, and single-line JSON log escaping.
- [x] Debug/ReleaseFast `zig build test` and executable builds pass.
- [ ] Benchmark hot single-IP and distributed multi-IP loads, recording throughput, P95/P99, lock contention, and resident memory.

## Rollout and acceptance gates

1. [ ] First release identity propagation, proxy parsing, logs, and metrics; compare peer/client values with proxy logs in staging.
2. [ ] Roll out direct deployment with `client_ip_header=none`; verify forged headers do not change identity.
3. [ ] Enable XFF only after ACLs prevent public bypass and the edge overwrites identity headers; configure precise proxy CIDRs.
4. [ ] Switch to the per-IP limiter; observe 429, entries, parse failures, and capacity while retaining edge DDoS limiting.
5. [ ] Verify attacker A cannot affect client B, forged headers cannot rotate A's bucket, and restart/window/capacity pressure causes no crash or unbounded memory.
6. [x] Update [`README.md`](../../../README.md), [security audit](../security/security-audit.md), and [roadmap](../architecture/roadmap.md) with process/replica and proxy prerequisites.

## Shortcuts explicitly rejected

- [x] Never use the first `request.header("X-Forwarded-For")` value directly as the key.
- [x] Never trust loopback, RFC1918, ULA, or common proxy ranges by default.
- [x] Never include `IP:port` in the key.
- [x] Never substitute User-Agent, Host, Authorization, or another mutable header for network identity.
- [x] Capacity exhaustion never falls back to one silent global shared bucket.
- [x] Documentation never claims the application limiter alone stops connection, bandwidth, or cross-replica aggregate attacks.
