# ZiServer

[English](README.md) | 简体中文

完整的分类文档见[文档中心](docs/README.md)。

使用 Zig master 版本 `0.17.0-dev.1282+c0f9b51d8` 构建的高并发 HTTP 服务器。

## 平台支持与当前限制

当前唯一经过构建、功能回归、HTTP/2 soak 和内存稳定性验证的平台是 **Windows x86_64**。Windows 使用 vcpkg 提供的 OpenSSL/nghttp2，并包含 Windows 专用的 AFD 可取消 socket 读取路径。

Linux、macOS 及其他目标虽然保留了部分可移植代码和 `std.Io` deadline 路径，但尚未完成同等级的 CI、协议回归、长稳态压测或发布验证，因此当前不应宣称为受支持平台。Windows SChannel provider 仍是占位；TLS/HTTP/2 的已验证组合是 OpenSSL + nghttp2。原生 HTTP/3 仍为实验性单连接实现，未完成生产级多连接、GOAWAY 与完整 router/middleware 集成。

## 运行

默认构建会编译 OpenSSL TLS 和 nghttp2 provider。Windows 推荐先通过 vcpkg 安装依赖，并设置任一受支持的 vcpkg 根目录环境变量：

### vcpkg 依赖

```powershell
vcpkg install openssl:x64-windows nghttp2:x64-windows ngtcp2[openssl]:x64-windows nghttp3:x64-windows
$env:VCPKG_ROOT="D:\path\to\vcpkg"
```

```powershell
zig build run
```
或：

```powershell
zig build run -- --tls-cert=.dev-certs/localhost.pem --tls-key=.dev-certs/localhost.key --tls-min=1.3 --host=127.0.0.1 --canonical-host=localhost
```

打开 <http://127.0.0.1:18080/> 或 <https://localhost:18443/>。`localhost` 开发证书只适合本机；不要将它和 `--host=0.0.0.0` 组合成局域网 TLS 配置。

默认编译 HTTP/2 provider，但未配置证书时只监听明文 HTTP/1.1，HTTP/2 保持 `reject`。配置证书和私钥后，同一进程会同时监听 `http://127.0.0.1:18080/` 和 `https://127.0.0.1:18443/`，HTTPS listener 默认启用 HTTP/2；不需要再重复传入 `-Dtls=openssl -Dhttp2=nghttp2`。

默认入口 `/` 由动态 handler 渲染，静态资源仍可通过 `/assets/style.css` 和 `/assets/app.js` 拉取。`/stats` 是一个被动的一次性 JSON 端点，除连接指标外还包含页面缓存容量、命中、淘汰及同 key miss 合并指标。

默认构建使用运行时文件系统静态资源模式。`zig build` 会把 `src/public/` 安装到 `zig-out/public/`，安装时会对比文件内容，只有目标不存在或内容变化时才替换。开发时 `zig build run` 会自动使用 `src/public/`。直接运行安装后的二进制时，可以在安装前缀目录运行，或显式传入静态目录：

```powershell
zig build
Set-Location zig-out
bin\ziserver.exe

# 或从项目根目录运行
zig-out\bin\ziserver.exe --static-dir=zig-out\public
```

## 参数

- `--host=127.0.0.1`: 监听地址
- `--port=N`: 兼容旧版的主端口参数；配置证书时表示 HTTPS 端口，否则表示 HTTP 端口
- `--http-port=18080`: 明文 HTTP listener 端口
- `--https-port=18443`: 配置证书后启用的 HTTPS listener 端口；必须与最终 HTTP 端口不同
- `--acceptors=N`: accept 线程总数，默认自动，最多 8；双 listener 至少各分配一个
- `--workers=N`: 固定连接处理 worker 数量，默认自动，最多 128
- `--queue=N`: 已 accept 待处理连接队列容量，默认自动
- `--shards=N`: 普通连接队列分片数量，默认自动，最多 4
- `--backlog=N`: 内核 listen backlog，默认 16384
- `--keep-alive=N`: 每个连接请求复用基线，默认 1000；HTTP/1.1 严格达到上限后关闭连接，HTTP/2 为已接收的并发 stream 保留最多 128 个 drain 余量后发送 GOAWAY；设为 0 禁止连接复用
- `--tls-handshake-timeout=MS`: TLS 握手绝对超时，默认 10000；设为 0 禁用
- `--header-timeout=MS`: 请求 header 绝对超时，默认 10000；设为 0 禁用
- `--body-timeout=MS`: 请求 body 绝对超时，默认 30000；设为 0 禁用
- `--keep-alive-timeout=MS`: HTTP/1.1 和 HTTP/2 空闲连接超时，默认 15000；设为 0 禁用
- `--shutdown-grace=MS`: Ctrl+C、SIGINT 或 SIGTERM 后等待活动连接排空的最长时间，默认 30000
- `--rate-limit-relaxed=N`: 每个规范化客户端 IP 的 relaxed 每秒请求数，默认 0（不限流）
- `--rate-limit-strict=N`: 每个规范化客户端 IP 的 strict 每秒请求数，默认 0（不限流）
- `--rate-limit-capacity=N`: `(client IP, policy)` 最大条目数，默认 65536，最大 1048576
- `--rate-limit-shards=N`: 限流锁分片数，默认 64，最大 256 且不能超过 capacity
- `--rate-limit-idle-ttl=MS`: 空闲限流条目保留时间，默认 600000，最小 1000
- `--client-ip-header=none|x-forwarded-for`: 客户端身份头模式，默认 `none`，即始终忽略转发头
- `--trusted-proxy=CIDR`: 允许提供 XFF 的直连代理网段，可重复；启用 XFF 时至少需要一个
- `--forwarded-max-hops=N`: XFF 最大地址数，默认 16，范围 1–32
- `--canonical-host=HOST`: 协议纠正重定向固定使用的主机名或 IP，不允许 scheme、端口、路径或 userinfo
- `--allowed-host=HOST`: 允许触发协议纠正重定向的请求 Host，可重复；配置后，canonical host 也被隐式允许
- `--xss-mode=off|observe|block`: 服务器级 XSS 最低策略，默认 off；路由策略只能加强，不能弱化该值
- `--xss-scan-query=on|off`: XSS 策略启用时是否扫描 query，默认 on
- `--xss-scan-body=on|off`: XSS 策略启用时是否扫描 body，默认 on
- `--stats=on|off`: 是否启用实时原子统计，默认 on
- `--no-stats`: 等同于 `--stats=off`
- `--access-log=on|off`: 是否逐请求输出访问日志，默认 on
- `--no-access-log`: 等同于 `--access-log=off`；适合纯吞吐压测或由上游代理统一记录访问日志的部署
- `--log-level=trace|debug|info|warn|error`: 最低日志等级，默认 `info`；4xx 请求为 `warn`，5xx 为 `error`
- `--log-format=pretty|json`: PowerShell 易读格式或严格 JSON Lines，默认 `pretty`
- `--log-color=auto|on|off`: 颜色策略，默认 `auto`；只在交互终端启用，重定向输出不会包含 ANSI 控制码
- `--page-cache=on|off`: 是否启用动态页面服务器端缓存，默认 on
- `--no-page-cache`: 等同于 `--page-cache=off`
- `--page-cache-capacity=N`: 页面缓存总条目数，默认 256，范围 1–16384
- `--page-cache-shards=N`: 页面缓存锁分片数，默认 16，范围 1–64 且不能超过 capacity
- `--page-cache-max-body=BYTES`: 单个缓存正文上限，默认 262144，最大 1048576
- `--page-cache-ttl-percent=N`: 全局缩放 DSL TTL，默认 100，范围 1–1000
- `--page-cache-header=on|off`: 命中时是否输出 `X-Page-Cache: HIT`，默认 off
- `--page-cache-fill-wait-timeout=MS`: 同 key miss 合并最长等待，默认 100；设为 0 直接绕过
- `--static=embedded|filesystem`: 静态资源提供模式，默认由构建参数决定
- `--static-dir=DIR`: filesystem 模式下的静态资源根目录，默认 `public`
- `--auth-token=TOKEN`: 配置 Bearer auth token
- `--api-key=KEY`: 配置 `X-API-Key` auth 凭证
- `--tls=off|terminate`: TLS 终止模式。没有证书配置时默认 `off`；配置证书或私钥后默认 `terminate`。显式参数优先于自动模式。
- `--tls-cert=FILE`: TLS 证书链文件，优先于 `ZISERVER_TLS_CERT`
- `--tls-key=FILE`: TLS 私钥文件，优先于 `ZISERVER_TLS_KEY`
- `--tls-min=1.2|1.3`: 最低 TLS 版本；默认兼容 TLS 1.2，并优先协商 TLS 1.3。仅允许 TLS 1.3 时设为 `1.3`
- `--http2=off|reject|on`: HTTP/2 处理模式。无 TLS 时默认 `reject`；配置证书后默认 `on`。明文 h2c 仍不开放。
- `--http3=off|advertise`: HTTP/3 宣告模式。默认 `off`；`advertise` 在 HTTPS 响应中通过 `Alt-Svc` 头声明 h3 端点，要求同时启用 TLS termination。当编译时启用 `-Dhttp3=nghttp3` 时，ZiServer 会监听 QUIC/UDP 端口并处理原生 HTTP/3 请求；否则只声明端点由外部反向代理承接。
- `--http3-port=N`: 在 Alt-Svc 头中广播的 QUIC/UDP 端口，默认 `443`。

