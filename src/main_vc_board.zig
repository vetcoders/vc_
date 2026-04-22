const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const doctor = @import("cli/doctor.zig");
const vc_install = @import("vc_board/install.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    if (argv.len > 1) {
        const command = argv[1];
        if (std.mem.eql(u8, command, "doctor")) {
            std.process.exit(try doctor.run(alloc, .doctor, argv[2..]));
        }
        if (std.mem.eql(u8, command, "status")) {
            std.process.exit(try doctor.run(alloc, .status, argv[2..]));
        }
        if (std.mem.eql(u8, command, "--help") or
            std.mem.eql(u8, command, "-h") or
            std.mem.eql(u8, command, "help"))
        {
            try printHelp();
            return;
        }
    }

    const ensured_config_path = try vc_install.ensureDefaultConfig(alloc);
    defer alloc.free(ensured_config_path);

    const app = try CoreApp.create(alloc);
    defer app.destroy();

    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    try app_runtime.run();
}

test {
    _ = apprt.vibecrafted;
    _ = doctor;
}

fn printHelp() !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: vc-board [doctor|status] [--json|--md]
        \\
        \\Without a subcommand, vc-board launches the runtime.
        \\`doctor` validates the install surface.
        \\`status` prints only warnings and failures.
        \\
    );
    try stdout.flush();
}
