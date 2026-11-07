//! image.zig — 通过 stb 的 PNG 素材导入与导出
//!
//! 文件加载由 Dir+相对路径约束,内存解码接收字节;编码使用回调写 File,不绕过路径边界。

const std = @import("std");

pub const adapter_ids = [_][]const u8{ "image.png.decode", "image.png.encode" };

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(data: [*]u8) void;
extern fn stbi_write_png_to_func(func: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void, context: ?*anyopaque, w: c_int, h: c_int, comp: c_int, data: ?*const anyopaque, stride_in_bytes: c_int) c_int;

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &.{};
    }
};

fn validPath(path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "pack://")) {
        const uri = @import("vne").uri.parse(path) catch return error.InvalidResourcePath;
        if (uri.root != .pack) return error.InvalidResourcePath;
        return uri.body;
    }
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidResourcePath;
    return path;
}

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

fn validatePng(bytes: []const u8) !void {
    if (bytes.len < png_signature.len) return error.TruncatedImage;
    if (!std.mem.eql(u8, bytes[0..png_signature.len], &png_signature)) return error.UnsupportedImageFormat;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    try validatePng(bytes);
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const decoded = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels, 4) orelse return error.ImageDecodeFailed;
    defer stbi_image_free(decoded);
    if (width <= 0 or height <= 0) return error.InvalidImageSize;
    const byte_count = try std.math.mul(usize, @as(usize, @intCast(width)), @as(usize, @intCast(height)));
    const pixels = try allocator.dupe(u8, decoded[0 .. byte_count * 4]);
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Image {
    const relative = try validPath(path);
    const bytes = try dir.readFileAlloc(io, relative, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

test "PNG header validation distinguishes unsupported and truncated input" {
    try validatePng(&png_signature);
    try std.testing.expectError(error.TruncatedImage, validatePng(png_signature[0..4]));
    try std.testing.expectError(error.UnsupportedImageFormat, validatePng("not png!"));
    try std.testing.expectError(error.UnsupportedImageFormat, validatePng(&.{ 0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0 }));
}

const WriteContext = struct {
    io: std.Io,
    file: std.Io.File,
    failed: bool = false,
    digest: std.crypto.hash.sha2.Sha256 = .init(.{}),
    size: u64 = 0,
};

fn writeCallback(opaque_ptr: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const ctx: *WriteContext = @ptrCast(@alignCast(opaque_ptr orelse return));
    if (ctx.failed or size == 0) return;
    if (size < 0 or data == null) {
        ctx.failed = true;
        return;
    }
    const bytes: [*]const u8 = @ptrCast(data.?);
    const chunk = bytes[0..@intCast(size)];
    const next_size = std.math.add(u64, ctx.size, chunk.len) catch {
        ctx.failed = true;
        return;
    };
    ctx.file.writeStreamingAll(ctx.io, chunk) catch {
        ctx.failed = true;
        return;
    };
    ctx.digest.update(chunk);
    ctx.size = next_size;
}

/// One owned, synced PNG candidate. Preparing never touches the old target.
/// Persist `digest` and `size` before commit when a Job needs recovery evidence.
/// This object's temporary file is process-local, not a durable restart token.
pub const PreparedPng = struct {
    atomic: std.Io.File.Atomic,
    digest: [32]u8,
    size: u64,
    committed: bool = false,
    allocator: std.mem.Allocator,
    owned_path: []u8,

    /// Failed replacement retains the candidate for a later commit retry.
    /// A successful commit is idempotent while this object is alive.
    pub fn commit(self: *PreparedPng, io: std.Io) !void {
        if (self.committed) return;
        try self.atomic.replace(io);
        self.committed = true;
    }

    pub fn deinit(self: *PreparedPng, io: std.Io) void {
        self.atomic.deinit(io);
        self.allocator.free(self.owned_path);
        self.* = undefined;
    }
};

fn pngStride(image: Image) !c_int {
    if (image.width == 0 or image.height == 0 or image.width > std.math.maxInt(c_int) or image.height > std.math.maxInt(c_int)) return error.InvalidImageSize;
    const stride = std.math.mul(usize, image.width, 4) catch return error.InvalidImageSize;
    if (stride > std.math.maxInt(c_int)) return error.InvalidImageSize;
    const size = std.math.mul(usize, stride, image.height) catch return error.InvalidImageSize;
    if (image.pixels.len != size) return error.InvalidPixelBuffer;
    return @intCast(stride);
}

fn prepareWithEncoder(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, image: Image, encoder: @TypeOf(&stbi_write_png_to_func)) !PreparedPng {
    const stride = try pngStride(image);
    if (!std.fs.path.isAbsolute(path)) _ = try validPath(path);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    var atomic = try dir.createFileAtomic(io, owned_path, .{ .make_path = true, .replace = true });
    errdefer atomic.deinit(io);
    var ctx = WriteContext{ .io = io, .file = atomic.file };
    const result = encoder(writeCallback, &ctx, @intCast(image.width), @intCast(image.height), 4, image.pixels.ptr, stride);
    if (result == 0 or ctx.failed or ctx.size == 0) return error.ImageEncodeFailed;
    try atomic.file.sync(io);
    return .{ .atomic = atomic, .digest = ctx.digest.finalResult(), .size = ctx.size, .allocator = allocator, .owned_path = owned_path };
}

pub fn preparePng(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, image: Image) !PreparedPng {
    return prepareWithEncoder(allocator, io, dir, path, image, &stbi_write_png_to_func);
}

pub fn savePng(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, image: Image) !void {
    _ = try validPath(path);
    var prepared = try preparePng(allocator, io, dir, path, image);
    defer prepared.deinit(io);
    try prepared.commit(io);
}

pub fn savePngExternal(allocator: std.mem.Allocator, io: std.Io, path: []const u8, image: Image) !void {
    if (!std.fs.path.isAbsolute(path)) _ = try validPath(path);
    var prepared = try preparePng(allocator, io, .cwd(), path, image);
    defer prepared.deinit(io);
    try prepared.commit(io);
}

fn testFileCount(dir: std.Io.Dir) !usize {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

test "prepared PNG owns its target and digest while old output remains untouched" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "output.png", .data = "old sentinel" });
    const path = try std.testing.allocator.dupe(u8, "output.png");
    var pixels = [_]u8{ 12, 34, 56, 255 };
    var prepared = try preparePng(std.testing.allocator, io, tmp.dir, path, .{ .width = 1, .height = 1, .pixels = &pixels });
    defer prepared.deinit(io);
    std.testing.allocator.free(path);
    const old = try tmp.dir.readFileAlloc(io, "output.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualStrings("old sentinel", old);
    pixels[0] = 99;
    try prepared.commit(io);
    try prepared.commit(io);
    const encoded = try tmp.dir.readFileAlloc(io, "output.png", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &prepared.digest);
    try std.testing.expectEqual(@as(u64, encoded.len), prepared.size);
    var image = try decode(std.testing.allocator, encoded);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, image.pixels);
    try std.testing.expectEqual(@as(usize, 1), try testFileCount(tmp.dir));
}

