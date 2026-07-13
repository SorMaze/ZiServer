# ZiServer 缺口与实施路线

本清单基于当前源码、构建选项、测试和公开文档整理。优先级按“会造成资源耗尽或错误语义”“阻碍协议能力”“生产可运维性”排序。

## P0：资源与协议正确性

1. **页面缓存同 key miss 合并（已完成）**
   - 已实现 fill leader / waiter、失败释放、固定容量退化、可取消且可配置的 bounded wait，以及 `/stats` 的 `fill_wait_timeouts` 指标。
   - 默认等待 100 ms，超时后独立渲染；后续仅保留 stale-while-revalidate 评估。
2. **HTTP/2 真正的连接内并发 dispatch（已完成）**
   - stream 完成后深拷贝请求并提交 Zig `std.Io` 并发任务；RST/会话关闭可取消并安全回收任务。
   - nghttp2 session 线程只负责轮询完成项、提交响应和 socket 写入，不从 handler 线程并发调用 nghttp2；`zibench` 支持 `--streams-per-connection=1..128`。
3. **双向流式传递（已完成）**
   - 支持严格 chunked framing、extension/trailer、CL/TE 防歧义、`Expect: 100-continue`/417 和统一绝对 body deadline。
   - 已提供统一 request Reader 与 response begin/write/finish API；HTTP/1.1 在 header 路由后直接读取 socket/chunk decoder，并实时 chunked flush。
   - HTTP/2 在 HEADERS 后启动 handler，以有界队列传递增量 DATA；响应通过 deferred provider/resume 实时输出，支持背压、RST 取消、超限传播与 GOAWAY 排空。
4. **文件落盘与数据库接入边界（基础完成）**
   - 小文件 multipart 支持校验后 atomic sink；大文件支持一请求一文件的 raw-body 流式落盘、随机命名、冲突策略和可选 fsync。
   - provider-neutral database pool/connection middleware、请求 cleanup 和 PostgreSQL driver adapter 已搭建；真实 PostgreSQL driver、事务和 metadata 补偿流程仍待实现。

## P1：协议与缓存完整性

5. **HTTP/3 生产化**：从实验性单连接扩展到多连接、优雅 GOAWAY/关闭、完整 router/middleware 集成和独立压力测试。
6. **缓存失效与表示维度**：提供 path/tag purge；只允许白名单 `Vary`；明确部署时的多进程一致性策略。
7. **静态资源 HTTP 语义**：增加 ETag/Last-Modified、条件请求、Range，以及预压缩 gzip/brotli 选择，减少重复传输。
8. **真实客户端身份边界（已完成）**：socket peer 地址贯穿 HTTP/1.1/HTTP/2，默认忽略转发头；显式可信代理 CIDR、有界 XFF 解析、规范化 client IP、per-IP 限流及聚合指标已经接入。原生 HTTP/3 完成 router/middleware 集成时仍需复用该边界。

## P2：生产运维与质量门禁

9. **可观测性**：Prometheus/OpenTelemetry 导出、按协议/状态码/路由的延迟直方图，以及异步结构化日志 sink。
10. **TLS 生命周期**：完成 SChannel provider，支持证书热更新/轮换，并覆盖握手失败、ALPN 和关闭路径测试。
11. **配置热更新**：对可安全更新的超时、限流、日志和缓存策略提供原子配置快照；监听地址/线程模型继续要求重启。
12. **自动化质量门禁**：补充 CI（Debug/ReleaseFast、TLS/HTTP2 开关、embedded static、主要平台）、parser fuzz、长连接/优雅停机回归和 sanitizer/泄漏检查。

## 推荐顺序

下一步若继续上传/数据库方向，优先实现 PostgreSQL driver、metadata transaction 与失败补偿清理；需要多文件大上传时，再为现有 Reader 增加跨 chunk multipart parser。否则按 P1 顺序推进 HTTP/3 生产化。
