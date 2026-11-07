const std = @import("std");
const RuntimeContext = @import("context.zig").Context;
const stream_mod = @import("stream.zig");
const escapement = @import("escapement.zig");
const command = @import("command.zig");

pub const Playback = struct {
    stream: stream_mod.Stream = undefined,
    engine: escapement.Engine = undefined,
    initialized: bool = false,
    active: bool = false,
    deadline_ns: i64 = 0,
    frame_duration_ns: i64 = 0,
    ready_t: i64 = -1,
    ready_ns: i64 = 0,
    last_offered_t: i64 = -1,

    pub fn start(self: *Playback, ctx: *RuntimeContext, frames: i64) !void {
        if (self.active) return error.PlaybackAlreadyActive;
        if (frames < 1 or frames > 600) return error.InvalidFrameCount;
        if (ctx.document.fps == 0 or ctx.document.fps > std.time.ns_per_s) return error.InvalidPlaybackRate;
        self.stop(ctx.allocator);
        self.stream = stream_mod.Stream.initWithProvider(&ctx.document, frames, @import("render.zig").workspaceProvider(ctx));
        self.initialized = true;
        errdefer self.stop(ctx.allocator);
        self.engine = .{ .clock = .{}, .sink = &ctx.devices.frame_sink, .stream = &self.stream };
        self.frame_duration_ns = @intCast(@divFloor(std.time.ns_per_s, ctx.document.fps));
        self.ready_t = -1;
        self.active = true;
        try self.prepare(ctx);
        self.deadline_ns = try ctx.clock.now();
    }

    pub fn stop(self: *Playback, allocator: std.mem.Allocator) void {
        if (self.initialized) self.stream.deinit(allocator);
        self.* = .{};
    }

    fn prepare(self: *Playback, ctx: *RuntimeContext) !void {
        const t = self.engine.cursor;
        if (self.ready_t == t and self.stream.has(t)) return;
        var resource_dir: ?std.Io.Dir = null;
        if (ctx.io) |io| {
            if (ctx.paths.resource_dir.len > 0) resource_dir = try ctx.paths.openResourceDir(io);
        }
        defer if (resource_dir) |dir| dir.close(ctx.io.?);
        const previous_generation = if (self.stream.preview.frame) |frame| frame.generation else 0;
        _ = try self.stream.get(t, ctx.allocator, ctx.io, resource_dir);
        if (self.stream.preview.frame.?.generation != previous_generation) self.ready_ns = try ctx.clock.now();
        self.ready_t = t;
    }

    pub fn pump(self: *Playback, ctx: *RuntimeContext) !void {
        if (!self.active) return;
        while (self.active) {
            const now = try ctx.clock.now();
            if (now < self.deadline_ns) return;
            const t = self.engine.cursor;
            if (self.ready_t != t or self.ready_ns > self.deadline_ns or !self.stream.has(t)) {
                ctx.devices.frame_sink.underflow(t);
                self.engine.cursor += 1;
            } else {
                var resource_dir: ?std.Io.Dir = null;
                if (ctx.io) |io| {
                    if (ctx.paths.resource_dir.len > 0) resource_dir = try ctx.paths.openResourceDir(io);
                }
                defer if (resource_dir) |dir| dir.close(ctx.io.?);
                const step = try self.engine.step(ctx.allocator, ctx.io, resource_dir);
                if (step == .offered) self.last_offered_t = t;
            }
            if (self.engine.cursor >= self.stream.frames) {
                self.active = false;
                return;
            }
            self.deadline_ns = std.math.add(i64, self.deadline_ns, self.frame_duration_ns) catch return error.ClockOutOfRange;
            try self.prepare(ctx);
        }
    }

    pub fn report(self: *const Playback, ctx: *const RuntimeContext) @import("vne").abi.PlaybackReport {
        return .{
            .struct_size = @sizeOf(@import("vne").abi.PlaybackReport),
            .abi_version = @import("vne").abi.version,
            .active = @intFromBool(self.active),
            .cursor = if (self.initialized) self.engine.cursor else 0,
            .frames = if (self.initialized) self.stream.frames else 0,
            .offer_count = ctx.devices.frame_sink.offer_count,
            .underflow_count = ctx.devices.frame_sink.underflow_count,
            .present_count = ctx.devices.frame_sink.present_count,
            .last_t = if (self.initialized) self.last_offered_t else -1,
        };
    }
};

