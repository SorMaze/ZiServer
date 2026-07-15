const std = @import("std");

const Context = @import("../core/context.zig").Context;
const core_http = @import("../core/http.zig");
const http_config = @import("../core/http_config.zig");
const middleware_mod = @import("../core/middleware.zig");
const page_cache = @import("../core/page_cache.zig");
const request_mod = @import("../core/request.zig");
const router = @import("../core/router.zig");
const services_mod = @import("../core/services.zig");

const compose_routes = @import("routes.zig");

pub const max_handlers = std.math.maxInt(router.Handler);
pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const layer = @import("layers.zig");
pub const Layer = layer.Layer;

pub const OptionsBuilder = struct {
    value: router.Options = .{},

    pub fn withLayer(self: OptionsBuilder, value: Layer) OptionsBuilder {
        var next = self;
        next.value = mergeOptions(next.value, value.options);
        return next;
    }

    pub fn withLayers(self: OptionsBuilder, comptime items: anytype) OptionsBuilder {
        var next = self;
        inline for (items) |item| {
            next = next.withLayer(item);
        }
        return next;
    }

    pub fn auth(self: OptionsBuilder, next_value: http_config.AuthPolicy) OptionsBuilder {
        return self.withLayer(layer.auth(next_value));
    }

    pub fn bodyLimit(self: OptionsBuilder, next_value: usize) OptionsBuilder {
        return self.withLayer(layer.bodyLimit(next_value));
    }

    pub fn streamingBody(self: OptionsBuilder) OptionsBuilder {
        return self.withLayer(layer.streamingBody());
    }

    pub fn cache(self: OptionsBuilder, next_value: http_config.CachePolicy) OptionsBuilder {
        return self.withLayer(layer.cache(next_value));
    }

    pub fn pageCache(self: OptionsBuilder, next_value: page_cache.Policy) OptionsBuilder {
        return self.withLayer(layer.pageCache(next_value));
    }

    pub fn cacheStrategy(self: OptionsBuilder, value: page_cache.Strategy) OptionsBuilder {
        return self.withLayer(layer.cacheStrategy(value));
    }

    pub fn upload(self: OptionsBuilder, value: http_config.UploadPolicy) OptionsBuilder {
        return self.withLayer(layer.upload(value));
    }

    pub fn smallFileUpload(self: OptionsBuilder, value: http_config.SmallFileUploadConfig) OptionsBuilder {
        return self.withLayer(layer.smallFileUpload(value));
    }

    pub fn streamFileUpload(self: OptionsBuilder, value: http_config.StreamFileUploadConfig) OptionsBuilder {
        return self.withLayer(layer.streamFileUpload(value));
    }

    pub fn database(self: OptionsBuilder, value: http_config.DatabasePolicy) OptionsBuilder {
        return self.withLayer(layer.database(value));
    }

    pub fn content(self: OptionsBuilder, value: http_config.ContentPolicy) OptionsBuilder {
        return self.withLayer(layer.content(value));
    }

    pub fn apiJson(self: OptionsBuilder, max_request_bytes: usize) OptionsBuilder {
        return self.withLayer(layer.apiJson(max_request_bytes));
    }

    pub fn extract(self: OptionsBuilder, format: http_config.Representation, max_request_bytes: usize) OptionsBuilder {
        return self.withLayer(layer.extract(format, max_request_bytes));
    }

    pub fn inject(self: OptionsBuilder, format: http_config.Representation) OptionsBuilder {
        return self.withLayer(layer.inject(format));
    }

    pub fn cors(self: OptionsBuilder, next_value: http_config.CorsPolicy) OptionsBuilder {
        return self.withLayer(layer.cors(next_value));
    }

    pub fn rate(self: OptionsBuilder, next_value: http_config.RateLimitPolicy) OptionsBuilder {
        return self.withLayer(layer.rate(next_value));
    }

    pub fn requireAuth(self: OptionsBuilder) OptionsBuilder {
        return self.withLayer(layer.requireAuth());
    }

    pub fn middlewareFlags(self: OptionsBuilder, next_value: u32) OptionsBuilder {
        return self.withLayer(layer.middlewareFlags("middleware_flags", next_value));
    }

    pub fn xssObserve(self: OptionsBuilder) OptionsBuilder {
        return self.withLayer(layer.xssObserve());
    }

    pub fn xssBlock(self: OptionsBuilder) OptionsBuilder {
        return self.withLayer(layer.xssBlock());
    }

    pub fn build(self: OptionsBuilder) router.Options {
        return self.value;
    }
};

