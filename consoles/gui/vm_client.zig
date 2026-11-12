const std = @import("std");
const vne = @import("vne");
const abi = vne.abi;
const command = vne.command;
const documents = vne.documents;
const workspace = vne.workspace;

/// Shell-owned projection state. It deliberately contains only mirror/view
/// fields; it is not a Runtime business context and owns no VM session.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    paths: vne.paths.Paths = .{},
    command: vne.command.Registry = undefined,
    status: vne.status.Status = .{},
    document: vne.documents.Document = vne.documents.Document.initDefault(),
    document_revision: u64 = 1,
    asset_view: vne.assets.View = .{},
    library_view: vne.library.View = .{},
    playback_view: vne.playback.View = .{},
    devices: vne.devices.Table = .{},

    pub fn init(self: *Context, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator };
        self.command.init(allocator, self);
    }

    pub fn deinit(self: *Context) void {
        self.command.deinit();
        self.asset_view.deinit(self.allocator);
        self.library_view.deinit(self.allocator);
        self.devices.reset();
        self.paths.deinit(self.allocator);
        self.status.clear();
        self.document = vne.documents.Document.initDefault();
        self.document_revision = 1;
        self.io = null;
    }
};

const RuntimeContext = Context;

pub const Frame = vne.frame.Frame;
pub const Paths = vne.paths.Paths;

const Projection = enum { document, playback, library, assets };

const ClientId = struct { hi: u64, lo: u64 };
const Pending = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    arg: ?[]u8,
    expected: workspace.Stamp,
    sequence: u64,

    fn deinit(self: Pending) void {
        self.allocator.free(self.name);
        if (self.arg) |arg| self.allocator.free(arg);
    }
};

const Client = struct {
    api: abi.ShellApi = undefined,
    workspace_api: workspace.Api = undefined,
    identity: ?ClientId = null,
    next_sequence: u64 = 1,
    sequence_exhausted: bool = false,
    stamp: ?workspace.Stamp = null,
    pending: ?Pending = null,
    last_outcome: ?workspace.Outcome = null,
    initialized: bool = false,
    mirror_errors: [4]?anyerror = @splat(error.MirrorNotInitialized),
};

var client: Client = .{};
var reconnect_cooldown: u8 = 0;

pub fn documentFresh() bool {
    return client.initialized and client.mirror_errors[@backingInt(Projection.document)] == null;
}

/// The latest settled receipt also survives an unknown-result recovery in pump.
pub fn lastDocumentOutcome() ?workspace.Outcome {
    return client.last_outcome;
}

pub fn mirrorsFresh() bool {
    for (client.mirror_errors) |failure| if (failure != null) return false;
    return client.initialized and client.pending == null;
}

fn mirrorFailed(ctx: *RuntimeContext, projection: Projection, failure: anyerror) void {
    const index = @backingInt(projection);
    if (client.mirror_errors[index] == null or client.mirror_errors[index].? != failure)
        std.debug.print("CUTRANS_SHELL_MIRROR_STALE projection={s} error={s}\n", .{ @tagName(projection), @errorName(failure) });
    client.mirror_errors[index] = failure;
    ctx.status.set("视图尚未同步，暂不能编辑；正在重试");
}

fn mirrorReady(ctx: *RuntimeContext, projection: Projection) void {
    const index = @backingInt(projection);
    const recovered = client.mirror_errors[index] != null;
    client.mirror_errors[index] = null;
    if (recovered) {
        std.debug.print("CUTRANS_SHELL_MIRROR_READY projection={s}\n", .{@tagName(projection)});
        if (mirrorsFresh()) ctx.status.set("视图已恢复同步");
    }
}

fn slice(value: []const u8) abi.ByteSlice {
    return .{ .ptr = value.ptr, .len = value.len };
}

pub fn init(api: *const abi.ShellApi) !void {
    if (!api.isCurrent()) return error.InvalidShellApi;
    if (api.context == null) return error.MissingRuntimeHandle;
    if (client.pending != null) return error.UnresolvedPreviousClient;
    var authority: workspace.Api = undefined;
    if (api.workspace_api(api.context, &authority) != abi.Status.ok) return error.WorkspaceApiUnavailable;
    if (authority.struct_size < @sizeOf(workspace.Api) or authority.api_version != workspace.version or authority.context == null) return error.InvalidWorkspaceApi;
    client = .{ .api = api.*, .workspace_api = authority };
    reconnect_cooldown = 0;
}

pub fn deinit() void {
    if (client.pending) |pending| pending.deinit();
    client = .{};
    reconnect_cooldown = 0;
}

fn initWithIdentity(api: *const abi.ShellApi, identity: ClientId) !void {
    try init(api);
    if (identity.hi == 0 and identity.lo == 0) return error.InvalidClientIdentity;
    client.identity = identity;
}

fn ensureIdentity(ctx: *RuntimeContext) !void {
    if (client.identity != null) return;
    const io = ctx.io orelse return error.ClientEntropyUnavailable;
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const identity = ClientId{ .hi = std.mem.readInt(u64, bytes[0..8], .little), .lo = std.mem.readInt(u64, bytes[8..16], .little) };
    if (identity.hi == 0 and identity.lo == 0) return error.ClientEntropyUnavailable;
    client.identity = identity;
}

fn resultCode(status: i32) command.Code {
    return switch (status) {
        abi.Status.ok => .ok,
        abi.Status.accepted => .accepted,
        abi.Status.unknown_command => .unknown_command,
        abi.Status.invalid_arguments => .invalid_arguments,
        abi.Status.permission_denied => .permission_denied,
        abi.Status.invalid_state => .invalid_state,
        abi.Status.not_ready => .not_ready,
        abi.Status.queue_full => .queue_full,
        abi.Status.cancelled => .cancelled,
        workspace.Status.stale_version, workspace.Status.wrong_epoch, workspace.Status.request_conflict, workspace.Status.receipt_expired, workspace.Status.bad_sequence => .invalid_state,
        workspace.Status.client_limit => .queue_full,
        workspace.Status.unsupported_command => .unknown_command,
        else => .failed,
    };
}

fn syncDocument(ctx: *RuntimeContext) !void {
    var metadata: workspace.Snapshot = undefined;
    var required: usize = 0;
    const query = client.workspace_api.snapshot(client.workspace_api.context, null, &metadata, null, 0, &required);
    if (query != abi.Status.buffer_too_small and query != abi.Status.ok) return error.DocumentSnapshotFailed;
    if (!validSnapshot(metadata) or required != metadata.text_len) return error.InvalidDocumentSnapshot;
    const text = try ctx.allocator.alloc(u8, required);
    defer ctx.allocator.free(text);
    var actual: workspace.Snapshot = undefined;
    const read = client.workspace_api.snapshot(client.workspace_api.context, &metadata.stamp, &actual, text.ptr, text.len, &required);
    if (read == workspace.Status.stale_version or read == workspace.Status.wrong_epoch) return error.DocumentSnapshotChanged;
    if (read != abi.Status.ok) return error.DocumentSnapshotFailed;
    if (!validSnapshot(actual) or !actual.stamp.eql(metadata.stamp) or actual.fingerprint != metadata.fingerprint or
        actual.node_id_high_water != metadata.node_id_high_water or actual.flags != metadata.flags or
        actual.text_len != metadata.text_len or required != metadata.text_len) return error.DocumentSnapshotChanged;
    var candidate = try documents.parse(text[0..required]);
    if (candidate.fingerprint() != actual.fingerprint or candidate.nodeIdHighWater() != actual.node_id_high_water) return error.DocumentMirrorMismatch;
    candidate.dirty = actual.flags & 1 != 0;
    candidate.legacy = actual.flags & 2 != 0;
    const changed = client.stamp == null or !client.stamp.?.eql(actual.stamp);
    ctx.document = candidate;
    ctx.document_revision = actual.stamp.revision;
    ctx.command.default_expected = actual.stamp;
    client.stamp = actual.stamp;
    client.initialized = true;
    if (changed) std.debug.print("[vm-client] 文档镜像同步 revision={d} fingerprint={d}\n", .{ actual.stamp.revision, actual.fingerprint });
}

