const std = @import("std");
const nanoui = @import("nanoui");
const runtime = @import("runtime");
const abi = @import("vne").abi;
const vm_client = @import("vm_client");
const model = @import("nanoui_model.zig");
const view = @import("nanoui_view.zig");
const library = @import("nanoui_library");

const ui = nanoui.ui;

fn require(result: runtime.command.Result) !void {
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
    var decoded = try runtime.image.decode(state.allocator, bytes);
    defer decoded.deinit(state.allocator);
    if (decoded.width != 1920 or decoded.height != 1080) return error.ExportDimensionsMismatch;
}

fn verify(state: *model.State, config: *const abi.ShellConfig) !void {
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
    try tester.clickText("编辑器");
    try tester.clickText("添加 invert");
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
    const path = try std.fs.path.join(state.allocator, &.{ resource_dir, "assets/examples/pngtest.png" });
    defer state.allocator.free(path);
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

pub fn run(init: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi) !void {
    const state = try model.State.init(init, config, api);
    defer state.deinit();
    std.debug.print("Cutrans VM 桌面就绪(NanoUI)\n", .{});
    if (state.page == .editor) std.debug.print("app.open editor\n", .{});
    if (config.asset_workspace == 1) return verify(state, config);

    const app = try nanoui.App.create(init, .{ .name = "Cutrans", .kv = false });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Cutrans",
        .width = 1280,
        .height = 800,
        .theme = view.theme(),
        .on_present = .{ .ctx = state, .func = model.State.onPresent },
        .content = .{ .view = .init(state, model.State.view) },
    });
    if (config.playback_frames > 0) {
        state.showPage(.editor);
        var argument_buffer: [32]u8 = undefined;
        const argument = try std.fmt.bufPrint(&argument_buffer, "{d}", .{config.playback_frames});
        try require(state.ctx.command.dispatch(.{ .name = "playback.start", .arg = argument }));
    }
    try app.run();
}
