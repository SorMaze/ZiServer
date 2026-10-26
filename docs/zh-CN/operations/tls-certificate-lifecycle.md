# TLS 证书停用、热替换与客户端吊销校验

OpenSSL 的 HTTPS listener 支持在同一进程内替换证书链和私钥，以及热更新客户端 CA、CRL 和签名 OCSP 响应。HTTP/1.1 与 HTTP/2 共用该策略。实验性 HTTP/3 与此功能不能同时启用；启动参数会拒绝该组合。SChannel 仍是占位实现。

## 启动和更新

将控制文件及私钥放在站点静态目录之外，只授予服务账号读取权限，并限制谁可以修改控制文件。控制文件是本地管理权限入口，不应由上传接口写入或由 HTTP 提供下载。

例如 `/secure/ziserver/tls.json`：

```json
{
  "revision": 1,
  "cert_file": "v1/fullchain.pem",
  "key_file": "v1/privkey.pem"
}
```

```sh
zig build run -- --host=127.0.0.1 --tls-control=/secure/ziserver/tls.json
```

`--tls-control` 自动开启 TLS；证书来源由控制文件决定，无需再传 `--tls-cert` / `--tls-key`。路径相对于控制文件所在目录解析。启动前控制文件必须存在且有效；`revoked: true` 可以作为有效的初始停用状态。默认每 1000 ms 检查一次，可用 `--tls-control-interval=MS` 设置为 50–60000 ms。

换证时先把完整的新证书和新私钥写到新的版本目录，递增 `revision`，再在同一文件系统内将完整的新 JSON 文件原子重命名为控制文件。不要逐个覆盖正在使用的证书和私钥。每次修正失败的更新也应递增版本；进程内相同或更小的版本不能回滚状态。

```json
{
  "revision": 2,
  "cert_file": "v2/fullchain.pem",
  "key_file": "v2/privkey.pem",
  "close_existing": false
}
```

新证书通过解析、有效期和私钥匹配检查后才发布。普通换证保留既有连接，新握手使用新证书；会话票据和会话缓存不跨代复用。`close_existing: true` 同时关闭旧 TLS 连接及尚在握手的旧代连接。

JSON 无效、文件缺失、证书过期或密钥不匹配时，保留最后可用状态并记录 `tls_control_failed`。缺失或损坏的控制文件不会把停用状态变回启用。有效的封禁先于替换生效：若当前证书被新策略封禁，即使新证书加载失败，也保持停用，不继续提供被封禁证书。重启从当前控制文件读取状态；运维应持久保存该文件，并避免回滚到历史策略。

## 紧急停用与公钥封禁

```json
{"revision": 3, "revoked": true}
```

该操作拒绝新 TLS 握手，并关闭现存 TLS 连接。HTTP listener 保持运行。若此前启用了客户端认证，应在停用文件中保留 `client_ca_file`，使重启后明文访问也保持禁止，例如：

```json
{"revision": 3, "revoked": true, "client_ca_file": "clients/ca.pem"}
```

恢复服务时发布更高版本，指向安全的新证书/私钥，并保留所需的客户端认证和封禁配置。

也可配置 `deny_cert_sha256`（证书 DER 的 SHA-256）和 `deny_spki_sha256`（完整 DER SubjectPublicKeyInfo 的 SHA-256）。每组最多 64 个、每个为不带冒号的 64 位十六进制值。公钥泄露后应生成新密钥；只换一张使用相同公钥的证书不能绕过 SPKI 封禁。封禁规则检查提供的完整服务端证书链，以及 mTLS 客户端经过验证的证书链。必须提供完整中间链，无法检查配置中未提供的服务端颁发者证书。

```json
{
  "revision": 4,
  "cert_file": "v3/fullchain.pem",
  "key_file": "v3/privkey.pem",
  "deny_spki_sha256": ["替换为被封禁公钥的64位十六进制SHA256值"]
}
```

新增封禁规则会关闭既有 TLS 连接，防止旧连接继续使用已撤销的身份。控制文件描述完整期望状态；以后换证时也应保留仍需生效的封禁列表。

