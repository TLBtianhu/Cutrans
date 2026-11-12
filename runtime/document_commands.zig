//! document_commands.zig — VM/CLI/agent 共用的文档与 DAG 编辑命令
//!
//! GUI 与诊断器注册同一份 handler,避免命令语义随入口漂移。

const std = @import("std");
const command = @import("vne").command;
const documents = @import("vne").documents;
const render = @import("render.zig");
const image = @import("image.zig");
const history = @import("history.zig");
const history_journal = @import("history_journal.zig");
const export_job = @import("export_job.zig");
const task_journal = @import("task_journal.zig");
const RuntimeContext = @import("context.zig").Context;
const EditCandidate = @import("edit_transaction.zig").Candidate;

fn io(ctx: *RuntimeContext) ?std.Io {
    return ctx.io;
}

const ResolvedPath = @import("vne").mounts.Resolved;

fn resolvePath(ctx: *RuntimeContext, path: []const u8, for_write: bool) !ResolvedPath {
    const parsed = @import("vne").uri.parse(path) catch return error.InvalidResourcePath;
    const resolved = try ctx.mounts.resolveAlloc(ctx.allocator, parsed);
    if (for_write and resolved.access != .read_write) {
        ctx.allocator.free(resolved.path);
        return error.ReadOnlyResource;
    }
    return resolved;
}

fn persistHistory(ctx: *RuntimeContext) !void {
    if (ctx.io == null or ctx.paths.data_dir.len == 0) return;
    const io_value = ctx.io.?;
    var data_dir = try ctx.paths.openDataDir(io_value, ctx.allocator);
    defer data_dir.close(io_value);
    try history_journal.save(&ctx.history, &ctx.document, ctx.allocator, io_value, data_dir);
}

fn open(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const io_value = io(ctx) orelse return .failure(.not_ready);
    var candidate = EditCandidate.init(ctx);
    var loaded: documents.Document = undefined;
    if (c.arg) |path| {
        const resolved = resolvePath(ctx, path, false) catch return .failure(.invalid_arguments);
        defer ctx.allocator.free(resolved.path);
        documents.openExternal(&loaded, io_value, ctx.allocator, resolved.path) catch return .failure(.failed);
    } else {
        var resource_dir = ctx.paths.openResourceDir(io_value) catch return .failure(.failed);
        defer resource_dir.close(io_value);
        documents.open(&loaded, io_value, ctx.allocator, resource_dir, "assets/examples/minimal.cut") catch return .failure(.failed);
    }
    candidate.document.replacePreservingIdentity(&loaded);
    candidate.record(ctx, .{ .replace_document = .{ .before = ctx.document, .after = candidate.document } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set(if (ctx.document.legacy) "旧版文档已打开,保存时迁移到 v3" else "文档已打开");
    return .success;
}

fn read(_: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const text = documents.emitAlloc(&ctx.document, ctx.allocator) catch return .failure(.failed);
    defer ctx.allocator.free(text);
    std.debug.print("{s}", .{text});
    ctx.status.set("文档已读取");
    return .success;
}

fn write(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const io_value = io(ctx) orelse return .failure(.not_ready);
    var candidate = EditCandidate.init(ctx);
    const path = c.arg orelse return .failure(.invalid_arguments);
    const resolved = resolvePath(ctx, path, false) catch return .failure(.invalid_arguments);
    defer ctx.allocator.free(resolved.path);
    var loaded: documents.Document = undefined;
    documents.openExternal(&loaded, io_value, ctx.allocator, resolved.path) catch return .failure(.failed);
    candidate.document.replacePreservingIdentity(&loaded);
    candidate.record(ctx, .{ .replace_document = .{ .before = ctx.document, .after = candidate.document } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set(if (ctx.document.legacy) "旧版文档已替换,保存时迁移到 v3" else "文档已替换");
    return .success;
}

fn save(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const io_value = io(ctx) orelse return .failure(.not_ready);
    const changes_flags = ctx.document.dirty or ctx.document.legacy or ctx.document.legacy_paths;
    // A successful save can publish new flags even when the content is equal.
    // Refuse an exhausted revision before either the journal or target is written.
    if (changes_flags and ctx.document_revision == std.math.maxInt(u64)) return .failure(.failed);
    const resolved = if (c.arg) |path| resolvePath(ctx, path, true) catch return .failure(.invalid_arguments) else null;
    defer if (resolved) |target| ctx.allocator.free(target.path);
    // This is not a transaction over two files. The write-ahead journal keeps
    // "pending" until the destination is durable, so a crash between the two
    // writes restores the new declaration and reports it as unsaved instead of
    // silently losing it.
    persistHistory(ctx) catch return .failure(.failed);
    if (resolved) |target| {
        documents.saveExternal(&ctx.document, io_value, ctx.allocator, target.path) catch return .failure(.failed);
    } else {
        var data_dir = ctx.paths.openDataDir(io_value, ctx.allocator) catch return .failure(.failed);
        defer data_dir.close(io_value);
        documents.save(&ctx.document, io_value, ctx.allocator, data_dir, "documents/session.cut") catch return .failure(.failed);
    }
    var confirmed = true;
    if (changes_flags) {
        // The destination is durable now; confirm the marker. A failed
        // confirmation stays conservative ("still pending") and must not turn a
        // durable save into a reported failure.
        persistHistory(ctx) catch |err| {
            confirmed = false;
            std.debug.print("[doc-save] 恢复标记确认失败: {s}\n", .{@errorName(err)});
        };
        ctx.document_revision += 1;
    }
    ctx.status.set(if (confirmed) "文档已保存" else "文档已保存,恢复标记未更新");
    return .success;
}

fn setGain(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    const arg = c.arg orelse return .failure(.invalid_arguments);
    var parts = std.mem.tokenizeAny(u8, arg, " \t");
    const first = parts.next() orelse return .failure(.invalid_arguments);
    const second = parts.next();
    const id = if (second != null)
        documents.parseCompId(first) catch return .failure(.invalid_arguments)
    else
        ctx.document.firstGainId() orelse return .failure(.invalid_state);
    const before = for (ctx.document.nodes[0..ctx.document.count]) |node| {
        if (node.id == id and node.op == .gain) break node.value;
    } else return .failure(.invalid_arguments);
    candidate.document.setGainText(arg) catch return .failure(.invalid_arguments);
    const after = for (candidate.document.nodes[0..candidate.document.count]) |node| {
        if (node.id == id and node.op == .gain) break node.value;
    } else return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .gain_set = .{ .id = id, .before = before, .after = after } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("增益已更新");
    return .success;
}

fn reportAdded(ctx: *RuntimeContext, id: u64) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "已添加 c{d}", .{id}) catch return;
    ctx.status.set(text);
}

fn addInvert(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    const input = if (c.arg) |text|
        documents.parseCompId(text) catch return .failure(.invalid_arguments)
    else
        ctx.document.outputId() orelse return .failure(.invalid_state);
    const previous_output = ctx.document.outputId();
    const id = candidate.document.addInvert(input) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .add_invert = .{ .id = id, .input = input, .previous_output = previous_output } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    reportAdded(ctx, id);
    return .success;
}

fn addOver(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    const arg = c.arg orelse return .failure(.invalid_arguments);
    var parts = std.mem.tokenizeAny(u8, arg, " \t");
    const bottom_text = parts.next() orelse return .failure(.invalid_arguments);
    const top_text = parts.next() orelse return .failure(.invalid_arguments);
    const opacity_text = parts.next();
    if (parts.next() != null) return .failure(.invalid_arguments);
    const bottom = documents.parseCompId(bottom_text) catch return .failure(.invalid_arguments);
    const top = documents.parseCompId(top_text) catch return .failure(.invalid_arguments);
    const opacity = if (opacity_text) |text| std.fmt.parseFloat(f32, text) catch return .failure(.invalid_arguments) else 1;
    const previous_output = ctx.document.outputId();
    const id = candidate.document.addOver(bottom, top, opacity) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .add_over = .{ .id = id, .bottom = bottom, .top = top, .opacity = opacity, .previous_output = previous_output } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    reportAdded(ctx, id);
    return .success;
}

fn setOverOpacity(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    const arg = c.arg orelse return .failure(.invalid_arguments);
    var parts = std.mem.tokenizeAny(u8, arg, " \t");
    const id_text = parts.next() orelse return .failure(.invalid_arguments);
    const opacity_text = parts.next() orelse return .failure(.invalid_arguments);
    if (parts.next() != null) return .failure(.invalid_arguments);
    const id = documents.parseCompId(id_text) catch return .failure(.invalid_arguments);
    const opacity = std.fmt.parseFloat(f32, opacity_text) catch return .failure(.invalid_arguments);
    const before = for (ctx.document.nodes[0..ctx.document.count]) |node| {
        if (node.id == id and node.op == .over) break node.topOpacity();
    } else return .failure(.invalid_arguments);
    candidate.document.setOverOpacity(id, opacity) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .over_opacity_set = .{ .id = id, .before = before, .after = opacity } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("over 透明度已更新");
    return .success;
}

fn addResize(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    const arg = c.arg orelse return .failure(.invalid_arguments);
    var parts = std.mem.tokenizeAny(u8, arg, " \t");
    const input_text = parts.next() orelse return .failure(.invalid_arguments);
    const width_text = parts.next() orelse return .failure(.invalid_arguments);
    const height_text = parts.next() orelse return .failure(.invalid_arguments);
    if (parts.next() != null) return .failure(.invalid_arguments);
    const input = documents.parseCompId(input_text) catch return .failure(.invalid_arguments);
    const width = std.fmt.parseInt(u32, width_text, 10) catch return .failure(.invalid_arguments);
    const height = std.fmt.parseInt(u32, height_text, 10) catch return .failure(.invalid_arguments);
    const previous_output = ctx.document.outputId();
    const old_width = ctx.document.width;
    const old_height = ctx.document.height;
    const id = candidate.document.addResize(input, width, height) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .add_resize = .{
        .id = id,
        .input = input,
        .width = width,
        .height = height,
        .previous_output = previous_output,
        .old_width = old_width,
        .old_height = old_height,
    } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    reportAdded(ctx, id);
    return .success;
}

fn openImage(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const io_value = io(ctx) orelse return .failure(.not_ready);
    const path = c.arg orelse "pack://assets/examples/pngtest.png";
    var candidate = EditCandidate.init(ctx);
    var resource_dir = ctx.paths.openResourceDir(io_value) catch return .failure(.failed);
    defer resource_dir.close(io_value);
    var loaded = image.load(ctx.allocator, io_value, resource_dir, path) catch return .failure(.failed);
    defer loaded.deinit(ctx.allocator);
    candidate.document.setImage(path, loaded.width, loaded.height) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .replace_document = .{ .before = ctx.document, .after = candidate.document } }) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("图片已导入");
    return .success;
}

