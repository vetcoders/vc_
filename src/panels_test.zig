const std = @import("std");

const controller_mod = @import("apprt/vibecrafted/controller.zig");
const keymap_mod = @import("apprt/vibecrafted/keymap.zig");
const panels_mod = @import("apprt/vibecrafted/panels.zig");
const runtime_mod = @import("apprt/vibecrafted/runtime.zig");
const tui_mod = @import("apprt/vibecrafted/tui/tui.zig");

test {
    std.testing.refAllDecls(runtime_mod);
    std.testing.refAllDecls(controller_mod);
    std.testing.refAllDecls(keymap_mod);
    std.testing.refAllDecls(panels_mod);
    std.testing.refAllDecls(tui_mod);
}

test "panels test root exercises the public vibecrafted seam" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "Vibecrafted runtime v0.0.1",
        runtime_mod.Runtime.banner(),
    );

    var controller = controller_mod.Controller.init(testing.allocator);
    defer controller.deinit();

    const first = try controller.createInitialNamed(.pty, "shell");
    try testing.expectEqualStrings(
        "shell",
        controller.panel(first.panel_id).?.name(),
    );

    try testing.expectEqual(
        keymap_mod.Action.split_vertical,
        keymap_mod.match(.{
            .key = .key_v,
            .mods = .{ .ctrl = true, .shift = true },
        }).?,
    );

    const split = try controller.routeKeyEvent(.{
        .key = .key_v,
        .mods = .{ .ctrl = true, .shift = true },
    });
    switch (split) {
        .split => |outcome| {
            try testing.expectEqual(panels_mod.SplitDirection.vertical, outcome.direction);
            try testing.expectEqual(first.panel_id, outcome.source_panel_id);
            try testing.expectEqual(controller_mod.SurfaceKind.pty, outcome.new_panel.kind);
        },
        else => return error.UnexpectedRouteResult,
    }
    try controller.validate();

    var workspace = panels_mod.Workspace.init(testing.allocator);
    defer workspace.deinit();

    const tab_name = try panels_mod.marblesTabName(
        testing.allocator,
        "marb-001",
        null,
    );
    defer testing.allocator.free(tab_name);

    const first_spawn = try workspace.spawnMarblesPanel(
        "marb-001",
        1,
        .horizontal,
        controller_mod.SurfaceKind.custom_tui,
        tab_name,
    );
    const second_spawn = try workspace.spawnMarblesPanel(
        "marb-001",
        2,
        .vertical,
        controller_mod.SurfaceKind.custom_tui,
        "marbles-other-run",
    );

    try testing.expectEqual(first_spawn.tab_id, second_spawn.tab_id);
    try testing.expectEqualStrings("marbles-marb-001", first_spawn.tab_name);
    try testing.expectEqualStrings("marb-001", first_spawn.pane_name);
    try testing.expectEqualStrings("marb-001-2", second_spawn.pane_name);
    try workspace.validate();
}

test "public vibecrafted seam exports runtime-aware marbles workspace routing" {
    const testing = std.testing;
    const vibecrafted = @import("apprt/vibecrafted.zig");

    var workspace = vibecrafted.WorkspaceController.init(testing.allocator);
    defer workspace.deinit();

    const first = try workspace.spawnMarblesPanel(
        "marb-002",
        1,
        .horizontal,
        .pty,
        null,
    );
    const second = try workspace.spawnMarblesPanel(
        "marb-002",
        2,
        .vertical,
        .custom_tui,
        "marbles-marb-002",
    );

    try testing.expectEqualStrings("marbles-marb-002", first.tab_name);
    try testing.expectEqual(vibecrafted.SurfaceKind.pty, first.target.kind);
    try testing.expectEqual(vibecrafted.SurfaceKind.custom_tui, second.target.kind);
    try testing.expectEqual(second.target, workspace.activeInputTarget().?);
    try workspace.validate();
}
