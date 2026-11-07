const std = @import("std");
const abi = @import("abi.zig");

pub const View = struct {
    active: bool = false,
    cursor: i64 = 0,
    frames: i64 = 0,
    last_t: i64 = -1,
    current_t: i64 = -1,
    offer_count: u64 = 0,
    underflow_count: u64 = 0,
    present_count: u64 = 0,

    pub fn apply(self: *View, report: abi.PlaybackReport) !void {
        if (report.struct_size < @sizeOf(abi.PlaybackReport) or report.abi_version != abi.version or report.reserved != 0) return error.InvalidPlaybackReport;
        if (report.active > 1 or report.cursor < 0 or report.frames < 0 or report.cursor > report.frames or report.last_t < -1) return error.InvalidPlaybackReport;
        if (report.frames > 0 and report.last_t >= report.frames) return error.InvalidPlaybackReport;
        self.* = .{
            .active = report.active != 0,
            .cursor = report.cursor,
            .frames = report.frames,
            .last_t = report.last_t,
            .current_t = if (report.cursor > 0) report.cursor - 1 else -1,
            .offer_count = report.offer_count,
            .underflow_count = report.underflow_count,
            .present_count = report.present_count,
        };
    }

    pub fn currentOffer(self: *const View) ?i64 {
        if (self.frames <= 0 or self.current_t < 0 or self.last_t != self.current_t) return null;
        return self.current_t;
    }
};

test "playback projection copies state without runtime pointers" {
    var view: View = .{};
    try view.apply(.{
        .struct_size = @sizeOf(abi.PlaybackReport),
        .abi_version = abi.version,
        .active = 1,
        .cursor = 2,
        .frames = 4,
        .last_t = 1,
        .offer_count = 2,
        .underflow_count = 0,
        .present_count = 1,
    });
    try std.testing.expect(view.active);
    try std.testing.expectEqual(@as(i64, 2), view.cursor);
    try std.testing.expectEqual(@as(i64, 1), view.last_t);
    try std.testing.expectEqual(@as(i64, 1), view.current_t);
    try std.testing.expectEqual(@as(u64, 1), view.present_count);
    try std.testing.expectEqual(@as(?i64, 1), view.currentOffer());
    view.cursor = 4;
    view.current_t = 3;
    view.last_t = 3;
    try std.testing.expectEqual(@as(?i64, 3), view.currentOffer());
    view.last_t = 1;
    try std.testing.expectEqual(@as(?i64, null), view.currentOffer());
    try std.testing.expectError(error.InvalidPlaybackReport, view.apply(.{
        .struct_size = @sizeOf(abi.PlaybackReport),
        .abi_version = abi.version,
        .active = 1,
        .cursor = 5,
        .frames = 4,
        .last_t = -1,
    }));
}
