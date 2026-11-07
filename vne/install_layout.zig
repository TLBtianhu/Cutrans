//! Layout helpers derive identity from context metadata, never from a missing Runtime fallback.
const std = @import("std");
const environment = @import("environment.zig");

pub fn installedRoot(allocator: std.mem.Allocator, io: std.Io, exe_dir: []const u8) !?[]u8 {
    var context = try environment.load(allocator, io, exe_dir);
    defer context.deinit();
    return if (context.form == .installed) try allocator.dupe(u8, context.product_root) else null;
}

pub fn portableRoot(allocator: std.mem.Allocator, io: std.Io, exe_dir: []const u8) !?[]u8 {
    var context = try environment.load(allocator, io, exe_dir);
    defer context.deinit();
    return if (context.form == .portable) try allocator.dupe(u8, context.product_root) else null;
}

pub fn dataDir(allocator: std.mem.Allocator, io: std.Io, exe_dir: []const u8) !?[]u8 {
    var context = try environment.load(allocator, io, exe_dir);
    defer context.deinit();
    return if (context.form == .installed) try context.dataDir(io, null, .normal) else null;
}

pub fn portableDataDir(allocator: std.mem.Allocator, io: std.Io, exe_dir: []const u8) !?[]u8 {
    var context = try environment.load(allocator, io, exe_dir);
    defer context.deinit();
    return if (context.form == .portable) try context.dataDir(io, null, .normal) else null;
}

fn writeContext(dir: std.Io.Dir, relative: []const u8, form: []const u8) !void {
    const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"cutrans-run-context/1\",\"product_id\":\"{s}\",\"version\":\"{s}\",\"channel\":\"stable\",\"form\":\"{s}\",\"development_data_root\":\"\",\"services\":{{\"updates\":false,\"accounts\":false,\"telemetry\":false}}}}", .{ @import("product.zig").id, @import("product.zig").version, form });
    defer std.testing.allocator.free(text);
    try dir.writeFile(std.testing.io, .{ .sub_path = relative, .data = text });
}

test "installed app and optional Shell share context even when Runtime is broken" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const app = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app);
    try tmp.dir.createDirPath(std.testing.io, "app");
    try std.testing.expectError(error.MissingRunContext, dataDir(std.testing.allocator, std.testing.io, app));
    try writeContext(tmp.dir, "app/cutrans-context.json", "installed");
    const data = (try dataDir(std.testing.allocator, std.testing.io, app)).?;
    defer std.testing.allocator.free(data);
    const joined = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(joined);
    const expected = try environment.canonicalPath(std.testing.allocator, std.testing.io, joined);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, data);
    try tmp.dir.createDirPath(std.testing.io, "shells/nanoui-library");
    const shell = try std.fs.path.join(std.testing.allocator, &.{ root, "shells", "nanoui-library" });
    defer std.testing.allocator.free(shell);
    const shell_data = (try dataDir(std.testing.allocator, std.testing.io, shell)).?;
    defer std.testing.allocator.free(shell_data);
    try std.testing.expectEqualStrings(expected, shell_data);
}

test "portable Shell context belongs to its product root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "nanoui-library");
    try writeContext(tmp.dir, "cutrans-context.json", "portable");
    const shell = try std.fs.path.join(std.testing.allocator, &.{ root, "nanoui-library" });
    defer std.testing.allocator.free(shell);
    const data = (try portableDataDir(std.testing.allocator, std.testing.io, shell)).?;
    defer std.testing.allocator.free(data);
    const root_data = (try portableDataDir(std.testing.allocator, std.testing.io, root)).?;
    defer std.testing.allocator.free(root_data);
    try std.testing.expectEqualStrings(root_data, data);
}
