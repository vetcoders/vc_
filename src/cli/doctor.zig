const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const vc_install = @import("../vc_board/install.zig");

pub const Mode = enum {
    doctor,
    status,
};

const OutputMode = enum {
    text,
    json,
    markdown,
};

const Severity = enum {
    ok,
    warn,
    fail,

    fn label(self: Severity) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warn => "warn",
            .fail => "fail",
        };
    }
};

const Check = struct {
    key: []const u8,
    severity: Severity,
    summary: []const u8,
    hint: ?[]const u8 = null,
};

const Report = struct {
    alloc: Allocator,
    checks: std.ArrayListUnmanaged(Check) = .empty,

    fn deinit(self: *Report) void {
        for (self.checks.items) |check| {
            self.alloc.free(check.key);
            self.alloc.free(check.summary);
            if (check.hint) |hint| self.alloc.free(hint);
        }
        self.checks.deinit(self.alloc);
    }

    fn append(
        self: *Report,
        severity: Severity,
        key: []const u8,
        summary: []const u8,
        hint: ?[]const u8,
    ) !void {
        try self.checks.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .severity = severity,
            .summary = try self.alloc.dupe(u8, summary),
            .hint = if (hint) |value| try self.alloc.dupe(u8, value) else null,
        });
    }

    fn hasFailures(self: *const Report) bool {
        for (self.checks.items) |check| {
            if (check.severity == .fail) return true;
        }
        return false;
    }
};

const Layout = struct {
    kind: enum {
        dev,
        portable,
        macos_app,
    },
    exe_path: []const u8,
    root_dir: ?[]const u8,
    helpers_dir: ?[]const u8,
    skills_dir: ?[]const u8,
    bundled_config_path: ?[]const u8,
    plist_path: ?[]const u8,

    fn deinit(self: Layout, alloc: Allocator) void {
        alloc.free(self.exe_path);
        if (self.root_dir) |value| alloc.free(value);
        if (self.helpers_dir) |value| alloc.free(value);
        if (self.skills_dir) |value| alloc.free(value);
        if (self.bundled_config_path) |value| alloc.free(value);
        if (self.plist_path) |value| alloc.free(value);
    }
};

const bundled_helpers = [_][]const u8{
    "aicx",
    "loctree",
    "prview",
    "rust-mux",
};

const agent_clis = [_][]const u8{
    "claude",
    "codex",
    "gemini",
};

pub fn run(alloc: Allocator, mode: Mode, argv: []const []const u8) !u8 {
    const output_mode = try parseOutputMode(argv);
    if (containsHelp(argv)) {
        try printHelp(mode);
        return 0;
    }

    var report = try collect(alloc);
    defer report.deinit();

    switch (mode) {
        .doctor => switch (output_mode) {
            .text => try renderText(report, false),
            .json => try renderJson(report),
            .markdown => try renderMarkdown(report, false),
        },
        .status => switch (output_mode) {
            .text => try renderText(report, true),
            .json => try renderJson(report),
            .markdown => try renderMarkdown(report, true),
        },
    }

    return if (report.hasFailures()) 1 else 0;
}

fn collect(alloc: Allocator) !Report {
    var report: Report = .{ .alloc = alloc };
    errdefer report.deinit();

    const config_path = vc_install.ensureDefaultConfig(alloc) catch |err| config_path: {
        const summary = try std.fmt.allocPrint(
            alloc,
            "config bootstrap failed: {}",
            .{err},
        );
        defer alloc.free(summary);
        try report.append(
            .fail,
            "config",
            summary,
            "Create the vc_ config path and rerun `vc_ doctor`.",
        );
        break :config_path null;
    };
    defer if (config_path) |path| alloc.free(path);

    if (config_path) |path| {
        const summary = try std.fmt.allocPrint(alloc, "config ready at {s}", .{path});
        defer alloc.free(summary);
        try report.append(.ok, "config", summary, null);
        try collectConfigWriteStatus(alloc, &report, path);
    }

    const layout = try detectLayout(alloc);
    defer layout.deinit(alloc);

    {
        const summary = try std.fmt.allocPrint(
            alloc,
            "runtime layout: {s} ({s})",
            .{ @tagName(layout.kind), layout.exe_path },
        );
        defer alloc.free(summary);
        try report.append(.ok, "layout", summary, null);
    }

    if (layout.kind == .dev) {
        try report.append(
            .warn,
            "bundle",
            "running from a dev tree, not an install bundle",
            "Build a DMG or tarball to validate bundled helpers and skills.",
        );
    } else if (layout.root_dir) |root| {
        const summary = try std.fmt.allocPrint(alloc, "bundle root at {s}", .{root});
        defer alloc.free(summary);
        try report.append(.ok, "bundle", summary, null);
    }

    try collectBundledAssets(alloc, &report, layout);
    try collectBundleMetadata(alloc, &report, layout);
    try collectAgentCliStatus(alloc, &report);

    return report;
}

