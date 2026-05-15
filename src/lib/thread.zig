const std = @import("std");

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(std.Options.debug_io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(std.Options.debug_io);
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(std.Options.debug_io, &mutex.inner);
    }

    pub fn timedWait(_: *Condition, _: *Mutex, _: u64) error{Timeout}!void {
        return error.Timeout;
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(std.Options.debug_io);
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(std.Options.debug_io);
    }
};

pub const Semaphore = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    permits: usize = 0,

    pub fn wait(self: *Semaphore) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        while (self.permits == 0) self.cond.waitUncancelable(std.Options.debug_io, &self.mutex);
        self.permits -= 1;
        if (self.permits > 0) self.cond.signal(std.Options.debug_io);
    }

    pub fn post(self: *Semaphore) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        self.permits += 1;
        self.cond.signal(std.Options.debug_io);
    }
};

pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(std.Options.debug_io);
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(std.Options.debug_io);
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(std.Options.debug_io);
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(std.Options.debug_io);
    }
};
