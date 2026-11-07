//! File identity and bytes must describe the same opened object. Windows
//! stable reads deny ordinary writers/deleters for the lifetime of that handle;
//! other platforms use a single handle and before/after metadata checks only.
const std = @import("std");
const builtin = @import("builtin");

pub const Identity = struct {
    volume_serial: u32,
    file_index: u64,
};

// BY_HANDLE_FILE_INFORMATION, matching the pinned Windows SDK fileapi.h.
// In particular, attributes is the FIRST DWORD, not the final DWORD.
const FileInformation = extern struct {
    attributes: u32,
    creation_time: std.os.windows.FILETIME,
    last_access_time: std.os.windows.FILETIME,
    last_write_time: std.os.windows.FILETIME,
    volume_serial_number: u32,
    file_size_high: u32,
    file_size_low: u32,
    number_of_links: u32,
    file_index_high: u32,
    file_index_low: u32,
};

comptime {
    std.debug.assert(@sizeOf(FileInformation) == 52);
    std.debug.assert(@alignOf(FileInformation) == 4);
    std.debug.assert(@offsetOf(FileInformation, "attributes") == 0);
    std.debug.assert(@offsetOf(FileInformation, "creation_time") == 4);
    std.debug.assert(@offsetOf(FileInformation, "last_access_time") == 12);
    std.debug.assert(@offsetOf(FileInformation, "last_write_time") == 20);
    std.debug.assert(@offsetOf(FileInformation, "volume_serial_number") == 28);
    std.debug.assert(@offsetOf(FileInformation, "file_size_high") == 32);
    std.debug.assert(@offsetOf(FileInformation, "file_size_low") == 36);
    std.debug.assert(@offsetOf(FileInformation, "number_of_links") == 40);
    std.debug.assert(@offsetOf(FileInformation, "file_index_high") == 44);
    std.debug.assert(@offsetOf(FileInformation, "file_index_low") == 48);
}