fn insertAsset(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const arg = c.arg orelse return .failure(.invalid_arguments);
    const id = std.fmt.parseInt(u64, std.mem.trim(u8, arg, " \t"), 10) catch return .failure(.invalid_arguments);
    const asset = ctx.assets.get(id) catch return .failure(.invalid_state);
    const source_uri = @import("vne").uri.parse(asset.source.uri) catch return .failure(.invalid_state);
    if (source_uri.root == .external) {
        const uri = source_uri;
        if (!(ctx.mounts.isPersistentExternal(uri) catch return .failure(.invalid_state))) {
            ctx.status.set("临时外部句柄不能直接插入;请显式选择原文件或导出受管快照");
            return .failure(.invalid_state);
        }
    }
    var loaded = image.decode(ctx.allocator, asset.bytes) catch return .failure(.failed);
    defer loaded.deinit(ctx.allocator);
    var candidate = EditCandidate.init(ctx);
    candidate.document.setImageSource(asset.source.uri, asset.source.content_hash, loaded.width, loaded.height) catch return .failure(.invalid_arguments);
    candidate.record(ctx, .{ .replace_document = .{ .before = ctx.document, .after = candidate.document } }) catch return .failure(.failed);
    retainLibraryAsset(ctx, asset) catch return .failure(.failed);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("素材 Source 已插入文档");
    std.debug.print("CUTRANS_ASSET_INSERT asset={d} kind={s} source={s}\n", .{ id, @tagName(asset.source.kind), asset.source.uri });
    return .success;
}

fn retainLibraryAsset(ctx: *RuntimeContext, asset: *const @import("assets.zig").Asset) !void {
    if (asset.source.kind != .library) return;
    const uri = try @import("vne").uri.parse(asset.source.uri);
    if (uri.root != .library) return error.InvalidLibrarySource;
    const id = std.fmt.parseInt(u64, uri.body, 10) catch return error.InvalidLibrarySource;
    // The Station may still own an older version after refresh. Adopt the
    // selected bytes and digest, never silently substitute the current pointer.
    try ctx.library.retainVersion(ctx, id, asset.source.content_hash, asset.bytes);
}

fn persistTasks(ctx: *RuntimeContext) !void {
    const io_value = io(ctx) orelse return error.IoNotReady;
    var dir = try ctx.paths.openDataDir(io_value, ctx.allocator);
    defer dir.close(io_value);
    try task_journal.save(&ctx.tasks, ctx.allocator, io_value, dir);
}

const ledger = @import("job_ledger.zig");

fn saveJob(ctx: *RuntimeContext, job: *const export_job.Job, task: @import("tasks.zig").Task) !void {
    const io_value = io(ctx) orelse return error.IoNotReady;
    var dir = try ctx.paths.openDataDir(io_value, ctx.allocator);
    defer dir.close(io_value);
    try ledger.save(job, task, ctx.allocator, io_value, dir);
}

fn projectTasks(ctx: *RuntimeContext) void {
    // Compatibility projection only. Per-job records are authoritative.
    persistTasks(ctx) catch |err| std.debug.print("[tasks-projection] {s}\n", .{@errorName(err)});
}

pub fn restore(ctx: *RuntimeContext) !usize {
    if (ctx.export_count != 0 or ctx.active_export != null or ctx.pending_finalize != null) return error.InvalidState;
    const io_value = io(ctx) orelse return error.IoNotReady;
    var dir = ctx.paths.openDataDirExisting(io_value) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close(io_value);
    try ctx.external_sources.restore(ctx);
    try ctx.library.restore(ctx);
    _ = try history_journal.load(&ctx.history, &ctx.document, ctx.allocator, io_value, dir);
    const legacy_recovered = try task_journal.load(&ctx.tasks, ctx.allocator, io_value, dir) orelse 0;
    var legacy_only_recovered: usize = 0;
    var recovery_events: [64]@import("tasks.zig").Event = undefined;
    const events = ctx.tasks.recentEvents(&recovery_events);
    for (events[0..@min(legacy_recovered, events.len)]) |event| {
        if ((try ledger.load(event.task_id, ctx.allocator, io_value, dir)) == null) legacy_only_recovered += 1;
    }
    var needs_archive = ctx.tasks.count == 0 and ctx.tasks.task_clock != 0;
    for (ctx.tasks.items[0..ctx.tasks.count]) |task| {
        if ((try ledger.load(task.id, ctx.allocator, io_value, dir)) == null) needs_archive = true;
    }
    // A projection made entirely from JobRecords is already reconstructible;
    // avoid manufacturing a new legacy archive on a read-only retry/rollback.
    if (needs_archive) try task_journal.archiveLegacy(ctx.allocator, io_value, dir);
    var archived: @import("tasks.zig").Registry = .{};
    _ = try task_journal.loadLegacyArchive(&archived, ctx.allocator, io_value, dir);
    ctx.tasks.task_clock = @max(ctx.tasks.task_clock, archived.task_clock);
    if (archived.event_clock > ctx.tasks.event_clock) {
        ctx.tasks.event_clock = archived.event_clock;
        ctx.tasks.event_count = 0; // Old ring indices do not belong to this clock.
    }
    const recovered = try ledger.loadAll(&ctx.tasks, ctx.allocator, io_value, dir);
    projectTasks(ctx);
    return legacy_only_recovered + recovered;
}

