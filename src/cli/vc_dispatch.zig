const std = @import("std");

const Allocator = std.mem.Allocator;
const dispatch_runtime = @import("../apprt/vibecrafted/runtime/dispatch.zig");

pub fn runSkill(
    alloc: Allocator,
    io: std.Io,
    writer: anytype,
    skill_name: []const u8,
    argv: []const []const u8,
) !u8 {
    if (argv.len == 0 or isHelp(argv[0])) {
        try printSkillHelp(writer, skill_name);
        return 0;
    }

    const agent = parseAgent(argv[0]) orelse {
        try writer.print("error: {s} expects <claude|codex|gemini> as the first argument\n\n", .{skill_name});
        try printSkillHelp(writer, skill_name);
        return 1;
    };

    var prompt_text: ?[]const u8 = null;
    var prompt_file: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var runtime: dispatch_runtime.RuntimeMode = .headless;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= argv.len) {
                try writer.writeAll("error: missing value for --prompt\n");
                return 1;
            }
            prompt_text = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= argv.len) {
                try writer.writeAll("error: missing value for --file\n");
                return 1;
            }
            prompt_file = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len) {
                try writer.writeAll("error: missing value for --root\n");
                return 1;
            }
            root = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime")) {
            i += 1;
            if (i >= argv.len) {
                try writer.writeAll("error: missing value for --runtime\n");
                return 1;
            }
            runtime = parseRuntime(argv[i]) orelse {
                try writer.print("error: unsupported runtime '{s}'\n", .{argv[i]});
                return 1;
            };
            continue;
        }

        try writer.print("error: unknown {s} argument '{s}'\n", .{ skill_name, arg });
        return 1;
    }

    const resolved_root = if (root) |value|
        try realpathAlloc(alloc, value)
    else
        try realpathAlloc(alloc, ".");
    defer alloc.free(resolved_root);

    var result = dispatch_runtime.dispatchSkill(alloc, .{
        .agent = agent,
        .skill_name = skill_name,
        .root = resolved_root,
        .runtime = runtime,
        .prompt_text = prompt_text,
        .prompt_file = prompt_file,
        .io = io,
    }) catch |err| {
        switch (err) {
            error.PromptConflict => try writer.writeAll("error: use at most one input source: --prompt or --file\n"),
            error.TerminalRuntimeNotImplemented => try writer.print("error: vc-board {s} currently supports only --runtime headless; panel runtime lands with T2/T3 integration\n", .{skill_name}),
            error.FileNotFound => try writer.print("error: skill surface for '{s}' was not found in the active skills directory\n", .{skill_name}),
            else => try writer.print("error: {s} dispatch failed: {}\n", .{ skill_name, err }),
        }
        return 1;
    };
    defer result.deinit(alloc);

    try writer.print("run_id: {s}\n", .{result.run_id});
    try writer.print("status: {s}\n", .{if (result.exit_code == 0) "completed" else "failed"});
    try writer.print("reaped: {d}\n", .{result.reaped_runs});
    try writer.print("meta: {s}\n", .{result.meta_path});
    try writer.print("report: {s}\n", .{result.report_path});
    try writer.print("transcript: {s}\n", .{result.transcript_path});
    try writer.print("prompt: {s}\n", .{result.prompt_path});
    if (result.launcher_pid) |pid| try writer.print("launcher_pid: {d}\n", .{pid});

    return if (result.exit_code == 0) 0 else 1;
}

pub fn runInit(
    alloc: Allocator,
    io: std.Io,
    writer: anytype,
    argv: []const []const u8,
) !u8 {
    return runSkill(alloc, io, writer, "init", argv);
}

fn realpathAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    const zpath = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, alloc);
    defer alloc.free(zpath);
    return alloc.dupe(u8, zpath);
}

fn parseAgent(value: []const u8) ?dispatch_runtime.Agent {
    if (std.mem.eql(u8, value, "claude")) return .claude;
    if (std.mem.eql(u8, value, "codex")) return .codex;
    if (std.mem.eql(u8, value, "gemini")) return .gemini;
    return null;
}

fn parseRuntime(value: []const u8) ?dispatch_runtime.RuntimeMode {
    if (std.mem.eql(u8, value, "headless")) return .headless;
    if (std.mem.eql(u8, value, "terminal")) return .terminal;
    if (std.mem.eql(u8, value, "visible")) return .visible;
    return null;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "help");
}

fn printSkillHelp(writer: anytype, skill_name: []const u8) !void {
    try writer.print(
        \\Usage: vc-board {s} <claude|codex|gemini> [--prompt <text>] [--file <path>] [--root <dir>] [--runtime headless]
        \\
        \\Headless runtime dispatch path for the `{s}` skill surface.
        \\This command creates a run_id, prompt/report/meta artifacts, tracks launcher_pid,
        \\and performs spawn-time GC for stale live runs before launching.
        \\
    , .{ skill_name, skill_name });
}
