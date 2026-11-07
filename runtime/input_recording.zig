const std = @import("std");
const vne = @import("vne");
const RuntimeContext = @import("context.zig").Context;
const input_replay = @import("input_replay.zig");
const input_actions = @import("input_actions.zig");

test "recording rejects equal content with a different node allocator baseline" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.document.observeNodeId(9);
    try std.testing.expectEqual(@import("documents.zig").Document.initDefault().fingerprint(), ctx.document.fingerprint());
    var recorder: Recorder = .{};
    defer recorder.deinit();
    try std.testing.expectError(error.InputRecordingRequiresFreshSession, recorder.start(&ctx, "session://input/blocked.cvr"));
    try std.testing.expect(!recorder.enabled);
}

pub const Recorder = struct {
    context: ?*RuntimeContext = null,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    target_path: []u8 = &.{},
    file: ?std.Io.File = null,
    pending: std.ArrayList(u8) = .empty,
    origin_time_ns: i64 = 0,
    baseline_fingerprint: u64 = 0,
    event_count: u64 = 0,
    relative_time_ns: i64 = 0,
    enabled: bool = false,

    pub fn start(self: *Recorder, ctx: *RuntimeContext, uri: []const u8) !void {
        if (self.enabled) return error.InputRecordingAlreadyActive;
        if (self.target_path.len > 0) self.deinit();
        switch (ctx.clock) {
            .manual => return error.LiveClockRequired,
            .system => {},
        }
        if (ctx.devices.input.last_serial != 0 or ctx.history.count != 0 or ctx.tasks.count != 0 or
            ctx.document.fingerprint() != @import("documents.zig").Document.initDefault().fingerprint() or
            ctx.document.nodeIdHighWater() != @import("documents.zig").Document.initDefault().nodeIdHighWater()) return error.InputRecordingRequiresFreshSession;
        const parsed = try vne.uri.parse(uri);
        const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, parsed);
        errdefer ctx.allocator.free(resolved.path);
        if (resolved.access != .read_write) return error.ReadOnlyResource;
        self.* = .{
            .context = ctx,
            .allocator = ctx.allocator,
            .io = ctx.io orelse return error.IoNotReady,
            .target_path = resolved.path,
            .baseline_fingerprint = ctx.document.fingerprint(),
            .enabled = true,
        };
    }

    pub fn consume(self: *Recorder, ctx: *RuntimeContext, event: vne.input.Event) !void {
        try ctx.devices.input.push(event);
        const consumed = ctx.devices.input.next().?;
        const outcome = input_actions.dispatch(ctx, &consumed);
        if (self.enabled) try self.capture(consumed, outcome);
    }

    fn capture(self: *Recorder, event: vne.input.Event, outcome: input_actions.Outcome) !void {
        if (self.file == null) {
            if (std.fs.path.dirname(self.target_path)) |parent| try std.Io.Dir.cwd().createDirPath(self.io, parent);
            const file = try std.Io.Dir.createFileAbsolute(self.io, self.target_path, .{});
            self.file = file;
            errdefer {
                file.close(self.io);
                self.file = null;
            }
            try file.writeStreamingAll(self.io, "cutrans_input_replay=3\nclock=logical\n");
            var header: [96]u8 = undefined;
            const baseline = try std.fmt.bufPrint(&header, "baseline={d}\n", .{self.baseline_fingerprint});
            try file.writeStreamingAll(self.io, baseline);
            self.origin_time_ns = event.time_ns;
        }
        var stored = event;
        stored.serial = self.event_count + 1;
        self.relative_time_ns = event.time_ns - self.origin_time_ns;
        try input_replay.appendEvent(&self.pending, self.allocator, &stored, self.relative_time_ns);
        try input_replay.appendAction(&self.pending, self.allocator, stored.serial, outcome);
        self.event_count += 1;
    }

    pub fn flush(self: *Recorder) !void {
        if (self.pending.items.len == 0) return;
        const file = self.file orelse return error.InputRecordingNotOpen;
        try file.writeStreamingAll(self.io, self.pending.items);
        self.pending.clearRetainingCapacity();
    }

    pub fn finish(self: *Recorder) !vne.abi.InputRecordReport {
        if (!self.enabled) return error.InputRecordingNotActive;
        const ctx = self.context orelse return error.InputRecordingNotActive;
        if (self.file != null) try input_replay.appendExpectation(&self.pending, self.allocator, ctx);
        try self.flush();
        if (self.file) |file| {
            try file.sync(self.io);
            file.close(self.io);
            self.file = null;
        }
        self.enabled = false;
        return .{
            .struct_size = @sizeOf(vne.abi.InputRecordReport),
            .abi_version = vne.abi.version,
            .event_count = self.event_count,
            .time_ns = self.relative_time_ns,
        };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.enabled) _ = self.finish() catch {};
        if (self.file) |file| file.close(self.io);
        if (self.target_path.len > 0) {
            self.allocator.free(self.target_path);
            self.pending.deinit(self.allocator);
        }
        self.* = .{};
    }
};

