const dsl = @import("compose/dsl.zig");
const database = @import("compose/database.zig");
const content = @import("compose/content.zig");
const api = @import("compose/api.zig");
const pgsql = @import("compose/database/pgsql.zig");
const json_body = @import("compose/json_body.zig");
const json_response = @import("compose/json_response.zig");
const page_cache = @import("core/page_cache.zig");
const routes = @import("compose/routes.zig");
const upload = @import("compose/upload.zig");
const upload_disk = @import("compose/upload_disk.zig");
const shutdown = @import("core/shutdown.zig");
const ziserver = @import("ziserver.zig");

test {
    _ = dsl;
    _ = database;
    _ = content;
    _ = api;
    _ = pgsql;
    _ = json_body;
    _ = json_response;
    _ = page_cache;
    _ = routes;
    _ = upload;
    _ = upload_disk;
    _ = shutdown;
    _ = ziserver.http2;
    _ = ziserver;
    _ = ziserver.protocol;
    _ = ziserver.tls;
    _ = ziserver.transport;
}
