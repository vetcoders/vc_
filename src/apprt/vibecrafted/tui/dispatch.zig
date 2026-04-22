//! Dispatch-tab state machine for the vibecrafted operator TUI (Track T3).
//!
//! Ports the launch-form state from `vc-operator/src/app.rs` and
//! `vc-operator/src/launch.rs` into Zig: mission kind, agent, runtime, and a
//! fixed-capacity prompt buffer plus a bounded launch-history ring. No
//! spawning, no shell quoting, no process APIs — those belong to the runtime
//! layer (T4). This module only answers: "given the user's keystrokes, what
//! should the form show next?".

const std = @import("std");
const Allocator = std.mem.Allocator;

const tabs = @import("tabs.zig");
pub const DispatchFocus = tabs.DispatchFocus;

pub const LaunchKind = enum(u8) {
    workflow = 0,
    research = 1,
    review = 2,
    marbles = 3,

    pub const count: usize = 4;

    pub fn label(self: LaunchKind) []const u8 {
        return switch (self) {
            .workflow => "workflow",
            .research => "research",
            .review => "review",
            .marbles => "marbles",
        };
    }

    pub fn humanTitle(self: LaunchKind) []const u8 {
        return switch (self) {
            .workflow => "Workflow",
            .research => "Research swarm",
            .review => "Review",
            .marbles => "Marbles loop",
        };
    }

    pub fn defaultPrompt(self: LaunchKind) []const u8 {
        return switch (self) {
            .workflow => "Plan and implement the task I am looking at now.",
            .research => "Research the task I am looking at now and report the ground truth.",
            .review => "Review the selected surface and call out concrete risks.",
            .marbles => "Run a convergence loop on the selected surface until the lies are exposed.",
        };
    }
};

pub const AgentId = enum(u8) {
    claude = 0,
    codex = 1,
    gemini = 2,

    pub const count: usize = 3;

    pub fn label(self: AgentId) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .gemini => "gemini",
        };
    }
};

pub const LaunchRuntime = enum(u8) {
    headless = 0,
    terminal = 1,
    visible = 2,

    pub const count: usize = 3;

    pub fn label(self: LaunchRuntime) []const u8 {
        return switch (self) {
            .headless => "headless",
            .terminal => "terminal",
            .visible => "visible",
        };
    }
};

pub const prompt_capacity: usize = 512;
pub const history_capacity: usize = 6;

