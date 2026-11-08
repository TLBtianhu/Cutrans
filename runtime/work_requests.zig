//! Managed working bodies. Drafts protect input; only commit advances the work head.
const std = @import("std");
const api = @import("vne").resource_api;
const abi = @import("vne").abi;
const Context = @import("context.zig").Context;
const library = @import("resource_library.zig");
const receipts = @import("request_receipts.zig");

pub fn stamp(ctx: *const Context, epoch: [2]u64) api.Stamp {
    return .{ .epoch_hi = epoch[0], .epoch_lo = epoch[1], .revision = ctx.library.revision };
}

pub const Snapshot = struct {
    metadata: api.WorkSnapshot,
    bytes: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn hash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn readSnapshot(ctx: *Context, epoch: [2]u64, id: u64) !Snapshot {
    const item = ctx.library.get(id) orelse return error.ResourceNotFound;
    if (item.kind != .owned or item.work_revision == 0) return error.ResourceNotReference;
    const has_draft = item.draft_revision != 0;
    const bytes = if (has_draft) try ctx.library.readDraft(ctx, id) else blk: {
        var loaded = try ctx.library.read(ctx, id);
        defer loaded.deinit(ctx.allocator);
        break :blk try ctx.allocator.dupe(u8, loaded.bytes);
    };
    errdefer ctx.allocator.free(bytes);
    const body_digest = hash(bytes);
    const expected = if (has_draft) item.draft_hash else item.content_hash;
    if (!std.mem.eql(u8, &body_digest, &expected)) return error.WorkContentMismatch;
    return .{
        .metadata = .{
            .stamp = stamp(ctx, epoch),
            .resource_id = id,
            .work_revision = item.work_revision,
            .base_revision = if (has_draft) item.draft_base_revision else item.work_revision,
            .draft_revision = item.draft_revision,
            .body_origin = @backingInt(if (has_draft) api.WorkBody.draft else api.WorkBody.published),
            .content_hash = item.content_hash,
            .body_hash = body_digest,
            .body_len = bytes.len,
        },
        .bytes = bytes,
    };
}

pub fn status(err: anyerror) i32 {
    return switch (err) {
        error.StaleWorkRevision => api.Status.stale_version,
        error.DraftConflict => api.Status.draft_conflict,
        error.ResourceNotReference => api.Status.wrong_kind,
        error.WorkReceiptLimit => api.Status.receipt_limit,
        error.ResourceNotFound, error.FileNotFound => abi.Status.not_found,
        error.WorkContentMismatch => api.Status.content_mismatch,
        error.ResourceLibraryFull, error.ResourceRevisionExhausted, error.WorkRevisionExhausted, error.DraftRevisionExhausted => abi.Status.queue_full,
        error.OutOfMemory => abi.Status.out_of_memory,
        error.IoNotReady => abi.Status.not_ready,
        error.InvalidResourceLabel, error.WorkBodyTooLarge => abi.Status.invalid_arguments,
        else => abi.Status.failed,
    };
}

fn number(hash_state: *std.crypto.hash.sha2.Sha256, value: u64) void {
    receipts.hashNumber(hash_state, value);
}

fn field(hash_state: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    number(hash_state, bytes.len);
    hash_state.update(bytes);
}

fn fingerprint(request: *const api.WorkRequest, label: []const u8, body: []const u8) [32]u8 {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    field(&state, "cutrans-work-request/1");
    for ([_]u64{ request.resource_id, request.base_revision, request.expected_draft_revision, request.mode }) |value| number(&state, value);
    field(&state, label);
    field(&state, body);
    return state.finalResult();
}

fn rejected(ctx: *Context, epoch: [2]u64, request: *const api.WorkRequest, code: i32) api.WorkOutcome {
    const item = ctx.library.get(request.resource_id);
    return .{
        .status = code,
        .disposition = @backingInt(api.Disposition.rejected),
        .sequence = request.sequence,
        .stamp = stamp(ctx, epoch),
        .resource_id = request.resource_id,
        .work_revision = if (item) |value| value.work_revision else 0,
        .draft_revision = if (item) |value| value.draft_revision else 0,
        .content_hash = if (item) |value| value.content_hash else @splat(0),
    };
}

fn replayed(ctx: *Context, epoch: [2]u64, sequence: u64, receipt: library.WorkReceipt) api.WorkOutcome {
    return .{
        .status = abi.Status.ok,
        .disposition = @backingInt(api.Disposition.replayed),
        .sequence = sequence,
        .stamp = stamp(ctx, epoch),
        .resource_id = receipt.resource_id,
        .work_revision = receipt.work_revision,
        .draft_revision = receipt.draft_revision,
        .content_hash = receipt.content_hash,
    };
}

fn persistentHigh(ctx: *const Context, client_hi: u64, client_lo: u64) u64 {
    var high: u64 = 0;
    for (ctx.library.work_receipts[0..ctx.library.work_receipt_count]) |receipt| {
        if (receipt.client_hi == client_hi and receipt.client_lo == client_lo) high = @max(high, receipt.sequence);
    }
    return high;
}

const Book = receipts.Book(api.WorkOutcome, api.receipt_capacity);

pub const Registry = struct {
    book: Book,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .book = Book.init(allocator, api.default_client_limit) };
    }

    pub fn deinit(self: *Registry) void {
        self.book.deinit();
    }

    pub fn submit(self: *Registry, ctx: *Context, epoch: [2]u64, request: *const api.WorkRequest, label: []const u8, body: []const u8) !api.WorkOutcome {
        if (!api.validWorkRequest(request)) return rejected(ctx, epoch, request, abi.Status.invalid_arguments);
        const digest = fingerprint(request, label, body);
        for (ctx.library.work_receipts[0..ctx.library.work_receipt_count]) |receipt| {
            if (receipt.client_hi != request.client_hi or receipt.client_lo != request.client_lo or receipt.sequence != request.sequence) continue;
            if (!std.mem.eql(u8, &receipt.request_hash, &digest)) return rejected(ctx, epoch, request, api.Status.request_conflict);
            var known = replayed(ctx, epoch, request.sequence, receipt);
            known.stamp = stamp(ctx, epoch);
            return known;
        }
        const client = [2]u64{ request.client_hi, request.client_lo };
        if (self.book.clients.get(client) == null) {
            if (self.book.clients.count() >= self.book.client_limit) return rejected(ctx, epoch, request, api.Status.client_limit);
            const entry = try self.book.clients.getOrPut(client);
            if (!entry.found_existing) entry.value_ptr.* = persistentHigh(ctx, request.client_hi, request.client_lo);
        }
        const high = switch (try self.book.prepare(client, request.sequence, digest)) {
            .replayed => |known| {
                var result = known;
                result.disposition = @backingInt(api.Disposition.replayed);
                return result;
            },
            .refused => |reason| return rejected(ctx, epoch, request, switch (reason) {
                .conflict => api.Status.request_conflict,
                .expired => api.Status.receipt_expired,
                .bad_sequence => api.Status.bad_sequence,
                .client_limit => api.Status.client_limit,
            }),
            .ready => |pointer| pointer,
        };
        const mode = std.enums.fromInt(api.WorkMode, request.mode).?;
        const envelope = library.WorkReceipt{
            .client_hi = request.client_hi,
            .client_lo = request.client_lo,
            .sequence = request.sequence,
            .mode = mode,
            .request_hash = digest,
            .resource_id = 0,
            .work_revision = 0,
            .draft_revision = 0,
            .content_hash = @splat(0),
        };
        const outcome = switch (mode) {
            .create => ctx.library.createWork(ctx, label, body, envelope),
            .save_draft => ctx.library.saveWorkDraft(ctx, request.resource_id, request.base_revision, request.expected_draft_revision, body, envelope),
            .commit => ctx.library.commitWorkDraft(ctx, request.resource_id, request.expected_draft_revision, envelope),
            .discard => ctx.library.discardWorkDraft(ctx, request.resource_id, request.expected_draft_revision, envelope),
        } catch |err| {
            const known = rejected(ctx, epoch, request, status(err));
            self.book.record(high, client, request.sequence, digest, known);
            return known;
        };
        const known = api.WorkOutcome{
            .status = abi.Status.ok,
            .disposition = @backingInt(api.Disposition.executed),
            .sequence = request.sequence,
            .stamp = stamp(ctx, epoch),
            .resource_id = outcome.resource_id,
            .work_revision = outcome.work_revision,
            .draft_revision = outcome.draft_revision,
            .content_hash = outcome.content_hash,
        };
        self.book.record(high, client, request.sequence, digest, known);
        return known;
    }
};

