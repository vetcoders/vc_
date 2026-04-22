const std = @import("std");
const Allocator = std.mem.Allocator;

const split_tree = @import("../../datastruct/split_tree.zig");

pub const PanelId = u32;
pub const TabId = u32;
pub const Tree = split_tree.SplitTree(PanelLeaf);
pub const max_panel_name_len: usize = 64;
pub const MarblesTabNameEnvVar = "VIBECRAFTED_MARBLES_TAB_NAME";

pub const SurfaceKind = enum {
    pty,
    custom_tui,
};

pub const InputTarget = struct {
    panel_id: PanelId,
    kind: SurfaceKind,
};

pub const SplitDirection = enum {
    horizontal,
    vertical,

    fn treeDirection(self: SplitDirection) Tree.Split.Direction {
        return switch (self) {
            .horizontal => .right,
            .vertical => .down,
        };
    }
};

pub const FocusDirection = enum {
    previous,
    next,
    left,
    right,
    up,
    down,

    fn treeGoto(self: FocusDirection) Tree.Goto {
        return switch (self) {
            .previous => .previous_wrapped,
            .next => .next_wrapped,
            .left => .{ .spatial = .left },
            .right => .{ .spatial = .right },
            .up => .{ .spatial = .up },
            .down => .{ .spatial = .down },
        };
    }
};