fn freezeSources(ctx: *RuntimeContext, job: *export_job.Job) !void {
    for (job.document.nodes[0..job.document.count]) |*node| {
        if (node.op != .image) continue;
        const handle = try ctx.assets.openVersion(ctx, node.asset(), if (node.asset_hash_present) node.asset_hash else null);
        defer ctx.assets.release(handle) catch {};
        const asset = try ctx.assets.get(handle);
        if (node.asset_hash_present and !std.mem.eql(u8, &node.asset_hash, &asset.source.content_hash)) return error.SourceContentMismatch;
        node.asset_hash = asset.source.content_hash;
        node.asset_hash_present = true;
        try retainLibraryAsset(ctx, asset);
    }
}

fn exportPng(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    _ = io(ctx) orelse return .failure(.not_ready);
    return admitJob(ctx, null, c.arg, false);
}

fn admitJob(ctx: *RuntimeContext, previous: ?*const export_job.Job, argument: ?[]const u8, retarget: bool) command.Result {
    _ = io(ctx) orelse return .failure(.not_ready);
    if (ctx.export_count + @intFromBool(ctx.active_export != null) == ctx.exports.len or ctx.pending_finalize != null) return .failure(.queue_full);
    // Reserve event identities for admission plus running/terminal transitions
    // of all queued jobs, before acknowledging work that could not finish.
    const reserved: u64 = @intCast((ctx.export_count + 1) * 2 + 1 + @intFromBool(ctx.active_export != null));
    if (ctx.tasks.event_clock > std.math.maxInt(u64) - reserved) return .failure(.queue_full);
    var candidate = ctx.tasks;
    const id = candidate.start() orelse return .failure(.queue_full);
    var job = if (previous) |old|
        export_job.Job.retry(old, id, argument) catch return .failure(.invalid_arguments)
    else
        export_job.Job.init(id, ctx.document, argument) catch return .failure(.invalid_arguments);
    if (previous == null) {
        job.origin = ctx.runtime_origin;
        job.origin.revision = ctx.document_revision;
        job.source_fingerprint = ctx.document.fingerprint();
    }
    if (job.explicit_path) {
        const resolved = resolvePath(ctx, job.path(), true) catch return .failure(.invalid_arguments);
        defer ctx.allocator.free(resolved.path);
        job.setTarget(resolved.path) catch return .failure(.invalid_arguments);
    } else {
        const target = std.fs.path.join(ctx.allocator, &.{ ctx.paths.data_dir, job.path() }) catch return .failure(.failed);
        defer ctx.allocator.free(target);
        job.setTarget(target) catch return .failure(.invalid_arguments);
    }
    const canonical_target = std.fs.path.resolve(ctx.allocator, &.{job.target()}) catch return .failure(.failed);
    defer ctx.allocator.free(canonical_target);
    job.setTarget(canonical_target) catch return .failure(.invalid_arguments);
    if (previous) |old| {
        const uri = if (job.explicit_path) @import("vne").uri.parse(job.path()) catch return .failure(.invalid_arguments) else null;
        if (uri != null and uri.?.root == .external and !retarget and !std.ascii.eqlIgnoreCase(old.target(), job.target()))
            return .failure(.invalid_arguments);
    }
    for (ctx.exports[0..ctx.export_count]) |*active| {
        if (std.ascii.eqlIgnoreCase(active.target(), job.target())) return .failure(.invalid_state);
    }
    if (ctx.active_export) |*active| if (std.ascii.eqlIgnoreCase(active.target(), job.target())) return .failure(.invalid_state);
    freezeSources(ctx, &job) catch |err| {
        std.debug.print("[export-admission] source validation: {s}\n", .{@errorName(err)});
        ctx.status.set("素材版本不可用，导出未受理；当前文档与输出保持原状");
        return .failure(.failed);
    };
    saveJob(ctx, &job, candidate.get(id).?) catch return .failure(.failed);
    // All fallible work precedes publication of the accepted identity/queue.
    ctx.tasks = candidate;
    ctx.exports[ctx.export_count] = job;
    ctx.export_count += 1;
    projectTasks(ctx);
    return .{ .code = .accepted, .task_id = id };
}

fn retryTask(c: command.Command, pointer: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(pointer));
    const text = std.mem.trim(u8, c.arg orelse return .failure(.invalid_arguments), " \t\r\n");
    const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    const id = std.fmt.parseInt(u64, text[0..split], 10) catch return .failure(.invalid_arguments);
    var target = std.mem.trim(u8, text[split..], " \t");
    const retarget = std.mem.startsWith(u8, target, "--retarget ");
    if (retarget) {
        target = std.mem.trim(u8, target["--retarget ".len..], " \t");
        if (target.len == 0) return .failure(.invalid_arguments);
    }
    const io_value = io(ctx) orelse return .failure(.not_ready);
    var dir = ctx.paths.openDataDir(io_value, ctx.allocator) catch return .failure(.failed);
    defer dir.close(io_value);
    const previous = (ledger.load(id, ctx.allocator, io_value, dir) catch return .failure(.failed)) orelse return .failure(.invalid_arguments);
    if (previous.task.state != .failed and previous.task.state != .cancelled and previous.task.state != .interrupted) return .failure(.invalid_state);
    return admitJob(ctx, &previous.job, if (target.len == 0) null else target, retarget);
}

fn removeExport(ctx: *RuntimeContext, index: usize) void {
    for (index + 1..ctx.export_count) |next| ctx.exports[next - 1] = ctx.exports[next];
    ctx.export_count -= 1;
}

fn completeRecord(ctx: *RuntimeContext, record: ledger.Record) !void {
    var candidate = ctx.tasks;
    const changed = switch (record.task.state) {
        .succeeded => candidate.succeed(record.task.id),
        .failed => candidate.fail(record.task.id, record.task.result orelse .failed),
        .cancelled => candidate.cancel(record.task.id),
        else => false,
    };
    if (!changed) return error.InvalidExportTaskState;
    saveJob(ctx, &record.job, candidate.get(record.task.id).?) catch |err| {
        ctx.pending_finalize = record;
        ctx.status.set("输出结果已确定，任务记录待保存；不会重新导出");
        return err;
    };
    ctx.tasks = candidate;
    ctx.pending_finalize = null;
    projectTasks(ctx);
}

fn failExport(ctx: *RuntimeContext, job: export_job.Job, err: anyerror) !void {
    var failed = job;
    failed.phase = .failed;
    failed.failure = .failed;
    failed.setError(@errorName(err));
    var task = ctx.tasks.get(job.task_id) orelse return error.MissingExportTask;
    task.state = .failed;
    task.result = .failed;
    try completeRecord(ctx, .{ .job = failed, .task = task });
    ctx.status.set("PNG 导出失败，原输出未被截断；详情见任务记录");
}

pub fn jobsPending(ctx: *const RuntimeContext) bool {
    return ctx.export_count != 0 or ctx.active_export != null or ctx.pending_finalize != null;
}

pub fn flushJobRecord(ctx: *RuntimeContext) !void {
    if (ctx.pending_finalize) |record| try completeRecord(ctx, record);
}

pub const Work = struct {
    job: export_job.Job,
    inputs: @import("export_inputs.zig").Inputs,

    pub fn deinit(self: *Work) void {
        self.inputs.deinit();
    }

    /// Uses only owned immutable inputs and the narrow cooperative token.
    /// No workspace/catalog/Context access is permitted on the render worker.
    pub fn compute(self: *Work, io_value: std.Io, cancel: *const std.atomic.Value(bool)) Computed {
        return .{ .prepared = self.prepare(io_value, cancel) catch |err| return .{ .failure = err } };
    }

    fn prepare(self: *Work, io_value: std.Io, cancel: *const std.atomic.Value(bool)) !image.PreparedPng {
        if (cancel.load(.acquire)) return error.Cancelled;
        var preview: render.Preview = .{ .cancel = cancel };
        defer preview.deinit(self.inputs.allocator);
        const frame = try preview.currentWithProvider(&self.job.document, self.inputs.allocator, self.inputs.provider());
        if (cancel.load(.acquire)) return error.Cancelled;
        var prepared = try image.preparePng(self.inputs.allocator, io_value, .cwd(), self.job.target(), .{ .width = frame.width, .height = frame.height, .pixels = frame.pixels });
        errdefer prepared.deinit(io_value);
        if (cancel.load(.acquire)) return error.Cancelled;
        return prepared;
    }
};

