# 页面响应缓存设计

页面响应缓存与现有两类缓存职责分离：

- `z.layer.cache(...)` 只控制客户端看到的 `Cache-Control`。
- `core/static.zig` 负责磁盘或 embedded 静态文件，不保存动态 handler 输出。
- `z.layer.pageCache(...)` 显式缓存动态页面在服务器端生成的响应正文。

## 请求流程

1. router 把 `PageCachePolicy` 放入 route options。
2. auth、限流、query 校验和安全过滤仍先执行；缓存命中不会绕过这些策略。
3. `compose/page_cache.zig` 用规范化 Host + 完整 request target（path + query）查找缓存，避免跨 Host 串用。
4. 命中时直接通过 `Context.writeBytesHead()` 输出；启用诊断配置时附加 `X-Page-Cache: HIT`。
5. 未命中时，同 key 的第一个请求成为 fill leader 并执行 handler；后续请求等待该次填充，成功后直接复用缓存。
6. 成功写出的匿名 GET 200 响应由 `Context` 在发送完成后填入缓存；handler 失败或响应不可缓存时也会释放 fill token，等待者随后重试或成为新 leader。

HEAD 与 GET 共享缓存键。HEAD 可以读取 GET 已填充的正文长度，但 HEAD miss 不会单独填充不完整条目。

## 安全边界

第一版仅允许匿名 GET/HEAD，以下请求始终绕过：

- 路由配置了 auth 或 `requireAuth`；
- 请求包含 `Authorization`、`Cookie`、`Origin` 或 `Range`；
- 请求要求 `Cache-Control: no-cache` 或 `no-store`；
- 响应不是 200，正文超过配置的单项上限（默认 256 KiB），或响应带 handler 自定义 header。

这些限制避免把用户态页面、Cookie 响应、跨域差异或部分内容错误地共享给其他请求。

## 存储与并发

- shard 数和总条目数在启动时分配，默认 16 shard / 256 项；
- key 通过 Wyhash 选择 shard，shard 内使用小型线性表和共享读锁；
- 满载时淘汰最久未使用条目，查找时同时清理过期项；
- 命中只每 64 次采样更新一次 LRU 时钟，降低热点 key 的原子写竞争；
- 条目通过引用计数管理，淘汰与并发响应发送可以安全重叠；
- 每个 shard 使用固定容量的 fill coordinator 合并同 key miss，避免热点条目过期后多个 worker 重复渲染；coordinator 满载时请求保守绕过，不扩大内存上界；
- `.short`、`.standard`、`.long` TTL 分别为 5、30、300 秒。

容量、shard、单项正文上限和 TTL 全局缩放比例都可以由 CLI 或环境变量配置。初始化后容量保持固定，使内存上界可预测，也避免运行中 resize 和全局缓存锁。缓存内容在进程重启后丢失，这是刻意的进程内 L1 设计。

## 外部配置

| CLI | 环境变量 | 默认值 |
| --- | --- | ---: |
| `--page-cache=on|off` | `ZISERVER_PAGE_CACHE` | `on` |
| `--page-cache-capacity=N` | `ZISERVER_PAGE_CACHE_CAPACITY` | `256` |
| `--page-cache-shards=N` | `ZISERVER_PAGE_CACHE_SHARDS` | `16` |
| `--page-cache-max-body=BYTES` | `ZISERVER_PAGE_CACHE_MAX_BODY` | `262144` |
| `--page-cache-ttl-percent=N` | `ZISERVER_PAGE_CACHE_TTL_PERCENT` | `100` |
| `--page-cache-header=on|off` | `ZISERVER_PAGE_CACHE_HEADER` | `off` |
| `--page-cache-fill-wait-timeout=MS` | `ZISERVER_PAGE_CACHE_FILL_WAIT_TIMEOUT` | `100` |

同 key miss 等待可取消，并在超时后绕过缓存独立渲染；`0` 表示不等待，最大值为 30000 ms。CLI 优先于环境变量。容量范围为 1–16384，shard 范围为 1–64 且不能超过容量，正文上限最大 1 MiB，TTL 比例范围为 1–1000%。例如 `50` 会把 `.standard` 从 30 秒缩短为 15 秒。

`/stats` 的 `page_cache` 对象提供 `entries`、`bytes`、`hits`、`misses`、`inserts`、`evictions`、`expired`、`fill_leaders`、`coalesced_waits`、`coalesced_hits`、`fill_bypasses` 和 `fill_wait_timeouts`。这些计数不依赖通用 `--stats` 开关，以便缓存调优始终可观测。

合并等待使用可取消条件变量并受上述超时约束；超时后请求绕过缓存独立渲染，不会被慢 leader 无限占住。若热点失效时 `coalesced_waits` 很高，应同时提高 worker 数、延长 TTL 或引入带抖动的刷新策略。

`X-Page-Cache` 只用于诊断，默认关闭。稳定压测应使用 `--page-cache-header=off --no-access-log`，避免把同步日志或额外响应 header 的成本算进页面生成性能。

## 后续阶段

- 评估 stale-while-revalidate，进一步减少超时后重复渲染；
- 支持显式 tag/path invalidation；
- 在确有需要时增加经过白名单约束的 `Vary` 维度。