fn validSnapshot(value: workspace.Snapshot) bool {
    return value.struct_size >= @sizeOf(workspace.Snapshot) and value.api_version == workspace.version and
        value.reserved == 0 and value.flags & ~@as(u32, 3) == 0 and value.text_len != 0 and value.stamp.revision != 0 and
        (value.stamp.epoch_hi != 0 or value.stamp.epoch_lo != 0);
}

pub fn sync(ctx: *RuntimeContext) !void {
    syncDocument(ctx) catch |err| {
        mirrorFailed(ctx, .document, err);
        return err;
    };
    mirrorReady(ctx, .document);
}

fn syncMirrors(ctx: *RuntimeContext) ?anyerror {
    var failure: ?anyerror = null;
    sync(ctx) catch |err| {
        failure = err;
    };
    syncPlayback(ctx) catch |err| {
        if (failure == null) failure = err;
    };
    syncLibrary(ctx) catch |err| {
        if (failure == null) failure = err;
    };
    syncAssets(ctx) catch |err| {
        if (failure == null) failure = err;
    };
    return failure;
}

fn refreshMirrors(ctx: *RuntimeContext) !void {
    if (syncMirrors(ctx)) |failure| return failure;
}

fn maybeReconnect(ctx: *RuntimeContext) void {
    if (reconnect_cooldown > 0) {
        reconnect_cooldown -= 1;
        return;
    }
    reconnect(ctx) catch {
        reconnect_cooldown = 30;
        ctx.status.set("Host 不可用，等待重新连接");
    };
}

fn allowedWhileStale(name: []const u8) bool {
    // Cleanup and stop controls must remain available after a projection fails.
    // Unrecognized future commands fail closed until the mirror is fresh.
    inline for (.{ "asset.release", "task.cancel", "playback.stop", "doc.read", "task.list", "library.list", "asset.list", "playback.status" }) |allowed|
        if (std.mem.eql(u8, name, allowed)) return true;
    return false;
}

fn pendingMessage(ctx: *RuntimeContext) void {
    ctx.status.set("修改结果尚未确认，正在核对；暂不能提交新修改");
}

fn submitPending(ctx: *RuntimeContext) command.Result {
    const pending = client.pending orelse return .failure(.invalid_state);
    const identity = client.identity.?;
    const request = workspace.Request{
        .client_hi = identity.hi,
        .client_lo = identity.lo,
        .sequence = pending.sequence,
        .expected = pending.expected,
        .name = .{ .ptr = pending.name.ptr, .len = pending.name.len },
        .arg = if (pending.arg) |arg| .{ .ptr = arg.ptr, .len = arg.len } else .{},
    };
    var outcome: workspace.Outcome = undefined;
    const transport = client.workspace_api.submit(client.workspace_api.context, &request, &outcome);
    if (transport != abi.Status.ok) {
        // There may already be a committed edit. Retain the exact request,
        // including its old expected stamp, until a receipt answers it.
        pendingMessage(ctx);
        return .failure(.not_ready);
    }
    if (outcome.struct_size < @sizeOf(workspace.Outcome) or outcome.api_version != workspace.version or
        outcome.sequence != pending.sequence or outcome.disposition < @backingInt(workspace.Disposition.executed) or
        outcome.disposition > @backingInt(workspace.Disposition.rejected) or outcome.stamp.revision == 0 or
        (outcome.stamp.epoch_hi == 0 and outcome.stamp.epoch_lo == 0))
    {
        pendingMessage(ctx);
        return .failure(.not_ready);
    }
    pending.deinit();
    client.pending = null;
    client.last_outcome = outcome;
    const early_refusal = outcome.disposition == @backingInt(workspace.Disposition.rejected) and
        (outcome.status == abi.Status.invalid_arguments or outcome.status == workspace.Status.client_limit);
    if (outcome.status == workspace.Status.wrong_epoch or outcome.status == workspace.Status.bad_sequence or outcome.status == workspace.Status.receipt_expired) {
        // This request is settled, never translated into a request for the new
        // Runtime. Only a later explicit user intent may create a new identity.
        client.identity = null;
        client.next_sequence = 1;
        client.sequence_exhausted = false;
    } else if (!early_refusal) {
        if (client.next_sequence == std.math.maxInt(u64)) client.sequence_exhausted = true else client.next_sequence += 1;
    }
    const result = command.Result{
        .code = resultCode(outcome.status),
        .task_id = if (outcome.task_id == 0) null else outcome.task_id,
        .workspace_outcome = outcome,
    };
    if (result.code != .ok and result.code != .accepted) {
        std.debug.print("CUTRANS_SHELL_DOCUMENT_REFUSED sequence={d} status={d}\n", .{ outcome.sequence, outcome.status });
        ctx.status.set("操作未成功完成；请检查当前状态后重新操作");
        if (outcome.status == workspace.Status.stale_version) ctx.status.set("文档版本已变化，本次修改未执行；请检查当前文档后重新操作");
        if (outcome.status == workspace.Status.wrong_epoch) ctx.status.set("运行时已重启，上次结果无法确认；请核对文档，不会自动重复修改");
        if (outcome.status == workspace.Status.receipt_expired) ctx.status.set("上次修改的回执已过期，结果无法确认；请核对文档，不会自动重复修改");
    }
    return result;
}

fn beginPending(ctx: *RuntimeContext, c: command.Command, expected: workspace.Stamp) !void {
    if (c.name.len == 0 or c.name.len > 64 or c.payload != null or
        (if (c.arg) |arg| arg.len > 1024 * 1024 else false)) return error.InvalidCommandArguments;
    try ensureIdentity(ctx);
    if (client.sequence_exhausted) return error.ClientSequenceExhausted;
    const name = try ctx.allocator.dupe(u8, c.name);
    errdefer ctx.allocator.free(name);
    const arg = if (c.arg) |value| try ctx.allocator.dupe(u8, value) else null;
    client.pending = .{ .allocator = ctx.allocator, .name = name, .arg = arg, .expected = expected, .sequence = client.next_sequence };
}

fn forwardManaged(ctx: *RuntimeContext, c: command.Command) command.Result {
    if (client.pending != null) {
        pendingMessage(ctx);
        return .failure(.not_ready);
    }
    // The intent belongs to the view the user acted on. A refresh may repair
    // projection health, but must never silently rebase this expected version.
    const expected = c.expected orelse client.stamp orelse return .failure(.not_ready);
    if (!mirrorsFresh()) refreshMirrors(ctx) catch return .failure(.not_ready);
    if (!mirrorsFresh()) return .failure(.not_ready);
    beginPending(ctx, c, expected) catch |err| return .failure(if (err == error.InvalidCommandArguments) .invalid_arguments else .not_ready);
    const result = submitPending(ctx);
    refreshMirrors(ctx) catch {};
    return result;
}

fn forward(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    if (workspace.manages(c.name)) return forwardManaged(ctx, c);
    if (!mirrorsFresh() and !allowedWhileStale(c.name))
        refreshMirrors(ctx) catch return .failure(.not_ready);
    if (!mirrorsFresh() and !allowedWhileStale(c.name)) return .failure(.not_ready);
    const arg = if (c.arg) |value| slice(value) else abi.ByteSlice{};
    var task_id: u64 = 0;
    const status = client.api.command_result(client.api.context, slice(c.name), arg, &task_id);
    // The authority's result is final for this invocation. A later read failure
    // marks the projection stale; it never retroactively fails/retries a command.
    refreshMirrors(ctx) catch {};
    if (status == abi.Status.not_ready) ctx.status.set("Host 连接中断，命令结果无法确认；请核对文档后重试");
    return .{ .code = resultCode(status), .task_id = if (task_id == 0) null else task_id };
}

