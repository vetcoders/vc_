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
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    }

    var existing = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |*file| {
        defer file.close(std.Options.debug_io);

        const stat = try file.stat(std.Options.debug_io);
        if (stat.size == 0) {
            try writeAll(file.*, default_config_contents);
        }

        return path;
    }

    var file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .exclusive = true });
    defer file.close(std.Options.debug_io);
    try writeAll(file, default_config_contents);

    return path;
}

fn writeAll(file: std.Io.File, data: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(std.Options.debug_io, &buffer);
    try writer.interface.writeAll(data);
    try writer.flush();
}

test "default config template is not empty" {
    try std.testing.expect(default_config_contents.len > 0);
}
