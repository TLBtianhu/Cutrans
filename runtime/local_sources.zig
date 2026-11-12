//! Explicit one-level local browsing. Entries are observations, not Resources.
const std = @import("std");
const Context = @import("context.zig").Context;
const external = @import("external_sources.zig");
const boundary = @import("source_boundary.zig");

pub const page_limit = 128;
pub const max_entries = 4096;

pub const Entry = struct {
    name: []u8,
    kind: []const u8,
    size: u64,
};

pub const Page = struct {
    format: []const u8 = "cutrans-local-directory/1",
    path: []const u8,
    cursor: u64,
    next_cursor: ?u64,
    total: usize,
    entries: []Entry,
};

fn validPath(path: []const u8) bool {
    return path.len != 0 and path.len <= 4096 and std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn validName(name: []const u8) bool {
    return name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

fn nameLess(_: void, left: Entry, right: Entry) bool {
    const left_directory = std.mem.eql(u8, left.kind, "directory");
    const right_directory = std.mem.eql(u8, right.kind, "directory");
    if (left_directory != right_directory) return left_directory;
    const count = @min(left.name.len, right.name.len);
    for (left.name[0..count], right.name[0..count]) |a, b| {
        const lower_a = std.ascii.toLower(a);
        const lower_b = std.ascii.toLower(b);
        if (lower_a != lower_b) return lower_a < lower_b;
    }
    return left.name.len < right.name.len;
}

extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;

fn reparsePoint(allocator: std.mem.Allocator, path: []const u8) !bool {
    if (@import("builtin").os.tag != .windows) return false;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const attributes = GetFileAttributesW(wide);
    if (attributes == std.math.maxInt(u32)) return error.SourceMetadataUnavailable;
    return attributes & 0x400 != 0;
}

fn freeEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

pub fn browse(ctx: *Context, input_path: []const u8, cursor: u64, limit: u32) ![]u8 {
    if (!validPath(input_path) or limit == 0 or limit > page_limit) return error.InvalidSourcePath;
    const io = ctx.io orelse return error.IoNotReady;
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, input_path, ctx.allocator);
    defer ctx.allocator.free(path);
    if (!validPath(path)) return error.InvalidSourcePath;
    try boundary.check(ctx.allocator, io, input_path, path, ctx.paths.data_dir, ctx.paths.resource_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(ctx.allocator, &entries);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (!validName(entry.name)) return error.InvalidSourceEntry;
        const full = try std.fs.path.join(ctx.allocator, &.{ path, entry.name });
        defer ctx.allocator.free(full);
        if (try reparsePoint(ctx.allocator, full)) continue;
        if (entries.items.len == max_entries) return error.DirectoryTooLarge;
        const stat = try dir.statFile(io, entry.name, .{});
        if (stat.kind != entry.kind) return error.SourceChangedDuringRead;
        try entries.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, entry.name),
            .kind = @tagName(entry.kind),
            .size = if (entry.kind == .file) stat.size else 0,
        });
    }
    std.mem.sort(Entry, entries.items, {}, nameLess);
    for (entries.items, 0..) |entry, index| {
        if (index != 0 and std.ascii.eqlIgnoreCase(entries.items[index - 1].name, entry.name)) return error.DuplicateDirectoryEntry;
    }
    if (cursor > entries.items.len) return error.InvalidSourceCursor;
    const begin: usize = @intCast(cursor);
    const count = @min(limit, entries.items.len - begin);
    const end = begin + count;
    const result = try std.json.Stringify.valueAlloc(ctx.allocator, Page{
        .path = path,
        .cursor = cursor,
        .next_cursor = if (end < entries.items.len) end else null,
        .total = entries.items.len,
        .entries = entries.items[begin..end],
    }, .{});
    freeEntries(ctx.allocator, &entries);
    return result;
}

pub fn read(ctx: *Context, path: []const u8) ![]u8 {
    if (!validPath(path)) return error.InvalidSourcePath;
    const snapshot = try external.readFileSnapshot(ctx, path);
    defer ctx.allocator.free(snapshot.path);
    return snapshot.bytes;
}

fn fixture(ctx: *Context, root: []const u8) !void {
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    ctx.paths = try @import("paths.zig").Paths.fromDirsPhysical(std.testing.allocator, std.testing.io, .portable, resource, data);
}

test "one-level browsing pages observations without registering or retaining files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.bin", .data = "second" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "first" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.bin", .data = "" });
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/child.txt", .data = "child" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var ctx: Context = undefined;
    try fixture(&ctx, root);
    defer ctx.deinit();
    const first_text = try browse(&ctx, root, 0, 2);
    defer std.testing.allocator.free(first_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first_text, .{});
    defer parsed.deinit();
    const first = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 4), first.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first.get("next_cursor").?.integer);
    const entries = first.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("nested", entries[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("a.txt", entries[1].object.get("name").?.string);
    const second_text = try browse(&ctx, root, 2, 2);
    defer std.testing.allocator.free(second_text);
    const second_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second_text, .{});
    defer second_parsed.deinit();
    const second_entries = second_parsed.value.object.get("entries").?.array.items;
    try std.testing.expectEqualStrings("b.bin", second_entries[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("empty.bin", second_entries[1].object.get("name").?.string);
    try std.testing.expect(second_parsed.value.object.get("next_cursor").? == .null);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ root, "a.txt" });
    defer std.testing.allocator.free(file_path);
    const bytes = try read(&ctx, file_path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("first", bytes);
    try std.testing.expectEqual(@as(usize, 0), ctx.library.count);
    const catalog = try std.fs.path.join(std.testing.allocator, &.{ root, "data/library/catalog.json" });
    defer std.testing.allocator.free(catalog);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, catalog, .{}));
}

test "browse rejects managed roots invalid cursors and non-paged limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var ctx: Context = undefined;
    try fixture(&ctx, root);
    defer ctx.deinit();
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data);
    try std.testing.expectError(error.ManagedSourceForbidden, browse(&ctx, data, 0, 128));
    try std.testing.expectError(error.InvalidSourceCursor, browse(&ctx, root, 2, 128));
    try std.testing.expectError(error.InvalidSourcePath, browse(&ctx, root, 0, 129));
    try std.testing.expectError(error.InvalidSourcePath, browse(&ctx, "relative", 0, 128));
}
