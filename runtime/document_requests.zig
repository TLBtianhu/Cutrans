//! Receipt retention is bounded; client high-water marks are never evicted.
//! Old requests with no retained receipt fail closed instead of executing again.
const std = @import("std");
const workspace = @import("vne").workspace;
const abi = @import("vne").abi;
const Context = @import("context.zig").Context;
const command = @import("command.zig");

const Receipts = @import("request_receipts.zig").Book(workspace.Outcome, workspace.receipt_capacity);

pub const Registry = struct {
    book: Receipts,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .book = Receipts.init(allocator, workspace.default_client_limit) };
    }

    pub fn deinit(self: *Registry) void {
        self.book.deinit();
    }

    pub fn stamp(ctx: *const Context, epoch: [2]u64) workspace.Stamp {
        return .{ .epoch_hi = epoch[0], .epoch_lo = epoch[1], .revision = ctx.document_revision };
    }

    fn rejected(ctx: *const Context, epoch: [2]u64, sequence: u64, status: i32) workspace.Outcome {
        return .{ .status = status, .disposition = @backingInt(workspace.Disposition.rejected), .sequence = sequence, .stamp = stamp(ctx, epoch) };
    }

    fn hashNumber(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        hash.update(&bytes);
    }

    fn fingerprint(request: *const workspace.Request, name: []const u8, arg: ?[]const u8) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashNumber(&hash, request.expected.epoch_hi);
        hashNumber(&hash, request.expected.epoch_lo);
        hashNumber(&hash, request.expected.revision);
        hashNumber(&hash, name.len);
        hash.update(name);
        hashNumber(&hash, @intFromBool(arg != null));
        if (arg) |text| {
            hashNumber(&hash, text.len);
            hash.update(text);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return digest;
    }

    /// Caller serializes all Runtime mutation and snapshot access. No allocation
    /// may occur in the receipt registry after the command starts executing.
    pub fn submit(self: *Registry, ctx: *Context, epoch: [2]u64, request: *const workspace.Request, name: []const u8, arg: ?[]const u8) !workspace.Outcome {
        if ((request.client_hi == 0 and request.client_lo == 0) or request.sequence == 0)
            return rejected(ctx, epoch, request.sequence, abi.Status.invalid_arguments);
        if (request.expected.epoch_hi != epoch[0] or request.expected.epoch_lo != epoch[1])
            return rejected(ctx, epoch, request.sequence, workspace.Status.wrong_epoch);
        const client = [2]u64{ request.client_hi, request.client_lo };
        const digest = fingerprint(request, name, arg);
        const high = switch (try self.book.prepare(client, request.sequence, digest)) {
            .replayed => |known| {
                var replayed = known;
                replayed.disposition = @backingInt(workspace.Disposition.replayed);
                return replayed;
            },
            .refused => |reason| return rejected(ctx, epoch, request.sequence, switch (reason) {
                .conflict => workspace.Status.request_conflict,
                .expired => workspace.Status.receipt_expired,
                .bad_sequence => workspace.Status.bad_sequence,
                .client_limit => workspace.Status.client_limit,
            }),
            .ready => |pointer| pointer,
        };
        const outcome = if (request.expected.revision != ctx.document_revision)
            rejected(ctx, epoch, request.sequence, workspace.Status.stale_version)
        else if (!workspace.manages(name))
            rejected(ctx, epoch, request.sequence, workspace.Status.unsupported_command)
        else blk: {
            const result = ctx.command.dispatch(.{ .name = name, .arg = arg });
            break :blk workspace.Outcome{
                .status = code(result.code),
                .disposition = @backingInt(workspace.Disposition.executed),
                .sequence = request.sequence,
                .stamp = stamp(ctx, epoch),
                .created_id = if (result.code == .ok and workspace.createsNode(name)) ctx.document.outputId() orelse 0 else 0,
                .task_id = result.task_id orelse 0,
            };
        };
        self.book.record(high, client, request.sequence, digest, outcome);
        return outcome;
    }
};