pub fn reconnect(ctx: *RuntimeContext) !void {
    try @import("shell").client.reconnect();
    if (client.pending == null) {
        client.identity = null;
        client.stamp = null;
    }
    try refreshMirrors(ctx);
    reconnect_cooldown = 0;
    ctx.status.set("Host 已重新连接，投影已刷新");
}

pub fn syncPlayback(ctx: *RuntimeContext) !void {
    syncPlaybackState(ctx) catch |err| {
        mirrorFailed(ctx, .playback, err);
        return err;
    };
    mirrorReady(ctx, .playback);
}

fn syncPlaybackState(ctx: *RuntimeContext) !void {
    var report: abi.PlaybackReport = undefined;
    if (client.api.playback_report(client.api.context, &report) != abi.Status.ok) return error.PlaybackMirrorFailed;
    if (report.active != @intFromBool(ctx.playback_view.active) or report.cursor != ctx.playback_view.cursor or report.last_t != ctx.playback_view.last_t) {
        std.debug.print("[playback-view] active={d} cursor={d} frames={d} last_t={d} current_t={d}\n", .{ report.active, report.cursor, report.frames, report.last_t, if (report.cursor > 0) report.cursor - 1 else -1 });
    }
    try ctx.playback_view.apply(report);
}

pub fn syncAssets(ctx: *RuntimeContext) !void {
    @import("shell").mirror.syncAssets(ctx.allocator, &client.api, &ctx.asset_view) catch |err| {
        mirrorFailed(ctx, .assets, err);
        return err;
    };
    mirrorReady(ctx, .assets);
}

pub fn ensureLibraryAsset(ctx: *RuntimeContext, id: u64, expected: [32]u8) !u64 {
    if (!mirrorsFresh()) return error.StaleMirror;
    return @import("shell").mirror.ensureLibrary(&client.api, ctx.allocator, &ctx.asset_view, id, expected);
}

pub fn sourceStatusText(status: @import("vne").assets.SourceStatus) []const u8 {
    return @import("shell").mirror.sourceStatusText(status);
}

/// An explicit owner-synchronous observation, like ensureLibraryAsset. It must
/// not enter the GUI frame queue, whose accepted result only means queued.
pub fn checkLoadedSource(ctx: *RuntimeContext, handle: u64) !void {
    if (!mirrorsFresh()) return error.StaleMirror;
    const item = ctx.asset_view.find(handle) orelse return error.AssetNotFound;
    if (item.library_id == 0) return error.InvalidLibraryResource;
    var buffer: [32]u8 = undefined;
    const argument = try std.fmt.bufPrint(&buffer, "{d}", .{handle});
    const status = try @import("shell").mirror.command(&client.api, "asset.check", argument);
    if (status != abi.Status.ok) return error.SourceCheckFailed;
    // A successful authority result is settled even if the projection is not.
    syncAssets(ctx) catch return error.SourceCheckProjectionFailed;
}

/// These two explicit library actions complete on the Runtime owner. Do not
/// route them through a GUI frame queue or retry a legacy result implicitly.
pub fn runLibraryAction(ctx: *RuntimeContext, name: []const u8, id: u64) !void {
    if ((!std.mem.eql(u8, name, "library.detach") and !std.mem.eql(u8, name, "library.refresh")) or id == 0)
        return error.InvalidLibraryAction;
    if (!mirrorsFresh()) return error.StaleMirror;
    var buffer: [32]u8 = undefined;
    const argument = try std.fmt.bufPrint(&buffer, "{d}", .{id});
    const status = try @import("shell").mirror.command(&client.api, name, argument);
    if (status != abi.Status.ok) return error.LibraryActionUnconfirmed;
    var failed = false;
    syncLibrary(ctx) catch {
        failed = true;
    };
    syncAssets(ctx) catch {
        failed = true;
    };
    if (failed) return error.LibraryActionProjectionFailed;
}

pub fn syncLibrary(ctx: *RuntimeContext) !void {
    @import("shell").mirror.syncLibrary(ctx.allocator, &client.api, &ctx.library_view) catch |err| {
        mirrorFailed(ctx, .library, err);
        return err;
    };
    mirrorReady(ctx, .library);
}

pub fn previewFrame(ctx: *RuntimeContext, expected: u64, allocator: std.mem.Allocator) !@import("vne").frame.Frame {
    _ = ctx;
    var info: @import("vne").abi.PreviewInfo = undefined;
    if (client.api.preview_info(client.api.context, expected, &info) != abi.Status.ok) return error.PreviewUnavailable;
    @import("vne").preview.validateInfo(info) catch return error.InvalidPreviewInfo;
    if (info.bytes_len > 64 * 1024 * 1024) return error.PreviewTooLarge;
    const frame = @import("vne").frame.Frame{
        .width = info.width,
        .height = info.height,
        .generation = info.generation,
        .pixels = try allocator.alloc(u8, info.bytes_len),
        .epoch_hi = info.epoch_hi,
        .epoch_lo = info.epoch_lo,
    };
    errdefer allocator.free(frame.pixels);
    var written: usize = 0;
    if (client.api.preview_read(client.api.context, expected, frame.pixels.ptr, frame.pixels.len, &written) != abi.Status.ok) return error.PreviewUnavailable;
    if (written != info.bytes_len) return error.PreviewLengthMismatch;
    return frame;
}

pub fn imageDimensions(allocator: std.mem.Allocator, bytes: []const u8) !struct { width: u32, height: u32 } {
    var decoded = try @import("imaging").decode(allocator, bytes);
    defer decoded.deinit(allocator);
    return .{ .width = decoded.width, .height = decoded.height };
}

pub fn previewAsset(ctx: *RuntimeContext, handle: u64, expected_hash: ?[32]u8) !@import("vne").frame.Frame {
    if (!mirrorsFresh()) return error.StaleMirror;
    var preview = try @import("shell").mirror.previewPng(ctx.allocator, &client.api, handle, expected_hash);
    defer preview.deinit(ctx.allocator);
    const decoded = try @import("imaging").decode(ctx.allocator, preview.bytes);
    if (decoded.width != preview.info.width or decoded.height != preview.info.height) {
        var owned = decoded;
        owned.deinit(ctx.allocator);
        return error.AssetPreviewMismatch;
    }
    return .{ .width = decoded.width, .height = decoded.height, .generation = 1, .pixels = decoded.pixels };
}

pub const Source = struct {
    image: @import("imaging").Image,
    lease: u64 = 0,
};

pub const SourceProvider = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque, documents.Node) anyerror!Source,
    release: *const fn (*anyopaque, u64) void,
};

fn loadSource(ptr: *anyopaque, node: documents.Node) !Source {
    if (!mirrorsFresh()) return error.StaleMirror;
    const ctx: *RuntimeContext = @ptrCast(@alignCast(ptr));
    var expected_hex: [64]u8 = undefined;
    const expected = if (node.asset_hash_present) blk: {
        expected_hex = std.fmt.bytesToHex(node.asset_hash, .lower);
        break :blk slice(&expected_hex);
    } else abi.ByteSlice{};
    var required: usize = 0;
    const query = client.api.source_read(client.api.context, slice(node.asset()), expected, null, 0, &required);
    if (query == abi.Status.legacy_identity_unverified) return error.LegacyExternalIdentityUnverified;
    if (query != abi.Status.buffer_too_small) return error.SourceReadFailed;
    if (required == 0 or required > 16 * 1024 * 1024) return error.InvalidSourceRead;
    const bytes = try ctx.allocator.alloc(u8, required);
    defer ctx.allocator.free(bytes);
    var actual: usize = 0;
    const status = client.api.source_read(client.api.context, slice(node.asset()), expected, bytes.ptr, bytes.len, &actual);
    if (status == abi.Status.legacy_identity_unverified) return error.LegacyExternalIdentityUnverified;
    if (status != abi.Status.ok) return error.SourceReadFailed;
    if (actual == 0 or actual > bytes.len) return error.InvalidSourceRead;
    if (node.asset_hash_present) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..actual], &digest, .{});
        if (!std.mem.eql(u8, &node.asset_hash, &digest)) return error.SourceContentMismatch;
    }
    // Encoded bytes and decoded pixels are caller owned. No remote Station
    // lease can be orphaned if a reply is lost or this rendering attempt fails.
    return .{ .image = try @import("imaging").decode(ctx.allocator, bytes[0..actual]), .lease = 0 };
}