fn collectBundledAssets(
    alloc: Allocator,
    report: *Report,
    layout: Layout,
) !void {
    if (layout.helpers_dir) |helpers_dir| {
        for (bundled_helpers) |helper| {
            const helper_path = try std.fs.path.join(alloc, &.{ helpers_dir, helper });
            defer alloc.free(helper_path);

            if (isExecutableFile(helper_path)) |executable| {
                if (!executable) {
                    const summary = try std.fmt.allocPrint(
                        alloc,
                        "bundled helper {s} is present but not executable",
                        .{helper},
                    );
                    defer alloc.free(summary);
                    try report.append(
                        if (layout.kind == .dev) .warn else .fail,
                        helper,
                        summary,
                        "Repair file permissions or rebuild the release bundle.",
                    );
                    continue;
                }

                const summary = try std.fmt.allocPrint(
                    alloc,
                    "{s} bundled and executable at {s}",
                    .{ helper, helper_path },
                );
                defer alloc.free(summary);
                try report.append(.ok, helper, summary, null);
            } else |_| {
                const summary = try std.fmt.allocPrint(
                    alloc,
                    "missing bundled helper {s}",
                    .{helper},
                );
                defer alloc.free(summary);
                try report.append(
                    if (layout.kind == .dev) .warn else .fail,
                    helper,
                    summary,
                    "Rebuild the release bundle so bundled helpers land under bin/.",
                );
            }
        }
    } else {
        try report.append(
            .warn,
            "helpers",
            "no bundled helpers directory detected",
            "Package vc_ through distribution scripts before shipping.",
        );
    }

    if (layout.skills_dir) |skills_dir| {
        if (std.Io.Dir.accessAbsolute(std.Options.debug_io, skills_dir, .{})) |_| {
            const summary = try std.fmt.allocPrint(
                alloc,
                "skills bundle detected at {s}",
                .{skills_dir},
            );
            defer alloc.free(summary);
            try report.append(.ok, "skills", summary, null);
        } else |_| {
            try report.append(
                if (layout.kind == .dev) .warn else .fail,
                "skills",
                "skills directory missing from bundle",
                "Copy the runtime skills surface into the release artifact.",
            );
        }
    } else {
        try report.append(
            .warn,
            "skills",
            "no bundled skills directory detected",
            "Package vc_ through distribution scripts before shipping.",
        );
    }

    if (layout.bundled_config_path) |bundled_config_path| {
        if (std.Io.Dir.accessAbsolute(std.Options.debug_io, bundled_config_path, .{})) |_| {
            const summary = try std.fmt.allocPrint(
                alloc,
                "bundled config seed detected at {s}",
                .{bundled_config_path},
            );
            defer alloc.free(summary);
            try report.append(.ok, "bundle-config", summary, null);
        } else |_| {
            try report.append(
                if (layout.kind == .dev) .warn else .fail,
                "bundle-config",
                "bundled config seed missing from install artifact",
                "Rebuild the release bundle so the initial config lands under share/config or Contents/Resources/config.",
            );
        }
    }
}