pub const Computed = struct {
    prepared: ?image.PreparedPng = null,
    failure: ?anyerror = null,
    pub fn deinit(self: *Computed, io_value: std.Io) void {
        if (self.prepared) |*prepared| prepared.deinit(io_value);
        self.* = .{};
    }
};

/// Called only by the session owner. Return ownership of captured bytes before
/// allowing expensive decode/render/encode outside the session lock.
pub fn beginExport(ctx: *RuntimeContext) !?Work {
    if (ctx.pending_finalize) |record| {
        try completeRecord(ctx, record);
        return null;
    }
    if (ctx.active_export != null or ctx.export_count == 0) return null;
    if (ctx.tasks.event_clock > std.math.maxInt(u64) - 2) return error.TaskClockOverflow;
    var job = ctx.exports[0];
    var inputs = @import("export_inputs.zig").captureLocked(ctx.allocator, ctx, &job.document, 64 * 1024 * 1024) catch |err| {
        removeExport(ctx, 0);
        try failExport(ctx, job, err);
        return null;
    };
    errdefer inputs.deinit();
    var running = ctx.tasks;
    if (!running.markRunning(job.task_id)) return error.InvalidExportTaskState;
    job.phase = .running;
    try saveJob(ctx, &job, running.get(job.task_id).?);
    ctx.tasks = running;
    removeExport(ctx, 0);
    ctx.active_export = job;
    ctx.active_cancel.store(false, .release);
    projectTasks(ctx);
    return Work{ .job = job, .inputs = inputs };
}

/// The owner performs cancellation check, durable prepared record and output
/// rename in one critical section. No cancellation can slip between them.
pub fn finishExport(ctx: *RuntimeContext, id: u64, result: *Computed) !void {
    return finishExportObserved(ctx, id, result, null);
}

const CommitObserver = struct {
    context: *anyopaque,
    after_commit: *const fn (*anyopaque, *RuntimeContext, u64) void,
};

fn finishExportObserved(ctx: *RuntimeContext, id: u64, result: *Computed, observer: ?CommitObserver) !void {
    var job = ctx.active_export orelse return error.MissingActiveExport;
    if (job.task_id != id) return error.StaleExportCompletion;
    defer ctx.active_export = null;
    if (job.cancel_requested) {
        job.phase = .cancelled;
        job.failure = .cancelled;
        var cancelled = ctx.tasks.get(id) orelse return error.MissingExportTask;
        cancelled.state = .cancelled;
        cancelled.result = .cancelled;
        try completeRecord(ctx, .{ .job = job, .task = cancelled });
        ctx.status.set("任务已取消，未提交本次输出");
        return;
    }
    if (result.failure) |err| return failExport(ctx, job, err);
    const prepared = if (result.prepared) |*value| value else return error.MissingPreparedOutput;
    job.phase = .prepared;
    job.output_hash = prepared.digest;
    job.output_size = prepared.size;
    saveJob(ctx, &job, ctx.tasks.get(job.task_id).?) catch |err| return failExport(ctx, job, err);
    ctx.active_export = job;
    prepared.commit(ctx.io.?) catch |err| return failExport(ctx, job, err);
    job.phase = .succeeded;
    ctx.active_export = job;
    if (observer) |probe| probe.after_commit(probe.context, ctx, job.task_id);
    var completed = ctx.tasks.get(job.task_id).?;
    completed.state = .succeeded;
    completed.result = .ok;
    try completeRecord(ctx, .{ .job = job, .task = completed });
    ctx.status.set("PNG 已导出并归档");
}

/// Manual Contexts (diagnostics/replay/tests) retain deterministic synchronous
/// pumping. Native Runtime takes/finishes under its owner and computes unlocked.
pub fn pumpJobs(ctx: *RuntimeContext) !void {
    return pumpJobsObserved(ctx, null);
}

fn pumpJobsObserved(ctx: *RuntimeContext, observer: ?CommitObserver) !void {
    var work = (try beginExport(ctx)) orelse return;
    defer work.deinit();
    var result = work.compute(ctx.io.?, &ctx.active_cancel);
    defer result.deinit(ctx.io.?);
    try finishExportObserved(ctx, work.job.task_id, &result, observer);
}

pub fn pump(ctx: *RuntimeContext) !void {
    try ctx.playback.pump(ctx);
    try pumpJobs(ctx);
}

fn cancelTask(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    _ = io(ctx) orelse return .failure(.not_ready);
    const id = if (c.arg) |text|
        std.fmt.parseInt(u64, text, 10) catch return .failure(.invalid_arguments)
    else if (ctx.active_export) |active| active.task_id else if (ctx.export_count > 0) ctx.exports[0].task_id else return .failure(.invalid_arguments);
    if (ctx.pending_finalize) |record| if (record.task.id == id) {
        ctx.status.set("该任务结果已确定，不能再取消");
        return .failure(.invalid_state);
    };
    if (ctx.active_export) |*active| {
        if (active.task_id == id) {
            if (active.phase != .running and active.phase != .prepared and active.phase != .queued) return .failure(.invalid_state);
            if (active.cancel_requested) return .success;
            var requested = active.*;
            requested.cancel_requested = true;
            saveJob(ctx, &requested, ctx.tasks.get(id).?) catch return .failure(.failed);
            active.* = requested;
            ctx.active_cancel.store(true, .release);
            ctx.status.set("取消已受理，正在安全边界停止");
            return .success;
        }
    }
    var index: ?usize = null;
    for (ctx.exports[0..ctx.export_count], 0..) |job, position| if (job.task_id == id) {
        index = position;
        break;
    };
    if (index) |position| {
        var candidate = ctx.tasks;
        if (!candidate.cancel(id)) return .failure(.invalid_state);
        var job = ctx.exports[position];
        job.phase = .cancelled;
        job.cancel_requested = true;
        job.failure = .cancelled;
        saveJob(ctx, &job, candidate.get(id).?) catch return .failure(.failed);
        ctx.tasks = candidate;
        removeExport(ctx, position);
        projectTasks(ctx);
        ctx.status.set("排队任务已取消");
        return .success;
    }
    // An identical request remains successful after durable cancellation.
    var dir = ctx.paths.openDataDir(ctx.io.?, ctx.allocator) catch return .failure(.failed);
    defer dir.close(ctx.io.?);
    const previous = (ledger.load(id, ctx.allocator, ctx.io.?, dir) catch return .failure(.failed)) orelse return .failure(.invalid_state);
    if (previous.task.state == .cancelled and previous.job.cancel_requested) return .success;
    return .failure(.invalid_state);
}

fn cancelAllTasks(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    _ = io(ctx) orelse return .failure(.not_ready);
    if (ctx.active_export) |active| {
        if (active.phase == .running or active.phase == .prepared or active.phase == .queued) {
            var buffer: [32]u8 = undefined;
            const arg = std.fmt.bufPrint(&buffer, "{d}", .{active.task_id}) catch return .failure(.invalid_arguments);
            const result = cancelTask(.{ .name = c.name, .arg = arg }, opaque_ptr);
            if (result.code != .ok) return result;
        }
    }
    var index = ctx.export_count;
    while (index > 0) {
        index -= 1;
        var buffer: [32]u8 = undefined;
        const arg = std.fmt.bufPrint(&buffer, "{d}", .{ctx.exports[index].task_id}) catch return .failure(.invalid_arguments);
        const result = cancelTask(.{ .name = c.name, .arg = arg }, opaque_ptr);
        if (result.code != .ok) return result;
    }
    ctx.status.set("已请求取消所有未完成任务");
    return .success;
}

fn listTasks(c: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    const after = if (c.arg) |text| std.fmt.parseInt(u64, text, 10) catch return .failure(.invalid_arguments) else 0;
    var dir = ctx.paths.openDataDir(ctx.io.?, ctx.allocator) catch return .failure(.failed);
    defer dir.close(ctx.io.?);
    const records = ledger.page(after, 32, ctx.allocator, ctx.io.?, dir) catch return .failure(.failed);
    defer ctx.allocator.free(records);
    for (records) |*record| std.debug.print("task={d} state={s} phase={s} output={s} error={s}\n", .{ record.task.id, @tagName(record.task.state), @tagName(record.job.phase), record.job.path(), record.job.errorText() });
    return .success;
}

