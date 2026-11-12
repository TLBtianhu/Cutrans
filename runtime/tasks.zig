//! tasks.zig — 每会话独立的长任务与状态事件
//!
//! TaskId 单调发放,终结状态不可改写;事件环只保存最近记录,事件 serial
//! 仍保持单调,便于以后按游标消费和回放。

const std = @import("std");
const command = @import("vne").command;

pub const Id = u64;
pub const State = enum { queued, running, succeeded, failed, cancelled, interrupted };
pub fn terminal(state: State) bool {
    return state != .queued and state != .running;
}
pub const EventKind = enum { task_changed };

pub const Event = struct {
    serial: u64,
    kind: EventKind,
    task_id: Id,
    state: State,
    progress_milli: ?u32,
};

pub const Task = struct {
    id: Id,
    state: State,
    progress_milli: ?u32 = null,
    result: ?command.Code = null,
};

pub const Registry = struct {
    /// Active tasks and a recent terminal projection. Durable records own the
    /// complete history; filling this cache is not a lifetime admission limit.
    items: [40]Task = undefined,
    count: usize = 0,
    task_clock: u64 = 0,
    events: [64]Event = undefined,
    event_clock: u64 = 0,
    /// The serial survives recovery; ring contents do not. Never infer the
    /// number of initialized ring entries from a restored serial alone.
    event_count: usize = 0,

    pub fn init(self: *Registry) void {
        self.* = .{};
    }

    pub fn reset(self: *Registry) void {
        self.init();
    }

    fn emit(self: *Registry, task: Task) void {
        std.debug.assert(self.event_clock != std.math.maxInt(u64));
        self.event_clock += 1;
        self.events[(self.event_clock - 1) % self.events.len] = .{
            .serial = self.event_clock,
            .kind = .task_changed,
            .task_id = task.id,
            .state = task.state,
            .progress_milli = task.progress_milli,
        };
        self.event_count = @min(self.event_count + 1, self.events.len);
    }

    fn find(self: *Registry, id: Id) ?*Task {
        for (self.items[0..self.count]) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    pub fn get(self: *const Registry, id: Id) ?Task {
        for (self.items[0..self.count]) |task| {
            if (task.id == id) return task;
        }
        return null;
    }

    pub fn start(self: *Registry) ?Id {
        if (self.task_clock == std.math.maxInt(u64) or self.event_clock == std.math.maxInt(u64)) return null;
        if (self.count == self.items.len) self.evictOldestTerminal() catch return null;
        self.task_clock += 1;
        const id = self.task_clock;
        self.items[self.count] = .{ .id = id, .state = .queued };
        self.count += 1;
        self.emit(self.items[self.count - 1]);
        return id;
    }

    pub fn markRunning(self: *Registry, id: Id) bool {
        if (self.event_clock == std.math.maxInt(u64)) return false;
        const task = self.find(id) orelse return false;
        if (task.state != .queued) return false;
        task.state = .running;
        self.emit(task.*);
        return true;
    }

    pub fn progress(self: *Registry, id: Id, milli: u32) bool {
        if (milli > 1000 or self.event_clock == std.math.maxInt(u64)) return false;
        const task = self.find(id) orelse return false;
        if (task.state != .queued and task.state != .running) return false;
        task.progress_milli = milli;
        self.emit(task.*);
        return true;
    }

    fn finish(self: *Registry, id: Id, state: State, result: command.Code) bool {
        if (self.event_clock == std.math.maxInt(u64)) return false;
        const task = self.find(id) orelse return false;
        if (task.state != .queued and task.state != .running) return false;
        task.state = state;
        task.result = result;
        self.emit(task.*);
        return true;
    }

    pub fn succeed(self: *Registry, id: Id) bool {
        return self.finish(id, .succeeded, .ok);
    }

    pub fn fail(self: *Registry, id: Id, code: command.Code) bool {
        if (code == .ok or code == .accepted or code == .cancelled) return false;
        return self.finish(id, .failed, code);
    }

    pub fn cancel(self: *Registry, id: Id) bool {
        return self.finish(id, .cancelled, .cancelled);
    }

    pub fn recoverInterrupted(self: *Registry) usize {
        var recovered: usize = 0;
        for (self.items[0..self.count]) |*task| {
            if (task.state != .queued and task.state != .running) continue;
            if (self.event_clock == std.math.maxInt(u64)) break;
            task.state = .interrupted;
            task.result = .failed;
            recovered += 1;
            self.emit(task.*);
        }
        return recovered;
    }

    fn oldestTerminal(self: *const Registry) ?usize {
        var oldest: ?usize = null;
        for (self.items[0..self.count], 0..) |task, index| {
            if (!terminal(task.state)) continue;
            if (oldest == null or task.id < self.items[oldest.?].id) oldest = index;
        }
        return oldest;
    }

    fn evictOldestTerminal(self: *Registry) !void {
        const index = self.oldestTerminal() orelse return error.TaskCacheFull;
        std.mem.copyForwards(Task, self.items[index .. self.count - 1], self.items[index + 1 .. self.count]);
        self.count -= 1;
    }

    /// Merge a durable projection without inventing a new task/event. Records
    /// may be scanned in any order; retain the newest terminal IDs and all active
    /// entries. A caller persists its candidate before publishing this cache.
    pub fn put(self: *Registry, task: Task) !void {
        if (task.id == 0) return error.InvalidTask;
        if (self.find(task.id)) |existing| {
            existing.* = task;
        } else {
            if (self.count == self.items.len) {
                const oldest = self.oldestTerminal() orelse return error.TaskCacheFull;
                if (terminal(task.state) and task.id < self.items[oldest].id) {
                    self.task_clock = @max(self.task_clock, task.id);
                    return;
                }
                try self.evictOldestTerminal();
            }
            var index = self.count;
            while (index > 0 and self.items[index - 1].id > task.id) : (index -= 1) self.items[index] = self.items[index - 1];
            self.items[index] = task;
            self.count += 1;
        }
        self.task_clock = @max(self.task_clock, task.id);
    }

    pub fn observeRestored(self: *Registry, task: Task) !void {
        if (self.event_clock == std.math.maxInt(u64)) return error.TaskClockOverflow;
        try self.put(task);
        self.emit(task);
    }

    pub fn recentEvents(self: *const Registry, buf: []Event) []Event {
        const n = @min(buf.len, self.event_count);
        for (0..n) |i| {
            buf[i] = self.events[(self.event_clock - 1 - i) % self.events.len];
        }
        return buf[0..n];
    }
};

test "task lifecycle emits ordered events and terminal states are final" {
    var registry: Registry = undefined;
    registry.init();
    const id = registry.start().?;
    try std.testing.expectEqual(State.queued, registry.get(id).?.state);
    try std.testing.expect(registry.markRunning(id));
    try std.testing.expect(registry.progress(id, 250));
    try std.testing.expectEqual(@as(u32, 250), registry.get(id).?.progress_milli.?);
    try std.testing.expect(registry.succeed(id));
    try std.testing.expectEqual(command.Code.ok, registry.get(id).?.result.?);
    try std.testing.expect(!registry.progress(id, 500));
    try std.testing.expect(!registry.cancel(id));

    var buf: [8]Event = undefined;
    const events = registry.recentEvents(&buf);
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqual(State.succeeded, events[0].state);
    try std.testing.expectEqual(State.running, events[1].state);
    try std.testing.expectEqual(State.running, events[2].state);
    try std.testing.expectEqual(State.queued, events[3].state);
    try std.testing.expect(events[0].serial > events[3].serial);
}

test "failure and cancellation use distinct terminal results" {
    var registry: Registry = undefined;
    registry.init();
    const failed = registry.start().?;
    try std.testing.expect(registry.fail(failed, .invalid_state));
    try std.testing.expectEqual(State.failed, registry.get(failed).?.state);
    try std.testing.expectEqual(command.Code.invalid_state, registry.get(failed).?.result.?);
    try std.testing.expect(!registry.fail(failed, .failed));

    const cancelled = registry.start().?;
    try std.testing.expect(registry.cancel(cancelled));
    try std.testing.expectEqual(State.cancelled, registry.get(cancelled).?.state);
    try std.testing.expectEqual(command.Code.cancelled, registry.get(cancelled).?.result.?);
    try std.testing.expect(!registry.fail(registry.start().?, .ok));
}

test "task registries do not share ids or events" {
    var first: Registry = undefined;
    var second: Registry = undefined;
    first.init();
    second.init();
    const first_id = first.start().?;
    try std.testing.expectEqual(first_id, second.start().?);
    try std.testing.expect(first.succeed(first_id));
    try std.testing.expectEqual(State.queued, second.get(first_id).?.state);
    var buf: [1]Event = undefined;
    try std.testing.expectEqual(State.succeeded, first.recentEvents(&buf)[0].state);
    try std.testing.expectEqual(State.queued, second.recentEvents(&buf)[0].state);
}

test "terminal cache eviction never imposes a lifetime task limit or evicts active tasks" {
    var registry: Registry = .{};
    const active = registry.start().?;
    for (0..100) |_| {
        const id = registry.start().?;
        try std.testing.expect(registry.succeed(id));
    }
    try std.testing.expectEqual(@as(usize, 40), registry.count);
    try std.testing.expectEqual(State.queued, registry.get(active).?.state);
    try std.testing.expect(registry.get(2) == null);
    try std.testing.expectEqual(@as(u64, 101), registry.task_clock);
    var full: Registry = .{};
    for (0..full.items.len) |_| _ = full.start().?;
    try std.testing.expect(full.start() == null);
    try std.testing.expectEqual(@as(u64, 40), full.task_clock);
}

test "task and event clocks reject overflow before state changes" {
    var registry: Registry = .{};
    const id = registry.start().?;
    registry.event_clock = std.math.maxInt(u64);
    try std.testing.expect(registry.start() == null);
    try std.testing.expect(!registry.markRunning(id));
    try std.testing.expect(!registry.progress(id, 1));
    try std.testing.expect(!registry.cancel(id));
    try std.testing.expectEqual(State.queued, registry.get(id).?.state);
    registry.event_clock = 1;
    registry.task_clock = std.math.maxInt(u64);
    try std.testing.expect(registry.start() == null);
}

test "restored serials do not expose uninitialized event ring entries" {
    var registry: Registry = .{};
    registry.event_clock = 100;
    var events: [64]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), registry.recentEvents(&events).len);
    try registry.observeRestored(.{ .id = 20, .state = .interrupted, .result = .failed });
    const recent = registry.recentEvents(&events);
    try std.testing.expectEqual(@as(usize, 1), recent.len);
    try std.testing.expectEqual(@as(u64, 101), recent[0].serial);
    try std.testing.expectEqual(@as(u64, 20), recent[0].task_id);
}