pub const Panel = struct {
    id: PanelId,
    name_buf: [max_panel_name_len]u8,
    name_len: u8,

    pub const InitError = error{
        NameTooLong,
    };

    pub fn init(id: PanelId, panel_name: []const u8) InitError!Panel {
        if (panel_name.len > max_panel_name_len) return error.NameTooLong;

        var panel: Panel = .{
            .id = id,
            .name_buf = undefined,
            .name_len = @intCast(panel_name.len),
        };
        @memcpy(panel.name_buf[0..panel_name.len], panel_name);
        return panel;
    }

    pub fn name(self: *const Panel) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const FocusPath = struct {
    panel_id: PanelId,
    handle: Tree.Node.Handle,
    depth: usize,
};

pub const CloseResult = union(enum) {
    none,
    closed: PanelId,
    emptied: PanelId,
};

pub const Panels = struct {
    const Self = @This();

    pub const CreateError = Allocator.Error || error{
        AlreadyInitialized,
        NameTooLong,
    };

    pub const ValidateError = error{
        ActiveOnEmptyTree,
        MissingActivePanel,
        DuplicatePanelId,
        ActiveMissingFromTree,
        NextIdRegressed,
        PanelNameCountMismatch,
        MissingPanelName,
        DanglingPanelName,
    };

    allocator: Allocator,
    tree: Tree = .empty,
    active: ?PanelId = null,
    next_panel_id: PanelId = 1,
    panel_names: std.AutoHashMapUnmanaged(PanelId, PanelName) = .{},

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.panel_names.deinit(self.allocator);
        self.tree.deinit();
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.tree.isEmpty();
    }

    pub fn panelCount(self: *const Self) usize {
        var count: usize = 0;
        var it = self.tree.iterator();
        while (it.next() != null) count += 1;
        return count;
    }

    pub fn createInitial(self: *Self) CreateError!PanelId {
        var default_name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&default_name_buf, "panel-{d}", .{self.next_panel_id}) catch unreachable;
        return self.createInitialNamed(name);
    }

    pub fn createInitialNamed(self: *Self, name: []const u8) CreateError!PanelId {
        if (!self.tree.isEmpty()) return error.AlreadyInitialized;

        const new_panel = try self.makePanel(name);
        var leaf = PanelLeaf.init(new_panel);
        const next_tree = try Tree.init(self.allocator, &leaf);
        self.replaceTree(next_tree);
        self.active = new_panel.id;
        errdefer _ = self.closeActive() catch {};
        try self.panel_names.put(self.allocator, new_panel.id, PanelName.init(name));
        return new_panel.id;
    }

    pub fn splitActive(
        self: *Self,
        direction: SplitDirection,
    ) CreateError!PanelId {
        var default_name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&default_name_buf, "panel-{d}", .{self.next_panel_id}) catch unreachable;
        return self.splitActiveNamed(direction, name);
    }

    pub fn splitActiveNamed(
        self: *Self,
        direction: SplitDirection,
        name: []const u8,
    ) CreateError!PanelId {
        if (self.tree.isEmpty()) return self.createInitialNamed(name);

        const new_panel = try self.makePanel(name);
        var leaf = PanelLeaf.init(new_panel);
        var insert_tree = try Tree.init(self.allocator, &leaf);
        defer insert_tree.deinit();

        const active_handle = self.activeHandle().?;
        const next_tree = try self.tree.split(
            self.allocator,
            active_handle,
            direction.treeDirection(),
            0.5,
            &insert_tree,
        );
        self.replaceTree(next_tree);
        self.active = new_panel.id;
        errdefer _ = self.closeActive() catch {};
        try self.panel_names.put(self.allocator, new_panel.id, PanelName.init(name));
        return new_panel.id;
    }

    pub fn focus(self: *Self, direction: FocusDirection) Allocator.Error!bool {
        const active_handle = self.activeHandle() orelse return false;
        const target = (try self.tree.goto(
            self.allocator,
            active_handle,
            direction.treeGoto(),
        )) orelse return false;
        const next_id = self.panelIdAt(target);
        if (next_id == self.active.?) return false;
        self.active = next_id;
        return true;
    }

    pub fn closeActive(self: *Self) Allocator.Error!CloseResult {
        const active_id = self.active orelse return .none;
        if (self.panelCount() == 1) {
            self.tree.deinit();
            self.tree = .empty;
            self.active = null;
            _ = self.panel_names.remove(active_id);
            return .{ .emptied = active_id };
        }

        const active_handle = self.activeHandle().?;
        const fallback_id = (try self.fallbackPanelId(active_handle)).?;
        const next_tree = try self.tree.remove(self.allocator, active_handle);
        self.replaceTree(next_tree);
        self.active = fallback_id;
        _ = self.panel_names.remove(active_id);
        return .{ .closed = active_id };
    }

    pub fn activePanel(self: *const Self) ?Panel {
        const id = self.active orelse return null;
        return self.panel(id);
    }

    pub fn activePanelName(self: *const Self) ?[]const u8 {
        const id = self.active orelse return null;
        return self.panelName(id);
    }

    pub fn panel(self: *const Self, id: PanelId) ?Panel {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.panel.id == id) return entry.view.panel;
        }
        return null;
    }

    pub fn panelName(self: *const Self, id: PanelId) ?[]const u8 {
        _ = self.panel(id) orelse return null;
        const stored_name = self.panel_names.get(id) orelse return null;
        return stored_name.slice();
    }

    pub fn activePath(self: *const Self) ?FocusPath {
        const id = self.active orelse return null;
        return self.findPath(.root, id, 0);
    }

    pub fn validate(self: *const Self) ValidateError!void {
        if (self.tree.isEmpty()) {
            if (self.active != null) return error.ActiveOnEmptyTree;
            return;
        }

        const active_id = self.active orelse return error.MissingActivePanel;
        var found_active = false;
        var max_id: PanelId = 0;

        var outer = self.tree.iterator();
        while (outer.next()) |entry| {
            const id = entry.view.panel.id;
            if (id == active_id) found_active = true;
            max_id = @max(max_id, id);

            var duplicates: usize = 0;
            var inner = self.tree.iterator();
            while (inner.next()) |other| {
                if (other.view.panel.id == id) duplicates += 1;
            }
            if (duplicates != 1) return error.DuplicatePanelId;
        }

        if (!found_active) return error.ActiveMissingFromTree;
        if (max_id >= self.next_panel_id) return error.NextIdRegressed;

        if (self.panel_names.count() != self.panelCount()) {
            return error.PanelNameCountMismatch;
        }

        var panel_it = self.tree.iterator();
        while (panel_it.next()) |entry| {
            if (!self.panel_names.contains(entry.view.panel.id)) {
                return error.MissingPanelName;
            }
        }

        var name_it = self.panel_names.iterator();
        while (name_it.next()) |entry| {
            if (self.panel(entry.key_ptr.*) == null) {
                return error.DanglingPanelName;
            }
        }
    }

    fn makePanel(self: *Self, name: []const u8) CreateError!Panel {
        const id = self.next_panel_id;
        errdefer self.next_panel_id = id;
        self.next_panel_id += 1;
        return try Panel.init(id, name);
    }

    fn replaceTree(self: *Self, next_tree: Tree) void {
        var old_tree = self.tree;
        self.tree = next_tree;
        old_tree.deinit();
    }

    fn activeHandle(self: *const Self) ?Tree.Node.Handle {
        const path = self.activePath() orelse return null;
        return path.handle;
    }

    fn panelIdAt(self: *const Self, handle: Tree.Node.Handle) PanelId {
        return self.tree.nodes[handle.idx()].leaf.panel.id;
    }

    fn fallbackPanelId(
        self: *const Self,
        active_handle: Tree.Node.Handle,
    ) Allocator.Error!?PanelId {
        const active_id = self.panelIdAt(active_handle);

        const next_handle = (try self.tree.goto(
            self.allocator,
            active_handle,
            .next_wrapped,
        )) orelse return null;
        const next_id = self.panelIdAt(next_handle);
        if (next_id != active_id) return next_id;

        const previous_handle = (try self.tree.goto(
            self.allocator,
            active_handle,
            .previous_wrapped,
        )) orelse return null;
        const previous_id = self.panelIdAt(previous_handle);
        if (previous_id != active_id) return previous_id;

        return null;
    }

    fn findPath(
        self: *const Self,
        current: Tree.Node.Handle,
        target_id: PanelId,
        depth: usize,
    ) ?FocusPath {
        return switch (self.tree.nodes[current.idx()]) {
            .leaf => |leaf| if (leaf.panel.id == target_id)
                .{
                    .panel_id = target_id,
                    .handle = current,
                    .depth = depth,
                }
            else
                null,
            .split => |split| self.findPath(split.left, target_id, depth + 1) orelse
                self.findPath(split.right, target_id, depth + 1),
        };
    }
};

