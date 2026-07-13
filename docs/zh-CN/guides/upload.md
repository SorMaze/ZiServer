# 用户上传拦截与处理

上传能力分为三种显式路由策略：

- `z.layer.upload(...)`：只解析并验证小型 `multipart/form-data`，不落盘；
- `z.layer.smallFileUpload(...)`：验证完整 multipart 后，把一个或多个小文件原子落盘；
- `z.layer.streamFileUpload(...)`：一请求一文件，边接收边写临时文件，完成后原子提交。

只有后两种 DSL 明确声明了磁盘副作用。普通 `upload(...)` 仍然只检查；handler 也可以绕过磁盘 layer，自行选择对象存储或异步任务。

上传策略构造器集中在 `compose/layers.zig`，通用路由 DSL 只合并 `Layer`，不再了解 upload、JSON、XSS 等各功能的构造细节。这样新增或修改上传策略不会继续扩大通用 DSL。

## 当前能力

### 只校验，不落盘

```zig
const policy: z.UploadPolicy = .{
    .max_request_bytes = 16 * 1024,
    .max_file_bytes = 8 * 1024,
    .max_files = 2,
    .allowed_content_types = &.{ "text/plain", "image/png" },
    .allowed_extensions = &.{ ".txt", ".png" },
};

h.post("/upload", uploadHandler)
    .withLayers(.{
        z.layer.upload(policy),
        z.layer.cache(.no_cache),
        z.layer.rate(.strict),
    });

pub fn uploadHandler(ctx: *z.Context) !void {
    // upload middleware 已完成解析；这里直接取得请求内缓存的 Summary。
    const summary = try z.upload.inspect(ctx);
    // app 在此选择临时文件、对象存储或仅返回统计。
    _ = summary;
    try ctx.json(.ok, "{\"stored\":false}\n");
}
```

### 小文件 multipart 落盘

```zig
const small_upload: z.SmallFileUploadConfig = .{
    .validation = .{
        .max_request_bytes = 16 * 1024,
        .max_file_bytes = 8 * 1024,
        .max_files = 2,
        .allowed_content_types = &.{ "text/plain", "image/png" },
        .allowed_extensions = &.{ ".txt", ".png" },
    },
    .storage = .{
        .directory = "var/uploads/small",
        .naming = .random,
        .collision = .reject,
        .create_directory = true,
        .sync_on_finish = false,
    },
};

h.post("/upload/store", storedHandler)
    .withLayer(z.layer.smallFileUpload(small_upload));
```

小文件仍先完整缓冲并完成 multipart 校验，然后逐文件写入临时文件。`.random` 使用 128-bit 随机十六进制名称并仅保留已验证扩展名；`.original` 使用安全检查后的原名。`.reject` 不覆盖现有文件，`.replace` 原子替换。`sync_on_finish` 会在提交前执行文件 fsync，提供更强持久性但明显增加延迟；当前不额外 fsync 父目录，因此不宣称断电后的目录项绝对持久化。

### 大文件流式落盘

```zig
const large_upload: z.StreamFileUploadConfig = .{
    .max_request_bytes = 256 * 1024 * 1024,
    .filename_header = "X-Upload-Filename",
    .allowed_content_types = &.{z.http_config.ContentType.octet_stream},
    .allowed_extensions = &.{ ".bin", ".txt", ".png" },
    .storage = .{
        .directory = "var/uploads/large",
        .naming = .random,
        .collision = .reject,
    },
};

h.put("/upload/stream", storedHandler)
    .withLayer(z.layer.streamFileUpload(large_upload));

pub fn storedHandler(ctx: *z.Context) !void {
    const stored = z.upload_storage.result(ctx) orelse return error.UploadStorageFailed;
    _ = stored;
    try ctx.json(.ok, "{\"stored\":true}\n");
}
```