pub fn handle(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    if (std.mem.eql(u8, c.name, "playback.start")) {
        const frames = if (c.arg) |text| std.fmt.parseInt(i64, text, 10) catch return .failure(.invalid_arguments) else 4;
        ctx.playback.start(ctx, frames) catch |err| return switch (err) {
            error.PlaybackAlreadyActive => .failure(.invalid_state),
            error.InvalidFrameCount, error.InvalidPlaybackRate => .failure(.invalid_arguments),
            else => .failure(.failed),
        };
        ctx.status.set("静态帧序列播放中");
        return .accepted;
    }
    if (std.mem.eql(u8, c.name, "playback.stop")) {
        if (!ctx.playback.active) return .failure(.invalid_state);
        ctx.playback.stop(ctx.allocator);
        ctx.status.set("静态帧序列已停止");
        return .success;
    }
    if (std.mem.eql(u8, c.name, "playback.status")) {
        const value = ctx.playback.report(ctx);
        std.debug.print("CUTRANS_PLAYBACK active={d} cursor={d} frames={d} offers={d} underflow={d} last_t={d}\n", .{
            value.active,
            value.cursor,
            value.frames,
            value.offer_count,
            value.underflow_count,
            value.last_t,
        });
        return .success;
    }
    return .failure(.unknown_command);
}

fn testContext(ctx: *RuntimeContext, resource: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.testing.io, resource);
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    ctx.paths = try @import("paths.zig").Paths.fromDirs(std.testing.allocator, .development, resource, data);
    try @import("mounts.zig").configure(ctx);
    ctx.clock = .{ .manual = .{} };
}

test "playback pump respects deadlines and tracks frame coordinates" {
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
    try ctx.playback.start(&ctx, 2);
    try ctx.playback.pump(&ctx);
    try std.testing.expectEqual(@as(i64, 1), ctx.playback.engine.cursor);
    try std.testing.expectEqual(@as(i64, 0), ctx.devices.frame_sink.last_t);
    const materialized_ns = ctx.playback.ready_ns;
    try ctx.clock.advanceTo(42);
    ctx.playback.ready_t = -1;
    try ctx.playback.prepare(&ctx);
    try std.testing.expectEqual(materialized_ns, ctx.playback.ready_ns);
    const deadline = ctx.playback.deadline_ns;
    try ctx.clock.advanceTo(deadline - 1);
    try ctx.playback.pump(&ctx);
    try std.testing.expectEqual(@as(i64, 1), ctx.playback.engine.cursor);
    try ctx.clock.advanceTo(deadline);
    try ctx.playback.pump(&ctx);
    try std.testing.expect(!ctx.playback.active);
    try std.testing.expectEqual(@as(i64, 2), ctx.playback.engine.cursor);
    try std.testing.expectEqual(@as(i64, 1), ctx.devices.frame_sink.last_t);
    try std.testing.expectEqual(@as(u64, 2), ctx.devices.frame_sink.offer_count);
    try std.testing.expectEqual(@as(u64, 0), ctx.devices.frame_sink.underflow_count);
    try std.testing.expectEqual(@as(u64, 0), ctx.devices.frame_sink.present_count);
}

test "playback skips a frame that is not ready at its deadline" {
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
    try ctx.playback.start(&ctx, 1);
    ctx.playback.ready_t = -1;
    try ctx.playback.pump(&ctx);
    try std.testing.expect(!ctx.playback.active);
    try std.testing.expectEqual(@as(u64, 0), ctx.devices.frame_sink.offer_count);
    try std.testing.expectEqual(@as(u64, 1), ctx.devices.frame_sink.underflow_count);
    try std.testing.expectEqual(@as(i64, 0), ctx.devices.frame_sink.last_underflow_t);
}