pub const RouteBuilder = struct {
    method: request_mod.Method,
    path: []const u8,
    handler: router.Handler,
    options: router.Options = .{},
    path_kind: router.PathKind,

    pub fn withOptions(self: RouteBuilder, value: router.Options) RouteBuilder {
        var next = self;
        next.options = value;
        return next;
    }

    pub fn withDefaults(self: RouteBuilder, value: anytype) RouteBuilder {
        var next = self;
        next.options = mergeOptions(toOptions(value), next.options);
        return next;
    }

    pub fn withLayer(self: RouteBuilder, value: Layer) RouteBuilder {
        var next = self;
        next.options = mergeOptions(next.options, value.options);
        return next;
    }

    pub fn withLayers(self: RouteBuilder, comptime items: anytype) RouteBuilder {
        var next = self;
        inline for (items) |item| {
            next = next.withLayer(item);
        }
        return next;
    }

    pub fn auth(self: RouteBuilder, value: http_config.AuthPolicy) RouteBuilder {
        return self.withLayer(layer.auth(value));
    }

    pub fn bodyLimit(self: RouteBuilder, value: usize) RouteBuilder {
        return self.withLayer(layer.bodyLimit(value));
    }

    pub fn streamingBody(self: RouteBuilder) RouteBuilder {
        return self.withLayer(layer.streamingBody());
    }

    pub fn cache(self: RouteBuilder, value: http_config.CachePolicy) RouteBuilder {
        return self.withLayer(layer.cache(value));
    }

    pub fn pageCache(self: RouteBuilder, value: page_cache.Policy) RouteBuilder {
        return self.withLayer(layer.pageCache(value));
    }

    pub fn cacheStrategy(self: RouteBuilder, value: page_cache.Strategy) RouteBuilder {
        return self.withLayer(layer.cacheStrategy(value));
    }

    pub fn upload(self: RouteBuilder, value: http_config.UploadPolicy) RouteBuilder {
        return self.withLayer(layer.upload(value));
    }

    pub fn smallFileUpload(self: RouteBuilder, value: http_config.SmallFileUploadConfig) RouteBuilder {
        return self.withLayer(layer.smallFileUpload(value));
    }

    pub fn streamFileUpload(self: RouteBuilder, value: http_config.StreamFileUploadConfig) RouteBuilder {
        return self.withLayer(layer.streamFileUpload(value));
    }

    pub fn database(self: RouteBuilder, value: http_config.DatabasePolicy) RouteBuilder {
        return self.withLayer(layer.database(value));
    }

    pub fn content(self: RouteBuilder, value: http_config.ContentPolicy) RouteBuilder {
        return self.withLayer(layer.content(value));
    }

    pub fn apiJson(self: RouteBuilder, max_request_bytes: usize) RouteBuilder {
        return self.withLayer(layer.apiJson(max_request_bytes));
    }

    pub fn extract(self: RouteBuilder, format: http_config.Representation, max_request_bytes: usize) RouteBuilder {
        return self.withLayer(layer.extract(format, max_request_bytes));
    }

    pub fn inject(self: RouteBuilder, format: http_config.Representation) RouteBuilder {
        return self.withLayer(layer.inject(format));
    }

    pub fn cors(self: RouteBuilder, value: http_config.CorsPolicy) RouteBuilder {
        return self.withLayer(layer.cors(value));
    }

    pub fn rate(self: RouteBuilder, value: http_config.RateLimitPolicy) RouteBuilder {
        return self.withLayer(layer.rate(value));
    }

    pub fn requireAuth(self: RouteBuilder) RouteBuilder {
        return self.withLayer(layer.requireAuth());
    }

    pub fn middlewareFlags(self: RouteBuilder, value: u32) RouteBuilder {
        return self.withLayer(layer.middlewareFlags("middleware_flags", value));
    }

    pub fn xssObserve(self: RouteBuilder) RouteBuilder {
        return self.withLayer(layer.xssObserve());
    }

    pub fn xssBlock(self: RouteBuilder) RouteBuilder {
        return self.withLayer(layer.xssBlock());
    }

    pub fn entry(self: RouteBuilder) router.Entry {
        return .{
            .method = self.method,
            .path = self.path,
            .handler = self.handler,
            .options = self.options,
            .path_kind = self.path_kind,
        };
    }
};