日志也可通过 `ZISERVER_LOG_LEVEL`、`ZISERVER_LOG_FORMAT`、`ZISERVER_LOG_COLOR` 配置；页面缓存对应 `ZISERVER_PAGE_CACHE`、`ZISERVER_PAGE_CACHE_CAPACITY`、`ZISERVER_PAGE_CACHE_SHARDS`、`ZISERVER_PAGE_CACHE_MAX_BODY`、`ZISERVER_PAGE_CACHE_TTL_PERCENT`、`ZISERVER_PAGE_CACHE_HEADER` 和 `ZISERVER_PAGE_CACHE_FILL_WAIT_TIMEOUT`；XSS 对应 `ZISERVER_XSS_MODE`、`ZISERVER_XSS_SCAN_QUERY` 和 `ZISERVER_XSS_SCAN_BODY`。客户端身份对应 `ZISERVER_CLIENT_IP_HEADER`、逗号分隔的 `ZISERVER_TRUSTED_PROXIES`、`ZISERVER_FORWARDED_MAX_HOPS`；限流容量对应 `ZISERVER_RATE_LIMIT_CAPACITY`、`ZISERVER_RATE_LIMIT_SHARDS`、`ZISERVER_RATE_LIMIT_IDLE_TTL_MS`；重定向 Host 策略对应 `ZISERVER_CANONICAL_HOST` 和逗号分隔的 `ZISERVER_ALLOWED_HOSTS`。CLI 参数优先于环境变量。可信代理部署规则见 [`docs/zh-CN/operations/client-ip-rate-limit.md`](docs/zh-CN/operations/client-ip-rate-limit.md)，分层规则见 [`docs/zh-CN/architecture/overview.md`](docs/zh-CN/architecture/overview.md)，当前缺口与推荐实施顺序见 [`docs/zh-CN/architecture/roadmap.md`](docs/zh-CN/architecture/roadmap.md)。

生产环境需要把已声明 XSS layer 的路由统一提升为阻断时，可以使用 `zig build run -- --xss-mode=block`。XSS 输入检测仅作为纵深防御，不能替代上下文相关输出编码、JSON 序列化和 CSP。

当前服务端采用双 listener + acceptor + sharded bounded queues + 固定 worker pool 的结构。acceptor 会把 socket 提供的对端地址随连接传入 HTTP/1.1/HTTP/2，统一解析为可信 `client_ip` 后再执行 middleware。运维指标通过 `/stats` 暴露，其中 `client_identity` 和 `rate_limit` 提供身份来源、拒绝、容量和回收计数，`page_cache` 提供缓存指标。

如果需要让局域网其他机器访问，可以显式使用：

```powershell
zig build run -- --host=0.0.0.0 --http-port=18080 --https-port=18443
```

上面的命令只启用明文 HTTP。局域网 TLS 必须使用 SAN 包含实际局域网 IP/域名的证书，并为 wildcard bind 声明安全的重定向 Host。例如同时允许 IP 和局域网域名：

```powershell
zig build run -- --host=0.0.0.0 --http-port=18080 --https-port=18443 --tls-cert=.dev-certs/localhost.pem --tls-key=.dev-certs/localhost.key --tls-min=1.3 --allowed-host=192.168.31.47 --allowed-host=server.lan
```

请把示例 IP、域名和证书路径替换为实际值。只有一个公开名称时可改用 `--canonical-host=server.lan`；多个入口应重复使用 `--allowed-host`。wildcard 按解析后的地址语义识别，因此 `::` 与完整展开的 IPv6 未指定地址等价。TLS wildcard bind 缺少 `--canonical-host`/`--allowed-host` 会以配置错误退出，这是防止攻击者控制重定向 `Location` 的安全默认。具体 IP bind 在没有显式策略时会自动作为 fallback。完整规则见 [`docs/zh-CN/operations/redirect-host-policy.md`](docs/zh-CN/operations/redirect-host-policy.md)。

在 Windows 上，如果 `0.0.0.0` 或某个端口被系统策略/保留端口拦住，可能会看到 `ACCESS_DENIED`。这时先用默认的 `127.0.0.1:18080` 验证本机访问，或在管理员 PowerShell 中运行公开监听。

## Release 构建

```powershell
$env:ZIG_GLOBAL_CACHE_DIR="$PWD\.zig-cache\global"
zig build -Doptimize=ReleaseFast
```

生成的二进制在 `zig-out/bin/ziserver.exe`。

静态资源模式可以在构建时选择：

```powershell
# 默认：不把页面烧进 exe，安装 public 目录，运行时读取文件
zig build -Dstatic=filesystem

# 单文件模式：把内置页面烧进 exe
zig build -Dstatic=embedded
```

`filesystem` 模式适合部署后直接替换 `public/` 下的文件；`embedded` 模式适合单文件分发。

TLS/HTTP2/HTTP3 provider 通过构建参数选择：

```powershell
# 默认：编译 OpenSSL + nghttp2，不编译 HTTP/3
zig build

# 完整 HTTP/1.1 + HTTP/2 + HTTP/3 构建
zig build -Dhttp3=nghttp3

# 精简 HTTP/1 构建，不链接 OpenSSL/nghttp2
zig build -Dtls=none

# SChannel 仍是占位 provider；HTTP/2 会随非 OpenSSL provider 自动关闭
zig build -Dtls=schannel
```

`-Dtls=`、`-Dhttp2=` 和 `-Dhttp3=` 是编译期 provider 选择。当前 `-Dhttp3=nghttp3` 依赖 `-Dtls=openssl`；启用后会链接 ngtcp2 和 nghttp3，启动时创建 QUIC/UDP listener 并通过 `Alt-Svc` 声明 h3 端点。默认 `-Dhttp3=none` 保持原来行为，不引入额外编译依赖。

### 库依赖

| 库 | vcpkg 包 | 用途 | 必需 |
|---|---|---|---|
| OpenSSL (libssl + libcrypto) | `openssl:x64-windows` | TLS 1.2/1.3 握手、加密、ALPN | 默认 |
| nghttp2 | `nghttp2:x64-windows` | HTTP/2 帧、HPACK、stream 管理 | 默认 |
| ngtcp2 | `ngtcp2[openssl]:x64-windows` | QUIC transport 层 | `-Dhttp3=nghttp3` |
| ngtcp2_crypto_openssl | (随 ngtcp2 安装) | QUIC + OpenSSL TLS 桥接 | `-Dhttp3=nghttp3` |
| nghttp3 | `nghttp3:x64-windows` | HTTP/3 帧（QPACK、stream 映射） | `-Dhttp3=nghttp3` |

所有三方库通过 C adapter 桥接到 Zig 侧，C 文件只向 Zig 暴露稳定的 extern 函数。除 Zig 标准库外无纯 Zig 第三方依赖。

如果 OpenSSL 不在系统默认搜索路径，可以显式传入 include/lib 目录和库名：

```powershell
zig build -Dtls=openssl -Dhttp2=none `
  -Dopenssl-include=C:\OpenSSL-Win64\include `
  -Dopenssl-lib-dir=C:\OpenSSL-Win64\lib `
  -Dopenssl-ssl-lib=libssl `
  -Dopenssl-crypto-lib=libcrypto
```

`openssl-include` 和 `openssl-lib-dir` 可以是项目根相对路径，也可以是绝对路径。上例是只接入自定义 OpenSSL 的 TLS-only 构建；需要 HTTP/2 时还要提供 nghttp2 的 include/lib，或改用下面的 vcpkg 自动发现。Windows 发行版的库名可能是 `ssl/crypto` 或 `libssl/libcrypto`，按本机安装调整即可。`schannel` 目前仍只是 provider 名称占位。

推荐 Windows 开发环境优先使用 vcpkg 管理 OpenSSL：

```powershell
vcpkg install openssl:x64-windows nghttp2:x64-windows

$env:VCPKG_ROOT="D:\path\to\vcpkg"
zig build
```

vcpkg 根目录按以下优先级解析：`-Dvcpkg-root`、`VCPKG_ROOT`、`VCPKG_INSTALLATION_ROOT`、`VCPKG_HOME`、`Vcpkg_home`。triplet 优先使用 `-Dvcpkg-triplet` 或 `VCPKG_DEFAULT_TRIPLET`，否则按目标平台推导。`-Dvcpkg-root` 会自动推导：

