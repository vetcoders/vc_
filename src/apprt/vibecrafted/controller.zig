const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const keymap = @import("keymap.zig");
const panels_mod = @import("panels.zig");

pub const PanelId = panels_mod.PanelId;
pub const TabId = panels_mod.TabId;
pub const Panels = panels_mod.Panels;
pub const Panel = panels_mod.Panel;
pub const SplitDirection = panels_mod.SplitDirection;
pub const FocusDirection = panels_mod.FocusDirection;

pub const SurfaceKind = enum {
    pty,
    custom_tui,
};

pub const InputTarget = struct {
    panel_id: PanelId,
    kind: SurfaceKind,
};

pub const SplitOutcome = struct {
    direction: SplitDirection,
    source_panel_id: PanelId,
    new_panel: InputTarget,
};

pub const FocusOutcome = struct {
    direction: FocusDirection,
    target: InputTarget,
};

pub const CloseOutcome = union(enum) {
    none,
    closed: struct {
        panel_id: PanelId,
        next_focus: InputTarget,
    },
    emptied: PanelId,
};

pub const RouteResult = union(enum) {
    none,
    binding_noop: keymap.Action,
    split: SplitOutcome,
    focus: FocusOutcome,
    close: CloseOutcome,
    forwarded: InputTarget,
};

pub const TabController = struct {
    id: TabId,
    name: []const u8,
    controller: Controller,

    fn init(allocator: Allocator, id: TabId, name: []const u8) !*TabController {
        const tab = try allocator.create(TabController);
        errdefer allocator.destroy(tab);

        tab.* = .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .controller = Controller.init(allocator),
        };
        return tab;
    }

    fn deinit(self: *TabController, allocator: Allocator) void {
        self.controller.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn activePanelName(self: *const TabController) ?[]const u8 {
        return self.controller.panels.activePanelName();
    }

    pub fn activePaneName(self: *const TabController) ?[]const u8 {
        return self.activePanelName();
    }

    pub fn activeInputTarget(self: *const TabController) ?InputTarget {
        return self.controller.activeInputTarget();
    }
};

pub const WorkspaceController = struct {
    const Self = @This();

    pub const SpawnedMarblesPanel = struct {
        tab_id: TabId,
        tab_name: []const u8,
        panel_id: PanelId,
        pane_name: []const u8,
        target: InputTarget,
    };

    pub const ValidateError = Controller.ValidateError || error{
        ActiveOnEmptyWorkspace,
        MissingActiveTab,
        DuplicateTabId,
        DuplicateTabName,
        ActiveMissingFromWorkspace,
        NextTabIdRegressed,
    };

    allocator: Allocator,
    tabs: std.ArrayListUnmanaged(*TabController) = .{},
    active_tab_id: ?TabId = null,
    next_tab_id: TabId = 1,

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.tabs.items) |workspace_tab| workspace_tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn tabCount(self: *const Self) usize {
        return self.tabs.items.len;
    }

    pub fn activeTab(self: *const Self) ?*TabController {
        const id = self.active_tab_id orelse return null;
        return self.tab(id);
    }

    pub fn activeInputTarget(self: *const Self) ?InputTarget {
        const tab = self.activeTab() orelse return null;
        return tab.activeInputTarget();
    }

    pub fn tab(self: *const Self, id: TabId) ?*TabController {
        for (self.tabs.items) |workspace_tab| {
            if (workspace_tab.id == id) return workspace_tab;
        }
        return null;
    }

    pub fn findTabByName(self: *const Self, name: []const u8) ?*TabController {
        for (self.tabs.items) |workspace_tab| {
            if (std.mem.eql(u8, workspace_tab.name, name)) return workspace_tab;
        }
        return null;
    }

    pub fn activateTab(self: *Self, id: TabId) error{UnknownTab}!void {
        if (self.tab(id) == null) return error.UnknownTab;
        self.active_tab_id = id;
    }

    pub fn findOrCreateTab(self: *Self, name: []const u8) !*TabController {
        if (self.findTabByName(name)) |existing| {
            self.active_tab_id = existing.id;
            return existing;
        }

        const id = self.next_tab_id;
        errdefer self.next_tab_id = id;
        self.next_tab_id += 1;

        const workspace_tab = try TabController.init(self.allocator, id, name);
        errdefer workspace_tab.deinit(self.allocator);

        try self.tabs.append(self.allocator, workspace_tab);
        self.active_tab_id = workspace_tab.id;
        return workspace_tab;
    }

    pub fn marblesTab(self: *Self, run_id: []const u8) !*TabController {
        return self.marblesTabInherited(run_id, null);
    }

    pub fn marblesTabInherited(
        self: *Self,
        run_id: []const u8,
        inherited_tab_name: ?[]const u8,
    ) !*TabController {
        const tab_name = try panels_mod.marblesTabName(
            self.allocator,
            run_id,
            inherited_tab_name,
        );
        defer self.allocator.free(tab_name);
        return self.findOrCreateTab(tab_name);
    }

    pub fn spawnMarblesPanel(
        self: *Self,
        run_id: []const u8,
        loop_nr: usize,
        direction: SplitDirection,
        kind: SurfaceKind,
        inherited_tab_name: ?[]const u8,
    ) !SpawnedMarblesPanel {
        const workspace_tab = try self.marblesTabInherited(run_id, inherited_tab_name);
        const pane_name = try panels_mod.marblesPaneName(self.allocator, run_id, loop_nr);
        defer self.allocator.free(pane_name);

        const target = if (workspace_tab.controller.isEmpty())
            try workspace_tab.controller.createInitialNamed(kind, pane_name)
        else
            (try workspace_tab.controller.splitActiveNamed(direction, kind, pane_name)).new_panel;

        return .{
            .tab_id = workspace_tab.id,
            .tab_name = workspace_tab.name,
            .panel_id = target.panel_id,
            .pane_name = workspace_tab.controller.panel(target.panel_id).?.name(),
            .target = target,
        };
    }

    pub fn routeKeyEvent(self: *Self, event: input.KeyEvent) !RouteResult {
        const workspace_tab = self.activeTab() orelse return .none;
        return workspace_tab.controller.routeKeyEvent(event);
    }

    pub fn validate(self: *const Self) ValidateError!void {
        if (self.tabs.items.len == 0) {
            if (self.active_tab_id != null) return error.ActiveOnEmptyWorkspace;
            return;
        }

        const active_tab_id = self.active_tab_id orelse return error.MissingActiveTab;
        var found_active = false;
        var max_id: TabId = 0;

        for (self.tabs.items) |workspace_tab| {
            if (workspace_tab.id == active_tab_id) found_active = true;
            max_id = @max(max_id, workspace_tab.id);
            try workspace_tab.controller.validate();

            var duplicate_ids: usize = 0;
            var duplicate_names: usize = 0;
            for (self.tabs.items) |other_tab| {
                if (other_tab.id == workspace_tab.id) duplicate_ids += 1;
                if (std.mem.eql(u8, other_tab.name, workspace_tab.name)) duplicate_names += 1;
            }
            if (duplicate_ids != 1) return error.DuplicateTabId;
            if (duplicate_names != 1) return error.DuplicateTabName;
        }

        if (!found_active) return error.ActiveMissingFromWorkspace;
        if (max_id >= self.next_tab_id) return error.NextTabIdRegressed;
    }
};