pub fn options() OptionsBuilder {
    return .{};
}

pub fn layers(comptime items: anytype) OptionsBuilder {
    return options().withLayers(items);
}

pub fn middlewareStack(comptime items: anytype) [middlewareCount(items)]middleware_mod.Middleware {
    var result: [middlewareCount(items)]middleware_mod.Middleware = undefined;
    var index: usize = 0;
    inline for (items) |item| {
        if (item.middleware) |middleware_item| {
            result[index] = middleware_item;
            index += 1;
        }
    }
    return result;
}

pub fn middlewareStackWithDefaults(comptime items: anytype) [compose_routes.default_middleware_stack.len + middlewareCount(items)]middleware_mod.Middleware {
    var result: [compose_routes.default_middleware_stack.len + middlewareCount(items)]middleware_mod.Middleware = undefined;
    var index: usize = 0;
    inline for (compose_routes.default_middleware_stack) |item| {
        result[index] = item;
        index += 1;
    }
    inline for (items) |item| {
        if (item.middleware) |middleware_item| {
            result[index] = middleware_item;
            index += 1;
        }
    }
    return result;
}

pub fn get(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.get, path, handler);
}

pub fn head(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.head, path, handler);
}

pub fn post(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.post, path, handler);
}

pub fn put(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.put, path, handler);
}

pub fn delete(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.delete, path, handler);
}

pub fn patch(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.patch, path, handler);
}

pub fn optionsRoute(comptime path: []const u8, handler: router.Handler) RouteBuilder {
    return route(.options, path, handler);
}

pub fn route(method: request_mod.Method, comptime path: []const u8, handler: router.Handler) RouteBuilder {
    // Large app route tables evaluate builder calls in one comptime expression.
    // Raise the quota at the common entry point instead of forcing each app to.
    @setEvalBranchQuota(10_000);
    validatePath(path);
    return .{
        .method = method,
        .path = path,
        .handler = handler,
        .path_kind = comptime router.classifyPath(path),
    };
}

pub fn handlers(comptime funcs: anytype) type {
    if (funcs.len == 0) @compileError("z.handlers() requires at least one handler");
    if (funcs.len > max_handlers) @compileError("z.handlers() has more handlers than router.Handler can represent");

    return struct {
        pub const len = funcs.len;
        const dispatch_table: [funcs.len]HandlerFn = block: {
            var table: [funcs.len]HandlerFn = undefined;
            for (funcs, 0..) |handler_fn, index| {
                table[index] = handler_fn;
            }
            break :block table;
        };

        pub fn id(comptime handler_fn: anytype) router.Handler {
            const target: HandlerFn = handler_fn;
            inline for (funcs, 0..) |candidate, index| {
                const current: HandlerFn = candidate;
                if (current == target) return @intCast(index + 1);
            }
            @compileError("handler function is not registered in this z.handlers() set");
        }

        pub fn get(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.get, path, id(handler_fn));
        }

        pub fn head(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.head, path, id(handler_fn));
        }

        pub fn post(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.post, path, id(handler_fn));
        }

        pub fn put(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.put, path, id(handler_fn));
        }

        pub fn delete(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.delete, path, id(handler_fn));
        }

        pub fn patch(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.patch, path, id(handler_fn));
        }

        pub fn optionsRoute(comptime path: []const u8, comptime handler_fn: anytype) RouteBuilder {
            return route(.options, path, id(handler_fn));
        }

        pub fn dispatch(ctx: *Context, handler: router.Handler) anyerror!void {
            if (handler == 0 or handler > dispatch_table.len) return error.UnknownHandler;
            return dispatch_table[handler - 1](ctx);
        }

        pub fn register(config: anytype) compose_routes.Registration {
            const Config = @TypeOf(config);
            if (!@hasField(Config, "routes")) @compileError("handler registry register() requires .routes");
            return compose_routes.Registration{
                .routes = config.routes,
                .dispatch = dispatch,
                .auth_credentials = if (@hasField(Config, "auth_credentials")) config.auth_credentials else .{},
                .services = if (@hasField(Config, "services")) config.services else .{},
                .middleware_stack = if (@hasField(Config, "middleware_stack")) config.middleware_stack else &compose_routes.default_middleware_stack,
            };
        }
    };
}

