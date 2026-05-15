const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    launching,
    running,
    completed,
    failed,
    ghost,

    pub fn isLive(self: Status) bool {
        return switch (self) {
            .launching, .running => true,
            .completed, .failed, .ghost => false,
        };
    }
};

pub const LayoutOptions = struct {
    root: []const u8,
    now_seconds: ?i64 = null,
    vibecrafted_home_override: ?[]const u8 = null,
    project_slug_override: ?[]const u8 = null,
};

pub const Layout = struct {
    allocator: Allocator,
    root: []const u8,
    project_slug: []const u8,
    vibecrafted_home: []const u8,
    project_artifacts_root: []const u8,
    day_root: []const u8,
    reports_dir: []const u8,
    tmp_dir: []const u8,
    locks_dir: []const u8,
    now_seconds: i64,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.root);
        self.allocator.free(self.project_slug);
        self.allocator.free(self.vibecrafted_home);
        self.allocator.free(self.project_artifacts_root);
        self.allocator.free(self.day_root);
        self.allocator.free(self.reports_dir);
        self.allocator.free(self.tmp_dir);
        self.allocator.free(self.locks_dir);
        self.* = undefined;
    }
};

pub const RunPaths = struct {
    allocator: Allocator,
    meta_path: []const u8,
    report_path: []const u8,
    transcript_path: []const u8,
    prompt_path: []const u8,
    lock_path: []const u8,

    pub fn deinit(self: *RunPaths) void {
        self.allocator.free(self.meta_path);
        self.allocator.free(self.report_path);
        self.allocator.free(self.transcript_path);
        self.allocator.free(self.prompt_path);
        self.allocator.free(self.lock_path);
        self.* = undefined;
    }
};

pub const CreateRunOptions = struct {
    layout: *const Layout,
    run_id: []const u8,
    agent: []const u8,
    skill_name: []const u8,
    skill_code: []const u8,
    mode: []const u8,
    root: []const u8,
    skill_path: ?[]const u8 = null,
};

pub const DiskPayload = struct {
    run_id: []const u8,
    agent: []const u8,
    skill_name: []const u8,
    skill_code: []const u8,
    mode: []const u8,
    root: []const u8,
    skill_path: ?[]const u8 = null,
    meta_path: []const u8,
    report_path: []const u8,
    transcript_path: []const u8,
    prompt_path: []const u8,
    lock_path: []const u8,
    status: Status,
    launcher_pid: ?std.posix.pid_t = null,
    ghost_reason: ?[]const u8 = null,
    exit_code: ?i32 = null,
    started_at: i64,
    updated_at: i64,
    completed_at: ?i64 = null,
};

pub const RunMeta = struct {
    allocator: Allocator,
    run_id: []const u8,
    agent: []const u8,
    skill_name: []const u8,
    skill_code: []const u8,
    mode: []const u8,
    root: []const u8,
    skill_path: ?[]const u8,
    meta_path: []const u8,
    report_path: []const u8,
    transcript_path: []const u8,
    prompt_path: []const u8,
    lock_path: []const u8,
    status: Status,
    launcher_pid: ?std.posix.pid_t = null,
    ghost_reason: ?[]const u8 = null,
    exit_code: ?i32 = null,
    started_at: i64,
    updated_at: i64,
    completed_at: ?i64 = null,

    pub fn deinit(self: *RunMeta) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.agent);
        self.allocator.free(self.skill_name);
        self.allocator.free(self.skill_code);
        self.allocator.free(self.mode);
        self.allocator.free(self.root);
        if (self.skill_path) |value| self.allocator.free(value);
        self.allocator.free(self.meta_path);
        self.allocator.free(self.report_path);
        self.allocator.free(self.transcript_path);
        self.allocator.free(self.prompt_path);
        self.allocator.free(self.lock_path);
        if (self.ghost_reason) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn save(self: *const RunMeta) !void {
        const payload: DiskPayload = .{
            .run_id = self.run_id,
            .agent = self.agent,
            .skill_name = self.skill_name,
            .skill_code = self.skill_code,
            .mode = self.mode,
            .root = self.root,
            .skill_path = self.skill_path,
            .meta_path = self.meta_path,
            .report_path = self.report_path,
            .transcript_path = self.transcript_path,
            .prompt_path = self.prompt_path,
            .lock_path = self.lock_path,
            .status = self.status,
            .launcher_pid = self.launcher_pid,
            .ghost_reason = self.ghost_reason,
            .exit_code = self.exit_code,
            .started_at = self.started_at,
            .updated_at = self.updated_at,
            .completed_at = self.completed_at,
        };

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try std.json.Stringify.value(payload, .{
            .whitespace = .indent_2,
        }, &out.writer);

        try writeFileAtomic(self.meta_path, 0o644, out.written());
    }

    pub fn markRunning(self: *RunMeta, pid: std.posix.pid_t, now_seconds: i64) !void {
        self.launcher_pid = pid;
        self.status = .running;
        self.updated_at = now_seconds;
        try self.save();
    }

    pub fn finish(self: *RunMeta, exit_code: i32, now_seconds: i64) !void {
        self.exit_code = exit_code;
        self.status = if (exit_code == 0) .completed else .failed;
        self.updated_at = now_seconds;
        self.completed_at = now_seconds;
        try self.save();
        self.releaseLock();
    }

    pub fn reapGhost(self: *RunMeta, reason: []const u8, now_seconds: i64) !void {
        if (self.ghost_reason) |value| self.allocator.free(value);
        self.ghost_reason = try self.allocator.dupe(u8, reason);
        self.status = .ghost;
        self.updated_at = now_seconds;
        self.completed_at = now_seconds;
        try self.save();
        self.releaseLock();
    }

    pub fn releaseLock(self: *const RunMeta) void {
        const dir_name = std.fs.path.dirname(self.lock_path) orelse return;
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_name, .{}) catch return;
        defer dir.close(std.Options.debug_io);
        dir.deleteFile(std.Options.debug_io, std.fs.path.basename(self.lock_path)) catch {};
    }
};

