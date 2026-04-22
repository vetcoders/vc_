//! Phase-1 surface adapter for the Vibecrafted runtime.
//!
//! This intentionally exports the minimum core/apprt contract so the board
//! runtime can compile and later tracks can replace these stubs with a real
//! mounted Ghostty surface implementation.

const std = @import("std");

const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");

pub const Surface = struct {
    pub const Options = struct {};

    app: *anyopaque,
    core_surface: *CoreSurface,

    pub fn deinit(self: *Surface) void {
        _ = self;
    }

    pub fn core(self: *Surface) *CoreSurface {
        return self.core_surface;
    }

    pub fn rtApp(self: *Surface) *apprt.App {
        return @ptrCast(@alignCast(self.app));
    }

    pub fn close(self: *Surface, _: bool) void {
        _ = self;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        _ = self;
        return null;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;
        return .{ .x = 1, .y = 1 };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        _ = self;
        return .{ .width = 0, .height = 0 };
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        _ = self;
        return .{ .x = 0, .y = 0 };
    }

    pub fn supportsClipboard(self: *const Surface, _: apprt.Clipboard) bool {
        _ = self;
        return false;
    }

    pub fn clipboardRequest(
        self: *Surface,
        _: apprt.Clipboard,
        _: apprt.ClipboardRequest,
    ) !bool {
        _ = self;
        return false;
    }

    pub fn setClipboard(
        self: *Surface,
        _: apprt.Clipboard,
        _: []const apprt.ClipboardContent,
        _: bool,
    ) !void {
        _ = self;
    }

    pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
        _ = self;
        return try std.process.getEnvMap(std.heap.page_allocator);
    }
};

test {
    _ = Surface;
}
