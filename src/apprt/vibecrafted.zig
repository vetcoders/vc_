//! Vibecrafted application runtime scaffold. Phase 1 keeps this intentionally
//! small so downstream tracks can start against a stable module path.

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const internal_os = @import("../os/main.zig");

pub const resourcesDir = internal_os.resourcesDir;
pub const panels = @import("vibecrafted/panels.zig");
pub const controller = @import("vibecrafted/controller.zig");
pub const keymap = @import("vibecrafted/keymap.zig");
pub const tui = @import("vibecrafted/tui/tui.zig");
pub const Runtime = @import("vibecrafted/runtime.zig").Runtime;
pub const Surface = @import("vibecrafted/surface.zig").Surface;
pub const Tui = tui.Tui;

pub const PanelId = panels.PanelId;
pub const Panel = panels.Panel;
pub const Panels = panels.Panels;
pub const SplitDirection = panels.SplitDirection;
pub const FocusDirection = panels.FocusDirection;
pub const FocusPath = panels.FocusPath;
pub const CloseResult = panels.CloseResult;

pub const Controller = controller.Controller;
pub const SurfaceKind = controller.SurfaceKind;
pub const InputTarget = controller.InputTarget;
pub const SplitOutcome = controller.SplitOutcome;
pub const FocusOutcome = controller.FocusOutcome;
pub const CloseOutcome = controller.CloseOutcome;
pub const RouteResult = controller.RouteResult;
pub const KeyAction = keymap.Action;
pub const matchBoardKey = keymap.match;
pub const isReservedBoardKey = keymap.isReserved;

pub const App = struct {
    const Lifecycle = enum {
        initialized,
        running,
        terminated,
    };

    pub const Options = struct {};

    core_app: *CoreApp,
    lifecycle: Lifecycle = .initialized,
    wakeup_count: usize = 0,

    pub fn init(self: *App, core_app: *CoreApp, opts: Options) !void {
        _ = opts;
        self.* = .{
            .core_app = core_app,
        };
    }

    pub fn run(self: *App) !void {
        self.lifecycle = .running;

        // Exercise the real core-app lifecycle even while phase 1 only
        // renders a banner. Later tracks can extend this runtime in place.
        try self.core_app.tick(self);
        try Runtime.printBanner();
    }

    pub fn terminate(self: *App) void {
        self.lifecycle = .terminated;
    }

    pub fn wakeup(self: *App) void {
        self.wakeup_count += 1;
    }

    pub fn performAction(
        self: *App,
        _: apprt.Target,
        comptime action: apprt.Action.Key,
        _: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .quit => self.lifecycle = .terminated,
            else => {},
        }

        return false;
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
