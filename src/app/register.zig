const std = @import("std");

const z = @import("../ziserver.zig");

const examples = @import("examples.zig");
const site = @import("site.zig");
const system = @import("system.zig");

const registry = z.handlers(.{
    system.health,
    system.stats,
    examples.submit,
    examples.apiEcho,
    examples.contentEcho,
    examples.upload,
    examples.uploadStored,
    examples.streamEcho,
    examples.streamChunks,
    examples.streamDemo,
    site.handle,
});

const h = registry;

const public_page_layers = z.layers(.{
    z.layer.cache(.api_short),
    z.layer.pageCache(.standard),
    z.layer.cors(.public_read),
    z.layer.rate(.relaxed),
});

const public_api_layers = z.layers(.{
    z.layer.cache(.no_cache),
    z.layer.cors(.public_read),
    z.layer.rate(.relaxed),
});

const public_pages = z.group(.{
    .layers = public_page_layers,
    .routes = .{
        h.get("/", site.handle),
        h.get("/about", site.handle),
        h.get("/products", site.handle),
        h.get("/api", site.handle),
        h.get("/security", site.handle),
        h.get("/contact", site.handle),
    },
});

const site_aliases = z.group(.{
    .prefix = "/site",
    .layers = public_page_layers,
    .routes = .{
        h.get("/", site.handle),
        h.get("/:page", site.handle),
    },
});

const public_api = z.group(.{
    .layers = public_api_layers,
    .routes = .{
        h.get("/health", system.health),
        h.get("/stats", system.stats),
    },
});

const content_routes = z.group(.{
    .prefix = "/content",
    .routes = .{
        h.post("/json", examples.contentEcho)
            .withLayers(.{ z.layer.extract(.json, 4096), z.layer.inject(.json), z.layer.cache(.no_cache) }),
        h.post("/xml", examples.contentEcho)
            .withLayers(.{ z.layer.extract(.xml, 4096), z.layer.inject(.xml), z.layer.cache(.no_cache) }),
        h.post("/html", examples.contentEcho)
            .withLayers(.{ z.layer.extract(.html, 4096), z.layer.inject(.html), z.layer.cache(.no_cache) }),
        h.post("/toml", examples.contentEcho)
            .withLayers(.{ z.layer.extract(.toml, 4096), z.layer.inject(.toml), z.layer.cache(.no_cache) }),
        h.post("/binary", examples.contentEcho)
            .withLayers(.{ z.layer.extract(.binary, 4096), z.layer.inject(.binary), z.layer.cache(.no_cache) }),
    },
});

const routes = z.routes(.{
    public_pages,
    site_aliases,
    public_api,
    h.get("/admin/stats", system.stats)
        .withLayer(z.layer.auth(.bearer_or_api_key))
        .withLayer(z.layer.rate(.strict)),
    h.post("/submit", examples.submit)
        .withLayers(.{
        z.layer.bodyLimit(1024),
        z.layer.cache(.no_cache),
        z.layer.cors(.public_form),
        z.layer.rate(.strict),
        z.layer.xssObserve(),
    }),
    h.post("/api/echo", examples.apiEcho)
        .withLayers(.{
        z.layer.apiJson(1024),
        z.layer.cache(.no_cache),
        z.layer.cors(.public_form),
        z.layer.rate(.strict),
        z.layer.xssObserve(),
    }),
    content_routes,
    h.post("/upload", examples.upload)
        .withLayers(.{
        z.layer.upload(examples.upload_policy),
        z.layer.cache(.no_cache),
        z.layer.cors(.public_form),
        z.layer.rate(.strict),
    }),
    h.post("/upload/store", examples.uploadStored)
        .withLayers(.{
        z.layer.smallFileUpload(examples.small_file_upload),
        z.layer.cache(.no_cache),
        z.layer.cors(.public_form),
        z.layer.rate(.strict),
    }),
    h.put("/upload/stream", examples.uploadStored)
        .withLayers(.{
        z.layer.streamFileUpload(examples.stream_file_upload),
        z.layer.cache(.no_cache),
        z.layer.rate(.strict),
    }),
    h.post("/stream/echo", examples.streamEcho)
        .withLayers(.{
        z.layer.bodyLimit(z.http_config.max_form_body_bytes),
        z.layer.streamingBody(),
        z.layer.cache(.no_cache),
        z.layer.rate(.strict),
    }),
    h.get("/stream/chunks", examples.streamChunks)
        .withLayer(z.layer.cache(.no_cache)),
    h.get("/stream/demo", examples.streamDemo)
        .withLayer(z.layer.cache(.no_cache)),
});

pub const registration = registry.register(.{
    .routes = &routes,
    .auth_credentials = z.http_config.AuthCredentials{},
});

pub fn withAuth(credentials: z.http_config.AuthCredentials) @TypeOf(registration) {
    return registry.register(.{
        .routes = &routes,
        .auth_credentials = credentials,
    });
}

/// Concrete application factory injected into the core server by main.zig.
pub fn buildApplication(_: std.mem.Allocator, startup: z.ApplicationStartupConfig) anyerror!z.ApplicationBundle {
    z.xss.init(.{
        .mode = startup.xss_mode,
        .scan_query = startup.xss_scan_query,
        .scan_body = startup.xss_scan_body,
    });
    return .{ .application = z.buildApplication(withAuth(startup.auth)) };
}
