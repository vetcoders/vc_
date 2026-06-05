//! Standalone demo binary for the vibecrafted operator TUI (Track T3 Phase 1).
//!
//! Pure presenter over the state machines in `apprt/vibecrafted/tui/`. No
//! runtime, no apprt hook, no Ghostty surface — `Tui` is initialized with
//! hardcoded sample data and the binary just renders the active tab and
//! routes Tab/Shift+Tab/q to the state machine. ANSI escapes for cell-grid
//! emulation, std.posix termios for raw input. Compiles without the Ghostty
//! shared deps so it stays gate-clean even while the workspace `zig build
//! test` is blocked on T2-lane wiring.
//!
//! Smoke flow (Phase 1 gate):
//!   `zig build vc-board-tui-mock && ./zig-out/bin/vc-board-tui-mock`
//!   → header shows `[Monitor] [Dispatch] [Controls]` with active tab inverse.
//!   → Tab cycles Monitor → Dispatch → Controls → Monitor.
//!   → Shift+Tab cycles backward.
//!   → q or Esc restores the terminal and exits cleanly.
//!
//! Non-TTY fallback: when stdout/stdin is not a terminal (CI, pipes), the
//! binary renders each tab once to stdout and exits, so `vc-board-tui-mock |
//! head` is a sufficient build-time smoke check.

const std = @import("std");
const builtin = @import("builtin");

const tui = @import("apprt/vibecrafted/tui/tui.zig");
const monitor_mod = @import("apprt/vibecrafted/tui/monitor.zig");
const dispatch_mod = @import("apprt/vibecrafted/tui/dispatch.zig");
const controls_mod = @import("apprt/vibecrafted/tui/controls.zig");

const sample_runs = [_]monitor_mod.RunSummary{
    .{ .run_id = "marb-181048", .agent = "claude", .kind = .active, .age_label = "now", .display_state = "running" },
    .{ .run_id = "marb-181616", .agent = "codex", .kind = .stalled, .age_label = "5m ago", .display_state = "stalled" },
    .{ .run_id = "marb-175511", .agent = "claude", .kind = .completed, .age_label = "55m ago", .display_state = "done" },
};

const sample_actions = [_]controls_mod.DeepAction{
    .{ .attach_session = "operator-181048" },
    .{ .resume_session = .{ .agent = "claude", .session = "marb-175511" } },
    .{ .open_report = "/Users/me/.vibecrafted/artifacts/.../latest.md" },
    .{ .open_root = "/Users/me/Libraxis/vc-runtime/vc-board" },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var t = tui.Tui.init(allocator);
    defer t.deinit();

    try t.monitor.setRuns(&sample_runs);
    try t.controls.setActions(&sample_actions);

    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writerStreaming(std.Options.debug_io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const stdin = std.Io.File.stdin();

    if (!try stdin.isTty(std.Options.debug_io) or !try stdout_file.isTty(std.Options.debug_io)) {
        try renderAllTabsOnce(stdout, &t);
        try stdout.flush();
        return;
    }

    const orig_termios = try std.posix.tcgetattr(stdin.handle);
    defer std.posix.tcsetattr(stdin.handle, .NOW, orig_termios) catch {};

    var raw = orig_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .NOW, raw);

    try stdout.writeAll("\x1b[?25l");
    defer {
        stdout.writeAll("\x1b[?25h\x1b[0m\n") catch {};
    }

    var key_buf: [8]u8 = undefined;
    while (true) {
        try renderActiveTab(stdout, &t);
        try stdout.flush();

        const n = try std.posix.read(stdin.handle, &key_buf);
        if (n == 0) continue;

        const ch = key_buf[0];
        if (ch == 'q' or ch == 'Q' or ch == 0x03) break;
        if (ch == 0x09) {
            t.nextTab();
            continue;
        }
        if (ch == 0x1b) {
            if (n == 1) break;
            if (n >= 3 and key_buf[1] == '[' and key_buf[2] == 'Z') {
                t.previousTab();
                continue;
            }
        }
    }
}