pub fn RouteGroup(comptime len: usize) type {
    return struct {
        pub const is_route_group = true;

        entries: [len]router.Entry,
    };
}

pub fn group(comptime config: anytype) RouteGroup(config.routes.len) {
    const Config = @TypeOf(config);
    const layer_defaults = if (@hasField(Config, "layers")) toOptions(config.layers) else router.Options{};
    const option_defaults = if (@hasField(Config, "defaults")) toOptions(config.defaults) else router.Options{};
    const defaults = mergeOptions(layer_defaults, option_defaults);
    const prefix = if (@hasField(Config, "prefix")) config.prefix else "";
    validatePrefix(prefix);

    var result: [config.routes.len]router.Entry = undefined;
    inline for (config.routes, 0..) |item, index| {
        var entry = item.withDefaults(defaults).entry();
        entry.path = joinPaths(prefix, item.path);
        result[index] = entry;
    }
    return .{ .entries = result };
}

pub fn routes(comptime items: anytype) [routeCount(items)]router.Entry {
    @setEvalBranchQuota(10_000);
    var result: [routeCount(items)]router.Entry = undefined;
    var index: usize = 0;

    inline for (items) |item| {
        if (comptime isRouteGroup(@TypeOf(item))) {
            inline for (item.entries) |entry| {
                result[index] = entry;
                index += 1;
            }
        } else {
            result[index] = item.entry();
            index += 1;
        }
    }

    return result;
}

pub const AppConfig = struct {
    routes: []const router.Entry,
    dispatch: core_http.DispatchFn,
    auth_credentials: http_config.AuthCredentials = .{},
    services: services_mod.Registry = .{},
    middleware_stack: ?[]const middleware_mod.Middleware = null,
};

pub fn register(config: AppConfig) compose_routes.Registration {
    return .{
        .routes = config.routes,
        .dispatch = config.dispatch,
        .auth_credentials = config.auth_credentials,
        .services = config.services,
        .middleware_stack = config.middleware_stack orelse &compose_routes.default_middleware_stack,
    };
}

test "route builder emits router entries" {
    const built = routes(.{
        get("/", 1).cache(.api_short).cors(.public_read).rate(.relaxed),
        post("/submit", 2).bodyLimit(1024).cors(.public_form).xssObserve(),
    });

    try std.testing.expectEqual(@as(usize, 2), built.len);
    try std.testing.expectEqual(@as(router.Handler, 1), built[0].handler);
    try std.testing.expectEqual(http_config.CachePolicy.api_short, built[0].options.cache.?);
    try std.testing.expectEqual(http_config.CorsPolicy.public_form, built[1].options.cors);
    try std.testing.expectEqual(@as(usize, 1024), built[1].options.body_limit.?);
}

test "register wraps routes and dispatch" {
    const built = routes(.{get("/", 1)});
    const registration = register(.{
        .routes = &built,
        .dispatch = testDispatch,
        .auth_credentials = .{ .bearer_token = "token" },
    });

    try std.testing.expectEqual(@as(usize, 1), registration.routes.len);
    try std.testing.expectEqualStrings("token", registration.auth_credentials.bearer_token.?);
}

fn testDispatch(_: *@import("../core/context.zig").Context, _: router.Handler) anyerror!void {}

test "register accepts custom middleware stack" {
    const built = routes(.{get("/", 1)});
    const stack = middlewareStack(.{
        layer.middleware("custom_test", testMiddleware),
    });
    const registration = register(.{
        .routes = &built,
        .dispatch = testDispatch,
        .middleware_stack = &stack,
    });

    try std.testing.expectEqual(@as(usize, 1), registration.middleware_stack.len);
    try std.testing.expectEqualStrings("custom_test", registration.middleware_stack[0].name);
}

