//! Resource operations own their CAS domain. A probe is just an observation;
//! submission reopens its path, checks the proof, then publishes dependencies
//! before the catalog head. Receipts precede every current-state/file check.
const std = @import("std");
const api = @import("vne").resource_api;
const abi = @import("vne").abi;
const Context = @import("context.zig").Context;
const external = @import("external_sources.zig");
const library = @import("resource_library.zig");
const receipts = @import("request_receipts.zig");
const Receipts = receipts.Book(api.Outcome, api.receipt_capacity);

pub fn stamp(ctx: *const Context, epoch: [2]u64) api.Stamp {
    return .{ .epoch_hi = epoch[0], .epoch_lo = epoch[1], .revision = ctx.library.revision };
}

pub fn status(err: anyerror) i32 {
    return switch (err) {
        error.StaleResourceVersion => api.Status.stale_version,
        error.WrongResourceEpoch => api.Status.wrong_epoch,
        error.ResourceCandidateChanged => api.Status.candidate_changed,
        error.ResourceNotReference, error.InvalidResourceState => api.Status.wrong_kind,
        error.ResourceContentMismatch, error.ResourceContentChanged, error.SourceContentMismatch => api.Status.content_mismatch,
        error.ResourceNotFound, error.FileNotFound => abi.Status.not_found,
        error.ResourceLibraryFull, error.ExternalGrantTableFull => abi.Status.queue_full,
        error.OutOfMemory => abi.Status.out_of_memory,
        error.IoNotReady => abi.Status.not_ready,
        error.ManagedSourceForbidden, error.LinkedSourceUnsupported, error.ReadOnlySourceRequired => abi.Status.permission_denied,
        error.InvalidExternalPath, error.InvalidArguments, error.TruncatedImage, error.UnsupportedImageFormat, error.InvalidPngHeader, error.InvalidImageSize, error.ExportDecodedBudgetExceeded, error.ExportEncodedBudgetExceeded, error.StreamTooLong, error.ImageDecodeFailed => abi.Status.invalid_arguments,
        else => abi.Status.failed,
    };
}

fn checkStamp(ctx: *const Context, epoch: [2]u64, expected: api.Stamp) !void {
    if (expected.epoch_hi != epoch[0] or expected.epoch_lo != epoch[1]) return error.WrongResourceEpoch;
    if (expected.revision != ctx.library.revision) return error.StaleResourceVersion;
}

