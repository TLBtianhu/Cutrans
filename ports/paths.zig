//! OS 用户目录口岸;调用方不接触 GUID/HRESULT/UTF-16

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");

pub fn localAppData(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    return windows.localAppData(allocator);
}

test "known folder returns owned UTF-8 path or an explicit unsupported error" {
    if (builtin.os.tag == .windows) {
        const path = try localAppData(std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expect(path.len > 0);
        try std.testing.expect(std.fs.path.isAbsolute(path));
    } else {
        try std.testing.expectError(error.UnsupportedPlatform, localAppData(std.testing.allocator));
    }
}
