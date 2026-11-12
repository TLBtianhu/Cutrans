//! Per-job source of truth. Recent task metadata is a bounded projection only.
//! Records are never silently deleted; recovery explains interrupted attempts
//! and does not repeat output writes or claim that prepared output succeeded.
const std = @import("std");
const tasks = @import("tasks.zig");
const job_mod = @import("export_job.zig");
const documents = @import("vne").documents;
const command = @import("vne").command;
const storage = @import("storage.zig");
const workspace = @import("vne").workspace;

pub const max_record_bytes = 128 * 1024;
pub const max_page = 32;
pub const Record = struct { job: job_mod.Job, task: tasks.Task };

const WireJob = struct {
    task_id: tasks.Id,
    operation: []const u8,
    document: []const u8,
    fingerprint: u64,
    node_id_high_water: u64,
    origin: workspace.Stamp,
    source_fingerprint: u64,
    path: []const u8,
    explicit_path: bool,
    target: []const u8,
    phase: job_mod.Phase,
    output_hash: []const u8,
    output_size: u64,
    retry_of: ?tasks.Id,
    attempt: u32 = 1,
    cancel_requested: bool = false,
    failure: ?command.Code,
    error_text: []const u8,
};
const Wire = struct { format: []const u8, job: WireJob, task: tasks.Task };

fn validTask(task: tasks.Task) bool {
    if (task.id == 0 or (if (task.progress_milli) |value| value > 1000 else false)) return false;
    return switch (task.state) {
        .queued, .running => task.result == null,
        .succeeded => task.result == .ok,
        .failed => task.result != null and task.result.? != .ok and task.result.? != .accepted and task.result.? != .cancelled,
        .cancelled => task.result == .cancelled,
        .interrupted => task.result == .failed,
    };
}

fn validRecord(job: *const job_mod.Job, task: tasks.Task) bool {
    if (job.task_id != task.id or !validTask(task) or job.target_len == 0 or job.target_len > job.target_bytes.len or
        job.path_len == 0 or job.path_len > job.path_bytes.len or job.error_len > job.error_bytes.len or
        !std.fs.path.isAbsolute(job.target()) or job.attempt == 0 or (job.retry_of == null and job.attempt != 1) or
        (if (job.retry_of) |id| id == 0 or id >= task.id else false)) return false;
    if (job.cancel_requested and (job.phase == .output_committed or job.phase == .succeeded or task.state == .succeeded)) return false;
    const state_ok = switch (job.phase) {
        .queued => task.state == .queued or task.state == .interrupted,
        .running, .prepared, .output_committed => task.state == .running or task.state == .interrupted,
        .succeeded => task.state == .succeeded,
        .failed => task.state == .failed,
        .cancelled => task.state == .cancelled,
        .interrupted => task.state == .interrupted,
    };
    if (!state_ok) return false;
    if ((job.phase == .prepared or job.phase == .output_committed or job.phase == .succeeded) and job.output_size == 0) return false;
    return true;
}

fn validTransition(previous: job_mod.Phase, next: job_mod.Phase) bool {
    if (previous == next) return true;
    return switch (previous) {
        .queued => next == .running or next == .failed or next == .cancelled,
        .running => next == .prepared or next == .failed or next == .cancelled,
        .prepared => next == .output_committed or next == .succeeded or next == .failed or next == .cancelled,
        .output_committed => next == .succeeded,
        .succeeded, .failed, .cancelled, .interrupted => false,
    };
}

fn filename(buffer: *[25]u8, id: tasks.Id) ![]const u8 {
    if (id == 0) return error.InvalidJobRecord;
    return std.fmt.bufPrint(buffer, "{d:0>20}.json", .{id});
}

fn fileId(name: []const u8) !tasks.Id {
    if (name.len != 25 or !std.mem.endsWith(u8, name, ".json")) return error.InvalidJobFilename;
    for (name[0..20]) |byte| if (byte < '0' or byte > '9') return error.InvalidJobFilename;
    const id = std.fmt.parseInt(tasks.Id, name[0..20], 10) catch return error.InvalidJobFilename;
    if (id == 0) return error.InvalidJobFilename;
    return id;
}