fn pathHash(path: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    // Match the Windows ASCII-insensitive canonical-path policy used by grants.
    // Identity is checked independently; this hash is never file authorization.
    if (@import("builtin").os.tag == .windows) {
        for (path) |byte| hash.update(&.{std.ascii.toLower(byte)});
    } else hash.update(path);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn observed(ctx: *const Context, epoch: [2]u64, id: u64, mode: u32, frozen: *const external.Frozen) !api.Proof {
    const registering = mode == @backingInt(api.Mode.register_file);
    if (registering and id != 0) return error.InvalidArguments;
    const item = if (registering) null else ctx.library.get(id) orelse return error.ResourceNotFound;
    if (item) |value| if (value.kind != .reference) return error.ResourceNotReference;
    return .{
        .stamp = stamp(ctx, epoch),
        .target_id = id,
        .mode = mode,
        .head_hash = if (item) |value| value.content_hash else @splat(0),
        .content_hash = frozen.digest,
        .path_hash = pathHash(frozen.path),
        .byte_length = frozen.bytes.len,
        .volume_serial = frozen.identity.volume_serial,
        .file_index = frozen.identity.file_index,
    };
}

pub fn probe(ctx: *Context, epoch: [2]u64, request: *const api.ProbeRequest, path: []const u8) !api.Proof {
    try checkStamp(ctx, epoch, request.expected);
    const mode = std.enums.fromInt(api.Mode, request.mode) orelse return error.InvalidArguments;
    if (!api.validPath(path) or !std.fs.path.isAbsolute(path)) return error.InvalidExternalPath;
    if (mode == .register_file) {
        if (request.target_id != 0) return error.InvalidArguments;
        var frozen = try external.readFileSnapshot(ctx, path);
        defer frozen.deinit(ctx.allocator);
        return observed(ctx, epoch, 0, request.mode, &frozen);
    }
    const item = ctx.library.get(request.target_id) orelse return error.ResourceNotFound;
    if (item.kind != .reference) return error.ResourceNotReference;
    var frozen = try external.readFrozen(ctx, path);
    defer frozen.deinit(ctx.allocator);
    try library.validateCandidate(ctx.allocator, frozen.bytes);
    if (mode == .relocate and !std.mem.eql(u8, &item.content_hash, &frozen.digest)) return error.ResourceContentMismatch;
    return observed(ctx, epoch, request.target_id, request.mode, &frozen);
}

fn proofEqual(a: api.Proof, b: api.Proof) bool {
    return a.stamp.eql(b.stamp) and a.target_id == b.target_id and a.mode == b.mode and
        std.mem.eql(u8, &a.head_hash, &b.head_hash) and std.mem.eql(u8, &a.content_hash, &b.content_hash) and
        std.mem.eql(u8, &a.path_hash, &b.path_hash) and a.byte_length == b.byte_length and
        a.volume_serial == b.volume_serial and a.file_index == b.file_index;
}

fn fingerprint(request: *const api.Request, path: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const proof = request.proof;
    for ([_]u64{ proof.stamp.epoch_hi, proof.stamp.epoch_lo, proof.stamp.revision, proof.target_id, @as(u64, proof.mode), proof.byte_length, proof.volume_serial, proof.file_index }) |value|
        receipts.hashNumber(&hash, value);
    hash.update(&proof.head_hash);
    hash.update(&proof.content_hash);
    hash.update(&proof.path_hash);
    receipts.hashNumber(&hash, path.len);
    hash.update(path);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn apply(ctx: *Context, epoch: [2]u64, request: *const api.Request, path: []const u8) !u64 {
    const proof = request.proof;
    try checkStamp(ctx, epoch, proof.stamp);
    if (proof.mode == @backingInt(api.Mode.register_file)) {
        var frozen = external.readFileSnapshot(ctx, path) catch |err| return switch (err) {
            error.FileNotFound, error.InvalidSourceFile, error.SourceChangedDuringRead => error.ResourceCandidateChanged,
            else => err,
        };
        defer frozen.deinit(ctx.allocator);
        const current = try observed(ctx, epoch, 0, proof.mode, &frozen);
        if (!proofEqual(proof, current)) return error.ResourceCandidateChanged;
        return ctx.library.registerFrozenFile(ctx, &frozen);
    }
    const item = ctx.library.get(proof.target_id) orelse return error.ResourceNotFound;
    if (item.kind != .reference) return error.ResourceNotReference;
    if (!std.mem.eql(u8, &item.content_hash, &proof.head_hash)) return error.ResourceCandidateChanged;
    if (ctx.library.revision == std.math.maxInt(u64)) return error.ResourceRevisionExhausted;
    if (ctx.assets.revision == std.math.maxInt(u64)) return error.AssetRevisionExhausted;
    var frozen = external.readFrozen(ctx, path) catch |err| return switch (err) {
        error.FileNotFound, error.InvalidSourceFile, error.SourceChangedDuringRead => error.ResourceCandidateChanged,
        else => err,
    };
    defer frozen.deinit(ctx.allocator);
    const current = try observed(ctx, epoch, proof.target_id, proof.mode, &frozen);
    if (!proofEqual(proof, current)) return error.ResourceCandidateChanged;
    try ctx.library.rebind(ctx, proof.target_id, std.enums.fromInt(api.Mode, proof.mode).?, &frozen);
    return proof.target_id;
}

pub const Registry = struct {
    book: Receipts,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .book = Receipts.init(allocator, api.default_client_limit) };
    }
    pub fn deinit(self: *Registry) void {
        self.book.deinit();
    }
    fn rejected(ctx: *const Context, epoch: [2]u64, sequence: u64, code: i32) api.Outcome {
        return .{ .status = code, .disposition = @backingInt(api.Disposition.rejected), .sequence = sequence, .stamp = stamp(ctx, epoch) };
    }

    pub fn submit(self: *Registry, ctx: *Context, epoch: [2]u64, request: *const api.Request, path: []const u8) !api.Outcome {
        if ((request.client_hi == 0 and request.client_lo == 0) or request.sequence == 0 or !api.validProof(&request.proof) or
            !api.validPath(path) or !std.fs.path.isAbsolute(path)) return rejected(ctx, epoch, request.sequence, abi.Status.invalid_arguments);
        if (request.proof.stamp.epoch_hi != epoch[0] or request.proof.stamp.epoch_lo != epoch[1])
            return rejected(ctx, epoch, request.sequence, api.Status.wrong_epoch);
        const client = [2]u64{ request.client_hi, request.client_lo };
        const digest = fingerprint(request, path);
        const high = switch (try self.book.prepare(client, request.sequence, digest)) {
            .replayed => |known| {
                var replayed = known;
                replayed.disposition = @backingInt(api.Disposition.replayed);
                return replayed;
            },
            .refused => |reason| return rejected(ctx, epoch, request.sequence, switch (reason) {
                .conflict => api.Status.request_conflict,
                .expired => api.Status.receipt_expired,
                .bad_sequence => api.Status.bad_sequence,
                .client_limit => api.Status.client_limit,
            }),
            .ready => |pointer| pointer,
        };
        var resource_id: u64 = 0;
        const code = if (apply(ctx, epoch, request, path)) |id| known: {
            resource_id = id;
            break :known abi.Status.ok;
        } else |err| status(err);
        const outcome = api.Outcome{
            .status = code,
            .disposition = @backingInt(api.Disposition.executed),
            .sequence = request.sequence,
            .stamp = stamp(ctx, epoch),
            .resource_id = resource_id,
        };
        self.book.record(high, client, request.sequence, digest, outcome);
        return outcome;
    }
};

