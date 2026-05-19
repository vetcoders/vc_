const std = @import("std");
const JsonRpc = @import("JsonRpc.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Optional initialize-response delay (milliseconds). When set, makes the
    // mock server sleep before answering `initialize`, so the integration
    // tests can deterministically force vc-mux into the `.wait` path of
    // State.registerInitializeRequest with two concurrent clients.
    const init_delay_ns: u64 = blk: {
        const raw = init.environ_map.get("VC_MUX_MOCK_INIT_DELAY_MS") orelse break :blk 0;
        const ms = std.fmt.parseInt(u64, raw, 10) catch break :blk 0;
        break :blk ms * std.time.ns_per_ms;
    };

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    var read_buf: [8192]u8 = undefined;
    var reader = stdin.reader(io, &read_buf);

    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(io, &write_buf);

    while (true) {
        const msg_opt = JsonRpc.Codec.readMessage(allocator, &reader.interface) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        var msg = msg_opt orelse return;
        defer msg.deinit();

        if (msg.parsed.value != .object) continue;
        const object = msg.parsed.value.object;
        const id = object.get("id") orelse continue;
        const method_value = object.get("method") orelse continue;
        if (method_value != .string) continue;

        const id_json = try std.json.Stringify.valueAlloc(allocator, id, .{});
        defer allocator.free(id_json);

        if (std.mem.eql(u8, method_value.string, "initialize")) {
            if (init_delay_ns > 0) {
                std.Io.sleep(io, .{ .nanoseconds = init_delay_ns }, .awake) catch {};
            }
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"capabilities\":{{}}}}}}",
                .{id_json},
            );
            defer allocator.free(payload);
            try writePayload(&writer.interface, payload);
        } else if (std.mem.eql(u8, method_value.string, "echo")) {
            const value_json = value_json: {
                if (object.get("params")) |params| {
                    if (params == .object) {
                        if (params.object.get("value")) |value| {
                            break :value_json try std.json.Stringify.valueAlloc(allocator, value, .{});
                        }
                    }
                }
                break :value_json try allocator.dupe(u8, "null");
            };
            defer allocator.free(value_json);

            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"value\":{s},\"observed_id\":{s}}}}}",
                .{ id_json, value_json, id_json },
            );
            defer allocator.free(payload);
            try writePayload(&writer.interface, payload);
        } else if (std.mem.eql(u8, method_value.string, "fanout")) {
            try writePayload(
                &writer.interface,
                "{\"jsonrpc\":\"2.0\",\"method\":\"server/notice\",\"params\":{\"value\":\"fanout\"}}",
            );
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true}}}}",
                .{id_json},
            );
            defer allocator.free(payload);
            try writePayload(&writer.interface, payload);
        } else {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"method not found\"}}}}",
                .{id_json},
            );
            defer allocator.free(payload);
            try writePayload(&writer.interface, payload);
        }
    }
}

fn writePayload(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    try writer.flush();
}