fn fixture(ctx: *Context, root: []const u8) !void {
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    ctx.paths = try @import("paths.zig").Paths.fromDirsPhysical(std.testing.allocator, std.testing.io, .portable, resource, data);
}

fn workRequest(sequence: u64, mode: api.WorkMode, id: u64, base: u64, draft: u64, label: []const u8, body: []const u8) api.WorkRequest {
    return .{
        .client_hi = 11,
        .client_lo = 22,
        .sequence = sequence,
        .resource_id = id,
        .base_revision = base,
        .expected_draft_revision = draft,
        .mode = @backingInt(mode),
        .label = .{ .ptr = if (label.len == 0) null else label.ptr, .len = label.len },
        .body = .{ .ptr = if (body.len == 0) null else body.ptr, .len = body.len },
    };
}

fn submit(registry: *Registry, ctx: *Context, value: *const api.WorkRequest) !api.WorkOutcome {
    const label = if (value.label.len == 0) "" else value.label.ptr.?[0..value.label.len];
    const body = if (value.body.len == 0) "" else value.body.ptr.?[0..value.body.len];
    return registry.submit(ctx, .{ 1, 2 }, value, label, body);
}

test "draft commit advances the work head while fixed versions and persistent receipts survive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var ctx: Context = undefined;
    try fixture(&ctx, root);
    defer ctx.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const create = workRequest(1, .create, 0, 0, 0, "note.txt", "old body");
    const created = try submit(&registry, &ctx, &create);
    try std.testing.expectEqual(abi.Status.ok, created.status);
    const id = created.resource_id;
    var old = try ctx.library.read(&ctx, id);
    defer old.deinit(ctx.allocator);
    const old_hash = old.source.content_hash;
    try ctx.library.retainVersion(&ctx, id, old_hash, old.bytes);
    const draft = workRequest(2, .save_draft, id, 1, 0, "", "new body");
    const saved = try submit(&registry, &ctx, &draft);
    try std.testing.expectEqual(@as(u64, 1), saved.work_revision);
    try std.testing.expectEqual(@as(u64, 1), saved.draft_revision);
    var during = try readSnapshot(&ctx, .{ 1, 2 }, id);
    defer during.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new body", during.bytes);
    var published = try ctx.library.read(&ctx, id);
    defer published.deinit(ctx.allocator);
    try std.testing.expectEqualStrings("old body", published.bytes);
    const commit = workRequest(3, .commit, id, 0, saved.draft_revision, "", "");
    const committed = try submit(&registry, &ctx, &commit);
    try std.testing.expectEqual(@as(u64, 2), committed.work_revision);
    try std.testing.expectEqual(@as(u64, 0), committed.draft_revision);
    var fixed = try ctx.library.readVersion(&ctx, id, old_hash);
    defer fixed.deinit(ctx.allocator);
    try std.testing.expectEqualStrings("old body", fixed.bytes);
    var current = try ctx.library.read(&ctx, id);
    defer current.deinit(ctx.allocator);
    try std.testing.expectEqualStrings("new body", current.bytes);
    var restored: Context = undefined;
    try fixture(&restored, root);
    defer restored.deinit();
    try restored.library.restore(&restored);
    var reopened = try readSnapshot(&restored, .{ 1, 2 }, id);
    defer reopened.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new body", reopened.bytes);
    try std.testing.expectEqual(@as(u64, 2), reopened.metadata.work_revision);
    var second_registry = Registry.init(std.testing.allocator);
    defer second_registry.deinit();
    const replay = try submit(&second_registry, &restored, &commit);
    try std.testing.expectEqual(@as(u32, @backingInt(api.Disposition.replayed)), replay.disposition);
    try std.testing.expectEqual(committed.work_revision, replay.work_revision);
    const create_replay = try submit(&second_registry, &restored, &create);
    try std.testing.expectEqual(id, create_replay.resource_id);
    try std.testing.expectEqual(@as(usize, 1), restored.library.count);
}