fn openJobs(dir: std.Io.Dir, io: std.Io, create: bool) !std.Io.Dir {
    if (create) dir.createDir(io, "tasks", .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var task_dir = try dir.openDir(io, "tasks", .{ .follow_symlinks = false });
    defer task_dir.close(io);
    if (create) task_dir.createDir(io, "jobs", .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    return task_dir.openDir(io, "jobs", .{ .iterate = true, .follow_symlinks = false });
}

pub fn save(job: *const job_mod.Job, task: tasks.Task, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    if (!validRecord(job, task)) return error.InvalidJobRecord;
    const text = try std.json.Stringify.valueAlloc(allocator, .{ .format = "cutrans-job/1", .job = job, .task = task }, .{});
    defer allocator.free(text);
    if (text.len > max_record_bytes) return error.JobRecordTooLarge;
    var jobs = try openJobs(dir, io, true);
    defer jobs.close(io);
    if (try loadFrom(jobs, task.id, allocator, io)) |previous| {
        if (previous.job.document.fingerprint() != job.document.fingerprint() or
            previous.job.document.nodeIdHighWater() != job.document.nodeIdHighWater() or
            !previous.job.origin.eql(job.origin) or previous.job.source_fingerprint != job.source_fingerprint or
            previous.job.explicit_path != job.explicit_path or !std.mem.eql(u8, previous.job.path(), job.path()) or
            !std.mem.eql(u8, previous.job.target(), job.target()) or previous.job.retry_of != job.retry_of or previous.job.attempt != job.attempt) return error.ImmutableJobSpec;
        if (previous.job.cancel_requested and !job.cancel_requested) return error.CancelRequestRollback;
        if (!previous.job.cancel_requested and job.cancel_requested and
            (tasks.terminal(previous.task.state) or (previous.job.phase != .queued and previous.job.phase != .running and previous.job.phase != .prepared)))
            return error.CancelTooLate;
        if (tasks.terminal(previous.task.state) and (previous.task.state != task.state or previous.job.phase != job.phase or
            previous.task.result != task.result or previous.job.output_size != job.output_size or
            !std.mem.eql(u8, &previous.job.output_hash, &job.output_hash) or previous.job.cancel_requested != job.cancel_requested)) return error.TerminalJobState;
        if (!tasks.terminal(previous.task.state) and !validTransition(previous.job.phase, job.phase)) return error.InvalidJobPhaseTransition;
    } else if (job.retry_of) |parent_id| {
        const parent = (try loadFrom(jobs, parent_id, allocator, io)) orelse return error.MissingRetryParent;
        if (!tasks.terminal(parent.task.state) or parent.task.state == .succeeded) return error.InvalidRetryParent;
        if (parent.job.attempt == 0 or (parent.job.retry_of != null and parent.job.attempt == 1)) return error.InvalidRetryLineage;
        const attempt = std.math.add(u32, parent.job.attempt, 1) catch return error.AttemptOverflow;
        if (job.attempt != attempt) return error.InvalidRetryAttempt;
        if (parent.job.document.fingerprint() != job.document.fingerprint() or parent.job.document.nodeIdHighWater() != job.document.nodeIdHighWater() or
            !parent.job.origin.eql(job.origin) or parent.job.source_fingerprint != job.source_fingerprint) return error.ImmutableRetryInput;
    }
    var buffer: [25]u8 = undefined;
    try storage.writeAtomic(jobs, io, try filename(&buffer, task.id), text);
}

fn loadFrom(jobs: std.Io.Dir, id: tasks.Id, allocator: std.mem.Allocator, io: std.Io) !?Record {
    var name: [25]u8 = undefined;
    const path = try filename(&name, id);
    var file = jobs.openFile(io, path, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_record_bytes) return error.JobRecordTooLarge;
    const text = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(text);
    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.interface.readSliceAll(text);
    const parsed = std.json.parseFromSlice(Wire, allocator, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJobRecord,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (!std.mem.eql(u8, wire.format, "cutrans-job/1") or !std.mem.eql(u8, wire.job.operation, "image.png.export/1") or
        wire.task.id != id or wire.job.task_id != id or wire.job.output_hash.len != 64 or wire.job.error_text.len > 96) return error.InvalidJobRecord;
    const document = documents.parse(wire.job.document) catch return error.InvalidJobRecord;
    if (document.fingerprint() != wire.job.fingerprint or document.nodeIdHighWater() != wire.job.node_id_high_water) return error.InvalidJobRecord;
    // Canonical spelling is part of the immutable declaration, not just a hash.
    const canonical = try documents.emitAlloc(&document, allocator);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, wire.job.document)) return error.InvalidJobRecord;
    var job = job_mod.Job.init(id, document, if (wire.job.explicit_path) wire.job.path else null) catch return error.InvalidJobRecord;
    if (!std.mem.eql(u8, job.path(), wire.job.path)) return error.InvalidJobRecord;
    job.setTarget(wire.job.target) catch return error.InvalidJobRecord;
    job.origin = wire.job.origin;
    job.source_fingerprint = wire.job.source_fingerprint;
    job.phase = wire.job.phase;
    _ = std.fmt.hexToBytes(&job.output_hash, wire.job.output_hash) catch return error.InvalidJobRecord;
    job.output_size = wire.job.output_size;
    job.retry_of = wire.job.retry_of;
    job.attempt = wire.job.attempt;
    job.cancel_requested = wire.job.cancel_requested;
    job.failure = wire.job.failure;
    job.setError(wire.job.error_text);
    if (!validRecord(&job, wire.task)) return error.InvalidJobRecord;
    return .{ .job = job, .task = wire.task };
}

pub fn load(id: tasks.Id, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?Record {
    var jobs = openJobs(dir, io, false) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer jobs.close(io);
    return loadFrom(jobs, id, allocator, io);
}

/// Merge legacy recent metadata first, then authoritative per-job records. A
/// failed scan never publishes a partly restored cache; recovered records may
/// already have been durably marked interrupted and remain safe to load again.
pub fn loadAll(registry: *tasks.Registry, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !usize {
    var jobs = openJobs(dir, io, false) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer jobs.close(io);
    var candidate = registry.*;
    var recovered: usize = 0;
    var iterator = jobs.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue; // Incomplete atomic staging is never a committed record.
        if (entry.kind != .file) return error.InvalidJobRecord;
        const id = try fileId(entry.name);
        var record = (try loadFrom(jobs, id, allocator, io)) orelse return error.MissingJobRecord;
        if (!tasks.terminal(record.task.state)) {
            // Consult the initial projection, not a cache whose older entries
            // can be evicted while the archive is scanned in arbitrary order.
            const recovered_state: tasks.State = if (record.job.cancel_requested) .cancelled else .interrupted;
            const already_recovered = if (registry.get(id)) |old| old.state == recovered_state else false;
            if (!already_recovered and candidate.event_clock == std.math.maxInt(u64)) return error.TaskClockOverflow;
            record.task.state = recovered_state;
            record.task.result = if (record.job.cancel_requested) .cancelled else .failed;
            record.job.failure = record.task.result;
            if (record.job.cancel_requested) {
                record.job.phase = .cancelled;
                record.job.setError("CancelledAfterRuntimeRestart");
            } else {
                record.job.setError(if (record.job.phase == .prepared) "InterruptedPreparedOutputUnverified" else "InterruptedByRuntimeRestart");
            }
            try save(&record.job, record.task, allocator, io, dir);
            recovered += 1; // Count authoritative records actually converted.
            if (!already_recovered) {
                try candidate.observeRestored(record.task);
            }
        }
        try candidate.put(record.task);
    }
    registry.* = candidate;
    return recovered;
}

/// Ascending task IDs after the cursor. Memory is bounded by one record plus
/// at most 32 results regardless of archive size; callers free the returned slice.
pub fn page(after_id: tasks.Id, limit: usize, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]Record {
    if (limit == 0 or limit > max_page) return error.InvalidJobPage;
    var output: std.ArrayList(Record) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, limit);
    var jobs = openJobs(dir, io, false) catch |err| {
        if (err == error.FileNotFound) return output.toOwnedSlice(allocator);
        return err;
    };
    defer jobs.close(io);
    var iterator = jobs.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (entry.kind != .file) return error.InvalidJobRecord;
        const id = try fileId(entry.name);
        if (id <= after_id or (output.items.len == limit and id >= output.items[output.items.len - 1].task.id)) continue;
        const record = (try loadFrom(jobs, id, allocator, io)) orelse return error.MissingJobRecord;
        var index: usize = 0;
        while (index < output.items.len and output.items[index].task.id < id) : (index += 1) {}
        if (output.items.len < limit) output.items.len += 1;
        var move = output.items.len - 1;
        while (move > index) : (move -= 1) output.items[move] = output.items[move - 1];
        output.items[index] = record;
    }
    return output.toOwnedSlice(allocator);
}

