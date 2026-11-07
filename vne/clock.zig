const std = @import("std");

pub const Manual = struct {
    now_ns: i64 = 0,
};

pub const Clock = union(enum) {
    manual: Manual,
    system: ?std.Io,

    pub fn now(self: *const Clock) !i64 {
        return switch (self.*) {
            .manual => |manual| manual.now_ns,
            .system => |maybe_io| {
                const io = maybe_io orelse return error.ClockNotReady;
                const raw = std.Io.Clock.awake.now(io).nanoseconds;
                return std.math.cast(i64, raw) orelse error.ClockOutOfRange;
            },
        };
    }

    pub fn advanceTo(self: *Clock, time_ns: i64) !void {
        switch (self.*) {
            .manual => |*manual| {
                if (time_ns < manual.now_ns) return error.TimeTravel;
                manual.now_ns = time_ns;
            },
            .system => return error.ManualClockRequired,
        }
    }
};

test "manual clock is monotonic and independent of wall clock" {
    var clock = Clock{ .manual = .{} };
    try std.testing.expectEqual(@as(i64, 0), try clock.now());
    try clock.advanceTo(42);
    try std.testing.expectEqual(@as(i64, 42), try clock.now());
    try std.testing.expectError(error.TimeTravel, clock.advanceTo(41));
}
