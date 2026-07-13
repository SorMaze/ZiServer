# ZiServer 安全审计报告

> 修复状态（2026-07-13）：本文保留最初审计发现作为历史记录。默认凭证、公开 CORS 的 `Authorization`、精确 `Server` 指纹、全局安全响应头、TLS 最低版本和进程全局共享限流预算问题已经修复。限流现按规范化客户端 IP 分桶；转发头默认不受信，只有直连 peer 命中显式可信代理 CIDR 时才解析有界 XFF 链。

**日期**: 2026-07-10  
**审计对象**: ZiServer v0.4 (Zig HTTP 服务器)  
**测试端点**: 
- `http://127.0.0.1:18080/` (HTTP)
- `https://127.0.0.1:18443/` (HTTPS)

---

## 总体评分: ⚠️ 存在多个安全问题

---

## 🔴 高危发现

### 1. 默认凭证泄露 (CVSS 9.8) — 已修复

**描述**: 服务器使用硬编码的默认开发凭证：
- **Bearer Token**: `dev-token`
- **API Key**: `dev-key`

这些凭证在 `src/compose/auth.zig` 中定义为 `default_credentials`，并在 README.md 中公开记录。如果服务器部署到网络环境且未通过环境变量或命令行参数覆盖，`/admin/stats` 端点将完全暴露。

**验证**:
```bash
# Bearer token 认证 (成功 200)
curl http://127.0.0.1:18080/admin/stats -H "Authorization: Bearer dev-token"
# API Key 认证 (成功 200)
curl http://127.0.0.1:18080/admin/stats -H "X-API-Key: dev-key"
```

**建议**: 
- 启动时强制要求设置 `ZISERVER_BEARER_TOKEN` 和 `ZISERVER_API_KEY` 环境变量
- 如果使用默认值，启动时打印明显警告
- 不要在生产文档中公开默认凭证

---

### 2. CORS 配置不安全 - 通配符源与 Authorization 头部组合 (CVSS 7.5) — 已修复

**描述**: CORS 中间件（`src/compose/cors.zig`）配置为：
- `Access-Control-Allow-Origin: *` (通配符，允许任意源)
- `Access-Control-Allow-Headers: Content-Type, Authorization`
- `Access-Control-Allow-Methods: GET, HEAD, POST, OPTIONS`

任何网站都可以对 `/api/echo` 和 `/submit` 发起跨域请求，并且可以携带 `Authorization` 头部。这意味着恶意网站可以通过 JavaScript 发起携带 Bearer Token 的请求。

**验证**:
```bash
curl -X OPTIONS http://127.0.0.1:18080/api/echo \
  -H "Origin: http://evil.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type"
# 返回 Access-Control-Allow-Origin: *
```

**建议**:
- 将 `*` 替换为明确的白名单域名
- 如果必须支持公开 API，将 `Authorization` 从 `allowed_headers` 中移除
- 考虑按路由配置不同的 CORS 策略

---

### 3. XSS 过滤器覆盖面不足 (CVSS 6.1)

> 当前状态（2026-07-12）：已增强并可配置。`/submit` 与 `/api/echo` 均声明 `xssObserve()`；运行时可用 `--xss-mode=block` 将服务器最低策略提升为阻断，且路由不能将其降级。有界双轮规范化会处理常见百分号/双重百分号编码及 ASCII 数字实体，检测覆盖危险标签、协议、CSS expression、`srcdoc` 和通用 `on*` 事件属性。以下描述与验证保留为历史审计记录。

**描述**: 
- `/submit` 路由使用 `xssObserve()` 模式（仅记录，不拦截）
- `/api/echo` 路由**完全没有** XSS 过滤层
- XSS 检测规则有限，可被多种方式绕过

**验证**:
```bash
# /api/echo 成功接收并回显 XSS payload（无过滤）
curl -X POST http://127.0.0.1:18080/api/echo \
  -H "Content-Type: application/json" \
  -d '{"message":"<img src=x onerror=alert(1)>","count":1}'
# 返回: {"message":"<img src=x onerror=alert(1)>",...}  200 OK

# /submit 仅记录不拦截
curl -X POST http://127.0.0.1:18080/submit \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=<script>alert(1)</script>&email=test@test.com"
# 返回 202 Accepted（payload 被接受）
```