fn releaseSource(_: *anyopaque, _: u64) void {}

pub fn sourceProvider(ctx: *RuntimeContext) SourceProvider {
    return .{ .context = ctx, .load = loadSource, .release = releaseSource };
}

pub fn openExternal(ctx: *RuntimeContext, path: []const u8) !u64 {
    if (!mirrorsFresh()) try refreshMirrors(ctx);
    if (!mirrorsFresh()) return error.StaleMirror;
    var handle: u64 = 0;
    const status = client.api.asset_open_external(client.api.context, slice(path), &handle);
    if (status != abi.Status.accepted or handle == 0) return error.ExternalAssetOpenFailed;
    // Loading may already have persisted a library entry. Preserve its accepted
    // handle even if reading the resulting projection fails.
    refreshMirrors(ctx) catch {};
    return handle;
}

pub fn registerExternal(ctx: *RuntimeContext, path: []const u8) !u64 {
    const io = ctx.io orelse return error.IoNotReady;
    return @import("shell").mirror.registerExternal(ctx.allocator, &client.api, &io, path);
}

pub fn register(ctx: *RuntimeContext) !void {
    try refreshMirrors(ctx);
    const names = [_][]const u8{
        "doc.open",
        "doc.read",
        "doc.write",
        "doc.save",
        "editor.gain.set",
        "editor.invert.add",
        "editor.over.add",
        "editor.over.opacity.set",
        "editor.image.open",
        "editor.export.png",
        "task.cancel",
        "task.retry",
        "task.list",
        "editor.resize.add",
        "history.undo",
        "history.redo",
        "playback.start",
        "playback.status",
        "playback.stop",
        "asset.open",
        "asset.ensure",
        "resource.acquire",
        "asset.check",
        "asset.preview",
        "asset.export",
        "asset.release",
        "asset.list",
        "source.reauthorize",
        "source.list",
        "library.refresh",
        "library.detach",
        "library.create",
        "library.folder.create",
        "library.rename",
        "library.move",
        "library.list",
        "editor.asset.insert",
    };
    for (names) |name| ctx.command.register(name, forward);
}

pub fn pump(ctx: *RuntimeContext) !void {
    if (client.pending != null) {
        _ = submitPending(ctx);
        if (client.pending != null) {
            refreshMirrors(ctx) catch {};
            return error.CommandResultUnknown;
        }
    }
    const status = client.api.pump(client.api.context);
    // Always retry reads, including after an execution error. Projection health
    // is reported separately and must not be mistaken for a failed task.
    refreshMirrors(ctx) catch {
        maybeReconnect(ctx);
    };
    if (status != abi.Status.ok) return error.TaskPumpFailed;
}

pub fn frameReport(report: *const abi.FrameReport) !void {
    if (client.api.frame_report(client.api.context, report) != abi.Status.ok) return error.FrameReportFailed;
}