pub const SweepResult = struct {
    scanned: usize = 0,
    reaped: usize = 0,
};

pub fn resolveLayout(alloc: Allocator, opts: LayoutOptions) !Layout {
    const now_seconds = opts.now_seconds orelse std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, opts.root, alloc);
    errdefer alloc.free(root);

    const project_slug = if (opts.project_slug_override) |value|
        try alloc.dupe(u8, value)
    else
        try deriveProjectSlug(alloc, root);
    errdefer alloc.free(project_slug);

    const vibecrafted_home = if (opts.vibecrafted_home_override) |value|
        try ensureRealpathDir(alloc, value)
    else
        try defaultVibecraftedHome(alloc);
    errdefer alloc.free(vibecrafted_home);

    const day_stamp = try formatDayStamp(alloc, now_seconds);
    defer alloc.free(day_stamp);

    const project_artifacts_root = try std.fs.path.join(alloc, &.{
        vibecrafted_home,
        "artifacts",
        project_slug,
    });
    errdefer alloc.free(project_artifacts_root);

    const day_root = try std.fs.path.join(alloc, &.{
        project_artifacts_root,
        day_stamp,
    });
    errdefer alloc.free(day_root);

    const reports_dir = try std.fs.path.join(alloc, &.{ day_root, "reports" });
    errdefer alloc.free(reports_dir);

    const tmp_dir = try std.fs.path.join(alloc, &.{ day_root, "tmp" });
    errdefer alloc.free(tmp_dir);

    const locks_dir = try std.fs.path.join(alloc, &.{
        vibecrafted_home,
        "locks",
        project_slug,
    });
    errdefer alloc.free(locks_dir);

    try ensureDirAbsolute(vibecrafted_home);
    try ensureDirAbsolute(project_artifacts_root);
    try ensureDirAbsolute(day_root);
    try ensureDirAbsolute(reports_dir);
    try ensureDirAbsolute(tmp_dir);
    try ensureDirAbsolute(locks_dir);

    return .{
        .allocator = alloc,
        .root = root,
        .project_slug = project_slug,
        .vibecrafted_home = vibecrafted_home,
        .project_artifacts_root = project_artifacts_root,
        .day_root = day_root,
        .reports_dir = reports_dir,
        .tmp_dir = tmp_dir,
        .locks_dir = locks_dir,
        .now_seconds = now_seconds,
    };
}

pub fn generateRunId(alloc: Allocator, prefix: []const u8, now_seconds: i64) ![]const u8 {
    const clock_stamp = try formatClockStamp(alloc, now_seconds);
    defer alloc.free(clock_stamp);
    return std.fmt.allocPrint(alloc, "{s}-{s}-{d}", .{
        prefix,
        clock_stamp,
        @as(std.posix.pid_t, @intCast(std.c.getpid())),
    });
}