fn testContext(ctx: *RuntimeContext, resource: []const u8, data: []const u8) !void {
    try @import("replay.zig").fixture(ctx, std.testing.allocator, resource, data);
    ctx.clock = .{ .system = std.testing.io };
}

test "recording consumes live events and replays a fresh normalized log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var ctx: RuntimeContext = undefined;
    try testContext(&ctx, resource, data);
    defer ctx.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    try recorder.start(&ctx, "session://input/live.cvr");
    try recorder.consume(&ctx, .{ .serial = 1, .time_ns = 100, .kind = .pointer_move, .x = 12, .y = 24 });
    const sample = "你\n好,Cutrans";
    var text = vne.input.Event{ .serial = 2, .time_ns = 110, .kind = .text };
    @memcpy(text.text[0..sample.len], sample);
    text.text_len = sample.len;
    try recorder.consume(&ctx, text);
    try recorder.consume(&ctx, .{ .serial = 3, .time_ns = 120, .kind = .key_down, .action = .repeat, .code = 257, .mods = 3 });
    try recorder.flush();
    try std.testing.expectEqual(@as(usize, 0), ctx.devices.input.count);
    try std.testing.expectEqual(@as(u64, 3), ctx.devices.input.consumed_count);
    const report = try recorder.finish();
    try std.testing.expectEqual(@as(u64, 3), report.event_count);
    try std.testing.expectEqual(@as(i64, 20), report.time_ns);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ data, "input/live.cvr" });
    defer std.testing.allocator.free(log_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "cutrans_input_replay=3\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, root) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "event=1,0,pointer_move,0,0,0,0,12,24,") != null);
    var log = try input_replay.parse(std.testing.allocator, bytes);
    defer log.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), log.events.len);
    try std.testing.expectEqualStrings(sample, log.events[1].textValue());
    try std.testing.expectEqual(vne.input.Action.repeat, log.events[2].action);
    try std.testing.expect(log.expected != null);
    try std.testing.expectError(error.InputRecordingNotActive, recorder.finish());
}

test "action recording reconciles command results history and document identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var ctx: RuntimeContext = undefined;
    try testContext(&ctx, resource, data);
    defer ctx.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    try recorder.start(&ctx, "session://input/actions.cvr");
    const empty_undo = vne.input.Event{ .serial = 1, .time_ns = 100, .kind = .key_down, .action = .press, .code = 90, .mods = 2 };
    try recorder.consume(&ctx, empty_undo);
    const insert = vne.input.Event{ .serial = 2, .time_ns = 110, .kind = .key_down, .action = .press, .code = 73, .mods = 2 };
    try recorder.consume(&ctx, insert);
    const changed = ctx.document.fingerprint();
    const undo = vne.input.Event{ .serial = 3, .time_ns = 120, .kind = .key_down, .action = .press, .code = 90, .mods = 2 };
    try recorder.consume(&ctx, undo);
    const redo = vne.input.Event{ .serial = 4, .time_ns = 130, .kind = .key_down, .action = .repeat, .code = 89, .mods = 2 };
    try recorder.consume(&ctx, redo);
    var text_undo = vne.input.Event{ .serial = 5, .time_ns = 140, .kind = .key_down, .action = .press, .code = 90, .mods = 2, .context = vne.input.Context.text_input };
    try recorder.consume(&ctx, text_undo);
    text_undo.serial = 6;
    text_undo.time_ns = 150;
    text_undo.mods = 3;
    text_undo.context = 0;
    try recorder.consume(&ctx, text_undo);
    _ = try recorder.finish();
    try std.testing.expectEqual(changed, ctx.document.fingerprint());
    try std.testing.expectEqual(@as(usize, 1), ctx.history.cursor);
    const path = try std.fs.path.join(std.testing.allocator, &.{ data, "input/actions.cvr" });
    defer std.testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    var log = try input_replay.parse(std.testing.allocator, bytes);
    defer log.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), log.actions.len);
    try std.testing.expectEqual(@as(?@import("command.zig").Code, .invalid_state), log.actions[0].result);
    try std.testing.expect(log.actions[4].suppressed);
    var replayed: RuntimeContext = undefined;
    try testContext(&replayed, resource, data);
    defer replayed.deinit();
    const report = try input_replay.run(&replayed, &log);
    try std.testing.expectEqual(changed, report.document_fingerprint);
    try std.testing.expectEqual(@as(u64, 1), report.history_count);
    try std.testing.expectEqual(@as(u64, 1), report.history_cursor);
    log.actions[0].result = .ok;
    var rejected: RuntimeContext = undefined;
    try testContext(&rejected, resource, data);
    defer rejected.deinit();
    try std.testing.expectError(error.InputActionMismatch, input_replay.run(&rejected, &log));
}