const MockShell = struct {
    document: documents.Document = documents.Document.initDefault(),
    command_status: i32 = abi.Status.ok,
    task_id: u64 = 0,
    command_calls: usize = 0,
    external_calls: usize = 0,
    fail_after_command: bool = false,
    fail_fingerprint: bool = false,
    wrong_fingerprint: bool = false,
    fail_playback: bool = false,
    fail_library: bool = false,
    fail_assets: bool = false,
    fail_assets_after_command: bool = false,
    fail_library_after_command: bool = false,
    resident_handle: u64 = 0,
    check_calls: usize = 0,
    library_action_calls: usize = 0,
    pump_status: i32 = abi.Status.ok,
    stamp: workspace.Stamp = .{ .epoch_hi = 7, .epoch_lo = 8, .revision = 1 },
    snapshot_calls: usize = 0,
    change_after_metadata: bool = false,
    submit_calls: usize = 0,
    lose_next_response: bool = false,
    malformed_next_outcome: bool = false,
    apply_gain: ?f32 = null,
    early_status: ?i32 = null,
    last_client: ClientId = .{ .hi = 0, .lo = 0 },
    last_sequence: u64 = 0,
    last_expected: workspace.Stamp = .{},
    last_name: [64]u8 = undefined,
    last_name_len: usize = 0,
    last_arg: [256]u8 = undefined,
    last_arg_len: usize = 0,
    last_outcome: workspace.Outcome = undefined,

    fn state(ptr: ?*anyopaque) *MockShell {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn commandResult(ptr: ?*anyopaque, name: abi.ByteSlice, _: abi.ByteSlice, task_id: ?*u64) callconv(.c) i32 {
        const self = state(ptr);
        self.command_calls += 1;
        if (std.mem.eql(u8, name.ptr.?[0..name.len], "asset.check")) self.check_calls += 1;
        if (std.mem.eql(u8, name.ptr.?[0..name.len], "library.detach") or std.mem.eql(u8, name.ptr.?[0..name.len], "library.refresh")) self.library_action_calls += 1;
        if (task_id) |value| value.* = self.task_id;
        if (self.fail_after_command) self.fail_fingerprint = true;
        if (self.fail_assets_after_command) self.fail_assets = true;
        if (self.fail_library_after_command) self.fail_library = true;
        return self.command_status;
    }

    fn snapshot(ptr: ?*anyopaque, expected: ?*const workspace.Stamp, report: ?*workspace.Snapshot, buffer: ?[*]u8, capacity: usize, required: ?*usize) callconv(.c) i32 {
        const self = state(ptr);
        self.snapshot_calls += 1;
        if (self.fail_fingerprint) return abi.Status.failed;
        if (expected) |stamp| if (!stamp.eql(self.stamp)) return workspace.Status.stale_version;
        const text = documents.emitAlloc(&self.document, std.testing.allocator) catch return abi.Status.failed;
        defer std.testing.allocator.free(text);
        report.?.* = .{
            .stamp = self.stamp,
            .fingerprint = self.document.fingerprint() ^ @as(u64, @intFromBool(self.wrong_fingerprint)),
            .node_id_high_water = self.document.nodeIdHighWater(),
            .flags = @as(u32, @intFromBool(self.document.dirty)) | (@as(u32, @intFromBool(self.document.legacy)) << 1),
            .text_len = text.len,
        };
        required.?.* = text.len;
        if (buffer == null or capacity < text.len) {
            if (self.change_after_metadata) {
                self.change_after_metadata = false;
                self.document.setGain(1, 0.1) catch return abi.Status.failed;
                self.stamp.revision += 1;
            }
            return abi.Status.buffer_too_small;
        }
        @memcpy(buffer.?[0..text.len], text);
        return abi.Status.ok;
    }

    fn submit(ptr: ?*anyopaque, request_ptr: ?*const workspace.Request, output: ?*workspace.Outcome) callconv(.c) i32 {
        const self = state(ptr);
        const request = request_ptr.?;
        self.submit_calls += 1;
        const name = request.name.ptr.?[0..request.name.len];
        const arg = if (request.arg.ptr) |bytes| bytes[0..request.arg.len] else "";
        if (self.early_status) |status| {
            output.?.* = .{ .status = status, .disposition = @backingInt(workspace.Disposition.rejected), .sequence = request.sequence, .stamp = self.stamp };
            return abi.Status.ok;
        }
        if (self.last_client.hi == request.client_hi and self.last_client.lo == request.client_lo and self.last_sequence == request.sequence) {
            if (!self.last_expected.eql(request.expected) or !std.mem.eql(u8, name, self.last_name[0..self.last_name_len]) or !std.mem.eql(u8, arg, self.last_arg[0..self.last_arg_len])) {
                output.?.* = .{ .status = workspace.Status.request_conflict, .disposition = @backingInt(workspace.Disposition.rejected), .sequence = request.sequence, .stamp = self.stamp };
                return abi.Status.ok;
            }
            output.?.* = self.last_outcome;
            output.?.disposition = @backingInt(workspace.Disposition.replayed);
            return abi.Status.ok;
        }
        const status = if (request.expected.eql(self.stamp)) self.command_status else workspace.Status.stale_version;
        if (status != workspace.Status.stale_version) {
            self.command_calls += 1;
            if (self.apply_gain) |value| {
                self.document.setGain(1, value) catch return abi.Status.failed;
                self.stamp.revision += 1;
            }
        }
        self.last_client = .{ .hi = request.client_hi, .lo = request.client_lo };
        self.last_sequence = request.sequence;
        self.last_expected = request.expected;
        self.last_name_len = name.len;
        self.last_arg_len = arg.len;
        @memcpy(self.last_name[0..name.len], name);
        @memcpy(self.last_arg[0..arg.len], arg);
        self.last_outcome = .{
            .status = status,
            .disposition = @backingInt(if (status == workspace.Status.stale_version) workspace.Disposition.rejected else workspace.Disposition.executed),
            .sequence = request.sequence,
            .stamp = self.stamp,
            .task_id = self.task_id,
        };
        if (self.fail_after_command) self.fail_fingerprint = true;
        if (self.lose_next_response) {
            self.lose_next_response = false;
            return abi.Status.failed;
        }
        output.?.* = self.last_outcome;
        if (self.malformed_next_outcome) {
            self.malformed_next_outcome = false;
            output.?.sequence += 1;
        }
        return abi.Status.ok;
    }

    fn workspaceApi(ptr: ?*anyopaque, output: ?*workspace.Api) callconv(.c) i32 {
        output.?.* = .{ .context = ptr, .snapshot = snapshot, .submit = submit };
        return abi.Status.ok;
    }

    fn resourceApi(_: ?*anyopaque, _: ?*@import("vne").resource_api.Api) callconv(.c) i32 {
        return abi.Status.not_ready;
    }

    fn fingerprint(ptr: ?*anyopaque, value: ?*u64) callconv(.c) i32 {
        const self = state(ptr);
        if (self.fail_fingerprint) return abi.Status.failed;
        value.?.* = self.document.fingerprint() ^ @as(u64, @intFromBool(self.wrong_fingerprint));
        return abi.Status.ok;
    }

    fn flags(ptr: ?*anyopaque, value: ?*u32) callconv(.c) i32 {
        const self = state(ptr);
        value.?.* = @intFromBool(self.document.dirty);
        return abi.Status.ok;
    }

    fn read(ptr: ?*anyopaque, buffer: ?[*]u8, capacity: usize, required: ?*usize) callconv(.c) i32 {
        const text = documents.emitAlloc(&state(ptr).document, std.testing.allocator) catch return abi.Status.failed;
        defer std.testing.allocator.free(text);
        required.?.* = text.len;
        if (buffer == null or capacity < text.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..text.len], text);
        return abi.Status.ok;
    }

    fn advance(ptr: ?*anyopaque) callconv(.c) i32 {
        return state(ptr).pump_status;
    }

    fn playback(ptr: ?*anyopaque, report: ?*abi.PlaybackReport) callconv(.c) i32 {
        if (state(ptr).fail_playback) return abi.Status.failed;
        report.?.* = .{
            .struct_size = @sizeOf(abi.PlaybackReport),
            .abi_version = abi.version,
            .active = 0,
            .cursor = 0,
            .frames = 0,
            .offer_count = 0,
            .underflow_count = 0,
            .present_count = 0,
            .last_t = -1,
        };
        return abi.Status.ok;
    }

    fn library(ptr: ?*anyopaque, report: ?*abi.LibraryListReport) callconv(.c) i32 {
        if (state(ptr).fail_library) return abi.Status.failed;
        report.?.* = .{ .struct_size = @sizeOf(abi.LibraryListReport), .abi_version = abi.version, .revision = 1, .count = 0, .entries = undefined };
        return abi.Status.ok;
    }

    fn assets(ptr: ?*anyopaque, report: ?*abi.AssetListReport) callconv(.c) i32 {
        const self = state(ptr);
        if (self.fail_assets) return abi.Status.failed;
        report.?.* = .{ .struct_size = @sizeOf(abi.AssetListReport), .abi_version = abi.version, .revision = 1, .count = @intFromBool(self.resident_handle != 0), .entries = @splat(.{}) };
        if (self.resident_handle != 0) report.?.entries[0] = .{ .handle = self.resident_handle, .byte_length = 72, .leases = 1, .source_kind = 3, .library_kind = 1, .library_id = 7, .content_hash = @splat(0x11) };
        return abi.Status.ok;
    }

    fn assetSource(_: ?*anyopaque, _: u64, buffer: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) i32 {
        const source = "library://7";
        length.?.* = source.len;
        if (buffer == null or capacity < source.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..source.len], source);
        return abi.Status.ok;
    }

    fn external(ptr: ?*anyopaque, _: abi.ByteSlice, handle: ?*u64) callconv(.c) i32 {
        const self = state(ptr);
        self.external_calls += 1;
        self.fail_library = true;
        handle.?.* = 37;
        return abi.Status.accepted;
    }

    fn api(self: *MockShell) abi.ShellApi {
        // Unused callbacks intentionally remain undefined: tests must fail if
        // stale preview handling reaches a data-read callback unexpectedly.
        return .{
            .struct_size = @sizeOf(abi.ShellApi),
            .abi_version = abi.version,
            .context = self,
            .command_result = commandResult,
            .document_fingerprint = fingerprint,
            .document_flags = flags,
            .document_read = read,
            .pump = advance,
            .playback_report = playback,
            .library_list = library,
            .asset_list = assets,
            .asset_open_external = external,
            .workspace_api = workspaceApi,
            .source_read = undefined,
            .resource_api = resourceApi,
            .input_push = undefined,
            .input_flush = undefined,
            .frame_report = undefined,
            .library_label = undefined,
            .asset_source = assetSource,
            .asset_preview = undefined,
            .asset_read = undefined,
            .preview_info = undefined,
            .preview_read = undefined,
        };
    }
};

fn testContext() !*RuntimeContext {
    const ctx = try std.testing.allocator.create(RuntimeContext);
    ctx.init(std.testing.allocator);
    ctx.io = std.testing.io;
    return ctx;
}

fn freeTestContext(ctx: *RuntimeContext) void {
    deinit();
    ctx.deinit();
    std.testing.allocator.destroy(ctx);
}

