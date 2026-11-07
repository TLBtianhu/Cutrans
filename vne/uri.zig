const std = @import("std");

pub const Root = enum { runtime, pack, session, cache, temp, external, library };
pub const Uri = struct { root: Root, body: []const u8 };

fn validRelative(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path)) return error.InvalidResourcePath;
    if (path[0] == '/' or path[0] == '\\' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, ':') != null) return error.InvalidResourcePath;
    if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidResourcePath;
}

pub fn parse(text: []const u8) !Uri {
    inline for (@typeInfo(Root).@"enum".field_names) |name| {
        const prefix = name ++ "://";
        if (std.mem.startsWith(u8, text, prefix)) {
            const root = std.meta.stringToEnum(Root, name).?;
            const body = text[prefix.len..];
            if (root == .external) {
                if (body.len == 0) return error.InvalidExternalGrant;
                _ = std.fmt.parseInt(u64, body, 10) catch return error.InvalidExternalGrant;
            } else {
                try validRelative(body);
            }
            return .{ .root = root, .body = body };
        }
    }
    return error.NotVirtualUri;
}

pub fn writePack(buffer: []u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "pack://")) {
        const uri = try parse(path);
        if (uri.root != .pack) return error.InvalidResourcePath;
        if (path.len > buffer.len) return error.InvalidResourcePath;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
    try validRelative(path);
    const total = "pack://".len + path.len;
    if (total > buffer.len) return error.InvalidResourcePath;
    @memcpy(buffer[0.."pack://".len], "pack://");
    @memcpy(buffer["pack://".len..total], path);
    return buffer[0..total];
}

pub fn normalizePack(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "pack://")) {
        const uri = try parse(path);
        if (uri.root != .pack) return error.InvalidResourcePath;
        return allocator.dupe(u8, path);
    }
    try validRelative(path);
    return std.fmt.allocPrint(allocator, "pack://{s}", .{path});
}

test "virtual paths reject host paths and normalize legacy pack assets" {
    const uri = try parse("pack://assets/examples/minimal.cut");
    try std.testing.expectEqual(Root.pack, uri.root);
    try std.testing.expectEqualStrings("assets/examples/minimal.cut", uri.body);
    try std.testing.expectError(error.NotVirtualUri, parse("C:/host/file.cut"));
    try std.testing.expectError(error.InvalidResourcePath, parse("session://../outside.cut"));
    try std.testing.expectError(error.InvalidExternalGrant, parse("external://not-a-number"));
    const normalized = try normalizePack(std.testing.allocator, "assets/examples/pngtest.png");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("pack://assets/examples/pngtest.png", normalized);
}
