const std = @import("std");
const nanoui = @import("nanoui");
const abi = @import("vne").abi;
const vm_client = @import("vm_client");
const model = @import("nanoui_model.zig");
const view = @import("nanoui_view.zig");
const library = @import("nanoui_library");

const ui = nanoui.ui;

fn require(result: @import("vne").command.Result) !void {
    if (result.code != .ok and result.code != .accepted) return error.CommandFailed;
}

fn openAsset(state: *model.State, uri: []const u8) !u64 {
    try require(state.ctx.command.dispatch(.{ .name = "asset.open", .arg = uri }));
    try vm_client.syncAssets(&state.ctx);
    for (state.ctx.asset_view.items[0..state.ctx.asset_view.count]) |item| {
        if (std.mem.eql(u8, item.source, uri)) return item.handle;
    }
    return error.AssetMirrorMissing;
}

fn previewAndInsert(state: *model.State, handle: u64) !void {
    var frame = try vm_client.previewAsset(&state.ctx, handle, null);
    defer frame.deinit(state.allocator);
    if (frame.width != 91 or frame.height != 69) return error.AssetPreviewMismatch;
    try state.editor.insertHandle(handle);
}

fn waitForJobs(state: *model.State, tester: *ui.Tester) !void {
    for (0..6000) |_| {
        state.console.refreshJobs() catch {};
        if (state.console.jobs) |jobs| {
            if (jobs.value.active_count == 0 and !jobs.value.record_pending) return;
        }
        tester.frame();
        try std.Io.sleep(state.ctx.io.?, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    }
    return error.JobCompletionTimeout;
}

fn verifyExport(state: *model.State) !void {
    const path = try state.ctx.paths.dataPath(state.allocator, "exports/output.png");
    defer state.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(state.ctx.io.?, path, state.allocator, .limited(16 * 1024 * 1024));
    defer state.allocator.free(bytes);
    const decoded = try vm_client.imageDimensions(state.allocator, bytes);
    if (decoded.width != 1920 or decoded.height != 1080) return error.ExportDimensionsMismatch;
}

fn waitForFile(state: *model.State, path: []const u8) !void {
    const io = state.ctx.io orelse return error.IoNotReady;
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        return;
    }
    return error.ReconnectMarkerTimeout;
}

fn reconnectDemo(state: *model.State) !void {
    const io = state.ctx.io orelse return error.IoNotReady;
    const restarted = try std.fs.path.join(state.allocator, &.{ state.ctx.paths.data_dir, "reconnect.host-restarted" });
    defer state.allocator.free(restarted);
    std.debug.print("CUTRANS_RECONNECT_READY\n", .{});
    if (std.c.getenv("CUTRANS_RECONNECT_AUTO") == null) {
        try waitForFile(state, restarted);
        try vm_client.reconnect(&state.ctx);
        std.debug.print("CUTRANS_RECONNECT_OK\n", .{});
        return;
    }
    const lost = try std.fs.path.join(state.allocator, &.{ state.ctx.paths.data_dir, "reconnect.host-lost" });
    defer state.allocator.free(lost);
    try waitForFile(state, lost);
    vm_client.pump(&state.ctx) catch {};
    const unknown = state.ctx.command.dispatch(.{ .name = "task.list" });
    if (unknown.code != .not_ready) return error.UnknownCommandWasRetried;
    std.debug.print("CUTRANS_COMMAND_UNKNOWN\n", .{});
    std.debug.print("CUTRANS_RECONNECT_LOST_DETECTED\n", .{});
    try waitForFile(state, restarted);
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        vm_client.pump(&state.ctx) catch {
            std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        std.debug.print("CUTRANS_RECONNECT_OK\n", .{});
        return;
    }
    return error.AutoReconnectTimeout;
}