fn collectBundleMetadata(
    alloc: Allocator,
    report: *Report,
    layout: Layout,
) !void {
    const plist_path = layout.plist_path orelse return;

    const bundle_id = try plistStringValue(alloc, plist_path, "CFBundleIdentifier");
    defer if (bundle_id) |value| alloc.free(value);

    if (bundle_id) |value| {
        if (std.mem.eql(u8, value, build_config.bundle_id)) {
            const summary = try std.fmt.allocPrint(
                alloc,
                "bundle identifier matches {s}",
                .{value},
            );
            defer alloc.free(summary);
            try report.append(.ok, "bundle-id", summary, null);
        } else {
            const summary = try std.fmt.allocPrint(
                alloc,
                "bundle identifier mismatch: expected {s}, found {s}",
                .{ build_config.bundle_id, value },
            );
            defer alloc.free(summary);
            try report.append(
                .fail,
                "bundle-id",
                summary,
                "Rebuild the macOS app bundle so Info.plist matches the vc_ product identity.",
            );
        }
    } else {
        try report.append(
            .fail,
            "bundle-id",
            "Info.plist missing CFBundleIdentifier",
            "Rebuild the macOS app bundle so the bundle identifier is written into Info.plist.",
        );
    }

    const executable_name = try plistStringValue(alloc, plist_path, "CFBundleExecutable");
    defer if (executable_name) |value| alloc.free(value);

    if (executable_name) |value| {
        // Accept the canonical "vc_" product mark as well as the
        // legacy "vc-board" name so old installs still pass doctor.
        if (std.mem.eql(u8, value, "vc_") or
            std.mem.eql(u8, value, "vc-board"))
        {
            const summary = try std.fmt.allocPrint(
                alloc,
                "bundle executable matches {s}",
                .{value},
            );
            defer alloc.free(summary);
            try report.append(.ok, "bundle-executable", summary, null);
        } else {
            const summary = try std.fmt.allocPrint(
                alloc,
                "bundle executable mismatch: expected vc_, found {s}",
                .{value},
            );
            defer alloc.free(summary);
            try report.append(
                .fail,
                "bundle-executable",
                summary,
                "Rebuild the macOS bundle so Finder launches the vc_ runtime entrypoint.",
            );
        }
    } else {
        try report.append(
            .fail,
            "bundle-executable",
            "Info.plist missing CFBundleExecutable",
            "Rebuild the macOS app bundle so Info.plist points Finder at vc_.",
        );
    }
}

fn collectAgentCliStatus(alloc: Allocator, report: *Report) !void {
    for (agent_clis) |name| {
        const path = try findOnPath(alloc, name);
        defer if (path) |value| alloc.free(value);

        if (path) |value| {
            const summary = try std.fmt.allocPrint(
                alloc,
                "{s} available in PATH at {s}",
                .{ name, value },
            );
            defer alloc.free(summary);
            try report.append(.ok, name, summary, null);
        } else {
            const summary = try std.fmt.allocPrint(alloc, "{s} not found in PATH", .{name});
            defer alloc.free(summary);
            try report.append(
                .warn,
                name,
                summary,
                "Install the agent CLI or add it to PATH before dispatching runtime tasks.",
            );
        }
    }
}

fn collectConfigWriteStatus(
    alloc: Allocator,
    report: *Report,
    config_path: []const u8,
) !void {
    const config_dir = std.fs.path.dirname(config_path) orelse {
        try report.append(
            .fail,
            "config-write",
            "config path has no writable parent directory",
            "Repair the config path and rerun `vc_ doctor`.",
        );
        return;
    };

    const probe_name = try std.fmt.allocPrint(
        alloc,
        ".vc-board-doctor-write-{d}.tmp",
        .{nowNanoseconds()},
    );
    defer alloc.free(probe_name);

    const probe_path = try std.fs.path.join(alloc, &.{ config_dir, probe_name });
    defer alloc.free(probe_path);

    var probe = std.Io.Dir.createFileAbsolute(std.Options.debug_io, probe_path, .{ .exclusive = true }) catch |err| {
        const summary = try std.fmt.allocPrint(
            alloc,
            "config directory is not writable: {}",
            .{err},
        );
        defer alloc.free(summary);
        try report.append(
            .fail,
            "config-write",
            summary,
            "Fix directory permissions for the vc_ config path.",
        );
        return;
    };
    probe.close(std.Options.debug_io);
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, probe_path) catch {};

    const summary = try std.fmt.allocPrint(
        alloc,
        "config directory is writable at {s}",
        .{config_dir},
    );
    defer alloc.free(summary);
    try report.append(.ok, "config-write", summary, null);
}

fn detectLayout(alloc: Allocator) !Layout {
    const exe_path = try selfExePathAlloc(alloc);
    defer alloc.free(exe_path);
    return detectLayoutForExePath(alloc, exe_path);
}