- include: `<vcpkg-root>/installed/<triplet>/include`
- lib: `<vcpkg-root>/installed/<triplet>/lib`
- runtime DLL: `libssl-3-x64.dll`、`libcrypto-3-x64.dll`，启用 HTTP/2 时的 `nghttp2.dll`，以及启用 HTTP/3 时的 `ngtcp2.dll`、`ngtcp2_crypto_openssl.dll`、`nghttp3.dll` 会随 `ziserver.exe` 安装到 `zig-out/bin`

Windows + vcpkg 默认链接 `libssl/libcrypto/nghttp2`，其他平台默认链接 `ssl/crypto/nghttp2`。仍可通过 `-Dopenssl-ssl-lib`、`-Dopenssl-crypto-lib` 和 `-Dnghttp2-lib` 覆盖。如果 vcpkg 下载 CMake 或源码失败，先修复代理/网络后重新安装；ZiServer 不把 OpenSSL 源码 vendoring 进仓库。

## 运行时证书配置

证书和私钥始终在进程启动时动态读取，不会编译进可执行文件。配置优先级为命令行 > 环境变量 > 未配置：

```powershell
$env:ZISERVER_TLS_CERT="C:\certs\fullchain.pem"
$env:ZISERVER_TLS_KEY="C:\certs\private-key.pem"
$env:ZISERVER_TLS_MIN="1.2" # 可改为 1.3

# --port 保留旧版 HTTPS 主端口语义，同时自动增加 HTTP 18080
zig build run -- --http-port=18080 --https-port=18443 --host=127.0.0.1 --canonical-host=localhost
```

推荐使用无歧义的 `--http-port` 和 `--https-port` 分别配置两个 listener；两者不能相同。兼容参数 `--port` 在配置证书时映射到 HTTPS 端口，并保留默认 HTTP `18080`；没有证书时仍映射到 HTTP 端口。可选的 `ZISERVER_TLS=off|terminate`、`ZISERVER_TLS_MIN=1.2|1.3` 和 `ZISERVER_HTTP2=off|reject|on` 能控制自动模式。命令行参数具有最高优先级，例如 `--http2=off` 会保留双 listener，但 HTTPS 只提供 HTTP/1.1；`--tls=off` 会关闭 HTTPS listener，只保留明文 HTTP。证书文件在启动时加载；更换文件后需要重启进程，目前不提供热重载。

本机开发使用项目根目录下的 `.dev-certs/localhost.pem` 和 `.dev-certs/localhost.key`。证书已安装到当前用户的受信任根证书存储，私钥 ACL 仅允许当前用户访问；`.dev-certs/` 已被 Git 忽略。可以直接使用：

```powershell
$env:ZISERVER_TLS_CERT=".dev-certs/localhost.pem"
$env:ZISERVER_TLS_KEY=".dev-certs/localhost.key"

zig build run -- --port=18443
```

此时可以同时访问 `http://127.0.0.1:18080/` 和 `https://localhost:18443/`。HTTPS 应使用 `localhost`，以匹配开发证书中的名称。该私钥未加密，只用于本机开发，不应复制到部署环境。

## 高承载力调优

默认参数适合本机多核环境。需要手动调优时，可以从下面的组合开始：

```powershell
zig build -Dartifact=all -Doptimize=ReleaseFast
zig-out\bin\ziserver.exe --acceptors=4 --workers=64 --queue=32768 --shards=4 --backlog=16384 --keep-alive=1000 --page-cache-capacity=1024 --page-cache-shards=32 --no-access-log
```

### 页面缓存最佳实践

- 只给确定性、匿名、生成成本明显的 GET 页面添加 `z.layer.pageCache(...)`。当前示例页面只有一次栈上格式化，缓存收益约 2–3%；数据库查询、模板组合或序列化更重的页面才会获得更明显收益。
- `z.layer.cache(...)` 控制浏览器/代理的 `Cache-Control`，`z.layer.pageCache(...)` 控制 ZiServer 进程内 L1，两者职责不同，通常需要分别声明。
- 默认从 256 entries / 16 shards 开始。热点 key 多、worker 多时再提高 shard；容量增大但 shard 不变会增加 shard 内查找长度。
- 用 `/stats` 观察 `hits / (hits + misses)`、`evictions` 和 `bytes`。命中率低且 entries 持续增长通常表示 query 基数过高或路由不适合整页缓存。
- query 是缓存键的一部分。搜索、筛选和带随机追踪参数的页面应规范化 query，或不要启用整页缓存，避免缓存污染。
- `.short/.standard/.long` 分别为 5/30/300 秒；可用 `--page-cache-ttl-percent` 全局缩放。同 key miss 会由一个 leader 填充、其他请求等待后复用；当前等待仍占用 worker，因此昂贵或不稳定的 handler 不应配置过短 TTL。
- 用 `fill_leaders`、`coalesced_waits`、`coalesced_hits` 判断击穿合并效果；`fill_bypasses` 持续增长表示单个 shard 同时填充过多不同 key，应提高 shard/capacity 或降低高基数路由的缓存范围。
- `X-Page-Cache` 默认关闭以减少热路径工作；排查时临时启用 `--page-cache-header=on`，不要把它当作长期性能指标。
- 纯吞吐 benchmark 同时使用 `--no-access-log --page-cache-header=off`。生产环境是否关闭访问日志应依据上游日志方案决定。
- 认证、Cookie、Origin、Range、`no-cache/no-store` 和带自定义响应 header 的请求会保守绕过，避免跨用户或跨表示共享。

模块结构：