pub const Controller = struct {
    const Self = @This();

    pub const ValidateError = Panels.ValidateError || error{
        MetadataCountMismatch,
        MissingPanelMetadata,
        DanglingPanelMetadata,
    };

    allocator: Allocator,
    panels: Panels,
    surface_kinds: std.AutoHashMapUnmanaged(PanelId, SurfaceKind) = .{},
    default_surface_kind: SurfaceKind = .pty,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .panels = Panels.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.surface_kinds.deinit(self.allocator);
        self.panels.deinit();
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.panels.isEmpty();
    }

    pub fn panelCount(self: *const Self) usize {
        return self.panels.panelCount();
    }

    pub fn createInitial(self: *Self, kind: SurfaceKind) !InputTarget {
        var default_name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&default_name_buf, "panel-{d}", .{self.panels.next_panel_id}) catch unreachable;
        return self.createInitialNamed(kind, name);
    }

    pub fn createInitialNamed(
        self: *Self,
        kind: SurfaceKind,
        name: []const u8,
    ) !InputTarget {
        const id = try self.panels.createInitialNamed(name);
        try self.surface_kinds.put(self.allocator, id, kind);
        return .{ .panel_id = id, .kind = kind };
    }

    pub fn splitActive(
        self: *Self,
        direction: SplitDirection,
        kind: SurfaceKind,
    ) !SplitOutcome {
        var default_name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&default_name_buf, "panel-{d}", .{self.panels.next_panel_id}) catch unreachable;
        return self.splitActiveNamed(direction, kind, name);
    }

    pub fn splitActiveNamed(
        self: *Self,
        direction: SplitDirection,
        kind: SurfaceKind,
        name: []const u8,
    ) !SplitOutcome {
        const source = self.activeInputTarget() orelse return error.MissingActivePanel;
        const new_id = try self.panels.splitActiveNamed(direction, name);
        try self.surface_kinds.put(self.allocator, new_id, kind);
        return .{
            .direction = direction,
            .source_panel_id = source.panel_id,
            .new_panel = .{
                .panel_id = new_id,
                .kind = kind,
            },
        };
    }

    pub fn focus(self: *Self, direction: FocusDirection) !?FocusOutcome {
        if (!try self.panels.focus(direction)) return null;
        return .{
            .direction = direction,
            .target = (self.activeInputTarget() orelse return error.MissingActivePanel),
        };
    }

    pub fn closeActive(self: *Self) !CloseOutcome {
        const result = try self.panels.closeActive();
        return switch (result) {
            .none => .none,
            .closed => |panel_id| closed: {
                _ = self.surface_kinds.remove(panel_id);
                break :closed .{
                    .closed = .{
                        .panel_id = panel_id,
                        .next_focus = self.activeInputTarget() orelse return error.MissingActivePanel,
                    },
                };
            },
            .emptied => |panel_id| emptied: {
                _ = self.surface_kinds.remove(panel_id);
                break :emptied .{ .emptied = panel_id };
            },
        };
    }

    pub fn setSurfaceKind(
        self: *Self,
        panel_id: PanelId,
        kind: SurfaceKind,
    ) (Allocator.Error || error{UnknownPanel})!void {
        if (self.panels.panel(panel_id) == null) return error.UnknownPanel;
        try self.surface_kinds.put(self.allocator, panel_id, kind);
    }

    pub fn panelTarget(self: *const Self, panel_id: PanelId) ?InputTarget {
        _ = self.panels.panel(panel_id) orelse return null;
        const kind = self.surface_kinds.get(panel_id) orelse return null;
        return .{ .panel_id = panel_id, .kind = kind };
    }

    pub fn activeInputTarget(self: *const Self) ?InputTarget {
        const active_panel = self.panels.activePanel() orelse return null;
        return self.panelTarget(active_panel.id);
    }

    pub fn panel(self: *const Self, panel_id: PanelId) ?Panel {
        return self.panels.panel(panel_id);
    }

    pub fn routeKeyEvent(self: *Self, event: input.KeyEvent) !RouteResult {
        if (keymap.match(event)) |action| {
            return switch (action) {
                .split_horizontal => .{
                    .split = try self.splitActive(
                        .horizontal,
                        self.bindingSplitKind(),
                    ),
                },
                .split_vertical => .{
                    .split = try self.splitActive(
                        .vertical,
                        self.bindingSplitKind(),
                    ),
                },
                .focus_left => if (try self.focus(.left)) |outcome|
                    .{ .focus = outcome }
                else
                    .{ .binding_noop = action },
                .focus_right => if (try self.focus(.right)) |outcome|
                    .{ .focus = outcome }
                else
                    .{ .binding_noop = action },
                .focus_up => if (try self.focus(.up)) |outcome|
                    .{ .focus = outcome }
                else
                    .{ .binding_noop = action },
                .focus_down => if (try self.focus(.down)) |outcome|
                    .{ .focus = outcome }
                else
                    .{ .binding_noop = action },
                .close_active => close: {
                    const outcome = try self.closeActive();
                    break :close switch (outcome) {
                        .none => .{ .binding_noop = action },
                        else => .{ .close = outcome },
                    };
                },
            };
        }

        return if (self.activeInputTarget()) |target|
            .{ .forwarded = target }
        else
            .none;
    }

    pub fn validate(self: *const Self) ValidateError!void {
        try self.panels.validate();

        if (self.surface_kinds.count() != self.panels.panelCount()) {
            return error.MetadataCountMismatch;
        }

        var panel_it = self.panels.tree.iterator();
        while (panel_it.next()) |entry| {
            if (!self.surface_kinds.contains(entry.view.panel.id)) {
                return error.MissingPanelMetadata;
            }
        }

        var kind_it = self.surface_kinds.iterator();
        while (kind_it.next()) |entry| {
            if (self.panels.panel(entry.key_ptr.*) == null) {
                return error.DanglingPanelMetadata;
            }
        }
    }

    fn bindingSplitKind(self: *const Self) SurfaceKind {
        return if (self.activeInputTarget()) |target|
            target.kind
        else
            self.default_surface_kind;
    }
};

