//! Autonomous job execution is explicit caller policy; manual Runtime users opt in.
const std = @import("std");
const abi = @import("abi.zig");

pub const Pump = *const fn (?*anyopaque, ?*u32) callconv(.c) i32;

pub const Driver = struct {
    io: std.Io,
    context: ?*anyopaque,
    pump: Pump,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    idle: std.Io.Condition = .init,
    closing: bool = false,
    paused: bool = false,
    active: bool = false,
    notified: bool = true,
    failures: u8 = 0,
    retry_at: ?std.Io.Clock.Timestamp = null,
    /// When set, an idle driver also sweeps the queue at this interval, so
    /// in-process callers need not notify after every admission.
    poll_ms: ?u32 = null,

    /// Keep this object at the same address until deinit joins its thread.
    pub fn start(self: *Driver, io: std.Io, context: ?*anyopaque, pump: Pump) !void {
        self.* = .{ .io = io, .context = context, .pump = pump };
        self.thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, run, .{self});
    }

    /// Like `start`, plus a periodic idle sweep every `poll_ms` milliseconds.
    pub fn startPolling(self: *Driver, io: std.Io, context: ?*anyopaque, pump: Pump, poll_ms: u32) !void {
        self.* = .{ .io = io, .context = context, .pump = pump, .poll_ms = poll_ms };
        self.thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, run, .{self});
    }

    /// Admission may have committed even if constructing or sending its reply failed.
    pub fn notify(self: *Driver) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.notified = true;
        self.changed.signal(self.io);
    }

    /// Stop scheduling, then wait for the current synchronous attempt to return.
    /// This does not preempt PNG encoding or filesystem operations in that attempt.
    pub fn pauseAndWait(self: *Driver) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.paused = true;
        self.changed.signal(self.io);
        while (self.active) self.idle.waitUncancelable(self.io, &self.mutex);
    }

    pub fn resumeWork(self: *Driver) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.paused = false;
        self.notified = true;
        self.changed.signal(self.io);
    }

    /// Must precede Runtime destruction and unloading its DLL.
    pub fn deinit(self: *Driver) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.changed.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.* = undefined;
    }

    fn run(self: *Driver) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closing) {
            if (self.paused) {
                self.changed.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            if (self.retry_at) |deadline| {
                if (std.Io.Clock.Timestamp.compare(.now(self.io, .awake), .lt, deadline)) {
                    // Notifications cannot bypass backoff; stop/pause still wake it.
                    self.changed.waitTimeout(self.io, &self.mutex, .{ .deadline = deadline }) catch {};
                    continue;
                }
                self.retry_at = null;
                self.notified = true;
            }
            if (!self.notified) {
                if (self.poll_ms) |interval| {
                    const deadline: std.Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = .{ .nanoseconds = @as(i96, interval) * std.time.ns_per_ms }, .clock = .awake });
                    self.changed.waitTimeout(self.io, &self.mutex, .{ .deadline = deadline }) catch {};
                    // A pause or close that woke the wait is handled first on the next pass.
                    self.notified = true;
                    continue;
                }
                self.changed.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            self.notified = false;
            self.active = true;
            self.mutex.unlock(self.io);
            var pending: u32 = 0;
            const returned = self.pump(self.context, &pending);
            const status = if (returned == abi.Status.ok and pending > 1) abi.Status.abi_mismatch else returned;
            self.mutex.lockUncancelable(self.io);
            self.active = false;
            self.idle.broadcast(self.io);
            if (status == abi.Status.ok) {
                self.failures = 0;
                if (pending != 0) self.notified = true;
            } else {
                self.failures = @min(self.failures + 1, 5);
                const delay_ms: u32 = @as(u32, 100) << @as(u5, @intCast(self.failures - 1));
                self.retry_at = .fromNow(self.io, .{ .raw = .{ .nanoseconds = @as(i96, delay_ms) * std.time.ns_per_ms }, .clock = .awake });
                std.debug.print("[job-driver] jobs pump status={d} retry_ms={d}\n", .{ status, delay_ms });
            }
        }
    }
};