- 启动控制由 `src/main.zig` 直接交给 `src/core/server.zig`；具体应用通过 factory 回调注入。compose 只作为 app 使用的装配层依赖 core，不参与进程启动。
- `src/main.zig`: 最小可执行入口，只声明 Zig 运行时选项，并调用 core server、注入具体 application factory。
- `src/ziserver.zig`: 面向用户侧应用的统一导入入口，重新导出 DSL、`Context`、`ApplicationBundle`、常用 HTTP 类型和 compose 构建 API。
- `src/core/`: 服务器核心能力，不包含具体业务页面或业务 handler。
- `src/core/server.zig`: core 进程启动与服务器运行时生命周期，负责配置解析、日志、核心缓存/限流资源、listener、TLS/HTTP2/HTTP3、acceptor、分片连接队列、worker pool 和优雅关闭；通过可失败且接收 allocator 的 factory 获取 `ApplicationBundle`，不导入 compose/app。
- `src/core/config.zig`: 参数解析和默认并发配置。
- `src/core/log.zig`: 线程安全单行日志格式、等级过滤、PowerShell ANSI 颜色、严格 JSON Lines 和访问缓存结果字段。
- `src/core/http_config.zig`: HTTP 状态码、响应头名、内容类型、缓存策略和请求大小上限。
- `src/core/transport.zig`: 明文/TLS 连接读写抽象，统一向 HTTP 层提供 reader/writer，并暴露 ALPN 协商结果。
- `src/core/protocol.zig`: 早期协议探测，识别 HTTP/1、HTTP/2 h2c preface 和 TLS ClientHello。
- `src/core/protocol_redirect.zig`: 双 listener 协议纠正响应；在请求进入 router/middleware 前生成保留路径与查询串的 `308 Permanent Redirect`。
- `src/core/tls.zig`: TLS provider 选择、运行时 TLS 配置校验和 provider adapter 边界。
- `src/core/tls_backend/openssl.zig`: OpenSSL 后端 Zig 边界，只声明稳定的 `extern` shim 函数，不直接展开 OpenSSL 头文件。
- `src/core/tls_backend/schannel.zig`: Windows SChannel 后端占位，后续可在不改 `tls.zig` 门面的情况下接入。
- `src/core/tls_openssl_adapter.c`: OpenSSL C shim，负责包含 OpenSSL 头、处理宏/API 细节，并向 Zig 暴露稳定函数。
- `src/core/http2.zig`: HTTP/2 provider 门面、nghttp2 ABI、TLS connection bridge 和协议支持级别。
- `src/core/http2_nghttp2_adapter.c`: nghttp2 session、HPACK/header callbacks、stream body 收集、HEADERS/DATA 响应和 flow control adapter。
- `src/core/http3.zig`: HTTP/3 provider 门面、调用 C adapter 的 Zig bridge（UDP read/write、dispatch bridge）。
- `src/core/http3_nghttp3_adapter.c`: QUIC 连接管理（ngtcp2）、HTTP/3 帧处理（nghttp3）、TLS 1.3 QUIC 握手（OpenSSL）、请求收集和响应编码。
- `src/core/quic_transport.zig`: QUIC/UDP socket 封装，含数据报接收和发送。
- `src/core/stream_queue.zig`: 有界连接队列和普通连接分片队列。
- `src/core/request.zig`: HTTP/1.x 请求行、路径、查询串和头解析。
- `src/core/response.zig`: 状态行、响应头、正文和缓存头拼接。
- `src/core/streaming.zig`: 协议无关的 request Reader；`Context` 与 response 层提供统一的流式响应生命周期。
- `src/core/errors.zig`: 统一错误类型、错误到 HTTP 状态/正文/header 的映射，以及错误响应写出。
- `src/core/static.zig`: embedded/filesystem 静态资源 provider、MIME 类型和浏览器缓存策略。
- `src/core/page_cache.zig`: 有界分片页面响应缓存、TTL/LRU 淘汰和并发引用生命周期。
- `src/core/router.zig`: 路由表注册 API、method/path 精确匹配、`:param` 动态参数和 `*path` 尾部通配参数匹配，返回 handler id、静态资源或错误路由。
- `src/core/query.zig`: Query 参数结构化解析，支持重复 key、空值、裸 key 和 `%XX` 校验/解码。
- `src/core/context.zig`: handler 执行上下文，集中持有 request、writer、stats、static store、keep-alive、路由配置、路径参数、query 视图和请求局部状态。
- `src/core/locals.zig`: 无分配、定长的请求局部 typed store，供 compose middleware 把派生结果安全交给 handler，不向 core 引入具体功能类型。
- `src/core/services.zig`: application-owned opaque service registry；连接池等服务由启动层注入且必须比请求生命周期更长。
- `src/core/middleware.zig`: 通用 handler 前置中间件 pipeline，只定义回调协议，不绑定具体安全策略。
- `src/core/http.zig`: HTTP 连接处理、请求读取、路由分发、静态资源、统一错误出口和访问日志；实际路由、handler 和中间件由外部 app 注入。
- `src/core/stats.zig`: 活跃请求和排队连接的运维统计。
- `src/compose/`: 服务装配层，负责把 core、用户注册入口、中间件和路由配置组合成可运行应用。
- `src/compose/dsl.zig`: Axum 风格的轻量 Zig DSL，提供 handler registry、`get/post` 路由构建器、路由分组、通用 Layer 合并、默认 route options 和 `register()` 包装。
- `src/compose/layers.zig`: auth、body、content、upload、cache、CORS、rate、XSS 和自定义 middleware 的 feature layer 构造器；避免通用 DSL 依赖各功能实现。
- `src/compose/routes.zig`: 参数化应用装配 API，暴露 `Registration` 和 `buildApplication()`，并集中维护默认中间件栈。
- `src/compose/cache.zig`: 路由级缓存策略中间件，把 `Options.cache` 应用到动态响应。
- `src/compose/page_cache.zig`: 动态页面缓存命中与安全绕过中间件；完整设计见 `docs/zh-CN/architecture/page-cache.md`。
- `src/compose/cors.zig`: 正式 CORS 中间件框架，支持按路由开启公开读取或表单提交预检。
- `src/compose/auth.zig`: 路由级 auth 中间件机制，支持 Bearer token、API key 或两者任选；凭证来自启动参数或环境变量，未配置时认证失败关闭。
- `src/compose/json_body.zig`: JSON body 解析组件，提供可选校验中间件和 typed parse helper。
- `src/compose/api.zig`: 请求级 API façade；负责 typed JSON 解析、参数/query 读取和固定缓冲 JSON 注入，不让 app handler 直接依赖 body/codec 细节。
- `src/compose/content.zig`: JSON/XML/HTML/TOML/binary/custom 的统一借用式 `Document`、提取校验、响应注入与 app codec runtime。
- `src/compose/host_guard.zig`: 独立的 HTTP authority 中间件，要求 HTTP/1.1 `Host` 唯一且非空。
- `src/compose/xss.zig`: 独立的 XSS 策略中间件，负责运行时策略合并、有界规范化、观察与阻断。
- `src/core/client_identity.zig`: 规范化 peer/client IP、可信代理 CIDR 和有界 XFF 解析；默认不信任任何转发头。
- `src/core/rate_limiter.zig`: 服务实例所有的有界分片 per-IP 固定窗口，按 `(client_ip, relaxed|strict)` 分桶。
- `src/compose/rate_limit.zig`: 从 Context 读取已验证 client IP 并调用 limiter 的薄中间件。
- `src/compose/query_guard.zig`: query 编码校验中间件。
- `src/compose/form.zig`: `application/x-www-form-urlencoded` 和 `multipart/form-data` 表单解析统计。
- `src/compose/upload.zig`: multipart 用户文件上传拦截器，检查结构、文件名、文件数、单文件大小和类型白名单；解析摘要通过请求局部状态交给 handler 复用，不负责落盘。
- `src/compose/upload_disk.zig`: 小文件 multipart 与大文件 raw stream 的 atomic disk sink，提供随机命名、冲突策略、可选 fsync 和请求内落盘结果。
- `src/compose/database.zig`: provider-neutral pool/connection/parameter 接口和按请求 acquire/release middleware。
- `src/compose/database/pgsql.zig`: PostgreSQL pool 配置与外部 driver adapter 边界；当前不包含 libpq/wire driver。
- `src/compose/json_response.zig`: JSON 字符串响应辅助。
- `src/app/`: 当前示例网站和用户侧注册入口，不负责服务器核心能力。
- `src/app/register.zig`: 用户网站注册与 application factory，声明 routes、dispatch 和 auth，并通过公共门面调用 compose 构建具体应用后返回带可选析构契约的 `ApplicationBundle`。
- `src/app/site.zig`: 动态示例网站页面数据和 HTML 模板。
- `src/app/system.zig`: 健康检查和统计端点；通过公开的运行时快照读取指标，不穿透缓存与统计实现。
- `src/app/examples.zig`: 表单提交和 JSON echo 示例 handler。

当前内置路由：

- `GET /`: 默认动态示例网站首页
- `GET /index.html`: 静态备用 HTML 入口
- `GET /assets/style.css`: 浏览器二次拉取的 CSS，返回 `text/css`
- `GET /assets/app.js`: 浏览器二次拉取的 JS，返回 `application/javascript`
- `GET /health`: 健康检查 JSON
- `GET /stats`: 服务器运维指标 JSON（`active` 活跃请求、`queued` 排队连接）
- `GET /admin/stats`: 受 auth 中间件保护的统计 JSON；必须通过启动参数或环境变量显式配置凭证
- `GET /about`、`GET /products`、`GET /security`、`GET /contact`: 默认动态示例网站页面
- `GET /site`、`GET /site/:page`: 动态示例网站兼容别名
- `POST /submit`: 表单提交入口，当前解析 `application/x-www-form-urlencoded` 并返回字段统计 JSON
- `POST /upload`: 小文件上传拦截示例，只接受最多两个 `.txt`/`.png` 文件并返回检查统计，不落盘
- `POST /upload/store`: 小文件 multipart 原子落盘示例，默认写入 `var/uploads/small`
- `PUT /upload/stream`: 单个大文件流式原子落盘示例，默认最大 256 MiB，写入 `var/uploads/large`
- `POST /api/echo`: JSON API 示例入口，要求 `Content-Type: application/json`，解析 `{ "message": string, "count": number }` 并返回 JSON
- `POST /content/json`、`/content/xml`、`/content/html`、`/content/toml`、`/content/binary`: 使用同一 handler 验证统一提取与注入的格式回显端点
- `POST /stream/echo`: 使用统一 Reader/Writer 分块回显请求正文
- `GET /stream/chunks`: 分三次写出响应，用于 HTTP/1 chunked 和 HTTP/2 DATA 路径验证
- `GET /stream/demo`: 每 250ms 输出一段响应
- `GET /stream-demo.html`: 浏览器流式下载、上传与取消操作 demo

静态资源存放在 `src/public/`，默认以 filesystem 模式安装到 `zig-out/public/`，也可以通过 `-Dstatic=embedded` 编译进二进制。服务器目前支持普通读取路由的 `GET` 和 `HEAD`，并为表单提交预留了 `POST /submit`。其他方法返回 `405` 并带 `Allow: GET, HEAD, POST`。
请求 body 支持严格十进制 `Content-Length` 和有界 `Transfer-Encoding: chunked`，也支持 `Expect: 100-continue`；CL/TE 并存、重复 framing、非法 chunk/trailer 或其他 transfer coding 会直接拒绝。普通缓冲正文硬上限为 16 KiB；显式 streaming route 使用 DSL body limit，框架硬上限 1 GiB。chunk 元数据额外受固定 8 KiB 上限约束，所有 body 路径共享绝对 deadline 和读取次数预算。声明 `z.layer.streamingBody()` 或 `z.layer.streamFileUpload()` 的路由会在 header 完成后立即 dispatch：HTTP/1 handler 直接拉取 socket/chunk decoder，HTTP/2 handler 从 HEADERS 后的有界 DATA 队列读取。完整 API、背压与浏览器限制见 [`docs/zh-CN/guides/streaming.md`](docs/zh-CN/guides/streaming.md)。

完整双工验证可直接运行：

```powershell
# HTTP/1.1
node examples/duplex-client.mjs

# TLS + ALPN HTTP/2；需要先配置本地证书并启动 HTTPS listener
node examples/duplex-client.mjs --http2
```