test "loaded source checks execute synchronously during a GUI frame without entering its queue" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote = MockShell{ .resident_handle = 11 };
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    const document_reads = remote.snapshot_calls;
    ctx.command.beginFrame();
    defer ctx.command.endFrame();
    try checkLoadedSource(ctx, 11);
    try std.testing.expectEqual(@as(usize, 1), remote.check_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
    try std.testing.expectEqual(document_reads, remote.snapshot_calls);
    try std.testing.expectEqual(@as(u32, 1), ctx.asset_view.find(11).?.leases);
    try std.testing.expectEqual(command.Code.ok, ctx.command.flush().code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
}

test "a completed source check distinguishes its later projection failure and never reexecutes it" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote = MockShell{ .resident_handle = 11 };
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    const source = ctx.asset_view.find(11).?.source.ptr;
    remote.fail_assets_after_command = true;
    ctx.command.beginFrame();
    defer ctx.command.endFrame();
    try std.testing.expectError(error.SourceCheckProjectionFailed, checkLoadedSource(ctx, 11));
    try std.testing.expectEqual(@as(usize, 1), remote.check_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
    try std.testing.expectEqual(source, ctx.asset_view.find(11).?.source.ptr);
    try std.testing.expectEqual(@as(u32, 1), ctx.asset_view.find(11).?.leases);
    try std.testing.expect(!mirrorsFresh());
    remote.fail_assets_after_command = false;
    remote.fail_assets = false;
    try syncAssets(ctx);
    try std.testing.expect(mirrorsFresh());
    try std.testing.expectEqual(@as(usize, 1), remote.check_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
}

test "library detach and refresh execute once during a GUI frame without queued or document work" {
    for ([_][]const u8{ "library.detach", "library.refresh" }) |name| {
        const ctx = try testContext();
        defer freeTestContext(ctx);
        var remote: MockShell = .{};
        const api = remote.api();
        try init(&api);
        try refreshMirrors(ctx);
        const document_reads = remote.snapshot_calls;
        ctx.command.beginFrame();
        defer ctx.command.endFrame();
        try runLibraryAction(ctx, name, 7);
        try std.testing.expectEqual(@as(usize, 1), remote.library_action_calls);
        try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
        try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
        try std.testing.expectEqual(document_reads, remote.snapshot_calls);
        try std.testing.expectEqual(command.Code.ok, ctx.command.flush().code);
        try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    }
}

test "known library success distinguishes projection failure and recovering views never repeats the action" {
    for ([_][]const u8{ "library.detach", "library.refresh" }) |name| {
        const ctx = try testContext();
        defer freeTestContext(ctx);
        var remote = MockShell{ .resident_handle = 11 };
        const api = remote.api();
        try init(&api);
        try refreshMirrors(ctx);
        const source = ctx.asset_view.find(11).?.source.ptr;
        const document_reads = remote.snapshot_calls;
        remote.fail_library_after_command = true;
        ctx.command.beginFrame();
        defer ctx.command.endFrame();
        try std.testing.expectError(error.LibraryActionProjectionFailed, runLibraryAction(ctx, name, 7));
        try std.testing.expectEqual(@as(usize, 1), remote.library_action_calls);
        try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
        try std.testing.expectEqual(source, ctx.asset_view.find(11).?.source.ptr);
        try std.testing.expectEqual(document_reads, remote.snapshot_calls);
        try std.testing.expect(!mirrorsFresh());
        remote.fail_library_after_command = false;
        remote.fail_library = false;
        try syncLibrary(ctx);
        try syncAssets(ctx);
        try std.testing.expect(mirrorsFresh());
        try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    }
}

test "library action helper restricts commands and never treats accepted as completed" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote = MockShell{ .command_status = abi.Status.accepted };
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    ctx.command.beginFrame();
    defer ctx.command.endFrame();
    try std.testing.expectError(error.InvalidLibraryAction, runLibraryAction(ctx, "library.move", 7));
    try std.testing.expectError(error.InvalidLibraryAction, runLibraryAction(ctx, "library.detach", 0));
    try std.testing.expectEqual(@as(usize, 0), remote.command_calls);
    try std.testing.expectError(error.LibraryActionUnconfirmed, runLibraryAction(ctx, "library.detach", 7));
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
}

test "successful command remains successful when the document mirror fails and recovers without replay" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    const before = ctx.document.fingerprint();
    try remote.document.setGain(1, 0.25);
    remote.fail_after_command = true;

    const result = forward(.{ .name = "editor.gain.set", .arg = "c1 0.25" }, ctx);
    try std.testing.expectEqual(command.Code.ok, result.code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expect(!documentFresh());
    try std.testing.expect(!mirrorsFresh());
    try std.testing.expectEqual(before, ctx.document.fingerprint());

    const blocked = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(command.Code.not_ready, blocked.code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expectError(error.StaleMirror, previewAsset(ctx, 1, null));
    remote.fail_fingerprint = false;
    try pump(ctx);
    try std.testing.expect(documentFresh());
    try std.testing.expect(mirrorsFresh());
    try std.testing.expectEqual(remote.document.fingerprint(), ctx.document.fingerprint());
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
}

test "transport-unknown command is not retried and reports an unknown outcome" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .command_status = abi.Status.not_ready };
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    const result = forward(.{ .name = "doc.read" }, ctx);
    try std.testing.expectEqual(command.Code.not_ready, result.code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expect(std.mem.indexOf(u8, ctx.status.get(), "无法确认") != null);
}

test "accepted task identity and authoritative refusal survive projection failure" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .command_status = abi.Status.accepted, .task_id = 42 };
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    remote.fail_after_command = true;
    const accepted = forward(.{ .name = "editor.export.png" }, ctx);
    try std.testing.expectEqual(command.Code.accepted, accepted.code);
    try std.testing.expectEqual(@as(?u64, 42), accepted.task_id);
    try std.testing.expect(!documentFresh());

    remote.fail_fingerprint = false;
    remote.fail_after_command = false;
    try refreshMirrors(ctx);
    remote.command_status = abi.Status.permission_denied;
    remote.task_id = 0;
    remote.fail_after_command = true;
    const refused = forward(.{ .name = "doc.save" }, ctx);
    try std.testing.expectEqual(command.Code.permission_denied, refused.code);
    try std.testing.expectEqual(@as(?u64, null), refused.task_id);
    try std.testing.expect(!documentFresh());
}

test "invalid candidate mirror is not published and cleanup controls remain available" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    const before = ctx.document.fingerprint();
    try remote.document.setGain(1, 0.4);
    remote.wrong_fingerprint = true;
    try std.testing.expectError(error.DocumentMirrorMismatch, sync(ctx));
    try std.testing.expectEqual(before, ctx.document.fingerprint());
    try std.testing.expect(!documentFresh());
    const cleanup = forward(.{ .name = "asset.release", .arg = "1" }, ctx);
    try std.testing.expectEqual(command.Code.ok, cleanup.code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expect(!documentFresh());
}

test "task execution failure is reported while healthy projections can still recover" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    remote.fail_assets = true;
    try pump(ctx);
    try std.testing.expect(documentFresh());
    try std.testing.expect(!mirrorsFresh());
    const blocked = forward(.{ .name = "future.business.command" }, ctx);
    try std.testing.expectEqual(command.Code.not_ready, blocked.code);
    try std.testing.expectEqual(@as(usize, 0), remote.command_calls);
    remote.fail_assets = false;
    remote.pump_status = abi.Status.failed;
    try std.testing.expectError(error.TaskPumpFailed, pump(ctx));
    try std.testing.expect(mirrorsFresh());
}

test "accepted external resource handle is preserved when the resulting library projection fails" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try init(&api);
    try refreshMirrors(ctx);
    try std.testing.expectEqual(@as(u64, 37), try openExternal(ctx, "C:/verification/example.png"));
    try std.testing.expectEqual(@as(usize, 1), remote.external_calls);
    try std.testing.expect(documentFresh());
    try std.testing.expect(!mirrorsFresh());
    try std.testing.expectError(error.StaleMirror, previewAsset(ctx, 37, null));
    remote.fail_library = false;
    try pump(ctx);
    try std.testing.expect(mirrorsFresh());
    try std.testing.expectEqual(@as(usize, 1), remote.external_calls);
}

test "snapshot text is bound to metadata and never publishes a mixed revision" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    const before = ctx.document.fingerprint();
    const stamp = client.stamp.?;
    remote.change_after_metadata = true;
    try std.testing.expectError(error.DocumentSnapshotChanged, sync(ctx));
    try std.testing.expectEqual(before, ctx.document.fingerprint());
    try std.testing.expect(client.stamp.?.eql(stamp));
    try std.testing.expect(ctx.command.default_expected.?.eql(stamp));
    try sync(ctx);
    try std.testing.expectEqual(remote.document.fingerprint(), ctx.document.fingerprint());
    try std.testing.expectEqual(@as(u64, 2), ctx.document_revision);
}