fn detectLayoutForExePath(alloc: Allocator, exe_path_input: []const u8) !Layout {
    const exe_path = try alloc.dupe(u8, exe_path_input);
    errdefer alloc.free(exe_path);

    if (std.mem.indexOf(u8, exe_path, ".app/Contents/MacOS/")) |idx| {
        const app_root = exe_path[0 .. idx + ".app".len];
        const helpers_dir = try std.fs.path.join(alloc, &.{ app_root, "Contents", "Resources", "bin" });
        errdefer alloc.free(helpers_dir);
        const skills_dir = try std.fs.path.join(alloc, &.{ app_root, "Contents", "Resources", "skills" });
        errdefer alloc.free(skills_dir);
        const bundled_config_path = try std.fs.path.join(alloc, &.{ app_root, "Contents", "Resources", "config", "config" });
        errdefer alloc.free(bundled_config_path);
        const plist_path = try std.fs.path.join(alloc, &.{ app_root, "Contents", "Info.plist" });
        errdefer alloc.free(plist_path);
        return .{
            .kind = .macos_app,
            .exe_path = exe_path,
            .root_dir = try alloc.dupe(u8, app_root),
            .helpers_dir = helpers_dir,
            .skills_dir = skills_dir,
            .bundled_config_path = bundled_config_path,
            .plist_path = plist_path,
        };
    }

    const exe_dir = std.fs.path.dirname(exe_path) orelse return .{
        .kind = .dev,
        .exe_path = exe_path,
        .root_dir = null,
        .helpers_dir = null,
        .skills_dir = null,
        .bundled_config_path = null,
        .plist_path = null,
    };
    if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) {
        const root_dir = std.fs.path.dirname(exe_dir) orelse exe_dir;
        if (try looksLikeDevZigOut(alloc, root_dir)) {
            return .{
                .kind = .dev,
                .exe_path = exe_path,
                .root_dir = null,
                .helpers_dir = null,
                .skills_dir = null,
                .bundled_config_path = null,
                .plist_path = null,
            };
        }

        const helpers_dir = try alloc.dupe(u8, exe_dir);
        errdefer alloc.free(helpers_dir);
        const skills_dir = try std.fs.path.join(alloc, &.{ root_dir, "share", "skills" });
        errdefer alloc.free(skills_dir);
        const bundled_config_path = try std.fs.path.join(alloc, &.{ root_dir, "share", "config", "config" });
        errdefer alloc.free(bundled_config_path);
        return .{
            .kind = .portable,
            .exe_path = exe_path,
            .root_dir = try alloc.dupe(u8, root_dir),
            .helpers_dir = helpers_dir,
            .skills_dir = skills_dir,
            .bundled_config_path = bundled_config_path,
            .plist_path = null,
        };
    }

    return .{
        .kind = .dev,
        .exe_path = exe_path,
        .root_dir = null,
        .helpers_dir = null,
        .skills_dir = null,
        .bundled_config_path = null,
        .plist_path = null,
    };
}

fn looksLikeDevZigOut(alloc: Allocator, root_dir: []const u8) !bool {
    if (!std.mem.eql(u8, std.fs.path.basename(root_dir), "zig-out")) return false;

    const repo_root = std.fs.path.dirname(root_dir) orelse return false;
    const build_zig_path = try std.fs.path.join(alloc, &.{ repo_root, "build.zig" });
    defer alloc.free(build_zig_path);
    std.Io.Dir.accessAbsolute(std.Options.debug_io, build_zig_path, .{}) catch return false;

    const src_dir_path = try std.fs.path.join(alloc, &.{ repo_root, "src" });
    defer alloc.free(src_dir_path);
    var src_dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, src_dir_path, .{}) catch return false;
    src_dir.close(std.Options.debug_io);

    return true;
}

fn plistStringValue(
    alloc: Allocator,
    plist_path: []const u8,
    key: []const u8,
) !?[]const u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        plist_path,
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(contents);

    const key_prefix = try std.fmt.allocPrint(alloc, "<key>{s}</key>", .{key});
    defer alloc.free(key_prefix);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var next_is_value = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (!next_is_value) {
            next_is_value = std.mem.eql(u8, trimmed, key_prefix);
            continue;
        }

        const string_prefix = "<string>";
        const string_suffix = "</string>";
        if (std.mem.startsWith(u8, trimmed, string_prefix) and std.mem.endsWith(u8, trimmed, string_suffix)) {
            const start = string_prefix.len;
            const end = trimmed.len - string_suffix.len;
            return try alloc.dupe(u8, trimmed[start..end]);
        }
        return null;
    }

    return null;
}

