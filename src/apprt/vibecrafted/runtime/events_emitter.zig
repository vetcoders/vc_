const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SpawnUpdate = struct {
    run_id: []const u8,
    agent: []const u8,
    skill: []const u8,
    mode: []const u8,
    state: []const u8,
    root: []const u8,
    session_id: ?[]const u8 = null,
    exit_code: ?i32 = null,
    launcher_pid: ?std.posix.pid_t = null,
    transcript: ?[]const u8 = null,
    report: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    ts_seconds: ?i64 = null,
};

pub fn emitSpawnUpdate(alloc: Allocator, vibecrafted_home: []const u8, update: SpawnUpdate) !void {
    const line = try formatSpawnUpdateLine(alloc, update);
    defer alloc.free(line);

    const control_plane_dir = try std.fs.path.join(alloc, &.{ vibecrafted_home, "control_plane" });
    defer alloc.free(control_plane_dir);
    try ensureDirAbsolute(control_plane_dir);

    const events_path = try std.fs.path.join(alloc, &.{ control_plane_dir, "events.jsonl" });
    defer alloc.free(events_path);

    try appendLine(events_path, line);
}

pub fn formatSpawnUpdateLine(alloc: Allocator, update: SpawnUpdate) ![]const u8 {
    const now_seconds = update.ts_seconds orelse std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds();
    const ts = try formatTimestamp(alloc, now_seconds);
    defer alloc.free(ts);

    const EventPayload = struct {
        agent: []const u8,
        skill: []const u8,
        mode: []const u8,
        state: []const u8,
        root: []const u8,
        session_id: ?[]const u8,
        exit_code: ?i32,
        launcher_pid: ?std.posix.pid_t,
        transcript: ?[]const u8,
        report: ?[]const u8,
        meta: ?[]const u8,
    };

    const Event = struct {
        ts: []const u8,
        run_id: []const u8,
        kind: []const u8,
        message: []const u8,
        payload: EventPayload,
    };

    const event: Event = .{
        .ts = ts,
        .run_id = update.run_id,
        .kind = "spawn-update",
        .message = "apprt spawn update",
        .payload = .{
            .agent = update.agent,
            .skill = update.skill,
            .mode = update.mode,
            .state = update.state,
            .root = update.root,
            .session_id = update.session_id,
            .exit_code = update.exit_code,
            .launcher_pid = update.launcher_pid,
            .transcript = update.transcript,
            .report = update.report,
            .meta = update.meta,
        },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try std.json.Stringify.value(event, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn appendLine(path: []const u8, line: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);

    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(std.Options.debug_io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(std.Options.debug_io, &write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

fn ensureDirAbsolute(path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn formatTimestamp(alloc: Allocator, now_seconds: i64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

test "formatSpawnUpdateLine matches vc-console spawn-update contract" {
    const line = try formatSpawnUpdateLine(std.testing.allocator, .{
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
    try std.testing.expectEqualStrings("launching", payload.get("state").?.string);
    try std.testing.expectEqualStrings("sess-1", payload.get("session_id").?.string);
    try std.testing.expectEqual(@as(i64, 42), payload.get("launcher_pid").?.integer);
}
