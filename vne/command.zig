//! command.zig — 可实例化的命令注册表与帧边界提交队列
//!
//! 每个 Registry 有自己的 handler 表、队列和回调上下文;启动/外部同步调用
//! 直接执行,UI 绘制阶段只入队,下一帧投影前统一提交。accepted 仅表示入队,
//! 不表示命令已经执行成功。

const std = @import("std");
const workspace = @import("workspace.zig");

pub const Code = enum {
    ok,
    accepted,
    unknown_command,
    invalid_arguments,
    permission_denied,
    invalid_state,
    not_ready,
    queue_full,
    failed,
    cancelled,
};

pub const Result = struct {
    code: Code,
    task_id: ?u64 = null,
    workspace_outcome: ?workspace.Outcome = null,

    pub const success = Result{ .code = .ok };
    pub const accepted = Result{ .code = .accepted };

    pub fn failure(code: Code) Result {
        return .{ .code = code };
    }

    pub fn codeText(self: Result) [:0]const u8 {
        return switch (self.code) {
            .ok => "ok",
            .accepted => "accepted",
            .unknown_command => "unknown_command",
            .invalid_arguments => "invalid_arguments",
            .permission_denied => "permission_denied",
            .invalid_state => "invalid_state",
            .not_ready => "not_ready",
            .queue_full => "queue_full",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
};

pub const Command = struct {
    name: []const u8,
    arg: ?[]const u8 = null,
    payload: ?*anyopaque = null,
    expected: ?workspace.Stamp = null,
};

pub const Handler = *const fn (Command, *anyopaque) Result;
pub const UnknownHandler = *const fn ([]const u8, *anyopaque) void;

const Queued = struct {
    name: [64]u8,
    arg: [128]u8,
    name_len: usize,
    arg_len: usize,
    has_arg: bool,
    expected: ?workspace.Stamp,
};

pub const Registry = struct {
    table: std.StringHashMap(Handler),
    queue: [32]Queued,
    queue_count: usize,
    defer_requests: bool,
    ctx: *anyopaque,
    on_unknown: ?UnknownHandler,
    /// GUI view stamp captured when an intent enters the frame queue. Runtime
    /// registries leave this null; handlers decide whether a command needs it.
    default_expected: ?workspace.Stamp,

    pub fn init(self: *Registry, allocator: std.mem.Allocator, ctx: *anyopaque) void {
        self.* = .{
            .table = std.StringHashMap(Handler).init(allocator),
            .queue = undefined,
            .queue_count = 0,
            .defer_requests = false,
            .ctx = ctx,
            .on_unknown = null,
            .default_expected = null,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.table.deinit();
        self.queue_count = 0;
        self.defer_requests = false;
    }

    pub fn register(self: *Registry, name: []const u8, handler: Handler) void {
        self.table.put(name, handler) catch @panic("command register: oom");
    }

    fn direct(self: *Registry, c: Command) Result {
        if (self.table.get(c.name)) |h| return h(c, self.ctx);
        std.debug.print("[command] 未知命令: {s}\n", .{c.name});
        if (self.on_unknown) |h| h(c.name, self.ctx);
        return .failure(.unknown_command);
    }

    fn enqueue(self: *Registry, c: Command) Result {
        if (self.queue_count == self.queue.len) return .failure(.queue_full);
        if (c.payload != null or c.name.len > 64) return .failure(.invalid_arguments);
        const arg_len = if (c.arg) |arg| arg.len else 0;
        if (arg_len > 128) return .failure(.invalid_arguments);
        var item = Queued{
            .name = undefined,
            .arg = undefined,
            .name_len = c.name.len,
            .arg_len = arg_len,
            .has_arg = c.arg != null,
            .expected = c.expected,
        };
        @memcpy(item.name[0..c.name.len], c.name);
        if (c.arg) |arg| @memcpy(item.arg[0..arg_len], arg);
        self.queue[self.queue_count] = item;
        self.queue_count += 1;
        return .accepted;
    }

    pub fn dispatch(self: *Registry, c: Command) Result {
        var prepared = c;
        if (prepared.expected == null) prepared.expected = self.default_expected;
        if (self.defer_requests) return self.enqueue(prepared);
        return self.direct(prepared);
    }

    pub fn beginFrame(self: *Registry) void {
        self.defer_requests = true;
    }

    pub fn endFrame(self: *Registry) void {
        self.defer_requests = false;
    }

    pub fn flush(self: *Registry) Result {
        self.defer_requests = false;
        const count = self.queue_count;
        self.queue_count = 0;
        var result = Result.success;
        for (self.queue[0..count]) |item| {
            const name = item.name[0..item.name_len];
            const arg = if (item.has_arg) item.arg[0..item.arg_len] else null;
            const next = self.direct(.{ .name = name, .arg = arg, .expected = item.expected });
            if (result.code == .ok and next.code != .ok) result = next;
        }
        return result;
    }
};

var test_arg_value: u8 = 0;

fn testHandler(c: Command, _: *anyopaque) Result {
    test_arg_value = (c.arg orelse return .failure(.invalid_arguments))[0];
    if (test_arg_value == 0) return .failure(.failed);
    return .success;
}

test "two command registries do not share handlers or queued commands" {
    var first_token: u8 = 0;
    var second_token: u8 = 0;
    var first: Registry = undefined;
    var second: Registry = undefined;
    first.init(std.testing.allocator, &first_token);
    second.init(std.testing.allocator, &second_token);
    defer first.deinit();
    defer second.deinit();
    first.register("test", testHandler);
    first.beginFrame();
    try std.testing.expectEqual(Code.accepted, first.dispatch(.{ .name = "test", .arg = "a" }).code);
    try std.testing.expectEqual(Code.unknown_command, second.dispatch(.{ .name = "test", .arg = "a" }).code);
    try std.testing.expectEqual(@as(usize, 1), first.queue_count);
    try std.testing.expectEqual(@as(usize, 0), second.queue_count);
}

test "frame queue copies arguments and defers execution" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(std.testing.allocator, &token);
    defer registry.deinit();
    registry.register("test", testHandler);
    registry.beginFrame();
    var arg = [_]u8{'a'};
    try std.testing.expectEqual(Code.accepted, registry.dispatch(.{ .name = "test", .arg = &arg }).code);
    try std.testing.expectEqual(@as(u8, 0), test_arg_value);
    arg[0] = 'z';
    registry.endFrame();
    try std.testing.expectEqual(Code.ok, registry.flush().code);
    try std.testing.expectEqual(@as(u8, 'a'), test_arg_value);
}

test "queue rejection distinguishes full queues and invalid payloads" {
    var token: u8 = 0;
    var registry: Registry = undefined;
    registry.init(std.testing.allocator, &token);
    defer registry.deinit();
    registry.beginFrame();
    var payload: u8 = 0;
    try std.testing.expectEqual(Code.invalid_arguments, registry.dispatch(.{ .name = "test", .payload = &payload }).code);
    for (0..registry.queue.len) |_| {
        try std.testing.expectEqual(Code.accepted, registry.dispatch(.{ .name = "test" }).code);
    }
    try std.testing.expectEqual(Code.queue_full, registry.dispatch(.{ .name = "test" }).code);
}

test "frame queue freezes the viewed document stamp before later refreshes" {
    const Probe = struct {
        expected: ?workspace.Stamp = null,
        fn handle(c: Command, pointer: *anyopaque) Result {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.expected = c.expected;
            return .success;
        }
    };
    var probe: Probe = .{};
    var registry: Registry = undefined;
    registry.init(std.testing.allocator, &probe);
    defer registry.deinit();
    registry.register("edit", Probe.handle);
    const viewed = workspace.Stamp{ .epoch_hi = 7, .epoch_lo = 8, .revision = 1 };
    registry.default_expected = viewed;
    registry.beginFrame();
    try std.testing.expectEqual(Code.accepted, registry.dispatch(.{ .name = "edit" }).code);
    registry.default_expected = .{ .epoch_hi = 7, .epoch_lo = 8, .revision = 2 };
    try std.testing.expectEqual(Code.ok, registry.flush().code);
    try std.testing.expect(probe.expected.?.eql(viewed));
}
