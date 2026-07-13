const std = @import("std");

const max_file_bytes = 16 * 1024 * 1024;

const CopyStats = struct {
    scanned: usize = 0,
    installed: usize = 0,
    unchanged: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    const source_root = args.next() orelse {
        std.debug.print("usage: install_static SOURCE_DIR DEST_DIR\n", .{});
        return 2;
    };
    const dest_root = args.next() orelse {
        std.debug.print("usage: install_static SOURCE_DIR DEST_DIR\n", .{});
        return 2;
    };
    if (args.next() != null) {
        std.debug.print("usage: install_static SOURCE_DIR DEST_DIR\n", .{});
        return 2;
    }

    const stats = try installChanged(init.io, init.gpa, source_root, dest_root);
    std.debug.print(
        "static assets scanned={d} installed={d} unchanged={d}\n",
        .{ stats.scanned, stats.installed, stats.unchanged },
    );
    return 0;
}

fn installChanged(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    dest_root: []const u8,
) !CopyStats {
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true });
    defer source_dir.close(io);

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    var stats = CopyStats{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        stats.scanned += 1;

        const source_body = try source_dir.readFileAlloc(
            io,
            entry.path,
            allocator,
            .limited(max_file_bytes),
        );
        defer allocator.free(source_body);

        const dest_path = try std.fs.path.join(allocator, &.{ dest_root, entry.path });
        defer allocator.free(dest_path);

        if (try sameFile(io, allocator, dest_path, source_body)) {
            stats.unchanged += 1;
            continue;
        }

        if (std.fs.path.dirname(dest_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = dest_path,
            .data = source_body,
        });
        stats.installed += 1;
    }

    return stats;
}

fn sameFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    source_body: []const u8,
) !bool {
    const dest_body = std.Io.Dir.cwd().readFileAlloc(
        io,
        dest_path,
        allocator,
        .limited(max_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        => return false,
        else => return err,
    };
    defer allocator.free(dest_body);

    return std.mem.eql(u8, source_body, dest_body);
}