pub const DispatchState = struct {
    const Self = @This();

    kind: LaunchKind = .workflow,
    agent: AgentId = .claude,
    runtime: LaunchRuntime = .terminal,
    focus: DispatchFocus = .kind,

    prompt_buf: [prompt_capacity]u8 = undefined,
    prompt_len: usize = 0,

    history_buf: [history_capacity][prompt_capacity]u8 = undefined,
    history_len_buf: [history_capacity]usize = @splat(0),
    history_len: usize = 0,
    history_next: usize = 0,

    pub fn init() Self {
        var self: Self = .{};
        self.writePromptAssumeFits(LaunchKind.workflow.defaultPrompt());
        return self;
    }

    pub fn prompt(self: *const Self) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }

    pub fn setKind(self: *Self, kind: LaunchKind) void {
        self.kind = kind;
        self.writePromptAssumeFits(kind.defaultPrompt());
    }

    pub fn shiftKind(self: *Self, delta: isize) void {
        const next = cyclicShift(@intFromEnum(self.kind), LaunchKind.count, delta);
        self.setKind(@enumFromInt(next));
    }

    pub fn shiftAgent(self: *Self, delta: isize) void {
        const next = cyclicShift(@intFromEnum(self.agent), AgentId.count, delta);
        self.agent = @enumFromInt(next);
    }

    pub fn shiftRuntime(self: *Self, delta: isize) void {
        const next = cyclicShift(@intFromEnum(self.runtime), LaunchRuntime.count, delta);
        self.runtime = @enumFromInt(next);
    }

    pub fn moveFocus(self: *Self, delta: isize) void {
        const current: isize = @intCast(@intFromEnum(self.focus));
        const count: isize = @intCast(DispatchFocus.count);
        var index = current + delta;
        while (index < 0) index += count;
        self.focus = DispatchFocus.fromIndex(@intCast(index));
    }

    /// Route an adjustment (±1) to the currently focused field. Mirrors the
    /// Rust `adjust_dispatch_selection` path: prompt field does not adjust
    /// here — editing is a separate focus state (`Focus.edit_prompt`) owned
    /// by `tabs.zig`.
    pub fn adjustFocused(self: *Self, delta: isize) void {
        switch (self.focus) {
            .kind => self.shiftKind(delta),
            .agent => self.shiftAgent(delta),
            .runtime => self.shiftRuntime(delta),
            .prompt => {},
        }
    }

    pub fn setPrompt(self: *Self, text: []const u8) error{PromptTooLong}!void {
        if (text.len > prompt_capacity) return error.PromptTooLong;
        self.writePromptAssumeFits(text);
    }

    pub fn pushHistory(self: *Self, entry: []const u8) void {
        const len = @min(entry.len, prompt_capacity);
        const slot = self.history_next;
        @memcpy(self.history_buf[slot][0..len], entry[0..len]);
        self.history_len_buf[slot] = len;
        self.history_next = (slot + 1) % history_capacity;
        if (self.history_len < history_capacity) self.history_len += 1;
    }

    pub fn historyLen(self: *const Self) usize {
        return self.history_len;
    }

    /// Retrieve history entries newest-first. `offset == 0` returns the most
    /// recently pushed entry; higher values walk backwards.
    pub fn historyEntry(self: *const Self, offset: usize) ?[]const u8 {
        if (offset >= self.history_len) return null;
        const slot = (self.history_next + history_capacity - 1 - offset) % history_capacity;
        return self.history_buf[slot][0..self.history_len_buf[slot]];
    }

    fn writePromptAssumeFits(self: *Self, text: []const u8) void {
        std.debug.assert(text.len <= prompt_capacity);
        @memcpy(self.prompt_buf[0..text.len], text);
        self.prompt_len = text.len;
    }
};

fn cyclicShift(current: u8, count: usize, delta: isize) u8 {
    const count_i: isize = @intCast(count);
    var index: isize = @as(isize, current) + delta;
    while (index < 0) index += count_i;
    return @intCast(@mod(index, count_i));
}

test "LaunchKind labels + default prompts are stable" {
    try std.testing.expectEqualStrings("workflow", LaunchKind.workflow.label());
    try std.testing.expectEqualStrings("research", LaunchKind.research.label());
    try std.testing.expectEqualStrings("review", LaunchKind.review.label());
    try std.testing.expectEqualStrings("marbles", LaunchKind.marbles.label());

    try std.testing.expectEqualStrings("Workflow", LaunchKind.workflow.humanTitle());
    try std.testing.expect(LaunchKind.research.defaultPrompt().len > 0);
    try std.testing.expect(LaunchKind.marbles.defaultPrompt().len > 0);
}

test "AgentId + LaunchRuntime counts agree with enum widths" {
    try std.testing.expectEqual(@as(usize, 3), AgentId.count);
    try std.testing.expectEqual(@as(usize, 3), LaunchRuntime.count);
    try std.testing.expectEqualStrings("claude", AgentId.claude.label());
    try std.testing.expectEqualStrings("terminal", LaunchRuntime.terminal.label());
}

test "DispatchState.init seeds workflow defaults" {
    const state = DispatchState.init();
    try std.testing.expectEqual(LaunchKind.workflow, state.kind);
    try std.testing.expectEqual(AgentId.claude, state.agent);
    try std.testing.expectEqual(LaunchRuntime.terminal, state.runtime);
    try std.testing.expectEqual(DispatchFocus.kind, state.focus);
    try std.testing.expectEqualStrings(
        LaunchKind.workflow.defaultPrompt(),
        state.prompt(),
    );
}

