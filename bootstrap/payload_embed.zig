//! Materialize the payload embedded in the executable into a managed cache.
//! The external `payload/` directory stays authoritative when present; this
//! only supplies the single-file fallback for a missing external payload.
const std = @import("std");

const magic = "CTPE1\x00\x00\x00";

fn readU16(bytes: []const u8, cursor: *usize) !u16 {
    if (cursor.* + 2 > bytes.len) return error.InvalidEmbeddedPayload;
    const value = std.mem.readInt(u16, bytes[cursor.*..][0..2], .little);
    cursor.* += 2;
    return value;
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* + 4 > bytes.len) return error.InvalidEmbeddedPayload;
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn take(bytes: []const u8, cursor: *usize, length: usize) ![]const u8 {
    if (cursor.* + length > bytes.len) return error.InvalidEmbeddedPayload;
    const value = bytes[cursor.*..][0..length];
    cursor.* += length;
    return value;
}

fn cacheComplete(allocator: std.mem.Allocator, io: std.Io, blob_bytes: []const u8, prefix: []const u8, cache: []const u8) !bool {
    if (!std.mem.startsWith(u8, blob_bytes, magic)) return error.InvalidEmbeddedPayload;
    var cursor: usize = magic.len;
    const count = try readU32(blob_bytes, &cursor);
    var found_manifest = false;
    for (0..count) |_| {
        const name_length = try readU16(blob_bytes, &cursor);
        const name = try take(blob_bytes, &cursor, name_length);
        const data_length = try readU32(blob_bytes, &cursor);
        const data = try take(blob_bytes, &cursor, data_length);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const relative = name[prefix.len..];
        const target = try std.fs.path.join(allocator, &.{ cache, relative });
        defer allocator.free(target);
        const actual = std.Io.Dir.cwd().readFileAlloc(io, target, allocator, .limited(data.len + 1)) catch return false;
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, data)) return false;
        if (std.mem.eql(u8, relative, "payload.json")) found_manifest = true;
    }
    return found_manifest;
}

fn pruneStaleCache(io: std.Io, cache_root: []const u8, blob_id: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, cache_root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const max_age_ns: i96 = 30 * 24 * 60 * 60 * std.time.ns_per_s;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, blob_id)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (now - stat.mtime.nanoseconds <= max_age_ns) continue;
        dir.deleteTree(io, entry.name) catch {};
    }
}

var staging_counter = std.atomic.Value(u64).init(0);

fn deleteTreePath(io: std.Io, path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    const name = std.fs.path.basename(path);
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer dir.close(io);
    dir.deleteTree(io, name) catch {};
}

pub fn materialize(allocator: std.mem.Allocator, io: std.Io, blob_id: []const u8, blob_bytes: []const u8, cache_root: []const u8, flavor: []const u8) ![]u8 {
    if (!std.mem.eql(u8, flavor, "desktop") and !std.mem.eql(u8, flavor, "nanoui-library")) return error.InvalidPayloadFlavor;
    const cache = try std.fs.path.join(allocator, &.{ cache_root, blob_id, flavor });
    errdefer allocator.free(cache);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{flavor});
    defer allocator.free(prefix);
    if (try cacheComplete(allocator, io, blob_bytes, prefix, cache)) {
        pruneStaleCache(io, cache_root, blob_id);
        return cache;
    }

    if (!std.mem.startsWith(u8, blob_bytes, magic)) return error.InvalidEmbeddedPayload;
    const cache_parent = std.fs.path.dirname(cache) orelse return error.InvalidEmbeddedPayload;
    const nonce = staging_counter.fetchAdd(1, .monotonic);
    const staging = try std.fmt.allocPrint(allocator, "{s}/.staging-{d}-{d}", .{ cache_parent, std.Thread.getCurrentId(), nonce });
    defer allocator.free(staging);
    errdefer deleteTreePath(io, staging);
    try std.Io.Dir.cwd().createDirPath(io, staging);

    var cursor: usize = magic.len;
    const count = try readU32(blob_bytes, &cursor);
    var manifest_data: ?[]const u8 = null;
    for (0..count) |_| {
        const name_length = try readU16(blob_bytes, &cursor);
        const name = try take(blob_bytes, &cursor, name_length);
        const data_length = try readU32(blob_bytes, &cursor);
        const data = try take(blob_bytes, &cursor, data_length);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const relative = name[prefix.len..];
        if (std.mem.eql(u8, relative, "payload.json")) {
            manifest_data = data;
            continue;
        }
        const target = try std.fs.path.join(allocator, &.{ staging, relative });
        defer allocator.free(target);
        if (std.fs.path.dirname(target)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = data });
    }
    const bytes = manifest_data orelse return error.InvalidEmbeddedPayload;
    const staging_manifest = try std.fs.path.join(allocator, &.{ staging, "payload.json" });
    defer allocator.free(staging_manifest);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging_manifest, .data = bytes });

    std.Io.Dir.renameAbsolute(staging, cache, io) catch |rename_error| {
        if (cacheComplete(allocator, io, blob_bytes, prefix, cache) catch false) {
            deleteTreePath(io, staging);
            pruneStaleCache(io, cache_root, blob_id);
            return cache;
        }
        // An incomplete cache can only come from an older direct-write
        // version or a damaged file. Replace it once; a concurrent winner is
        // detected by the completeness check above.
        deleteTreePath(io, cache);
        std.Io.Dir.renameAbsolute(staging, cache, io) catch {
            deleteTreePath(io, staging);
            return rename_error;
        };
    };
    pruneStaleCache(io, cache_root, blob_id);
    return cache;
}

