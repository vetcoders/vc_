// Integration tests for the vc-mux runtime. Spawns a real mux process over a
// temporary Unix socket and drives it from multiple in-test clients to verify
// id rewriting, initialize caching, and fan-out routing end-to-end.
const std = @import("std");
const testing = std.testing;
const JsonRpc = @import("JsonRpc.zig");

const io = testing.io;

const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    read_buf: [8192]u8 = undefined,
    write_buf: [8192]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,

    fn create(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .stream = stream,
        };
        client.reader = stream.reader(io, &client.read_buf);
        client.writer = stream.writer(io, &client.write_buf);
        return client;
    }

    fn destroy(self: *Client) void {
        self.stream.close(io);
        self.allocator.destroy(self);
    }

    fn write(self: *Client, payload: []const u8) !void {
        try self.writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
        try self.writer.interface.flush();
    }

    fn read(self: *Client, allocator: std.mem.Allocator) !JsonRpc.Message {
        return (try JsonRpc.Codec.readMessage(allocator, &self.reader.interface)) orelse error.MuxClosed;
    }
};

test "vc-mux multiplexes clients, rewrites ids, caches initialize, and fans out notifications" {
    const allocator = testing.allocator;
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;

    const bin_paths = try testBinaries(allocator);
    defer bin_paths.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const socket_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/vc-mux.sock",
        .{tmp.sub_path},
    );
    defer allocator.free(socket_path);

    const mux_argv = &[_][]const u8{
        bin_paths.mux,
        "--socket",
        socket_path,
        "--max-active-clients",
        "8",
        "--cmd",
        bin_paths.mock_server,
    };
    // Discard mux stderr so debug prints don't trigger zig build's
    // "failed command" noise on otherwise green test runs. Flip back to
    // `.inherit` locally when debugging the mux runtime itself.
    var mux = try std.process.spawn(io, .{
        .argv = mux_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer mux.kill(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    var client_a = try connectClient(allocator, socket_path);
    defer client_a.destroy();
    var client_b = try connectClient(allocator, socket_path);
    defer client_b.destroy();

    try client_a.write("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    {
        var response = try client_a.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .integer = 1 });
        try expectResultObject(response.parsed.value);
    }

    try client_b.write("{\"jsonrpc\":\"2.0\",\"id\":\"init-b\",\"method\":\"initialize\",\"params\":{}}");
    {
        var response = try client_b.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .string = "init-b" });
        try expectResultObject(response.parsed.value);
    }

    try client_a.write("{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"echo\",\"params\":{\"value\":\"A\"}}");
    try client_b.write("{\"jsonrpc\":\"2.0\",\"id\":202,\"method\":\"echo\",\"params\":{\"value\":\"B\"}}");
    {
        var response = try client_a.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .integer = 101 });
        try expectEcho(response.parsed.value, "A");
        try expectObservedGlobalId(response.parsed.value);
    }
    {
        var response = try client_b.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .integer = 202 });
        try expectEcho(response.parsed.value, "B");
        try expectObservedGlobalId(response.parsed.value);
    }

    try client_a.write("{\"jsonrpc\":\"2.0\",\"id\":303,\"method\":\"fanout\",\"params\":{}}");
    try expectFanoutNotification(client_a, allocator);
    try expectFanoutNotification(client_b, allocator);
}

test "vc-mux serializes concurrent initialize and replays cached response on later clients" {
    const allocator = testing.allocator;
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;

    const bin_paths = try testBinaries(allocator);
    defer bin_paths.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const socket_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/vc-mux-concurrent-init.sock",
        .{tmp.sub_path},
    );
    defer allocator.free(socket_path);

    // Force the mock server to stall before answering `initialize` so the
    // second client lands inside the `initialize_in_flight` window and
    // exercises the `.wait` branch in State.registerInitializeRequest.
    var env_map = try testing.environ.createMap(allocator);
    defer env_map.deinit();
    try env_map.put("VC_MUX_MOCK_INIT_DELAY_MS", "300");

    const mux_argv = &[_][]const u8{
        bin_paths.mux,
        "--socket",
        socket_path,
        "--max-active-clients",
        "8",
        "--cmd",
        bin_paths.mock_server,
    };
    var mux = try std.process.spawn(io, .{
        .argv = mux_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
    });
    defer mux.kill(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    var client_a = try connectClient(allocator, socket_path);
    defer client_a.destroy();
    var client_b = try connectClient(allocator, socket_path);
    defer client_b.destroy();

    // Client A fires initialize first → `.forward` branch (sent to server).
    try client_a.write("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");

    // Give A a head start so its initialize is registered as in-flight.
    // The mock server is still inside its 300 ms sleep when B arrives.
    try std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);

    // Client B fires initialize while A's initialize is still in flight →
    // `.wait` branch. State queues B as a waiter; completeInitialize must
    // drain it with the cached payload rewritten to B's local id.
    try client_b.write("{\"jsonrpc\":\"2.0\",\"id\":\"init-b\",\"method\":\"initialize\",\"params\":{}}");

    {
        var response = try client_a.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .integer = 1 });
        try expectResultObject(response.parsed.value);
    }
    {
        var response = try client_b.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .string = "init-b" });
        try expectResultObject(response.parsed.value);
    }

    // Now the initialize response is cached. A late-joining client must hit
    // the `.replay` branch — its initialize is answered locally with the
    // cached payload rewritten to client C's id, without touching the
    // upstream server.
    var client_c = try connectClient(allocator, socket_path);
    defer client_c.destroy();

    try client_c.write("{\"jsonrpc\":\"2.0\",\"id\":303,\"method\":\"initialize\",\"params\":{}}");
    {
        var response = try client_c.read(allocator);
        defer response.deinit();
        try expectId(response.parsed.value, .{ .integer = 303 });
        try expectResultObject(response.parsed.value);
    }
}