所有响应默认带 MIME 嗅探、点击劫持、Referrer、Permissions、CSP、跨窗口隔离和跨域策略文件防护头；`Strict-Transport-Security: max-age=31536000` 只在 TLS 连接（含 HTTP/2）上输出，避免明文开发端口错误声明 HSTS。默认 CSP 允许同源脚本和图片，并为当前服务端页面保留内联样式支持。

慢连接防护同时使用绝对读取截止时间和读取碎片预算。TLS 握手、HTTP/1.1 header、body 和 keep-alive 空闲阶段分别使用上述超时；客户端逐字节发送不会刷新当前阶段的截止时间。header/body 超时会尽可能返回 `408 Request Timeout`，空闲连接则静默关闭。Windows 使用项目内直接调用 `NtDeviceIoControlFile(AFD.RECEIVE)` 与 event wait 的可取消读取路径实现 deadline；它不依赖 Zig 的 `std.Io.Threaded`/IOCP socket timeout 支持。该 Windows 专用低层路径已做本机慢 header 回归，升级 Zig 或变更 Windows 版本后仍应重新回归验证；其他平台使用 `std.Io` deadline。读取次数上限仍作为第二层防护。

进程捕获 Ctrl+C、SIGINT 和 SIGTERM 后进入优雅停机：先设置 stopping 状态并停止分发新连接，唤醒并退出所有 acceptor，然后关闭 listener；HTTP/2 session 发送 `NO_ERROR` GOAWAY，HTTP/1.1 不再接受下一次 keep-alive 请求。服务器等待活动连接在 `--shutdown-grace` 内结束，超时后强制 shutdown 剩余 socket，最后输出 `shutdown_complete`，其中 `forced_connections` 表示被强制中止的连接数。

每个请求结束时会输出一行访问日志。Windows PowerShell 默认采用带等级和颜色的 `pretty` 格式，例如：

```text
[INFO] 1783923412704 HTTP[http/1.1] GET / 200 359us bytes=10234 client=127.0.0.1 source=peer cache=FILL enabled=yes response_cache=api-short
[INFO] 1783923412730 HTTP[http/1.1] GET / 200 120us bytes=10234 client=127.0.0.1 source=peer cache=HIT enabled=yes response_cache=api-short
[WARN] 1783923412744 HTTP[http/1.1] GET /missing 404 519us bytes=28 client=127.0.0.1 source=peer cache=BYPASS enabled=yes response_cache=no-cache
```

`cache` 表示服务器页面缓存的本次结果：`OFF` 为全局关闭，`BYPASS` 为路由或请求不适合缓存，`MISS` 为未命中且未写入，`FILL` 为本请求生成并写入缓存，`HIT` 为直接复用缓存。`enabled` 单独表示页面缓存 store 是否启用，`response_cache` 则是发给浏览器/代理的响应缓存策略，两者不可混为一谈。

日志等级为 `TRACE/DEBUG/INFO/WARN/ERROR`；成功和重定向请求为 `INFO`，4xx 为 `WARN`，5xx 为 `ERROR`。`--log-level=warn` 可以只保留异常请求。`--log-color=auto` 会尝试为 Windows PowerShell 启用 ANSI 颜色，但当 stderr 被重定向时自动退回无颜色输出；设置 `NO_COLOR=1` 也会关闭自动颜色。

采集到文件、Loki、Vector 或其他日志系统时，使用严格 JSON Lines：

```powershell
zig-out\bin\ziserver.exe --log-format=json --log-color=off 2> .\ziserver.jsonl
```

JSON 字段包含 `time_unix_ms`、`level`、`event`、`protocol`、`method`、`path`、`status`、`body_bytes`、`duration_us`、`cache_enabled`、`page_cache` 和 `response_cache`。handler 和 middleware 只返回语义错误，例如 `error.Unauthorized`、`error.InvalidQueryEncoding`、`error.UnsupportedMediaType`，由 `src/core/errors.zig` 统一映射为 HTTP 响应。

## TLS、HTTP/2 和 HTTP/3

当前可运行协议面是明文 HTTP/1.0/1.1、HTTPS/HTTP/1.1、HTTPS/HTTP/2，以及通过 `-Dhttp3=nghttp3` 编译的 HTTPS/HTTP/3：

- 配置证书后，明文 HTTP 和 HTTPS 使用两个独立 listener，但共享连接队列、worker pool、router、middleware、静态资源和统计。
- 两个 listener 同时运行时自动启用协议纠正：`http://host:<https-port>/path` 重定向到当前 HTTP 端口，`https://host:<http-port>/path` 在完成 TLS 握手后重定向到当前 HTTPS 端口。响应使用 `308 Permanent Redirect` 并保留路径和查询串；Location 主机由 canonical/allowed/fallback 策略决定，语法合法但未授权的 Host 返回 400。该处理发生在 router/middleware 之前。
- OpenSSL 默认最低 TLS 1.2，优先使用 TLS 1.3；可用 `--tls-min=1.3` 强制仅接受 TLS 1.3。TLS 1.3 使用 AES-128-GCM、ChaCha20-Poly1305、AES-256-GCM，key exchange 优先 X25519，并保留 P-256/P-384 回退。
- TLS 1.2 仅保留 ECDHE + AEAD cipher；启用服务端会话缓存和 TLS tickets，明确关闭 0-RTT early data 以避免业务请求重放。每次握手记录 `version`、`cipher`、ALPN 和 `session_reused`，便于确认客户端实际走 TLS 1.3/h2 及会话恢复。
- 明文 HTTP/2 h2c preface 或 `HTTP/2.0` 请求行会返回 `505 HTTP Version Not Supported`，不会再被误归类为普通 `400`。
- 明文端口收到 TLS ClientHello 时会快速关闭并记录 `method=TLS` 的访问日志；TLS 客户端无法读取明文错误响应，因此这里不写 HTTP body。
- `--http2=on` 只在 TLS termination 和 nghttp2 provider 同时可用时启动；服务端通过 ALPN 优先协商 `h2`，不支持 h2 的客户端继续回退到 HTTP/1.1。
- h2 SETTINGS 明确发布 4 KiB HPACK table、128 个并发 stream、最大 256 KiB 单 stream 初始接收窗口和 4 KiB header-list 上限；正文仍经 16 KiB request queue 反压，不按窗口大小预分配。
- h2 请求会深拷贝后提交到 Zig 并发执行器，并映射到现有 router、middleware、body limit、handler 和结构化日志；nghttp2 session 提交与 socket 写保持单线程，动态页面、静态资源、HEAD、JSON POST、错误响应和并发 stream 共用同一业务管线。
- h2 在 HEADERS 后提前生成协议纠正 `308` 等终止响应时，dispatch 仍会后台排空该 stream 的 DATA 直到 END_STREAM；因此超过 16 KiB request queue 的 POST 不会阻塞 nghttp2 session 或同连接上的其他 stream。
- h2 的 header/body 超限只终止当前请求并返回 `431`/`413`，不会拖垮同一连接上的其他 stream。缺失或重复必要伪头会返回 `400`。
- `--keep-alive=N` 同样限制单个 h2 session 完成的请求数；达到上限后发送 `NO_ERROR` GOAWAY，等待已接收 stream 排空。session 结束时输出 `http2_session_closed` JSON Lines 事件，包含请求数、最高 stream id 和 GOAWAY 状态。
- 收到进程停机信号时，阻塞读取会在内部 50 ms 检查周期内被取消，h2 session 随即发送 `NO_ERROR` GOAWAY；该检查周期不改变用户配置的请求或 keep-alive 绝对超时。
- `--http3=advertise` 配合 `-Dhttp3=nghttp3` 编译时，ZiServer 会在同一进程中监听 QUIC/UDP 端口（默认 443），通过 ngtcp2 完成 QUIC 握手和传输，再用 nghttp3 解析 HTTP/3 帧。QUIC session 共享现有 TLS 证书配置（基于 OpenSSL TLS 1.3）。未启用 `-Dhttp3=nghttp3` 时，`advertise` 只在 HTTPS 响应中注入 `Alt-Svc: h3=":443"` 头，QUIC 流量仍需由反向代理承接。
- HTTP/3 server 当前为实验性单活动连接模式；同一 QUIC 连接内的每个 H3 stream 使用独立请求/响应状态，并进入与 HTTP/1.1、HTTP/2 相同的 router、middleware、静态资源、页面缓存、可信客户端身份、per-IP 限流和访问日志管线。QUIC 线程同步执行 dispatch，不占用 TCP worker pool。
- 原生 H3 当前在 END_STREAM 后分发完整请求，request body 上限为 16 KiB，响应在提交给 nghttp3 前缓冲；尚未实现 H3 增量请求/响应流。多连接 CID demux、Retry/地址验证、经验证的 NAT rebinding/path migration、优雅连接关闭和专项压测仍属于生产化工作。
- 生产环境也可以继续放在 Caddy、nginx、HAProxy、Envoy 等 TLS 终止代理后面，由代理对外提供 TLS/ALPN/HTTP2/HTTP3，再把 HTTP/1.1 转发给 ZiServer。