fn undoCommand(_: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    if (!candidate.undo(ctx)) return .failure(.invalid_state);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("已撤销");
    return .success;
}

fn redoCommand(_: command.Command, opaque_ptr: *anyopaque) command.Result {
    const ctx: *RuntimeContext = @ptrCast(@alignCast(opaque_ptr));
    var candidate = EditCandidate.init(ctx);
    if (!candidate.redo(ctx)) return .failure(.invalid_state);
    candidate.commit(ctx) catch return .failure(.failed);
    ctx.status.set("已重做");
    return .success;
}

test "registered resident resource commands reach their owner without loading missing resources" {
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    register(ctx);
    const ensure_result = ctx.command.dispatch(.{ .name = "asset.ensure", .arg = "1 0000000000000000000000000000000000000000000000000000000000000000" });
    try std.testing.expectEqual(command.Code.invalid_state, ensure_result.code);
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "resource.acquire", .arg = "1 0000000000000000000000000000000000000000000000000000000000000000" }).code);
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "asset.check", .arg = "99999" }).code);
    try std.testing.expectEqual(@as(usize, 0), ctx.assets.count);
    try std.testing.expectEqual(@as(u64, 0), ctx.assets.revision);
}

pub fn register(ctx: *RuntimeContext) void {
    ctx.command.register("doc.open", open);
    ctx.command.register("doc.read", read);
    ctx.command.register("doc.write", write);
    ctx.command.register("doc.save", save);
    ctx.command.register("editor.gain.set", setGain);
    ctx.command.register("editor.invert.add", addInvert);
    ctx.command.register("editor.over.add", addOver);
    ctx.command.register("editor.over.opacity.set", setOverOpacity);
    ctx.command.register("editor.image.open", openImage);
    ctx.command.register("editor.asset.insert", insertAsset);
    ctx.command.register("editor.export.png", exportPng);
    ctx.command.register("task.cancel", cancelTask);
    ctx.command.register("task.cancel_all", cancelAllTasks);
    ctx.command.register("task.retry", retryTask);
    ctx.command.register("task.list", listTasks);
    ctx.command.register("editor.resize.add", addResize);
    ctx.command.register("history.undo", undoCommand);
    ctx.command.register("history.redo", redoCommand);
    ctx.command.register("playback.start", @import("playback.zig").handle);
    ctx.command.register("playback.status", @import("playback.zig").handle);
    ctx.command.register("playback.stop", @import("playback.zig").handle);
    ctx.command.register("asset.open", @import("assets.zig").dispatch);
    ctx.command.register("asset.ensure", @import("assets.zig").dispatch);
    ctx.command.register("resource.acquire", @import("assets.zig").dispatch);
    ctx.command.register("asset.check", @import("assets.zig").dispatch);
    ctx.command.register("asset.preview", @import("assets.zig").dispatch);
    ctx.command.register("asset.export", @import("assets.zig").dispatch);
    ctx.command.register("asset.release", @import("assets.zig").dispatch);
    ctx.command.register("asset.list", @import("assets.zig").dispatch);
    ctx.command.register("source.reauthorize", @import("external_sources.zig").dispatch);
    ctx.command.register("source.list", @import("external_sources.zig").dispatch);
    ctx.command.register("library.refresh", @import("resource_library.zig").dispatch);
    ctx.command.register("library.detach", @import("resource_library.zig").dispatch);
    ctx.command.register("library.create", @import("resource_library.zig").dispatch);
    ctx.command.register("library.folder.create", @import("resource_library.zig").dispatch);
    ctx.command.register("library.rename", @import("resource_library.zig").dispatch);
    ctx.command.register("library.move", @import("resource_library.zig").dispatch);
    ctx.command.register("library.remove", @import("resource_library.zig").dispatch);
    ctx.command.register("library.list", @import("resource_library.zig").dispatch);
}

test "shared commands create and retune a DAG" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    register(&ctx);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.invert.add", .arg = "c1" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.over.add", .arg = "c0 c2 0.25" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.over.opacity.set", .arg = "c3 0.5" }).code);
    try std.testing.expectEqual(@as(usize, 4), ctx.document.count);
    try std.testing.expectEqual(@as(f32, 0.5), ctx.document.nodes[3].topOpacity());
    try std.testing.expectEqual(command.Code.invalid_arguments, ctx.command.dispatch(.{ .name = "editor.over.add", .arg = "c0 c99" }).code);
}

test "runtime registry matches the shared command manifest" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    register(&ctx);
    const commands = @import("vne").commands;
    try std.testing.expectEqual(commands.forwarded.len + commands.runtime_only.len, ctx.command.table.count());
    for (commands.forwarded) |name| try std.testing.expect(ctx.command.table.contains(name));
    for (commands.runtime_only) |name| try std.testing.expect(ctx.command.table.contains(name));
}

test "history commands undo redo and truncate branches" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    register(&ctx);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.25" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(@as(f32, 0.8), ctx.document.nodes[1].value);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.redo" }).code);
    try std.testing.expectEqual(@as(f32, 0.25), ctx.document.nodes[1].value);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.invert.add", .arg = "c1" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(@as(usize, 2), ctx.document.count);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.redo" }).code);
    try std.testing.expectEqual(@as(usize, 3), ctx.document.count);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.5" }).code);
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "history.redo" }).code);
}

fn editTestFixture(ctx: *RuntimeContext, dir: std.Io.Dir) !u64 {
    ctx.init(std.testing.allocator);
    errdefer ctx.deinit();
    ctx.io = std.testing.io;
    const root = try dir.realPathFileAlloc(std.testing.io, ".", ctx.allocator);
    defer ctx.allocator.free(root);
    const resources = try std.fs.path.join(ctx.allocator, &.{ root, "resources" });
    defer ctx.allocator.free(resources);
    const data = try std.fs.path.join(ctx.allocator, &.{ root, "data" });
    defer ctx.allocator.free(data);
    ctx.paths = try @import("paths.zig").Paths.fromDirs(ctx.allocator, .portable, resources, data);
    try @import("mounts.zig").configure(ctx);
    register(ctx);
    try dir.createDirPath(std.testing.io, "resources/assets/examples");
    try dir.createDirPath(std.testing.io, "data");
    const text = try documents.emitAlloc(&ctx.document, ctx.allocator);
    defer ctx.allocator.free(text);
    try dir.writeFile(std.testing.io, .{ .sub_path = "resources/assets/examples/minimal.cut", .data = text });
    try dir.writeFile(std.testing.io, .{ .sub_path = "data/replacement.cut", .data = text });
    const pixels = [_]u8{ 10, 20, 30, 255 };
    try image.savePng(ctx.allocator, std.testing.io, dir, "resources/assets/examples/pngtest.png", .{ .width = 1, .height = 1, .pixels = @constCast(&pixels) });
    return ctx.assets.open(ctx, "pack://assets/examples/pngtest.png");
}

test "a temporary external snapshot URI cannot bypass persistent Source insertion rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const pack = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    try ctx.assets.exportSnapshot(pack, "session://snapshots/temporary");
    const snapshot_path = try ctx.paths.dataPath(ctx.allocator, "snapshots/temporary");
    defer ctx.allocator.free(snapshot_path);
    const grant = try ctx.mounts.grantExternal(ctx.allocator, snapshot_path, .read_only);
    var uri_buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "external://{d}", .{grant});
    const temporary = try ctx.assets.open(ctx, uri);
    try std.testing.expectEqual(@import("assets.zig").SourceKind.snapshot, (try ctx.assets.get(temporary)).source.kind);
    const before = ctx.document;
    const revision = ctx.document_revision;
    var arg_buffer: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buffer, "{d}", .{temporary});
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = arg }).code);
    try expectSameEditState(ctx, &before, 0, 0);
    try std.testing.expectEqual(revision, ctx.document_revision);
    try std.testing.expectEqual(@as(usize, 0), ctx.history.count);
    // Explicitly selecting the managed Session snapshot supplies a recoverable
    // locator even when Station reuses the same content identity and handle.
    const managed = try ctx.assets.open(ctx, "session://snapshots/temporary");
    const managed_arg = try std.fmt.bufPrint(&arg_buffer, "{d}", .{managed});
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = managed_arg }).code);
    try std.testing.expectEqualStrings("session://snapshots/temporary", ctx.document.nodes[0].asset());
}