test "failed encoder and invalid pixel buffers never truncate an old output or retain temporary files" {
    const Broken = struct {
        fn encode(callback: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void, context: ?*anyopaque, _: c_int, _: c_int, _: c_int, _: ?*const anyopaque, _: c_int) callconv(.c) c_int {
            var partial = "partial invalid PNG".*;
            callback(context, &partial, partial.len);
            return 0;
        }
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "output.png", .data = "old sentinel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "unrelated", .data = "keep" });
    var pixels = [_]u8{ 12, 34, 56, 255 };
    try std.testing.expectError(error.ImageEncodeFailed, prepareWithEncoder(std.testing.allocator, io, tmp.dir, "output.png", .{ .width = 1, .height = 1, .pixels = &pixels }, &Broken.encode));
    try std.testing.expectError(error.InvalidPixelBuffer, preparePng(std.testing.allocator, io, tmp.dir, "new/output.png", .{ .width = 1, .height = 1, .pixels = pixels[0..3] }));
    try std.testing.expectError(error.InvalidImageSize, preparePng(std.testing.allocator, io, tmp.dir, "output.png", .{ .width = 0, .height = 1, .pixels = &pixels }));
    const old = try tmp.dir.readFileAlloc(io, "output.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualStrings("old sentinel", old);
    try std.testing.expectEqual(@as(usize, 2), try testFileCount(tmp.dir));
}

test "failed atomic replacement preserves the target directory and deinit removes only its candidate" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "blocked.png");
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked.png/KEEP", .data = "directory sentinel" });
    var pixels = [_]u8{ 12, 34, 56, 255 };
    var prepared = try preparePng(std.testing.allocator, io, tmp.dir, "blocked.png", .{ .width = 1, .height = 1, .pixels = &pixels });
    if (prepared.commit(io)) |_| {
        prepared.deinit(io);
        return error.ExpectedCommitFailure;
    } else |_| {}
    const sentinel = try tmp.dir.readFileAlloc(io, "blocked.png/KEEP", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("directory sentinel", sentinel);
    prepared.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), try testFileCount(tmp.dir));
}

test "exclusive Windows target lock preserves old bytes and the same prepared PNG can commit after unlock" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Win = struct {
        extern fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
        extern fn CloseHandle(*anyopaque) i32;
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "output.png", .data = "locked old sentinel" });
    const path = try tmp.dir.realPathFileAlloc(io, "output.png", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(wide);
    const handle = Win.CreateFileW(wide.ptr, 0x80000000, 0, null, 3, 0x80, null) orelse return error.LockFixtureFailed;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.LockFixtureFailed;
    var lock_open = true;
    defer if (lock_open) {
        _ = Win.CloseHandle(handle);
    };
    var pixels = [_]u8{ 12, 34, 56, 255 };
    var prepared = try preparePng(std.testing.allocator, io, .cwd(), path, .{ .width = 1, .height = 1, .pixels = &pixels });
    defer prepared.deinit(io);
    if (prepared.commit(io)) |_| return error.ExpectedCommitFailure else |_| {}
    _ = Win.CloseHandle(handle);
    lock_open = false;
    const old = try tmp.dir.readFileAlloc(io, "output.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualStrings("locked old sentinel", old);
    try prepared.commit(io);
    const encoded = try tmp.dir.readFileAlloc(io, "output.png", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &prepared.digest);
}
