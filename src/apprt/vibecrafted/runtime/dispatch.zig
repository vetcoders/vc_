const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;
const skills_runtime = @import("skills.zig");
const session = @import("session.zig");

pub const RuntimeMode = enum {
    headless,
    terminal,
    visible,

    pub fn label(self: RuntimeMode) []const u8 {
        return switch (self) {
            .headless => "headless",
            .terminal => "terminal",
            .visible => "visible",
        };
    }
};

pub const Agent = enum {
    claude,
    codex,
    gemini,

    pub fn label(self: Agent) []const u8 {
        return @tagName(self);
    }
};

pub const Request = struct {
    agent: Agent,
    skill_name: []const u8,
    root: []const u8,
    runtime: RuntimeMode = .headless,
    prompt_text: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    skills_dir_override: ?[]const u8 = null,
    vibecrafted_home_override: ?[]const u8 = null,
    project_slug_override: ?[]const u8 = null,
    agent_binary_override: ?[]const u8 = null,
    now_seconds: ?i64 = null,
};

pub const Result = struct {
    run_id: []const u8,
    meta_path: []const u8,
    report_path: []const u8,
    transcript_path: []const u8,
    prompt_path: []const u8,
    launcher_pid: ?std.posix.pid_t,
    exit_code: i32,
    reaped_runs: usize,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.run_id);
        alloc.free(self.meta_path);
        alloc.free(self.report_path);
        alloc.free(self.transcript_path);
        alloc.free(self.prompt_path);
        self.* = undefined;
    }
};

pub const Error = error{
    PromptConflict,
    TerminalRuntimeNotImplemented,
    UnsupportedAgent,
};

pub fn dispatchSkill(alloc: Allocator, req: Request) !Result {
    if (req.runtime != .headless) return error.TerminalRuntimeNotImplemented;
    if (req.skill_name.len == 0) return error.FileNotFound;
    if (req.prompt_text != null and req.prompt_file != null) return error.PromptConflict;

    const now_seconds = req.now_seconds orelse std.time.timestamp();

    var layout = try session.resolveLayout(alloc, .{
        .root = req.root,
        .now_seconds = now_seconds,
        .vibecrafted_home_override = req.vibecrafted_home_override,
        .project_slug_override = req.project_slug_override,
    });
    defer layout.deinit();

    const sweep = try session.sweepDeadRuns(alloc, &layout);

    var resolved = try resolveSkill(alloc, req);
    defer resolved.deinit(alloc);

    const run_id = try session.generateRunId(alloc, resolved.skill_code, now_seconds);
    defer alloc.free(run_id);

    var meta = try session.createRunMeta(alloc, .{
        .layout = &layout,
        .run_id = run_id,
        .agent = req.agent.label(),
        .skill_name = resolved.surface_name,
        .skill_code = resolved.skill_code,
        .mode = req.runtime.label(),
        .root = layout.root,
        .skill_path = resolved.document.path,
    });
    defer meta.deinit();

    const prompt = try composeSkillPrompt(alloc, req, resolved.prompt_command);
    defer alloc.free(prompt);
    try writeText(meta.prompt_path, prompt);

    var argv_buf: [4][]const u8 = undefined;
    const argv = buildAgentArgv(&argv_buf, req.agent, req.agent_binary_override, prompt);

    var child = std.process.Child.init(argv, alloc);
    child.cwd = layout.root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const launcher_pid = childPid(&child);
    if (launcher_pid) |pid| try meta.markRunning(pid, now_seconds);

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    defer stdout.deinit(alloc);
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    defer stderr.deinit(alloc);

    try child.collectOutput(alloc, &stdout, &stderr, 2 * 1024 * 1024);
    const term = try child.wait();
    const exit_code = exitCode(term);

    const transcript = try joinTranscript(alloc, stdout.items, stderr.items);
    defer alloc.free(transcript);
    try writeText(meta.transcript_path, transcript);
    try writeText(meta.report_path, if (stdout.items.len > 0) stdout.items else transcript);

    try meta.finish(exit_code, std.time.timestamp());

    return .{
        .run_id = try alloc.dupe(u8, meta.run_id),
        .meta_path = try alloc.dupe(u8, meta.meta_path),
        .report_path = try alloc.dupe(u8, meta.report_path),
        .transcript_path = try alloc.dupe(u8, meta.transcript_path),
        .prompt_path = try alloc.dupe(u8, meta.prompt_path),
        .launcher_pid = launcher_pid,
        .exit_code = exit_code,
        .reaped_runs = sweep.reaped,
    };
}

