//! Retained Source bytes are user data, not a render cache. A version is
//! addressed by (library id, SHA-256); publication never replaces an existing
//! version. Unreferenced versions survive failed edits and are not auto-GC'd.
const std = @import("std");

/// Budget for complete file bytes. A consumer's decoded-media limits are separate.
pub const max_file_bytes = 16 * 1024 * 1024;
pub const max_encoded_bytes = max_file_bytes;

pub fn relativePath(allocator: std.mem.Allocator, id: u64, digest: [32]u8) ![]u8 {
    if (id == 0) return error.InvalidResourceVersion;
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "library/versions/{d}/{s}.bin", .{ id, hex });
}

fn contentHash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn openComponent(parent: std.Io.Dir, io: std.Io, name: []const u8, create: bool) !std.Io.Dir {
    if (create) parent.createDir(io, name, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var child = try parent.openDir(io, name, .{ .follow_symlinks = false });
    errdefer child.close(io);
    // On Windows OPEN_REPARSE_POINT can open the link itself. Check the opened
    // handle as well, so junctions and unknown reparse points cannot be roots.
    if ((try child.stat(io)).kind != .directory) return error.InvalidResourceVersionPath;
    return child;
}

fn openVersions(dir: std.Io.Dir, io: std.Io, id: u64, create: bool) !std.Io.Dir {
    if (id == 0) return error.InvalidResourceVersion;
    var library = try openComponent(dir, io, "library", create);
    defer library.close(io);
    var versions = try openComponent(library, io, "versions", create);
    defer versions.close(io);
    var buffer: [20]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "{d}", .{id});
    return openComponent(versions, io, name, create);
}

fn filename(buffer: *[68]u8, digest: [32]u8) []const u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(buffer[0..64], &hex);
    @memcpy(buffer[64..], ".bin");
    return buffer;
}

fn readFrom(versions: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, digest: [32]u8) ![]u8 {
    var buffer: [68]u8 = undefined;
    var file = try versions.openFile(io, filename(&buffer, digest), .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidResourceVersionPath;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_encoded_bytes)) catch |err| return switch (err) {
        error.ReadFailed => reader.err.?,
        else => err,
    };
    errdefer allocator.free(bytes);
    if (!std.mem.eql(u8, &digest, &contentHash(bytes))) return error.ResourceVersionContentMismatch;
    return bytes;
}

pub fn read(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, id: u64, digest: [32]u8) ![]u8 {
    var versions = try openVersions(dir, io, id, false);
    defer versions.close(io);
    return readFrom(versions, io, allocator, digest);
}

/// Sync bytes before atomically publishing their name. A concurrent publisher
/// can only win with the exact same bytes; damaged versions are never repaired
/// implicitly by re-inserting an Asset that still happens to be in Station.
pub fn retain(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, id: u64, digest: [32]u8, bytes: []const u8) !void {
    if (bytes.len > max_encoded_bytes) return error.ResourceVersionBudgetExceeded;
    if (!std.mem.eql(u8, &digest, &contentHash(bytes))) return error.ResourceVersionContentMismatch;
    var versions = try openVersions(dir, io, id, true);
    defer versions.close(io);
    if (readFrom(versions, io, allocator, digest)) |existing| {
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, bytes)) return error.ResourceVersionConflict;
        return;
    } else |err| if (err != error.FileNotFound) return err;

    var buffer: [68]u8 = undefined;
    var atomic = try versions.createFileAtomic(io, filename(&buffer, digest), .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const existing = try readFrom(versions, io, allocator, digest);
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, bytes)) return error.ResourceVersionConflict;
    };
}

test "retained versions are immutable scoped Source bytes and survive reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "first adopted Source";
    const digest = contentHash(bytes);
    try retain(tmp.dir, std.testing.io, std.testing.allocator, 7, digest, bytes);
    try retain(tmp.dir, std.testing.io, std.testing.allocator, 7, digest, bytes);
    var reopened = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer reopened.close(std.testing.io);
    const restored = try read(reopened, std.testing.io, std.testing.allocator, 7, digest);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(bytes, restored);
    try std.testing.expectError(error.FileNotFound, read(tmp.dir, std.testing.io, std.testing.allocator, 8, digest));
    const path = try relativePath(std.testing.allocator, 7, digest);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "corrupt" });
    try std.testing.expectError(error.ResourceVersionContentMismatch, read(tmp.dir, std.testing.io, std.testing.allocator, 7, digest));
    try std.testing.expectError(error.ResourceVersionContentMismatch, retain(tmp.dir, std.testing.io, std.testing.allocator, 7, digest, bytes));
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("corrupt", unchanged);
}

test "invalid and blocked retained versions never publish a substitute" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "candidate Source";
    const digest = contentHash(bytes);
    try std.testing.expectError(error.InvalidResourceVersion, retain(tmp.dir, std.testing.io, std.testing.allocator, 0, digest, bytes));
    try std.testing.expectError(error.ResourceVersionContentMismatch, retain(tmp.dir, std.testing.io, std.testing.allocator, 1, digest, "wrong"));
    try tmp.dir.createDirPath(std.testing.io, "library");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "library/versions", .data = "blocking sentinel" });
    var failed = false;
    retain(tmp.dir, std.testing.io, std.testing.allocator, 1, digest, bytes) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    const sentinel = try tmp.dir.readFileAlloc(std.testing.io, "library/versions", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("blocking sentinel", sentinel);
}
