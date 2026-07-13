# Client IP and Rate-Limit Deployment

[简体中文原文](../../zh-CN/operations/client-ip-rate-limit.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

ZiServer routes use independent process-local fixed windows keyed by `(client_ip, relaxed|strict)`. No forwarded header is read by default; `client_ip` is always the direct `peer_ip` supplied by the socket at accept time.

## Direct deployment

Keep defaults when no reverse proxy is present:

```powershell
zig-out\bin\ziserver.exe --rate-limit-relaxed=120 --rate-limit-strict=20
```

Client-supplied `X-Forwarded-For`, `Forwarded`, and `X-Real-IP` never change rate-limit identity. Keys exclude source port, and IPv4-mapped IPv6 is folded to IPv4.

## Reverse-proxy deployment

Enable XFF only when all of the following are true:

1. A firewall, security group, container network, or loopback restricts the ZiServer listener so only designated proxies can connect; the public cannot bypass them.
2. The outermost proxy removes client-supplied `X-Forwarded-For` and rebuilds it from the real connection source.
3. `--trusted-proxy` uses the narrowest proxy address/CIDR possible. Loopback, RFC1918, or ULA addresses are not implicitly trusted.

Single-proxy example:

```powershell
zig-out\bin\ziserver.exe `
  --client-ip-header=x-forwarded-for `
  --trusted-proxy=127.0.0.1/32 `
  --forwarded-max-hops=4 `
  --rate-limit-relaxed=120 `
  --rate-limit-strict=20
```

Repeat `--trusted-proxy=CIDR` as needed. Environment form:

```powershell
$env:ZISERVER_CLIENT_IP_HEADER="x-forwarded-for"
$env:ZISERVER_TRUSTED_PROXIES="127.0.0.1/32,10.20.0.0/24"
$env:ZISERVER_FORWARDED_MAX_HOPS="4"
```

Enabling XFF without a trusted proxy fails startup. Duplicate, oversized, over-hop, or invalid XFF is never partially accepted: identity safely falls back to `peer_ip` and increments `client_identity.invalid`. XFF from an untrusted peer is ignored and increments `ignored_untrusted`.

### Minimum proxy constraints

Edge nginx must overwrite rather than preserve a public request's XFF:

```nginx
location / {
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_pass http://127.0.0.1:18080;
}
```

Edge HAProxy may delete and rebuild it:

```haproxy
frontend public
    http-request del-header X-Forwarded-For
    option forwardfor
    default_backend ziserver
```

Caddy and Envoy must follow the same rule: the external listener rebuilds XFF from the real remote address; only controlled internal hops append an already-sanitized chain. For multiple proxies, trust each proxy CIDR and preserve `client, proxy-1, proxy-2` order. ZiServer strips trusted proxies right to left and selects the first untrusted address.

Do not mix PROXY protocol with HTTP forwarded headers. ZiServer does not currently enable a PROXY protocol parser; disable a load balancer's PROXY preamble until it is added as a separate explicit transport option.

## Capacity and concurrency

The default limiter uses 64 lock shards, up to 65,536 `(IP, policy)` entries, and a ten-minute idle TTL:

```text
--rate-limit-capacity=65536
--rate-limit-shards=64
--rate-limit-idle-ttl=600000
```

A policy with threshold 0 creates no entry. A full shard first removes idle-expired entries. If still full, new keys fail closed with 429 and increment `capacity_rejections`; memory never grows without bound or silently bypasses. The current window is one second and 429 includes `Retry-After: 1`.

Each ZiServer process owns its limiter state. Multiple processes or replicas each receive the full budget. Exact cluster-wide limits belong at the trusted edge or in a future shared-state backend. Application rate limiting also does not replace connection-count, listen-queue, or bandwidth DDoS protection.

## Logs and metrics

Access logs include normalized `client_ip` and `client_ip_source=peer|x-forwarded-for` but never the raw XFF chain. `/stats` provides:

- `client_identity.peer|forwarded|header_missing|ignored_untrusted|invalid`
- `rate_limit.entries`
- `rate_limit.allowed_relaxed|allowed_strict`
- `rate_limit.rejected_relaxed|rejected_strict`
- `rate_limit.expired|capacity_rejections`

These are low-cardinality aggregates; IP addresses never become metric labels. IP addresses may identify people, so log retention and access control must follow the deployer's privacy policy.
