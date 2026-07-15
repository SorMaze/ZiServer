# 按客户端 IP 限流与可信代理边界实施清单

本文针对以下两个相互依赖的问题给出可分阶段实施、测试和上线的清单：

- 当前限流是进程级、按策略共享的固定窗口，不区分客户端；单个来源可以耗尽其他客户端的预算。
- 请求上下文没有来自 socket 的对端地址，也没有可信代理配置和规范化客户端 IP；直接信任 `Forwarded`、`X-Forwarded-For` 或 `X-Real-IP` 会允许客户端伪造身份并绕过限流。

## 完成状态（2026-07-13）

核心修复已经落地：`client_identity.zig` 建立 socket peer、可信代理 CIDR 和有界 XFF 边界；`rate_limiter.zig` 提供 server-owned、有界分片的 per-IP limiter；HTTP/1.1、HTTP/2、缓冲式实验 HTTP/3、Context、访问日志、`/stats`、CLI/环境配置和部署文档均已接入。仍保留为后续项的内容是 HTTP/3 验证后 path migration、RFC 7239 `Forwarded`、token bucket、parser fuzz、协议级 HTTP/2/TLS/QUIC 压测及真实生产灰度。

## 实施前源码核查结论（历史）

- `src/compose/rate_limit.zig:21-23` 的 `relaxed`、`strict` 和 `rate_config` 是模块级全局状态；`limit()` 在 `:37-38` 只按 `relaxed`/`strict` 选择全局窗口。所有客户端共享同一计数。
- 当前键空间实际上只有两个窗口；同一策略下的所有路由和所有客户端会互相消耗预算。
- `src/compose/rate_limit.zig:44-56` 使用 1 秒固定窗口和单个 mutex；测试只覆盖“达到预算后拒绝、下一窗口恢复”，没有多客户端隔离、并发或代理伪造测试。
- `src/core/context.zig:60-89` 的 `Context` 没有 `peer_ip`、`client_ip` 或身份来源字段。
- `src/core/stream_queue.zig:11-14` 的 `PendingConnection` 只携带 stream 和 plain/TLS 标记；`src/main.zig:401-416` 接受连接后没有保存对端地址。
- `src/core/http.zig:55-63` 的 HTTP/2 dispatch state 也没有连接对端地址；重建 HTTP/1.1 风格请求后直接进入共用 middleware。
- 原生 HTTP/3 历史上尚未进入 router/middleware；实验适配器现已使用 UDP/QUIC peer 和共用身份解析器。path migration 在 ngtcp2 验证并传播活动 path 前保持禁用。
- `Request.header()` 只返回第一个同名头。客户端身份解析不能直接复用它而忽略重复头、合并语义和长度上限。
- 429 已带固定 `Retry-After: 1`；在继续采用 1 秒窗口的第一阶段可以保留，若改用 token bucket 再按实际等待时间生成。

## 必须先确定的安全语义

- [x] 将直连 socket/QUIC 对端地址定义为 `peer_ip`，它是不依赖 HTTP 头的根信任信息。
- [x] 将业务使用的规范化地址定义为 `client_ip`；限流、审计和以后需要 IP 的认证扩展只使用这一统一结果，不各自解析头。
- [x] 默认模式设为 `client_ip_header=none`：`client_ip = peer_ip`，无条件忽略客户端发送的所有转发头。
- [x] 只有 `peer_ip` 命中显式配置的可信代理 CIDR 时，才允许解析配置选中的转发头；“监听在 loopback/private 地址”本身不能自动等价于可信代理。
- [x] 第一阶段只支持一种头模式，建议 `none|x-forwarded-for`；如以后支持 RFC 7239 `Forwarded`，作为独立解析器和模式加入，不能混合两种头后猜测优先级。
- [x] 不把 `X-Real-IP` 作为隐式回退。若未来支持它，也必须是显式、互斥的模式，并受同一可信代理判断约束。
- [x] 可信代理模式下，将 `peer_ip` 逻辑追加在代理链右端，从右向左移除可信代理；第一个不可信地址是 `client_ip`。若头内全部地址均可信，则取最左地址作为来源。
- [x] 要求最外层入口代理覆盖或严格清洗来自公网请求的身份头。仅仅“追加 XFF”在内部客户端地址也属于可信网段时仍可能保留攻击者伪造的最左项。
- [x] 对头缺失、重复、超长、超过 hop 上限、空元素、非法 IP、带 zone ID、`unknown`/混淆标识等情况规定确定行为。身份解析失败时安全回退到 `peer_ip` 并记录原因计数。
- [x] 不根据公网/私网/保留地址类别自动丢弃合法 IP；这些地址可能出现在真实内网拓扑。信任只由配置的 CIDR 和链位置决定。
- [x] 明确第一阶段仍是“单进程内按 IP”限流。多进程、多副本会各自拥有预算；需要集群级精确限制时应由可信边缘代理完成，或以后引入共享后端，而不是误称当前实现为全局集群限流。

