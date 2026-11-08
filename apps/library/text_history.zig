//! Complete UTF-8 snapshots, bounded by retained bytes and snapshot count.
const std = @import("std");

pub const byte_budget = 8 * 1024 * 1024;
pub const max_snapshots = 64;
pub const Snapshot = struct { text: []u8, selection: [2]usize };
pub const History = struct {
    allocator: std.mem.Allocator,
    snapshots: [max_snapshots]Snapshot = undefined,
    count: usize = 0,
    cursor: usize = 0,
    bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !History {
        var result = History{ .allocator = allocator };
        _ = try result.record(text, .{ text.len, text.len });
        return result;
    }
    pub fn deinit(self: *History) void {
        for (self.snapshots[0..self.count]) |snapshot| self.allocator.free(snapshot.text);
        self.* = undefined;
    }
    pub fn current(self: *const History) *const Snapshot {
        return &self.snapshots[self.cursor];
    }
    pub fn setSelection(self: *History, selection: [2]usize) void {
        self.snapshots[self.cursor].selection = selection;
    }
    pub fn record(self: *History, text: []const u8, selection: [2]usize) !bool {
        if (text.len > byte_budget) return error.HistoryEntryTooLarge;
        if (self.count > 0 and std.mem.eql(u8, self.current().text, text)) {
            self.setSelection(selection);
            return false;
        }
        const owned = try self.allocator.dupe(u8, text);
        while (self.count > 0 and self.count > self.cursor + 1) self.dropLast();
        while (self.count > 0 and (self.count == max_snapshots or self.bytes + owned.len > byte_budget)) {
            self.bytes -= self.snapshots[0].text.len;
            self.allocator.free(self.snapshots[0].text);
            std.mem.copyForwards(Snapshot, self.snapshots[0 .. self.count - 1], self.snapshots[1..self.count]);
            self.count -= 1;
            if (self.cursor > 0) self.cursor -= 1;
        }
        self.snapshots[self.count] = .{ .text = owned, .selection = selection };
        self.bytes += owned.len;
        self.cursor = self.count;
        self.count += 1;
        return true;
    }
    fn dropLast(self: *History) void {
        self.count -= 1;
        self.bytes -= self.snapshots[self.count].text.len;
        self.allocator.free(self.snapshots[self.count].text);
    }
    pub fn canUndo(self: *const History) bool {
        return self.cursor > 0;
    }
    pub fn canRedo(self: *const History) bool {
        return self.cursor + 1 < self.count;
    }
    pub fn previous(self: *const History) ?*const Snapshot {
        return if (self.canUndo()) &self.snapshots[self.cursor - 1] else null;
    }
    pub fn next(self: *const History) ?*const Snapshot {
        return if (self.canRedo()) &self.snapshots[self.cursor + 1] else null;
    }
};

test "history preserves undo until the new snapshot is admitted" {
    var history = try History.init(std.testing.allocator, "one");
    defer history.deinit();
    _ = try history.record("two", .{ 3, 3 });
    try std.testing.expectEqualStrings("one", history.previous().?.text);
    history.cursor -= 1;
    _ = try history.record("three", .{ 5, 5 });
    try std.testing.expect(!history.canRedo());
    try std.testing.expectEqualStrings("three", history.current().text);
}
