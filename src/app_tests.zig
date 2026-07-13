const examples = @import("app/examples.zig");
const register = @import("app/register.zig");
const site = @import("app/site.zig");
const system = @import("app/system.zig");
const ziserver = @import("ziserver.zig");

test {
    _ = examples;
    _ = register;
    _ = site;
    _ = system;
    _ = ziserver.http2;
}
