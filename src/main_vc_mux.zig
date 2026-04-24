const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("vc-mux starting...\n", .{});

    const Config = @import("mux/Config.zig").Config;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    const config = Config.parse(allocator, &args) catch |err| {
        std.debug.print("Failed to parse arguments: {s}\n", .{@errorName(err)});
        std.debug.print("Usage: vc-mux --socket <path> [--max-active-clients <num>] --cmd <cmd> [args...]\n", .{});
        std.process.exit(1);
    };

    const Runtime = @import("mux/Runtime.zig").Runtime;
    var runtime = try Runtime.init(allocator, init.io, config);
    try runtime.run();
}