fn testJob(dir: std.Io.Dir, id: tasks.Id) !job_mod.Job {
    const root = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target = try std.fs.path.join(std.testing.allocator, &.{ root, "output.png" });
    defer std.testing.allocator.free(target);
    var job = try job_mod.Job.init(id, documents.Document.initDefault(), null);
    try job.setTarget(target);
    job.origin = .{ .epoch_hi = 11, .epoch_lo = 22, .revision = 3 };
    job.source_fingerprint = job.document.fingerprint();
    return job;
}

test "ledger round trip retains declaration provenance phase and initialized JSON fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    job.phase = .prepared;
    job.output_hash = @splat(7);
    job.output_size = 123;
    job.setError("SharingViolation");
    const task = tasks.Task{ .id = 1, .state = .running };
    try save(&job, task, std.testing.allocator, std.testing.io, tmp.dir);
    const restored = (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(job_mod.Phase.prepared, restored.job.phase);
    try std.testing.expectEqual(job.document.fingerprint(), restored.job.document.fingerprint());
    try std.testing.expectEqual(job.source_fingerprint, restored.job.source_fingerprint);
    try std.testing.expectEqual(job.output_hash, restored.job.output_hash);
    try std.testing.expect(job.origin.eql(restored.job.origin));
    try std.testing.expectEqualStrings(job.target(), restored.job.target());
    try std.testing.expectEqualStrings("SharingViolation", restored.job.errorText());
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, restored, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "path_bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "image.png.export/1") != null);
}