推荐的解析示例：

| `peer_ip` | 可信代理 | `X-Forwarded-For` | 结果 |
| --- | --- | --- | --- |
| `203.0.113.8` | 否 | `1.1.1.1` | `203.0.113.8`，忽略伪造头 |
| `10.0.0.10` | 是 | `203.0.113.8` | `203.0.113.8` |
| `10.0.0.10` | 是 | `203.0.113.8, 10.0.0.20` | `203.0.113.8`，从右向左剥离两个可信代理 |
| `10.0.0.10` | 是 | 非法值 | 回退 `10.0.0.10` 并增加解析失败指标 |

## P0：建立真实客户端身份边界

### 地址类型与解析器

- [x] 新建 core 层客户端身份模块 `src/core/client_identity.zig`，代理信任逻辑不在限流中间件中。
- [x] 定义无端口的规范化 `IpKey`：保存 address family 和固定 4/16 字节；IPv4-mapped IPv6 统一折叠为 IPv4。
- [x] 定义值语义 `ClientIdentity`，包含 `peer_ip`、`client_ip`、来源、可信 hop 数和解析状态。
- [x] 提供 CIDR 解析与匹配，启动时解析一次，逐请求只匹配预编译结果。
- [x] 为 XFF 编写有界、无分配解析器，限制总字节数和 hop 数并拒绝非法 token。
- [x] 显式拒绝并安全回退重复 `X-Forwarded-For`，不使用“取第一个”的行为。
- [x] 使用纯解析函数和单调时钟，不依赖墙上时间或全局配置。

### 从传输层贯穿到 Context

- [x] accept 使用 Zig socket 返回的远端地址，去掉端口后存入 `PendingConnection`，不从 HTTP 头猜测 peer。
- [x] 扩展 `PendingConnection` 和 `ServeOptions`，让 HTTP/1.1 keep-alive 请求共享正确的 `peer_ip`。
- [x] 将同一个 `peer_ip` 放入 `Http2DispatchState`；每个 HTTP/2 stream 根据自己的 header 解析 `client_ip`。
- [x] 在 middleware 前写入 `ClientIdentity`，并提供只读 `ctx.clientIp()`/`ctx.peerIp()` 接口。
- [x] preflight 与普通 handler 走同一身份解析路径，访问日志取得相同身份。
- [x] 实验性 HTTP/3 使用初始 QUIC connection peer 作为 `peer_ip` 并复用同一解析器；单连接 session 拒绝来自其他 peer 的数据包。
- [ ] 启用 NAT rebinding/path migration 前，只能用 ngtcp2 验证后的活动 path 更新身份。
- [x] 保留测试/内嵌调用的显式 identity 注入入口，未使用模块级“当前客户端”全局变量。

### 配置边界

- [x] 增加 `--client-ip-header`、可重复的 `--trusted-proxy` 和 `--forwarded-max-hops`。
- [x] 默认 `none` 且可信列表为空；启用转发头但未配置可信代理时启动失败。
- [x] 非法 CIDR、hop 上限及容量配置在启动阶段失败并输出明确错误。
- [x] 提供环境变量、CLI 优先级和配置测试。
- [x] 启动日志只输出模式、可信网段数量和 hop 上限，不打印完整转发链。
- [x] [`client-ip-rate-limit.md`](client-ip-rate-limit.md) 给出代理侧清洗和网络边界约束。

## P0：把限流改为按 client IP 分桶

### 所有权与键语义

- [x] 用 server-owned `RateLimiter` 实例替换模块级可变窗口；在 `main` 初始化、注入、关闭时释放，测试可独立创建多个实例。
- [x] 键定义为 `(client_ip, RateLimitPolicy)`，保持策略级语义并隔离不同客户端。
- [x] 未无声改成 route scope；如以后需要，使用稳定 route ID 和显式 scope 配置。
- [x] `limit(ctx)` 只读取 `ctx.clientIp()` 和注入的 limiter，不解析 HTTP 头。
- [x] 阈值为 0 表示不限流且不创建 map entry。

### 并发、时间与内存上限

- [x] 使用分片 map/锁，哈希输入为规范化二进制 IP 和 policy。
- [x] 保留 1 秒固定窗口并改用 `Clock.awake` 单调时钟；token bucket/sliding window 仍是独立后续项。
- [x] 实现最大 entry 数和 idle TTL；分片容量受压时清理全部过期 entry，内存不会无界增长。
- [x] 容量仍满时对新 key fail-closed 返回 429 并增加 `capacity_rejections`。
- [x] 窗口更新和清理在分片锁内完成，不在解锁后保留 entry 指针。
- [x] 计数不会超过 u32 阈值，时间回退会重置窗口，并发同 IP 不会超过预算。
- [x] 当前配置启动后不可变且需要重启，不在请求路径无同步修改结构。