extern "kernel32" fn GetFileInformationByHandle(handle: std.os.windows.HANDLE, info: *FileInformation) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, desired_access: u32, share_mode: u32, security_attributes: ?*anyopaque, creation_disposition: u32, flags_and_attributes: u32, template_file: ?*anyopaque) callconv(.winapi) ?*anyopaque;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const DELETE: u32 = 0x00010000;
const FILE_SHARE_READ: u32 = 1;
const FILE_SHARE_WRITE: u32 = 2;
const FILE_SHARE_DELETE: u32 = 4;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_SEQUENTIAL_SCAN: u32 = 0x08000000;
const invalid_handle: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const Read = struct {
    bytes: []u8,
    identity: ?Identity,

    pub fn deinit(self: *Read, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const PathRead = struct {
    bytes: []u8,
    identity: ?Identity,
    path: []u8,

    pub fn deinit(self: *PathRead, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PathGuard = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// Query the already opened object, without reopening its pathname.
/// Non-Windows callers retain the existing optional-identity contract.
pub fn queryFile(io: std.Io, file: std.Io.File) !?Identity {
    _ = io;
    if (builtin.os.tag != .windows) return null;
    var info: FileInformation = undefined;
    if (GetFileInformationByHandle(file.handle, &info) == 0) return error.FileIdentityUnavailable;
    return .{
        .volume_serial = info.volume_serial_number,
        .file_index = (@as(u64, info.file_index_high) << 32) | info.file_index_low,
    };
}

pub fn query(io: std.Io, path: []const u8) !?Identity {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidSourcePath;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    return queryFile(io, file);
}

fn openWindows(path: []const u8, desired_access: u32, share_mode: u32) !std.Io.File {
    // The std helper preserves WTF-8 filenames and long/UNC paths. It produces
    // an NT prefix; CreateFileW needs the equivalent Win32 verbatim prefix.
    var name = try std.Io.Threaded.sliceToPrefixedFileW(null, path, .{});
    name.data[0..4].* = .{ '\\', '\\', '?', '\\' };
    const handle = CreateFileW(name.span().ptr, desired_access, share_mode, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_SEQUENTIAL_SCAN, null);
    if (handle == null or handle == invalid_handle) return switch (std.os.windows.GetLastError()) {
        .SHARING_VIOLATION, .LOCK_VIOLATION => error.SourceBusy,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .FILENAME_EXCED_RANGE => error.NameTooLong,
        .INVALID_NAME, .BAD_PATHNAME => error.BadPathName,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
        .DIRECTORY => error.NotDir,
        else => error.SourceOpenFailed,
    };
    return .{ .handle = @ptrCast(handle.?), .flags = .{ .nonblocking = false } };
}

fn openStable(io: std.Io, path: []const u8) !std.Io.File {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidSourcePath;
    if (builtin.os.tag == .windows) return openWindows(path, GENERIC_READ, FILE_SHARE_READ);
    return std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = true });
}

fn sameIdentity(left: ?Identity, right: ?Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.volume_serial == right.?.volume_serial and left.?.file_index == right.?.file_index;
}

fn sameMetadata(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    // Access time may change because of this read and is intentionally omitted.
    return before.kind == .file and after.kind == .file and
        before.inode == after.inode and before.nlink == after.nlink and
        before.size == after.size and
        before.mtime.nanoseconds == after.mtime.nanoseconds and
        before.ctime.nanoseconds == after.ctime.nanoseconds;
}

fn readOpened(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, limit: usize) !Read {
    const before = try file.stat(io);
    if (before.kind != .file) return error.InvalidSourceFile;
    const identity = try queryFile(io, file);
    if (before.size > limit) return error.StreamTooLong;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.SourceChangedDuringRead;
    const after = try file.stat(io);
    const after_identity = try queryFile(io, file);
    if (!sameMetadata(before, after) or !sameIdentity(identity, after_identity)) return error.SourceChangedDuringRead;
    return .{ .bytes = bytes, .identity = identity };
}

/// Read bounded bytes and their identity through one handle. On Windows the
/// handle shares reads only, so ordinary write/delete handles conflict in both
/// directions. Metadata checks are additional detection, not a cross-platform
/// lock or a claim of an atomic snapshot against writable memory mappings.
pub fn readStable(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) !Read {
    const file = try openStable(io, path);
    defer file.close(io);
    return readOpened(allocator, io, file, limit);
}

/// New ordinary-file registration needs the final locator of the same object
/// whose identity and bytes were read. Multi-link files are deliberately not
/// accepted by this new path; older Source readers keep their existing policy.
pub fn readStablePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize, guard: ?PathGuard) !PathRead {
    const file = try openStable(io, path);
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.InvalidSourceFile;
    if (before.nlink != 1) return error.LinkedSourceUnsupported;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try file.realPath(io, &buffer);
    const final_path = try allocator.dupe(u8, buffer[0..length]);
    errdefer allocator.free(final_path);
    if (guard) |policy| try policy.check(policy.context, final_path);
    var read = try readOpened(allocator, io, file, limit);
    errdefer read.deinit(allocator);
    const after = try file.stat(io);
    if (!sameMetadata(before, after)) return error.SourceChangedDuringRead;
    if (after.nlink != 1) return error.LinkedSourceUnsupported;
    return .{ .bytes = read.bytes, .identity = read.identity, .path = final_path };
}

test "real file identities distinguish equal bytes and remain stable for one file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.bin" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.bin" });
    defer allocator.free(second_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "first.bin", .data = "same bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.bin", .data = "same bytes" });
    const first = try query(io, first_path);
    const again = try query(io, first_path);
    const second = try query(io, second_path);
    try std.testing.expect(first != null and second != null);
    try std.testing.expect(first.?.file_index != 0);
    try std.testing.expect(sameIdentity(first, again));
    try std.testing.expect(!sameIdentity(first, second));
    var read = try readStable(allocator, io, first_path, 64);
    defer read.deinit(allocator);
    try std.testing.expectEqualStrings("same bytes", read.bytes);
    try std.testing.expect(sameIdentity(first, read.identity));
}