pub fn buildRunPaths(
    alloc: Allocator,
    layout: *const Layout,
    run_id: []const u8,
    agent: []const u8,
) !RunPaths {
    const file_stamp = try formatFileStamp(alloc, layout.now_seconds);
    defer alloc.free(file_stamp);

    return .{
        .allocator = alloc,
        .meta_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}_{s}_{s}.meta.json",
            .{ layout.reports_dir, file_stamp, run_id, agent },
        ),
        .report_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}_{s}_{s}.md",
            .{ layout.reports_dir, file_stamp, run_id, agent },
        ),
        .transcript_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}_{s}_{s}.transcript.log",
            .{ layout.reports_dir, file_stamp, run_id, agent },
        ),
        .prompt_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}_{s}_{s}.prompt.md",
            .{ layout.tmp_dir, file_stamp, run_id, agent },
        ),
        .lock_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}.lock",
            .{ layout.locks_dir, run_id },
        ),
    };
}

pub fn createRunMeta(alloc: Allocator, opts: CreateRunOptions) !RunMeta {
    var paths = try buildRunPaths(alloc, opts.layout, opts.run_id, opts.agent);
    errdefer paths.deinit();

    var meta: RunMeta = .{
        .allocator = alloc,
        .run_id = try alloc.dupe(u8, opts.run_id),
        .agent = try alloc.dupe(u8, opts.agent),
        .skill_name = try alloc.dupe(u8, opts.skill_name),
        .skill_code = try alloc.dupe(u8, opts.skill_code),
        .mode = try alloc.dupe(u8, opts.mode),
        .root = try alloc.dupe(u8, opts.root),
        .skill_path = if (opts.skill_path) |value| try alloc.dupe(u8, value) else null,
        .meta_path = paths.meta_path,
        .report_path = paths.report_path,
        .transcript_path = paths.transcript_path,
        .prompt_path = paths.prompt_path,
        .lock_path = paths.lock_path,
        .status = .launching,
        .started_at = opts.layout.now_seconds,
        .updated_at = opts.layout.now_seconds,
    };
    errdefer meta.deinit();

    try writeLockFile(meta.lock_path, meta.run_id, meta.agent, meta.skill_name, meta.root, meta.started_at);
    try meta.save();
    return meta;
}

pub fn loadMetaAbsolute(alloc: Allocator, meta_path: []const u8) !RunMeta {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        meta_path,
        alloc,
        .limited(256 * 1024),
    );
    defer alloc.free(content);

    var parsed = try std.json.parseFromSlice(DiskPayload, alloc, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const payload = parsed.value;
    return .{
        .allocator = alloc,
        .run_id = try alloc.dupe(u8, payload.run_id),
        .agent = try alloc.dupe(u8, payload.agent),
        .skill_name = try alloc.dupe(u8, payload.skill_name),
        .skill_code = try alloc.dupe(u8, payload.skill_code),
        .mode = try alloc.dupe(u8, payload.mode),
        .root = try alloc.dupe(u8, payload.root),
        .skill_path = if (payload.skill_path) |value| try alloc.dupe(u8, value) else null,
        .meta_path = try alloc.dupe(u8, payload.meta_path),
        .report_path = try alloc.dupe(u8, payload.report_path),
        .transcript_path = try alloc.dupe(u8, payload.transcript_path),
        .prompt_path = try alloc.dupe(u8, payload.prompt_path),
        .lock_path = try alloc.dupe(u8, payload.lock_path),
        .status = payload.status,
        .launcher_pid = payload.launcher_pid,
        .ghost_reason = if (payload.ghost_reason) |value| try alloc.dupe(u8, value) else null,
        .exit_code = payload.exit_code,
        .started_at = payload.started_at,
        .updated_at = payload.updated_at,
        .completed_at = payload.completed_at,
    };
}

pub fn sweepDeadRuns(alloc: Allocator, layout: *const Layout) !SweepResult {
    if (!pathExists(layout.project_artifacts_root)) return .{};

    var result: SweepResult = .{};

    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, layout.project_artifacts_root, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".meta.json")) continue;

        const meta_path = try std.fs.path.join(alloc, &.{ layout.project_artifacts_root, entry.path });
        defer alloc.free(meta_path);

        var meta = loadMetaAbsolute(alloc, meta_path) catch continue;
        defer meta.deinit();

        result.scanned += 1;
        if (!meta.status.isLive()) continue;
        const pid = meta.launcher_pid orelse {
            try meta.reapGhost("launcher_pid missing for live run", layout.now_seconds);
            result.reaped += 1;
            continue;
        };
        if (pidAlive(pid)) continue;

        try meta.reapGhost("launcher_pid dead at reap", layout.now_seconds);
        result.reaped += 1;
    }

    return result;
}

pub fn pidAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