### 429 语义

- [x] 固定 1 秒窗口阶段保留 429 和 `Retry-After: 1`。
- [ ] 可选增加标准化的 `RateLimit-Limit`、`RateLimit-Remaining`、`RateLimit-Reset`，但不要在并发下返回未经同步的误导值。
- [x] 429 响应不回显 `client_ip`、代理链或可信代理配置。

## P1：可观测性与隐私

- [x] access log 增加规范化 `client_ip` 和身份来源，不记录原始 XFF。
- [x] JSON 和 pretty 日志使用统一格式化结果，IP 不含端口。
- [x] `/stats` 增加按 policy、identity 来源、解析失败、entry、过期和容量拒绝的低基数指标。
- [x] 未以 client IP 作为指标 label，单 IP 排查依赖访问日志。
- [x] 启动记录配置摘要；非可信转发头只聚合计数，不制造逐请求 warning。

## 测试清单

### 客户端身份单元测试

- [x] 无代理模式下 XFF/`Forwarded`/`X-Real-IP` 不改变 `peer_ip`。
- [x] 非可信 peer 的 XFF 被忽略；可信 peer 的单 hop XFF 被采用。
- [x] 多级代理链覆盖首个非可信地址和全部 hop 可信。
- [x] 覆盖 IPv4、IPv6、IPv4-mapped IPv6、CIDR 边界、可选端口和规范化相等性。
- [x] 覆盖重复头、空元素、非法字符、超长值、超 hop、`unknown`、IPv6 zone ID、错误括号/端口；全部安全回退且不 panic。
- [x] 增加身份头 parser fuzz target，并对输入长度设置硬上限。

### 限流单元与并发测试

- [x] IP A 耗尽 strict 预算后，IP B 的第一个请求仍通过。
- [x] 同一 IP 达到阈值后返回 429，窗口重置后恢复。
- [x] relaxed/strict 预算互不影响，阈值 0 不创建 entry。
- [x] 并发命中同一 key 的成功数严格不超过阈值，分片 map 避免全局锁。
- [x] idle entry 回收、容量上限、fail-closed、指标和恢复行为有测试。
- [x] 两个 limiter 实例状态互不污染。

### 协议与集成测试

- [x] HTTP 请求路径验证直连伪造 XFF 无法换桶，可信代理下两个 XFF 客户端预算独立。
- [ ] 同一 keep-alive 连接上的多请求使用同一 peer，但可按每个请求的已验证转发头解析身份。
- [ ] HTTP/2 多 stream 与 HTTP/1.1 结果一致，且并发 stream 不串用身份。
- [ ] TLS 与明文连接的 peer 获取结果一致；代理 TLS termination 的示例只在代理地址受信时采用 XFF。
- [x] 实验性 HTTP/3 已进入 middleware/client identity，并记录仍待完成的 migration 与协议压测。
- [ ] 回归 429 的 `Retry-After`、HEAD/preflight、错误响应、访问日志 JSON 单行转义。
- [x] Debug 与 ReleaseFast 均通过 `zig build test`，Debug/ReleaseFast 可执行文件构建通过。
- [ ] 对“同一 IP 热 key”和“多 IP 分散 key”分别做 ReleaseFast 性能压测，记录吞吐、P95/P99、锁竞争和常驻内存。

## 上线顺序与验收门槛

1. [ ] 先发布 identity 传递、可信代理解析、日志/指标，限流仍处于现有实现；在测试环境核对 `peer_ip`、`client_ip` 与代理日志一致。
2. [ ] 以 `client_ip_header=none` 上线直连场景，确认伪造头不会改变身份。
3. [ ] 只在网络 ACL 已确保 ZiServer 不可被公网绕过、且入口代理覆盖身份头后，配置精确可信代理 CIDR并启用 XFF。
4. [ ] 切换到 per-IP limiter，观察 429、entry 数、解析失败和容量指标；保留边缘限流作为大规模 DDoS 防线。
5. [ ] 验收攻击者 A 打满预算时正常客户端 B 持续成功；伪造任意转发头不能让 A 换桶；重启、窗口切换和容量压力下无崩溃、无无界内存。
6. [x] 更新 [`README.md`](../../../README.md)、[`security-audit.md`](../security/security-audit.md) 与 [`roadmap.md`](../architecture/roadmap.md) 的状态，明确单进程/多副本边界和代理配置前提。

## 明确不应采用的捷径

- [x] 不直接将 `request.header("X-Forwarded-For")` 的第一个值作为限流键。
- [x] 不默认信任 loopback、RFC1918、ULA 或代理常用网段。
- [x] 键不包含 `IP:port`。
- [x] 不以 User-Agent、Host、Authorization 或可变 header 代替网络身份。
- [x] 容量耗尽不会退回所有客户端共享的静默全局桶。
- [x] 文档不宣称应用层 limiter 能单独抵御连接、带宽或多副本聚合攻击。