fn waitEvent(event: *std.Io.Event) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake });
    while (!event.isSet()) {
        event.waitTimeout(std.testing.io, .{ .deadline = deadline }) catch |err| {
            if (err != error.Timeout or std.Io.Clock.Timestamp.compare(.now(std.testing.io, .awake), .gte, deadline)) return err;
        };
    }
}

const LifecycleMock = struct {
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    drained: std.Io.Event = .unset,
    calls: std.atomic.Value(u32) = .init(0),

    fn pump(ptr: ?*anyopaque, pending: ?*u32) callconv(.c) i32 {
        const self: *LifecycleMock = @ptrCast(@alignCast(ptr.?));
        const count = self.calls.fetchAdd(1, .monotonic) + 1;
        if (count == 1) {
            self.entered.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            pending.?.* = 1;
        } else {
            pending.?.* = 0;
            self.drained.set(std.testing.io);
        }
        return abi.Status.ok;
    }
};

test "job driver pause waits for its attempt and resume drains without another RPC" {
    var mock: LifecycleMock = .{};
    var driver: Driver = undefined;
    try driver.start(std.testing.io, &mock, LifecycleMock.pump);
    // Release a blocked mock even if an assertion fails before the explicit release.
    defer driver.deinit();
    defer mock.release.set(std.testing.io);
    try waitEvent(&mock.entered);
    const Pause = struct {
        driver: *Driver,
        finished: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.driver.pauseAndWait();
            self.finished.set(std.testing.io);
        }
    };
    var pause = Pause{ .driver = &driver };
    const thread = try std.Thread.spawn(.{}, Pause.run, .{&pause});
    defer {
        mock.release.set(std.testing.io);
        thread.join();
    }
    // Observe pause under its mutex, not a scheduling delay heuristic.
    while (true) {
        driver.mutex.lockUncancelable(std.testing.io);
        const paused = driver.paused;
        driver.mutex.unlock(std.testing.io);
        if (paused) break;
        try std.Io.sleep(std.testing.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake);
    }
    try std.testing.expect(!pause.finished.isSet());
    mock.release.set(std.testing.io);
    try waitEvent(&pause.finished);
    driver.notify();
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    try std.testing.expectEqual(@as(u32, 1), mock.calls.load(.acquire));
    driver.resumeWork();
    try waitEvent(&mock.drained);
    driver.pauseAndWait();
    try std.testing.expectEqual(@as(u32, 2), mock.calls.load(.acquire));
}

const FailureMock = struct {
    first: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    calls: std.atomic.Value(u32) = .init(0),
    times: [3]i96 = undefined,

    fn pump(ptr: ?*anyopaque, pending: ?*u32) callconv(.c) i32 {
        const self: *FailureMock = @ptrCast(@alignCast(ptr.?));
        const index = self.calls.fetchAdd(1, .monotonic);
        if (index < self.times.len) self.times[index] = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds;
        pending.?.* = 0;
        if (index == 0) self.first.set(std.testing.io);
        if (index < 2) return abi.Status.failed;
        self.done.set(std.testing.io);
        return abi.Status.ok;
    }
};

test "job driver retries failed persistence with backoff and no new RPC" {
    var mock: FailureMock = .{};
    var driver: Driver = undefined;
    try driver.start(std.testing.io, &mock, FailureMock.pump);
    defer driver.deinit();
    try waitEvent(&mock.first);
    // Frequent notifications must not turn failed persistence into a busy loop.
    for (0..20) |_| driver.notify();
    try waitEvent(&mock.done);
    driver.pauseAndWait();
    try std.testing.expectEqual(@as(u32, 3), mock.calls.load(.acquire));
    try std.testing.expect(mock.times[1] - mock.times[0] >= 100 * std.time.ns_per_ms);
    try std.testing.expect(mock.times[2] - mock.times[1] >= 200 * std.time.ns_per_ms);
}

test "job driver shutdown interrupts its retry wait" {
    var mock: FailureMock = .{};
    var driver: Driver = undefined;
    try driver.start(std.testing.io, &mock, FailureMock.pump);
    try waitEvent(&mock.first);
    driver.pauseAndWait();
    driver.deinit();
    const calls = mock.calls.load(.acquire);
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    try std.testing.expectEqual(calls, mock.calls.load(.acquire));
}