**历史实现的 XSS 检测签名不足**（现已拆分到 `src/compose/xss.zig` 并增强）:
- 仅检测9个固定模式
- 缺少对 `onfocus`, `onmouseover`, `expression()`, `data:text/html`, `` ` `` 模板注入, SVG 事件等的检测
- Unicode 编码变体未被覆盖（如 `＜script＞` 全角字符）

**建议**:
- 在 `/api/echo` 和所有回显用户输入的路由上添加 XSS 过滤
- 考虑输出编码/HTML 转义而非仅做输入检测
- 将 observe 模式改为 block 模式用于回显路由

即使启用 `block`，该组件仍是纵深防御，不承诺识别所有 HTML/Unicode/浏览器解析变体；上下文相关输出编码、JSON 序列化和 CSP 仍是主要边界。

---

## 🟡 中危发现

### 4. 服务器指纹信息泄露 (CVSS 5.3) — 已修复

**描述**: 所有响应包含 `Server: ZiServer/0.4` 头部，泄露了精确的软件名称和版本。

**影响**: 攻击者可以快速识别服务器技术栈并针对已知漏洞进行攻击。

**建议**: 移除 `Server` 头部或提供通用值如 `Server: webserver`。

---

### 5. 缺少安全头部 (CVSS 5.0) — 已修复基础项

**描述**: 响应中缺少以下标准安全头部：

| 缺失的安全头部 | 风险 |
|---|---|
| `X-Content-Type-Options: nosniff` | MIME 类型嗅探攻击 |
| `X-Frame-Options: DENY` | Clickjacking 攻击 |
| `Content-Security-Policy` | XSS/注入防护 |
| `Strict-Transport-Security` | SSL 降级攻击 |
| `Referrer-Policy` | 信息泄露 |
| `Permissions-Policy` | 浏览器特性滥用 |

**建议**: 为所有响应添加基本的安全头部，至少包括：
```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Strict-Transport-Security: max-age=31536000; includeSubDomains
Referrer-Policy: strict-origin-when-cross-origin
```

---

### 6. TLS 配置问题 (CVSS 5.0) — 已修复并增强 TLS 1.3

**描述**: 
- README 声称最低 TLS 1.2，但测试表明 TLS 1.0 和 1.1 连接成功（curl `--tls-max 1.0` 成功获取页面）
- 开发证书使用 `127.0.0.1` 作为 CN，但建议使用 `localhost`

**建议**:
- 在 OpenSSL 配置中明确设置 `SSL_CTX_set_min_proto_version(TLS1_2_VERSION)`
- 重新生成开发证书使用 `localhost` CN

---

### 7. 不安全的直接对象引用 (IDOR) - 源码暴露风险 (CVSS 4.3)

**描述**: 静态文件服务依赖于 `public/` 目录过滤，但 `.env`、`.git` 等敏感路径需要确认不可访问。

**验证**:
```bash
# 以下请求返回 404（当前安全）
curl http://127.0.0.1:18080/.env          # 404 ✓
curl http://127.0.0.1:18080/src/main.zig  # 404 ✓
curl http://127.0.0.1:18080/assets/../../../README.md  # 404 ✓
```

**当前状态**: ✓ 安全 - 路径遍历防护有效

---

## 🟢 低危发现

### 8. 限流器为进程级而非按IP (CVSS 3.7)

**当前状态（2026-07-13）**: ✓ 已修复。`src/core/rate_limiter.zig` 使用服务实例所有的有界分片表，按 `(client_ip, policy)` 分桶；`src/core/client_identity.zig` 从 socket peer 建立根信任，提供可信代理 CIDR 和从右向左的 XFF 解析。容量耗尽 fail-closed，且有独立统计。该状态仍是单进程内限流，多副本聚合限制应由可信边缘或未来共享后端完成。

**描述**: `src/compose/rate_limit.zig` 使用全局静态原子计数器实现固定窗口限流：
- `strict` 策略: 每秒 20 请求（所有 strict 路由共享）
- `relaxed` 策略: 每秒 120 请求（所有 relaxed 路由共享）
- 无按客户端 IP 的区分

**影响**: 单个攻击者可以耗尽所有路由的限流预算。

**验证**: 20+ 并发请求到 `/submit` 后返回 429。
```bash
# 约20个请求后触发 429
for i in $(seq 1 50); do curl -o /dev/null -w "%{http_code} " .../submit; done
# 输出: 202 202 ... 429 429 429 ...
```

**建议**: 实现按 IP 的限流计数器（使用哈希表映射 IP -> 窗口计数器）。

---

### 9. Bearer 前缀大小写敏感（RFC 偏差）(CVSS 2.6)

**描述**: `hasBearer()` 使用 `startsWith` 精确匹配 `"Bearer "`，不接受 `"bearer "` 或 `"BEARER "`（RFC 7235 要求大小写不敏感）。

**建议**: 使用大小写不敏感的前缀比较。

---

### 10. Content-Type 泄露 (CVSS 2.3)

**描述**: 415 错误响应泄露支持的 Content-Type：
```json
{"error":"unsupported_media_type","expected":"application/json, application/x-www-form-urlencoded, or multipart/form-data"}
```

**建议**: 返回通用的 "Unsupported Media Type" 消息。

---

### 11. HTTP 方法解析大小写敏感 (CVSS 2.0)

**描述**: `parseMethod()` 仅识别大写的 `GET`、`POST` 等。小写 `get` 被解析为 `.unknown`。虽然 RFC 要求方法名大小写敏感，但这可能导致与其他 HTTP 库的兼容性问题。

---

## ✅ 已通过的安全测试

| 测试项 | 状态 | 说明 |
|---|---|---|
| 路径遍历 (`../`) | ✅ 通过 | `validPath()` 拒绝含 `..` 的路径 |
| 路径遍历 (编码 `%2e%2e%2f`) | ✅ 通过 | 返回 404 |
| Null 字节注入 (`%00`) | ✅ 通过 | 返回 404 |
| CRLF 注入 (Header) | ✅ 通过 | `containsLineBreak()` 检测并拒绝 |
| CRLF 注入 (URL 编码 `%0d%0a`) | ✅ 通过 | 返回 404 |
| HTTP/2 h2c 明文降级 | ✅ 通过 | 返回 505 |
| HTTP/2 错误 listener 重定向 + 超过 16 KiB POST | ✅ 通过 | 先发布 308，持续排空 DATA，request queue 与 multiplexed session 不阻塞 |
| CONNECT 代理滥用 | ✅ 通过 | 返回 405 |
| TRACE XST 攻击 | ✅ 通过 | 返回 405 |
| 超大 Body (buffer overflow) | ✅ 通过 | 有 16KB 全局限制 + 路由级限制 |
| 超长 URL | ✅ 通过 | 正常返回（已安全处理） |
| Host 头部注入与重定向投毒 | ✅ 通过 | canonical host 固定 Location；allowlist 拒绝未知 Host；wildcard TLS 缺少策略时拒绝启动 |
| .env / 源码暴露 | ✅ 通过 | 静态文件仅服务 public/ 目录 |
| 限流器基本功能 | ✅ 通过 | 20+ 请求后返回 429 |
| 401 未授权响应 | ✅ 通过 | 正确返回 401（无信息泄露） |
| HTTP 方法限制 | ✅ 通过 | PUT/DELETE/PATCH/CONNECT/TRACE 返回 405 |

---

## 修复优先级建议

| 优先级 | 问题 | 工作量 | 影响 |
|---|---|---|---|
| 🔴 P0 | 默认凭证泄露 | 小 | 未授权访问 |
| 🔴 P0 | CORS wildcard + Authorization | 小 | 跨域凭证盗取 |
| 🟡 P1 | 添加安全头部 | 小 | 防范多种客户端攻击 |
| 🟡 P1 | 修复 XSS 过滤器覆盖面 | 中 | 跨站脚本防护 |
| 🟡 P1 | 移除 Server 头部 | 极小 | 信息泄露 |
| ✅ 已修复 | 强制 TLS 1.2+ 并支持 TLS 1.3-only | - | 已验证 |
| ✅ 已修复 | 按 IP 限流与可信代理边界 | - | 客户端隔离且转发头不可任意伪造 |
| 🟢 P2 | Bearer 前缀大小写 | 极小 | RFC 合规 |
| 🟢 P3 | Content-Type 错误消息 | 极小 | 信息泄露 |
| 🟢 P3 | HTTP 方法大小写 | 极小 | RFC 合规 |

---

## 结论

原审计的两个 P0 项及按客户端限流已经修复，HTTP 请求/响应定界也已进一步收紧。生产代理部署必须限制 ZiServer 端口不可被绕过，并按 [`../operations/client-ip-rate-limit.md`](../operations/client-ip-rate-limit.md) 清洗 XFF；多副本聚合限制和完整 QUIC transport 仍属于边缘/后续能力。XSS 观察器只能作为遥测信号，不能替代上下文相关输出编码和浏览器 CSP。