test "concurrent materialization converges on one complete cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const manifest = "{\"id\":\"concurrent\"}";
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(std.testing.allocator);
    try blob.appendSlice(std.testing.allocator, magic);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, 2, .little);
    try blob.appendSlice(std.testing.allocator, &count);
    for ([_][]const u8{ "desktop/payload.json", "desktop/assets/concurrent.txt" }, [_][]const u8{ manifest, "stable" }) |path, data| {
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(path.len), .little);
        try blob.appendSlice(std.testing.allocator, &length);
        try blob.appendSlice(std.testing.allocator, path);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.len), .little);
        try blob.appendSlice(std.testing.allocator, &size);
        try blob.appendSlice(std.testing.allocator, data);
    }

    const Worker = struct {
        fn run(failures: *std.atomic.Value(u32), bytes: []const u8, cache_root: []const u8) void {
            const cache = materialize(std.heap.page_allocator, std.testing.io, "concurrent-blob", bytes, cache_root, "desktop") catch {
                _ = failures.fetchAdd(1, .monotonic);
                return;
            };
            std.heap.page_allocator.free(cache);
        }
    };
    var failures = std.atomic.Value(u32).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &failures, blob.items, root });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));

    const cache = try materialize(std.testing.allocator, std.testing.io, "concurrent-blob", blob.items, root, "desktop");
    defer std.testing.allocator.free(cache);
    const file = try std.fs.path.join(std.testing.allocator, &.{ cache, "assets/concurrent.txt" });
    defer std.testing.allocator.free(file);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("stable", contents);
}

test "embedded payload cache is repaired after corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const manifest = "{\"id\":\"test\"}";
    const name = "desktop/payload.json";
    const payload = "hello";
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(std.testing.allocator);
    try blob.appendSlice(std.testing.allocator, magic);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, 2, .little);
    try blob.appendSlice(std.testing.allocator, &count);
    for ([_][]const u8{ name, "desktop/assets/hello.txt" }, [_][]const u8{ manifest, payload }) |path, data| {
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(path.len), .little);
        try blob.appendSlice(std.testing.allocator, &length);
        try blob.appendSlice(std.testing.allocator, path);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(data.len), .little);
        try blob.appendSlice(std.testing.allocator, &size);
        try blob.appendSlice(std.testing.allocator, data);
    }

    const cache = try materialize(std.testing.allocator, std.testing.io, "test-blob", blob.items, root, "desktop");
    defer std.testing.allocator.free(cache);
    const file = try std.fs.path.join(std.testing.allocator, &.{ cache, "assets/hello.txt" });
    defer std.testing.allocator.free(file);
    const first = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings(payload, first);

    const cache2 = try materialize(std.testing.allocator, std.testing.io, "test-blob", blob.items, root, "desktop");
    defer std.testing.allocator.free(cache2);
    try std.testing.expectEqualStrings(cache, cache2);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file, .data = "changed" });
    const cache3 = try materialize(std.testing.allocator, std.testing.io, "test-blob", blob.items, root, "desktop");
    defer std.testing.allocator.free(cache3);
    const repaired = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(repaired);
    try std.testing.expectEqualStrings(payload, repaired);
}
