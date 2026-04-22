//! Controls-tab state machine for the vibecrafted operator TUI (Track T3).
//!
//! Deep-action list + selection cursor, ported from
//! `vc-operator/src/app.rs` (`DeepAction`, `deep_actions`, `deep_selected`,
//! `move_deep_selection`). Each variant carries a caller-owned slice: the
//! state machine only cares about enumeration, selection, and wrap semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DeepAction = union(enum) {
    attach_session: []const u8,
    resume_session: struct {
        agent: []const u8,
        session: []const u8,
    },
    open_report: []const u8,
    open_transcript: []const u8,
    open_root: []const u8,

    pub fn kindLabel(self: DeepAction) []const u8 {
        return switch (self) {
            .attach_session => "attach",
            .resume_session => "resume",
            .open_report => "report",
            .open_transcript => "transcript",
            .open_root => "root",
        };
    }
};

pub const ControlsState = struct {
    const Self = @This();
    const List = std.ArrayList(DeepAction);

    allocator: Allocator,
    actions: List = .empty,
    selected: usize = 0,

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.actions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setActions(self: *Self, actions: []const DeepAction) Allocator.Error!void {
        self.actions.clearRetainingCapacity();
        try self.actions.ensureTotalCapacity(self.allocator, actions.len);
        for (actions) |action| self.actions.appendAssumeCapacity(action);
        self.syncSelection();
    }

    pub fn selectedAction(self: *const Self) ?DeepAction {
        if (self.actions.items.len == 0) return null;
        return self.actions.items[self.selected];
    }

    pub fn moveSelection(self: *Self, delta: isize) void {
        if (self.actions.items.len == 0) {
            self.selected = 0;
            return;
        }
        const len: isize = @intCast(self.actions.items.len);
        var index = @as(isize, @intCast(self.selected)) + delta;
        if (index < 0) index = len - 1;
        if (index >= len) index = 0;
        self.selected = @intCast(index);
    }

    fn syncSelection(self: *Self) void {
        if (self.actions.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.actions.items.len) {
            self.selected = self.actions.items.len - 1;
        }
    }
};

test "DeepAction.kindLabel enumerates every variant" {
    try std.testing.expectEqualStrings("attach", (DeepAction{ .attach_session = "s" }).kindLabel());
    try std.testing.expectEqualStrings(
        "resume",
        (DeepAction{ .resume_session = .{ .agent = "claude", .session = "s" } }).kindLabel(),
    );
    try std.testing.expectEqualStrings("report", (DeepAction{ .open_report = "r" }).kindLabel());
    try std.testing.expectEqualStrings("transcript", (DeepAction{ .open_transcript = "t" }).kindLabel());
    try std.testing.expectEqualStrings("root", (DeepAction{ .open_root = "/tmp" }).kindLabel());
}

test "ControlsState: setActions populates + clamps selection" {
    var state = ControlsState.init(std.testing.allocator);
    defer state.deinit();

    state.selected = 99;
    const actions = [_]DeepAction{
        .{ .attach_session = "sess-1" },
        .{ .open_report = "/tmp/report.md" },
    };
    try state.setActions(&actions);

    try std.testing.expectEqual(@as(usize, 2), state.actions.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.selected);
}

test "ControlsState: moveSelection wraps" {
    var state = ControlsState.init(std.testing.allocator);
    defer state.deinit();

    const actions = [_]DeepAction{
        .{ .attach_session = "a" },
        .{ .open_report = "b" },
        .{ .open_root = "c" },
    };
    try state.setActions(&actions);
    state.selected = 0;

    state.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.moveSelection(2);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
}

test "ControlsState: empty list yields null + pinned selection" {
    var state = ControlsState.init(std.testing.allocator);
    defer state.deinit();

    state.moveSelection(5);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expect(state.selectedAction() == null);
}

test "ControlsState: selectedAction returns the union at cursor" {
    var state = ControlsState.init(std.testing.allocator);
    defer state.deinit();

    const actions = [_]DeepAction{
        .{ .attach_session = "sess" },
        .{ .resume_session = .{ .agent = "claude", .session = "abc" } },
    };
    try state.setActions(&actions);
    state.selected = 1;

    const picked = state.selectedAction().?;
    switch (picked) {
        .resume_session => |payload| {
            try std.testing.expectEqualStrings("claude", payload.agent);
            try std.testing.expectEqualStrings("abc", payload.session);
        },
        else => try std.testing.expect(false),
    }
}
