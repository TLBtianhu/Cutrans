//! task_journal.zig — Task Registry 的版本化快照与崩溃恢复
//!
//! 活跃任务不跨进程假装继续:完整载入后 queued/running 统一变 interrupted。
//! 解析先写临时 Registry,损坏输入不会覆盖调用方的最后有效状态。

const std = @import("std");
const command = @import("command.zig");
const tasks = @import("tasks.zig");
const storage = @import("storage.zig");

pub const journal_path = "tasks/journal.txt";
pub const legacy_archive_path = "tasks/legacy-journal-v1.txt";

fn openTasks(dir: std.Io.Dir, io: std.Io, create: bool) !std.Io.Dir {
    if (create) dir.createDir(io, "tasks", .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    return dir.openDir(io, "tasks", .{ .follow_symlinks = false });
}

fn readText(dir: std.Io.Dir, name: []const u8, allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var file = dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > 64 * 1024) return error.InvalidTaskJournal;
    const text = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(text);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(text);
    return text;
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn save(registry: *const tasks.Registry, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "cutrans_tasks=1\n");
    try appendFmt(&out, allocator, "task_clock={d}\nevent_clock={d}\n", .{ registry.task_clock, registry.event_clock });
    for (registry.items[0..registry.count]) |task| {
        try appendFmt(&out, allocator, "task={d},{s},", .{ task.id, @tagName(task.state) });
        if (task.progress_milli) |value| try appendFmt(&out, allocator, "{d}", .{value}) else try out.appendSlice(allocator, "-");
        try out.appendSlice(allocator, ",");
        if (task.result) |value| try out.appendSlice(allocator, @tagName(value)) else try out.appendSlice(allocator, "-");
        try out.appendSlice(allocator, "\n");
    }
    var task_dir = try openTasks(dir, io, true);
    defer task_dir.close(io);
    try storage.writeAtomic(task_dir, io, "journal.txt", out.items);
}

fn validResult(state: tasks.State, result: ?command.Code) bool {
    return switch (state) {
        .queued, .running => result == null,
        .succeeded => result == .ok,
        .failed => result != null and result.? != .ok and result.? != .accepted and result.? != .cancelled,
        .cancelled => result == .cancelled,
        .interrupted => result == .failed,
    };
}

fn parseTask(registry: *tasks.Registry, line: []const u8) !void {
    if (registry.count == registry.items.len) return error.InvalidTaskJournal;
    var fields = std.mem.splitScalar(u8, line["task=".len..], ',');
    const id_text = fields.next() orelse return error.InvalidTaskJournal;
    const state_text = fields.next() orelse return error.InvalidTaskJournal;
    const progress_text = fields.next() orelse return error.InvalidTaskJournal;
    const result_text = fields.next() orelse return error.InvalidTaskJournal;
    if (fields.next() != null) return error.InvalidTaskJournal;
    const id = std.fmt.parseInt(tasks.Id, id_text, 10) catch return error.InvalidTaskJournal;
    if (id == 0 or id > registry.task_clock or (registry.count > 0 and id <= registry.items[registry.count - 1].id)) return error.InvalidTaskJournal;
    const state = std.meta.stringToEnum(tasks.State, state_text) orelse return error.InvalidTaskJournal;
    const progress: ?u32 = if (std.mem.eql(u8, progress_text, "-")) null else std.fmt.parseInt(u32, progress_text, 10) catch return error.InvalidTaskJournal;
    if (progress != null and progress.? > 1000) return error.InvalidTaskJournal;
    const result: ?command.Code = if (std.mem.eql(u8, result_text, "-")) null else std.meta.stringToEnum(command.Code, result_text) orelse return error.InvalidTaskJournal;
    if (!validResult(state, result)) return error.InvalidTaskJournal;
    registry.items[registry.count] = .{ .id = id, .state = state, .progress_milli = progress, .result = result };
    registry.count += 1;
}

fn parseText(text: []const u8) !tasks.Registry {
    var restored: tasks.Registry = undefined;
    restored.init();
    var saw_header = false;
    var saw_task_clock = false;
    var saw_event_clock = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "cutrans_tasks=1")) {
            if (saw_header) return error.InvalidTaskJournal;
            saw_header = true;
        } else if (std.mem.startsWith(u8, line, "task_clock=")) {
            if (saw_task_clock) return error.InvalidTaskJournal;
            restored.task_clock = std.fmt.parseInt(u64, line["task_clock=".len..], 10) catch return error.InvalidTaskJournal;
            saw_task_clock = true;
        } else if (std.mem.startsWith(u8, line, "event_clock=")) {
            if (saw_event_clock) return error.InvalidTaskJournal;
            restored.event_clock = std.fmt.parseInt(u64, line["event_clock=".len..], 10) catch return error.InvalidTaskJournal;
            saw_event_clock = true;
        } else if (std.mem.startsWith(u8, line, "task=")) {
            if (!saw_header or !saw_task_clock or !saw_event_clock) return error.InvalidTaskJournal;
            try parseTask(&restored, line);
        } else return error.InvalidTaskJournal;
    }
    if (!saw_header or !saw_task_clock or !saw_event_clock) return error.InvalidTaskJournal;
    if (restored.count > 0 and restored.task_clock < restored.items[restored.count - 1].id) return error.InvalidTaskJournal;
    var active: u64 = 0;
    for (restored.items[0..restored.count]) |task| if (!tasks.terminal(task.state)) {
        active += 1;
    };
    _ = std.math.add(u64, restored.event_clock, active) catch return error.InvalidTaskJournal;
    return restored;
}