const PanelName = struct {
    buf: [max_panel_name_len]u8,
    len: u8,

    fn init(name: []const u8) PanelName {
        var stored: PanelName = .{
            .buf = undefined,
            .len = @intCast(name.len),
        };
        @memcpy(stored.buf[0..name.len], name);
        return stored;
    }

    fn slice(self: *const PanelName) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Tab = struct {
    id: TabId,
    name: []const u8,
    panels: Panels,
    surface_kinds: std.AutoHashMapUnmanaged(PanelId, SurfaceKind) = .{},

    pub const ValidateError = Panels.ValidateError || error{
        MetadataCountMismatch,
        MissingPanelMetadata,
        DanglingPanelMetadata,
    };

    fn init(allocator: Allocator, id: TabId, name: []const u8) !*Tab {
        const tab = try allocator.create(Tab);
        errdefer allocator.destroy(tab);

        tab.* = .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .panels = Panels.init(allocator),
        };
        return tab;
    }

    fn deinit(self: *Tab, allocator: Allocator) void {
        self.surface_kinds.deinit(allocator);
        self.panels.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn createInitialNamed(
        self: *Tab,
        kind: SurfaceKind,
        name: []const u8,
    ) (Allocator.Error || Panels.CreateError)!InputTarget {
        const id = try self.panels.createInitialNamed(name);
        errdefer _ = self.panels.closeActive() catch {};
        try self.surface_kinds.put(self.panels.allocator, id, kind);
        return .{ .panel_id = id, .kind = kind };
    }

    pub fn splitActiveNamed(
        self: *Tab,
        direction: SplitDirection,
        kind: SurfaceKind,
        name: []const u8,
    ) (Allocator.Error || Panels.CreateError)!InputTarget {
        const id = try self.panels.splitActiveNamed(direction, name);
        errdefer _ = self.panels.closeActive() catch {};
        try self.surface_kinds.put(self.panels.allocator, id, kind);
        return .{ .panel_id = id, .kind = kind };
    }

    pub fn activePanelName(self: *const Tab) ?[]const u8 {
        return self.panels.activePanelName();
    }

    pub fn activePaneName(self: *const Tab) ?[]const u8 {
        return self.activePanelName();
    }

    pub fn panelTarget(self: *const Tab, panel_id: PanelId) ?InputTarget {
        _ = self.panels.panel(panel_id) orelse return null;
        const kind = self.surface_kinds.get(panel_id) orelse return null;
        return .{ .panel_id = panel_id, .kind = kind };
    }

    pub fn activeInputTarget(self: *const Tab) ?InputTarget {
        const active_panel = self.panels.activePanel() orelse return null;
        return self.panelTarget(active_panel.id);
    }

    pub fn validate(self: *const Tab) ValidateError!void {
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
};

pub const Workspace = struct {
    const Self = @This();

    pub const SpawnedMarblesPanel = struct {
        tab_id: TabId,
        tab_name: []const u8,
        panel_id: PanelId,
        pane_name: []const u8,
        target: InputTarget,
    };

    pub const ValidateError = Tab.ValidateError || error{
        ActiveOnEmptyWorkspace,
        MissingActiveTab,
        DuplicateTabId,
        DuplicateTabName,
        ActiveMissingFromWorkspace,
        NextTabIdRegressed,
    };

    allocator: Allocator,
    tabs: std.ArrayListUnmanaged(*Tab) = .{},
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

    pub fn activeTab(self: *const Self) ?*Tab {
        const id = self.active_tab_id orelse return null;
        return self.tab(id);
    }

    pub fn tab(self: *const Self, id: TabId) ?*Tab {
        for (self.tabs.items) |workspace_tab| {
            if (workspace_tab.id == id) return workspace_tab;
        }
        return null;
    }

    pub fn findTabByName(self: *const Self, name: []const u8) ?*Tab {
        for (self.tabs.items) |workspace_tab| {
            if (std.mem.eql(u8, workspace_tab.name, name)) return workspace_tab;
        }
        return null;
    }

    pub fn findOrCreateTab(self: *Self, name: []const u8) !*Tab {
        if (self.findTabByName(name)) |existing| {
            self.active_tab_id = existing.id;
            return existing;
        }

        const id = self.next_tab_id;
        errdefer self.next_tab_id = id;
        self.next_tab_id += 1;

        const workspace_tab = try Tab.init(self.allocator, id, name);
        errdefer workspace_tab.deinit(self.allocator);

        try self.tabs.append(self.allocator, workspace_tab);
        self.active_tab_id = workspace_tab.id;
        return workspace_tab;
    }

    pub fn marblesTab(self: *Self, run_id: []const u8) !*Tab {
        return self.marblesTabInherited(run_id, null);
    }

    pub fn marblesTabInherited(
        self: *Self,
        run_id: []const u8,
        inherited_tab_name: ?[]const u8,
    ) !*Tab {
        const tab_name = try marblesTabName(
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
        const pane_name = try marblesPaneName(self.allocator, run_id, loop_nr);
        defer self.allocator.free(pane_name);

        const target = if (workspace_tab.panels.isEmpty())
            try workspace_tab.createInitialNamed(kind, pane_name)
        else
            try workspace_tab.splitActiveNamed(direction, kind, pane_name);
        return .{
            .tab_id = workspace_tab.id,
            .tab_name = workspace_tab.name,
            .panel_id = target.panel_id,
            .pane_name = workspace_tab.panels.panelName(target.panel_id).?,
            .target = target,
        };
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
            try workspace_tab.validate();

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

pub fn marblesTabName(
    allocator: Allocator,
    run_id: []const u8,
    inherited_tab_name: ?[]const u8,
) Allocator.Error![]u8 {
    const canonical_name = try std.fmt.allocPrint(allocator, "marbles-{s}", .{run_id});
    errdefer allocator.free(canonical_name);

    if (inherited_tab_name) |tab_name| {
        if (std.mem.eql(u8, tab_name, canonical_name)) {
            return canonical_name;
        }
    }
    return canonical_name;
}

pub fn marblesPaneName(
    allocator: Allocator,
    run_id: []const u8,
    loop_nr: usize,
) Allocator.Error![]u8 {
    if (loop_nr <= 1) return allocator.dupe(u8, run_id);
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ run_id, loop_nr });
}

const PanelLeaf = struct {
    const Self = @This();

    panel: Panel,

    fn init(panel: Panel) Self {
        return .{ .panel = panel };
    }

    pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
        const ptr = try alloc.create(Self);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn eql(self: *const Self, other: *const Self) bool {
        return self.panel.id == other.panel.id;
    }

    pub fn splitTreeLabel(self: *const Self) []const u8 {
        return self.panel.name();
    }
};

test "panels: create initial panel" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const root = try panels.createInitial();

    try testing.expectEqual(@as(u32, 1), root);
    try testing.expectEqual(@as(usize, 1), panels.panelCount());
    try testing.expectEqual(root, panels.activePanel().?.id);
    try testing.expectEqualStrings("panel-1", panels.activePanel().?.name());
    try testing.expectEqual(@as(usize, 0), panels.activePath().?.depth);
    try panels.validate();
}

test "panels: named panel creation preserves pane labels" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const root = try panels.createInitialNamed("marbles-run-001");
    const second = try panels.splitActiveNamed(.horizontal, "marbles-run-001-2");

    try testing.expectEqual(@as(u32, 1), root);
    try testing.expectEqual(@as(u32, 2), second);
    try testing.expectEqualStrings("marbles-run-001", panels.panel(root).?.name());
    try testing.expectEqualStrings("marbles-run-001-2", panels.panel(second).?.name());
    try panels.validate();
}

test "panels: stored panel names survive later tree rewrites" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const first = try panels.createInitialNamed("marbles-run-001");
    _ = try panels.splitActiveNamed(.horizontal, "marbles-run-001-2");

    try testing.expectEqualStrings("marbles-run-001", panels.panelName(first).?);
    try panels.validate();
}

