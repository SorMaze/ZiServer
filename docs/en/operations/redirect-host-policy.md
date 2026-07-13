# Protocol-Correction Redirect Host Policy

[简体中文原文](../../zh-CN/operations/redirect-host-policy.md)

> [!NOTE]
> This English document was translated with the assistance of a large language model (LLM). If an interpretation differs, the Simplified Chinese source is authoritative.

ZiServer performs dual-listener protocol correction before router/middleware execution. To prevent a syntactically valid but attacker-controlled `Host`/`:authority` from entering `Location`, the redirect host is resolved in this order:

1. When `canonical-host` is configured, always emit it.
2. Without canonical but with allowed hosts, accept only a request matching the allowlist and emit the corresponding configured value.
3. With neither and a concrete bind address, use that address as fallback.
4. Startup fails when the TLS bind is an IPv4/IPv6 unspecified address without explicit policy. Detection uses the parsed address value, so `::` equals `0:0:0:0:0:0:0:0`.

Once `--allowed-host` appears, it restricts input Host. A simultaneously configured canonical host is implicitly allowed. Domain comparison is case-insensitive; IPv4/IPv6 comparison uses normalized addresses. Values may contain only a hostname or IP literal—never scheme, port, path, fragment, or userinfo.

## One public name

```powershell
zig build run -- `
  --host=0.0.0.0 `
  --canonical-host=app.example.com `
  --tls-cert=.dev-certs/lan.pem `
  --tls-key=.dev-certs/lan-key.pem
```

Even with `Host: attacker.example`, redirects only target `app.example.com`. To reject unknown Host values outright, also add:

```powershell
--allowed-host=app.example.com
```

## Multiple LAN entry points

```powershell
zig build run -- `
  --host=0.0.0.0 `
  --allowed-host=192.168.31.47 `
  --allowed-host=server.lan `
  --tls-cert=.dev-certs/lan.pem `
  --tls-key=.dev-certs/lan-key.pem
```

Equivalent environment configuration:

```powershell
$env:ZISERVER_CANONICAL_HOST="app.example.com"
$env:ZISERVER_ALLOWED_HOSTS="app.example.com,api.example.com"
```

A reverse proxy should still validate external Host at the edge. This policy protects only ZiServer-generated protocol-correction redirects; it does not replace the proxy's virtual-host boundary.

The protocol adapter parses and validates the complete `Location` independently before writing a 308. Only authority, target path, or Host-policy validation failures become 400. Socket, HTTP/2 output-queue, response-capture, and allocation failures terminate the request unchanged and never attempt a second 400 after a partial response.