test "unknown command result retries the exact owned request and blocks new edits" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .lose_next_response = true, .apply_gain = 0.25, .command_status = abi.Status.accepted, .task_id = 42 };
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    const viewed = client.stamp.?;
    var arg = "c1 0.25".*;
    const uncertain = forward(.{ .name = "editor.gain.set", .arg = &arg, .expected = viewed }, ctx);
    try std.testing.expectEqual(command.Code.not_ready, uncertain.code);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.submit_calls);
    try std.testing.expect(!mirrorsFresh());
    try std.testing.expect(client.pending.?.expected.eql(viewed));
    try std.testing.expect(!client.stamp.?.eql(viewed));
    @memcpy(&arg, "c1 0.99");
    const blocked = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(command.Code.not_ready, blocked.code);
    try std.testing.expectEqual(@as(usize, 1), remote.submit_calls);
    try pump(ctx);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    try std.testing.expectEqual(@as(usize, 2), remote.submit_calls);
    try std.testing.expectEqual(@as(u64, 1), remote.last_sequence);
    try std.testing.expectEqual(@as(u64, 101), remote.last_client.hi);
    try std.testing.expectEqualStrings("c1 0.25", remote.last_arg[0..remote.last_arg_len]);
    try std.testing.expect(remote.last_expected.eql(viewed));
    try std.testing.expect(client.pending == null);
    try std.testing.expectEqual(@as(u64, 2), client.next_sequence);
    try std.testing.expectEqual(@as(u64, 42), lastDocumentOutcome().?.task_id);
    try std.testing.expect(mirrorsFresh());
}

test "invalid receipt is uncertain while an authoritative refusal is never retried" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .malformed_next_outcome = true };
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    try std.testing.expectEqual(command.Code.not_ready, forward(.{ .name = "editor.gain.set", .arg = "c1 0.25" }, ctx).code);
    try std.testing.expect(client.pending != null);
    try pump(ctx);
    try std.testing.expectEqual(@as(usize, 1), remote.command_calls);
    remote.command_status = abi.Status.permission_denied;
    const refused = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(command.Code.permission_denied, refused.code);
    try std.testing.expectEqual(abi.Status.permission_denied, refused.workspace_outcome.?.status);
    const calls = remote.submit_calls;
    try pump(ctx);
    try std.testing.expectEqual(calls, remote.submit_calls);
    try std.testing.expect(client.pending == null);
}

test "queued stale intent keeps its original expected stamp and receives a refusal" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try register(ctx);
    const viewed = client.stamp.?;
    ctx.command.beginFrame();
    try std.testing.expectEqual(command.Code.accepted, ctx.command.dispatch(.{ .name = "editor.invert.add" }).code);
    remote.stamp.revision += 1;
    try remote.document.setGain(1, 0.1);
    try sync(ctx);
    const rejected = ctx.command.flush();
    try std.testing.expectEqual(command.Code.invalid_state, rejected.code);
    try std.testing.expectEqual(workspace.Status.stale_version, rejected.workspace_outcome.?.status);
    try std.testing.expect(remote.last_expected.eql(viewed));
    try std.testing.expectEqual(@as(usize, 0), remote.command_calls);
    try std.testing.expectEqual(@as(u64, 2), client.next_sequence);
    const calls = remote.submit_calls;
    try pump(ctx);
    try std.testing.expectEqual(calls, remote.submit_calls);
}

test "early rejections preserve sequence and a new epoch requires a new explicit intent" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .early_status = abi.Status.invalid_arguments };
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    _ = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    remote.early_status = null;
    remote.command_status = abi.Status.invalid_arguments;
    _ = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(@as(u64, 2), client.next_sequence);
    remote.early_status = workspace.Status.wrong_epoch;
    remote.stamp.epoch_lo += 1;
    _ = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expect(client.pending == null);
    try std.testing.expect(client.identity == null);
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    try std.testing.expect(std.mem.indexOf(u8, ctx.status.get(), "上次结果无法确认") != null);
    const calls = remote.submit_calls;
    try pump(ctx);
    try std.testing.expectEqual(calls, remote.submit_calls);
    remote.early_status = null;
    remote.command_status = abi.Status.ok;
    try std.testing.expectEqual(command.Code.ok, forward(.{ .name = "editor.invert.add" }, ctx).code);
    try std.testing.expect(remote.last_client.hi != 101 or remote.last_client.lo != 202);
    try std.testing.expectEqual(@as(u64, 1), remote.last_sequence);
}

test "client limit and expired receipt do not automatically resubmit an unresolved intent" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .early_status = workspace.Status.client_limit };
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    const limited = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(command.Code.queue_full, limited.code);
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    try std.testing.expectEqual(@as(u64, 101), client.identity.?.hi);
    remote.early_status = workspace.Status.receipt_expired;
    const expired = forward(.{ .name = "editor.invert.add" }, ctx);
    try std.testing.expectEqual(workspace.Status.receipt_expired, expired.workspace_outcome.?.status);
    try std.testing.expect(client.identity == null);
    try std.testing.expect(client.pending == null);
    const calls = remote.submit_calls;
    try pump(ctx);
    try std.testing.expectEqual(calls, remote.submit_calls);
    try std.testing.expectEqual(@as(usize, 0), remote.command_calls);
    try std.testing.expectEqual(workspace.Status.receipt_expired, lastDocumentOutcome().?.status);
}

test "oversized managed arguments are rejected before pending and do not block later edits" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{};
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    const too_large = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'x');
    const rejected = forward(.{ .name = "doc.write", .arg = too_large }, ctx);
    try std.testing.expectEqual(command.Code.invalid_arguments, rejected.code);
    try std.testing.expect(client.pending == null);
    try std.testing.expectEqual(@as(usize, 0), remote.submit_calls);
    try std.testing.expectEqual(@as(u64, 1), client.next_sequence);
    try std.testing.expectEqual(command.Code.ok, forward(.{ .name = "editor.invert.add" }, ctx).code);
    try std.testing.expectEqual(@as(usize, 1), remote.submit_calls);
    try std.testing.expectEqual(@as(u64, 1), remote.last_sequence);
}

test "pending document request blocks external import even when projection reads recover" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: MockShell = .{ .lose_next_response = true };
    const api = remote.api();
    try initWithIdentity(&api, .{ .hi = 101, .lo = 202 });
    try refreshMirrors(ctx);
    _ = forward(.{ .name = "editor.gain.set", .arg = "c1 0.25" }, ctx);
    try std.testing.expect(client.pending != null);
    try std.testing.expectError(error.StaleMirror, openExternal(ctx, "C:/verification/example.png"));
    try std.testing.expectEqual(@as(usize, 0), remote.external_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.submit_calls);
    try pump(ctx);
    try std.testing.expect(client.pending == null);
    try std.testing.expectEqual(@as(u64, 37), try openExternal(ctx, "C:/verification/example.png"));
    try std.testing.expectEqual(@as(usize, 1), remote.external_calls);
}

fn sourceTestPng(pixel: [4]u8) [73]u8 {
    var bytes: [73]u8 = undefined;
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    @memcpy(bytes[16..29], &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 });
    std.mem.writeInt(u32, bytes[29..33], std.hash.Crc32.hash(bytes[12..29]), .big);
    std.mem.writeInt(u32, bytes[33..37], 16, .big);
    @memcpy(bytes[37..41], "IDAT");
    @memcpy(bytes[41..49], &[_]u8{ 0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x00 });
    @memcpy(bytes[49..53], &pixel);
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes[48..53]) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    std.mem.writeInt(u32, bytes[53..57], (b << 16) | a, .big);
    std.mem.writeInt(u32, bytes[57..61], std.hash.Crc32.hash(bytes[37..57]), .big);
    std.mem.writeInt(u32, bytes[61..65], 0, .big);
    @memcpy(bytes[65..69], "IEND");
    std.mem.writeInt(u32, bytes[69..73], std.hash.Crc32.hash(bytes[65..69]), .big);
    return bytes;
}