test "panels: split horizontal and vertical" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const first = try panels.createInitial();
    const second = try panels.splitActive(.horizontal);

    try testing.expectEqual(@as(u32, 2), second);
    try testing.expectEqual(@as(usize, 2), panels.panelCount());
    try testing.expectEqual(second, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.left));
    try testing.expectEqual(first, panels.activePanel().?.id);

    const third = try panels.splitActive(.vertical);

    try testing.expectEqual(@as(u32, 3), third);
    try testing.expectEqual(@as(usize, 3), panels.panelCount());
    try testing.expectEqual(third, panels.activePanel().?.id);
    try testing.expectEqual(@as(usize, 2), panels.activePath().?.depth);
    try panels.validate();
}

test "panels: focus navigation follows spatial layout" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const first = try panels.createInitial();
    const second = try panels.splitActive(.horizontal);
    try testing.expect(try panels.focus(.left));
    const third = try panels.splitActive(.vertical);

    try testing.expectEqual(third, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.up));
    try testing.expectEqual(first, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.right));
    try testing.expectEqual(second, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.left));
    try testing.expectEqual(first, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.down));
    try testing.expectEqual(third, panels.activePanel().?.id);
    try panels.validate();
}

test "panels: close active rehomes focus and clears on last close" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    _ = try panels.createInitial();
    const second = try panels.splitActive(.horizontal);
    try testing.expect(try panels.focus(.left));
    const third = try panels.splitActive(.vertical);
    try testing.expectEqual(third, panels.activePanel().?.id);

    const closed_third = try panels.closeActive();
    try testing.expectEqual(CloseResult{ .closed = third }, closed_third);
    try testing.expectEqual(second, panels.activePanel().?.id);
    try testing.expectEqual(@as(usize, 2), panels.panelCount());
    try panels.validate();

    const closed_second = try panels.closeActive();
    try testing.expectEqual(CloseResult{ .closed = second }, closed_second);
    try testing.expectEqual(@as(u32, 1), panels.activePanel().?.id);
    try testing.expectEqual(@as(usize, 1), panels.panelCount());
    try panels.validate();

    const closed_last = try panels.closeActive();
    try testing.expectEqual(CloseResult{ .emptied = 1 }, closed_last);
    try testing.expectEqual(@as(usize, 0), panels.panelCount());
    try testing.expect(panels.activePanel() == null);
    try panels.validate();
}