fn renderAllTabsOnce(w: *std.Io.Writer, t: *tui.Tui) !void {
    for ([_]tui.Tab{ .monitor, .dispatch, .controls }) |kind| {
        t.setActiveTab(kind);
        try renderActiveTab(w, t);
        try w.writeAll("\n");
    }
}

fn renderActiveTab(w: *std.Io.Writer, t: *tui.Tui) !void {
    try w.writeAll("\x1b[2J\x1b[H");
    try w.writeAll("vc-board-tui-mock  T3 P1 — state-only presenter (Vibecrafted.)\n\n");
    try renderTabBar(w, t.activeTab());
    try w.writeAll("\n");
    switch (t.activeTab()) {
        .monitor => try renderMonitor(w, &t.monitor),
        .dispatch => try renderDispatch(w, &t.dispatch),
        .controls => try renderControls(w, &t.controls),
    }
    try w.writeAll("\n\x1b[2m  Tab=next  Shift+Tab=prev  q=quit  \x1b[0m\n");
}

fn renderTabBar(w: *std.Io.Writer, active: tui.Tab) !void {
    for ([_]tui.Tab{ .monitor, .dispatch, .controls }) |kind| {
        if (kind == active) {
            try w.print("\x1b[7m  {s}  \x1b[0m ", .{kind.label()});
        } else {
            try w.print("  {s}   ", .{kind.label()});
        }
    }
    try w.writeAll("\n");
}

fn renderMonitor(w: *std.Io.Writer, state: *const monitor_mod.MonitorState) !void {
    const counts = state.statusCounts();
    try w.print(" Runs: total={d} live={d} (active={d} stalled={d} completed={d})\n\n", .{
        counts[7],
        state.activeRunCount(),
        counts[monitor_mod.RunKind.active.sortRank()],
        counts[monitor_mod.RunKind.stalled.sortRank()],
        counts[monitor_mod.RunKind.completed.sortRank()],
    });
    for (state.runs.items, 0..) |run, i| {
        const marker = if (i == state.selected) "▶" else " ";
        try w.print(" {s} {s:<14} {s:<8} {s:<10} {s}\n", .{
            marker, run.run_id, run.agent, run.kind.label(), run.age_label,
        });
    }
    if (state.runs.items.len == 0) try w.writeAll(" (no runs in mock data)\n");
}

fn renderDispatch(w: *std.Io.Writer, state: *const dispatch_mod.DispatchState) !void {
    try w.print(" Launch form  (focus={s})\n\n", .{@tagName(state.focus)});
    try fieldLine(w, "Kind", state.focus == .kind, state.kind.humanTitle());
    try fieldLine(w, "Agent", state.focus == .agent, state.agent.label());
    try fieldLine(w, "Runtime", state.focus == .runtime, state.runtime.label());
    try fieldLine(w, "Prompt", state.focus == .prompt, state.prompt());
    try w.print("\n  History: {d} entr{s}\n", .{
        state.historyLen(),
        if (state.historyLen() == 1) "y" else "ies",
    });
}

fn fieldLine(w: *std.Io.Writer, label: []const u8, focused: bool, value: []const u8) !void {
    const marker = if (focused) "▶" else " ";
    try w.print(" {s} {s:<8} {s}\n", .{ marker, label, value });
}

fn renderControls(w: *std.Io.Writer, state: *const controls_mod.ControlsState) !void {
    try w.print(" Deep actions ({d})\n\n", .{state.actions.items.len});
    for (state.actions.items, 0..) |action, i| {
        const marker = if (i == state.selected) "▶" else " ";
        try w.print(" {s} [{s:<10}] {s}\n", .{ marker, action.kindLabel(), describeAction(action) });
    }
    if (state.actions.items.len == 0) try w.writeAll(" (no deep actions in mock data)\n");
}

fn describeAction(action: controls_mod.DeepAction) []const u8 {
    return switch (action) {
        .attach_session => |s| s,
        .resume_session => |payload| payload.session,
        .open_report => |p| p,
        .open_transcript => |p| p,
        .open_root => |p| p,
    };
}
