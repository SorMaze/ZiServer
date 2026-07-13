# 客户端 IP 与限流部署说明

ZiServer 的路由限流按 `(client_ip, relaxed|strict)` 使用独立的进程内固定窗口。默认不读取任何转发头，`client_ip` 始终等于 accept 时由 socket 提供的直连 `peer_ip`。

## 直接部署

没有反向代理时保持默认配置即可：

```powershell
zig-out\bin\ziserver.exe --rate-limit-relaxed=120 --rate-limit-strict=20
```

客户端发送的 `X-Forwarded-For`、`Forwarded` 或 `X-Real-IP` 都不会改变限流身份。IP 键不包含源端口，IPv4-mapped IPv6 会折叠为 IPv4。

## 反向代理部署

只有同时满足以下条件才能启用 XFF：

1. ZiServer 的监听端口通过防火墙、Security Group、容器网络或 loopback 限制为只能被指定代理访问，公网不能绕过代理直连。
2. 最外层代理删除客户端传入的 `X-Forwarded-For`，再用实际连接来源重建该头。
3. `--trusted-proxy` 使用尽量精确的代理地址/CIDR，不因为地址属于 loopback、RFC1918 或 ULA 就自动信任。

单代理示例：

```powershell
zig-out\bin\ziserver.exe `
  --client-ip-header=x-forwarded-for `
  --trusted-proxy=127.0.0.1/32 `
  --forwarded-max-hops=4 `
  --rate-limit-relaxed=120 `
  --rate-limit-strict=20
```

可以重复 `--trusted-proxy=CIDR`。环境变量形式为：

```powershell
$env:ZISERVER_CLIENT_IP_HEADER="x-forwarded-for"
$env:ZISERVER_TRUSTED_PROXIES="127.0.0.1/32,10.20.0.0/24"
$env:ZISERVER_FORWARDED_MAX_HOPS="4"
```

启用 XFF 但没有可信代理会导致启动失败。重复、超长、超 hop 或包含非法地址的 XFF 不会被部分采用，而是安全回退到 `peer_ip` 并增加 `client_identity.invalid` 指标。来自非可信 peer 的 XFF 会被忽略并增加 `ignored_untrusted`。

### 代理侧最小约束

边缘 nginx 应覆盖而不是直接保留公网请求的 XFF：

```nginx
location / {
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_pass http://127.0.0.1:18080;
}
```

边缘 HAProxy 可先删除再重建：

```haproxy
frontend public
    http-request del-header X-Forwarded-For
    option forwardfor
    default_backend ziserver
```

Caddy/Envoy 也必须采用同一原则：外部 listener 使用实际 remote address 重建 XFF；只有受控的内部 hop 才能追加已经清洗的链。若使用多层代理，应把每一层代理地址加入可信 CIDR，并保证链顺序为 `client, proxy-1, proxy-2`。ZiServer 从右向左剥离可信代理，第一个非可信地址作为客户端地址。

不要把 PROXY protocol 与 HTTP 转发头混用。ZiServer 当前没有启用 PROXY protocol parser；如果负载均衡器发送 PROXY 前导行，请关闭该功能或在以后以独立、显式的 transport 配置接入。

## 容量与并发

默认 limiter 使用 64 个锁分片、最多 65,536 个 `(IP, policy)` entry，idle TTL 为 10 分钟：

```text
--rate-limit-capacity=65536
--rate-limit-shards=64
--rate-limit-idle-ttl=600000
```

阈值为 0 的策略不会创建 entry。分片满时先删除超过 idle TTL 的 entry；仍无容量则对新 key fail-closed 返回 429，并增加 `capacity_rejections`，不会无界增长或静默绕过。当前窗口为 1 秒，429 保留 `Retry-After: 1`。

限流状态由单个 ZiServer 进程所有。多进程或多副本各自拥有完整预算；需要集群级精确限制时，应在可信边缘代理执行，或使用后续共享状态后端。应用层限流也不能代替连接数、监听队列和带宽层面的 DDoS 防护。

## 日志与指标

访问日志包含规范化的 `client_ip` 和 `client_ip_source=peer|x-forwarded-for`，不会记录原始 XFF 链。`/stats` 提供：

- `client_identity.peer|forwarded|header_missing|ignored_untrusted|invalid`
- `rate_limit.entries`
- `rate_limit.allowed_relaxed|allowed_strict`
- `rate_limit.rejected_relaxed|rejected_strict`
- `rate_limit.expired|capacity_rejections`

这些都是低基数聚合值，不把 IP 放入指标 label。IP 属于可能识别个人的信息，访问日志的保留期限和访问权限应按部署方隐私策略设置。