test "panels: focus cycling works in leaf order" {
    const testing = std.testing;

    var panels = Panels.init(testing.allocator);
    defer panels.deinit();

    const first = try panels.createInitial();
    const second = try panels.splitActive(.horizontal);
    const third = try panels.splitActive(.horizontal);

    try testing.expectEqual(third, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.previous));
    try testing.expectEqual(second, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.previous));
    try testing.expectEqual(first, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.previous));
    try testing.expectEqual(third, panels.activePanel().?.id);
    try testing.expect(try panels.focus(.next));
    try testing.expectEqual(first, panels.activePanel().?.id);
    try panels.validate();
}

test "workspace: marbles tabs isolate run ids and preserve inherited names" {
    const testing = std.testing;

    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();

    const run_a = try workspace.marblesTab("run-a");
    const run_a_again = try workspace.marblesTab("run-a");
    const run_b = try workspace.marblesTab("run-b");
    const inherited = try workspace.marblesTabInherited("run-a", "marbles-run-a");

    try testing.expectEqual(@as(usize, 2), workspace.tabCount());
    try testing.expectEqual(run_a.id, run_a_again.id);
    try testing.expectEqual(run_a.id, inherited.id);
    try testing.expectEqualStrings("marbles-run-a", run_a.name);
    try testing.expectEqualStrings("marbles-run-b", run_b.name);
    try testing.expectEqual(inherited.id, workspace.activeTab().?.id);
    try workspace.validate();
}