test "ledger archives grow beyond recent cache and recover without executing prepared output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (1..56) |id| {
        var job = try testJob(tmp.dir, id);
        job.phase = .succeeded;
        job.output_hash = @splat(1);
        job.output_size = 1;
        try save(&job, .{ .id = id, .state = .succeeded, .result = .ok }, std.testing.allocator, std.testing.io, tmp.dir);
    }
    var queued = try testJob(tmp.dir, 56);
    try save(&queued, .{ .id = 56, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var prepared = try testJob(tmp.dir, 57);
    prepared.phase = .prepared;
    prepared.output_hash = @splat(2);
    prepared.output_size = 123;
    try save(&prepared, .{ .id = 57, .state = .running }, std.testing.allocator, std.testing.io, tmp.dir);
    var registry: tasks.Registry = .{};
    registry.task_clock = 100; // Reserved legacy IDs survive terminal-cache eviction.
    try std.testing.expectEqual(@as(usize, 2), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 40), registry.count);
    try std.testing.expect(registry.get(1) == null);
    try std.testing.expectEqual(tasks.State.interrupted, registry.get(56).?.state);
    try std.testing.expectEqual(tasks.State.interrupted, registry.get(57).?.state);
    try std.testing.expectEqual(@as(u64, 101), registry.start().?);
    const recovered = (try load(57, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(job_mod.Phase.prepared, recovered.job.phase);
    try std.testing.expectEqualStrings("InterruptedPreparedOutputUnverified", recovered.job.errorText());
    try std.testing.expectEqual(@as(usize, 0), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    const first = try page(0, 32, std.testing.allocator, std.testing.io, tmp.dir);
    defer std.testing.allocator.free(first);
    const second = try page(32, 32, std.testing.allocator, std.testing.io, tmp.dir);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 32), first.len);
    try std.testing.expectEqual(@as(usize, 25), second.len);
    for (first, 1..) |record, expected| try std.testing.expectEqual(@as(u64, expected), record.task.id);
    for (second, 33..) |record, expected| try std.testing.expectEqual(@as(u64, expected), record.task.id);
    try std.testing.expectError(error.InvalidJobPage, page(0, 33, std.testing.allocator, std.testing.io, tmp.dir));
}

test "ledger failed allocation and malformed filename identity preserve prior state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    try save(&job, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var candidate = job;
    candidate.phase = .cancelled;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, save(&candidate, .{ .id = 1, .state = .cancelled, .result = .cancelled }, failing.allocator(), std.testing.io, tmp.dir));
    try std.testing.expectEqual(job_mod.Phase.queued, (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?.job.phase);
    var jobs = try openJobs(tmp.dir, std.testing.io, false);
    defer jobs.close(std.testing.io);
    const text = try jobs.readFileAlloc(std.testing.io, "00000000000000000001.json", std.testing.allocator, .limited(max_record_bytes));
    defer std.testing.allocator.free(text);
    try jobs.writeFile(std.testing.io, .{ .sub_path = "00000000000000000002.json", .data = text });
    try std.testing.expectError(error.InvalidJobRecord, load(2, std.testing.allocator, std.testing.io, tmp.dir));
    var registry: tasks.Registry = .{};
    _ = registry.start().?;
    try std.testing.expectError(error.InvalidJobRecord, loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 1), registry.count);
    try std.testing.expectEqual(tasks.State.queued, registry.get(1).?.state);
}