fn libraryEditTestFixture(ctx: *RuntimeContext, dir: std.Io.Dir) !struct { library_id: u64, asset_id: u64, source_path: []u8 } {
    const pack = try editTestFixture(ctx, dir);
    errdefer ctx.deinit();
    const root = try dir.realPathFileAlloc(std.testing.io, ".", ctx.allocator);
    defer ctx.allocator.free(root);
    const path = try std.fs.path.join(ctx.allocator, &.{ root, "external-source.png" });
    errdefer ctx.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = (try ctx.assets.get(pack)).bytes });
    const id = try ctx.library.importExternal(ctx, path);
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "library://{d}", .{id});
    return .{ .library_id = id, .asset_id = try ctx.assets.open(ctx, uri), .source_path = path };
}

test "adopted library versions survive refresh undo cold restore and queued export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const source = try libraryEditTestFixture(ctx, tmp.dir);
    defer ctx.allocator.free(source.source_path);
    defer ctx.deinit();
    var arg_buffer: [32]u8 = undefined;
    const old_arg = try std.fmt.bufPrint(&arg_buffer, "{d}", .{source.asset_id});
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = old_arg }).code);
    const adopted = ctx.document;
    const adopted_revision = ctx.document_revision;
    const old_hash = adopted.nodes[0].asset_hash;
    const admitted = ctx.command.dispatch(.{ .name = "editor.export.png", .arg = "session://exports/retained-old.png" });
    try std.testing.expectEqual(command.Code.accepted, admitted.code);
    const replacement = try std.fs.path.join(ctx.allocator, &.{ std.fs.path.dirname(source.source_path).?, "replacement-source.png" });
    defer ctx.allocator.free(replacement);
    const new_pixels = [_]u8{ 91, 82, 73, 255 };
    try image.savePngExternal(ctx.allocator, std.testing.io, replacement, .{ .width = 1, .height = 1, .pixels = @constCast(&new_pixels) });
    const changed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, replacement, ctx.allocator, .limited(1024 * 1024));
    defer ctx.allocator.free(changed);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source.source_path, .data = changed });
    try std.testing.expect(try ctx.library.refresh(ctx, source.library_id));
    try std.testing.expectEqual(adopted.fingerprint(), ctx.document.fingerprint());
    try std.testing.expectEqual(adopted_revision, ctx.document_revision);
    {
        var preview: render.Preview = .{};
        defer preview.deinit(ctx.allocator);
        const frame = try preview.currentWithProvider(&ctx.document, ctx.allocator, render.workspaceProvider(ctx));
        try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, frame.pixels);
    }
    var uri_buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "library://{d}", .{source.library_id});
    const latest = try ctx.assets.open(ctx, uri);
    const latest_arg = try std.fmt.bufPrint(&arg_buffer, "{d}", .{latest});
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = latest_arg }).code);
    try std.testing.expect(!std.mem.eql(u8, &old_hash, &ctx.document.nodes[0].asset_hash));
    try std.Io.Dir.cwd().deleteFile(std.testing.io, source.source_path);
    try pumpJobs(ctx);
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, ctx.tasks.get(admitted.task_id.?).?.state);
    var dir = try ctx.paths.openDataDir(std.testing.io, ctx.allocator);
    defer dir.close(std.testing.io);
    var output = try image.load(ctx.allocator, std.testing.io, dir, "exports/retained-old.png");
    defer output.deinit(ctx.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, output.pixels);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(adopted.fingerprint(), ctx.document.fingerprint());
    const restored = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(restored);
    restored.init(ctx.allocator);
    defer restored.deinit();
    restored.io = std.testing.io;
    restored.paths = try @import("paths.zig").Paths.fromDirs(ctx.allocator, .portable, ctx.paths.resource_dir, ctx.paths.data_dir);
    try @import("mounts.zig").configure(restored);
    register(restored);
    _ = try restore(restored);
    {
        var preview: render.Preview = .{};
        defer preview.deinit(restored.allocator);
        const frame = try preview.currentWithProvider(&restored.document, restored.allocator, render.workspaceProvider(restored));
        try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, frame.pixels);
    }
    try std.testing.expectEqual(command.Code.ok, restored.command.dispatch(.{ .name = "history.redo" }).code);
    var preview: render.Preview = .{};
    defer preview.deinit(restored.allocator);
    const frame = try preview.currentWithProvider(&restored.document, restored.allocator, render.workspaceProvider(restored));
    try std.testing.expectEqualSlices(u8, &new_pixels, frame.pixels);
}

test "library retention and later history failure never publish a partial document adoption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const source = try libraryEditTestFixture(ctx, tmp.dir);
    defer ctx.allocator.free(source.source_path);
    defer ctx.deinit();
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.25" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.5" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    const before = ctx.document;
    const revision = ctx.document_revision;
    const journal = try tmp.dir.readFileAlloc(std.testing.io, "data/documents/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(journal);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/library/versions", .data = "retention blocked" });
    var buffer: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buffer, "{d}", .{source.asset_id});
    try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = arg }).code);
    try expectSameEditState(ctx, &before, 2, 1);
    try std.testing.expectEqual(revision, ctx.document_revision);
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "data/documents/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(unchanged);
    try std.testing.expectEqualStrings(journal, unchanged);
    try tmp.dir.deleteFile(std.testing.io, "data/library/versions");
    try tmp.dir.rename("data/documents/history.txt", tmp.dir, "data/documents/history.saved", std.testing.io);
    try tmp.dir.createDirPath(std.testing.io, "data/documents/history.txt");
    try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = arg }).code);
    try expectSameEditState(ctx, &before, 2, 1);
    try std.testing.expectEqual(revision, ctx.document_revision);
    const asset = try ctx.assets.get(source.asset_id);
    const relative = try @import("resource_versions.zig").relativePath(ctx.allocator, source.library_id, asset.source.content_hash);
    defer ctx.allocator.free(relative);
    var data_dir = try ctx.paths.openDataDir(std.testing.io, ctx.allocator);
    defer data_dir.close(std.testing.io);
    const retained = try data_dir.readFileAlloc(std.testing.io, relative, ctx.allocator, .limited(16 * 1024 * 1024));
    defer ctx.allocator.free(retained);
    try std.testing.expectEqualSlices(u8, asset.bytes, retained);
    try tmp.dir.deleteDir(std.testing.io, "data/documents/history.txt");
    try tmp.dir.rename("data/documents/history.saved", tmp.dir, "data/documents/history.txt", std.testing.io);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = arg }).code);
    try std.testing.expectEqual(revision + 1, ctx.document_revision);
}

test "legacy library Job admission retains bound bytes before publishing an accepted task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const source = try libraryEditTestFixture(ctx, tmp.dir);
    defer ctx.allocator.free(source.source_path);
    defer ctx.deinit();
    const asset = try ctx.assets.get(source.asset_id);
    try ctx.document.setImageSource(asset.source.uri, asset.source.content_hash, 1, 1); // Unretained legacy fixture.
    const before = ctx.document.fingerprint();
    const revision = ctx.document_revision;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/library/versions", .data = "retention blocked" });
    const c = command.Command{ .name = "editor.export.png", .arg = "session://exports/legacy-retained.png" };
    const refused = ctx.command.dispatch(c);
    try std.testing.expectEqual(command.Code.failed, refused.code);
    try std.testing.expect(refused.task_id == null);
    try std.testing.expectEqual(@as(u64, 0), ctx.tasks.task_clock);
    try std.testing.expectEqual(@as(usize, 0), ctx.export_count);
    try std.testing.expectEqual(before, ctx.document.fingerprint());
    try std.testing.expectEqual(revision, ctx.document_revision);
    try tmp.dir.deleteFile(std.testing.io, "data/library/versions");
    const accepted = ctx.command.dispatch(c);
    try std.testing.expectEqual(command.Code.accepted, accepted.code);
    try std.testing.expectEqual(@as(?u64, 1), accepted.task_id);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, source.source_path);
    try pumpJobs(ctx);
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, ctx.tasks.get(1).?.state);
    var dir = try ctx.paths.openDataDir(std.testing.io, ctx.allocator);
    defer dir.close(std.testing.io);
    var output = try image.load(ctx.allocator, std.testing.io, dir, "exports/legacy-retained.png");
    defer output.deinit(ctx.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, output.pixels);
}

