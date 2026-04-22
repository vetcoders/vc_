//! Vibecrafted application runtime scaffold. Phase 1 keeps this intentionally
//! small so downstream tracks can start against a stable module path.

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const internal_os = @import("../os/main.zig");

pub const resourcesDir = internal_os.resourcesDir;
pub const Runtime = @import("vibecrafted/runtime.zig").Runtime;
pub const Surface = @import("vibecrafted/surface.zig").Surface;

pub const App = struct {
    pub const Options = struct {};

    pub fn init(self: *App, _: *CoreApp, opts: Options) !void {
        _ = opts;
        self.* = .{};
    }

    pub fn run(_: *App) !void {
        try Runtime.printBanner();
    }

    pub fn terminate(_: *App) void {}

    pub fn wakeup(_: *App) void {}

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