fn unknownResultDemo(state: *model.State) !void {
    const io = state.ctx.io orelse return error.IoNotReady;
    const before = state.ctx.document.count;
    const pending = state.ctx.command.dispatch(.{ .name = "editor.invert.add" });
    if (pending.code != .not_ready or !vm_client.hasPending()) return error.UnknownResultPendingMissing;
    const after_lost = state.ctx.document.count;
    if (after_lost != before + 1) return error.UnknownResultCommitNotObserved;
    std.debug.print("CUTRANS_UNKNOWN_PENDING nodes_before={d} nodes_after={d}\n", .{ before, after_lost });
    const restarted = try std.fs.path.join(state.allocator, &.{ state.ctx.paths.data_dir, "unknown.host-restarted" });
    defer state.allocator.free(restarted);
    try waitForFile(state, restarted);
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        vm_client.pump(&state.ctx) catch {};
        if (!vm_client.hasPending()) break;
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    if (vm_client.hasPending()) return error.UnknownResultNotCleared;
    if (state.ctx.document.count != after_lost) return error.UnknownResultAppliedTwice;
    std.debug.print("CUTRANS_UNKNOWN_CLEARED status={s}\n", .{state.ctx.status.get()});
    const recovered = state.ctx.command.dispatch(.{ .name = "editor.invert.add" });
    if (recovered.code != .ok) return error.UnknownResultRecoveryFailed;
    const after_recovery = state.ctx.document.count;
    if (after_recovery != after_lost + 1) return error.UnknownResultRecoveryMiscount;
    std.debug.print("CUTRANS_UNKNOWN_NODES after_lost={d} after_recovery={d}\n", .{ after_lost, after_recovery });
    std.debug.print("CUTRANS_UNKNOWN_RECOVERED\n", .{});
    std.debug.print("CUTRANS_UNKNOWN_DEMO_DONE\n", .{});
}

fn unknownResultExitDemo(state: *model.State) !void {
    const before = state.ctx.document.count;
    const pending = state.ctx.command.dispatch(.{ .name = "editor.invert.add" });
    if (pending.code != .not_ready or !vm_client.hasPending()) return error.UnknownResultPendingMissing;
    if (state.ctx.document.count != before + 1) return error.UnknownResultCommitNotObserved;
    std.debug.print("CUTRANS_UNKNOWN_PENDING nodes_before={d} nodes_after={d}\n", .{ before, state.ctx.document.count });
    std.debug.print("CUTRANS_UNKNOWN_EXIT_PENDING\n", .{});
}

