//! Monitor-tab state machine for the vibecrafted operator TUI (Track T3).
//!
//! Pure state: the module owns a run-list cursor, a filter toggle, and the
//! classification enum. It does not read the control-plane directory, parse
//! JSON, or render. Callers feed pre-classified `RunSummary` values; timing
//! and I/O belong to the runtime layer (T4) so this layer stays trivially
//! testable under the workspace `zig build test`.
//!
//! Contract ported from `vc-operator/src/state.rs` (`RunKind`, sort rank,
//! active-like classification surface) and `vc-operator/src/app.rs`
//! (`selected`, `move_selection`, `filter_active_only`, `status_summary`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RunKind = enum(u8) {
    active = 0,
    stalled = 1,
    failed = 2,
    paused = 3,
    recent = 4,
    completed = 5,
    unknown = 6,

    pub fn label(self: RunKind) []const u8 {
        return switch (self) {
            .active => "active",
            .stalled => "stalled",
            .failed => "failed",
            .paused => "paused",
            .recent => "recent",
            .completed => "completed",
            .unknown => "unknown",
        };
    }

    pub fn sortRank(self: RunKind) u8 {
        return @intFromEnum(self);
    }

    pub fn isLive(self: RunKind) bool {
        return switch (self) {
            .active, .stalled, .paused => true,
            else => false,
        };
    }
};

/// Minimal, lifetime-agnostic projection of a control-plane run. Slice fields
/// must outlive the `MonitorState` that borrows them (callers own memory).
pub const RunSummary = struct {
    run_id: []const u8,
    agent: []const u8 = "unknown",
    kind: RunKind = .unknown,
    age_label: []const u8 = "age unknown",
    display_state: []const u8 = "unknown",
};

pub const MonitorState = struct {
    const Self = @This();
    const List = std.ArrayList(RunSummary);

    allocator: Allocator,
    runs: List = .empty,
    selected: usize = 0,
    filter_active_only: bool = false,

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.runs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Replace the current run list with a caller-owned slice and reset
    /// selection bounds. Borrowed slices must remain valid for the lifetime
    /// of this state or until the next `setRuns` call.
    pub fn setRuns(self: *Self, runs: []const RunSummary) Allocator.Error!void {
        self.runs.clearRetainingCapacity();
        try self.runs.ensureTotalCapacity(self.allocator, runs.len);
        for (runs) |run| self.runs.appendAssumeCapacity(run);
        self.syncSelection();
    }

    pub fn selectedRun(self: *const Self) ?RunSummary {
        if (self.runs.items.len == 0) return null;
        return self.runs.items[self.selected];
    }

    pub fn moveSelection(self: *Self, delta: isize) void {
        if (self.runs.items.len == 0) {
            self.selected = 0;
            return;
        }
        const len: isize = @intCast(self.runs.items.len);
        var index = @as(isize, @intCast(self.selected)) + delta;
        if (index < 0) index = len - 1;
        if (index >= len) index = 0;
        self.selected = @intCast(index);
    }

    pub fn toggleFilter(self: *Self) void {
        self.filter_active_only = !self.filter_active_only;
        self.syncSelection();
    }

    pub fn activeRunCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.runs.items) |run| if (run.kind.isLive()) {
            count += 1;
        };
        return count;
    }

    /// Counts by kind in `sortRank` order, no heap allocation. Slot 7 holds
    /// the total; callers decide how to render the tuple.
    pub fn statusCounts(self: *const Self) [8]usize {
        var counts: [8]usize = @splat(0);
        for (self.runs.items) |run| counts[run.kind.sortRank()] += 1;
        counts[7] = self.runs.items.len;
        return counts;
    }

    fn syncSelection(self: *Self) void {
        if (self.runs.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.runs.items.len) {
            self.selected = self.runs.items.len - 1;
        }
    }
};

fn sample() [3]RunSummary {
    return .{
        .{ .run_id = "marb-01", .agent = "claude", .kind = .active, .age_label = "2m ago", .display_state = "running" },
        .{ .run_id = "marb-02", .agent = "codex", .kind = .stalled, .age_label = "23m ago", .display_state = "stalled" },
        .{ .run_id = "marb-03", .agent = "gemini", .kind = .completed, .age_label = "1h ago", .display_state = "done" },
    };
}

test "RunKind sort rank matches Rust operator layout" {
    try std.testing.expectEqual(@as(u8, 0), RunKind.active.sortRank());
    try std.testing.expectEqual(@as(u8, 1), RunKind.stalled.sortRank());
    try std.testing.expectEqual(@as(u8, 2), RunKind.failed.sortRank());
    try std.testing.expectEqual(@as(u8, 3), RunKind.paused.sortRank());
    try std.testing.expectEqual(@as(u8, 4), RunKind.recent.sortRank());
    try std.testing.expectEqual(@as(u8, 5), RunKind.completed.sortRank());
    try std.testing.expectEqual(@as(u8, 6), RunKind.unknown.sortRank());
}

test "RunKind.isLive covers active, stalled, paused" {
    try std.testing.expect(RunKind.active.isLive());
    try std.testing.expect(RunKind.stalled.isLive());
    try std.testing.expect(RunKind.paused.isLive());
    try std.testing.expect(!RunKind.failed.isLive());
    try std.testing.expect(!RunKind.completed.isLive());
    try std.testing.expect(!RunKind.recent.isLive());
    try std.testing.expect(!RunKind.unknown.isLive());
}

test "MonitorState: setRuns populates and clamps selection" {
    var state = MonitorState.init(std.testing.allocator);
    defer state.deinit();

    state.selected = 42;
    const runs = sample();
    try state.setRuns(&runs);

    try std.testing.expectEqual(@as(usize, 3), state.runs.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    try std.testing.expectEqualStrings("marb-03", state.selectedRun().?.run_id);
}

test "MonitorState: moveSelection wraps at both ends" {
    var state = MonitorState.init(std.testing.allocator);
    defer state.deinit();

    const runs = sample();
    try state.setRuns(&runs);
    state.selected = 0;

    state.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 1), state.selected);
}

test "MonitorState: empty list pins selection to zero" {
    var state = MonitorState.init(std.testing.allocator);
    defer state.deinit();

    state.moveSelection(5);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expect(state.selectedRun() == null);
}

test "MonitorState: statusCounts and activeRunCount" {
    var state = MonitorState.init(std.testing.allocator);
    defer state.deinit();

    const runs = sample();
    try state.setRuns(&runs);

    const counts = state.statusCounts();
    try std.testing.expectEqual(@as(usize, 1), counts[RunKind.active.sortRank()]);
    try std.testing.expectEqual(@as(usize, 1), counts[RunKind.stalled.sortRank()]);
    try std.testing.expectEqual(@as(usize, 1), counts[RunKind.completed.sortRank()]);
    try std.testing.expectEqual(@as(usize, 3), counts[7]);
    try std.testing.expectEqual(@as(usize, 2), state.activeRunCount());
}

test "MonitorState: toggleFilter flips boolean without losing runs" {
    var state = MonitorState.init(std.testing.allocator);
    defer state.deinit();

    const runs = sample();
    try state.setRuns(&runs);

    try std.testing.expect(!state.filter_active_only);
    state.toggleFilter();
    try std.testing.expect(state.filter_active_only);
    try std.testing.expectEqual(@as(usize, 3), state.runs.items.len);
}
