const apprt = @import("apprt.zig");

pub fn main() !void {
    try apprt.vibecrafted.Runtime.printBanner();
}

test {
    _ = apprt.vibecrafted;
}
