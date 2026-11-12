//! paths.zig — 只读资源与用户数据的路径边界
//!
//! resource_dir 只放随应用分发的只读内容;data_dir 只放用户数据。三种运行
//! 形态各有独立数据根,目录只在实际保存时创建,不在普通启动时写状态。

const std = @import("std");

const environment = @import("environment.zig");
const launch = @import("launch.zig");

pub const Mode = launch.Mode;
pub const LaunchOptions = launch.LaunchOptions;
pub const parseMode = launch.parseMode;
pub const parseLaunchArg = launch.parseLaunchArg;
pub const parseLaunchArgs = launch.parseLaunchArgs;

pub const Paths = struct {
    mode: Mode = .development,
    resource_dir: []u8 = &.{},
    data_dir: []u8 = &.{},

    pub fn init(
        self: *Paths,
        allocator: std.mem.Allocator,
        io: std.Io,
        mode: Mode,
        environ: *const std.process.Environ.Map,
    ) !void {
        _ = environ; // inherited home/appdata/cwd never choose a product instance
        const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
        defer allocator.free(exe_dir);
        var context = try environment.load(allocator, io, exe_dir);
        defer context.deinit();
        if (mode != context.form) return error.RunContextModeMismatch;
        const data_dir = try context.dataDir(io, null, .normal);
        errdefer allocator.free(data_dir);
        // This entry is the diagnostic executable. Portable data legitimately
        // sits below its EXE root; writable diagnostics replace it explicitly.
        self.* = .{ .mode = mode, .resource_dir = try environment.canonicalPath(allocator, io, exe_dir), .data_dir = data_dir };
    }

    pub fn fromDirs(allocator: std.mem.Allocator, mode: Mode, resource_dir: []const u8, data_dir: []const u8) !Paths {
        try environment.ensureSeparateLexically(allocator, resource_dir, data_dir);
        return .{
            .mode = mode,
            .resource_dir = try allocator.dupe(u8, resource_dir),
            .data_dir = try allocator.dupe(u8, data_dir),
        };
    }

    pub fn fromDirsPhysical(allocator: std.mem.Allocator, io: std.Io, mode: Mode, resource_dir: []const u8, data_dir: []const u8) !Paths {
        const resource = try environment.canonicalPath(allocator, io, resource_dir);
        errdefer allocator.free(resource);
        const data = try environment.canonicalPath(allocator, io, data_dir);
        errdefer allocator.free(data);
        try environment.ensureSeparateLexically(allocator, resource, data);
        return .{ .mode = mode, .resource_dir = resource, .data_dir = data };
    }

    pub fn overrideDataDir(self: *Paths, allocator: std.mem.Allocator, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidResourcePath;
        try environment.ensureSeparateLexically(allocator, self.resource_dir, path);
        const owned = try allocator.dupe(u8, path);
        if (self.data_dir.len > 0) allocator.free(self.data_dir);
        self.data_dir = owned;
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        if (self.resource_dir.len > 0) allocator.free(self.resource_dir);
        if (self.data_dir.len > 0) allocator.free(self.data_dir);
        self.* = .{};
    }

    fn validRelative(path: []const u8) !void {
        if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidResourcePath;
    }

    pub fn resourcePath(self: *const Paths, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
        try validRelative(relative);
        return std.fs.path.join(allocator, &.{ self.resource_dir, relative });
    }

    pub fn dataPath(self: *const Paths, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
        try validRelative(relative);
        return std.fs.path.join(allocator, &.{ self.data_dir, relative });
    }

    pub fn openResourceDir(self: *const Paths, io: std.Io) !std.Io.Dir {
        return std.Io.Dir.openDirAbsolute(io, self.resource_dir, .{});
    }

    pub fn openDataDirExisting(self: *const Paths, io: std.Io) !std.Io.Dir {
        return std.Io.Dir.openDirAbsolute(io, self.data_dir, .{});
    }

    pub fn openDataDir(self: *const Paths, io: std.Io, allocator: std.mem.Allocator) !std.Io.Dir {
        const documents_dir = try std.fs.path.join(allocator, &.{ self.data_dir, "documents" });
        defer allocator.free(documents_dir);
        try std.Io.Dir.cwd().createDirPath(io, documents_dir);
        const exports_dir = try std.fs.path.join(allocator, &.{ self.data_dir, "exports" });
        defer allocator.free(exports_dir);
        try std.Io.Dir.cwd().createDirPath(io, exports_dir);
        return std.Io.Dir.openDirAbsolute(io, self.data_dir, .{});
    }
};

test "resource and data paths stay separate and reject traversal" {
    var paths = try Paths.fromDirs(std.testing.allocator, .portable, "C:/app", "C:/data");
    defer paths.deinit(std.testing.allocator);
    const resource = try paths.resourcePath(std.testing.allocator, "assets/examples/minimal.cut");
    defer std.testing.allocator.free(resource);
    const data = try paths.dataPath(std.testing.allocator, "documents/session.cut");
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.startsWith(u8, resource, "C:/app"));
    try std.testing.expect(std.mem.startsWith(u8, data, "C:/data"));
    try std.testing.expect(!std.mem.startsWith(u8, resource, "C:/data"));
    try std.testing.expectError(error.InvalidResourcePath, paths.dataPath(std.testing.allocator, "../outside.cut"));
    try std.testing.expectError(error.InvalidResourcePath, paths.resourcePath(std.testing.allocator, "/outside.cut"));
}

test "all runtime modes parse and unknown modes are rejected" {
    try std.testing.expectEqual(Mode.development, try parseMode("development"));
    try std.testing.expectEqual(Mode.portable, try parseMode("portable"));
    try std.testing.expectEqual(Mode.installed, try parseMode("installed"));
    try std.testing.expectError(error.InvalidMode, parseMode("other"));
}

test "verification data override is absolute and preserves resource ownership" {
    const absolute = if (@import("builtin").os.tag == .windows) "C:/verification" else "/verification";
    var paths = try Paths.fromDirs(std.testing.allocator, .portable, "C:/app", "C:/data");
    defer paths.deinit(std.testing.allocator);
    try paths.overrideDataDir(std.testing.allocator, absolute);
    try std.testing.expectEqualStrings("C:/app", paths.resource_dir);
    try std.testing.expectEqualStrings(absolute, paths.data_dir);
    try std.testing.expectError(error.InvalidResourcePath, paths.overrideDataDir(std.testing.allocator, "relative/data"));
    try std.testing.expectEqualStrings(absolute, paths.data_dir);
}
