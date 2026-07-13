# 协议纠正重定向 Host 策略

ZiServer 的双 listener 协议纠正发生在 router/middleware 之前。为了避免合法但由攻击者控制的 `Host`/`:authority` 进入 `Location`，重定向主机按以下优先级解析：

1. 配置 `canonical-host` 时始终输出 canonical host。
2. 未配置 canonical、但配置 allowed hosts 时，只接受命中 allowlist 的请求，并输出对应的配置值。
3. 两者均未配置且 bind 是具体地址时，使用 bind 地址作为 fallback。
4. TLS bind 为 IPv4/IPv6 未指定地址且没有显式策略时，启动失败。判断基于解析后的地址值，因此 `::` 和 `0:0:0:0:0:0:0:0` 等价。

`--allowed-host` 一旦出现就会限制输入 Host；如果同时配置 canonical，canonical 会被隐式允许。域名比较不区分大小写，IPv4/IPv6 使用规范化地址比较。所有配置值都只能包含 hostname 或 IP literal，不允许 scheme、端口、路径、fragment 或 userinfo。

## 单一公开名称

```powershell
zig build run -- `
  --host=0.0.0.0 `
  --canonical-host=app.example.com `
  --tls-cert=.dev-certs/lan.pem `
  --tls-key=.dev-certs/lan-key.pem
```

即使请求携带 `Host: attacker.example`，重定向也只会指向 `app.example.com`。如果希望直接拒绝未知 Host，再增加：

```powershell
--allowed-host=app.example.com
```

## 多个局域网入口

```powershell
zig build run -- `
  --host=0.0.0.0 `
  --allowed-host=192.168.31.47 `
  --allowed-host=server.lan `
  --tls-cert=.dev-certs/lan.pem `
  --tls-key=.dev-certs/lan-key.pem
```

环境变量等价配置：

```powershell
$env:ZISERVER_CANONICAL_HOST="app.example.com"
$env:ZISERVER_ALLOWED_HOSTS="app.example.com,api.example.com"
```

反向代理仍应在边缘层校验外部 Host。该策略只保护 ZiServer 自己生成的协议纠正重定向，不替代代理的虚拟主机边界。

协议适配器会先独立解析并验证完整 `Location`，再写入 308 响应。只有 authority、目标路径或 Host policy 验证失败会转换为 400；socket、HTTP/2 output queue、响应捕获和内存分配错误会原样结束请求，不会在响应已经部分提交后再次尝试写 400。