fn verify(state: *model.State, config: *const abi.ShellConfig) !void {
    if (std.c.getenv("CUTRANS_UNKNOWN_RESULT_EXIT") != null) {
        try unknownResultExitDemo(state);
        return;
    }
    if (std.c.getenv("CUTRANS_UNKNOWN_RESULT_DEMO") != null) {
        try unknownResultDemo(state);
        return;
    }
    if (std.c.getenv("CUTRANS_RECONNECT_DEMO") != null or std.c.getenv("CUTRANS_RECONNECT_AUTO") != null) try reconnectDemo(state);
    state.showPage(.home);
    var tester: ui.Tester = undefined;
    try tester.init(state.allocator, .init(state, model.State.view), .{
        .width = 1280,
        .height = 800,
        .scale = 1,
        .theme = view.theme(),
    });
    defer tester.deinit();
    if (!tester.hasText("声明式 VM 与多域创作工作台")) return error.DesktopHomeMissing;
    if (!tester.hasText("最大化/还原") or !tester.hasText("安全退出")) return error.DesktopChromeMissing;
    try tester.clickText("编辑器");
    const preview_fingerprint = state.ctx.document.fingerprint();
    var preview_a = try vm_client.previewFrame(&state.ctx, preview_fingerprint, state.allocator);
    defer preview_a.deinit(state.allocator);
    var preview_b = try vm_client.previewFrame(&state.ctx, preview_fingerprint, state.allocator);
    defer preview_b.deinit(state.allocator);
    if (preview_a.width == 0 or preview_a.height == 0 or preview_a.pixels.len != preview_a.width * preview_a.height * 4) return error.PreviewFrameInvalid;
    if (preview_a.generation != preview_b.generation or !std.mem.eql(u8, preview_a.pixels, preview_b.pixels)) return error.PreviewCacheMismatch;
    var preview_info: abi.PreviewInfo = undefined;
    if (state.api.preview_info(state.api.context, preview_fingerprint, &preview_info) != abi.Status.ok) return error.PreviewInfoFailed;
    var tiny: [4]u8 = undefined;
    var preview_required: usize = 0;
    if (state.api.preview_read(state.api.context, preview_fingerprint, &tiny, tiny.len, &preview_required) != abi.Status.buffer_too_small or preview_required != preview_info.bytes_len) return error.PreviewShortReadMismatch;
    std.debug.print("CUTRANS_PREVIEW_OK width={d} height={d} generation={d} bytes={d} epoch={x}:{x} revision={d} cache=1 short_buffer=1\n", .{ preview_a.width, preview_a.height, preview_a.generation, preview_a.pixels.len, preview_a.epoch_hi, preview_a.epoch_lo, preview_info.revision });
    try tester.clickText("添加 invert");
    if (state.api.preview_info(state.api.context, preview_fingerprint, &preview_info) != abi.Status.invalid_state) return error.PreviewStaleAccepted;
    if (state.ctx.document.count != 3) return error.EditorInsertFailed;
    try tester.clickText("撤销");
    if (state.ctx.document.count != 2) return error.EditorUndoFailed;
    try tester.clickText("重做");
    if (state.ctx.document.count != 3) return error.EditorRedoFailed;
    try tester.clickText("导出 PNG");
    try waitForJobs(state, &tester);
    try verifyExport(state);
    std.debug.print("CUTRANS_NANOUI_EDITOR_OK edit=1 undo=1 redo=1 export=1\n", .{});

    try tester.clickText("资源库");
    const resource_dir = state.ctx.paths.resource_dir;
    const packed_path = try std.fs.path.join(state.allocator, &.{ resource_dir, "assets/examples/pngtest.png" });
    defer state.allocator.free(packed_path);
    // A Pack asset is managed evidence, not an external source. Copy it to the
    // host temp directory so the test exercises the same external port as a
    // user's file instead of asking register_file to import the Pack itself.
    const image_bytes = try std.Io.Dir.cwd().readFileAlloc(state.ctx.io.?, packed_path, state.allocator, .limited(16 * 1024 * 1024));
    defer state.allocator.free(image_bytes);
    const temp_value = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse return error.TempDirectoryUnavailable;
    const temp_root = std.mem.span(temp_value);
    const path = try std.fs.path.join(state.allocator, &.{ temp_root, "cutrans-verify-import.png" });
    defer state.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(state.ctx.io.?, .{ .sub_path = path, .data = image_bytes });
    defer std.Io.Dir.cwd().deleteFile(state.ctx.io.?, path) catch {};
    _ = try state.library.importExternal(path);
    if (state.library.preview == null) return error.LibraryPreviewMissing;
    tester.frame();
    try tester.clickText("插入到文档");
    if (state.ctx.document.count != 1 or state.ctx.document.nodes[0].op != .image) return error.LibraryInsertFailed;
    const library_id = state.library.selected_library;

    const pack_handle = try openAsset(state, "pack://assets/examples/pngtest.png");
    try previewAndInsert(state, pack_handle);
    const snapshot_uri = "session://snapshots/asset-desktop";
    var export_buffer: [160]u8 = undefined;
    const export_arg = try std.fmt.bufPrint(&export_buffer, "{d} {s}", .{ pack_handle, snapshot_uri });
    try require(state.ctx.command.dispatch(.{ .name = "asset.export", .arg = export_arg }));
    const snapshot_handle = try openAsset(state, snapshot_uri);
    try previewAndInsert(state, snapshot_handle);
    if (!std.mem.startsWith(u8, state.ctx.document.nodes[0].asset(), "session://")) return error.SnapshotSourceMismatch;

    try state.library.refreshLibrary(library_id);
    try state.library.detachLibrary(library_id);
    var create_buffer: [64]u8 = undefined;
    const create_arg = try std.fmt.bufPrint(&create_buffer, "{d} created.png", .{state.library.selected_handle});
    try require(state.ctx.command.dispatch(.{ .name = "library.create", .arg = create_arg }));
    try vm_client.syncLibrary(&state.ctx);
    const created = state.ctx.library_view.findResource(2) orelse return error.LibraryDirectoryMissing;
    if (created.kind.? != .owned or created.provenance.? != .created) return error.LibraryCreateMismatch;
    const folder = try state.library.createFolder(0, "素材");
    const child = try state.library.createFolder(folder, "角色");
    if (state.library.moveLibrary(folder, child)) |_| return error.LibraryFolderCycleAccepted else |_| {}
    try state.library.moveLibrary(2, child);
    try state.library.beginRename(child);
    state.library.rename_buffer.set("主角");
    try state.library.applyRename();
    try state.library.beginRename(2);
    state.library.rename_buffer.set("renamed.png");
    try state.library.applyRename();
    try state.library.selectLibrary(2);
    try state.editor.insertHandle(state.library.selected_handle);
    if (!std.mem.eql(u8, state.ctx.document.nodes[0].asset(), "library://2") or !state.ctx.document.nodes[0].asset_hash_present) return error.AssetDocumentMismatch;
    const editor_nodes = state.ctx.document.count;
    try state.editor.importExternal(path);
    if (state.ctx.document.count != editor_nodes or std.mem.indexOf(u8, state.ctx.status.get(), "素材已插入") == null) return error.EditorImportFailed;
    std.debug.print("CUTRANS_EDITOR_IMPORT_OK register_file=1\n", .{});
    std.debug.print("CUTRANS_SHELL_ASSETS_OK selected=1 preview=91x69 inserted=1 source_uri=1 snapshot=1 library=1 catalog_unloaded=1 folder_ops=1\n", .{});

    try tester.clickText("CLI");
    state.console.input.set("history.undo");
    state.console.submitLine();
    if (state.console.history_count == 0) return error.ConsoleHistoryMissing;
    try tester.clickText("任务");
    if (!tester.containsText("attempt")) return error.JobViewMissing;

    state.showPage(.editor);
    tester.resize(1120, 740);
    tester.frame();
    try library.verifyD3D(&tester, state.allocator);
    try library.verifyDynamicD3D(state.allocator);
    state.confirmPresent();
    std.debug.print("CUTRANS_NANOUI_DESKTOP_OK editor=1 export=1 library=1 cli=1 jobs=1\n", .{});
    _ = config;
}

