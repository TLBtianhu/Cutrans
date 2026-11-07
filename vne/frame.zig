const std = @import("std");

pub const ReportKind = enum(u32) { submitted, underflow, unavailable };

pub const Frame = struct {
    width: u32,
    height: u32,
    generation: u64,
    pixels: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &.{};
    }
};
