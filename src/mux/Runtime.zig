const std = @import("std");
const Config = @import("Config.zig").Config;
const State = @import("State.zig").State;
const ClientChannel = @import("State.zig").ClientChannel;
const JsonRpc = @import("JsonRpc.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,

    active_clients: std.atomic.Value(usize),
    client_counter: std.atomic.Value(usize),

    state: State,

    child: ?std.process.Child = null,
    child_stdin_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !*Runtime {
        const runtime = try allocator.create(Runtime);
        runtime.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .active_clients = std.atomic.Value(usize).init(0),
            .client_counter = std.atomic.Value(usize).init(0),
            .state = State.init(allocator, io),
        };
        return runtime;
    }

    pub fn run(self: *Runtime) !void {
        var child_args: std.ArrayList([]const u8) = .empty;
        defer child_args.deinit(self.allocator);
        try child_args.append(self.allocator, self.config.cmd_name);
        for (self.config.cmd_args) |arg| {
            try child_args.append(self.allocator, arg);
        }

        const child_args_slice = try child_args.toOwnedSlice(self.allocator);
        defer self.allocator.free(child_args_slice);

        const child = try std.process.spawn(self.io, .{
            .argv = child_args_slice,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.child = child;

        std.debug.print("Spawned child process.\n", .{});

        const server_reader_thread = try std.Thread.spawn(.{}, serverReader, .{self});
        server_reader_thread.detach();

        _ = std.Io.Dir.cwd().deleteFile(self.io, self.config.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const ua = try std.Io.net.UnixAddress.init(self.config.socket_path);
        var server = try ua.listen(self.io, .{});
        defer server.deinit(self.io);

        std.debug.print("Server listening on socket {s}\n", .{self.config.socket_path});

        while (true) {
            const stream = try server.accept(self.io);
            std.debug.print("Client connected.\n", .{});

            const thread = try std.Thread.spawn(.{}, handleClient, .{ self, stream });
            thread.detach();
        }
    }

    fn serverReader(self: *Runtime) void {
        const stdout = self.child.?.stdout.?;
        var read_buf: [8192]u8 = undefined;
        var reader = stdout.reader(self.io, &read_buf);
        const io_reader = &reader.interface;

        while (true) {
            var msg_opt = JsonRpc.Codec.readMessage(self.allocator, io_reader) catch |err| {
                std.debug.print("Error reading from server: {}\n", .{err});
                break;
            };
            if (msg_opt) |*msg| {
                defer msg.deinit();
                self.routeServerMessage(msg.parsed.value) catch |err| {
                    std.debug.print("Error routing server message: {}\n", .{err});
                };
            } else {
                break; // EOF
            }
        }
        std.debug.print("Server reader exited.\n", .{});
    }

    fn writeToServer(self: *Runtime, payload: []const u8) !void {
        if (self.child.?.stdin) |stdin| {
            self.child_stdin_mutex.lockUncancelable(self.io);
            defer self.child_stdin_mutex.unlock(self.io);
            var write_buf: [8192]u8 = undefined;
            var writer = stdin.writer(self.io, &write_buf);
            const io_writer = &writer.interface;
            try io_writer.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
            try io_writer.flush();
        }
    }

    fn routeServerMessage(self: *Runtime, value: std.json.Value) !void {
        if (value != .object) return;
        var map = value.object;

        // Is it a response? (has id, no method)
        if (map.get("id")) |id_val| {
            if (!map.contains("method")) {
                const global_id_str = try stringifyValue(self.allocator, id_val);
                defer self.allocator.free(global_id_str);

                if (self.state.takePendingRequest(global_id_str)) |pending| {
                    defer self.allocator.free(pending.local_id);

                    // Rewrite ID back to local
                    var local_id_val = try parseStringAsValue(self.allocator, pending.local_id);
                    defer local_id_val.deinit();

                    // Put local id back
                    try map.put(self.allocator, "id", local_id_val.value);

                    const payload = try stringifyValueAlloc(self.allocator, value);
                    defer self.allocator.free(payload);

                    self.state.mutex.lockUncancelable(self.io);
                    if (self.state.clients.get(pending.client_id)) |channel| {
                        self.state.mutex.unlock(self.io);
                        try channel.send(self.io, self.allocator, payload);
                    } else {
                        self.state.mutex.unlock(self.io);
                    }
                    return;
                }
            }
        }

        // Notification, broadcast
        const payload = try stringifyValueAlloc(self.allocator, value);
        defer self.allocator.free(payload);

        self.state.mutex.lockUncancelable(self.io);
        defer self.state.mutex.unlock(self.io);
        var it = self.state.clients.valueIterator();
        while (it.next()) |channel| {
            channel.*.send(self.io, self.allocator, payload) catch {};
        }
    }

    fn handleClient(self: *Runtime, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        var current = self.active_clients.load(.acquire);
        while (true) {
            if (current >= self.config.max_active_clients) {
                std.debug.print("Max clients reached. Rejecting connection.\n", .{});
                return;
            }
            if (self.active_clients.cmpxchgWeak(current, current + 1, .acquire, .monotonic)) |new_current| {
                current = new_current;
            } else {
                break;
            }
        }
        defer _ = self.active_clients.fetchSub(1, .release);

        const client_id = self.client_counter.fetchAdd(1, .monotonic);
        std.debug.print("Client {} started. Active clients: {}\n", .{ client_id, self.active_clients.load(.acquire) });

        var channel = ClientChannel{};
        self.state.registerClient(client_id, &channel) catch return;
        defer self.state.unregisterClient(client_id);

        // Writer thread to client
        const writer_thread = std.Thread.spawn(.{}, clientWriter, .{ self, stream, &channel }) catch return;

        var read_buf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        const io_reader = &reader.interface;
        while (true) {
            var msg_opt = JsonRpc.Codec.readMessage(self.allocator, io_reader) catch |err| {
                std.debug.print("Error reading from client {}: {}\n", .{ client_id, err });
                break;
            };
            if (msg_opt) |*msg| {
                defer msg.deinit();
                self.routeClientMessage(client_id, msg.parsed.value) catch |err| {
                    std.debug.print("Error routing client message: {}\n", .{err});
                };
            } else {
                break;
            }
        }
        channel.close(self.io);
        writer_thread.join();
        std.debug.print("Client {} disconnected.\n", .{client_id});
    }

    fn clientWriter(self: *Runtime, stream: std.Io.net.Stream, channel: *ClientChannel) void {
        var write_buf: [8192]u8 = undefined;
        var writer = stream.writer(self.io, &write_buf);
        const io_writer = &writer.interface;
        while (true) {
            const payload = channel.recv(self.io) catch break;
            defer self.allocator.free(payload);

            // We expect the payload to be just the raw JSON. We must format it with Content-Length.
            io_writer.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload }) catch break;
            io_writer.flush() catch break;
        }
    }

    fn routeClientMessage(self: *Runtime, client_id: usize, value: std.json.Value) !void {
        if (value != .object) return;
        var map = value.object;

        if (map.get("id")) |id_val| {
            // It's a request
            const is_init = if (map.get("method")) |m| std.mem.eql(u8, m.string, "initialize") else false;

            const local_id_str = try stringifyValue(self.allocator, id_val);
            defer self.allocator.free(local_id_str);

            const global_id_str = try self.state.registerPendingRequest(client_id, local_id_str, is_init);
            defer self.allocator.free(global_id_str);

            // Overwrite id
            try map.put(self.allocator, "id", std.json.Value{ .string = global_id_str });

            const payload = try stringifyValueAlloc(self.allocator, value);
            defer self.allocator.free(payload);

            try self.writeToServer(payload);
        } else {
            // It's a notification, forward directly
            const payload = try stringifyValueAlloc(self.allocator, value);
            defer self.allocator.free(payload);

            try self.writeToServer(payload);
        }
    }

    fn stringifyValueAlloc(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{}", .{std.json.fmt(val, .{})});
    }

    fn stringifyValue(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
        if (val == .string) return try allocator.dupe(u8, val.string);
        return try stringifyValueAlloc(allocator, val);
    }

    fn parseStringAsValue(allocator: std.mem.Allocator, str: []const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, str, .{});
    }
};
