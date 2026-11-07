const std = @import("std");
const vne = @import("vne");
const RuntimeContext = @import("context.zig").Context;
const command = @import("command.zig");
const document_commands = @import("document_commands.zig");

pub const Report = vne.abi.ReplayReport;

fn expectedCode(code: command.Code) !vne.replay.ResultCode {
    return switch (code) {
        .ok => .ok,
        .accepted => .accepted,
        .unknown_command => .unknown_command,
        .invalid_arguments => .invalid_arguments,
        .permission_denied => .permission_denied,
        .invalid_state => .invalid_state,
        .not_ready => .not_ready,
        .queue_full => .queue_full,
        .failed => .failed,
        .cancelled => .cancelled,
    };
}

fn mix(hash: *u64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 1099511628211;
    }
}

fn taskHash(ctx: *const RuntimeContext) u64 {
    var hash: u64 = 14695981039346656037;
    for (ctx.tasks.items[0..ctx.tasks.count]) |task| {
        mix(&hash, task.id);
        mix(&hash, switch (task.state) {
            .queued => 1,
            .running => 2,
            .succeeded => 3,
            .failed => 4,
            .cancelled => 5,
            .interrupted => 6,
        });
        mix(&hash, if (task.progress_milli) |value| value + 1 else 0);
        mix(&hash, if (task.result) |result| @backingInt(result) + 1 else 0);
    }
    return hash;
}

pub fn run(ctx: *RuntimeContext, log: *const vne.replay.Log) !Report {
    if (ctx.history.count != 0 or ctx.tasks.count != 0) return error.ReplayRequiresFreshSession;
    if (ctx.document.nodeIdHighWater() != @import("documents.zig").Document.initDefault().nodeIdHighWater()) return error.ReplayRequiresFreshSession;
    ctx.clock = .{ .manual = .{} };
    for (log.events[0..log.count]) |*event| {
        try ctx.clock.advanceTo(event.time_ns);
        const result = ctx.command.dispatch(.{ .name = event.command(), .arg = if (event.arg_len == 0) null else event.argument() });
        if ((try expectedCode(result.code)) != event.expected_code) {
            std.debug.print("[replay] event={d} {s} expected={s} actual={s}\n", .{ event.serial, event.command(), @tagName(event.expected_code), result.codeText() });
            return error.ReplayResultMismatch;
        }
        try document_commands.pump(ctx);
    }
    return .{
        .struct_size = @sizeOf(Report),
        .abi_version = vne.abi.version,
        .kind = 0,
        .input_events = 0,
        .document_fingerprint = ctx.document.fingerprint(),
        .history_count = @intCast(ctx.history.count),
        .history_cursor = @intCast(ctx.history.cursor),
        .task_count = @intCast(ctx.tasks.count),
        .tasks_hash = taskHash(ctx),
        .time_ns = try ctx.clock.now(),
        .event_count = @intCast(log.count),
    };
}

pub fn runUri(ctx: *RuntimeContext, path: []const u8) !Report {
    const parsed = try vne.uri.parse(path);
    const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, parsed);
    defer ctx.allocator.free(resolved.path);
    const io = ctx.io orelse return error.IoNotReady;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, resolved.path, ctx.allocator, .limited(16 * 1024 * 1024));
    defer ctx.allocator.free(text);
    if (std.mem.indexOf(u8, text, "cutrans_input_replay=") != null) {
        var log = try @import("input_replay.zig").parse(ctx.allocator, text);
        defer log.deinit(ctx.allocator);
        return @import("input_replay.zig").run(ctx, &log);
    }
    const log = try vne.replay.parse(text);
    return run(ctx, &log);
}

pub fn fixture(ctx: *RuntimeContext, allocator: std.mem.Allocator, root: []const u8, data: []const u8) !void {
    ctx.init(allocator);
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(allocator, .development, root, data);
    try @import("mounts.zig").configure(ctx);
    document_commands.register(ctx);
}

test "replay produces identical document task and time state in isolated sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const examples = try std.fs.path.join(std.testing.allocator, &.{ resource, "assets/examples" });
    defer std.testing.allocator.free(examples);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, examples);
    const minimal = try std.fs.path.join(std.testing.allocator, &.{ examples, "minimal.cut" });
    defer std.testing.allocator.free(minimal);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = minimal, .data = @import("assets").minimal_cut });
    const replay_path = try std.fs.path.join(std.testing.allocator, &.{ examples, "replay.cvr" });
    defer std.testing.allocator.free(replay_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = replay_path, .data = @import("assets").replay_log });
    const first_data = try std.fs.path.join(std.testing.allocator, &.{ root, "first" });
    defer std.testing.allocator.free(first_data);
    const second_data = try std.fs.path.join(std.testing.allocator, &.{ root, "second" });
    defer std.testing.allocator.free(second_data);
    var first: RuntimeContext = undefined;
    try fixture(&first, std.testing.allocator, resource, first_data);
    defer first.deinit();
    var second: RuntimeContext = undefined;
    try fixture(&second, std.testing.allocator, resource, second_data);
    defer second.deinit();
    const a = try runUri(&first, "pack://assets/examples/replay.cvr");
    const b = try runUri(&second, "pack://assets/examples/replay.cvr");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(i64, 6000000), a.time_ns);
    try std.testing.expectEqual(@as(u64, 1), a.task_count);
}

test "replay rejects time travel and unexpected command results" {
    try std.testing.expectError(error.ReplayTimeTravel, vne.replay.parse("cutrans_replay=1\nclock=logical\nevent=1,20,ok,doc.open,\nevent=2,10,ok,doc.open,\n"));
    try std.testing.expectError(error.InvalidReplayResult, vne.replay.parse("cutrans_replay=1\nclock=logical\nevent=1,10,unexpected,doc.open,\n"));
}