test "cold draft recovery rejects stale commit without losing protected input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var ctx: Context = undefined;
    try fixture(&ctx, root);
    defer ctx.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try submit(&registry, &ctx, &workRequest(1, .create, 0, 0, 0, "draft.txt", "base"));
    const draft = workRequest(2, .save_draft, 1, 1, 0, "", "protected");
    const saved = try submit(&registry, &ctx, &draft);
    var restored: Context = undefined;
    try fixture(&restored, root);
    defer restored.deinit();
    try restored.library.restore(&restored);
    var snapshot = try readSnapshot(&restored, .{ 1, 2 }, 1);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("protected", snapshot.bytes);
    try std.testing.expectEqual(@as(u32, @backingInt(api.WorkBody.draft)), snapshot.metadata.body_origin);
    var second = Registry.init(std.testing.allocator);
    defer second.deinit();
    const stale = workRequest(3, .save_draft, 1, 2, 0, "", "wrong base");
    try std.testing.expectEqual(api.Status.stale_version, (try submit(&second, &restored, &stale)).status);
    const commit = workRequest(4, .commit, 1, 0, saved.draft_revision, "", "");
    try std.testing.expectEqual(abi.Status.ok, (try submit(&second, &restored, &commit)).status);
    const discard = workRequest(5, .discard, 1, 0, saved.draft_revision, "", "");
    try std.testing.expectEqual(api.Status.draft_conflict, (try submit(&second, &restored, &discard)).status);
}