test "panels controller keeps surface kinds in sync with layout" {
    const testing = std.testing;

    var controller = Controller.init(testing.allocator);
    defer controller.deinit();

    const first = try controller.createInitial(.pty);
    try testing.expectEqual(SurfaceKind.pty, first.kind);
    try testing.expectEqual(@as(usize, 1), controller.panelCount());

    const second = try controller.splitActive(.horizontal, .custom_tui);
    try testing.expectEqual(first.panel_id, second.source_panel_id);
    try testing.expectEqual(SurfaceKind.custom_tui, second.new_panel.kind);
    try testing.expectEqual(second.new_panel, controller.activeInputTarget().?);
    try controller.validate();
}

test "panels controller routes non-binding keys to the active panel kind" {
    const testing = std.testing;

    var controller = Controller.init(testing.allocator);
    defer controller.deinit();

    _ = try controller.createInitial(.custom_tui);

    const result = try controller.routeKeyEvent(.{
        .key = .key_a,
        .unshifted_codepoint = 'a',
    });

    try testing.expectEqual(
        RouteResult{ .forwarded = .{ .panel_id = 1, .kind = .custom_tui } },
        result,
    );
}

test "panels controller reserves panel bindings and mutates layout" {
    const testing = std.testing;

    var controller = Controller.init(testing.allocator);
    defer controller.deinit();

    _ = try controller.createInitial(.pty);

    const split_result = try controller.routeKeyEvent(.{
        .key = .key_h,
        .mods = .{ .ctrl = true, .shift = true },
    });
    try testing.expectEqual(
        RouteResult{
            .split = .{
                .direction = .horizontal,
                .source_panel_id = 1,
                .new_panel = .{ .panel_id = 2, .kind = .pty },
            },
        },
        split_result,
    );

    const focus_result = try controller.routeKeyEvent(.{
        .key = .arrow_left,
        .mods = .{ .ctrl = true, .shift = true },
    });
    try testing.expectEqual(
        RouteResult{
            .focus = .{
                .direction = .left,
                .target = .{ .panel_id = 1, .kind = .pty },
            },
        },
        focus_result,
    );

    const close_result = try controller.routeKeyEvent(.{
        .key = .key_w,
        .mods = .{ .ctrl = true, .shift = true },
    });
    try testing.expectEqual(
        RouteResult{
            .close = .{
                .closed = .{
                    .panel_id = 1,
                    .next_focus = .{ .panel_id = 2, .kind = .pty },
                },
            },
        },
        close_result,
    );
    try controller.validate();
}