协议层实施计划：

1. 已完成 transport/protocol 边界：HTTP/1.1 处理路径不再直接散落操作 `std.Io.net.Stream`，早期协议探测集中到 `core/protocol.zig`。
2. 已完成 TLS provider 构建期开关和 OpenSSL adapter：`-Dtls=none|openssl|schannel` 进入 build options、启动日志和运行时校验；OpenSSL provider 提供 TLS 1.3 优先 cipher/group、TLS 1.2 AEAD 回退、会话恢复、可配置最低版本和 ALPN `h2,http/1.1`。
3. 已抽出 TLS backend 层：`tls.zig` 是跨平台门面，`tls_backend/openssl.zig` 承接 OpenSSL/vcpkg，`tls_backend/schannel.zig` 预留 Windows 原生实现。后续 Linux 可以继续走 OpenSSL，Windows 可以在 OpenSSL 和 SChannel 间选择。
4. 已接入 HTTPS + HTTP/1.1 over TLS：支持证书/私钥加载、OpenSSL server context、连接级 TLS 握手、自定义 BIO、`SSL_read/SSL_write`、线程隔离的错误状态、正常 TLS EOF、握手失败日志，以及明文端口误发 TLS 的稳定处理。BIO 通过 Zig `std.Io` 回调完成底层收发，不假设 Windows AFD handle 是 Winsock `SOCKET`，Linux 也可以沿用同一 provider 边界。
5. 已完成 ALPN 分流：`--http2=on` 发布 `h2,http/1.1`，其他模式只发布 `http/1.1`。
6. 已接入 nghttp2 adapter：处理帧层、HPACK、并发 stream、flow control、单 stream 请求限制和 graceful GOAWAY，并把 h2 request/response 映射到现有 `Context`、middleware、router、静态资源和日志。
7. h2c 最小实验路径可作为测试模块保留，但不作为生产默认路径。
8. HTTP/3 advertise 模式已就绪：`--http3=advertise --http3-port=N` 可在 HTTPS 响应中注入 `Alt-Svc` 头宣告 h3 端点。
9. HTTP/3 实验套件已接入：`-Dhttp3=nghttp3` 编译后链接 ngtcp2 + nghttp3，创建 QUIC/UDP listener，完成 TLS 1.3 + `h3` ALPN、HTTP/3 帧/QPACK、per-stream 状态、应用响应编码，并复用现有 router/middleware/client identity。后续需补多连接、原生流式 body/response、Retry/path validation、优雅关闭和专项压测。

## 路由框架规划

当前 `src/core/router.zig` 已经把 method/path 分发抽成独立组件，并提供基础路由表注册 API。用户侧优先通过 `src/ziserver.zig` 这个门面入口声明路由；DSL 最终仍生成 `router.Entry`，所以不会绕开现有 router。默认应用路由表位于 `src/app/register.zig`，注册了 `/`、顶层页面路由、`/health`、`/stats`、`/site` 兼容别名、`/submit` 和 `/api/echo`，静态资源由 core static provider 兜底解析。

```zig
const z = @import("../ziserver.zig");
const Context = z.Context;

pub const registry = z.handlers(.{
    home,
    about,
    submit,
    apiEcho,
    uploadHandler,
});

const upload_policy: z.UploadPolicy = .{
    .max_request_bytes = z.http_config.max_form_body_bytes,
    .max_file_bytes = 8 * 1024,
    .max_files = 2,
    .allowed_content_types = &.{ "text/plain", "image/png" },
    .allowed_extensions = &.{ ".txt", ".png" },
};

const public_pages = z.group(.{
    .layers = z.layers(.{
        z.layer.cache(.api_short),
        z.layer.pageCache(.standard),
        z.layer.cors(.public_read),
        z.layer.rate(.relaxed),
    }),
    .routes = .{
        registry.get("/", home),
        registry.get("/about", about),
    },
});

const routes = z.routes(.{
    public_pages,
    z.group(.{
        .prefix = "/site",
        .layers = z.layers(.{
            z.layer.cache(.api_short),
            z.layer.cors(.public_read),
        }),
        .routes = .{
            registry.get("/", home),
            registry.get("/:page", home),
        },
    }),
    registry.post("/submit", submit)
        .withLayers(.{
            z.layer.bodyLimit(1024),
            z.layer.cors(.public_form),
            z.layer.rate(.strict),
            z.layer.xssObserve(),
        }),
    registry.post("/api/echo", apiEcho)
        .withLayers(.{
            z.layer.content(.{
                .request = .json,
                .response = .json,
                .max_request_bytes = 1024,
            }),
            z.layer.cors(.public_form),
            z.layer.rate(.strict),
        }),
    registry.post("/upload", uploadHandler)
        .withLayers(.{
            z.layer.upload(upload_policy),
            z.layer.cache(.no_cache),
            z.layer.rate(.strict),
        }),
});

pub const registration = registry.register(.{
    .routes = &routes,
});

pub fn home(ctx: *Context) !void {
    try ctx.html(.ok, "<h1>Hello ZiServer</h1>");
}

pub fn uploadHandler(ctx: *Context) !void {
    const summary = try z.upload.inspect(ctx); // 复用 middleware 的解析结果
    _ = summary;
    try ctx.json(.ok, "{\"stored\":false}\n");
}
```

功能 layer 的构造集中在 `compose/layers.zig`，`dsl.zig` 只负责按顺序合并通用 `router.Options`。重复的 `middleware_flags` 使用按位 OR，因此旧 `jsonBody()`、`xssObserve()` 等 layer 组合时不会互相覆盖。新路由优先用 `content()` 或可组合的 `extract()`/`inject()`，handler 通过 `z.content.document(ctx)` 读取借用式正文；完整格式、自定义 codec 与流式边界见 [`docs/zh-CN/guides/content.md`](docs/zh-CN/guides/content.md)。`smallFileUpload()` 配置小文件 multipart 原子落盘；`streamFileUpload()` 自动启用 streaming body 并配置一请求一文件的流式落盘。handler 通过 `z.upload_storage.result(ctx)` 取得文件数与字节数。完整说明见 [`docs/zh-CN/guides/upload.md`](docs/zh-CN/guides/upload.md)。

浏览器侧可以直接用 `fetch()` 调 JSON API：

```js
const res = await fetch("/api/echo", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: "hello", count: 2 }),
});

const data = await res.json();
```

应用侧的 typed JSON API 使用 `apiJson()` 与 `z.api.call(ctx)`。它只做一次 typed parse；输出由固定缓冲区序列化，不再创建临时 JSON AST、手动转义字符串或对框架生成的 JSON 再校验一次：

```zig
const Input = struct { message: []const u8 = "", count: i64 = 0 };

pub fn echo(ctx: *z.Context) !void {
    var api = z.api.call(ctx);
    defer api.deinit();
    const input = try api.json(Input);

    var output: [1024]u8 = undefined;
    try api.respondJson(.ok, .{
        .ok = true,
        .message = input.message,
        .count = input.count,
    }, &output, .no_cache);
}

const routes = z.routes(.{
    z.post("/api/echo", handlers.id(echo)).apiJson(1024),
});
```

`apiJson(max_bytes)` 仅适合 handler 自己通过 `z.api` 解析并响应的 JSON API；需要原样转发、通用格式校验或自定义 codec 时，继续使用 `content()`、`extract()` 和 `inject()`。

如果需要扩展执行型 middleware，可以把自定义中间件作为 layer 加到默认栈后面：

```zig
const middleware_stack = z.middlewareStackWithDefaults(.{
    z.layer.middleware("trace_id", traceId),
});

pub const registration = z.register(.{
    .routes = &routes,
    .dispatch = registry.dispatch,
    .middleware_stack = &middleware_stack,
});

fn traceId(ctx: *Context) !z.middleware.Decision {
    try ctx.addHeader("X-Trace", "local");
    return .next;
}
```

handler 仍然统一接收 `Context`。为了让最小建站少写协议细节，`Context` 提供了 `html()`、`text()`、`json()` 以及带缓存参数的 `htmlCached()`、`textCached()`、`jsonCached()`：

```zig
pub fn home(ctx: *Context) !void {
    try ctx.html(.ok, "<h1>Hello ZiServer</h1>");
}
```

当前由 `src/main.zig` 直接启动 core server，并把具体应用工厂作为回调注入。core 先完成进程配置和核心资源初始化，再调用 app factory；app 内部才使用 compose 构建路由与中间件：

```zig
// src/main.zig
return server.start(init, app_registration.buildApplication);

// src/core/server.zig：不导入 app/compose，只调用注入的 factory。
var bundle = try application_factory(allocator, startup_config);
defer bundle.deinit(io, allocator);

// src/app/register.zig：通过公共门面使用 compose。
return .{ .application = z.buildApplication(withAuth(startup.auth)) };
```