fn verifyExit(state: *model.State, hooks: *@import("shell").client.ExitHooks) !void {
    state.showPage(.home);
    var tester: ui.Tester = undefined;
    try tester.init(state.allocator, .init(state, model.State.view), .{
        .width = 1280,
        .height = 800,
        .scale = 1,
        .theme = view.theme(),
    });
    defer tester.deinit();
    if (!tester.hasText("退出虚拟环境…")) return error.ExitEntryMissing;
    const text_id = try state.library.createText("safe-exit-draft");
    if (text_id == 0) return error.DraftCreateFailed;
    try state.library.work.?.editor.?.editor.paste("安全退出时只保存草稿，不自动提交正文");
    state.showPage(.library);
    // Let the frame process the paste before forcing the idle-debounced draft.
    tester.frame();
    try state.library.work.?.pump(true);
    var settled = false;
    for (0..200) |_| {
        tester.frame();
        if (state.library.work.?.pending == null and state.library.work.?.editor.?.draft_revision != 0) {
            settled = true;
            break;
        }
    }
    if (!settled) return error.DraftNotPersisted;
    if (state.library.work.?.editor.?.work_revision != 1) return error.DraftWasCommitted;
    state.showPage(.home);
    tester.frame();

    const documents = try state.ctx.paths.dataPath(state.allocator, "documents");
    defer state.allocator.free(documents);
    const backup = try state.ctx.paths.dataPath(state.allocator, "documents-exit-backup");
    defer state.allocator.free(backup);
    try std.Io.Dir.cwd().rename(documents, std.Io.Dir.cwd(), backup, state.ctx.io.?);
    var restored = false;
    defer if (!restored) {
        std.Io.Dir.cwd().deleteFile(state.ctx.io.?, documents) catch {};
        std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), documents, state.ctx.io.?) catch {};
    };
    try std.Io.Dir.cwd().writeFile(state.ctx.io.?, .{ .sub_path = documents, .data = "deliberate save failure" });
    try tester.clickText("安全退出");
    var failed = false;
    for (0..20) |_| {
        tester.frame();
        if (state.exit.phase == .failed) {
            failed = true;
            break;
        }
    }
    if (!failed) return error.ExitFailureNotReported;
    if (!tester.hasText("重试安全退出")) return error.ExitRetryMissing;
    try std.Io.Dir.cwd().deleteFile(state.ctx.io.?, documents);
    try std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), documents, state.ctx.io.?);
    restored = true;
    try tester.clickText("重试安全退出");
    for (0..6000) |_| {
        if (state.exit.phase == .stopped) break;
        tester.frame();
        try std.Io.sleep(state.ctx.io.?, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    } else return error.SafeExitTimeout;
    if (!hooks.host_stopped) return error.HostStillRunning;
    std.debug.print("CUTRANS_SAFE_EXIT_DRAFT_OK draft_revision={d} work_revision={d} stop_retry=1\n", .{ state.library.work.?.editor.?.draft_revision, state.library.work.?.editor.?.work_revision });
}

