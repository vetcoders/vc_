//! Root aggregator for the vibecrafted operator TUI (Track T3).
//!
//! Owns the three tab-local state machines (Monitor, Dispatch, Controls) plus
//! the shared `TabState` that routes tab switches. No rendering, no input
//! glue: this is the state contract that T1/T2 (apprt, panels) attach to in
//! later phases. Wired into `apprt/vibecrafted.zig` so workspace-level
//! `zig build test` exercises every invariant in `tabs.zig` +
//! `monitor.zig` + `dispatch.zig` + `controls.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const tabs = @import("tabs.zig");
pub const monitor = @import("monitor.zig");
pub const dispatch = @import("dispatch.zig");
pub const controls = @import("controls.zig");

pub const Tab = tabs.Tab;
pub const Focus = tabs.Focus;
pub const TabState = tabs.TabState;
pub const DispatchFocus = tabs.DispatchFocus;

pub const RunKind = monitor.RunKind;
pub const RunSummary = monitor.RunSummary;
pub const MonitorState = monitor.MonitorState;

pub const LaunchKind = dispatch.LaunchKind;
pub const AgentId = dispatch.AgentId;
pub const LaunchRuntime = dispatch.LaunchRuntime;
pub const DispatchState = dispatch.DispatchState;

pub const DeepAction = controls.DeepAction;
pub const ControlsState = controls.ControlsState;

pub const Tui = struct {
    const Self = @This();

    allocator: Allocator,
    tab: TabState = .{},
    monitor: MonitorState,
    dispatch: DispatchState,
    controls: ControlsState,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .monitor = MonitorState.init(allocator),
            .dispatch = DispatchState.init(),
            .controls = ControlsState.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.monitor.deinit();
        self.controls.deinit();
        self.* = undefined;
    }

    pub fn activeTab(self: *const Self) Tab {
        return self.tab.active;
    }

    pub fn nextTab(self: *Self) void {
        self.tab.next();
    }

    pub fn previousTab(self: *Self) void {
        self.tab.previous();
    }

    pub fn setActiveTab(self: *Self, tab_value: Tab) void {
        self.tab.setActive(tab_value);
    }
};

test "Tui: lifecycle + tab routing exercises every panel" {
    var tui = Tui.init(std.testing.allocator);
    defer tui.deinit();

    // Tab routing through the whole cycle.
    try std.testing.expectEqual(Tab.monitor, tui.activeTab());
    tui.nextTab();
    try std.testing.expectEqual(Tab.dispatch, tui.activeTab());
    tui.nextTab();
    try std.testing.expectEqual(Tab.controls, tui.activeTab());
    tui.nextTab();
    try std.testing.expectEqual(Tab.monitor, tui.activeTab());
    tui.previousTab();
    try std.testing.expectEqual(Tab.controls, tui.activeTab());
    tui.setActiveTab(.dispatch);
    try std.testing.expectEqual(Tab.dispatch, tui.activeTab());

    // Monitor: small live run list.
    const runs = [_]RunSummary{
        .{ .run_id = "marb-01", .agent = "claude", .kind = .active },
        .{ .run_id = "marb-02", .agent = "codex", .kind = .stalled },
    };
    try tui.monitor.setRuns(&runs);
    tui.monitor.moveSelection(1);
    try std.testing.expectEqualStrings("marb-02", tui.monitor.selectedRun().?.run_id);

    // Dispatch: form cycling matches invariant.
    tui.dispatch.focus = .agent;
    tui.dispatch.adjustFocused(1);
    try std.testing.expectEqual(AgentId.codex, tui.dispatch.agent);

    // Controls: deep action cursor.
    const actions = [_]DeepAction{
        .{ .attach_session = "sess-1" },
        .{ .open_report = "/tmp/report.md" },
    };
    try tui.controls.setActions(&actions);
    try std.testing.expect(tui.controls.selectedAction() != null);
}

test "Tui: focus invariant — tab change resets Dispatch form focus back to browse" {
    // The Focus invariant lives in tabs.zig, but the Tui wrapper also holds
    // a DispatchState with its own per-tab cursor. Verify they cohere: when
    // tabs rotate, the shared top-level Focus resets while the dispatch
    // focus (inside the form) is preserved for when the user returns.
    var tui = Tui.init(std.testing.allocator);
    defer tui.deinit();

    tui.dispatch.focus = .runtime;
    tui.tab.focus = .edit_prompt;

    tui.nextTab();
    try std.testing.expectEqual(Focus.browse, tui.tab.focus);
    try std.testing.expectEqual(DispatchFocus.runtime, tui.dispatch.focus);

    tui.setActiveTab(.dispatch);
    try std.testing.expectEqual(DispatchFocus.runtime, tui.dispatch.focus);
}

test {
    std.testing.refAllDecls(@This());
}