test "layers merge route options" {
    const built = routes(.{
        get("/", 1).withLayers(.{
            layer.cache(.api_short),
            layer.cors(.public_read),
            layer.rate(.relaxed),
        }),
        post("/submit", 2).withLayer(layer.bodyLimit(512)).withLayer(layer.xssBlock()),
        post("/api/echo", 3).withLayer(layer.jsonBodyLimit(256)),
        get("/page", 4).cacheStrategy(.static_shared),
        post("/upload", 5).withLayer(layer.upload(.{ .max_request_bytes = 2048, .max_file_bytes = 1024 })),
        post("/upload/store", 6).withLayer(layer.smallFileUpload(.{
            .validation = .{ .max_request_bytes = 4096, .max_file_bytes = 2048 },
            .storage = .{ .directory = "var/test-small" },
        })),
        put("/upload/stream", 7).withLayer(layer.streamFileUpload(.{
            .max_request_bytes = 64 * 1024 * 1024,
            .storage = .{ .directory = "var/test-large" },
        })),
        get("/database", 8).withLayer(layer.database(.required)),
        post("/content", 9).withLayers(.{ layer.extract(.xml, 2048), layer.inject(.json) }),
    });

    try std.testing.expectEqual(http_config.CachePolicy.api_short, built[0].options.cache.?);
    try std.testing.expectEqual(http_config.CorsPolicy.public_read, built[0].options.cors);
    try std.testing.expectEqual(http_config.RateLimitPolicy.relaxed, built[0].options.rate_limit);
    try std.testing.expectEqual(@as(usize, 512), built[1].options.body_limit.?);
    try std.testing.expectEqual(@import("xss.zig").flag_block, built[1].options.middleware_flags);
    try std.testing.expectEqual(@as(usize, 256), built[2].options.body_limit.?);
    try std.testing.expect((built[2].options.middleware_flags & @import("json_body.zig").flag_validate_json_body) != 0);
    try std.testing.expectEqual(page_cache.Strategy.static_shared, built[3].options.cache_strategy.?);
    try std.testing.expectEqual(@as(usize, 2048), built[4].options.body_limit.?);
    try std.testing.expectEqual(@as(usize, 1024), built[4].options.upload.?.max_file_bytes);
    try std.testing.expectEqual(@as(usize, 4096), built[5].options.body_limit.?);
    try std.testing.expectEqualStrings("var/test-small", built[5].options.upload_landing.small.storage.directory);
    try std.testing.expect(built[6].options.streaming_body);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), built[6].options.body_limit.?);
    try std.testing.expectEqual(http_config.DatabasePolicy.required, built[7].options.database);
    try std.testing.expectEqual(http_config.Representation.xml, built[8].options.content.?.request);
    try std.testing.expectEqual(http_config.Representation.json, built[8].options.content.?.response);
    try std.testing.expectEqual(@as(usize, 2048), built[8].options.body_limit.?);
}

test "fluent middleware flags compose instead of replacing earlier flags" {
    const json_flag = @import("json_body.zig").flag_validate_json_body;
    const block_flag = @import("xss.zig").flag_block;
    const built = routes(.{
        post("/combined", 1).middlewareFlags(json_flag).xssBlock(),
    });
    try std.testing.expectEqual(json_flag | block_flag, built[0].options.middleware_flags);
}

test "group accepts layer defaults" {
    const built = routes(.{
        group(.{
            .prefix = "/api",
            .layers = layers(.{
                layer.cache(.no_cache),
                layer.cors(.public_read),
                layer.rate(.strict),
            }),
            .routes = .{
                get("/health", 1),
                get("/stats", 2).withLayer(layer.rate(.relaxed)),
            },
        }),
    });

    try std.testing.expectEqualStrings("/api/health", built[0].path);
    try std.testing.expectEqual(http_config.CachePolicy.no_cache, built[1].options.cache.?);
    try std.testing.expectEqual(http_config.CorsPolicy.public_read, built[1].options.cors);
    try std.testing.expectEqual(http_config.RateLimitPolicy.relaxed, built[1].options.rate_limit);
}

