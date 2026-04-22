const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try CoreApp.create(gpa.allocator());
    defer app.destroy();

    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    try app_runtime.run();
}

test {
    _ = apprt.vibecrafted;
    _ = @import("../test/panels.zig");
}