大文件协议是一个请求对应一个原始文件正文，默认 `Content-Type: application/octet-stream`，文件展示名由 `X-Upload-Filename` 提供。它不是流式 multipart：这样无需在跨 DATA/chunk 边界解析 multipart delimiter，也不会把大正文重新拼回内存。HTTP/1.1 支持 Content-Length 和 chunked，HTTP/2 使用有界 DATA queue 和 socket/flow-control 反压。

可运行客户端：

```powershell
node examples/upload-client.mjs
node examples/upload-client.mjs --http2
```

拦截器会检查：

- 请求方法及 `multipart/form-data` boundary；
- multipart 结构、part header 和 `Content-Disposition`；
- 总请求大小、文件数量和单文件大小；
- MIME 与扩展名白名单；
- 空文件选择、缺少文件；
- `../a.txt`、绝对/反斜杠路径、控制字符、Windows 设备名、首尾点或空格等危险文件名。

`z.upload.inspect(ctx)` 返回 part、普通字段、文件数量和文件字节数。默认 upload middleware 会先调用它；结果保存在 `Context` 的请求局部存储中，所以 handler 再调用时不会第二次扫描 multipart。`z.upload.inspectRequest()` 是无 `Context` 的底层入口，适合独立解析、测试或自定义 pipeline，正常路由 handler 应优先使用 `inspect(ctx)`。

验证通过后，app 可以使用公开的 `z.upload.MultipartIterator` 逐个读取 `Part.name`、`filename`、`content_type` 和 `data`。当前 `/upload` 只验证，`/upload/store` 演示小文件落盘，`PUT /upload/stream` 演示大文件流式落盘。

## 当前性能

2026-07-13 在本机 Windows、ReleaseFast、关闭访问日志、8 个 HTTP/1.1 连接下，使用一个包含 2 KiB `.txt` 文件的 multipart 请求压测 `/upload`：

| 实现 | req/s | 平均延迟 | 失败 |
| --- | ---: | ---: | ---: |
| middleware 与 handler 各解析一次 | 113,532 | 69.7 us | 0 |
| 请求内复用一次解析结果，三轮中位数 | 117,689 | 67.0 us | 0 |

代表性吞吐提升约 3.7%。这是“小文件内存解析与策略校验”的吞吐，不包含磁盘写入、对象存储、病毒扫描或大文件流式 I/O，不能当作持久化上传性能。

HTTP/2 同一负载已完成 TLS 1.3 + ALPN `h2` 功能验证；单 stream 测试零失败。高并发 stream 下正文 DATA 的 flow-control/session 轮询成本明显高于无正文 GET，且本轮基准在结束排空阶段仍观察到少量读超时，因此暂不发布一个容易误导的稳定 HTTP/2 上传吞吐数字。

## 安全边界

浏览器提交的 filename、扩展名和 `Content-Type` 都不可信。真正落盘前仍应：

1. 由服务端生成随机存储名，原文件名只作为经过编码的展示元数据；
2. 根据文件签名重新识别类型，而不是只相信 MIME/扩展名；
3. 写入 web root 之外的隔离临时目录，并使用独占创建避免覆盖；
4. 执行病毒扫描或异步内容审核，再转为可下载状态；
5. 对用户、租户和总存储量另设配额；
6. 下载时固定 `Content-Disposition: attachment`，并禁止 MIME sniffing。

普通缓冲路由仍有 16 KiB 硬上限；只有显式 streaming 路由可提高到每路由配置值，框架总上限为 1 GiB。大文件写入期间不会保留完整正文，失败、取消或超限会由 atomic file 清理临时文件。每个文件的提交是原子的，但多文件 multipart 不是跨文件事务：第二个文件失败时，第一个已提交文件不会自动回滚。

落盘只是接收阶段。原文件名、owner、hash、审核状态和最终对象 key 应写入数据库；病毒扫描或内容审核通过前，不应把文件暴露为公开下载。数据库 middleware 接口见 [`database.md`](database.md)。
