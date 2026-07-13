# ZiServer 文档中心

[English documentation](README.en.md) | 简体中文

文档按用途分类。根目录 [`README.zh-CN.md`](../README.zh-CN.md) 提供构建、运行、配置和性能总览；这里保存面向实现、部署和维护的详细说明。

## 架构与路线

- [分层边界](zh-CN/architecture/overview.md)：`core`、`compose`、`app` 的职责和单向依赖。
- [页面响应缓存设计](zh-CN/architecture/page-cache.md)：缓存键、安全绕过、并发填充和外部配置。
- [缺口与实施路线](zh-CN/architecture/roadmap.md)：当前完成状态与 P0/P1/P2 优先级。

## 开发指南

- [统一内容提取与注入](zh-CN/guides/content.md)：JSON、XML、HTML、TOML、binary 与自定义 codec。
- [数据库中间件抽象](zh-CN/guides/database.md)：连接池、请求生命周期和 PostgreSQL adapter 边界。
- [HTTP/1 与 HTTP/2 双向流](zh-CN/guides/streaming.md)：Reader/Writer、背压、取消与协议行为。
- [用户上传拦截与处理](zh-CN/guides/upload.md)：校验、小文件落盘和大文件流式落盘。

## 部署与运维

- [客户端 IP 与限流部署](zh-CN/operations/client-ip-rate-limit.md)：直连、可信代理、容量和隐私。
- [协议纠正重定向 Host 策略](zh-CN/operations/redirect-host-policy.md)：canonical/allowlist/fallback 规则。
- [按客户端 IP 限流实施清单](zh-CN/operations/rate-limit-client-ip-checklist.md)：历史核查、实现状态和验收门槛。

## 安全

- [安全审计报告](zh-CN/security/security-audit.md)：历史发现、修复状态、剩余风险和验证记录。

## 许可证

项目许可证和第三方授权材料属于法律原文，不制作翻译版本：

- [BSD 2-Clause License](../LICENSE)
- [第三方声明](../THIRD_PARTY_NOTICES.md)
- [第三方许可证目录](../LICENSES/)
