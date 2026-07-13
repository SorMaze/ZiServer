# ZiServer Documentation

English | [简体中文](README.md)

> [!NOTE]
> This English documentation was translated with the assistance of a large language model (LLM). If an interpretation differs, the corresponding Simplified Chinese source is authoritative.

Documentation is grouped by purpose. The root [`README.md`](../README.md) provides the build, runtime, configuration, and performance overview; this directory contains implementation, deployment, and maintenance details.

## Architecture and roadmap

- [Layer boundaries](en/architecture/overview.md): responsibilities and one-way dependencies among `core`, `compose`, and `app`.
- [Page response cache design](en/architecture/page-cache.md): keys, safe bypasses, concurrent fills, and external configuration.
- [Gaps and implementation roadmap](en/architecture/roadmap.md): current completion state and P0/P1/P2 priorities.

## Guides

- [Unified content extraction and injection](en/guides/content.md): JSON, XML, HTML, TOML, binary data, and custom codecs.
- [Database middleware abstraction](en/guides/database.md): pools, request lifetime, and the PostgreSQL adapter boundary.
- [Bidirectional HTTP/1 and HTTP/2 streaming](en/guides/streaming.md): readers, writers, backpressure, cancellation, and protocol behavior.
- [User upload interception and handling](en/guides/upload.md): validation, small-file persistence, and large-file streaming.

## Operations

- [Client IP and rate-limit deployment](en/operations/client-ip-rate-limit.md): direct deployment, trusted proxies, capacity, and privacy.
- [Protocol-correction redirect Host policy](en/operations/redirect-host-policy.md): canonical, allowlist, and fallback rules.
- [Per-client-IP rate-limit checklist](en/operations/rate-limit-client-ip-checklist.md): historical review, implementation status, and acceptance gates.

## Security

- [Security audit report](en/security/security-audit.md): historical findings, remediation status, remaining risks, and verification records.

## Licenses

Project and third-party license texts are legal originals and are intentionally not translated:

- [BSD 2-Clause License](../LICENSE)
- [Third-party notices](../THIRD_PARTY_NOTICES.md)
- [Third-party license directory](../LICENSES/)
