const std = @import("std");

pub const max_items = 64;

pub const NodeKind = enum(u32) {
    folder = 1,
    resource = 2,
};

pub const Kind = enum(u32) {
    reference = 1,
    owned = 2,
};

pub const Provenance = enum(u32) {
    external = 0,
    created = 1,
    detached = 2,
};

pub const Item = struct {
    id: u64,
    parent_id: u64 = 0,
    label: []u8,
    node_kind: NodeKind,
    kind: ?Kind = null,
    provenance: ?Provenance = null,
    content_hash: [32]u8 = @splat(0),
};

pub const View = struct {
    items: [max_items]Item = undefined,
    count: usize = 0,
    revision: u64 = 0,

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |item| allocator.free(item.label);
        self.* = .{};
    }

    pub fn find(self: *const View, id: u64) ?*const Item {
        for (self.items[0..self.count]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn findResource(self: *const View, id: u64) ?*const Item {
        const item = self.find(id) orelse return null;
        return if (item.node_kind == .resource) item else null;
    }

    pub fn validate(self: *const View) !void {
        if (self.count > self.items.len) return error.InvalidLibraryHierarchy;
        for (self.items[0..self.count], 0..) |item, index| {
            if (item.id == 0 or item.label.len == 0 or item.label.len > 128) return error.InvalidLibraryHierarchy;
            for (self.items[0..index]) |previous| {
                if (previous.id == item.id) return error.InvalidLibraryHierarchy;
            }
            switch (item.node_kind) {
                .folder => {
                    if (item.kind != null or item.provenance != null) return error.InvalidLibraryHierarchy;
                    for (item.content_hash) |byte| if (byte != 0) return error.InvalidLibraryHierarchy;
                    var parent_id = item.parent_id;
                    var depth: usize = 0;
                    while (parent_id != 0) {
                        if (parent_id == item.id) return error.InvalidLibraryHierarchy;
                        const parent = self.find(parent_id) orelse return error.InvalidLibraryHierarchy;
                        if (parent.node_kind != .folder) return error.InvalidLibraryHierarchy;
                        parent_id = parent.parent_id;
                        depth += 1;
                        if (depth > self.count) return error.InvalidLibraryHierarchy;
                    }
                },
                .resource => {
                    const kind = item.kind orelse return error.InvalidLibraryHierarchy;
                    const provenance = item.provenance orelse return error.InvalidLibraryHierarchy;
                    if ((kind == .reference) != (provenance == .external)) return error.InvalidLibraryHierarchy;
                    if (item.parent_id != 0) {
                        const parent = self.find(item.parent_id) orelse return error.InvalidLibraryHierarchy;
                        if (parent.node_kind != .folder) return error.InvalidLibraryHierarchy;
                    }
                },
            }
        }
    }
};

test "library view owns labels and validates its logical hierarchy" {
    var view: View = .{};
    defer view.deinit(std.testing.allocator);
    var label = [_]u8{ 'c', 'r', 'e', 'a', 't', 'e', 'd' };
    view.items[0] = .{ .id = 1, .label = try std.testing.allocator.dupe(u8, "素材"), .node_kind = .folder };
    view.items[1] = .{ .id = 2, .parent_id = 1, .label = try std.testing.allocator.dupe(u8, "角色"), .node_kind = .folder };
    view.items[2] = .{
        .id = 3,
        .parent_id = 2,
        .label = try std.testing.allocator.dupe(u8, &label),
        .node_kind = .resource,
        .kind = .owned,
        .provenance = .created,
        .content_hash = [_]u8{7}**32,
    };
    view.count = 3;
    view.revision = 3;
    label[0] = 'X';
    try view.validate();
    try std.testing.expectEqualStrings("created", view.findResource(3).?.label);
    try std.testing.expectEqual(Kind.owned, view.findResource(3).?.kind.?);
    try std.testing.expectEqual(Provenance.created, view.findResource(3).?.provenance.?);
    try std.testing.expect(view.findResource(1) == null);
    view.items[0].parent_id = 2;
    try std.testing.expectError(error.InvalidLibraryHierarchy, view.validate());
    view.items[0].parent_id = 0;
    view.items[1].parent_id = 3;
    try std.testing.expectError(error.InvalidLibraryHierarchy, view.validate());
}