test "atomic replacement changes path identity while opened reads keep the original object" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.bin" });
    defer allocator.free(path);
    const replacement = try std.fs.path.join(allocator, &.{ root, "replacement.bin" });
    defer allocator.free(replacement);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "original" });
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement.bin", .data = "replacement" });
    const original = try openWindows(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    defer original.close(io);
    const original_identity = try queryFile(io, original);
    try std.Io.Dir.renameAbsolute(replacement, path, io);
    var original_read = try readOpened(allocator, io, original, 64);
    defer original_read.deinit(allocator);
    try std.testing.expectEqualStrings("original", original_read.bytes);
    try std.testing.expect(sameIdentity(original_identity, original_read.identity));
    var replacement_read = try readStable(allocator, io, path, 64);
    defer replacement_read.deinit(allocator);
    try std.testing.expectEqualStrings("replacement", replacement_read.bytes);
    try std.testing.expect(!sameIdentity(original_read.identity, replacement_read.identity));
}

test "Windows stable read rejects existing write delete handles and prevents new ones" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.bin" });
    defer allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "source" });
    const all_sharing = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    for ([_]u32{ GENERIC_WRITE, DELETE }) |access| {
        const conflicting = try openWindows(path, access, all_sharing);
        defer conflicting.close(io);
        try std.testing.expectError(error.SourceBusy, readStable(allocator, io, path, 64));
    }
    const held_read = try openStable(io, path);
    defer held_read.close(io);
    for ([_]u32{ GENERIC_WRITE, DELETE }) |access| {
        try std.testing.expectError(error.SourceBusy, openWindows(path, access, all_sharing));
    }
    var concurrent_read = try readStable(allocator, io, path, 64);
    defer concurrent_read.deinit(allocator);
    try std.testing.expectEqualStrings("source", concurrent_read.bytes);
}

const ChangedReadTest = struct {
    base: std.Io,
    mode: enum { size, kind, inode, nlink, mtime, ctime, short_read },
    stat_count: usize = 0,

    fn stat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const self: *ChangedReadTest = @ptrCast(@alignCast(userdata.?));
        var result = try file.stat(self.base);
        self.stat_count += 1;
        if (self.stat_count == 2) switch (self.mode) {
            .size => result.size += 1,
            .kind => result.kind = .directory,
            .inode => result.inode +%= 1,
            .nlink => result.nlink +%= 1,
            .mtime => result.mtime.nanoseconds += 1,
            .ctime => result.ctime.nanoseconds += 1,
            .short_read => {},
        };
        return result;
    }

    fn read(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const self: *ChangedReadTest = @ptrCast(@alignCast(userdata.?));
        if (self.mode == .short_read) return 0;
        return file.readPositional(self.base, data, offset);
    }
};

test "single handle read rejects short bytes metadata changes nonfiles and oversized sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.bin" });
    defer allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "source" });
    try std.testing.expectError(error.StreamTooLong, readStable(allocator, io, path, 5));
    try std.testing.expectError(error.InvalidSourceFile, readStable(allocator, io, root, 64));
    const file = try openStable(io, path);
    defer file.close(io);
    for (std.enums.values(@FieldType(ChangedReadTest, "mode"))) |mode| {
        var changed = ChangedReadTest{ .base = io, .mode = mode };
        var vtable = io.vtable.*;
        vtable.fileStat = ChangedReadTest.stat;
        vtable.fileReadPositional = ChangedReadTest.read;
        const changed_io = std.Io{ .userdata = &changed, .vtable = &vtable };
        try std.testing.expectError(error.SourceChangedDuringRead, readOpened(allocator, changed_io, file, 64));
    }
}