test "workspace controller keeps marbles tabs isolated and preserves surface kinds" {
    const testing = std.testing;

    var workspace = WorkspaceController.init(testing.allocator);
    defer workspace.deinit();

    const first = try workspace.spawnMarblesPanel(
        "marb-175510-002",
        1,
        .horizontal,
        .pty,
        null,
    );
    const second = try workspace.spawnMarblesPanel(
        "marb-175510-002",
        2,
        .vertical,
        .custom_tui,
        "marbles-some-other-run",
    );
    const third = try workspace.spawnMarblesPanel(
        "marb-175510-003",
        1,
        .horizontal,
        .pty,
        null,
    );

    try testing.expectEqual(@as(usize, 2), workspace.tabCount());
    try testing.expectEqual(first.tab_id, second.tab_id);
    try testing.expect(first.tab_id != third.tab_id);
    try testing.expectEqualStrings("marbles-marb-175510-002", first.tab_name);
    try testing.expectEqualStrings("marb-175510-002", first.pane_name);
    try testing.expectEqualStrings("marb-175510-002-2", second.pane_name);
    try testing.expectEqual(InputTarget{ .panel_id = first.panel_id, .kind = .pty }, first.target);
    try testing.expectEqual(
        InputTarget{ .panel_id = second.panel_id, .kind = .custom_tui },
        second.target,
    );
    try testing.expectEqual(second.target, workspace.activeInputTarget().?);
    try workspace.validate();
}

test "workspace controller routes keys within the active tab" {
    const testing = std.testing;

    var workspace = WorkspaceController.init(testing.allocator);
    defer workspace.deinit();

    const first = try workspace.spawnMarblesPanel(
        "marb-175510-002",
        1,
        .horizontal,
        .pty,
        null,
    );
    const second = try workspace.spawnMarblesPanel(
        "marb-175510-002",
        2,
        .horizontal,
        .custom_tui,
        "marbles-marb-175510-002",
    );
    _ = try workspace.spawnMarblesPanel(
        "marb-175510-003",
        1,
        .horizontal,
        .pty,
        null,
    );

    try workspace.activateTab(first.tab_id);
    try testing.expectEqual(second.target, workspace.activeInputTarget().?);

    const forwarded = try workspace.routeKeyEvent(.{
        .key = .key_a,
        .unshifted_codepoint = 'a',
    });
    try testing.expectEqual(RouteResult{ .forwarded = second.target }, forwarded);

    const focus = try workspace.routeKeyEvent(.{
        .key = .arrow_left,
        .mods = .{ .ctrl = true, .shift = true },
    });
    try testing.expectEqual(
        RouteResult{
            .focus = .{
                .direction = .left,
                .target = first.target,
            },
        },
        focus,
    );

    const close = try workspace.routeKeyEvent(.{
        .key = .key_w,
        .mods = .{ .ctrl = true, .shift = true },
    });
    try testing.expectEqual(
        RouteResult{
            .close = .{
                .closed = .{
                    .panel_id = first.panel_id,
                    .next_focus = second.target,
                },
            },
        },
        close,
    );
    try workspace.validate();
}
