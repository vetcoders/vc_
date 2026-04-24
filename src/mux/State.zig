const std = @import("std");

pub const PendingRequest = struct {
    client_id: usize,
    // JSON text for the original client id. String IDs must keep their quotes
    // so they can be parsed back into a response id later.
    local_id: []const u8,
    is_initialize: bool,

    pub fn deinit(self: PendingRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.local_id);
    }
};

pub const InitializeRequest = union(enum) {
    forward: []const u8,
    wait,
    replay: []const u8,

    pub fn deinit(self: InitializeRequest, allocator: std.mem.Allocator) void {
        switch (self) {
            .forward, .replay => |payload| allocator.free(payload),
            .wait => {},
        }
    }
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
    initialize_waiters: std.ArrayListUnmanaged(PendingRequest) = .empty,

    request_counter: usize = 0,
    initialize_in_flight: bool = false,
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

        return try self.registerPendingRequestLocked(client_id, local_id, is_init);
    }

    pub fn registerInitializeRequest(self: *State, client_id: usize, local_id: []const u8) !InitializeRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.cached_initialize) |cached| {
            return .{ .replay = try self.allocator.dupe(u8, cached) };
        }

        if (self.initialize_in_flight) {
            const stored_local_id = try self.allocator.dupe(u8, local_id);
            errdefer self.allocator.free(stored_local_id);

            try self.initialize_waiters.append(self.allocator, .{
                .client_id = client_id,
                .local_id = stored_local_id,
                .is_initialize = true,
            });
            return .wait;
        }

        const global_id = try self.registerPendingRequestLocked(client_id, local_id, true);
        self.initialize_in_flight = true;
        return .{ .forward = global_id };
    }

    pub fn completeInitialize(self: *State, response_payload: []const u8) ![]PendingRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.cached_initialize) |old| self.allocator.free(old);
        self.cached_initialize = try self.allocator.dupe(u8, response_payload);
        self.initialize_in_flight = false;

        const waiters = try self.initialize_waiters.toOwnedSlice(self.allocator);
        self.initialize_waiters = .empty;
        return waiters;
    }

    fn registerPendingRequestLocked(self: *State, client_id: usize, local_id: []const u8, is_init: bool) ![]const u8 {
        self.request_counter += 1;
        const global_id = try std.fmt.allocPrint(self.allocator, "c{d}:r{d}", .{ client_id, self.request_counter });
        errdefer self.allocator.free(global_id);

        const stored_local_id = try self.allocator.dupe(u8, local_id);
        errdefer self.allocator.free(stored_local_id);

        try self.pending.put(self.allocator, global_id, .{
            .client_id = client_id,
            .local_id = stored_local_id,
            .is_initialize = is_init,
        });

        // Return a dupe so the caller owns it and we don't have use-after-free if take happens concurrently.
        return self.allocator.dupe(u8, global_id) catch |err| {
            if (self.pending.fetchRemove(global_id)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit(self.allocator);
            }
            return err;
        };
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