const TestBinaries = struct {
    mux: []const u8,
    mock_server: []const u8,

    fn deinit(self: TestBinaries, allocator: std.mem.Allocator) void {
        allocator.free(self.mux);
        allocator.free(self.mock_server);
    }
};

fn testBinaries(allocator: std.mem.Allocator) !TestBinaries {
    const mux_env = std.process.Environ.getAlloc(testing.environ, allocator, "VC_MUX_TEST_BIN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    const mock_env = std.process.Environ.getAlloc(testing.environ, allocator, "VC_MUX_MOCK_BIN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => {
            if (mux_env) |mux| allocator.free(mux);
            return err;
        },
    };
    if (mux_env) |mux| {
        if (mock_env) |mock_server| return .{ .mux = mux, .mock_server = mock_server };
        allocator.free(mux);
    }
    if (mock_env) |mock_server| allocator.free(mock_server);
    return error.SkipZigTest;
}

fn connectClient(allocator: std.mem.Allocator, socket_path: []const u8) !*Client {
    const ua = try std.Io.net.UnixAddress.init(socket_path);
    var last_err: anyerror = error.FileNotFound;
    for (0..100) |_| {
        const stream = ua.connect(io) catch |err| {
            last_err = err;
            try std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
            continue;
        };
        return Client.create(allocator, stream);
    }
    return last_err;
}

fn expectFanoutNotification(client: *Client, allocator: std.mem.Allocator) !void {
    for (0..4) |_| {
        var msg = try client.read(allocator);
        defer msg.deinit();
        if (isFanoutNotification(msg.parsed.value)) return;
    }
    return error.MissingFanoutNotification;
}

fn isFanoutNotification(value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    const method = object.get("method") orelse return false;
    if (method != .string or !std.mem.eql(u8, method.string, "server/notice")) return false;
    const params = object.get("params") orelse return false;
    if (params != .object) return false;
    const fanout = params.object.get("value") orelse return false;
    return fanout == .string and std.mem.eql(u8, fanout.string, "fanout");
}

fn expectId(value: std.json.Value, expected: std.json.Value) !void {
    try testing.expect(value == .object);
    const actual = value.object.get("id") orelse return error.MissingId;
    switch (expected) {
        .integer => |expected_int| {
            try testing.expect(actual == .integer);
            try testing.expectEqual(expected_int, actual.integer);
        },
        .string => |expected_string| {
            try testing.expect(actual == .string);
            try testing.expectEqualStrings(expected_string, actual.string);
        },
        else => unreachable,
    }
}

fn expectResultObject(value: std.json.Value) !void {
    try testing.expect(value == .object);
    const result = value.object.get("result") orelse return error.MissingResult;
    try testing.expect(result == .object);
}

fn expectEcho(value: std.json.Value, expected: []const u8) !void {
    try testing.expect(value == .object);
    const result = value.object.get("result") orelse return error.MissingResult;
    try testing.expect(result == .object);
    const echoed = result.object.get("value") orelse return error.MissingEchoValue;
    try testing.expect(echoed == .string);
    try testing.expectEqualStrings(expected, echoed.string);
}

fn expectObservedGlobalId(value: std.json.Value) !void {
    try testing.expect(value == .object);
    const result = value.object.get("result") orelse return error.MissingResult;
    try testing.expect(result == .object);
    const observed = result.object.get("observed_id") orelse return error.MissingObservedId;
    try testing.expect(observed == .string);
    try testing.expect(std.mem.startsWith(u8, observed.string, "c"));
    try testing.expect(std.mem.indexOf(u8, observed.string, ":r") != null);
}
