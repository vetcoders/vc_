const std = @import("std");

pub const Runtime = struct {
    pub const version = "0.0.1";
    pub const name = "Vibecrafted runtime";

    pub fn banner() []const u8 {
        return name ++ " v" ++ version;
    }

    pub fn writeBanner(writer: anytype) !void {
        try writer.print("{s}\n", .{banner()});
    }

    pub fn printBanner() !void {
        var buffer: [256]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&buffer);
        const stdout = &stdout_writer.interface;
        try writeBanner(stdout);
        try stdout.flush();
    }
};

test {
    try std.testing.expectEqualStrings("Vibecrafted runtime v0.0.1", Runtime.banner());
}
