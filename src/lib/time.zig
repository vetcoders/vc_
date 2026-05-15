const std = @import("std");

/// Compatibility wrapper for the pre-0.16 `std.time.Instant` API used by
/// renderer image ordering.
pub const Instant = struct {
    timestamp: std.Io.Timestamp,

    pub fn now() !Instant {
        return .{ .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .boot) };
    }

    pub fn order(self: Instant, other: Instant) std.math.Order {
        return std.math.order(
            self.timestamp.toNanoseconds(),
            other.timestamp.toNanoseconds(),
        );
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const delta = self.timestamp.toNanoseconds() - earlier.timestamp.toNanoseconds();
        return @intCast(@max(delta, 0));
    }
};