factory 类型为 `fn (std.mem.Allocator, ApplicationStartupConfig) anyerror!ApplicationBundle`。动态路由、数据库池、模板缓存或插件可以存入 `bundle.state`，并设置 `bundle.deinit_fn`；core 保证应用析构先于限流器、页面缓存及进程 allocator 的释放。factory 自身初始化到一半失败时，应使用 `errdefer` 回收已经创建的资源。

认证凭证的优先级为：启动参数 > 环境变量。项目不提供默认凭证；两者都未配置时，受保护路由保持 401。环境变量名为 `ZISERVER_BEARER_TOKEN` 和 `ZISERVER_API_KEY`：

```powershell
$env:ZISERVER_BEARER_TOKEN="local-token"
$env:ZISERVER_API_KEY="local-key"
zig build run

# 或使用启动参数覆盖
zig build run -- --auth-token=local-token --api-key=local-key
```

后续如果业务路由继续增加，计划继续补齐：

- 动态路径参数：已支持 `/users/:id` 这类单段参数，也支持 `/files/*path` 这类尾部通配参数，并把参数写入 `Context.params`，handler 可通过 `ctx.param("id")` 或 `ctx.param("path")` 读取。
- Query 参数结构化解析：已由 `src/core/query.zig` 提供，只读键值视图支持重复 key、空值、裸 key、`%XX` 校验和按需解码；handler 可通过 `ctx.queryParam("name")` 读取首个值。
- 中间件/拦截器：已接入 handler 前置 pipeline，`host_guard`、`xss`、`cors`、`auth`、`rate_limit`、`query_guard` 等组件分别维护和执行。XSS 支持 `off`、`observe`、`block`，服务器级配置作为最低策略，路由可通过 `xssObserve/xssBlock` 进一步加强；query/body 扫描目标可独立配置。用户侧可以通过 `z.layer.middleware()` 声明自定义执行中间件，并用 `z.middlewareStackWithDefaults()` 扩展默认栈。
- Handler 统一接口：已引入 `Context`，动态 handler 统一由 `z.handlers()` 生成的 `registry.dispatch(ctx, handler)` 执行；handler/middleware 失败时返回统一语义错误，由 core 错误出口写响应。`Context` 同时提供 `html/text/json` 响应糖，方便写最小动态站点。
- 路由级配置：每条路由可以通过 `z.layer.auth()`、`bodyLimit()`、`content/extract/inject()`、兼容接口 `jsonBody/jsonBodyLimit()`、`upload/smallFileUpload/streamFileUpload()`、`database()`、`cache/pageCache()`、`cors()`、`rate()`、`requireAuth()` 和 `xssObserve/xssBlock()` 声明策略；也可以通过 route group 设置默认 layer。文件、codec 与数据库副作用只有显式 layer/service 才会启用。
- 错误处理统一化：404、405、415、413、400、401、403、500 等错误由 `core/errors.zig` 统一生成，业务 handler 和中间件只返回语义错误。

建议分三步落地：

1. 已完成基础路由表注册 API 和 method/path 精确匹配。
2. 已完成 `Context` 和统一 handler 分发，让动态 handler 不再直接分散在 `http.zig`。
3. 已完成中间件 pipeline 初版，并在 handler 前提供 XSS/跨站脚本过滤挂点。
4. 已完成 `require_auth`、路由级 body limit 和 query parser。
5. 已完成统一错误出口和访问日志。
6. 已完成正式 CORS 中间件框架和动态路由缓存策略框架。
7. 已完成限流、尾部通配动态 pattern、auth 策略化和 multipart 基础解析。
8. 已完成轻量 Axum 风格 DSL，用户侧可以用 `registry.get(...).withLayer(...)` 或 `withLayers(...)` 声明路由。
9. 已完成 DSL 路由分组、prefix 展开、默认 route options 和 `get/head/post/put/delete/patch/optionsRoute` 方法构建器。
10. 已完成 handler registry，用户侧可以直接用 handler 函数注册路由，dispatch switch 由 DSL 生成。
11. 已完成 layer/middleware DSL 初版，支持路由策略 layer、分组默认 layer、自定义执行 middleware 和默认栈扩展。
12. 已完成 JSON body parser 组件和 `/api/echo` JSON API 示例路由。
13. 已完成按客户端地址限流、可信代理边界、文件落盘策略、跨平台 socket deadline、Slowloris 防护和优雅停机；生产级 auth provider 仍可继续扩展。

## 内置压测程序

项目内置了一个同样使用 Zig 构建的压测程序 `zibench`。它支持明文 HTTP/1.1、TLS + ALPN HTTP/1.1，以及原生 HTTP/2（发送 connection preface、SETTINGS、HPACK 请求 header、WINDOW_UPDATE 和 GOAWAY），三种模式都支持连接复用或单请求连接：

测量服务器本身的吞吐时建议用 `--no-access-log` 启动 ZiServer；保留访问日志的结果衡量的是服务逻辑与同步日志输出的组合性能。

```powershell
$env:ZIG_GLOBAL_CACHE_DIR="$PWD\.zig-cache\global"
zig build -Dartifact=all -Doptimize=ReleaseFast
zig build bench -- --threads=16 --duration=30
zig build bench -- --https --threads=16 --duration=30
zig build bench -- --http2 --threads=16 --duration=30
```

常用参数：

- `--host=127.0.0.1`: 目标地址
- `--port=18080`: 目标端口
- `--https-port=18443`: HTTPS/HTTP2 目标端口
- `--path=/`: 请求路径
- `--body=TEXT`: 改用 POST 并发送指定正文；HTTP/1.1 与 HTTP/2 均支持
- `--content-type=TYPE`: POST 的 `Content-Type`；multipart benchmark 需要同时提供 boundary
- `--threads=N`: 压测线程数，默认 8
- `--duration=SECONDS`: 测试时长，默认 10 秒
- `--keep-alive=N`: 每个 TCP 连接复用的请求数，默认 1000
- `--no-keep-alive`: 等同于 `--keep-alive=0`，用于短连接兼容测试
- `--https`: 使用 TLS 并通过 ALPN 强制 HTTP/1.1
- `--http2`: 使用 TLS、ALPN `h2` 和原生 HTTP/2 帧
- `--streams-per-connection=N`: HTTP/2 每批并发 stream 数，默认 1，范围 1–128
- `--timeout=MS`: TLS 握手和每次响应读取的绝对超时，默认 5000 ms
- `--tls-verify`: 验证证书链和目标主机名；本地自签名压测默认关闭
- `--json`: 输出适合脚本采集的单行 JSON 结果

### HTTP/2 长稳态回归

除 `zibench` 外，仓库还提供两个无外部依赖的回归工具：`scripts/http2-soak.mjs` 用 Node 原生 HTTP/2 客户端持续维持多路复用请求，`scripts/monitor-process.ps1` 只读采样服务器的工作集、私有内存、句柄、线程和 CPU 时间。它们适合交叉验证高并发 HTTP/2 的错误率与资源曲线：

```powershell
$server = Start-Process .\zig-out\bin\ziserver.exe -ArgumentList @(
  '--http-port=18090', '--https-port=18490',
  '--tls-cert=.dev-certs/localhost.pem', '--tls-key=.dev-certs/localhost.key',
  '--tls-min=1.3', '--http2=on', '--page-cache=off', '--no-access-log'
) -PassThru
.\scripts\monitor-process.ps1 -ProcessId $server.Id -DurationSeconds 135 -OutFile .\soak.csv
node .\scripts\http2-soak.mjs --origin=https://127.0.0.1:18490 --path=/about --connections=8 --streams=8 --duration=120
Stop-Process -Id $server.Id
```

脚本也可回归真实 JSON API；使用 `--body-file` 保留原始字节，避免 Windows shell 对 JSON 引号的转义影响：

```powershell
node .\scripts\http2-soak.mjs --origin=https://127.0.0.1:18490 --path=/api/echo `
  --method=POST --body-file=.\request.json --content-type=application/json `
  --connections=1 --streams=8 --duration=30
```

2026-07-13 的 ReleaseFast 复测中，`/about`、8 连接 × 8 streams、120 秒得到 1,917,123 次成功请求、零 HTTP 状态/会话错误、约 15.97k req/s。资源从预热后的 1.365 GiB 私有内存、189 句柄、85 线程，达到 1.383 GiB/191/86 的高水位后收敛至 1.380 GiB/175/86；未观察到持续增长。此前另一轮 120 秒中出现过 1 次状态错误，但加入状态码采集后的同配置复测未复现，暂不宣称跨工作负载的绝对零错误。

`zibench` 的 HTTP/2 固定时长测试在结束边界可能报告每 worker 一次 `ReadTimeout`；服务端会话日志未显示对应的 `http2_session_failed`。当前应保留该信号用于排查，但以 Node 回归脚本的完整状态/会话统计交叉判断服务端稳定性，避免把压测器收尾噪声直接归类为服务器错误。

