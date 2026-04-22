const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const keymap = @import("keymap.zig");
const panels_mod = @import("panels.zig");

pub const PanelId = panels_mod.PanelId;
pub const Panels = panels_mod.Panels;
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
        const id = try self.panels.createInitial();
        try self.surface_kinds.put(self.allocator, id, kind);
        return .{ .panel_id = id, .kind = kind };
    }

    pub fn splitActive(
        self: *Self,
        direction: SplitDirection,
        kind: SurfaceKind,
    ) !SplitOutcome {
        const source = self.activeInputTarget() orelse return error.MissingActivePanel;
        const new_id = try self.panels.splitActive(direction);
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
        const panel = self.panels.activePanel() orelse return null;
        return self.panelTarget(panel.id);
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