const SourceMock = struct {
    base: MockShell = .{},
    panel_leases: [2]u32 = .{ 1, 1 },
    reads: usize = 0,
    actual_reads: usize = 0,
    last_hash_len: usize = 0,
    fail_read: bool = false,
    legacy_identity: bool = false,
    corrupt_body: bool = false,
    query_size: ?usize = null,
    current: usize = 1,
    const uri = "library://9";
    const png_a = sourceTestPng(.{ 255, 0, 0, 255 });
    const png_b = sourceTestPng(.{ 0, 0, 255, 255 });

    fn selfFrom(ptr: ?*anyopaque) *SourceMock {
        const base: *MockShell = @ptrCast(@alignCast(ptr.?));
        return @fieldParentPtr("base", base);
    }

    fn bytes(index: usize) []const u8 {
        return if (index == 0) &png_a else &png_b;
    }

    fn digest(index: usize) [32]u8 {
        var value: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes(index), &value, .{});
        return value;
    }

    fn copy(value: []const u8, buffer: ?[*]u8, capacity: usize, length: ?*usize) i32 {
        length.?.* = value.len;
        if (buffer == null or capacity < value.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..value.len], value);
        return abi.Status.ok;
    }

    fn sourceRead(ptr: ?*anyopaque, source: abi.ByteSlice, expected: abi.ByteSlice, buffer: ?[*]u8, capacity: usize, out_len: ?*usize) callconv(.c) i32 {
        const self = selfFrom(ptr);
        const length = out_len orelse return abi.Status.invalid_arguments;
        length.* = 0;
        self.reads += 1;
        if (self.legacy_identity) return abi.Status.legacy_identity_unverified;
        if (source.ptr == null or !std.mem.eql(u8, source.ptr.?[0..source.len], uri)) return abi.Status.invalid_arguments;
        var index = self.current;
        self.last_hash_len = expected.len;
        if (expected.len != 0) {
            if (expected.len != 64 or expected.ptr == null) return abi.Status.invalid_arguments;
            var hash: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash, expected.ptr.?[0..64]) catch return abi.Status.invalid_arguments;
            const hash_a = digest(0);
            const hash_b = digest(1);
            if (std.mem.eql(u8, &hash, &hash_a)) index = 0 else if (std.mem.eql(u8, &hash, &hash_b)) index = 1 else return abi.Status.not_found;
        }
        const value = bytes(index);
        if (buffer == null) {
            length.* = self.query_size orelse value.len;
            return abi.Status.buffer_too_small;
        }
        self.actual_reads += 1;
        if (self.fail_read) return abi.Status.failed;
        length.* = value.len;
        if (capacity < value.len) return abi.Status.buffer_too_small;
        @memcpy(buffer.?[0..value.len], value);
        if (self.corrupt_body) buffer.?[49] ^= 1;
        return abi.Status.ok;
    }

    fn assetList(ptr: ?*anyopaque, out: ?*abi.AssetListReport) callconv(.c) i32 {
        const self = selfFrom(ptr);
        out.?.* = .{ .struct_size = @sizeOf(abi.AssetListReport), .abi_version = abi.version, .revision = 1, .count = 2, .entries = undefined };
        for (0..2) |index| out.?.entries[index] = .{ .handle = if (index == 0) 101 else 202, .byte_length = bytes(index).len, .leases = self.panel_leases[index], .source_kind = 3, .library_kind = 1, .library_id = 9 };
        return abi.Status.ok;
    }

    fn assetSource(_: ?*anyopaque, handle: u64, buffer: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) i32 {
        if (handle != 101 and handle != 202) return abi.Status.not_found;
        return copy(uri, buffer, capacity, length);
    }

    fn api(self: *SourceMock) abi.ShellApi {
        var value = self.base.api();
        value.source_read = sourceRead;
        value.asset_list = assetList;
        value.asset_source = assetSource;
        return value;
    }

    fn node(expected: ?[32]u8) documents.Node {
        var value = documents.Node{ .id = 9, .op = .image, .asset_len = uri.len, .asset_hash_present = expected != null };
        @memcpy(value.asset_path[0..uri.len], uri);
        if (expected) |hash| value.asset_hash = hash;
        return value;
    }
};

test "source provider reads exact A and B bytes for the same URI without changing Station panel leases" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote: SourceMock = .{};
    const api = remote.api();
    try init(&api);
    try register(ctx);
    try std.testing.expectEqualStrings(ctx.asset_view.items[0].source, ctx.asset_view.items[1].source);
    const before_fingerprint = ctx.document.fingerprint();
    const before_snapshots = remote.base.snapshot_calls;
    const provider = sourceProvider(ctx);
    var blue = try provider.load(provider.context, SourceMock.node(SourceMock.digest(1)));
    defer blue.image.deinit(ctx.allocator);
    var red = try provider.load(provider.context, SourceMock.node(SourceMock.digest(0)));
    defer red.image.deinit(ctx.allocator);
    try std.testing.expectEqual(@as(u64, 0), blue.lease);
    try std.testing.expectEqual(@as(u64, 0), red.lease);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, blue.image.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, red.image.pixels);
    ctx.command.beginFrame();
    provider.release(provider.context, blue.lease);
    provider.release(provider.context, red.lease);
    ctx.command.endFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.command.queue_count);
    try std.testing.expectEqualDeep([2]u32{ 1, 1 }, remote.panel_leases);
    try std.testing.expectEqual(@as(usize, 0), remote.base.command_calls);
    try std.testing.expectEqual(before_snapshots, remote.base.snapshot_calls);
    try std.testing.expectEqual(before_fingerprint, ctx.document.fingerprint());
}

test "failed or corrupt source replies leave Station and document state unchanged and can be retried" {
    const ctx = try testContext();
    defer freeTestContext(ctx);
    var remote = SourceMock{ .fail_read = true };
    const api = remote.api();
    try init(&api);
    try register(ctx);
    const before = ctx.document.fingerprint();
    const provider = sourceProvider(ctx);
    for (0..3) |_| try std.testing.expectError(error.SourceReadFailed, provider.load(provider.context, SourceMock.node(SourceMock.digest(0))));
    try std.testing.expectEqualDeep([2]u32{ 1, 1 }, remote.panel_leases);
    try std.testing.expectEqual(@as(usize, 0), remote.base.command_calls);
    remote.fail_read = false;
    remote.legacy_identity = true;
    try std.testing.expectError(error.LegacyExternalIdentityUnverified, provider.load(provider.context, SourceMock.node(SourceMock.digest(0))));
    remote.legacy_identity = false;
    remote.corrupt_body = true;
    try std.testing.expectError(error.SourceContentMismatch, provider.load(provider.context, SourceMock.node(SourceMock.digest(0))));
    remote.corrupt_body = false;
    remote.query_size = 16 * 1024 * 1024 + 1;
    const actual_reads = remote.actual_reads;
    try std.testing.expectError(error.InvalidSourceRead, provider.load(provider.context, SourceMock.node(null)));
    try std.testing.expectEqual(actual_reads, remote.actual_reads);
    remote.query_size = null;
    var current = try provider.load(provider.context, SourceMock.node(null));
    defer current.image.deinit(ctx.allocator);
    provider.release(provider.context, current.lease);
    try std.testing.expectEqual(@as(u64, 0), current.lease);
    try std.testing.expectEqual(@as(usize, 0), remote.last_hash_len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, current.image.pixels);
    try std.testing.expectEqual(before, ctx.document.fingerprint());
    try std.testing.expectEqualDeep([2]u32{ 1, 1 }, remote.panel_leases);
    try std.testing.expectEqual(@as(usize, 0), remote.base.command_calls);
}

test "GUI rejects an old Shell API prefix before reading the source callback" {
    var remote: MockShell = .{};
    var api = remote.api();
    api.struct_size = @offsetOf(abi.ShellApi, "source_read");
    try std.testing.expectError(error.InvalidShellApi, init(&api));
}
