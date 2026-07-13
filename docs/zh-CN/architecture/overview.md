# ZiServer 分层边界

ZiServer 使用单向依赖：

```text
app  ->  ziserver public facade  ->  compose  ->  core
                                      |           |
                                      +-----------+
```

## 平台范围

当前只有 **Windows x86_64** 被视为可用：已在该平台完成构建、功能回归、HTTP/2 长稳态和内存稳定性验证。Windows TLS/HTTP/2 的已验证组合是 vcpkg 提供的 OpenSSL + nghttp2，并使用 Windows 专用 AFD 可取消读取路径实现 socket deadline。

Linux、macOS 与其他目标仍保留部分 `std.Io` 可移植路径，但没有同等级 CI、协议回归、长稳态压测或发行验证；当前不能宣称受支持。SChannel 后端仅为占位；原生 HTTP/3 仍是实验性单连接实现，尚未完成多连接、GOAWAY 和完整 router/middleware 集成。

`main.zig` 是最小 composition root，直接调用 `core/server.zig`，并把具体 application factory 作为回调注入。core 负责解析启动配置、持有核心资源和运行服务器；factory 位于 app，通过公共门面使用 compose。core 不导入 compose/app，compose 不反向导入 app。

## core

负责协议和运行时机制：socket/TLS、HTTP/1/2/3、错误 listener 协议纠正、请求解析、双向流、响应写入、路由表、静态资源、缓存存储、队列、统计、超时和停机。

- 不导入 `compose/` 或 `app/`。
- 不包含具体端点、页面文案或业务路径。
- 只定义通用机制和稳定的数据契约，例如 `Context.runtimeSnapshot()`、opaque application service registry 和请求 cleanup hook。
- 不决定具体中间件顺序或应用路由。
- `core/server.zig` 是进程启动服务，管理配置、核心资源、listener、acceptor、worker 和优雅关闭；具体应用通过 `fn (Allocator, ApplicationStartupConfig) anyerror!ApplicationBundle` factory 回调注入。bundle 的可选析构函数在 core 服务资源释放前执行。
- `core/protocol_redirect.zig` 在 router/middleware 前处理双 listener 协议用错端口的 308 响应，并以 canonical/allowed/fallback Host 策略隔离请求 authority；Location 解析与响应传输分离。bind host 在配置阶段解析为规范化 IP，供 listener、Host policy 与关闭唤醒共用；任意写法的 wildcard TLS 缺少显式策略时均由 `core/config.zig` 拒绝启动。

## compose

负责把 core 能力组合成可复用策略：DSL、默认 middleware pipeline、auth/CORS/XSS/限流、query 校验、统一内容提取/注入、显式文件落盘、数据库连接借还和页面缓存策略。

- 可以依赖 core；不得导入 app。
- middleware 可按 DSL 显式策略检查、变换、短路或管理有界资源副作用；内容层只保存借用式 `Document`，自定义 codec 通过 app-owned service 注入；文件落盘使用 atomic sink，数据库连接通过请求 cleanup 归还。middleware 不承载站点响应逻辑。
- 不读取整个应用注册表，也不包含 `/health`、`/stats` 或示例业务响应。
- 启动配置的 CLI/环境变量优先级由 `core/config.zig` 解析；middleware 接收解析后的策略或凭证。

## app

负责可替换的最终应用：handler、页面模板、端点响应和路由注册。

- 框架能力只经 `ziserver.zig` 公共门面访问，不直接导入 `core/` 或 `compose/` 内部文件。
- 可以在 app 内部相互导入。
- app registration 提供 application factory，由 main 注入 core server；factory 可以通过 `ziserver.zig` 公共门面组合 compose 能力，并使用 allocator 初始化动态路由、连接池、模板缓存或插件。初始化失败必须返回错误，长期资源由 `ApplicationBundle` 的 state/deinit 契约持有。
- 不管理 listener、worker、TLS session、缓存锁或 middleware 全局生命周期。
- 运维端点通过公开快照读取数据，不穿透 `Context` 的缓存/统计存储字段。

## 验证

`zig build test` 分别构建 `core-tests`、`compose-tests` 和 `app-tests`。审查依赖时还应确认：

```powershell
rg '@import\(".*(compose|app)' src/core
rg '@import\(".*app' src/compose
rg '\.\./(core|compose)' src/app
```

三条命令在架构正常时都不应返回匹配。
