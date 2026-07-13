# ZiServer Security Audit Report

[简体中文原文](../../zh-CN/security/security-audit.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

> Remediation status (2026-07-13): this document preserves the original findings as a historical record. Default credentials, public CORS authorization, exact `Server` fingerprinting, global security response headers, minimum TLS version, and the process-global shared rate-limit budget have been remediated. Rate limiting now buckets normalized client IPs. Forwarded headers are untrusted by default and a bounded XFF chain is parsed only when the direct peer matches an explicitly trusted proxy CIDR.

**Date**: 2026-07-10  
**Target**: ZiServer v0.4 (Zig HTTP server)  
**Test endpoints**:

- `http://127.0.0.1:18080/` (HTTP)
- `https://127.0.0.1:18443/` (HTTPS)

---

## Overall rating: ⚠️ Multiple security issues found

---

## 🔴 High-severity findings

### 1. Default credential exposure (CVSS 9.8) — remediated

**Description**: The server used hard-coded development credentials:

- **Bearer token**: `dev-token`
- **API key**: `dev-key`

They were defined as `default_credentials` in `src/compose/auth.zig` and documented in the README. A network deployment without an environment/CLI override exposed `/admin/stats` completely.

**Verification**:

```bash
# Bearer token authentication (200)
curl http://127.0.0.1:18080/admin/stats -H "Authorization: Bearer dev-token"
# API-key authentication (200)
curl http://127.0.0.1:18080/admin/stats -H "X-API-Key: dev-key"
```

**Recommendation**:

- Require `ZISERVER_BEARER_TOKEN` and `ZISERVER_API_KEY` at startup.
- Emit a prominent startup warning if a default is used.
- Do not publish production default credentials.

---

### 2. Unsafe CORS wildcard combined with Authorization (CVSS 7.5) — remediated

**Description**: `src/compose/cors.zig` allowed:

- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Headers: Content-Type, Authorization`
- `Access-Control-Allow-Methods: GET, HEAD, POST, OPTIONS`

Any website could make cross-origin `/api/echo` or `/submit` requests and include `Authorization`, letting malicious JavaScript send bearer credentials.

**Verification**:

```bash
curl -X OPTIONS http://127.0.0.1:18080/api/echo \
  -H "Origin: http://evil.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type"
# Returned Access-Control-Allow-Origin: *
```

**Recommendation**:

- Replace `*` with an explicit origin allowlist.
- For a public API, remove `Authorization` from allowed headers.
- Consider route-specific CORS policy.

---

### 3. Incomplete XSS filter coverage (CVSS 6.1)

> Current status (2026-07-12): enhanced and configurable. `/submit` and `/api/echo` declare `xssObserve()`; `--xss-mode=block` raises the server-wide minimum to blocking and routes cannot weaken it. Bounded two-pass normalization handles common percent/double-percent encoding and ASCII numeric entities; detection covers dangerous tags, protocols, CSS expression, `srcdoc`, and generic `on*` event attributes. The description and checks below are retained as historical audit evidence.

**Historical description**:

- `/submit` used `xssObserve()` and logged rather than blocked.
- `/api/echo` had no XSS layer.
- The old signatures could be bypassed in many ways.

**Verification**:

```bash
# /api/echo accepted and reflected the payload
curl -X POST http://127.0.0.1:18080/api/echo \
  -H "Content-Type: application/json" \
  -d '{"message":"<img src=x onerror=alert(1)>","count":1}'

# /submit observed but did not block
curl -X POST http://127.0.0.1:18080/submit \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=<script>alert(1)</script>&email=test@test.com"
```

The historical implementation checked only nine fixed patterns and missed `onfocus`, `onmouseover`, `expression()`, `data:text/html`, template-injection backticks, SVG events, and Unicode variants such as full-width angle brackets. It has since moved to and been strengthened in `src/compose/xss.zig`.

**Recommendation**:

- Apply XSS policy to every route reflecting user input.
- Prefer context-aware output encoding/HTML escaping over input filtering alone.
- Use blocking mode for reflective routes.

Even in `block`, this component is defense in depth and cannot promise coverage of every HTML/Unicode/browser parsing variant. Context-aware output encoding, JSON serialization, and CSP remain primary controls.

---

## 🟡 Medium-severity findings

### 4. Server fingerprint disclosure (CVSS 5.3) — remediated

Every response exposed `Server: ZiServer/0.4`, allowing rapid stack identification and targeted exploitation. Remove the header or use a generic value such as `Server: webserver`.

---

### 5. Missing security headers (CVSS 5.0) — baseline remediated

The following standard headers were absent:

| Missing header | Risk |
|---|---|
| `X-Content-Type-Options: nosniff` | MIME sniffing |
| `X-Frame-Options: DENY` | Clickjacking |
| `Content-Security-Policy` | XSS/injection |
| `Strict-Transport-Security` | SSL downgrade |
| `Referrer-Policy` | Information disclosure |
| `Permissions-Policy` | Browser-feature abuse |

At minimum, add:

```text
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Strict-Transport-Security: max-age=31536000; includeSubDomains
Referrer-Policy: strict-origin-when-cross-origin
```

---

### 6. TLS configuration issue (CVSS 5.0) — remediated and TLS 1.3 enhanced

**Historical description**:

- The README claimed TLS 1.2 minimum, but TLS 1.0/1.1 connections succeeded (`curl --tls-max 1.0`).
- The development certificate used `127.0.0.1` as CN, while `localhost` was recommended.

**Recommendation**: explicitly call `SSL_CTX_set_min_proto_version(TLS1_2_VERSION)` and regenerate the development certificate for `localhost`.

---

### 7. IDOR / source exposure risk (CVSS 4.3)

Static service relies on the `public/` root; sensitive paths such as `.env` and `.git` must remain inaccessible.

```bash
curl http://127.0.0.1:18080/.env          # 404 ✓
curl http://127.0.0.1:18080/src/main.zig  # 404 ✓
curl http://127.0.0.1:18080/assets/../../../README.md  # 404 ✓
```

**Current status**: ✓ Safe—path traversal protection is effective.

---

## 🟢 Low-severity findings

### 8. Process-wide rather than per-IP limiter (CVSS 3.7)

**Current status (2026-07-13)**: ✓ Remediated. `src/core/rate_limiter.zig` uses a service-owned bounded sharded table keyed by `(client_ip, policy)`. `src/core/client_identity.zig` roots trust in the socket peer, adds trusted-proxy CIDRs, and strips XFF right to left. Capacity fails closed and has dedicated metrics. This remains process-local; trusted edge infrastructure or a future shared backend must aggregate replicas.

The historical global counters gave all strict routes 20 requests/second and all relaxed routes 120 requests/second, regardless of client. One attacker could exhaust the shared budget. The recommendation was a hash map from IP to window counter.

---

### 9. Case-sensitive Bearer scheme (RFC deviation) (CVSS 2.6)

`hasBearer()` used an exact `startsWith("Bearer ")`, rejecting `bearer` and `BEARER`, despite RFC 7235's case-insensitive scheme. Use a case-insensitive prefix comparison.

---

### 10. Content-Type disclosure (CVSS 2.3)

A 415 response exposed every supported type:

```json
{"error":"unsupported_media_type","expected":"application/json, application/x-www-form-urlencoded, or multipart/form-data"}
```

Return a generic “Unsupported Media Type” message if this detail is not intended.

---

### 11. Case-sensitive HTTP method parsing (CVSS 2.0)

`parseMethod()` recognizes uppercase `GET`, `POST`, and so on. Lowercase `get` becomes `.unknown`. HTTP method tokens are case-sensitive by specification, but this may affect compatibility with some libraries.

---

## ✅ Security tests passed

| Test | Status | Notes |
|---|---|---|
| Path traversal (`../`) | ✅ Pass | `validPath()` rejects `..` |
| Encoded traversal (`%2e%2e%2f`) | ✅ Pass | 404 |
| Null-byte injection (`%00`) | ✅ Pass | 404 |
| Header CRLF injection | ✅ Pass | `containsLineBreak()` rejects it |
| Encoded CRLF (`%0d%0a`) | ✅ Pass | 404 |
| HTTP/2 h2c downgrade | ✅ Pass | 505 |
| Wrong-listener HTTP/2 redirect + >16 KiB POST | ✅ Pass | Publishes 308, drains DATA, does not block the request queue or multiplexed session |
| CONNECT proxy abuse | ✅ Pass | 405 |
| TRACE/XST | ✅ Pass | 405 |
| Oversized body | ✅ Pass | 16 KiB global plus route limits |
| Long URL | ✅ Pass | Safely handled |
| Host injection / redirect poisoning | ✅ Pass | Canonical Location, allowlist rejection, wildcard TLS startup guard |
| `.env` / source exposure | ✅ Pass | Static files only from `public/` |
| Basic limiter function | ✅ Pass | 429 after 20+ requests in the historical test |
| Unauthorized response | ✅ Pass | Correct 401 without disclosure |
| Method restriction | ✅ Pass | PUT/DELETE/PATCH/CONNECT/TRACE return 405 where unsupported |

---

## Recommended remediation priority

| Priority | Issue | Effort | Impact |
|---|---|---|---|
| 🔴 P0 | Default credentials | Small | Unauthorized access |
| 🔴 P0 | CORS wildcard + Authorization | Small | Cross-origin credential abuse |
| 🟡 P1 | Security headers | Small | Multiple browser attacks |
| 🟡 P1 | XSS coverage | Medium | Cross-site scripting |
| 🟡 P1 | Exact Server fingerprint | Very small | Information disclosure |
| ✅ Remediated | Enforce TLS 1.2+ / support TLS 1.3-only | — | Verified |
| ✅ Remediated | Per-IP limiting and trusted-proxy boundary | — | Client isolation and non-forgeable forwarding boundary |
| 🟢 P2 | Bearer scheme casing | Very small | RFC compliance |
| 🟢 P3 | Content-Type error detail | Very small | Information disclosure |
| 🟢 P3 | HTTP method casing | Very small | RFC compatibility |

---

## Conclusion

Both original P0 issues and per-client limiting have been remediated, and HTTP request/response framing has been tightened further. Production proxy deployments must prevent bypass of the ZiServer port and sanitize XFF according to the [client-IP deployment guide](../operations/client-ip-rate-limit.md). Cross-replica aggregation and full QUIC transport remain edge/future capabilities. The XSS observer is telemetry only and never replaces context-aware output encoding or browser CSP.
