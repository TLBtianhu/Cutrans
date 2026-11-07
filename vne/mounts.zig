const std = @import("std");
const Uri = @import("uri.zig");

pub const Access = enum { read_only, read_write };
pub const Resolved = struct { path: []u8, access: Access };

const Grant = struct {
    id: u64 = 0,
    path: []u8 = &.{},
    access: Access = .read_write,
    persistent: bool = false,
};

pub const Table = struct {
    roots: [6]?[]u8 = @splat(null),
    grants: [8]Grant = @splat(.{}),
    next_grant_id: u64 = 1,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (&self.roots) |*root| {
            if (root.*) |path| allocator.free(path);
            root.* = null;
        }
        for (&self.grants) |*grant| {
            if (grant.id != 0) allocator.free(grant.path);
            grant.* = .{};
        }
        self.next_grant_id = 1;
    }

    pub fn setRoot(self: *Table, allocator: std.mem.Allocator, root: Uri.Root, path: []const u8) !void {
        if (root == .external or root == .library or !std.fs.path.isAbsolute(path)) return error.InvalidMountRoot;
        const owned = try allocator.dupe(u8, path);
        const index = @backingInt(root);
        if (self.roots[index]) |old| allocator.free(old);
        self.roots[index] = owned;
    }

    pub fn grantExternal(self: *Table, allocator: std.mem.Allocator, path: []const u8, access: Access) !u64 {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidExternalPath;
        if (self.next_grant_id == 0) return error.ExternalGrantIdExhausted;
        for (&self.grants) |*grant| {
            if (grant.id == 0) {
                const owned = try allocator.dupe(u8, path);
                const id = self.next_grant_id;
                self.next_grant_id = std.math.add(u64, id, 1) catch 0;
                grant.* = .{ .id = id, .path = owned, .access = access };
                return id;
            }
        }
        return error.ExternalGrantTableFull;
    }

    pub fn grantPersistentExternal(self: *Table, allocator: std.mem.Allocator, path: []const u8, access: Access, requested_id: ?u64) !u64 {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidExternalPath;
        const id = requested_id orelse self.next_grant_id;
        if (id == 0) return if (requested_id == null) error.ExternalGrantIdExhausted else error.InvalidExternalGrant;
        for (self.grants) |grant| {
            if (grant.id == id) return error.DuplicateExternalGrant;
        }
        for (&self.grants) |*grant| {
            if (grant.id == 0) {
                const owned = try allocator.dupe(u8, path);
                grant.* = .{ .id = id, .path = owned, .access = access, .persistent = true };
                if (self.next_grant_id != 0 and id >= self.next_grant_id)
                    self.next_grant_id = std.math.add(u64, id, 1) catch 0;
                return id;
            }
        }
        return error.ExternalGrantTableFull;
    }

    pub fn isPersistentExternal(self: *const Table, uri: Uri.Uri) !bool {
        if (uri.root != .external) return false;
        const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
        for (self.grants) |grant| {
            if (grant.id == id) return grant.persistent;
        }
        return false;
    }

    pub fn revokeExternal(self: *Table, allocator: std.mem.Allocator, id: u64) bool {
        for (&self.grants) |*grant| {
            if (grant.id == id) {
                allocator.free(grant.path);
                grant.* = .{};
                return true;
            }
        }
        return false;
    }

    pub fn resolveAlloc(self: *const Table, allocator: std.mem.Allocator, uri: Uri.Uri) !Resolved {
        if (uri.root == .external) {
            const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidExternalGrant;
            for (self.grants) |grant| {
                if (grant.id == id) return .{ .path = try allocator.dupe(u8, grant.path), .access = grant.access };
            }
            return error.ExternalGrantNotFound;
        }
        if (uri.root == .library) return error.LibraryRequiresResourceCatalog;
        const root = self.roots[@backingInt(uri.root)] orelse return error.MountNotFound;
        return .{
            .path = try std.fs.path.join(allocator, &.{ root, uri.body }),
            .access = switch (uri.root) {
                .runtime, .pack, .library => .read_only,
                .session, .cache, .temp => .read_write,
                .external => unreachable,
            },
        };
    }
};

test "mounts keep virtual identities stable across host roots and grants" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    const root = if (@import("builtin").os.tag == .windows) "C:/pack" else "/pack";
    const data = if (@import("builtin").os.tag == .windows) "C:/session" else "/session";
    const external = if (@import("builtin").os.tag == .windows) "C:/work/a.cut" else "/work/a.cut";
    try table.setRoot(std.testing.allocator, .pack, root);
    try table.setRoot(std.testing.allocator, .session, data);
    const pack = try table.resolveAlloc(std.testing.allocator, try Uri.parse("pack://assets/a.cut"));
    defer std.testing.allocator.free(pack.path);
    try std.testing.expect(pack.access == .read_only);
    const id = try table.grantExternal(std.testing.allocator, external, .read_write);
    const grant = try table.resolveAlloc(std.testing.allocator, try Uri.parse("external://1"));
    defer std.testing.allocator.free(grant.path);
    try std.testing.expectEqualStrings(external, grant.path);
    try std.testing.expect(grant.access == .read_write);
    try std.testing.expect(table.revokeExternal(std.testing.allocator, id));
    try std.testing.expectError(error.ExternalGrantNotFound, table.resolveAlloc(std.testing.allocator, try Uri.parse("external://1")));
    try std.testing.expectError(error.InvalidExternalPath, table.grantExternal(std.testing.allocator, "../outside", .read_write));
    try std.testing.expectError(error.LibraryRequiresResourceCatalog, table.resolveAlloc(std.testing.allocator, try Uri.parse("library://1")));
}

test "external grant exhaustion preserves the last identity without wrapping or reuse" {
    const allocator = std.testing.allocator;
    const path = if (@import("builtin").os.tag == .windows) "C:/work/source.png" else "/work/source.png";
    var table: Table = .{ .next_grant_id = std.math.maxInt(u64) };
    defer table.deinit(allocator);
    const last = try table.grantExternal(allocator, path, .read_only);
    try std.testing.expectEqual(std.math.maxInt(u64), last);
    try std.testing.expectEqual(@as(u64, 0), table.next_grant_id);
    try std.testing.expectError(error.ExternalGrantIdExhausted, table.grantExternal(allocator, path, .read_only));
    try std.testing.expect(table.revokeExternal(allocator, last));
    try std.testing.expectError(error.ExternalGrantIdExhausted, table.grantPersistentExternal(allocator, path, .read_only, null));

    var restored: Table = .{};
    defer restored.deinit(allocator);
    try std.testing.expectEqual(last, try restored.grantPersistentExternal(allocator, path, .read_only, last));
    try std.testing.expectEqual(@as(u64, 1), try restored.grantPersistentExternal(allocator, path, .read_only, 1));
    try std.testing.expectEqual(@as(u64, 0), restored.next_grant_id);
    try std.testing.expectError(error.ExternalGrantIdExhausted, restored.grantExternal(allocator, path, .read_only));
    try std.testing.expectError(error.InvalidExternalGrant, restored.grantPersistentExternal(allocator, path, .read_only, 0));
}