fn parseOutputMode(argv: []const []const u8) !OutputMode {
    var mode: OutputMode = .text;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            mode = .json;
        } else if (std.mem.eql(u8, arg, "--md")) {
            mode = .markdown;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            continue;
        } else {
            return error.InvalidArguments;
        }
    }
    return mode;
}

fn containsHelp(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn renderText(report: Report, compact: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buffer);
    const stdout = &stdout_writer.interface;

    if (compact) {
        var emitted = false;
        for (report.checks.items) |check| {
            if (check.severity == .ok) continue;
            emitted = true;
            try stdout.print("[{s}] {s}: {s}\n", .{
                check.severity.label(),
                check.key,
                check.summary,
            });
        }
        if (!emitted) {
            try stdout.writeAll("vc_ status: ok\n");
        }
        try stdout.flush();
        return;
    }

    try stdout.writeAll("vc_ doctor\n");
    for (report.checks.items) |check| {
        try stdout.print("- [{s}] {s}: {s}\n", .{
            check.severity.label(),
            check.key,
            check.summary,
        });
        if (check.hint) |hint| {
            try stdout.print("  hint: {s}\n", .{hint});
        }
    }
    try stdout.flush();
}

fn renderJson(report: Report) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("{{\"bundle_id\":{f},\"checks\":[", .{std.json.fmt(build_config.bundle_id, .{})});
    for (report.checks.items, 0..) |check, idx| {
        if (idx > 0) try stdout.writeAll(",");
        try stdout.print(
            "{{\"key\":{f},\"severity\":{f},\"summary\":{f}",
            .{
                std.json.fmt(check.key, .{}),
                std.json.fmt(check.severity.label(), .{}),
                std.json.fmt(check.summary, .{}),
            },
        );
        if (check.hint) |hint| {
            try stdout.print(",\"hint\":{f}", .{std.json.fmt(hint, .{})});
        }
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]}\n");
    try stdout.flush();
}

fn renderMarkdown(report: Report, compact: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("# vc_ doctor\n\n");
    for (report.checks.items) |check| {
        if (compact and check.severity == .ok) continue;
        try stdout.print("- **{s}** `{s}`: {s}\n", .{
            check.severity.label(),
            check.key,
            check.summary,
        });
        if (check.hint) |hint| {
            try stdout.print("  hint: {s}\n", .{hint});
        }
    }
    try stdout.flush();
}

fn printHelp(mode: Mode) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\Usage: vc_ {s} [--json|--md]
        \\
        \\Checks bundle identity, bundled helpers, bundled skills,
        \\config bootstrap, and agent CLIs in PATH.
        \\
    ,
        .{@tagName(mode)},
    );
    try stdout.flush();
}

fn isExecutableFile(path: []const u8) !bool {
    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);

    const stat = try file.stat(std.Options.debug_io);
    if (stat.kind != .file) return false;

    return switch (builtin.os.tag) {
        .windows => true,
        else => (@intFromEnum(stat.permissions) & 0o111) != 0,
    };
}

fn findOnPath(alloc: Allocator, name: []const u8) !?[]const u8 {
    const path_env = try internal_os.getenv(alloc, "PATH");
    defer if (path_env) |value| value.deinit(alloc);
    const path_value = path_env orelse return null;

    var parts = std.mem.tokenizeScalar(u8, path_value.value, std.fs.path.delimiter);
    while (parts.next()) |part| {
        const candidate = try std.fs.path.join(alloc, &.{ part, name });
        errdefer alloc.free(candidate);

        if (std.Io.Dir.accessAbsolute(std.Options.debug_io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            alloc.free(candidate);
        }
    }

    return null;
}

fn nowNanoseconds() i128 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
}

fn selfExePathAlloc(alloc: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .macos) {
        var required: u32 = 0;
        var tiny: [1]u8 = undefined;
        _ = std.c._NSGetExecutablePath(&tiny, &required);

        const raw_buf = try alloc.alloc(u8, required);
        defer alloc.free(raw_buf);
        if (std.c._NSGetExecutablePath(raw_buf.ptr, &required) != 0) return error.NameTooLong;

        const raw = std.mem.sliceTo(raw_buf.ptr, 0);
        return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, raw, alloc) catch try alloc.dupe(u8, raw);
    }

    return error.Unsupported;
}

