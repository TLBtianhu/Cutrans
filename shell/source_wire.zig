//! Local-source RPC carries paths and cursors, never process-local pointers.
const std = @import("std");
const resource = @import("vne").resource_api;

pub const browse_header_size = 24;
pub const read_header_size = 16;
pub const Browse = struct { path: []const u8, cursor: u64, limit: u32 };

fn validPath(path: []const u8) bool {
    return resource.validPath(path) and std.fs.path.isAbsolute(path);
}

pub fn encodeBrowse(allocator: std.mem.Allocator, value: Browse) ![]u8 {
    if (!validPath(value.path) or value.limit == 0 or value.limit > 128) return error.InvalidSourceBrowse;
    const bytes = try allocator.alloc(u8, browse_header_size + value.path.len);
    @memset(bytes[0..browse_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    std.mem.writeInt(u64, bytes[8..16], value.cursor, .little);
    std.mem.writeInt(u32, bytes[16..20], value.limit, .little);
    std.mem.writeInt(u32, bytes[20..24], @intCast(value.path.len), .little);
    @memcpy(bytes[browse_header_size..], value.path);
    return bytes;
}

pub fn parseBrowse(bytes: []const u8) !Browse {
    if (bytes.len < browse_header_size or std.mem.readInt(u32, bytes[0..4], .little) != resource.version or
        std.mem.readInt(u32, bytes[4..8], .little) != 0) return error.InvalidSourceBrowse;
    const cursor = std.mem.readInt(u64, bytes[8..16], .little);
    const limit = std.mem.readInt(u32, bytes[16..20], .little);
    const path_len = std.mem.readInt(u32, bytes[20..24], .little);
    if (bytes.len != browse_header_size + path_len or limit == 0 or limit > 128) return error.InvalidSourceBrowse;
    const path = bytes[browse_header_size..];
    if (!validPath(path)) return error.InvalidSourceBrowse;
    return .{ .path = path, .cursor = cursor, .limit = limit };
}

pub fn encodeRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!validPath(path)) return error.InvalidSourceRead;
    const bytes = try allocator.alloc(u8, read_header_size + path.len);
    @memset(bytes[0..read_header_size], 0);
    std.mem.writeInt(u32, bytes[0..4], resource.version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(path.len), .little);
    @memcpy(bytes[read_header_size..], path);
    return bytes;
}

pub fn parseRead(bytes: []const u8) ![]const u8 {
    if (bytes.len < read_header_size or std.mem.readInt(u32, bytes[0..4], .little) != resource.version or
        std.mem.readInt(u32, bytes[4..8], .little) != 0 or std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidSourceRead;
    const path_len = std.mem.readInt(u32, bytes[8..12], .little);
    if (bytes.len != read_header_size + path_len) return error.InvalidSourceRead;
    const path = bytes[read_header_size..];
    if (!validPath(path)) return error.InvalidSourceRead;
    return path;
}

test "local browse and read frames preserve absolute UTF-8 paths and bounds" {
    const path = if (@import("builtin").os.tag == .windows) "C:/素材/正文.txt" else "/tmp/正文.txt";
    const encoded = try encodeBrowse(std.testing.allocator, .{ .path = path, .cursor = 128, .limit = 64 });
    defer std.testing.allocator.free(encoded);
    const browse = try parseBrowse(encoded);
    try std.testing.expectEqualStrings(path, browse.path);
    try std.testing.expectEqual(@as(u64, 128), browse.cursor);
    try std.testing.expectEqual(@as(u32, 64), browse.limit);
    try std.testing.expectError(error.InvalidSourceBrowse, parseBrowse(encoded[0 .. encoded.len - 1]));
    const read_bytes = try encodeRead(std.testing.allocator, path);
    defer std.testing.allocator.free(read_bytes);
    try std.testing.expectEqualStrings(path, try parseRead(read_bytes));
    try std.testing.expectError(error.InvalidSourceRead, parseRead(read_bytes[0 .. read_bytes.len - 1]));
    try std.testing.expectError(error.InvalidSourceRead, encodeRead(std.testing.allocator, "relative.txt"));
}
