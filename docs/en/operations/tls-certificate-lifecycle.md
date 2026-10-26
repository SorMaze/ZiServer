# Certificate revocation, replacement and client authentication

OpenSSL HTTPS supports in-process certificate/key replacement and updates to client CA, CRL and signed OCSP material for HTTP/1.1 and HTTP/2. Experimental HTTP/3 cannot be combined with this feature; startup rejects that combination. SChannel remains a placeholder.

## Local desired state

Keep the control file and keys outside all public/static/upload directories. Restrict write access to administrators and grant the service account read access. This file grants local administrative control; there is no HTTP administration endpoint.

Create `/secure/ziserver/tls.json`:

```json
{"revision": 1, "cert_file": "v1/fullchain.pem", "key_file": "v1/privkey.pem"}
```

```sh
zig build run -- --host=127.0.0.1 --tls-control=/secure/ziserver/tls.json
```

The control file enables TLS and is the authoritative certificate source; startup certificate/key arguments are unnecessary. Credential paths resolve relative to the control file. The file must exist and be valid at startup; an explicit `revoked: true` is a valid disabled initial state. Polling defaults to 1000 ms; `--tls-control-interval=MS` accepts 50–60000 ms.

Write a complete new credential pair into a new version directory, increment `revision`, then atomically rename the complete replacement JSON over the control file on the same filesystem. Do not overwrite certificate and key files separately. Every retry needs a higher revision, including retries after failed reloads. The process ignores equal or older revisions.

```json
{"revision": 2, "cert_file": "v2/fullchain.pem", "key_file": "v2/privkey.pem", "close_existing": false}
```

Parsing, validity and private-key matching must succeed before publication. Ordinary rotation preserves established connections; new handshakes use the replacement and cannot resume old tickets/cache entries. `close_existing: true` also closes old TLS connections and in-flight handshakes.

Invalid JSON, missing files, expired certificates and key mismatches retain the working state and log `tls_control_failed`. Missing/broken control files never re-enable a disabled credential. A valid deny policy takes effect before replacement: a denied active credential stays disabled even if its replacement fails. Restart loads the current file; persist it and prevent operational rollback to historical policies.

## Emergency disable and key blocklists

```json
{"revision": 3, "revoked": true}
```

This blocks new TLS handshakes and closes existing TLS connections. HTTP remains available. If client authentication was required, retain `client_ca_file` in the disabled state so plaintext access remains forbidden after restart:

```json
{"revision": 3, "revoked": true, "client_ca_file": "clients/ca.pem"}
```

Recover with a higher revision pointing to safe credentials and retaining required authentication/blocklist fields.

`deny_cert_sha256` blocks certificate DER hashes; `deny_spki_sha256` blocks full DER SubjectPublicKeyInfo hashes. Each accepts at most 64 hexadecimal SHA-256 values, 64 characters without colons. Generate a new key after compromise: reissuing with the same key cannot bypass an SPKI block. Rules cover the configured full server chain and the verified mTLS peer chain. Issuers absent from the supplied server chain cannot be inspected.

```json
{
  "revision": 4,
  "cert_file": "v3/fullchain.pem",
  "key_file": "v3/privkey.pem",
  "deny_spki_sha256": ["replace-with-the-blocked-SPKI-64-character-hex-SHA256"]
}
```

Blocklist updates close existing TLS connections. Each document describes complete desired state; retain blocklists that must remain effective during later rotations.

Use `openssl x509 -in cert.pem -noout -fingerprint -sha256` and remove the colons for a certificate hash. Avoid binary shell pipelines on Windows when computing SPKI hashes:

```sh
openssl x509 -in cert.pem -pubkey -noout -out public.pem
openssl pkey -pubin -in public.pem -outform DER -out public.der
openssl dgst -sha256 public.der
```

## Client CRL and OCSP validation

```json
{
  "revision": 5,
  "cert_file": "v3/fullchain.pem",
  "key_file": "v3/privkey.pem",
  "client_ca_file": "clients/ca-bundle.pem",
  "client_crl_file": "clients/crl-bundle.pem",
  "client_ocsp_files": ["clients/client-a.ocsp.der"]
}
```

- `client_ca_file` enables mandatory client authentication using a dedicated CA bundle. It requires CRL material, OCSP material, or both.
- `client_crl_file` is a PEM CRL bundle. Signatures and freshness are checked before publication; complete-chain revocation checks run during handshakes. Missing/expired issuer CRLs fail authentication.
- Up to 64 DER OCSP responses are accepted. Signatures, authorized signers, matching CertIDs and freshness are checked. SHA-1/SHA-256 and other OpenSSL-supported CertID digests work. Only matching `GOOD` status admits a client; missing, `UNKNOWN` and `REVOKED` statuses fail. A `GOOD` response cannot override a signed `REVOKED` response.
- OCSP requires `thisUpdate`/`nextUpdate`, allows 300 seconds of clock skew, and limits `thisUpdate` age to 86400 seconds. Remove obsolete responses when publishing new sets; expired material cannot be loaded into a replacement policy.
- If both CRL and OCSP are supplied, both must pass. External automation obtains signed OCSP responses from a trusted responder; the server makes no online OCSP requests or client-controlled network lookups. Increment the control revision after updating material.
- Trust-policy updates close established TLS connections. mTLS disables session resumption so every new connection checks revocation again. Established connections are not automatically reauthenticated when a CRL/response naturally expires; publish a policy update to cut them off.
- Plain HTTP returns 403 and existing plaintext connections close while client authentication is required. Explicitly set `disable_client_auth: true` in a policy without `client_ca_file` to turn off previously enabled client authentication.

## Public CA revocation and trust-store updates

Local `revoked` state does not submit a public CA revocation request. Use the issuer's management interface or an ACME client, and replace compromised keys. See [Let's Encrypt's revocation procedure](https://letsencrypt.org/docs/revoking/).

The October 2026 eMudhra intermediate-key incident required verifier-side trust updates. Mozilla distributed OneCRL blocks and updated NSS; replacing a server certificate does not update browsers, operating systems or other client trust stores. See [Mozilla's incident statement](https://blog.mozilla.org/security/2026/10/20/protecting-firefox-users-following-the-compromise-of-emudhra-intermediate-certificates/).

## Regression tests

The fixture dependency is test-only. Generated keys and certificates stay isolated; the system trust store is not modified:

```sh
python -m pip install -r scripts/requirements-tls-test.txt
python scripts/tls-test-fixtures.py .zig-cache/tls-reload-fixtures
zig build --prefix .zig-cache/tls-reload-debug
node scripts/tls-reload-test.mjs --server=.zig-cache/tls-reload-debug/bin/ziserver --fixtures=.zig-cache/tls-reload-fixtures
```

Append `.exe` on Windows. Regressions cover rotation, old tickets, emergency revocation and persisted state, CRL/OCSP good/revoked/unknown/expired/forged cases, authentication downgrade protection, and concurrent handshakes.
