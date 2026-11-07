const std = @import("std");
const builtin = @import("builtin");

extern fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) ?*anyopaque;
extern fn GetProcAddress(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn FreeLibrary(handle: ?*anyopaque) i32;

pub const Library = struct {
    handle: ?*anyopaque,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Library {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!std.fs.path.isAbsolute(path)) return error.AbsoluteLibraryPathRequired;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        // Dependencies may come only from the verified DLL's directory or System32.
        return .{ .handle = LoadLibraryExW(wide.ptr, null, 0x100 | 0x800) orelse return error.LibraryLoadFailed };
    }

    pub fn openSystem(allocator: std.mem.Allocator, name: []const u8) !Library {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "\\/:") != null) return error.InvalidSystemLibraryName;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(wide);
        return .{ .handle = LoadLibraryExW(wide.ptr, null, 0x800) orelse return error.LibraryLoadFailed };
    }

    pub fn lookup(self: *const Library, comptime T: type, name: [:0]const u8) ?T {
        const address = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(address);
    }

    pub fn close(self: *Library) void {
        if (self.handle) |handle| _ = FreeLibrary(handle);
        self.* = undefined;
    }
};

test "library port loads a known system library and resolves a symbol" {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var library = try Library.openSystem(std.testing.allocator, "kernel32.dll");
    defer library.close();
    const Fn = *const fn () callconv(.c) u32;
    try std.testing.expect(library.lookup(Fn, "GetCurrentProcessId") != null);
    try std.testing.expect(library.lookup(Fn, "CutransMissingSymbol") == null);
    try std.testing.expectError(error.AbsoluteLibraryPathRequired, Library.open(std.testing.allocator, "kernel32.dll"));
}