test "output committed before record failure is finalized without writing output again" {
    const Probe = struct {
        dir: std.Io.Dir,
        failure: ?anyerror = null,
        const record = "data/tasks/jobs/00000000000000000001.json";
        const saved = "data/tasks/prepared-record.saved";
        fn block(pointer: *anyopaque, _: *RuntimeContext, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.run() catch |err| {
                self.failure = err;
            };
        }
        fn run(self: *@This()) !void {
            try self.dir.rename(record, self.dir, saved, std.testing.io);
            try self.dir.createDirPath(std.testing.io, record);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    ctx.document.width = 2;
    ctx.document.height = 2;
    const accepted = ctx.command.dispatch(.{ .name = "editor.export.png", .arg = "session://exports/commit.png" });
    try std.testing.expectEqual(command.Code.accepted, accepted.code);
    var probe = Probe{ .dir = tmp.dir };
    var failed = false;
    pumpJobsObserved(ctx, .{ .context = &probe, .after_commit = Probe.block }) catch {
        failed = true;
    };
    try std.testing.expect(probe.failure == null);
    try std.testing.expect(failed);
    try std.testing.expect(ctx.pending_finalize != null);
    try std.testing.expectEqual(@import("tasks.zig").State.running, ctx.tasks.get(accepted.task_id.?).?.state);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "data/exports/commit.png", ctx.allocator, .limited(4096));
    defer ctx.allocator.free(output);
    try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, output[0..8]);
    try tmp.dir.deleteDir(std.testing.io, Probe.record);
    try tmp.dir.rename(Probe.saved, tmp.dir, Probe.record, std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/exports/commit.png", .data = "user changed completed output" });
    try pumpJobs(ctx);
    try std.testing.expect(!jobsPending(ctx));
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, ctx.tasks.get(accepted.task_id.?).?.state);
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "data/exports/commit.png", ctx.allocator, .limited(4096));
    defer ctx.allocator.free(unchanged);
    try std.testing.expectEqualStrings("user changed completed output", unchanged);
    var dir = try ctx.paths.openDataDir(std.testing.io, ctx.allocator);
    defer dir.close(std.testing.io);
    const record = (try ledger.load(accepted.task_id.?, ctx.allocator, std.testing.io, dir)).?;
    try std.testing.expectEqual(export_job.Phase.succeeded, record.job.phase);
}

test "legacy archive preserves high water without its disposable projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    ctx.document.width = 2;
    ctx.document.height = 2;
    var dir = try ctx.paths.openDataDir(std.testing.io, ctx.allocator);
    defer dir.close(std.testing.io);
    var old: @import("tasks.zig").Registry = .{};
    old.task_clock = 499;
    const old_id = old.start().?;
    try std.testing.expect(old.succeed(old_id));
    try task_journal.save(&old, ctx.allocator, std.testing.io, dir);
    try std.testing.expectEqual(@as(usize, 0), try restore(ctx));
    try dir.deleteFile(std.testing.io, task_journal.journal_path);
    ctx.tasks.reset();
    try std.testing.expectEqual(@as(usize, 0), try restore(ctx));
    try std.testing.expectEqual(@as(u64, 500), ctx.tasks.task_clock);
    const accepted = ctx.command.dispatch(.{ .name = "editor.export.png", .arg = "session://exports/legacy-clock.png" });
    try std.testing.expectEqual(command.Code.accepted, accepted.code);
    try std.testing.expectEqual(@as(?u64, 501), accepted.task_id);
    try pumpJobs(ctx);
    // A stale compatibility projection cannot downgrade an authoritative
    // succeeded JobRecord or inflate the number of interrupted jobs.
    var stale: @import("tasks.zig").Registry = .{};
    try stale.put(.{ .id = 501, .state = .running });
    try task_journal.save(&stale, ctx.allocator, std.testing.io, dir);
    try std.testing.expectEqual(@as(usize, 0), try restore(ctx));
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, ctx.tasks.get(501).?.state);
    var events: [4]@import("tasks.zig").Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), ctx.tasks.recentEvents(&events).len);
    var archive: @import("tasks.zig").Registry = .{};
    _ = try task_journal.loadLegacyArchive(&archive, ctx.allocator, std.testing.io, dir);
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, archive.get(500).?.state);
}

test "queued output conflict includes normalized dot path aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    try std.testing.expectEqual(command.Code.accepted, ctx.command.dispatch(.{ .name = "editor.export.png", .arg = "session://exports/same.png" }).code);
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "editor.export.png", .arg = "session://exports/./same.png" }).code);
    try std.testing.expectEqual(@as(u64, 1), ctx.tasks.task_clock);
    try std.testing.expectEqual(@as(usize, 1), ctx.export_count);
}

test "export admission reserves identities for all durable state transitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    ctx.document.width = 2;
    ctx.document.height = 2;
    ctx.tasks.event_clock = std.math.maxInt(u64) - 2;
    const refused = ctx.command.dispatch(.{ .name = "editor.export.png" });
    try std.testing.expectEqual(command.Code.queue_full, refused.code);
    try std.testing.expectEqual(@as(u64, 0), ctx.tasks.task_clock);
    try std.testing.expect(!jobsPending(ctx));
    ctx.tasks.event_clock = std.math.maxInt(u64) - 3;
    try std.testing.expectEqual(command.Code.accepted, ctx.command.dispatch(.{ .name = "editor.export.png" }).code);
    try pumpJobs(ctx);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.tasks.event_clock);
    try std.testing.expectEqual(@import("tasks.zig").State.succeeded, ctx.tasks.get(1).?.state);
}

fn expectSameEditState(ctx: *const RuntimeContext, doc: *const documents.Document, count: usize, cursor: usize) !void {
    try std.testing.expectEqual(doc.fingerprint(), ctx.document.fingerprint());
    try std.testing.expectEqual(doc.nodeIdHighWater(), ctx.document.nodeIdHighWater());
    try std.testing.expectEqual(doc.dirty, ctx.document.dirty);
    try std.testing.expectEqual(doc.legacy, ctx.document.legacy);
    try std.testing.expectEqual(doc.legacy_paths, ctx.document.legacy_paths);
    try std.testing.expectEqual(count, ctx.history.count);
    try std.testing.expectEqual(cursor, ctx.history.cursor);
}

const record_test_commands = [_]command.Command{
    .{ .name = "editor.gain.set", .arg = "c1 0.5" },
    .{ .name = "editor.invert.add", .arg = "c1" },
    .{ .name = "editor.over.add", .arg = "c0 c1 0.5" },
    .{ .name = "editor.over.opacity.set", .arg = "c2 0.5" },
    .{ .name = "editor.resize.add", .arg = "c1 2 2" },
    .{ .name = "doc.open" },
    .{ .name = "doc.write", .arg = "session://replacement.cut" },
    .{ .name = "editor.image.open", .arg = "pack://assets/examples/pngtest.png" },
};

