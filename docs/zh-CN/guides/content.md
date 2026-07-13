# 统一内容提取与注入

ZiServer 用一个表示层处理 JSON、XML、HTML、TOML、任意二进制和应用自定义格式：

- `core/http_config.zig` 只定义 `Representation` 与 `ContentPolicy`，不认识 parser、codec 或业务对象；
- `compose/content.zig` 校验媒体类型和正文边界，把请求变成借用式 `Document`，并按路由策略写响应；
- `app` 通过 route layer 声明格式，handler 只读取 `Document` 或调用统一 injector；
- 自定义 codec 由 app 通过 `services.Registry` 注入，core/compose 不反向依赖 app。

`Document` 不复制正文，也不默认构建 XML/HTML/TOML AST。它只保存格式、custom codec id 和一个借用自请求正文的 slice，因此请求结束后不可继续保存。这样可避免框架为未知格式制造无界分配和跨格式对象模型。

## App DSL

同时声明提取和注入：

```zig
h.post("/api/echo", apiEcho)
    .withLayer(z.layer.content(.{
        .request = .json,
        .response = .json,
        .max_request_bytes = 1024,
    }));
```

分开组合也会合并成同一份 route policy：

```zig
h.post("/content/xml", contentEcho)
    .withLayers(.{
        z.layer.extract(.xml, 4096),
        z.layer.inject(.xml),
        z.layer.cache(.no_cache),
    });
```

也可使用 fluent 写法：

```zig
h.post("/content/toml", contentEcho)
    .extract(.toml, 4096)
    .inject(.toml);
```

handler 对所有内置格式使用同一接口：

```zig
pub fn contentEcho(ctx: *z.Context) !void {
    const doc = z.content.document(ctx) orelse
        return error.InvalidContentEncoding;

    // 原样回显；目标 MIME 由 route 的 response 策略决定。
    try z.content.injectDocument(ctx, .ok, doc, .no_cache);
}
```

JSON 可按需转成业务类型，不把 typed model 放进 compose：

```zig
const Payload = struct {
    message: []const u8,
    count: i64 = 0,
};

pub fn jsonHandler(ctx: *z.Context) !void {
    const doc = z.content.document(ctx) orelse
        return error.InvalidContentEncoding;
    var parsed = doc.parseJson(Payload, std.heap.page_allocator) catch
        return error.InvalidContentEncoding;
    defer parsed.deinit();

    // 先用 JSON serializer/转义器生成目标 bytes，再统一注入。
    try z.content.inject(ctx, .ok, "{\"ok\":true}\n", .no_cache);
}
```

## 内置格式行为

| 表示 | 默认请求媒体类型 | 默认响应媒体类型 | `basic` 校验 |
|---|---|---|---|
| JSON | `application/json`、`application/*+json` | `application/json; charset=utf-8` | Zig 标准 JSON parser 完整语法校验 |
| XML | `application/xml`、`text/xml`、`application/*+xml` | `application/xml; charset=utf-8` | UTF-8、控制字符、基本 envelope；拒绝 DTD/ENTITY |
| HTML | `text/html`、`application/xhtml+xml` | `text/html; charset=utf-8` | UTF-8 和非法控制字符，允许 fragment |
| TOML | `application/toml`、`text/toml` | `application/toml; charset=utf-8` | UTF-8 和非法控制字符 |
| binary | 任意或缺失 | `application/octet-stream` | opaque bytes，不解释内容 |

XML/HTML/TOML 的 `basic` 是有界词法防线，不是 schema、DOM 或完整语义解析器。业务需要严格 XML/TOML 语义时，应在 handler 中调用专用库，并继续设置业务级节点数、嵌套深度和字符串长度限制。XML 默认拒绝 `DOCTYPE`/`ENTITY`，避免后续 parser 意外打开外部实体。

可以覆盖媒体类型或关闭框架校验：

```zig
z.layer.content(.{
    .request = .binary,
    .response = .binary,
    .max_request_bytes = 64 * 1024,
    .request_content_type = "application/x-protobuf",
    .response_content_type = "application/x-protobuf",
    .request_validation = .none,
    .response_validation = .none,
})
```

关闭校验只适用于后续有明确 decoder 和边界限制的格式。响应 injector 是格式检查与 MIME 写出器，不做 JSON/XML/TOML 之间的隐式转码。

## App 自定义 codec

自定义 codec 用非零、应用内唯一的 `u16` id 注册。extractor 只能返回请求正文的 subslice；需要分配的 decode 应由 handler 执行，并通过 `Context.registerCleanup` 或 handler 自己的 `defer` 释放。

```zig
const custom_codec_id: u16 = 41;

fn stripEnvelope(_: *z.Context, bytes: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, bytes, "v1:"))
        return error.InvalidContentEncoding;
    return bytes[3..]; // 借用原 request body
}

fn writeEnvelope(
    ctx: *z.Context,
    status: z.Status,
    bytes: []const u8,
    cache: z.CachePolicy,
) !void {
    try ctx.writeBytes(status, "application/x-example", bytes, cache, &.{});
}

const codecs = [_]z.ContentCodec{.{
    .id = custom_codec_id,
    .request_content_types = &.{"application/x-example"},
    .response_content_type = "application/x-example",
    .extract = stripEnvelope,
    .inject = writeEnvelope,
}};

var content_runtime = z.ContentRuntime.init(&codecs) catch unreachable;
var service_entries = [_]z.services.Entry{
    z.content.service(&content_runtime),
};

const routes = z.routes(.{
    h.post("/custom", customHandler).withLayer(z.layer.content(.{
        .request = .custom,
        .response = .custom,
        .max_request_bytes = 4096,
        .request_codec = custom_codec_id,
        .response_codec = custom_codec_id,
    })),
});

pub const registration = registry.register(.{
    .routes = &routes,
    .services = .{ .entries = &service_entries },
});
```

`Runtime.init` 拒绝 id 0 和重复 id。路由引用未注册 id、漏注入 runtime 或让 extractor 返回外部内存时都会 fail closed 为 500，而不会静默退回 binary。

## 缓冲、流式与性能边界

统一 `Document` 面向有界、已缓冲正文，`max_request_bytes` 同时进入 route body limit。它不适用于超大对象；声明 `streamingBody()` 的路由会拒绝 content extractor，应用应直接使用 `ctx.requestBodyStream()`，按流式 decoder 的状态机和自己的总量/深度限制处理。响应大对象同理使用 `beginResponseStream()`。

性能建议：

1. binary、HTML fragment、已由业务 decoder 验证的内容可谨慎设置 `.request_validation = .none`；
2. JSON `basic` 会先做一次完整语法校验，随后 typed parse 再解析一次；极致吞吐路径可关闭前置校验，让 handler 的 typed parse 成为唯一校验点，但必须把 parse error 映射为 `InvalidContentEncoding`；
3. 不要把 `Document.bytes` 保存到请求结束之后；需要持久化时复制到有明确所有权和上限的内存或流式落盘；
4. 不要把不可信 HTML 直接注入管理页面；`Content-Type`、CSP 和 XSS 观察不能替代上下文相关输出编码。

默认示例提供 `/content/json`、`/content/xml`、`/content/html`、`/content/toml` 和 `/content/binary`，它们使用同一个 handler 原样回显，用于验证提取/注入和 MIME 行为。