pub fn dispatchInit(alloc: Allocator, req: Request) !Result {
    return dispatchSkill(alloc, req);
}

const ResolvedSkill = struct {
    surface_name: []const u8,
    skill_code: []const u8,
    prompt_command: []const u8,
    document: skills_runtime.SkillDocument,

    fn deinit(self: *ResolvedSkill, alloc: Allocator) void {
        alloc.free(self.surface_name);
        alloc.free(self.skill_code);
        alloc.free(self.prompt_command);
        self.document.deinit(alloc);
        self.* = undefined;
    }
};

fn resolveSkill(alloc: Allocator, req: Request) !ResolvedSkill {
    const requested = std.mem.trim(u8, req.skill_name, " \t\r\n");
    if (requested.len == 0) return error.FileNotFound;

    const base_name = std.fs.path.basename(requested);
    const surface_name = if (std.mem.startsWith(u8, base_name, "vc-"))
        try alloc.dupe(u8, base_name)
    else
        try std.fmt.allocPrint(alloc, "vc-{s}", .{base_name});
    errdefer alloc.free(surface_name);

    const skill_code = if (std.mem.startsWith(u8, surface_name, "vc-"))
        try alloc.dupe(u8, surface_name["vc-".len..])
    else
        try alloc.dupe(u8, surface_name);
    errdefer alloc.free(skill_code);

    const prompt_command = try std.fmt.allocPrint(alloc, "/{s}", .{surface_name});
    errdefer alloc.free(prompt_command);

    const queries = [_][]const u8{
        requested,
        surface_name,
        skill_code,
    };

    var last_err: anyerror = error.FileNotFound;
    for (queries) |query| {
        const document = skills_runtime.loadByName(alloc, .{
            .skills_dir_override = req.skills_dir_override,
        }, query) catch |err| {
            last_err = err;
            continue;
        };

        return .{
            .surface_name = surface_name,
            .skill_code = skill_code,
            .prompt_command = prompt_command,
            .document = document,
        };
    }

    return last_err;
}

fn composeSkillPrompt(alloc: Allocator, req: Request, prompt_command: []const u8) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll(prompt_command);

    const extra = try inputContext(alloc, req.prompt_text, req.prompt_file);
    defer if (extra) |value| alloc.free(value);

    if (extra) |value| {
        if (value.len > 0) {
            try out.writer.writeAll("\n\n");
            try out.writer.writeAll(value);
        }
    }

    return out.toOwnedSlice();
}

fn inputContext(
    alloc: Allocator,
    prompt_text: ?[]const u8,
    prompt_file: ?[]const u8,
) !?[]const u8 {
    if (prompt_text) |value| return @as(?[]const u8, try alloc.dupe(u8, value));
    if (prompt_file) |path| return @as(?[]const u8, try std.fs.cwd().readFileAlloc(alloc, path, 512 * 1024));
    return null;
}

fn buildInitArgv(
    argv_buf: *[4][]const u8,
    agent: Agent,
    binary_override: ?[]const u8,
    prompt: []const u8,
) []const []const u8 {
    const binary = binary_override orelse agent.label();
    argv_buf[0] = binary;

    switch (agent) {
        .claude => {
            argv_buf[1] = "--verbose";
            argv_buf[2] = "--dangerously-skip-permissions";
            argv_buf[3] = prompt;
            return argv_buf[0..4];
        },
        .codex => {
            argv_buf[1] = "--dangerously-bypass-approvals-and-sandbox";
            argv_buf[2] = prompt;
            return argv_buf[0..3];
        },
        .gemini => {
            argv_buf[1] = "-y";
            argv_buf[2] = "-i";
            argv_buf[3] = prompt;
            return argv_buf[0..4];
        },
    }
}

