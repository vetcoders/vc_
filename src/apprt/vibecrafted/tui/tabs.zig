//! Tab state machine for the vibecrafted operator TUI (Track T3).
//!
//! Pure state: no rendering, no I/O, no Ghostty surface or runtime coupling.
//! This is the load-bearing contract every T3 surface (Monitor/Dispatch/
//! Controls) hangs on — tab order, wrap semantics, and the focus-reset
//! invariant on tab changes. Ported from `vc-operator/src/app.rs` AppTab
//! (enum + TITLES + from_index/index + next_tab/previous_tab) so Rust and
//! Zig observers see the same three labels in the same three positions.
//!
//! The module intentionally avoids any `build.zig` wire-up: T1 (apprt root)
//! has not landed yet, and attaching production build paths belongs to T1.
//! `zig test src/apprt/vibecrafted/tui/tabs.zig` runs the invariant tests
//! standalone.

const std = @import("std");

pub const Tab = enum(u8) {
    monitor = 0,
    dispatch = 1,
    controls = 2,

    pub const count: usize = 3;
    pub const titles = [count][]const u8{ "Monitor", "Dispatch", "Controls" };

    pub fn label(self: Tab) []const u8 {
        return titles[@intFromEnum(self)];
    }

    pub fn index(self: Tab) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(idx: usize) Tab {
        return @enumFromInt(@as(u8, @intCast(idx % count)));
    }
};

/// Top-level focus bucket: which surface element receives keyboard input
/// across all tabs. Reset to `browse` on every tab change to match the
/// Rust predecessor's behavior (`LaunchFocus::Browse` after next/prev tab).
pub const Focus = enum {
    browse,
    edit_prompt,
    help,

    pub const default_on_tab_change: Focus = .browse;
};

/// Tab-local focus inside the Dispatch form. Kept here (not in
/// `dispatch.zig`) so the wider state machine can reason about field
/// cycling without depending on the Dispatch implementation module.
pub const DispatchFocus = enum(u8) {
    kind = 0,
    agent = 1,
    runtime = 2,
    prompt = 3,

    pub const count: usize = 4;

    pub fn fromIndex(idx: usize) DispatchFocus {
        return @enumFromInt(@as(u8, @intCast(idx % count)));
    }
};

pub const TabState = struct {
    active: Tab = .monitor,
    focus: Focus = .browse,

    pub fn next(self: *TabState) void {
        self.active = Tab.fromIndex(self.active.index() + 1);
        self.focus = Focus.default_on_tab_change;
    }

    pub fn previous(self: *TabState) void {
        const current = self.active.index();
        const prev = if (current == 0) Tab.count - 1 else current - 1;
        self.active = Tab.fromIndex(prev);
        self.focus = Focus.default_on_tab_change;
    }

    pub fn setActive(self: *TabState, tab: Tab) void {
        self.active = tab;
        self.focus = Focus.default_on_tab_change;
    }
};

test "Tab index bijection matches Rust operator-tui layout" {
    try std.testing.expectEqual(@as(usize, 0), Tab.monitor.index());
    try std.testing.expectEqual(@as(usize, 1), Tab.dispatch.index());
    try std.testing.expectEqual(@as(usize, 2), Tab.controls.index());
    try std.testing.expectEqual(Tab.monitor, Tab.fromIndex(0));
    try std.testing.expectEqual(Tab.dispatch, Tab.fromIndex(1));
    try std.testing.expectEqual(Tab.controls, Tab.fromIndex(2));
}

test "Tab labels match TITLES constants" {
    try std.testing.expectEqualStrings("Monitor", Tab.monitor.label());
    try std.testing.expectEqualStrings("Dispatch", Tab.dispatch.label());
    try std.testing.expectEqualStrings("Controls", Tab.controls.label());
    try std.testing.expectEqual(@as(usize, 3), Tab.titles.len);
}

test "Tab.fromIndex wraps modulo count" {
    try std.testing.expectEqual(Tab.monitor, Tab.fromIndex(3));
    try std.testing.expectEqual(Tab.dispatch, Tab.fromIndex(4));
    try std.testing.expectEqual(Tab.controls, Tab.fromIndex(5));
    try std.testing.expectEqual(Tab.monitor, Tab.fromIndex(300));
}

test "TabState.next cycles forward with wrap" {
    var s = TabState{};
    try std.testing.expectEqual(Tab.monitor, s.active);
    s.next();
    try std.testing.expectEqual(Tab.dispatch, s.active);
    s.next();
    try std.testing.expectEqual(Tab.controls, s.active);
    s.next();
    try std.testing.expectEqual(Tab.monitor, s.active);
}

test "TabState.previous wraps backward through zero" {
    var s = TabState{};
    try std.testing.expectEqual(Tab.monitor, s.active);
    s.previous();
    try std.testing.expectEqual(Tab.controls, s.active);
    s.previous();
    try std.testing.expectEqual(Tab.dispatch, s.active);
    s.previous();
    try std.testing.expectEqual(Tab.monitor, s.active);
}

test "TabState resets focus on every tab change" {
    var s = TabState{ .focus = .edit_prompt };
    s.next();
    try std.testing.expectEqual(Focus.browse, s.focus);

    s.focus = .help;
    s.previous();
    try std.testing.expectEqual(Focus.browse, s.focus);

    s.focus = .edit_prompt;
    s.setActive(.dispatch);
    try std.testing.expectEqual(Focus.browse, s.focus);
}

test "TabState.setActive jumps directly without cycling" {
    var s = TabState{};
    s.setActive(.controls);
    try std.testing.expectEqual(Tab.controls, s.active);
    s.setActive(.monitor);
    try std.testing.expectEqual(Tab.monitor, s.active);
}

test "DispatchFocus order matches Rust DispatchFocus" {
    try std.testing.expectEqual(DispatchFocus.kind, DispatchFocus.fromIndex(0));
    try std.testing.expectEqual(DispatchFocus.agent, DispatchFocus.fromIndex(1));
    try std.testing.expectEqual(DispatchFocus.runtime, DispatchFocus.fromIndex(2));
    try std.testing.expectEqual(DispatchFocus.prompt, DispatchFocus.fromIndex(3));
    try std.testing.expectEqual(@as(usize, 4), DispatchFocus.count);
}

test "DispatchFocus.fromIndex wraps modulo count" {
    try std.testing.expectEqual(DispatchFocus.kind, DispatchFocus.fromIndex(4));
    try std.testing.expectEqual(DispatchFocus.agent, DispatchFocus.fromIndex(5));
    try std.testing.expectEqual(DispatchFocus.kind, DispatchFocus.fromIndex(400));
}
