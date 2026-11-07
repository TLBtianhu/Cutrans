//! storage.zig — 同目录临时文件 + flush + 原子替换

const std = @import("std");

pub fn writeAtomic(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