test "DispatchState.shiftKind wraps and rewrites default prompt" {
    var state = DispatchState.init();

    state.shiftKind(1);
    try std.testing.expectEqual(LaunchKind.research, state.kind);
    try std.testing.expectEqualStrings(LaunchKind.research.defaultPrompt(), state.prompt());

    state.shiftKind(2);
    try std.testing.expectEqual(LaunchKind.marbles, state.kind);

    state.shiftKind(1);
    try std.testing.expectEqual(LaunchKind.workflow, state.kind);

    state.shiftKind(-1);
    try std.testing.expectEqual(LaunchKind.marbles, state.kind);

    state.shiftKind(4);
    try std.testing.expectEqual(LaunchKind.marbles, state.kind);
}

test "DispatchState.shiftAgent / shiftRuntime cycle forward and backward" {
    var state = DispatchState.init();

    state.shiftAgent(1);
    try std.testing.expectEqual(AgentId.codex, state.agent);
    state.shiftAgent(1);
    try std.testing.expectEqual(AgentId.gemini, state.agent);
    state.shiftAgent(1);
    try std.testing.expectEqual(AgentId.claude, state.agent);
    state.shiftAgent(-1);
    try std.testing.expectEqual(AgentId.gemini, state.agent);

    state.shiftRuntime(1);
    try std.testing.expectEqual(LaunchRuntime.visible, state.runtime);
    state.shiftRuntime(-2);
    try std.testing.expectEqual(LaunchRuntime.headless, state.runtime);
}

test "DispatchState.moveFocus cycles through all four fields" {
    var state = DispatchState.init();

    state.moveFocus(1);
    try std.testing.expectEqual(DispatchFocus.agent, state.focus);
    state.moveFocus(1);
    try std.testing.expectEqual(DispatchFocus.runtime, state.focus);
    state.moveFocus(1);
    try std.testing.expectEqual(DispatchFocus.prompt, state.focus);
    state.moveFocus(1);
    try std.testing.expectEqual(DispatchFocus.kind, state.focus);
    state.moveFocus(-1);
    try std.testing.expectEqual(DispatchFocus.prompt, state.focus);
}

test "DispatchState.adjustFocused routes to the focused field only" {
    var state = DispatchState.init();

    state.focus = .agent;
    state.adjustFocused(1);
    try std.testing.expectEqual(AgentId.codex, state.agent);
    try std.testing.expectEqual(LaunchKind.workflow, state.kind);

    state.focus = .runtime;
    state.adjustFocused(-1);
    try std.testing.expectEqual(LaunchRuntime.headless, state.runtime);

    state.focus = .kind;
    state.adjustFocused(2);
    try std.testing.expectEqual(LaunchKind.review, state.kind);

    // Prompt focus is a no-op for adjust — editing is a separate state.
    state.focus = .prompt;
    state.adjustFocused(1);
    try std.testing.expectEqualStrings(LaunchKind.review.defaultPrompt(), state.prompt());
}

test "DispatchState.setPrompt accepts short and rejects overflow" {
    var state = DispatchState.init();
    try state.setPrompt("run this");
    try std.testing.expectEqualStrings("run this", state.prompt());

    var big: [prompt_capacity + 1]u8 = @splat('x');
    try std.testing.expectError(error.PromptTooLong, state.setPrompt(&big));
}

test "DispatchState.history is a bounded ring with newest-first access" {
    var state = DispatchState.init();

    try std.testing.expectEqual(@as(usize, 0), state.historyLen());
    try std.testing.expect(state.historyEntry(0) == null);

    state.pushHistory("one");
    state.pushHistory("two");
    state.pushHistory("three");

    try std.testing.expectEqual(@as(usize, 3), state.historyLen());
    try std.testing.expectEqualStrings("three", state.historyEntry(0).?);
    try std.testing.expectEqualStrings("two", state.historyEntry(1).?);
    try std.testing.expectEqualStrings("one", state.historyEntry(2).?);

    for ([_][]const u8{ "four", "five", "six", "seven" }) |entry| state.pushHistory(entry);

    try std.testing.expectEqual(history_capacity, state.historyLen());
    try std.testing.expectEqualStrings("seven", state.historyEntry(0).?);
    try std.testing.expectEqualStrings("two", state.historyEntry(history_capacity - 1).?);
    try std.testing.expect(state.historyEntry(history_capacity) == null);
}