test "parse output mode" {
    try std.testing.expectEqual(OutputMode.json, try parseOutputMode(&.{"--json"}));
    try std.testing.expectEqual(OutputMode.markdown, try parseOutputMode(&.{"--md"}));
    try std.testing.expectError(error.InvalidArguments, parseOutputMode(&.{"--bogus"}));
}

test "contains help" {
    try std.testing.expect(containsHelp(&.{"--help"}));
    try std.testing.expect(!containsHelp(&.{"--json"}));
}

test "plist string value extracts bundle metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "Info.plist",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.vibecrafted.vc-board</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>vc-board</string>
        \\</dict>
        \\</plist>
        ,
    });

    const plist_path = try tmp.dir.realpathAlloc(std.testing.allocator, "Info.plist");
    defer std.testing.allocator.free(plist_path);

    const bundle_id = try plistStringValue(std.testing.allocator, plist_path, "CFBundleIdentifier");
    defer if (bundle_id) |value| std.testing.allocator.free(value);
    try std.testing.expect(bundle_id != null);
    try std.testing.expectEqualStrings("com.vibecrafted.vc-board", bundle_id.?);

    const executable = try plistStringValue(std.testing.allocator, plist_path, "CFBundleExecutable");
    defer if (executable) |value| std.testing.allocator.free(value);
    try std.testing.expect(executable != null);
    try std.testing.expectEqualStrings("vc-board", executable.?);
}

test "detect layout treats zig-out runtime as dev tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo");
    try tmp.dir.writeFile(.{
        .sub_path = "repo/build.zig",
        .data = "const std = @import(\"std\");\n",
    });
    try tmp.dir.makePath("repo/src");
    try tmp.dir.makePath("repo/zig-out/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "repo/zig-out/bin/vc-board",
        .data = "",
    });

    const exe_path = try tmp.dir.realpathAlloc(std.testing.allocator, "repo/zig-out/bin/vc-board");
    defer std.testing.allocator.free(exe_path);

    const layout = try detectLayoutForExePath(std.testing.allocator, exe_path);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(.dev, layout.kind);
    try std.testing.expect(layout.root_dir == null);
    try std.testing.expect(layout.helpers_dir == null);
}

test "detect layout treats portable bin/share install as portable bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("portable/bin");
    try tmp.dir.makePath("portable/share/skills");
    try tmp.dir.makePath("portable/share/config");
    try tmp.dir.writeFile(.{
        .sub_path = "portable/bin/vc-board",
        .data = "",
    });

    const exe_path = try tmp.dir.realpathAlloc(std.testing.allocator, "portable/bin/vc-board");
    defer std.testing.allocator.free(exe_path);

    const layout = try detectLayoutForExePath(std.testing.allocator, exe_path);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(.portable, layout.kind);
    try std.testing.expect(layout.root_dir != null);
    try std.testing.expect(layout.helpers_dir != null);
    try std.testing.expect(layout.skills_dir != null);
    try std.testing.expect(layout.bundled_config_path != null);
}

test "detect layout treats macos app bundle as macos_app bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("vc-board.app/Contents/MacOS");
    try tmp.dir.makePath("vc-board.app/Contents/Resources/bin");
    try tmp.dir.makePath("vc-board.app/Contents/Resources/skills");
    try tmp.dir.makePath("vc-board.app/Contents/Resources/config");
    try tmp.dir.writeFile(.{
        .sub_path = "vc-board.app/Contents/MacOS/vc-board",
        .data = "",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "vc-board.app/Contents/Info.plist",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.vibecrafted.vc-board</string>
        \\</dict>
        \\</plist>
        ,
    });

    const exe_path = try tmp.dir.realpathAlloc(
        std.testing.allocator,
        "vc-board.app/Contents/MacOS/vc-board",
    );
    defer std.testing.allocator.free(exe_path);

    const layout = try detectLayoutForExePath(std.testing.allocator, exe_path);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(.macos_app, layout.kind);
    try std.testing.expect(layout.root_dir != null);
    try std.testing.expect(layout.helpers_dir != null);
    try std.testing.expect(layout.skills_dir != null);
    try std.testing.expect(layout.bundled_config_path != null);
    try std.testing.expect(layout.plist_path != null);
}
