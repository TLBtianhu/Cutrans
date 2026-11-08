//! Complete working bodies and drafts are published before their Catalog head.
//! Unreferenced candidates survive failed commits and are never guessed as GC.
const std = @import("std");
const versions = @import("resource_versions.zig");

pub const Kind = enum { work, drafts };

fn contentHash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn openComponent(parent: std.Io.Dir, io: std.Io, name: []const u8, create: bool) !std.Io.Dir {
    if (create) parent.createDir(io, name, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var child = try parent.openDir(io, name, .{ .follow_symlinks = false });
    errdefer child.close(io);
    if ((try child.stat(io)).kind != .directory) return error.InvalidWorkPath;
    return child;
}

fn openResource(dir: std.Io.Dir, io: std.Io, kind: Kind, id: u64, create: bool) !std.Io.Dir {
    if (id == 0) return error.InvalidWorkPath;
    var library = try openComponent(dir, io, "library", create);
    defer library.close(io);
    var root = try openComponent(library, io, @tagName(kind), create);
    defer root.close(io);
    var buffer: [20]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "{d}", .{id});
    return openComponent(root, io, name, create);
}

fn filename(buffer: *[25]u8, revision: u64) ![]const u8 {
    if (revision == 0) return error.InvalidWorkRevision;
    return std.fmt.bufPrint(buffer, "{d:0>20}.bin", .{revision});
}

fn readFrom(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, revision: u64, digest: [32]u8) ![]u8 {
    var buffer: [25]u8 = undefined;
    var file = try dir.openFile(io, try filename(&buffer, revision), .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidWorkPath;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(versions.max_file_bytes)) catch |err| return switch (err) {
        error.ReadFailed => reader.err.?,
        else => err,
    };
    errdefer allocator.free(bytes);
    if (!std.mem.eql(u8, &digest, &contentHash(bytes))) return error.WorkContentMismatch;
    return bytes;
}

pub fn read(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, kind: Kind, id: u64, revision: u64, digest: [32]u8) ![]u8 {
    var resource = try openResource(dir, io, kind, id, false);
    defer resource.close(io);
    return readFrom(resource, io, allocator, revision, digest);
}

pub fn publish(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, kind: Kind, id: u64, revision: u64, digest: [32]u8, bytes: []const u8) !void {
    if (bytes.len > versions.max_file_bytes) return error.WorkBodyTooLarge;
    if (!std.mem.eql(u8, &digest, &contentHash(bytes))) return error.WorkContentMismatch;
    var resource = try openResource(dir, io, kind, id, true);
    defer resource.close(io);
    if (readFrom(resource, io, allocator, revision, digest)) |existing| {
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, bytes)) return error.WorkContentMismatch;
        return;
    } else |err| if (err != error.FileNotFound) return err;
    var buffer: [25]u8 = undefined;
    var atomic = try resource.createFileAtomic(io, try filename(&buffer, revision), .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const existing = try readFrom(resource, io, allocator, revision, digest);
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, bytes)) return error.WorkContentMismatch;
    };
}

test "work and draft bodies use independent immutable revision names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = "published one";
    const second = "draft two";
    try publish(tmp.dir, std.testing.io, std.testing.allocator, .work, 7, 1, contentHash(first), first);
    try publish(tmp.dir, std.testing.io, std.testing.allocator, .drafts, 7, 9, contentHash(second), second);
    const restored_work = try read(tmp.dir, std.testing.io, std.testing.allocator, .work, 7, 1, contentHash(first));
    defer std.testing.allocator.free(restored_work);
    const restored_draft = try read(tmp.dir, std.testing.io, std.testing.allocator, .drafts, 7, 9, contentHash(second));
    defer std.testing.allocator.free(restored_draft);
    try std.testing.expectEqualStrings(first, restored_work);
    try std.testing.expectEqualStrings(second, restored_draft);
    try std.testing.expectError(error.FileNotFound, read(tmp.dir, std.testing.io, std.testing.allocator, .work, 7, 2, contentHash(second)));
}
