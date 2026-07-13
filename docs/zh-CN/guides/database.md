# 数据库中间件抽象

数据库接入分为三层：

- core 的 `services.Registry` 只保存 application-owned opaque service，不认识数据库或 PostgreSQL；
- `compose/database.zig` 定义连接池、连接、参数值和按请求借还的 middleware；
- `compose/database/pgsql.zig` 定义 PostgreSQL 配置和 driver adapter 边界，具体 libpq/native wire driver 后续实现。

## 路由声明

```zig
h.post("/files/metadata", metadataHandler)
    .withLayer(z.layer.database(.required));

pub fn metadataHandler(ctx: *z.Context) !void {
    const db = z.database.connection(ctx) orelse return error.DatabaseUnavailable;
    const result = try db.exec(
        "insert into uploads (object_key, size) values ($1, $2)",
        &.{
            .{ .text = "object-key" },
            .{ .integer = 4096 },
        },
    );
    _ = result;
    try ctx.json(.ok, "{\"saved\":true}\n");
}
```

`.required` 在连接池未注册或 acquire 失败时返回 503；`.optional` 在没有 pool 时继续执行，handler 可通过 `connection(ctx)` 判断；`.none` 不触碰数据库。

## 启动层注入

```zig
var pool = try pg_driver.openPool(io, allocator, .{
    .connection_uri = "postgresql://user:password@127.0.0.1/app",
    .min_connections = 2,
    .max_connections = 16,
});

const service_entries = [_]z.services.Entry{
    z.database.service(&pool),
};

pub const registration = registry.register(.{
    .routes = &routes,
    .services = z.services.Registry{ .entries = &service_entries },
});
```

pool 与 driver state 由 composition root 持有，并且必须比所有请求活得更久。middleware acquire 后把 `Connection` 放进请求局部状态，并注册请求结束 cleanup；handler 正常返回、报错或 middleware 短路时都会 release。

服务器停止接收并等待活动请求排空后，composition root 应调用 `pool.deinit()`。连接 URI 可能含密码，不应写入访问日志、错误响应或统计标签。

## PostgreSQL 当前边界

`z.pgsql.Config` 已包含 URI、最小/最大连接数、acquire timeout 和 idle timeout；`z.pgsql.Driver` 接收外部 driver 的 `open_pool_fn`。当前仓库尚未链接 libpq，也没有宣称 PostgreSQL wire protocol 已可用。下一阶段应在 adapter 后实现：

1. 连接建立、TLS、SCRAM-SHA-256 和取消请求；
2. 有界 pool、acquire deadline、idle/失效连接回收；
3. prepared statement cache、typed row cursor 和事务对象；
4. 数据库错误分类、重试边界和 `/stats` pool 指标；
5. 上传临时文件与 metadata transaction 的补偿清理流程。