fn loadNamed(registry: *tasks.Registry, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?usize {
    var task_dir = openTasks(dir, io, false) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer task_dir.close(io);
    const text = (try readText(task_dir, name, allocator, io)) orelse return null;
    defer allocator.free(text);
    var restored = try parseText(text);
    const recovered = restored.recoverInterrupted();
    registry.* = restored;
    return recovered;
}

pub fn load(registry: *tasks.Registry, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?usize {
    return loadNamed(registry, allocator, io, dir, "journal.txt");
}

/// Preserve the original v1 bytes before the compatibility projection can be
/// overwritten. Existing archives are retained verbatim, including corrupt
/// evidence; this function never guesses a missing export declaration.
pub fn archiveLegacy(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var task_dir = openTasks(dir, io, false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer task_dir.close(io);
    const existing = try readText(task_dir, "legacy-journal-v1.txt", allocator, io);
    if (existing) |text| {
        allocator.free(text);
        return;
    }
    const original = (try readText(task_dir, "journal.txt", allocator, io)) orelse return;
    defer allocator.free(original);
    _ = try parseText(original);
    try storage.writeAtomic(task_dir, io, "legacy-journal-v1.txt", original);
}

pub fn loadLegacyArchive(registry: *tasks.Registry, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?usize {
    return loadNamed(registry, allocator, io, dir, "legacy-journal-v1.txt");
}

test "journal round trip interrupts active work and preserves id clocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var original: tasks.Registry = undefined;
    original.init();
    const finished = original.start().?;
    try std.testing.expect(original.succeed(finished));
    const active = original.start().?;
    try std.testing.expect(original.markRunning(active));
    try std.testing.expect(original.progress(active, 500));
    const task_clock = original.task_clock;
    const event_clock = original.event_clock;
    try save(&original, std.testing.allocator, std.testing.io, tmp.dir);

    var restored: tasks.Registry = undefined;
    restored.init();
    try std.testing.expectEqual(@as(?usize, 1), try load(&restored, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(tasks.State.succeeded, restored.get(finished).?.state);
    try std.testing.expectEqual(tasks.State.interrupted, restored.get(active).?.state);
    try std.testing.expectEqual(command.Code.failed, restored.get(active).?.result.?);
    try std.testing.expect(restored.event_clock > event_clock);
    try std.testing.expectEqual(task_clock + 1, restored.start().?);
}

test "missing and corrupt journals never erase the last valid registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry: tasks.Registry = undefined;
    registry.init();
    const id = registry.start().?;
    try std.testing.expectEqual(@as(?usize, null), try load(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    try storage.writeAtomic(tmp.dir, std.testing.io, journal_path, "cutrans_tasks=1\ntask_clock=9\nevent_clock=9\ntask=2,running\n");
    try std.testing.expectError(error.InvalidTaskJournal, load(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 1), registry.count);
    try std.testing.expectEqual(tasks.State.queued, registry.get(id).?.state);
}

test "legacy journal archive remains byte exact after recent projection eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry: tasks.Registry = .{};
    const original_id = registry.start().?;
    try std.testing.expect(registry.succeed(original_id));
    const active_id = registry.start().?;
    try save(&registry, std.testing.allocator, std.testing.io, tmp.dir);
    const original = try tmp.dir.readFileAlloc(std.testing.io, journal_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(original);
    try archiveLegacy(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expect(registry.cancel(active_id));
    for (0..50) |_| {
        const id = registry.start().?;
        try std.testing.expect(registry.succeed(id));
    }
    try save(&registry, std.testing.allocator, std.testing.io, tmp.dir);
    try archiveLegacy(std.testing.allocator, std.testing.io, tmp.dir);
    const archived = try tmp.dir.readFileAlloc(std.testing.io, legacy_archive_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(archived);
    try std.testing.expectEqualStrings(original, archived);
    var legacy: tasks.Registry = .{};
    try std.testing.expectEqual(@as(?usize, 1), try loadLegacyArchive(&legacy, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(tasks.State.succeeded, legacy.get(original_id).?.state);
    try std.testing.expectEqual(tasks.State.interrupted, legacy.get(active_id).?.state);
    try std.testing.expectEqual(@as(usize, 2), legacy.count);
    try std.testing.expect(registry.get(original_id) == null);
}

test "legacy journals reject invalid clocks and never archive corrupt input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_inputs = [_][]const u8{
        "cutrans_tasks=1\ntask_clock=1\nevent_clock=2\ntask=2,queued,-,-\n",
        "cutrans_tasks=1\ntask_clock=1\nevent_clock=18446744073709551615\ntask=1,running,-,-\n",
    };
    var registry: tasks.Registry = .{};
    const id = registry.start().?;
    for (bad_inputs) |text| {
        try storage.writeAtomic(tmp.dir, std.testing.io, journal_path, text);
        try std.testing.expectError(error.InvalidTaskJournal, archiveLegacy(std.testing.allocator, std.testing.io, tmp.dir));
        try std.testing.expectError(error.InvalidTaskJournal, load(&registry, std.testing.allocator, std.testing.io, tmp.dir));
        try std.testing.expectEqual(@as(usize, 1), registry.count);
        try std.testing.expectEqual(tasks.State.queued, registry.get(id).?.state);
        var legacy: tasks.Registry = .{};
        try std.testing.expect((try loadLegacyArchive(&legacy, std.testing.allocator, std.testing.io, tmp.dir)) == null);
    }
}
