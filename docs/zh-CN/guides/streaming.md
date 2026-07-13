# HTTP/1 与 HTTP/2 双向流框架

## Handler API

请求正文通过统一 Reader 分块消费：

```zig
const input = ctx.requestBodyStream();
var buffer: [4096]u8 = undefined;
while (true) {
    const count = try input.read(&buffer);
    if (count == 0) break;
    // process buffer[0..count]
}
```

响应使用 begin/write/finish 生命周期：

```zig
var output = try ctx.beginResponseStream(
    .ok,
    z.http_config.ContentType.octet_stream,
    null, // 未知总长度
    .no_cache,
);
errdefer output.abort();
try output.write("first\n");
try output.write("second\n");
try output.finish();
```

`content_length` 非空时会严格检查写入总字节；未知长度的 HTTP/1.1 响应使用 chunked framing，HTTP/1.0 使用 close-delimited，HTTP/2 由 deferred DATA provider 输出。HTTP/1 write 会实时 flush；HTTP/2 的请求和响应分别使用固定容量队列，队列满时 producer 等待 consumer，避免无限累积正文。

## 当前协议接入状态

| 能力 | HTTP/1.1 | HTTP/2 |
| --- | --- | --- |
| 统一 request Reader | 已接入 | 已接入 |
| handler 分块读取 | header 路由后直接读取 socket | HEADERS 后消费增量 DATA |
| 统一 response begin/write/finish | 已接入 | 已接入 |
| 分块 wire 输出 | chunked，实时 flush | deferred DATA provider，写入后 resume |
| 真正边收边 dispatch | 已接入 | 已接入 |
| 背压/取消 | socket 写阻塞；未消费完正文则关闭连接 | 双向有界队列；RST/关闭时取消 handler 与队列 |

流式路由必须显式声明 `z.layer.streamingBody()`。这使普通路由继续在 middleware/handler 前得到完整的 `request.body`，而流式路由通过 `requestBodyStream()` 消费正文。HTTP/1 支持 Content-Length 和增量 chunked decoder，并保留同一连接中已经预读的下一请求字节；handler 没有读完整个正文时连接不复用。HTTP/2 在初始 HEADERS 后启动 handler，DATA callback 向请求队列写入，响应 header 就绪后立即提交；响应队列暂时为空时 provider 返回 deferred，新的输出到达后 resume。

流式正文不会出现在 `request.body` 中，因此依赖完整正文的 XSS body scan、JSON parser、multipart parser 和上传检查器不会自动作用于这类路由。流式 handler 必须在消费 Reader 时完成对应的增量验证；不要仅添加 `streamingBody()` 就把原有缓冲式安全检查视为仍然有效。

普通缓冲路由仍受全局 16 KiB 上限；显式 streaming 路由使用 DSL 的 route body limit，框架硬上限为 1 GiB，并继续受 body absolute deadline 约束。队列取消会唤醒等待中的 producer/consumer；HTTP/2 stream 关闭会取消对应异步 handler。没有 Content-Length 且在响应开始后才越界的 HTTP/2 流会用 `ENHANCE_YOUR_CALM` RST_STREAM 中止；能够在响应前判断的超限请求仍返回 413。TLS 下的短轮询会先检查 `SSL_pending()`，再使用 AFD/平台 socket 可读性探测，只有存在数据时才进入 `SSL_read`，避免把未完成的 TLS read 与 response write 交错。

## 可运行示例

- 浏览器：启动服务器后访问 `/stream-demo.html`。`/stream/demo` 每 250ms 产生一段响应，上传按钮使用 `ReadableStream` 调用 `/stream/echo`。
- Node.js HTTP/1.1：`node examples/duplex-client.mjs`
- Node.js HTTP/2 + TLS：`node examples/duplex-client.mjs --http2`
- 超限/RST 测试：`node examples/duplex-client.mjs --http2 --bytes=20480`

Node 示例每 300ms 上传一段，并应在下一段发送前收到上一段回显。浏览器 Fetch 当前通常采用 half-duplex 语义，可能等上传完成后才向 JavaScript 暴露 Response；这属于浏览器 API 行为，不代表服务端缓冲。

## 后续扩展边界

1. `streamFileUpload()` 已提供一请求一文件的 raw-body 原子落盘；multipart parser 仍要求完整正文，后续可增加跨 Reader chunk 的事件式 multipart parser。
2. 当前 HTTP/2 接收窗口由 nghttp2/session 配置控制；大正文上限提高后，应把 WINDOW_UPDATE 与队列低水位显式联动。
3. 可继续增加 handler 执行 deadline、每路由队列容量、慢 consumer 指标与长时间 cancellation/GOAWAY soak test。