test "failed commit retains its draft and discard never reuses a token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var ctx: Context = undefined;
    try fixture(&ctx, root);
    defer ctx.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try submit(&registry, &ctx, &workRequest(1, .create, 0, 0, 0, "token.txt", "base"));
    _ = try submit(&registry, &ctx, &workRequest(2, .save_draft, 1, 1, 0, "", "one"));
    const commit = workRequest(3, .commit, 1, 0, 1, "", "");
    ctx.io = null;
    try std.testing.expectEqual(abi.Status.not_ready, (try submit(&registry, &ctx, &commit)).status);
    try std.testing.expectEqual(@as(u64, 1), ctx.library.get(1).?.draft_revision);
    ctx.io = std.testing.io;
    const retry = workRequest(4, .commit, 1, 0, 1, "", "");
    try std.testing.expectEqual(abi.Status.ok, (try submit(&registry, &ctx, &retry)).status);
    _ = try submit(&registry, &ctx, &workRequest(5, .save_draft, 1, 2, 0, "", "two"));
    _ = try submit(&registry, &ctx, &workRequest(6, .discard, 1, 0, 2, "", ""));
    const next = try submit(&registry, &ctx, &workRequest(7, .save_draft, 1, 2, 0, "", "three"));
    try std.testing.expectEqual(@as(u64, 3), next.draft_revision);
    ctx.library.work_receipt_count = ctx.library.work_receipts.len;
    const full = try submit(&registry, &ctx, &workRequest(8, .discard, 1, 0, 3, "", ""));
    try std.testing.expectEqual(api.Status.receipt_limit, full.status);
    try std.testing.expectEqual(@as(u64, 3), ctx.library.get(1).?.draft_revision);
}
