const std = @import("std");

pub const PendingRequest = struct {
    client_id: usize,
    local_id: []const u8, // We will store it as stringified JSON so we don't worry about Arena lifetimes
    is_initialize: bool,
};

pub const ClientChannel = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayListUnmanaged([]const u8) = .empty,
    closed: bool = false,

    pub fn send(self: *ClientChannel, io: std.Io, allocator: std.mem.Allocator, payload: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.Closed;

        const copy = try allocator.dupe(u8, payload);
        try self.queue.append(allocator, copy);
        self.cond.signal(io);
    }

    pub fn recv(self: *ClientChannel, io: std.Io) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0) {
            if (self.closed) return error.Closed;
            self.cond.waitUncancelable(io, &self.mutex);
        }
        return self.queue.orderedRemove(0);
    }

    pub fn close(self: *ClientChannel, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.cond.broadcast(io);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    clients: std.AutoHashMapUnmanaged(usize, *ClientChannel) = .empty,
    pending: std.StringHashMapUnmanaged(PendingRequest) = .empty,

    request_counter: usize = 0,
    cached_initialize: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) State {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn registerClient(self: *State, client_id: usize, channel: *ClientChannel) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.clients.put(self.allocator, client_id, channel);
    }

    pub fn unregisterClient(self: *State, client_id: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.clients.remove(client_id);
    }

    pub fn nextRequestId(self: *State) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.request_counter += 1;
        return self.request_counter;
    }

    pub fn registerPendingRequest(self: *State, client_id: usize, local_id: []const u8, is_init: bool) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.request_counter += 1;
        const global_id = try std.fmt.allocPrint(self.allocator, "c{d}:r{d}", .{ client_id, self.request_counter });

        try self.pending.put(self.allocator, global_id, .{
            .client_id = client_id,
            .local_id = try self.allocator.dupe(u8, local_id),
            .is_initialize = is_init,
        });

        // Return a dupe so the caller owns it and we don't have use-after-free if take happens concurrently.
        return try self.allocator.dupe(u8, global_id);
    }

    pub fn takePendingRequest(self: *State, global_id: []const u8) ?PendingRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending.fetchRemove(global_id)) |kv| {
            self.allocator.free(kv.key);
            return kv.value;
        }
        return null;
    }
};
