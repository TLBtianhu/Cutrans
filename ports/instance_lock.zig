//! instance_lock.zig — 数据根单写者锁
//!
//! 一个数据根同一时刻只允许一个虚拟环境实例。锁是以共享模式 0 打开的文件句柄，
//! 进程退出（包括崩溃）时由系统释放，不需要清理残留。
const std = @import("std");
const builtin = @import("builtin");

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const OPEN_ALWAYS: u32 = 4;
const invalid_handle: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

extern fn CreateFileW(name: [*:0]const u16, desired_access: u32, share_mode: u32, security_attributes: ?*anyopaque, creation_disposition: u32, flags_and_attributes: u32, template_file: ?*anyopaque) ?*anyopaque;
extern fn CloseHandle(handle: ?*anyopaque) i32;

pub const Lock = struct {
    handle: ?*anyopaque,

    pub fn deinit(self: *Lock) void {
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }
};

/// Exclusively open `<data_dir>/<relative>`; another holder yields
/// `error.EnvironmentAlreadyRunning`.
pub fn acquire(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, relative: []const u8) !Lock {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const path = try std.fs.path.join(allocator, &.{ data_dir, relative });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |directory| try std.Io.Dir.cwd().createDirPath(io, directory);
    const name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(name);
    const handle = CreateFileW(name.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_ALWAYS, 0, null);
    if (handle == null or handle == invalid_handle) return error.EnvironmentAlreadyRunning;
    return .{ .handle = handle };
}

test "a data root admits exactly one live holder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var first = try acquire(std.testing.allocator, std.testing.io, root, "session/instance.lock");
    try std.testing.expectError(error.EnvironmentAlreadyRunning, acquire(std.testing.allocator, std.testing.io, root, "session/instance.lock"));
    first.deinit();
    var again = try acquire(std.testing.allocator, std.testing.io, root, "session/instance.lock");
    again.deinit();
}
