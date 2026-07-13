const std = @import("std");

const import_marker = "@import(\"";

test "source layers retain one-way imports" {
    try assertNoDirectImports("src/core", &.{ "compose/", "app/" });
    try assertNoDirectImports("src/compose", &.{"app/"});
    try assertNoDirectImports("src/app", &.{ "core/", "compose/" });
}

fn assertNoDirectImports(directory_path: []const u8, forbidden_segments: []const []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, directory_path, .{ .iterate = true });
    defer directory.close(std.testing.io);

    var walker = try directory.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const source = try directory.readFileAlloc(
            std.testing.io,
            entry.path,
            std.testing.allocator,
            .limited(2 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);

        var cursor: usize = 0;
        while (std.mem.indexOf(u8, source[cursor..], import_marker)) |relative_start| {
            const import_start = cursor + relative_start + import_marker.len;
            const relative_end = std.mem.indexOfScalar(u8, source[import_start..], '"') orelse break;
            const import_path = source[import_start .. import_start + relative_end];
            cursor = import_start + relative_end + 1;

            for (forbidden_segments) |segment| {
                if (std.mem.indexOf(u8, import_path, segment) == null) continue;
                std.debug.print(
                    "layering violation: {s}/{s} directly imports {s}\n",
                    .{ directory_path, entry.path, import_path },
                );
                return error.LayeringViolation;
            }
        }
    }
}
