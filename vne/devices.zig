const std = @import("std");
const frame_type = @import("frame.zig");

pub const FrameSink = struct {
    last_generation: u64 = 0,
    last_content_id: u64 = 0,
    last_t: i64 = -1,
    offer_count: u64 = 0,
    present_count: u64 = 0,
    last_presented_generation: u64 = 0,
    last_presented_content_id: u64 = 0,
    last_presented_t: i64 = -1,
    underflow_count: u64 = 0,
    last_underflow_t: i64 = -1,
    unavailable_count: u64 = 0,
    last_unavailable_t: i64 = -1,

    pub fn offer(self: *FrameSink, frame: *const frame_type.Frame, content_id: u64) void {
        self.offerAt(frame, content_id, -1);
    }

    pub fn offerAt(self: *FrameSink, frame: *const frame_type.Frame, content_id: u64, t: i64) void {
        self.last_generation = frame.generation;
        self.last_content_id = content_id;
        self.last_t = t;
        self.offer_count += 1;
    }

    pub fn markSubmitted(self: *FrameSink, content_id: u64, generation: u64, t: i64) void {
        self.last_generation = generation;
        self.last_content_id = content_id;
        self.last_t = t;
        self.last_presented_generation = generation;
        self.last_presented_content_id = content_id;
        self.last_presented_t = t;
        self.present_count += 1;
    }

    pub fn underflow(self: *FrameSink, t: i64) void {
        self.last_underflow_t = t;
        self.underflow_count += 1;
    }

    pub fn unavailable(self: *FrameSink, t: i64) void {
        self.last_unavailable_t = t;
        self.unavailable_count += 1;
    }
};

pub const Table = struct {
    frame_sink: FrameSink = .{},
    input: @import("input.zig").Queue = .{},

    pub fn reset(self: *Table) void {
        self.frame_sink = .{};
        self.input.reset();
    }
};

test "frame sink separates offers confirmed presentation and missing output" {
    var sink: FrameSink = .{};
    var pixels = [_]u8{ 1, 2, 3, 255 };
    const frame = frame_type.Frame{ .width = 1, .height = 1, .generation = 7, .pixels = &pixels };
    sink.offer(&frame, 42);
    try std.testing.expectEqual(@as(u64, 7), sink.last_generation);
    try std.testing.expectEqual(@as(u64, 42), sink.last_content_id);
    try std.testing.expectEqual(@as(u64, 1), sink.offer_count);
    try std.testing.expectEqual(@as(u64, 0), sink.present_count);
    sink.markSubmitted(42, 7, -1);
    try std.testing.expectEqual(@as(u64, 1), sink.present_count);
    try std.testing.expectEqual(@as(u64, 42), sink.last_presented_content_id);
    sink.underflow(3);
    sink.unavailable(4);
    try std.testing.expectEqual(@as(i64, 3), sink.last_underflow_t);
    try std.testing.expectEqual(@as(u64, 1), sink.underflow_count);
    try std.testing.expectEqual(@as(u64, 1), sink.unavailable_count);
    try std.testing.expectEqual(@as(i64, 4), sink.last_unavailable_t);
}
