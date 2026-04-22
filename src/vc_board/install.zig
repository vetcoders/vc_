const std = @import("std");
const Allocator = std.mem.Allocator;
const file_load = @import("../config/file_load.zig");

pub const default_config_contents =
    \\# vc-board initial config
    \\# This file is created lazily on first launch or `vc-board doctor`.
    \\
;

pub fn ensureDefaultConfig(alloc: Allocator) ![]const u8 {
    const path = try file_load.preferredDefaultFilePath(alloc);
    errdefer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var existing = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |*file| {
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) {
            try file.writeAll(default_config_contents);
        }

        return path;
    }

    var file = try std.fs.createFileAbsolute(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(default_config_contents);

    return path;
}

test "default config template is not empty" {
    try std.testing.expect(default_config_contents.len > 0);
}
