//! escapement.zig — 时钟门禁呈现骨架
//!
//! Clock 负责节拍,Stream 负责帧,Sink 负责输出。step 先查 has,再决定 offer
//! 或欠账,不用未物化帧冒充当前帧。实现 skip 政策、无头测试与静态文档 Runtime 播放,
//! 不包含真实媒体输出。

const std = @import("std");
const stream_mod = @import("stream.zig");
const render = @import("render.zig");

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    wait_next_fn: ?*const fn (?*anyopaque) void = null,
    now_fn: ?*const fn (?*anyopaque) i64 = null,

    pub fn waitNext(self: *const Clock) void {
        if (self.wait_next_fn) |f| f(self.ctx);
    }

    pub fn now(self: *const Clock) i64 {
        return if (self.now_fn) |f| f(self.ctx) else 0;
    }
};

pub const Sink = @import("vne").devices.FrameSink;

pub const UnderflowPolicy = enum { skip };
pub const Step = enum { offered, underflow, finished };

pub const Engine = struct {
    clock: Clock,
    sink: *Sink,
    stream: *stream_mod.Stream,
    underflow_policy: UnderflowPolicy = .skip,
    cursor: i64 = 0,

    pub fn step(self: *Engine, allocator: std.mem.Allocator, io: ?std.Io, dir: ?std.Io.Dir) !Step {
        self.clock.waitNext();
        if (self.cursor >= self.stream.frames) return .finished;
        const t = self.cursor;
        if (!self.stream.has(t)) {
            switch (self.underflow_policy) {
                .skip => {
                    self.sink.underflow(t);
                    self.cursor += 1;
                    return .underflow;
                },
            }
        }
        const frame = try self.stream.get(t, allocator, io, dir);
        self.sink.offerAt(frame, self.stream.document.fingerprint(), t);
        self.cursor += 1;
        return .offered;
    }

    pub fn run(self: *Engine, allocator: std.mem.Allocator, io: ?std.Io, dir: ?std.Io.Dir, max_steps: usize) !usize {
        var offered: usize = 0;
        for (0..max_steps) |_| {
            switch (try self.step(allocator, io, dir)) {
                .offered => offered += 1,
                .underflow => {},
                .finished => break,
            }
        }
        return offered;
    }
};

const NullClock = struct {
    waits: usize = 0,
    current: i64 = 0,

    fn waitNext(ctx: ?*anyopaque) void {
        const self: *NullClock = @ptrCast(@alignCast(ctx orelse return));
        self.waits += 1;
    }

    fn now(ctx: ?*anyopaque) i64 {
        const self: *NullClock = @ptrCast(@alignCast(ctx orelse return 0));
        return self.current;
    }
};

test "clock gated playback presents only materialized frames and finishes" {
    var doc = @import("vne").documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    var stream = stream_mod.Stream.init(&doc, 2);
    defer stream.deinit(std.testing.allocator);
    var clock = NullClock{};
    _ = try stream.get(0, std.testing.allocator, null, null);
    _ = try stream.get(1, std.testing.allocator, null, null);
    var sink: Sink = .{};
    var engine = Engine{
        .clock = .{ .ctx = &clock, .wait_next_fn = NullClock.waitNext, .now_fn = NullClock.now },
        .sink = &sink,
        .stream = &stream,
    };
    try std.testing.expectEqual(@as(usize, 2), try engine.run(std.testing.allocator, null, null, 4));
    try std.testing.expectEqual(@as(u64, 2), sink.offer_count);
    try std.testing.expectEqual(@as(u64, 0), sink.present_count);
    try std.testing.expectEqual(@as(u64, 1), sink.last_generation);
    try std.testing.expectEqual(@as(u64, 0), sink.underflow_count);
    try std.testing.expectEqual(@as(usize, 3), clock.waits);
    try std.testing.expectEqual(@as(i64, 0), engine.clock.now());
}

test "skip underflow never produces an unmaterialized frame" {
    var doc = @import("vne").documents.Document.initDefault();
    doc.width = 1;
    doc.height = 1;
    var stream = stream_mod.Stream.init(&doc, 1);
    defer stream.deinit(std.testing.allocator);
    var clock = NullClock{};
    var sink: Sink = .{};
    var engine = Engine{
        .clock = .{ .ctx = &clock, .wait_next_fn = NullClock.waitNext },
        .sink = &sink,
        .stream = &stream,
    };
    try std.testing.expectEqual(Step.underflow, try engine.step(std.testing.allocator, null, null));
    try std.testing.expectEqual(@as(u64, 1), sink.underflow_count);
    try std.testing.expectEqual(@as(u64, 0), sink.present_count);
    try std.testing.expectEqual(@as(i64, 0), sink.last_underflow_t);
    try std.testing.expect(stream.preview.frame == null);
    try std.testing.expectEqual(Step.finished, try engine.step(std.testing.allocator, null, null));
}