/// Caller holds the owner lock while serializing these business declarations.
/// Observation hashes, physical paths, Station and document state are absent.
pub fn snapshotText(ctx: *Context) ![]u8 {
    const Folder = struct { id: u64, parent_id: u64, label: []const u8 };
    const Resource = struct { id: u64, parent_id: u64, label: []const u8, kind: []const u8, provenance: []const u8, source: []const u8, sha256: []const u8 };
    var folders: [32]Folder = undefined;
    var resources: [32]Resource = undefined;
    var hashes: [32][64]u8 = undefined;
    for (ctx.library.folders[0..ctx.library.folder_count], 0..) |item, i|
        folders[i] = .{ .id = item.id, .parent_id = item.parent_id, .label = item.label };
    for (ctx.library.items[0..ctx.library.count], 0..) |item, i| {
        hashes[i] = std.fmt.bytesToHex(item.content_hash, .lower);
        resources[i] = .{ .id = item.id, .parent_id = item.parent_id, .label = item.label, .kind = @tagName(item.kind), .provenance = @tagName(item.provenance), .source = item.source_uri, .sha256 = &hashes[i] };
    }
    return std.json.Stringify.valueAlloc(ctx.allocator, .{ .format = "cutrans-resource-snapshot/1", .next_id = ctx.library.next_id, .folders = folders[0..ctx.library.folder_count], .resources = resources[0..ctx.library.count] }, .{});
}

test "resource refusals are receipted while obsolete epochs do not consume sequences" {
    const ctx = try std.testing.allocator.create(Context);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const epoch = [2]u64{ 1, 2 };
    var request = api.Request{ .client_hi = 3, .client_lo = 4, .sequence = 1, .proof = .{ .stamp = stamp(ctx, epoch), .target_id = 1, .mode = 2, .head_hash = @splat(0), .content_hash = @splat(0), .path_hash = @splat(0), .byte_length = 0, .volume_serial = 0, .file_index = 0 }, .path = .{} };
    const path = if (@import("builtin").os.tag == .windows) "C:/missing.png" else "/missing.png";
    const first = try registry.submit(ctx, epoch, &request, path);
    try std.testing.expectEqual(abi.Status.not_found, first.status);
    ctx.library.revision += 1;
    const replayed = try registry.submit(ctx, epoch, &request, path);
    try std.testing.expectEqual(first.status, replayed.status);
    try std.testing.expectEqual(@as(u32, @backingInt(api.Disposition.replayed)), replayed.disposition);
    request.proof.content_hash[0] = 1;
    try std.testing.expectEqual(api.Status.request_conflict, (try registry.submit(ctx, epoch, &request, path)).status);
    request.sequence = 2;
    request.proof.stamp.epoch_lo = 999;
    try std.testing.expectEqual(api.Status.wrong_epoch, (try registry.submit(ctx, epoch, &request, path)).status);
    request.proof.stamp.epoch_lo = 2;
    try std.testing.expectEqual(api.Status.stale_version, (try registry.submit(ctx, epoch, &request, path)).status);
    try std.testing.expectEqual(@as(u64, 2), registry.book.clients.get(.{ 3, 4 }).?);
}

test "resource snapshots serialize only coherent library declarations" {
    const ctx = try std.testing.allocator.create(Context);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    const text = try snapshotText(ctx);
    defer ctx.allocator.free(text);
    try std.testing.expectEqualStrings("{\"format\":\"cutrans-resource-snapshot/1\",\"next_id\":1,\"folders\":[],\"resources\":[]}", text);
    try std.testing.expectEqual(@as(u64, 0), stamp(ctx, .{ 11, 12 }).revision);
}

test "resource submission checks publication exhaustion before opening a candidate" {
    const ctx = try std.testing.allocator.create(Context);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    // No Io or paths: reading the candidate would report not_ready, not failed.
    ctx.library.items[0] = .{ .id = 1, .label = try ctx.allocator.dupe(u8, "reference.png"), .kind = .reference, .provenance = .external, .source_uri = try ctx.allocator.dupe(u8, "external://1"), .content_hash = @splat(0) };
    ctx.library.count = 1;
    ctx.library.next_id = 2;
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const epoch = [2]u64{ 1, 2 };
    ctx.library.revision = std.math.maxInt(u64);
    var request = api.Request{ .client_hi = 9, .client_lo = 10, .sequence = 1, .proof = .{ .stamp = stamp(ctx, epoch), .target_id = 1, .mode = 2, .head_hash = @splat(0), .content_hash = @splat(0), .path_hash = @splat(0), .byte_length = 0, .volume_serial = 0, .file_index = 0 }, .path = .{} };
    const path = if (@import("builtin").os.tag == .windows) "C:/missing.png" else "/missing.png";
    try std.testing.expectEqual(abi.Status.failed, (try registry.submit(ctx, epoch, &request, path)).status);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.library.revision);
    ctx.library.revision = 0;
    ctx.assets.revision = std.math.maxInt(u64);
    request.sequence = 2;
    request.proof.stamp = stamp(ctx, epoch);
    try std.testing.expectEqual(abi.Status.failed, (try registry.submit(ctx, epoch, &request, path)).status);
    try std.testing.expectEqual(@as(u64, 0), ctx.library.revision);
    try std.testing.expectEqual(@as(usize, 0), ctx.external_sources.count);
}
