const builtin = @import("builtin");
const std = @import("std");

const dispatch = @import("apprt_dispatch");
const events_emitter = dispatch.testing_events_emitter;
const session = dispatch.testing_session;

fn testingRealPath(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const zpath = try dir.realPathFileAlloc(std.Options.debug_io, sub_path, alloc);
    defer alloc.free(zpath);
    return alloc.dupe(u8, zpath);
}

test "events_emitter line is vc-console spawn-update JSON" {
    const line = try events_emitter.formatSpawnUpdateLine(std.testing.allocator, .{
        .run_id = "workflow-212557-123",
        .agent = "codex",
        .skill = "vc-workflow",
        .mode = "terminal",
        .state = "launching",
        .root = "/tmp/project",
        .session_id = "sess-1",
        .launcher_pid = 42,
        .ts_seconds = 1710883557,
    });
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("spawn-update", root.get("kind").?.string);
    try std.testing.expectEqualStrings("workflow-212557-123", root.get("run_id").?.string);

    const payload = root.get("payload").?.object;
    try std.testing.expectEqualStrings("codex", payload.get("agent").?.string);
    try std.testing.expectEqualStrings("vc-workflow", payload.get("skill").?.string);
    try std.testing.expectEqualStrings("terminal", payload.get("mode").?.string);
    try std.testing.expectEqualStrings("launching", payload.get("state").?.string);
    try std.testing.expectEqualStrings("sess-1", payload.get("session_id").?.string);
}

test "DiskPayload round-trips session_id set and null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try testingRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root_path);
    const home_path = try testingRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home_path);

    var layout = try session.resolveLayout(std.testing.allocator, .{
        .root = root_path,
        .now_seconds = 1710883557,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
    });
    defer layout.deinit();

    var null_meta = try session.createRunMeta(std.testing.allocator, .{
        .layout = &layout,
        .run_id = "workflow-null-1",
        .agent = "codex",
        .skill_name = "vc-workflow",
        .skill_code = "workflow",
        .mode = "terminal",
        .root = root_path,
    });
    defer null_meta.deinit();

    var null_loaded = try session.loadMetaAbsolute(std.testing.allocator, null_meta.meta_path);
    defer null_loaded.deinit();
    try std.testing.expect(null_loaded.session_id == null);

    var set_meta = try session.createRunMeta(std.testing.allocator, .{
        .layout = &layout,
        .run_id = "workflow-set-1",
        .agent = "codex",
        .skill_name = "vc-workflow",
        .skill_code = "workflow",
        .mode = "terminal",
        .root = root_path,
        .session_id = "launcher-session-1",
    });
    defer set_meta.deinit();

    var set_loaded = try session.loadMetaAbsolute(std.testing.allocator, set_meta.meta_path);
    defer set_loaded.deinit();
    try std.testing.expectEqualStrings("launcher-session-1", set_loaded.session_id.?);
}

test "terminal runtime dispatch emits lifecycle events and stores session_id" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Options.debug_io, "skills/vc-workflow");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "skills/vc-workflow/SKILL.md",
        .data =
        \\---
        \\name: vc-workflow
        \\description: Examine, research, implement
        \\---
        \\# vc-workflow
        ,
    });

    try tmp.dir.createDirPath(std.Options.debug_io, "bin");
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "bin/fake-codex.sh",
        .data =
        \\#!/bin/sh
        \\printf 'vc workflow ok\n'
        \\printf 'session: fake-session-5678\n'
        ,
    });
    const file = try tmp.dir.openFile(std.Options.debug_io, "bin/fake-codex.sh", .{});
    defer file.close(std.Options.debug_io);
    try file.setPermissions(std.Options.debug_io, @enumFromInt(0o755));

    const root_path = try testingRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root_path);
    const home_path = try testingRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home_path);
    const skills_root = try testingRealPath(std.testing.allocator, tmp.dir, "skills");
    defer std.testing.allocator.free(skills_root);
    const agent_bin = try testingRealPath(std.testing.allocator, tmp.dir, "bin/fake-codex.sh");
    defer std.testing.allocator.free(agent_bin);

    var result = try dispatch.dispatchSkill(std.testing.allocator, .{
        .agent = .codex,
        .skill_name = "workflow",
        .root = root_path,
        .runtime = .terminal,
        .prompt_text = "Bootstrap project context.",
        .skills_dir_override = skills_root,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
        .agent_binary_override = agent_bin,
        .now_seconds = 1710883557,
    });
    defer result.deinit(std.testing.allocator);

    var meta = try session.loadMetaAbsolute(std.testing.allocator, result.meta_path);
    defer meta.deinit();
    try std.testing.expectEqual(session.Status.completed, meta.status);
    try std.testing.expectEqualStrings("fake-session-5678", meta.session_id.?);

    const events_path = try std.fs.path.join(std.testing.allocator, &.{ home_path, "control_plane", "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        events_path,
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(events);

    var launching_seen = false;
    var completed_seen = false;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        try std.testing.expectEqualStrings("spawn-update", root.get("kind").?.string);
        const payload = root.get("payload").?.object;
        const state = payload.get("state").?.string;
        launching_seen = launching_seen or std.mem.eql(u8, state, "launching");
        completed_seen = completed_seen or std.mem.eql(u8, state, "completed");
    }

    try std.testing.expect(count >= 2);
    try std.testing.expect(launching_seen);
    try std.testing.expect(completed_seen);
}
