//! atomic_write.zig — 同目录临时文件 + flush + 原子替换
//!
//! 声明层(documents)与持久层(runtime journals/catalog)共用同一个落盘原语。
//! 它放在 vne 而不是 runtime:documents 属于 vne,若把原语留在 runtime,
//! 声明层要么重复实现一份,要么把 vne 反向依赖到 runtime。
//!
//! 语义:成功返回时目标已是新字节;任何失败都必须让旧目标保持原样。

const std = @import("std");

/// 先写同目录临时文件,flush 后原子替换 `path`;失败时旧目标不变。
pub fn writeAtomic(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "atomic writes replace the target or leave it untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomic(tmp.dir, std.testing.io, "nested/value.txt", "first");
    const read = struct {
        fn text(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
            return dir.readFileAlloc(io, "nested/value.txt", allocator, .limited(64));
        }
    };
    const first = try read.text(std.testing.io, tmp.dir, std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("first", first);
    try writeAtomic(tmp.dir, std.testing.io, "nested/value.txt", "second");
    const second = try read.text(std.testing.io, tmp.dir, std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("second", second);
    // No staging siblings survive a successful replace.
    var nested = try tmp.dir.openDir(std.testing.io, "nested", .{ .iterate = true });
    defer nested.close(std.testing.io);
    var iterator = nested.iterate();
    var entries: usize = 0;
    while (try iterator.next(std.testing.io)) |_| entries += 1;
    try std.testing.expectEqual(@as(usize, 1), entries);
}

// Invalidates the cached test binaries so a verification run is a real run.
