const std = @import("std");
const testing = std.testing;
const apprt = @import("../src/apprt.zig");
const input = @import("../src/input.zig");

const vibecrafted = apprt.vibecrafted;
const Panels = vibecrafted.Panels;
const SplitDirection = vibecrafted.SplitDirection;
const FocusDirection = vibecrafted.FocusDirection;
const CloseResult = vibecrafted.CloseResult;
const Controller = vibecrafted.Controller;
const SurfaceKind = vibecrafted.SurfaceKind;
const RouteResult = vibecrafted.RouteResult;
const KeyAction = vibecrafted.KeyAction;

test "panels: create initial panel" {
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

test "panels: controller exposes stable routing outcomes through public API" {
    var controller = Controller.init(testing.allocator);
    defer controller.deinit();

    const first = try controller.createInitial(.pty);
    try testing.expectEqual(SurfaceKind.pty, first.kind);

    const split = try controller.splitActive(.horizontal, .custom_tui);
    try testing.expectEqual(first.panel_id, split.source_panel_id);
    try testing.expectEqual(SurfaceKind.custom_tui, split.new_panel.kind);
    try testing.expectEqual(split.new_panel, controller.activeInputTarget().?);

    const routed = try controller.routeKeyEvent(.{
        .key = .key_a,
        .unshifted_codepoint = 'a',
    });
    try testing.expectEqual(
        RouteResult{
            .forwarded = .{
                .panel_id = split.new_panel.panel_id,
                .kind = .custom_tui,
            },
        },
        routed,
    );
    try controller.validate();
}

test "panels: reserved board bindings are detected through exported keymap" {
    const mods: input.Mods = .{ .ctrl = true, .shift = true };

    try testing.expectEqual(
        KeyAction.split_horizontal,
        vibecrafted.matchBoardKey(.{
            .key = .key_h,
            .mods = mods,
        }).?,
    );
    try testing.expectEqual(
        KeyAction.focus_right,
        vibecrafted.matchBoardKey(.{
            .key = .arrow_right,
            .mods = mods,
        }).?,
    );
    try testing.expect(vibecrafted.isReservedBoardKey(.{
        .key = .key_w,
        .mods = mods,
    }));
    try testing.expect(!vibecrafted.isReservedBoardKey(.{
        .key = .key_h,
        .mods = .{ .ctrl = true },
    }));
}