test "cache strategy arena supports group defaults and route overrides" {
    const built = routes(.{
        group(.{
            .prefix = "/cache-arena",
            .layers = layers(.{layer.cacheStrategy(.static_shared)}),
            .routes = .{
                get("/shared", 1),
                get("/never", 2).cacheStrategy(.never),
            },
        }),
    });

    try std.testing.expectEqual(page_cache.Strategy.static_shared, built[0].options.cache_strategy.?);
    try std.testing.expectEqual(page_cache.Strategy.never, built[1].options.cache_strategy.?);
}

test "middleware stack extracts executable layers" {
    const stack = middlewareStack(.{
        layer.cache(.api_short),
        layer.middleware("custom_test", testMiddleware),
    });

    try std.testing.expectEqual(@as(usize, 1), stack.len);
    try std.testing.expectEqualStrings("custom_test", stack[0].name);
}

test "middleware stack can extend defaults" {
    const stack = middlewareStackWithDefaults(.{
        layer.middleware("custom_test", testMiddleware),
    });

    try std.testing.expectEqual(compose_routes.default_middleware_stack.len + 1, stack.len);
    try std.testing.expectEqualStrings(compose_routes.default_middleware_stack[0].name, stack[0].name);
    try std.testing.expectEqualStrings("custom_test", stack[stack.len - 1].name);
}

test "handler registry maps functions to route builders" {
    const registry = handlers(.{
        testHome,
        testSubmit,
    });
    const built = routes(.{
        registry.get("/", testHome),
        registry.post("/submit", testSubmit).bodyLimit(64),
    });

    try std.testing.expectEqual(@as(usize, 2), built.len);
    try std.testing.expectEqual(@as(router.Handler, 1), built[0].handler);
    try std.testing.expectEqual(@as(router.Handler, 2), built[1].handler);
    try std.testing.expectEqual(@as(usize, 64), built[1].options.body_limit.?);
    try std.testing.expectEqual(router.PathKind.exact, built[0].path_kind);
}

test "handler registry binds dispatch during registration" {
    const registry = handlers(.{testHome});
    const built = routes(.{registry.get("/", testHome)});
    const registration = registry.register(.{
        .routes = &built,
        .auth_credentials = http_config.AuthCredentials{ .bearer_token = "token" },
    });

    try std.testing.expectEqual(@as(usize, 1), registration.routes.len);
    try std.testing.expect(registration.dispatch == registry.dispatch);
    try std.testing.expectEqualStrings("token", registration.auth_credentials.bearer_token.?);
}

fn testHome(_: *Context) anyerror!void {}

fn testSubmit(_: *Context) anyerror!void {}

fn testMiddleware(_: *Context) anyerror!middleware_mod.Decision {
    return .next;
}

fn routeCount(comptime items: anytype) comptime_int {
    var total: comptime_int = 0;
    inline for (items) |item| {
        if (comptime isRouteGroup(@TypeOf(item))) {
            total += item.entries.len;
        } else {
            total += 1;
        }
    }
    return total;
}

fn middlewareCount(comptime items: anytype) comptime_int {
    var total: comptime_int = 0;
    inline for (items) |item| {
        if (item.middleware != null) total += 1;
    }
    return total;
}

fn isRouteGroup(comptime T: type) bool {
    return @hasDecl(T, "is_route_group");
}

fn toOptions(value: anytype) router.Options {
    const T = @TypeOf(value);
    if (T == router.Options) return value;
    if (T == OptionsBuilder) return value.build();
    @compileError("expected router.Options or z.options() builder");
}

fn mergeOptions(defaults: router.Options, overrides: router.Options) router.Options {
    return .{
        .auth = if (overrides.auth != .none) overrides.auth else defaults.auth,
        .body_limit = overrides.body_limit orelse defaults.body_limit,
        .cache = overrides.cache orelse defaults.cache,
        .cors = if (overrides.cors != .none) overrides.cors else defaults.cors,
        .rate_limit = if (overrides.rate_limit != .none) overrides.rate_limit else defaults.rate_limit,
        .require_auth = defaults.require_auth or overrides.require_auth,
        .middleware_flags = defaults.middleware_flags | overrides.middleware_flags,
        .page_cache = if (overrides.page_cache != .none) overrides.page_cache else defaults.page_cache,
        .cache_strategy = overrides.cache_strategy orelse defaults.cache_strategy,
        .upload = overrides.upload orelse defaults.upload,
        .upload_landing = switch (overrides.upload_landing) {
            .none => defaults.upload_landing,
            else => overrides.upload_landing,
        },
        .streaming_body = defaults.streaming_body or overrides.streaming_body,
        .database = if (overrides.database != .none) overrides.database else defaults.database,
        .content = mergeContentPolicy(defaults.content, overrides.content),
    };
}