test "workspace tab: input targets survive focus moves inside one tab" {
    const testing = std.testing;

    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();

    const workspace_tab = try workspace.findOrCreateTab("monitor");
    const monitor = try workspace_tab.createInitialNamed(.custom_tui, "monitor");
    const shell = try workspace_tab.splitActiveNamed(.horizontal, .pty, "shell");

    try testing.expectEqual(shell, workspace_tab.activeInputTarget().?);
    try testing.expect(try workspace_tab.panels.focus(.left));
    try testing.expectEqual(monitor, workspace_tab.activeInputTarget().?);
    try workspace_tab.validate();
}

test "workspace: marbles pane names follow the loop contract" {
    const testing = std.testing;

    const first = try marblesPaneName(testing.allocator, "marb-175510-001", 1);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("marb-175510-001", first);

    const second = try marblesPaneName(testing.allocator, "marb-175510-001", 2);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("marb-175510-001-2", second);
}

test "workspace: spawnMarblesPanel keeps loops in one tab and ignores mismatched env" {
    const testing = std.testing;

    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();

    const first = try workspace.spawnMarblesPanel(
        "marb-175510-001",
        1,
        .horizontal,
        .pty,
        null,
    );
    const second = try workspace.spawnMarblesPanel(
        "marb-175510-001",
        2,
        .vertical,
        .pty,
        "marbles-run-other",
    );

    try testing.expectEqual(@as(usize, 1), workspace.tabCount());
    try testing.expectEqual(first.tab_id, second.tab_id);
    try testing.expectEqualStrings("marbles-marb-175510-001", first.tab_name);
    try testing.expectEqualStrings("marb-175510-001", first.pane_name);
    try testing.expectEqualStrings("marb-175510-001-2", second.pane_name);
    try testing.expectEqual(InputTarget{ .panel_id = first.panel_id, .kind = .pty }, first.target);
    try testing.expectEqual(InputTarget{ .panel_id = second.panel_id, .kind = .pty }, second.target);
    try testing.expectEqualStrings("marb-175510-001-2", workspace.activeTab().?.activePaneName().?);
    try testing.expectEqual(second.target, workspace.activeTab().?.activeInputTarget().?);
    try workspace.validate();
}