证书指纹可用 `openssl x509 -in cert.pem -noout -fingerprint -sha256` 查看，去掉冒号后填写。为避免 Windows shell 的二进制管道改变 DER 内容，SPKI 指纹可以通过公共临时文件计算：

```sh
openssl x509 -in cert.pem -pubkey -noout -out public.pem
openssl pkey -pubin -in public.pem -outform DER -out public.der
openssl dgst -sha256 public.der
```

## 客户端证书：CRL 与 OCSP

在同一文件中加入客户端信任材料，启用强制客户端证书认证：

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

- `client_ca_file` 指定专用客户端 CA 包；客户端必须提供可验证的证书链。配置时必须同时提供 CRL、OCSP 或两者。
- `client_crl_file` 是 PEM CRL 包。装载时检查签名和有效期；握手时检查完整链的吊销状态。必须提供各颁发者所需的有效 CRL，缺失或过期时认证失败。
- `client_ocsp_files` 最多包含 64 个 DER OCSP 响应。检查响应签名、授权签名者、匹配的 CertID 和时间；支持 SHA-1/SHA-256 等受 OpenSSL 支持的 CertID 摘要。只接受匹配客户端的 `GOOD`；缺失、`UNKNOWN` 或 `REVOKED` 均拒绝。`REVOKED` 不能被另一份 `GOOD` 覆盖。
- OCSP 要求 `thisUpdate` / `nextUpdate`，容许 300 秒时钟偏差，`thisUpdate` 最多早于当前 86400 秒。配置多份响应时应及时清理旧响应；过期材料不会装入新策略。
- 同时配置 CRL 与 OCSP 时，两者都必须通过。OCSP 文件由外部任务从受信任的 responder 获取并更新；服务器不发起在线 OCSP 请求，也不根据客户端输入访问网络地址。每次更新材料后递增控制文件版本。
- 客户端信任策略更新会关闭已有 TLS 连接；mTLS 禁用会话恢复，每次新连接重新验证吊销状态。已建立的连接不会在 CRL/OCSP 自然过期时自动重新握手，应通过策略版本更新主动切断。
- 开启 mTLS 后，明文 HTTP 返回 403，已有明文连接关闭，避免从 HTTP listener 绕过认证。要关闭已启用的 mTLS，必须在无 `client_ca_file` 的新策略中显式设置 `disable_client_auth: true`。

## 与 CA 正式吊销、系统信任库的边界

这里的 `revoked` 是本站立即停用策略，不会替你向公共 CA 提交吊销申请。正式吊销仍由 CA 管理接口或 ACME 客户端执行；私钥泄露时还需要换新密钥。参考 [Let's Encrypt 的吊销流程](https://letsencrypt.org/docs/revoking/)。

2026 年 10 月 eMudhra 中间 CA 私钥事件涉及验证端信任规则；Mozilla 通过 OneCRL 封禁了相关证书，并更新了 NSS 信任库。服务端换证不等于替浏览器、操作系统或其他客户端修复信任库。参考 [Mozilla 官方事件说明](https://blog.mozilla.org/security/2026/10/20/protecting-firefox-users-following-the-compromise-of-emudhra-intermediate-certificates/)。

## 回归测试

测试依赖只用于生成隔离 PKI，不属于服务端运行时依赖。测试不会修改系统证书库：

```sh
python -m pip install -r scripts/requirements-tls-test.txt
python scripts/tls-test-fixtures.py .zig-cache/tls-reload-fixtures
zig build --prefix .zig-cache/tls-reload-debug
node scripts/tls-reload-test.mjs --server=.zig-cache/tls-reload-debug/bin/ziserver --fixtures=.zig-cache/tls-reload-fixtures
```

Windows 为可执行文件补上 `.exe`。回归覆盖换证不中断既有连接、旧票据失效、紧急停用与重启保持状态、CRL/OCSP 的正常/吊销/未知/过期/伪造状态、认证降级防护和并发握手。