test "ledger declaration and terminal outcome cannot be rewritten under the same task id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    try save(&job, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var changed = job;
    try changed.document.setGainText("c1 0.25");
    try std.testing.expectError(error.ImmutableJobSpec, save(&changed, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir));
    job.phase = .cancelled;
    try save(&job, .{ .id = 1, .state = .cancelled, .result = .cancelled }, std.testing.allocator, std.testing.io, tmp.dir);
    changed = job;
    changed.phase = .failed;
    try std.testing.expectError(error.TerminalJobState, save(&changed, .{ .id = 1, .state = .failed, .result = .failed }, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(tasks.State.cancelled, (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?.task.state);
}

test "ledger rejects corrupt hash canonical text fingerprint and oversized records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    try save(&job, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var jobs = try openJobs(tmp.dir, std.testing.io, false);
    defer jobs.close(std.testing.io);
    const path = "00000000000000000001.json";
    const original = try jobs.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(max_record_bytes));
    defer std.testing.allocator.free(original);
    const parsed = try std.json.parseFromSlice(Wire, std.testing.allocator, original, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const noncanonical = try std.mem.concat(std.testing.allocator, u8, &.{ parsed.value.job.document, "\n" });
    defer std.testing.allocator.free(noncanonical);
    for (0..3) |index| {
        var invalid = parsed.value;
        switch (index) {
            0 => invalid.job.output_hash = "00",
            1 => invalid.job.document = noncanonical,
            2 => invalid.job.fingerprint ^= 1,
            else => unreachable,
        }
        const corrupt = try std.json.Stringify.valueAlloc(std.testing.allocator, invalid, .{});
        defer std.testing.allocator.free(corrupt);
        try storage.writeAtomic(jobs, std.testing.io, path, corrupt);
        try std.testing.expectError(error.InvalidJobRecord, load(1, std.testing.allocator, std.testing.io, tmp.dir));
    }
    const oversized = try std.testing.allocator.alloc(u8, max_record_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try storage.writeAtomic(jobs, std.testing.io, path, oversized);
    try std.testing.expectError(error.JobRecordTooLarge, load(1, std.testing.allocator, std.testing.io, tmp.dir));
    try storage.writeAtomic(jobs, std.testing.io, path, original);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, load(1, failing.allocator(), std.testing.io, tmp.dir));
}

test "ledger recovery counts authoritative transitions without repeating legacy events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    try save(&job, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var registry: tasks.Registry = .{};
    try registry.put(.{ .id = 1, .state = .interrupted, .result = .failed });
    registry.event_clock = 9; // The v1 projection already emitted recovery.
    try std.testing.expectEqual(@as(usize, 1), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(u64, 9), registry.event_clock);
    try std.testing.expectEqual(@as(usize, 0), registry.event_count);
    try std.testing.expectEqual(tasks.State.interrupted, registry.get(1).?.state);
    const restored = (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(tasks.State.interrupted, restored.task.state);
    try std.testing.expectEqual(job_mod.Phase.queued, restored.job.phase);
    try std.testing.expectEqual(@as(usize, 0), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
}

test "ledger cancellation is durable monotone and cannot overtake a committed or terminal result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    const running = tasks.Task{ .id = 1, .state = .running };
    job.phase = .running;
    try save(&job, running, std.testing.allocator, std.testing.io, tmp.dir);
    job.phase = .prepared;
    job.output_hash = @splat(7);
    job.output_size = 123;
    try save(&job, running, std.testing.allocator, std.testing.io, tmp.dir);
    job.cancel_requested = true;
    try save(&job, running, std.testing.allocator, std.testing.io, tmp.dir);
    var stale_worker = job;
    stale_worker.cancel_requested = false;
    try std.testing.expectError(error.CancelRequestRollback, save(&stale_worker, running, std.testing.allocator, std.testing.io, tmp.dir));
    var late_success = job;
    late_success.phase = .succeeded;
    try std.testing.expectError(error.InvalidJobRecord, save(&late_success, .{ .id = 1, .state = .succeeded, .result = .ok }, std.testing.allocator, std.testing.io, tmp.dir));
    job.phase = .cancelled;
    try save(&job, .{ .id = 1, .state = .cancelled, .result = .cancelled }, std.testing.allocator, std.testing.io, tmp.dir);
    var terminal = try testJob(tmp.dir, 2);
    terminal.phase = .cancelled; // Compatible B1 cancellation had no intent flag.
    try save(&terminal, .{ .id = 2, .state = .cancelled, .result = .cancelled }, std.testing.allocator, std.testing.io, tmp.dir);
    terminal.cancel_requested = true;
    try std.testing.expectError(error.CancelTooLate, save(&terminal, .{ .id = 2, .state = .cancelled, .result = .cancelled }, std.testing.allocator, std.testing.io, tmp.dir));
    var committed = try testJob(tmp.dir, 3);
    committed.phase = .output_committed;
    committed.output_size = 1;
    committed.output_hash = @splat(8);
    try save(&committed, .{ .id = 3, .state = .running }, std.testing.allocator, std.testing.io, tmp.dir);
    committed.cancel_requested = true;
    committed.phase = .cancelled;
    try std.testing.expectError(error.CancelTooLate, save(&committed, .{ .id = 3, .state = .cancelled, .result = .cancelled }, std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(job_mod.Phase.output_committed, (try load(3, std.testing.allocator, std.testing.io, tmp.dir)).?.job.phase);
}

test "ledger restart settles durable cancellation without touching prepared output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "output.png", .data = "existing user output" });
    var queued = try testJob(tmp.dir, 1);
    queued.cancel_requested = true;
    try save(&queued, .{ .id = 1, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var prepared = try testJob(tmp.dir, 2);
    prepared.cancel_requested = true;
    prepared.phase = .prepared;
    prepared.output_hash = @splat(9);
    prepared.output_size = 123;
    try save(&prepared, .{ .id = 2, .state = .running }, std.testing.allocator, std.testing.io, tmp.dir);
    var registry: tasks.Registry = .{};
    try std.testing.expectEqual(@as(usize, 2), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
    for ([_]u64{ 1, 2 }) |id| {
        try std.testing.expectEqual(tasks.State.cancelled, registry.get(id).?.state);
        try std.testing.expectEqual(command.Code.cancelled, registry.get(id).?.result.?);
        const record = (try load(id, std.testing.allocator, std.testing.io, tmp.dir)).?;
        try std.testing.expect(record.job.cancel_requested);
        try std.testing.expectEqual(job_mod.Phase.cancelled, record.job.phase);
        try std.testing.expectEqualStrings("CancelledAfterRuntimeRestart", record.job.errorText());
    }
    const record = (try load(2, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(prepared.output_hash, record.job.output_hash);
    try std.testing.expectEqual(prepared.output_size, record.job.output_size);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "output.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("existing user output", output);
    try std.testing.expectEqual(@as(usize, 0), try loadAll(&registry, std.testing.allocator, std.testing.io, tmp.dir));
}

test "ledger retries create new attempts on the original input and preserve old terminal records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var original = try testJob(tmp.dir, 1);
    original.phase = .failed;
    original.failure = .failed;
    original.setError("OriginalFailure");
    try save(&original, .{ .id = 1, .state = .failed, .result = .failed }, std.testing.allocator, std.testing.io, tmp.dir);
    var retry = try job_mod.Job.retry(&original, 2, null);
    try std.testing.expectEqual(@as(u32, 2), retry.attempt);
    try std.testing.expectEqual(@as(?u64, 1), retry.retry_of);
    try std.testing.expect(retry.origin.eql(original.origin));
    try std.testing.expectEqual(original.source_fingerprint, retry.source_fingerprint);
    try std.testing.expectEqual(original.document.fingerprint(), retry.document.fingerprint());
    try std.testing.expectEqual(@as(u16, 0), retry.target_len);
    try std.testing.expect(!retry.cancel_requested and retry.failure == null and retry.error_len == 0 and retry.output_size == 0);
    try std.testing.expectError(error.InvalidJobRecord, save(&retry, .{ .id = 2, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir));
    try retry.setTarget(original.target()); // An owner resolves current authorization.
    try save(&retry, .{ .id = 2, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var changed = retry;
    changed.attempt = 3;
    try std.testing.expectError(error.ImmutableJobSpec, save(&changed, .{ .id = 2, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir));
    var mismatched_input = try job_mod.Job.retry(&original, 3, null);
    try mismatched_input.setTarget(original.target());
    try mismatched_input.document.setGainText("c1 0.25");
    try std.testing.expectError(error.ImmutableRetryInput, save(&mismatched_input, .{ .id = 3, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir));
    var active_parent = try job_mod.Job.retry(&retry, 4, null);
    try active_parent.setTarget(original.target());
    try std.testing.expectError(error.InvalidRetryParent, save(&active_parent, .{ .id = 4, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir));
    const old = (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(tasks.State.failed, old.task.state);
    try std.testing.expectEqualStrings("OriginalFailure", old.job.errorText());
    var external = try job_mod.Job.init(5, original.document, "external://7");
    external.origin = original.origin;
    external.source_fingerprint = original.source_fingerprint;
    try external.setTarget(original.target());
    try std.testing.expectError(error.RetryTargetRequired, job_mod.Job.retry(&external, 6, null));
    const redirected = try job_mod.Job.retry(&external, 6, "session://exports/retry.png");
    try std.testing.expectEqualStrings("session://exports/retry.png", redirected.path());
    try std.testing.expectEqual(@as(u16, 0), redirected.target_len);
    var exhausted = original;
    exhausted.task_id = 2;
    exhausted.attempt = std.math.maxInt(u32);
    exhausted.retry_of = 1;
    try std.testing.expectError(error.AttemptOverflow, job_mod.Job.retry(&exhausted, 3, null));
    try std.testing.expectError(error.InvalidRetryIdentity, job_mod.Job.retry(&original, 1, null));
}

test "ledger older records default cancellation and attempt fields without inventing retry lineage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var original = try testJob(tmp.dir, 1);
    original.phase = .failed;
    try save(&original, .{ .id = 1, .state = .failed, .result = .failed }, std.testing.allocator, std.testing.io, tmp.dir);
    var jobs = try openJobs(tmp.dir, std.testing.io, false);
    defer jobs.close(std.testing.io);
    const path = "00000000000000000001.json";
    const current = try jobs.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(max_record_bytes));
    defer std.testing.allocator.free(current);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const object = &parsed.value.object.getPtr("job").?.object;
    try std.testing.expect(object.swapRemove("attempt"));
    try std.testing.expect(object.swapRemove("cancel_requested"));
    const old_json = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(old_json);
    try storage.writeAtomic(jobs, std.testing.io, path, old_json);
    const restored = (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?;
    try std.testing.expectEqual(@as(u32, 1), restored.job.attempt);
    try std.testing.expect(!restored.job.cancel_requested);
    var retry = try job_mod.Job.retry(&restored.job, 2, null);
    try retry.setTarget(original.target());
    try save(&retry, .{ .id = 2, .state = .queued }, std.testing.allocator, std.testing.io, tmp.dir);
    var unknown = original;
    unknown.task_id = 3;
    unknown.retry_of = 1;
    unknown.attempt = 1; // B1's reserved field cannot establish an Attempt chain.
    try std.testing.expectError(error.InvalidRetryLineage, job_mod.Job.retry(&unknown, 4, null));
}

test "ledger phases cannot skip preparation regress or fail after output commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var job = try testJob(tmp.dir, 1);
    const queued = tasks.Task{ .id = 1, .state = .queued };
    const running = tasks.Task{ .id = 1, .state = .running };
    const succeeded = tasks.Task{ .id = 1, .state = .succeeded, .result = .ok };
    try save(&job, queued, std.testing.allocator, std.testing.io, tmp.dir);
    var candidate = job;
    candidate.phase = .prepared;
    candidate.output_hash = @splat(3);
    candidate.output_size = 1;
    try std.testing.expectError(error.InvalidJobPhaseTransition, save(&candidate, running, std.testing.allocator, std.testing.io, tmp.dir));
    job.phase = .running;
    try save(&job, running, std.testing.allocator, std.testing.io, tmp.dir);
    candidate.phase = .queued;
    try std.testing.expectError(error.InvalidJobPhaseTransition, save(&candidate, queued, std.testing.allocator, std.testing.io, tmp.dir));
    candidate.phase = .succeeded;
    try std.testing.expectError(error.InvalidJobPhaseTransition, save(&candidate, succeeded, std.testing.allocator, std.testing.io, tmp.dir));
    candidate.phase = .prepared;
    try save(&candidate, running, std.testing.allocator, std.testing.io, tmp.dir);
    candidate.phase = .running;
    try std.testing.expectError(error.InvalidJobPhaseTransition, save(&candidate, running, std.testing.allocator, std.testing.io, tmp.dir));
    candidate.phase = .output_committed;
    try save(&candidate, running, std.testing.allocator, std.testing.io, tmp.dir);
    candidate.phase = .failed;
    try std.testing.expectError(error.InvalidJobPhaseTransition, save(&candidate, .{ .id = 1, .state = .failed, .result = .failed }, std.testing.allocator, std.testing.io, tmp.dir));
    candidate.phase = .succeeded;
    try save(&candidate, succeeded, std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(tasks.State.succeeded, (try load(1, std.testing.allocator, std.testing.io, tmp.dir)).?.task.state);
}
