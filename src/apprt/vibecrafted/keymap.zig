const input = @import("../../input.zig");

pub const Action = enum {
    split_horizontal,
    split_vertical,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    close_active,
};

pub fn match(event: input.KeyEvent) ?Action {
    if (event.action != .press) return null;

    const mods = event.effectiveMods().withoutLocks();
    if (!mods.ctrl or !mods.shift) return null;
    if (mods.alt or mods.super) return null;

    return switch (event.key) {
        .key_h => .split_horizontal,
        .key_v => .split_vertical,
        .arrow_left => .focus_left,
        .arrow_right => .focus_right,
        .arrow_up => .focus_up,
        .arrow_down => .focus_down,
        .key_w => .close_active,
        else => switch (event.unshifted_codepoint) {
            'h', 'H' => .split_horizontal,
            'v', 'V' => .split_vertical,
            'w', 'W' => .close_active,
            else => null,
        },
    };
}

pub fn isReserved(event: input.KeyEvent) bool {
    return match(event) != null;
}

test "panels keymap matches split and focus bindings" {
    const testing = @import("std").testing;

    const mods: input.Mods = .{ .ctrl = true, .shift = true };

    try testing.expectEqual(
        Action.split_horizontal,
        match(.{ .key = .key_h, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.split_vertical,
        match(.{ .key = .key_v, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.focus_left,
        match(.{ .key = .arrow_left, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.focus_right,
        match(.{ .key = .arrow_right, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.focus_up,
        match(.{ .key = .arrow_up, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.focus_down,
        match(.{ .key = .arrow_down, .mods = mods }).?,
    );
    try testing.expectEqual(
        Action.close_active,
        match(.{ .key = .key_w, .mods = mods }).?,
    );
}

test "panels keymap rejects unrelated modifiers and release events" {
    const testing = @import("std").testing;

    try testing.expect(match(.{
        .action = .release,
        .key = .key_h,
        .mods = .{ .ctrl = true, .shift = true },
    }) == null);
    try testing.expect(match(.{
        .key = .key_h,
        .mods = .{ .ctrl = true },
    }) == null);
    try testing.expect(match(.{
        .key = .key_h,
        .mods = .{ .ctrl = true, .shift = true, .alt = true },
    }) == null);
}