fn buildAgentArgv(
    argv_buf: *[4][]const u8,
    agent: Agent,
    binary_override: ?[]const u8,
    prompt: []const u8,
) []const []const u8 {
    return buildInitArgv(argv_buf, agent, binary_override, prompt);
}

fn childPid(child: *const std.process.Child) ?std.posix.pid_t {
    const value = child.id;
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value,
        else => value,
    };
}

fn exitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => 1,
    };
}

fn joinTranscript(alloc: Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    if (stderr.len == 0) return alloc.dupe(u8, stdout);
    if (stdout.len == 0) return alloc.dupe(u8, stderr);
    return std.fmt.allocPrint(alloc, "{s}\n\n[stderr]\n{s}", .{ stdout, stderr });
}

fn writeText(path: []const u8, data: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return error.BadPathName;
    const base_name = std.fs.path.basename(path);

    var dir = try std.fs.openDirAbsolute(dir_name, .{});
    defer dir.close();

    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try dir.atomicFile(base_name, .{
        .mode = if (comptime builtin.os.tag == .windows) 0 else 0o644,
        .write_buffer = &write_buffer,
    });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(data);
    try atomic_file.finish();
}

test "dispatchSkill writes prompt/report/meta and reuses sweep" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/vc-workflow");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/vc-workflow/SKILL.md",
        .data =
        \\---
        \\name: vc-workflow
        \\description: Examine, research, implement
        \\---
        \\# vc-workflow
        ,
    });

    try tmp.dir.makePath("bin");
    try tmp.dir.writeFile(.{
        .sub_path = "bin/fake-claude.sh",
        .data =
        \\#!/bin/sh
        \\printf 'vc-init ok\n'
        \\printf 'session: fake-session-1234\n'
        ,
    });
    if (comptime builtin.os.tag != .windows) {
        const file = try tmp.dir.openFile("bin/fake-claude.sh", .{});
        defer file.close();
        try file.chmod(0o755);
    }

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const home_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home_path);
    const skills_root = try tmp.dir.realpathAlloc(testing.allocator, "skills");
    defer testing.allocator.free(skills_root);
    const agent_bin = try tmp.dir.realpathAlloc(testing.allocator, "bin/fake-claude.sh");
    defer testing.allocator.free(agent_bin);

    var result = try dispatchSkill(testing.allocator, .{
        .agent = .claude,
        .skill_name = "workflow",
        .root = root_path,
        .runtime = .headless,
        .prompt_text = "Scan the repository and bootstrap context.",
        .skills_dir_override = skills_root,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
        .agent_binary_override = agent_bin,
        .now_seconds = 1710883557,
    });
    defer result.deinit(testing.allocator);

    const prompt = try std.fs.cwd().readFileAlloc(testing.allocator, result.prompt_path, 8 * 1024);
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.startsWith(u8, prompt, "/vc-workflow"));

    var meta = try session.loadMetaAbsolute(testing.allocator, result.meta_path);
    defer meta.deinit();
    try testing.expectEqual(session.Status.completed, meta.status);
    try testing.expectEqual(@as(i32, 0), meta.exit_code.?);
    try testing.expectEqualStrings("vc-workflow", meta.skill_name);
    try testing.expectEqualStrings("workflow", meta.skill_code);

    const report = try std.fs.cwd().readFileAlloc(testing.allocator, result.report_path, 8 * 1024);
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "vc-init ok") != null);
}

test "resolveSkill normalizes vc-prefixed aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/foundations/vc-aicx");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/foundations/vc-aicx/SKILL.md",
        .data =
        \\---
        \\name: aicx
        \\description: Memory foundation
        \\---
        \\# vc-aicx
        ,
    });

    const skills_root = try tmp.dir.realpathAlloc(std.testing.allocator, "skills");
    defer std.testing.allocator.free(skills_root);

    var resolved = try resolveSkill(std.testing.allocator, .{
        .agent = .codex,
        .skill_name = "foundations/vc-aicx",
        .root = "/tmp",
        .skills_dir_override = skills_root,
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("vc-aicx", resolved.surface_name);
    try std.testing.expectEqualStrings("aicx", resolved.skill_code);
    try std.testing.expectEqualStrings("/vc-aicx", resolved.prompt_command);
}
