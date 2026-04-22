const std = @import("std");
const Allocator = std.mem.Allocator;

const split_tree = @import("../../datastruct/split_tree.zig");

pub const PanelId = u32;
pub const Tree = split_tree.SplitTree(PanelLeaf);

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
    };

    pub const ValidateError = error{
        ActiveOnEmptyTree,
        MissingActivePanel,
        DuplicatePanelId,
        ActiveMissingFromTree,
        NextIdRegressed,
    };

    allocator: Allocator,
    tree: Tree = .empty,
    active: ?PanelId = null,
    next_panel_id: PanelId = 1,

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
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
        if (!self.tree.isEmpty()) return error.AlreadyInitialized;

        const new_panel = self.makePanel();
        var leaf = PanelLeaf.init(new_panel);
        const next_tree = try Tree.init(self.allocator, &leaf);
        self.replaceTree(next_tree);
        self.active = new_panel.id;
        return new_panel.id;
    }

    pub fn splitActive(
        self: *Self,
        direction: SplitDirection,
    ) CreateError!PanelId {
        if (self.tree.isEmpty()) return self.createInitial();

        const new_panel = self.makePanel();
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
            return .{ .emptied = active_id };
        }

        const active_handle = self.activeHandle().?;
        const fallback_id = (try self.fallbackPanelId(active_handle)).?;
        const next_tree = try self.tree.remove(self.allocator, active_handle);
        self.replaceTree(next_tree);
        self.active = fallback_id;
        return .{ .closed = active_id };
    }

    pub fn activePanel(self: *const Self) ?Panel {
        const id = self.active orelse return null;
        return self.panel(id);
    }

    pub fn panel(self: *const Self, id: PanelId) ?Panel {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.panel.id == id) return entry.view.panel;
        }
        return null;
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
    }

    fn makePanel(self: *Self) Panel {
        const id = self.next_panel_id;
        self.next_panel_id += 1;
        return .{ .id = id };
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

const PanelLeaf = struct {
    const Self = @This();

    panel: Panel,
    label_buf: [24]u8,
    label_len: u8,

    fn init(panel: Panel) Self {
        var leaf: Self = .{
            .panel = panel,
            .label_buf = undefined,
            .label_len = 0,
        };
        const label = std.fmt.bufPrint(&leaf.label_buf, "panel-{d}", .{panel.id}) catch unreachable;
        leaf.label_len = @intCast(label.len);
        return leaf;
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
        return self.label_buf[0..self.label_len];
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
    try testing.expectEqual(@as(usize, 0), panels.activePath().?.depth);
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
