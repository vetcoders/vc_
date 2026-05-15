const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const doctor = @import("cli/doctor.zig");
const vc_dispatch = @import("cli/vc_dispatch.zig");
const vc_skills = @import("cli/vc_skills.zig");
const vc_install = @import("vc_board/install.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(alloc);

    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_iter.deinit();
    while (arg_iter.next()) |arg| try argv_list.append(alloc, arg);
    const argv = argv_list.items;

    const invoked_as = std.fs.path.basename(argv[0]);
    if (aliasSkillName(invoked_as)) |skill_name| {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        defer stdout.flush() catch {};

        std.process.exit(try vc_dispatch.runSkill(alloc, stdout, skill_name, argv[1..]));
    }

    if (argv.len > 1) {
        const command = argv[1];
        if (std.mem.eql(u8, command, "doctor")) {
            std.process.exit(try doctor.run(alloc, .doctor, argv[2..]));
        }
        if (std.mem.eql(u8, command, "status")) {
            std.process.exit(try doctor.run(alloc, .status, argv[2..]));
        }
        if (std.mem.eql(u8, command, "skills")) {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            defer stdout.flush() catch {};

            std.process.exit(try vc_skills.run(alloc, stdout, argv[2..], .{}));
        }
        if (std.mem.eql(u8, command, "init")) {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            defer stdout.flush() catch {};

            std.process.exit(try vc_dispatch.runInit(alloc, stdout, argv[2..]));
        }
        if (std.mem.eql(u8, command, "--help") or
            std.mem.eql(u8, command, "-h") or
            std.mem.eql(u8, command, "help"))
        {
            try printHelp(init.io);
            return;
        }

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        defer stdout.flush() catch {};

        std.process.exit(try vc_dispatch.runSkill(alloc, stdout, command, argv[2..]));
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
    _ = vc_dispatch;
    _ = vc_skills;
}

fn printHelp(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: vc-board [doctor|status|skills|<skill>] [--json|--md]
        \\
        \\Without a subcommand, vc-board launches the runtime.
        \\`doctor` validates the install surface.
        \\`status` prints only warnings and failures.
        \\`skills` scans the runtime skills surface (`list`, `show <name>`).
        \\Any other subcommand is treated as a runtime skill (`vc-board init claude`, `vc-board workflow codex`).
        \\If the binary is invoked through an alias such as `vc-init`, that alias is dispatched as the skill name.
        \\
    );
    try stdout.flush();
}

fn aliasSkillName(invoked_as: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, invoked_as, "vc-")) return null;
    if (std.mem.eql(u8, invoked_as, "vc-board")) return null;

    const suffix = invoked_as["vc-".len..];
    if (suffix.len == 0) return null;
    return suffix;
}

test "aliasSkillName ignores vc-board and resolves vc-init" {
    try std.testing.expectEqualStrings("init", aliasSkillName("vc-init").?);
    try std.testing.expect(aliasSkillName("vc-board") == null);
    try std.testing.expect(aliasSkillName("ghostty") == null);
}