pub fn run(init: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi, hooks: *@import("shell").client.ExitHooks) !void {
    const state = try model.State.init(init, config, api, hooks);
    defer state.deinit();
    std.debug.print("Cutrans VM 桌面就绪(NanoUI)\n", .{});
    std.debug.print("CUTRANS_ENVIRONMENT_SESSION_OK epoch={x}:{x}\n", .{ state.session.epoch_hi, state.session.epoch_lo });
    if (state.page == .editor) std.debug.print("app.open editor\n", .{});
    if (state.page == .files) std.debug.print("app.open local-files\n", .{});
    if (config.asset_workspace == 1) return verify(state, config);
    if (config.asset_workspace == 3) return verifyExit(state, hooks);
    if (config.asset_workspace == 2) {
        var tester: nanoui.ui.Tester = undefined;
        try tester.init(state.allocator, .init(state, model.State.view), .{
            .width = 1280,
            .height = 800,
            .scale = 1,
            .theme = view.theme(),
        });
        defer tester.deinit();
        return @import("local_files").verify(state, &tester);
    }

    const app = try nanoui.App.create(init, .{ .name = "Cutrans", .kv = false });
    defer app.destroy();
    const window = try app.newWindow(.{
        .title = "Cutrans",
        .width = 1280,
        .height = 800,
        .decorations = true,
        .title_bar = .hidden,
        .theme = view.theme(),
        .on_present = .{ .ctx = state, .func = model.State.onPresent },
        .should_close = .{ .ctx = state, .func = model.State.shouldClose },
        .content = .{ .view = .init(state, model.State.view) },
    });
    state.window = window;
    // App-drawn title bar under a retained frame: the native resize grips,
    // Snap Layouts, system menu and DWM shadow stay; chrome.zig maps the
    // view's caption/maximize boxes back to non-client hit codes.
    window.setFullScreen(true);
    if (config.playback_frames > 0) {
        state.showPage(.editor);
        var argument_buffer: [32]u8 = undefined;
        const argument = try std.fmt.bufPrint(&argument_buffer, "{d}", .{config.playback_frames});
        try require(state.ctx.command.dispatch(.{ .name = "playback.start", .arg = argument }));
    }
    try app.run();
}
