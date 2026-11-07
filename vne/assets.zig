const std = @import("std");

pub const max_items = 16;

/// Source observation is independent of whether resident bytes remain usable.
pub const SourceStatus = enum(u32) {
    unchecked = 0,
    unchanged = 1,
    missing = 2,
    content_changed = 3,
    identity_changed = 4,
    unverified = 5,
    unavailable = 6,
    superseded = 7,
};

pub const Item = struct {
    handle: u64,
    byte_length: u64,
    leases: u32,
    source_kind: u32,
    library_kind: u32 = 0,
    library_id: u64 = 0,
    content_hash: [32]u8 = @splat(0),
    source_state: SourceStatus = .unchecked,
    source: []u8,
};

pub const View = struct {
    items: [max_items]Item = undefined,
    count: usize = 0,
    revision: u64 = 0,

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |item| allocator.free(item.source);
        self.* = .{};
    }

    pub fn find(self: *const View, handle: u64) ?*const Item {
        for (self.items[0..self.count]) |*item| {
            if (item.handle == handle) return item;
        }
        return null;
    }
};

test "asset view owns source names and rejects stale handles" {
    var view: View = .{};
    defer view.deinit(std.testing.allocator);
    view.items[0] = .{
        .handle = 7,
        .byte_length = 12,
        .leases = 1,
        .source_kind = 0,
        .source = try std.testing.allocator.dupe(u8, "pack://assets/example.png"),
    };
    view.count = 1;
    try std.testing.expect(view.find(7) != null);
    try std.testing.expect(view.find(8) == null);
}