fn mergeContentPolicy(defaults: ?http_config.ContentPolicy, overrides: ?http_config.ContentPolicy) ?http_config.ContentPolicy {
    const next = overrides orelse return defaults;
    const base = defaults orelse http_config.ContentPolicy{};
    return .{
        .request = if (next.request != .none) next.request else base.request,
        .response = if (next.response != .none) next.response else base.response,
        .max_request_bytes = next.max_request_bytes orelse base.max_request_bytes,
        .request_validation = if (next.request != .none) next.request_validation else base.request_validation,
        .response_validation = if (next.response != .none) next.response_validation else base.response_validation,
        .request_content_type = next.request_content_type orelse base.request_content_type,
        .response_content_type = next.response_content_type orelse base.response_content_type,
        .request_codec = if (next.request_codec != 0) next.request_codec else base.request_codec,
        .response_codec = if (next.response_codec != 0) next.response_codec else base.response_codec,
    };
}

fn validatePrefix(comptime prefix: []const u8) void {
    if (prefix.len == 0) return;
    validatePath(prefix);
    if (prefix.len > 1 and prefix[prefix.len - 1] == '/') {
        @compileError("route group prefix must not end with '/'");
    }
}

fn validatePath(comptime path: []const u8) void {
    if (path.len == 0 or path[0] != '/') {
        @compileError("route path must start with '/'");
    }
    if (std.mem.indexOfScalar(u8, path, '\\') != null) {
        @compileError("route path must not contain backslash");
    }
    if (std.mem.indexOf(u8, path, "..") != null) {
        @compileError("route path must not contain '..'");
    }

    var parts = std.mem.splitScalar(u8, path, '/');
    var wildcard_seen = false;
    while (parts.next()) |segment| {
        if (wildcard_seen) @compileError("route wildcard parameter must be the final path segment");
        if (segment.len == 0) continue;

        if (segment[0] == ':') {
            if (segment.len == 1) @compileError("route dynamic parameter name cannot be empty");
            continue;
        }

        if (segment[0] == '*') {
            if (segment.len == 1) @compileError("route wildcard parameter name cannot be empty");
            wildcard_seen = true;
        }
    }
}

fn joinPaths(comptime prefix: []const u8, comptime path: []const u8) []const u8 {
    if (prefix.len == 0) return path;
    if (std.mem.eql(u8, path, "/")) return prefix;
    return prefix ++ path;
}

test "route group applies defaults and prefix" {
    const built = routes(.{
        group(.{
            .prefix = "/site",
            .defaults = options().cache(.api_short).cors(.public_read).rate(.relaxed),
            .routes = .{
                get("/", 1),
                get("/:page", 2).cache(.no_cache),
            },
        }),
    });
    try std.testing.expectEqual(@as(usize, 2), built.len);
    try std.testing.expectEqualStrings("/site", built[0].path);
    try std.testing.expectEqualStrings("/site/:page", built[1].path);
    try std.testing.expectEqual(http_config.CachePolicy.api_short, built[0].options.cache.?);
    try std.testing.expectEqual(http_config.CachePolicy.no_cache, built[1].options.cache.?);
    try std.testing.expectEqual(http_config.CorsPolicy.public_read, built[1].options.cors);
    try std.testing.expectEqual(http_config.RateLimitPolicy.relaxed, built[1].options.rate_limit);
}

test "routes flattens groups beside single routes" {
    const built = routes(.{
        group(.{
            .defaults = options().cache(.api_short),
            .routes = .{
                get("/", 1),
                get("/about", 2),
            },
        }),
        post("/submit", 3).bodyLimit(256),
    });

    try std.testing.expectEqual(@as(usize, 3), built.len);
    try std.testing.expectEqualStrings("/about", built[1].path);
    try std.testing.expectEqual(@as(router.Handler, 3), built[2].handler);
    try std.testing.expectEqual(@as(usize, 256), built[2].options.body_limit.?);
}