fn defaultVibecraftedHome(alloc: Allocator) ![]const u8 {
    if (try getenvOwned(alloc, "VIBECRAFTED_HOME")) |value| {
        defer alloc.free(value);
        return ensureRealpathDir(alloc, value);
    }

    const home = (try getenvOwned(alloc, "HOME")) orelse return error.EnvironmentVariableNotFound;
    defer alloc.free(home);
    const joined = try std.fs.path.join(alloc, &.{ home, ".vibecrafted" });
    defer alloc.free(joined);
    return realpathAlloc(alloc, joined) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try ensureDirAbsolute(joined);
            break :blk try realpathAlloc(alloc, joined);
        },
        else => return err,
    };
}

fn deriveProjectSlug(alloc: Allocator, root: []const u8) ![]const u8 {
    if (try getenvOwned(alloc, "VIBECRAFTED_PROJECT_SLUG")) |value| {
        return value;
    }

    const maybe_remote = try gitRemoteOrigin(alloc, root);
    defer if (maybe_remote) |value| alloc.free(value);

    if (maybe_remote) |remote| {
        if (parseOrgRepoRemote(alloc, std.mem.trim(u8, remote, " \n\r\t"))) |slug| {
            return slug;
        } else |_| {}
    }

    return alloc.dupe(u8, std.fs.path.basename(root));
}

fn gitRemoteOrigin(alloc: Allocator, root: []const u8) !?[]const u8 {
    const result = std.process.run(alloc, std.Options.debug_io, .{
        .argv = &.{ "git", "-C", root, "remote", "get-url", "origin" },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const term = result.term;
    switch (term) {
        .exited => |code| if (code == 0 and result.stdout.len > 0) return try alloc.dupe(u8, result.stdout),
        else => {},
    }
    return null;
}

fn parseOrgRepoRemote(alloc: Allocator, remote: []const u8) ![]const u8 {
    var end = remote.len;
    if (std.mem.endsWith(u8, remote, ".git")) end -= 4;

    const trimmed = remote[0..end];
    const last_slash = std.mem.lastIndexOfAny(u8, trimmed, "/:") orelse return error.InvalidRemote;
    const repo = trimmed[last_slash + 1 ..];
    const owner_end = last_slash;
    const owner_sep = std.mem.lastIndexOfAny(u8, trimmed[0..owner_end], "/:") orelse return error.InvalidRemote;
    const owner = trimmed[owner_sep + 1 .. owner_end];
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ owner, repo });
}

fn ensureDirAbsolute(path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureRealpathDir(alloc: Allocator, path: []const u8) ![]const u8 {
    return realpathAlloc(alloc, path) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureDirAbsolute(path);
            return realpathAlloc(alloc, path);
        },
        else => return err,
    };
}

fn realpathAlloc(alloc: Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, alloc);
}

fn getenvOwned(alloc: Allocator, name: [*:0]const u8) !?[]u8 {
    const value = std.c.getenv(name) orelse return null;
    return try alloc.dupe(u8, std.mem.sliceTo(value, 0));
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn writeLockFile(
    lock_path: []const u8,
    run_id: []const u8,
    agent: []const u8,
    skill_name: []const u8,
    root: []const u8,
    started_at: i64,
) !void {
    const body = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "run_id={s}\nagent={s}\nskill={s}\nroot={s}\nstarted={d}\nstatus=running\n",
        .{ run_id, agent, skill_name, root, started_at },
    );
    defer std.heap.page_allocator.free(body);
    try writeFileAtomic(lock_path, 0o644, body);
}

fn writeFileAtomic(path: []const u8, mode: u16, data: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return error.BadPathName;
    const base_name = std.fs.path.basename(path);

    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_name, .{});
    defer dir.close(std.Options.debug_io);

    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try dir.createFileAtomic(std.Options.debug_io, base_name, .{
        .permissions = @enumFromInt(mode),
        .replace = true,
    });
    defer atomic_file.deinit(std.Options.debug_io);

    var file_writer = atomic_file.file.writer(std.Options.debug_io, &write_buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
    try atomic_file.replace(std.Options.debug_io);
}

fn formatDayStamp(alloc: Allocator, now_seconds: i64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        alloc,
        "{d}_{d:0>2}{d:0>2}",
        .{ year_day.year, month_day.month.numeric(), month_day.day_index },
    );
}