### 当前 ReleaseFast 性能（2026-07-12）

以下结果来自本机 Windows、`/about`、关闭访问日志、独立测试端口；数字用于当前提交内的相对比较，不代表跨机器承诺：

| 模式 | 并发连接 | 页面缓存 | req/s | 失败 |
| --- | ---: | --- | ---: | ---: |
| HTTP/1.1 | 16 | off | 约 144k | 0 |
| HTTP/1.1 | 16 | on | 约 147k | 0 |
| HTTP/2 优化前 | 8 | off | 约 18.1k | 0 |
| HTTP/2 优化后 | 8 | off | 约 35.6k | 0 |
| HTTP/2 优化后 | 8 | on | 约 36.7k | 0 |
| HTTPS/1.1 | 8 | on | 约 64.8k | 0 |

HTTP/2 优化通过静态借用默认安全响应头和把 capture body 所有权直接移交给 nghttp2 stream，去掉了每请求 8 次 header 小分配以及第二次正文分配/copy。无缓存 HTTP/2 中位吞吐约提升 96.5%，平均延迟从约 441 µs 降到约 224 µs。

HTTP/2 缓存开启后的连接伸缩结果为：1/4/8/16/32 个连接约 6.9k/23.1k/35.8k/55.3k/60.0k req/s。32 连接吞吐最高，但平均延迟约 530 µs；低延迟场景应根据实际负载选择 8–16 个并发连接。

### API 调用层复测（2026-07-13）

本机 ReleaseFast、TLS 1.3、关闭页面缓存和访问日志。`/api/echo` 使用 `apiJson(1024)`，请求为 30-byte JSON。HTTP/1.1（8 条长连接）得到约 108.8k req/s、零失败；Node HTTP/2 回归（1 连接 × 8 streams）得到 87,031 次成功请求、零 HTTP/session 错误、约 17.3k req/s。该 API 路径把 JSON 解析和响应序列化各收敛为一次；多连接 HTTP/2 的独立执行器容量仍需后续专项改造，因此这里不外推为多 session 吞吐承诺。

### 小文件上传解析性能（2026-07-13）

本机 ReleaseFast、关闭访问日志、8 个 HTTP/1.1 连接，对 `/upload` 发送含 2 KiB `.txt` 文件的 multipart 请求。旧实现由 middleware 和 handler 各扫描一次，代表值为 113,532 req/s、平均 69.7 µs；请求内缓存 `Summary` 后三轮中位数为 117,689 req/s、平均约 67.0 µs，零失败，代表性提升约 3.7%。该数字只衡量内存解析和策略校验，不包含落盘、对象存储和病毒扫描。

HTTP/2 已验证同一 POST 负载能够经 TLS 1.3 + ALPN `h2` 正确处理；单 stream 回归零失败。高并发带正文 stream 的 session/flow-control 路径在本轮结束排空阶段仍有少量读超时，暂不发布稳定吞吐承诺。复现 HTTP/1.1 测量可使用：

```powershell
$body = "--abc`r`nContent-Disposition: form-data; name=`"file`"; filename=`"bench.txt`"`r`nContent-Type: text/plain`r`n`r`n" + ('x' * 2048) + "`r`n--abc--`r`n"
zig build bench -- --path=/upload '--content-type=multipart/form-data; boundary=abc' "--body=$body" --threads=8 --duration=3 --json
```

### 双向流回归（2026-07-13）

HTTP/1.1 与 HTTP/2 已接入真正的边收边 dispatch 和实时响应。Node 示例按 300 ms 间隔发送 `alpha/bravo/charlie/delta`，两种协议均在下一段上传前收到上一段回显；HTTP/2 实际协商 TLS 1.3 + ALPN `h2`。默认 Debug 构建的功能/并发回归结果如下，数字只用于正确性验证，不与上面的 ReleaseFast 吞吐横向比较：

| 场景 | 请求 | 成功 | 失败 |
| --- | ---: | ---: | ---: |
| HTTP/1.1 流式 POST，4 threads | 48,758 | 48,758 | 0 |
| HTTP/2 流式 POST，4 connections × 8 streams | 53,592 | 53,592 | 0 |
| HTTP/2 `/health`，4 connections × 8 streams | 60,232 | 60,232 | 0 |
| HTTP/2 单请求连接 | 258 | 258 | 0 |

HTTP/2 自定义 OpenSSL BIO 现在把临时无数据正确映射为 retry，并在 AFD 可读或 `SSL_pending()` 非零后才读 TLS；response DATA 最后一段会同时标记 EOF。GOAWAY 会等待当前 stream 排空，并为最多 128 个已接收并发 stream 保留 drain 余量，避免连接上限边界截断响应。无 Content-Length 的正文若在响应开始后才超过上限，会重置单个 stream，不会拖垮整个 h2 session。

可复现 A/B 时，用同一二进制分别启动 `--page-cache=off` 和 `--page-cache=on`，其他参数完全一致；若默认端口已有开发服务，应换独立端口。`zibench` 已能在收到包含当前 stream 的 GOAWAY 后继续读取该响应，`--keep-alive=1000` 边界测试为约 35.2k req/s、零失败。

### HTTP/1.1 与 HTTP/2 内存稳定性检查（2026-07-12）

本机 Windows 使用 ReleaseSafe 构建，对 `/about` 关闭页面缓存和访问日志后，交替执行 6 轮 HTTP/1.1/HTTP/2 压测，并以全新进程额外执行 10 轮 HTTP/2 单协议压测。HTTP/1.1 使用 16 个线程，HTTP/2 使用 8 个连接、每连接 8 个并发 stream；每轮结束后等待 2–3 秒再采样服务器工作集、私有内存、句柄数和线程数。

HTTP/2 独立序列的采样结果如下：

| 阶段 | 工作集 | 私有内存 | 句柄 | 线程 |
| --- | ---: | ---: | ---: | ---: |
| 预热后基线 | 18.65 MiB | 1337.90 MiB | 219 | 87 |
| 高并发第 1 轮 | 26.84 MiB | 1403.85 MiB | 223 | 91 |
| 第 4 轮峰值 | 27.96 MiB | 1404.89 MiB | 223 | 88 |
| 第 10 轮 | 27.82 MiB | 1404.71 MiB | 223 | 88 |
| 最终空闲 | 27.82 MiB | 1404.71 MiB | 223 | 88 |

HTTP/2 首轮增加约 66 MiB 私有内存，来自线程池、TLS/nghttp2 和分配器的一次性高水位扩容；后续 9 轮在约 1 MiB 范围内上下波动，句柄和线程数保持稳定，没有随轮次线性增长。交替测试中，HTTP/1.1 每轮冷却后的内存与前一个采样点一致。因此本轮压力测试没有发现 HTTP/1.1 请求处理或 HTTP/2 异步 dispatch 存在持续性内存泄漏迹象。该结论是压力采样结果，不替代 Application Verifier、Dr. Memory 等分配级检测或更长时间的 soak test。

用于校验请求结果的三轮短测试中，HTTP/1.1 共 747,234 个请求且全部成功；HTTP/2 共 172,098 个请求，其中 98 个失败，失败率约 0.057%。当时的失败伴随 TLS `unexpected message`/`bad write retry`。2026-07-13 的双向流改造已修正自定义 OpenSSL BIO 的 retry 语义，并在 Windows AFD 可读性探测后才进入短轮询 TLS read；后续验证结果见本节之后的新测试记录，旧数字只保留为历史基线。

构建时可以通过 `-Dartifact=` 选择生成不同结果：

- `server`: 只生成 `ziserver`，默认值
- `bench`: 只生成 `zibench`
- `all`: 同时生成 `ziserver` 和 `zibench`

示例：

```powershell
zig build -Dartifact=server -Doptimize=ReleaseFast
zig build -Dartifact=bench -Doptimize=ReleaseFast
zig build -Dartifact=all -Doptimize=ReleaseFast
```

## 外部压测示例

```powershell
wrk -t8 -c1000 -d30s http://127.0.0.1:18080/
```

也可以使用 `bombardier`：

```powershell
bombardier -c 1000 -d 30s http://127.0.0.1:18080/
```

## 许可证

ZiServer 的原创源码、文档与示例使用 [BSD 2-Clause License](LICENSE) 开源。

OpenSSL、nghttp2、ngtcp2、nghttp3 以及演示页面使用的 GSAP/ScrollTrigger
保留各自的上游许可证。完整组件映射、版权说明和本地许可文本见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [`LICENSES/`](LICENSES/)。

其中 GSAP 3.12.5 和 ScrollTrigger 3.12.5 是 GreenSock 单独授权的第三方
演示资产，不受 ZiServer 的 BSD-2-Clause 许可证覆盖。重新分发源码或二进制
发行包时，请同时保留项目许可证、第三方声明以及相应的第三方许可文本。
