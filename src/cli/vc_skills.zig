const std = @import("std");
const Allocator = std.mem.Allocator;
const skills_runtime = @import("../apprt/vibecrafted/runtime/skills.zig");

pub const Options = struct {
    skills_dir_override: ?[]const u8 = null,
};

pub fn run(
    alloc: Allocator,
    writer: anytype,
    argv: []const []const u8,
    opts: Options,
) !u8 {
    if (argv.len == 0 or isHelp(argv[0])) {
        try printHelp(writer);
        return 0;
    }

    const subcommand = argv[0];
    if (std.mem.eql(u8, subcommand, "list")) {
        return runList(alloc, writer, opts);
    }
    if (std.mem.eql(u8, subcommand, "show")) {
        if (argv.len < 2) {
            try writer.writeAll("error: missing skill name\n\n");
            try printHelp(writer);
            return 1;
        }
        return runShow(alloc, writer, argv[1], opts);
    }

    try writer.print("error: unknown skills subcommand '{s}'\n\n", .{subcommand});
    try printHelp(writer);
    return 1;
}

fn runList(alloc: Allocator, writer: anytype, opts: Options) !u8 {
    var catalog = skills_runtime.loadCatalog(alloc, .{
        .skills_dir_override = opts.skills_dir_override,
    }) catch |err| {
        try renderLoadError(writer, err);
        return 1;
    };
    defer catalog.deinit();

    try writer.print("skills root: {s}\n", .{catalog.root_dir});
    for (catalog.skills.items) |skill| {
        const version = skill.version orelse "unknown";
        try writer.print("{s}\t{s}\t{s}\n", .{
            skill.name,
            version,
            skill.description,
        });
    }
    return 0;
}

fn runShow(alloc: Allocator, writer: anytype, name: []const u8, opts: Options) !u8 {
    var document = skills_runtime.loadByName(alloc, .{
        .skills_dir_override = opts.skills_dir_override,
    }, name) catch |err| {
        if (err == error.FileNotFound) {
            try writer.print("error: skill '{s}' not found\n", .{name});
            return 1;
        }
        try renderLoadError(writer, err);
        return 1;
    };
    defer document.deinit(alloc);

    try writer.print("name: {s}\n", .{document.name});
    try writer.print("version: {s}\n", .{document.version orelse "unknown"});
    try writer.print("path: {s}\n", .{document.path});
    try writer.print("description: {s}\n\n", .{document.description});
    try writer.writeAll(document.body);
    if (!std.mem.endsWith(u8, document.body, "\n")) try writer.writeByte('\n');
    return 0;
}

fn renderLoadError(writer: anytype, err: anyerror) !void {
    switch (err) {
        error.SkillsRootNotFound => try writer.writeAll("error: unable to locate a skills directory\n"),
        else => try writer.print("error: failed to load skills: {}\n", .{err}),
    }
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "help");
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: vc_ skills <list|show <name>>
        \\
        \\`list` scans the active vibecrafted skills directory and prints metadata.
        \\`show` prints the parsed metadata plus the markdown body for one skill.
        \\
    );
}

test "skills cli list renders catalog lines" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/vc-alpha");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/vc-alpha/SKILL.md",
        .data =
        \\---
        \\name: vc-alpha
        \\version: 0.1.0
        \\description: Alpha skill
        \\---
        \\# Alpha
        ,
    });

    const skills_root = try tmp.dir.realpathAlloc(testing.allocator, "skills");
    defer testing.allocator.free(skills_root);

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(testing.allocator, stream.writer(), &.{"list"}, .{
        .skills_dir_override = skills_root,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stream.getWritten(), "vc-alpha\t0.1.0\tAlpha skill") != null);
}

test "skills cli show renders body" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/vc-beta");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/vc-beta/SKILL.md",
        .data =
        \\---
        \\name: vc-beta
        \\description: Beta skill
        \\---
        \\# Beta
        \\Body text.
        ,
    });

    const skills_root = try tmp.dir.realpathAlloc(testing.allocator, "skills");
    defer testing.allocator.free(skills_root);

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(testing.allocator, stream.writer(), &.{ "show", "vc-beta" }, .{
        .skills_dir_override = skills_root,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stream.getWritten(), "name: vc-beta") != null);
    try testing.expect(std.mem.indexOf(u8, stream.getWritten(), "# Beta\nBody text.\n") != null);
}

test "skills cli show resolves nested skill by folder alias" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/foundations/vc-aicx");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/foundations/vc-aicx/SKILL.md",
        .data =
        \\---
        \\name: aicx
        \\description: Memory foundation
        \\---
        \\# AICX
        \\Intent retrieval.
        ,
    });

    const skills_root = try tmp.dir.realpathAlloc(testing.allocator, "skills");
    defer testing.allocator.free(skills_root);

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(testing.allocator, stream.writer(), &.{ "show", "vc-aicx" }, .{
        .skills_dir_override = skills_root,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stream.getWritten(), "name: aicx") != null);
    try testing.expect(std.mem.indexOf(u8, stream.getWritten(), "# AICX\nIntent retrieval.\n") != null);
}
