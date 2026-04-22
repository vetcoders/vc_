const std = @import("std");
const testing = std.testing;

const panels_mod = @import("../src/apprt/vibecrafted/panels.zig");
const Panels = panels_mod.Panels;
const SplitDirection = panels_mod.SplitDirection;
const FocusDirection = panels_mod.FocusDirection;
const CloseResult = panels_mod.CloseResult;

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