pub fn code(value: command.Code) i32 {
    return switch (value) {
        .ok => abi.Status.ok,
        .accepted => abi.Status.accepted,
        .unknown_command => abi.Status.unknown_command,
        .invalid_arguments => abi.Status.invalid_arguments,
        .permission_denied => abi.Status.permission_denied,
        .invalid_state => abi.Status.invalid_state,
        .not_ready => abi.Status.not_ready,
        .queue_full => abi.Status.queue_full,
        .failed => abi.Status.failed,
        .cancelled => abi.Status.cancelled,
    };
}

test "receipts precede stale checks and old sequences never execute twice" {
    const ctx = try std.testing.allocator.create(Context);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    @import("document_commands.zig").register(ctx);
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const epoch = [2]u64{ 1, 2 };
    var request = workspace.Request{ .client_hi = 3, .client_lo = 4, .sequence = 1, .expected = Registry.stamp(ctx, epoch), .name = .{} };
    const first = try registry.submit(ctx, epoch, &request, "editor.invert.add", "c1");
    try std.testing.expectEqual(abi.Status.ok, first.status);
    const replayed = try registry.submit(ctx, epoch, &request, "editor.invert.add", "c1");
    try std.testing.expectEqual(@as(u32, @backingInt(workspace.Disposition.replayed)), replayed.disposition);
    try std.testing.expectEqual(first.created_id, replayed.created_id);
    try std.testing.expectEqual(@as(usize, 3), ctx.document.count);
    const conflict = try registry.submit(ctx, epoch, &request, "editor.invert.add", "c0");
    try std.testing.expectEqual(workspace.Status.request_conflict, conflict.status);
    request.sequence = 2;
    try std.testing.expectEqual(workspace.Status.stale_version, (try registry.submit(ctx, epoch, &request, "history.undo", null)).status);
    for (3..workspace.receipt_capacity + 5) |sequence| {
        request.sequence = sequence;
        request.expected = Registry.stamp(ctx, epoch);
        _ = try registry.submit(ctx, epoch, &request, "editor.gain.set", "c1 0.5");
    }
    request.sequence = 1;
    try std.testing.expectEqual(workspace.Status.receipt_expired, (try registry.submit(ctx, epoch, &request, "editor.invert.add", "c1")).status);
    try std.testing.expectEqual(@as(usize, 3), ctx.document.count);
    request.expected.epoch_lo += 1;
    try std.testing.expectEqual(workspace.Status.wrong_epoch, (try registry.submit(ctx, epoch, &request, "history.undo", null)).status);
}

test "client admission fails before mutation and retained high waters are not evicted" {
    const ctx = try std.testing.allocator.create(Context);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    @import("document_commands.zig").register(ctx);
    const epoch = [2]u64{ 11, 12 };
    const original = Registry.stamp(ctx, epoch);
    var request = workspace.Request{ .client_hi = 1, .client_lo = 1, .sequence = 1, .expected = original, .name = .{} };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var unavailable = Registry.init(failing.allocator());
    defer unavailable.deinit();
    try std.testing.expectError(error.OutOfMemory, unavailable.submit(ctx, epoch, &request, "editor.invert.add", "c1"));
    try std.testing.expectEqual(@as(usize, 0), unavailable.book.clients.count());
    try std.testing.expectEqual(original.revision, ctx.document_revision);
    try std.testing.expectEqual(@as(usize, 2), ctx.document.count);

    var bounded = Registry.init(std.testing.allocator);
    defer bounded.deinit();
    bounded.book.client_limit = 1;
    const first = try bounded.submit(ctx, epoch, &request, "editor.invert.add", "c1");
    try std.testing.expectEqual(abi.Status.ok, first.status);
    request.client_lo = 2;
    request.expected = Registry.stamp(ctx, epoch);
    const refused = try bounded.submit(ctx, epoch, &request, "editor.invert.add", "c1");
    try std.testing.expectEqual(workspace.Status.client_limit, refused.status);
    try std.testing.expectEqual(@as(usize, 3), ctx.document.count);
    try std.testing.expectEqual(@as(usize, 1), bounded.book.clients.count());
    request.client_lo = 1;
    request.expected = original;
    const replayed = try bounded.submit(ctx, epoch, &request, "editor.invert.add", "c1");
    try std.testing.expectEqual(first.created_id, replayed.created_id);
    try std.testing.expectEqual(@as(u32, @backingInt(workspace.Disposition.replayed)), replayed.disposition);
}