test "all document candidates preserve state and redo history when journal persistence fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const asset = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.over.add", .arg = "c0 c1" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.25" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    const before = ctx.document;
    const before_revision = ctx.document_revision;
    const valid_journal = try tmp.dir.readFileAlloc(std.testing.io, "data/documents/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(valid_journal);
    // A real filesystem failure, after successful edits have already produced
    // a valid journal and a redo branch. Keep the valid bytes as evidence.
    try tmp.dir.rename("data/documents", tmp.dir, "history-backup", std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/documents", .data = "deliberately blocks persistence" });
    for (record_test_commands) |c| {
        try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(c).code);
        try expectSameEditState(ctx, &before, 2, 1);
        try std.testing.expectEqual(before_revision, ctx.document_revision);
        try std.testing.expectEqual(@as(f32, 0.25), ctx.history.entries[1].gain_set.after);
    }
    var asset_arg: [32]u8 = undefined;
    const inserted = ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = try std.fmt.bufPrint(&asset_arg, "{d}", .{asset}) });
    try std.testing.expectEqual(command.Code.failed, inserted.code);
    try expectSameEditState(ctx, &before, 2, 1);
    try std.testing.expectEqual(before_revision, ctx.document_revision);
    inline for (.{ "history.undo", "history.redo" }) |name| {
        try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(.{ .name = name }).code);
        try expectSameEditState(ctx, &before, 2, 1);
        try std.testing.expectEqual(before_revision, ctx.document_revision);
    }
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "history-backup/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(saved);
    try std.testing.expectEqualStrings(valid_journal, saved);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/save-target.cut", .data = "preserve external target" });
    try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(.{ .name = "doc.save", .arg = "session://save-target.cut" }).code);
    const target = try tmp.dir.readFileAlloc(std.testing.io, "data/save-target.cut", ctx.allocator, .limited(1024));
    defer ctx.allocator.free(target);
    try std.testing.expectEqualStrings("preserve external target", target);
    try expectSameEditState(ctx, &before, 2, 1);
    try std.testing.expectEqual(before_revision, ctx.document_revision);

    try tmp.dir.deleteFile(std.testing.io, "data/documents");
    try tmp.dir.rename("history-backup", tmp.dir, "data/documents", std.testing.io);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.redo" }).code);
    try std.testing.expectEqual(@as(f32, 0.25), ctx.document.nodes[1].value);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.7" }).code);
    try std.testing.expectEqual(@as(usize, 2), ctx.history.count);
    try std.testing.expectEqual(command.Code.invalid_state, ctx.command.dispatch(.{ .name = "history.redo" }).code);
}

test "history capacity and invalid arguments reject edits before publishing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    const asset = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    _ = try ctx.document.addOver(0, 1, 1);
    for (0..history.History.capacity) |_|
        try ctx.history.record(.{ .gain_set = .{ .id = 1, .before = 0.8, .after = 0.8 } });
    const before = ctx.document;
    const before_revision = ctx.document_revision;
    for (record_test_commands) |c| {
        try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(c).code);
        try expectSameEditState(ctx, &before, history.History.capacity, history.History.capacity);
        try std.testing.expectEqual(before_revision, ctx.document_revision);
    }
    var asset_arg: [32]u8 = undefined;
    try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = try std.fmt.bufPrint(&asset_arg, "{d}", .{asset}) }).code);
    try expectSameEditState(ctx, &before, history.History.capacity, history.History.capacity);
    try std.testing.expectEqual(before_revision, ctx.document_revision);
    const invalid = [_]command.Command{
        .{ .name = "editor.gain.set", .arg = "c1 nan" },
        .{ .name = "editor.gain.set", .arg = "c1 inf" },
        .{ .name = "editor.over.add", .arg = "c0 c1 nan" },
        .{ .name = "editor.over.opacity.set", .arg = "c2 nan" },
        .{ .name = "editor.resize.add", .arg = "c1 0 1" },
        .{ .name = "editor.invert.add", .arg = "c99" },
    };
    for (invalid) |c| {
        try std.testing.expectEqual(command.Code.invalid_arguments, ctx.command.dispatch(c).code);
        try expectSameEditState(ctx, &before, history.History.capacity, history.History.capacity);
        try std.testing.expectEqual(before_revision, ctx.document_revision);
    }
}

test "successful legacy edits publish revisions and reject an ABA candidate" {
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    register(ctx);
    const initial_fingerprint = ctx.document.fingerprint();
    try std.testing.expectEqual(@as(u64, 1), ctx.document_revision);
    // Equal content is still a committed edit/history transition.
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.8" }).code);
    try std.testing.expectEqual(initial_fingerprint, ctx.document.fingerprint());
    try std.testing.expectEqual(@as(u64, 2), ctx.document_revision);
    var candidate = EditCandidate.init(ctx);
    try candidate.document.setGain(1, 0.5);
    try candidate.record(ctx, .{ .gain_set = .{ .id = 1, .before = 0.8, .after = 0.5 } });
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.redo" }).code);
    try std.testing.expectEqual(@as(u64, 4), ctx.document_revision);
    // Content, history position and dirty match again, but this candidate was
    // prepared before two publications and must not be accepted as current.
    try std.testing.expectEqual(initial_fingerprint, ctx.document.fingerprint());
    try std.testing.expectError(error.StaleEditCandidate, candidate.commit(ctx));
    try std.testing.expectEqual(@as(u64, 4), ctx.document_revision);
    try std.testing.expectEqual(@as(f32, 0.8), ctx.document.nodes[1].value);
    try std.testing.expectEqual(command.Code.invalid_arguments, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 nan" }).code);
    try std.testing.expectEqual(@as(u64, 4), ctx.document_revision);
}

test "document replacement and saved flag transitions advance revision exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.8" }).code);
    try std.testing.expectEqual(@as(u64, 2), ctx.document_revision);
    try std.testing.expect(ctx.document.dirty);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.save" }).code);
    try std.testing.expectEqual(@as(u64, 3), ctx.document_revision);
    try std.testing.expect(!ctx.document.dirty);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.save" }).code);
    try std.testing.expectEqual(@as(u64, 3), ctx.document_revision);
    // Opening/replacing an equal document still publishes a new edit boundary.
    const fingerprint = ctx.document.fingerprint();
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.open", .arg = "session://replacement.cut" }).code);
    try std.testing.expectEqual(fingerprint, ctx.document.fingerprint());
    try std.testing.expectEqual(@as(u64, 4), ctx.document_revision);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.write", .arg = "session://replacement.cut" }).code);
    try std.testing.expectEqual(@as(u64, 5), ctx.document_revision);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/legacy.cut", .data = "resolution=1920x1080\nfps=30\nnodes:\nc0=testsrc{}\nc1=gain{ in:c0,value:0.8 }\noutput=c1\n" });
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.open", .arg = "session://legacy.cut" }).code);
    try std.testing.expect(ctx.document.legacy);
    try std.testing.expectEqual(@as(u64, 6), ctx.document_revision);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "doc.save" }).code);
    try std.testing.expect(!ctx.document.legacy);
    try std.testing.expectEqual(@as(u64, 7), ctx.document_revision);
}

test "revision exhaustion rejects candidates and save before writing either file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = try std.testing.allocator.create(RuntimeContext);
    defer std.testing.allocator.destroy(ctx);
    _ = try editTestFixture(ctx, tmp.dir);
    defer ctx.deinit();
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.25" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "editor.gain.set", .arg = "c1 0.5" }).code);
    try std.testing.expectEqual(command.Code.ok, ctx.command.dispatch(.{ .name = "history.undo" }).code);
    const before = ctx.document;
    const journal_before = try tmp.dir.readFileAlloc(std.testing.io, "data/documents/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(journal_before);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/save-target.cut", .data = "keep target" });
    ctx.document_revision = std.math.maxInt(u64);
    const commands = [_]command.Command{
        .{ .name = "editor.gain.set", .arg = "c1 0.7" },
        .{ .name = "editor.invert.add", .arg = "c1" },
        .{ .name = "history.undo" },
        .{ .name = "history.redo" },
        .{ .name = "doc.open" },
        .{ .name = "doc.write", .arg = "session://replacement.cut" },
        .{ .name = "doc.save", .arg = "session://save-target.cut" },
    };
    for (commands) |c| {
        try std.testing.expectEqual(command.Code.failed, ctx.command.dispatch(c).code);
        try std.testing.expectEqual(std.math.maxInt(u64), ctx.document_revision);
        try expectSameEditState(ctx, &before, 2, 1);
    }
    const journal_after = try tmp.dir.readFileAlloc(std.testing.io, "data/documents/history.txt", ctx.allocator, .limited(128 * 1024));
    defer ctx.allocator.free(journal_after);
    try std.testing.expectEqualStrings(journal_before, journal_after);
    const target = try tmp.dir.readFileAlloc(std.testing.io, "data/save-target.cut", ctx.allocator, .limited(1024));
    defer ctx.allocator.free(target);
    try std.testing.expectEqualStrings("keep target", target);
}