fn formatClockStamp(alloc: Allocator, now_seconds: i64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        alloc,
        "{d:0>2}{d:0>2}{d:0>2}",
        .{
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn formatFileStamp(alloc: Allocator, now_seconds: i64) ![]const u8 {
    const day_stamp = try formatDayStamp(alloc, now_seconds);
    defer alloc.free(day_stamp);
    const clock_stamp = try formatClockStamp(alloc, now_seconds);
    defer alloc.free(clock_stamp);

    var compact_day = try alloc.alloc(u8, day_stamp.len - 1);
    defer alloc.free(compact_day);

    var write_index: usize = 0;
    for (day_stamp) |ch| {
        if (ch == '_') continue;
        compact_day[write_index] = ch;
        write_index += 1;
    }

    return std.fmt.allocPrint(alloc, "{s}_{s}", .{ compact_day[0..write_index], clock_stamp[0..4] });
}

test "generateRunId keeps the legacy prefix-hhmmss-pid contract" {
    const run_id = try generateRunId(std.testing.allocator, "init", 1710883557);
    defer std.testing.allocator.free(run_id);

    try std.testing.expect(std.mem.startsWith(u8, run_id, "init-212557-"));
    const pid_suffix = run_id["init-212557-".len..];
    try std.testing.expect(pid_suffix.len > 0);
    for (pid_suffix) |ch| try std.testing.expect(std.ascii.isDigit(ch));
}

test "createRunMeta writes meta and lock files" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const home_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home_path);

    var layout = try resolveLayout(testing.allocator, .{
        .root = root_path,
        .now_seconds = 1710883557,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
    });
    defer layout.deinit();

    const run_id = try generateRunId(testing.allocator, "init", 1710883557);
    defer testing.allocator.free(run_id);

    var meta = try createRunMeta(testing.allocator, .{
        .layout = &layout,
        .run_id = run_id,
        .agent = "claude",
        .skill_name = "init",
        .skill_code = "init",
        .mode = "headless",
        .root = root_path,
    });
    defer meta.deinit();

    try testing.expect(pathExists(meta.meta_path));
    try testing.expect(pathExists(meta.lock_path));

    var loaded = try loadMetaAbsolute(testing.allocator, meta.meta_path);
    defer loaded.deinit();

    try testing.expectEqual(Status.launching, loaded.status);
    try std.testing.expect(std.mem.startsWith(u8, loaded.run_id, "init-212557-"));
    try testing.expectEqualStrings(meta.lock_path, loaded.lock_path);
}

test "sweepDeadRuns flips stale launchers to ghost and releases locks" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const home_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home_path);

    var layout = try resolveLayout(testing.allocator, .{
        .root = root_path,
        .now_seconds = 1710883557,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
    });
    defer layout.deinit();

    const run_id = try generateRunId(testing.allocator, "init", 1710883557);
    defer testing.allocator.free(run_id);

    var meta = try createRunMeta(testing.allocator, .{
        .layout = &layout,
        .run_id = run_id,
        .agent = "claude",
        .skill_name = "init",
        .skill_code = "init",
        .mode = "headless",
        .root = root_path,
    });
    defer meta.deinit();

    meta.launcher_pid = 999_999;
    meta.status = .running;
    try meta.save();

    const sweep = try sweepDeadRuns(testing.allocator, &layout);
    try testing.expectEqual(@as(usize, 1), sweep.reaped);

    var loaded = try loadMetaAbsolute(testing.allocator, meta.meta_path);
    defer loaded.deinit();

    try testing.expectEqual(Status.ghost, loaded.status);
    try testing.expect(loaded.ghost_reason != null);
    try testing.expect(!pathExists(meta.lock_path));
}

test "sweepDeadRuns reaps live runs that never recorded launcher_pid" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const home_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home_path);

    var layout = try resolveLayout(testing.allocator, .{
        .root = root_path,
        .now_seconds = 1710883557,
        .vibecrafted_home_override = home_path,
        .project_slug_override = "vet/sample",
    });
    defer layout.deinit();

    const run_id = try generateRunId(testing.allocator, "init", 1710883557);
    defer testing.allocator.free(run_id);

    var meta = try createRunMeta(testing.allocator, .{
        .layout = &layout,
        .run_id = run_id,
        .agent = "claude",
        .skill_name = "init",
        .skill_code = "init",
        .mode = "headless",
        .root = root_path,
    });
    defer meta.deinit();

    meta.status = .running;
    meta.launcher_pid = null;
    try meta.save();

    const sweep = try sweepDeadRuns(testing.allocator, &layout);
    try testing.expectEqual(@as(usize, 1), sweep.reaped);

    var loaded = try loadMetaAbsolute(testing.allocator, meta.meta_path);
    defer loaded.deinit();

    try testing.expectEqual(Status.ghost, loaded.status);
    try testing.expectEqualStrings("launcher_pid missing for live run", loaded.ghost_reason.?);
    try testing.expect(!pathExists(meta.lock_path));
}
