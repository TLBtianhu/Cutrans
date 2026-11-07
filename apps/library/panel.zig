const std = @import("std");
const zgui = @import("zgui");
const RuntimeContext = @import("runtime").context.Context;
const render = @import("runtime").render;
const vm_client = @import("vm_client");
const theme = @import("uikit").theme;

extern fn zguiRegisterUserTexture(*zgui.TextureData) void;

pub const State = struct {
    selected: u64 = 0,
    selected_library: u64 = 0,
    selected_folder: u64 = 0,
    rename_target: u64 = 0,
    rename_buffer: [129:0]u8 = std.mem.zeroes([129:0]u8),
    new_folder_label: [129:0]u8 = std.mem.zeroes([129:0]u8),
    previewed: u64 = 0,
    frame: ?render.Frame = null,
    texture: zgui.TextureData = std.mem.zeroes(zgui.TextureData),
    texture_registered: bool = false,
    upload_generation: u64 = 0,
    dialog_owner: ?*anyopaque = null,

    pub fn deinit(self: *State, ctx: *RuntimeContext) void {
        self.clearPreview(ctx);
        if (self.texture_registered and self.texture.status != .destroyed) {
            self.texture.status = .want_destroy;
            self.texture.unused_Frames = 1;
        }
        self.selected = 0;
        self.selected_library = 0;
        self.selected_folder = 0;
        self.rename_target = 0;
        self.new_folder_label[0] = 0;
        self.rename_buffer[0] = 0;
    }

    fn clearPreview(self: *State, ctx: *RuntimeContext) void {
        if (self.frame) |*frame| frame.deinit(ctx.allocator);
        self.frame = null;
        self.previewed = 0;
        self.upload_generation = 0;
    }
};

fn textureRef(texture: *zgui.TextureData) zgui.TextureRef {
    return if (@backingInt(texture.tex_id) == 0)
        .{ .tex_data = texture, .tex_id = texture.tex_id }
    else
        .{ .tex_data = null, .tex_id = texture.tex_id };
}

fn updateTexture(state: *State, frame: *const render.Frame) ?*zgui.TextureData {
    const texture = &state.texture;
    if (texture.status == .want_destroy) return null;
    if (texture.status == .destroyed) {
        state.texture_registered = false;
        state.upload_generation = 0;
    }
    if (!state.texture_registered) {
        texture.* = std.mem.zeroes(zgui.TextureData);
        texture.unique_id = 2;
        texture.ref_count = 1;
        texture.format = .rgba32;
        texture.status = .want_create;
        state.texture_registered = true;
        zguiRegisterUserTexture(texture);
    }
    if (@backingInt(texture.tex_id) != 0 and (texture.width != frame.width or texture.height != frame.height)) {
        texture.status = .want_destroy;
        texture.unused_Frames = 1;
        return null;
    }
    if (state.upload_generation != frame.generation) {
        texture.width = @intCast(frame.width);
        texture.height = @intCast(frame.height);
        texture.bytes_per_pixel = 4;
        texture.pixels = frame.pixels.ptr;
        texture.status = if (@backingInt(texture.tex_id) == 0) .want_create else .want_updates;
        state.upload_generation = frame.generation;
    }
    return texture;
}

pub fn select(ctx: *RuntimeContext, state: *State, handle: u64) bool {
    const item = ctx.asset_view.find(handle) orelse {
        ctx.status.set("素材已释放,请重新选择");
        return false;
    };
    if (state.selected == handle and state.frame != null) {
        state.selected_library = item.library_id;
        state.selected_folder = if (ctx.library_view.findResource(item.library_id)) |entry| entry.parent_id else 0;
        return true;
    }
    const frame = vm_client.previewAsset(ctx, handle, item.content_hash) catch {
        ctx.status.set("素材不是可完整预览的 PNG");
        return false;
    };
    // Keep the old successful preview and selection until its replacement is
    // fully decoded. Merely clicking an unavailable head does not erase it.
    state.clearPreview(ctx);
    state.selected = handle;
    state.selected_library = item.library_id;
    state.selected_folder = if (ctx.library_view.findResource(item.library_id)) |entry| entry.parent_id else 0;
    state.frame = frame;
    state.previewed = handle;
    std.debug.print("CUTRANS_ASSET_SELECT asset={d} source={s}\n", .{ handle, item.source });
    return true;
}

pub fn insertSelected(ctx: *RuntimeContext, state: *State) bool {
    if (state.selected == 0 or ctx.asset_view.find(state.selected) == null) {
        ctx.status.set("请先选择素材");
        return false;
    }
    var buffer: [32]u8 = undefined;
    const arg = std.fmt.bufPrint(&buffer, "{d}", .{state.selected}) catch return false;
    const result = ctx.command.dispatch(.{ .name = "editor.asset.insert", .arg = arg });
    return result.code == .ok;
}

pub fn openPackExample(ctx: *RuntimeContext, state: *State) bool {
    const source = "pack://assets/examples/pngtest.png";
    const result = ctx.command.dispatch(.{ .name = "asset.open", .arg = source });
    if (result.code != .accepted and result.code != .ok) {
        ctx.status.set("Pack 素材加载失败");
        return false;
    }
    vm_client.syncAssets(ctx) catch {
        ctx.status.set("素材投影同步失败");
        return false;
    };
    for (ctx.asset_view.items[0..ctx.asset_view.count]) |item| {
        if (std.mem.eql(u8, item.source, source)) return select(ctx, state, item.handle);
    }
    ctx.status.set("加载后未找到素材投影");
    return false;
}

pub fn pickExternal(ctx: *RuntimeContext, state: *State) bool {
    const selected_path = @import("ports").file_dialog.pickPng(ctx.allocator, state.dialog_owner) catch {
        ctx.status.set("无法打开 PNG 文件选择器");
        return false;
    };
    const path = selected_path orelse return false;
    defer ctx.allocator.free(path);
    const handle = vm_client.openExternal(ctx, path) catch {
        ctx.status.set("外部素材加载失败");
        return false;
    };
    if (!vm_client.mirrorsFresh()) {
        ctx.status.set("素材已加载，视图正在重新同步");
        return true;
    }
    return select(ctx, state, handle);
}

pub fn exportSnapshotAndInsert(ctx: *RuntimeContext, state: *State) bool {
    const item = ctx.asset_view.find(state.selected) orelse {
        ctx.status.set("请先选择要导出的素材");
        return false;
    };
    var destination_buffer: [96]u8 = undefined;
    const destination = std.fmt.bufPrint(&destination_buffer, "session://snapshots/asset-{d}", .{item.handle}) catch return false;
    var argument_buffer: [160]u8 = undefined;
    const argument = std.fmt.bufPrint(&argument_buffer, "{d} {s}", .{ item.handle, destination }) catch return false;
    if (ctx.command.dispatch(.{ .name = "asset.export", .arg = argument }).code != .ok) {
        ctx.status.set("快照导出失败;已有目标不会被覆盖");
        return false;
    }
    if (ctx.command.dispatch(.{ .name = "asset.open", .arg = destination }).code != .accepted) {
        ctx.status.set("快照无法重新加载");
        return false;
    }
    vm_client.syncAssets(ctx) catch {
        ctx.status.set("快照投影同步失败");
        return false;
    };
    for (ctx.asset_view.items[0..ctx.asset_view.count]) |snapshot| {
        if (!std.mem.eql(u8, snapshot.source, destination)) continue;
        if (!select(ctx, state, snapshot.handle)) return false;
        if (!insertSelected(ctx, state)) return false;
        std.debug.print("CUTRANS_ASSET_SNAPSHOT source={s} snapshot={s}\n", .{ item.source, destination });
        return true;
    }
    ctx.status.set("快照加载后未找到 Source");
    return false;
}

fn selectLibrary(ctx: *RuntimeContext, state: *State, id: u64) bool {
    const entry = ctx.library_view.findResource(id) orelse {
        ctx.status.set("请选择资源，而不是文件夹");
        return false;
    };
    const handle = vm_client.ensureLibraryAsset(ctx, id, entry.content_hash) catch {
        ctx.status.set("库项无法载入：原文件缺失、内容已变化或不是受支持的 PNG");
        return false;
    };
    std.debug.print("CUTRANS_LIBRARY_SELECT library={d} loaded_on_demand=1\n", .{id});
    return select(ctx, state, handle);
}

pub fn checkSelectedSource(ctx: *RuntimeContext, state: *State) bool {
    const selected = ctx.asset_view.find(state.selected) orelse {
        ctx.status.set("请先选择已加载的库项");
        return false;
    };
    if (selected.library_id == 0) {
        ctx.status.set("请选择已加载的库项核对来源");
        return false;
    }
    vm_client.checkLoadedSource(ctx, state.selected) catch |err| {
        ctx.status.set(if (err == error.SourceCheckProjectionFailed)
            "来源已核对，但结果尚未同步"
        else
            "来源核对未完成；已加载预览保持可用");
        return false;
    };
    const checked = ctx.asset_view.find(state.selected) orelse return false;
    ctx.status.set(vm_client.sourceStatusText(checked.source_state));
    return true;
}

pub fn refreshLibrary(ctx: *RuntimeContext, state: *State) bool {
    const item = ctx.library_view.findResource(state.selected_library) orelse return false;
    if (item.kind != .reference) return false;
    const library_id = item.id;
    vm_client.runLibraryAction(ctx, "library.refresh", library_id) catch |err| {
        ctx.status.set(if (err == error.LibraryActionProjectionFailed)
            "目录版本已更新，但视图尚未同步；原预览继续保留"
        else
            "重新载入结果尚未确认；请核对目录后再操作");
        return false;
    };
    if (!selectLibrary(ctx, state, library_id)) {
        ctx.status.set("目录版本已更新，但内容无法载入");
        return false;
    }
    ctx.status.set("已载入目录当前版本；请再次插入以更新文档版本");
    return true;
}

pub fn detachLibrary(ctx: *RuntimeContext, state: *State) bool {
    const item = ctx.library_view.findResource(state.selected_library) orelse return false;
    if (item.kind != .reference) return false;
    vm_client.runLibraryAction(ctx, "library.detach", item.id) catch |err| {
        ctx.status.set(if (err == error.LibraryActionProjectionFailed)
            "独立副本已保存，但视图尚未同步；原预览继续保留"
        else
            "独立副本操作结果尚未确认；请核对目录后再操作");
        return false;
    };
    ctx.status.set("已转为库内文件,资源 ID 与工程引用不变");
    return true;
}

fn selectFolder(ctx: *RuntimeContext, state: *State, id: u64) void {
    if (id != 0) {
        const folder = ctx.library_view.find(id) orelse return;
        if (folder.node_kind != .folder) return;
    }
    state.selected_folder = id;
    state.selected_library = 0;
    state.selected = 0;
    state.rename_target = 0;
    state.clearPreview(ctx);
}

fn createLibraryFolder(ctx: *RuntimeContext, state: *State, parent_id: u64, label: []const u8) ?u64 {
    _ = state;
    var argument: [192]u8 = undefined;
    const value = std.fmt.bufPrint(&argument, "{d} {s}", .{ parent_id, label }) catch return null;
    if (ctx.command.dispatch(.{ .name = "library.folder.create", .arg = value }).code != .ok) {
        ctx.status.set("新建文件夹失败；请检查父文件夹和逻辑名称");
        return null;
    }
    vm_client.syncLibrary(ctx) catch {
        ctx.status.set("文件夹已写入，但目录投影同步失败");
        return null;
    };
    var created: ?u64 = null;
    for (ctx.library_view.items[0..ctx.library_view.count]) |item| {
        if (item.node_kind == .folder and item.parent_id == parent_id and std.mem.eql(u8, item.label, label)) created = item.id;
    }
    if (created) |id| {
        ctx.status.set("文件夹已写入真实资源目录");
        return id;
    }
    ctx.status.set("文件夹已写入，但未找到目录投影");
    return null;
}

fn renameLibrary(ctx: *RuntimeContext, state: *State, id: u64, label: []const u8) bool {
    _ = state;
    if (ctx.library_view.find(id) == null) return false;
    var argument: [192]u8 = undefined;
    const value = std.fmt.bufPrint(&argument, "{d} {s}", .{ id, label }) catch return false;
    if (ctx.command.dispatch(.{ .name = "library.rename", .arg = value }).code != .ok) {
        ctx.status.set("重命名失败；名称不能为空或包含路径分隔符");
        return false;
    }
    vm_client.syncLibrary(ctx) catch {
        ctx.status.set("名称已写入，但目录投影同步失败");
        return false;
    };
    ctx.status.set("逻辑名称已更新；资源 ID 与工程引用不变");
    return true;
}

fn beginRename(ctx: *RuntimeContext, state: *State, id: u64) void {
    const item = ctx.library_view.find(id) orelse return;
    state.rename_target = id;
    @memset(state.rename_buffer[0..], 0);
    @memcpy(state.rename_buffer[0..item.label.len], item.label);
}

fn renameSelected(ctx: *RuntimeContext, state: *State) bool {
    if (state.rename_target == 0) return false;
    const label = std.mem.sliceTo(&state.rename_buffer, 0);
    if (!renameLibrary(ctx, state, state.rename_target, label)) return false;
    state.rename_target = 0;
    state.rename_buffer[0] = 0;
    return true;
}

fn moveLibrary(ctx: *RuntimeContext, state: *State, id: u64, parent_id: u64) bool {
    const item = ctx.library_view.find(id) orelse return false;
    if (parent_id != 0) {
        const parent = ctx.library_view.find(parent_id) orelse return false;
        if (parent.node_kind != .folder) return false;
    }
    var argument: [64]u8 = undefined;
    const value = std.fmt.bufPrint(&argument, "{d} {d}", .{ id, parent_id }) catch return false;
    if (ctx.command.dispatch(.{ .name = "library.move", .arg = value }).code != .ok) {
        ctx.status.set("移动失败；文件夹不能移动到自己或自己的子文件夹中");
        return false;
    }
    vm_client.syncLibrary(ctx) catch {
        ctx.status.set("位置已写入，但目录投影同步失败");
        return false;
    };
    if (item.node_kind == .resource and state.selected_library == id) state.selected_folder = parent_id;
    ctx.status.set("逻辑位置已更新；物理内容与工程引用不变");
    return true;
}

fn isDescendant(view: *const @import("vne").library.View, folder_id: u64, ancestor_id: u64) bool {
    var current = folder_id;
    for (0..view.count + 1) |_| {
        if (current == ancestor_id) return true;
        if (current == 0) return false;
        const folder = view.find(current) orelse return true;
        if (folder.node_kind != .folder) return true;
        current = folder.parent_id;
    }
    return true;
}

fn drawMoveTargets(ctx: *RuntimeContext, state: *State, item: @import("vne").library.Item) void {
    if (zgui.menuItem("根目录", .{ .enabled = item.parent_id != 0 })) {
        _ = moveLibrary(ctx, state, item.id, 0);
        return;
    }
    for (ctx.library_view.items[0..ctx.library_view.count]) |candidate| {
        if (candidate.node_kind != .folder or candidate.id == item.id) continue;
        if (item.node_kind == .folder and isDescendant(&ctx.library_view, candidate.id, item.id)) continue;
        var buffer: [192]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{s} #{d}", .{ candidate.label, candidate.id }) catch continue;
        buffer[label.len] = 0;
        if (zgui.menuItem(buffer[0..label.len :0], .{ .enabled = candidate.id != item.parent_id })) {
            _ = moveLibrary(ctx, state, item.id, candidate.id);
            return;
        }
    }
}

fn drawLibraryContext(ctx: *RuntimeContext, state: *State, item: @import("vne").library.Item) void {
    if (item.node_kind == .resource and state.selected_library == item.id and ctx.asset_view.find(state.selected) != null) {
        if (zgui.menuItem("核对已加载来源", .{})) {
            _ = checkSelectedSource(ctx, state);
            return;
        }
    }
    if (item.node_kind == .folder and zgui.menuItem("新建子文件夹", .{})) {
        _ = createLibraryFolder(ctx, state, item.id, "新建文件夹");
        return;
    }
    if (item.node_kind == .resource and item.kind != null and item.kind.? == .reference) {
        if (zgui.menuItem("从原文件重新载入", .{})) {
            _ = refreshLibrary(ctx, state);
            return;
        }
        if (zgui.menuItem("保存为库内独立副本", .{})) {
            _ = detachLibrary(ctx, state);
            return;
        }
    }
    if (zgui.menuItem("重命名（在下方编辑）", .{})) beginRename(ctx, state, item.id);
    if (zgui.beginMenu("移动到", true)) {
        drawMoveTargets(ctx, state, item);
        zgui.endMenu();
    }
}

pub fn verifyPackExample(ctx: *RuntimeContext, state: *State) !void {
    if (!openPackExample(ctx, state)) return error.AssetSelectionFailed;
    if (!insertSelected(ctx, state)) return error.AssetInsertFailed;
    if (!exportSnapshotAndInsert(ctx, state)) return error.AssetSnapshotInsertFailed;
    const resource_path = try std.fs.path.join(ctx.allocator, &.{ ctx.paths.resource_dir, "assets/examples/pngtest.png" });
    defer ctx.allocator.free(resource_path);
    const external = vm_client.openExternal(ctx, resource_path) catch return error.LibraryImportFailed;
    if (!select(ctx, state, external)) return error.LibraryPreviewFailed;
    if (!detachLibrary(ctx, state)) return error.LibraryDetachFailed;
    var argument_buffer: [64]u8 = undefined;
    const argument = try std.fmt.bufPrint(&argument_buffer, "{d} created.png", .{state.selected});
    if (ctx.command.dispatch(.{ .name = "library.create", .arg = argument }).code != .ok) return error.LibraryCreateFailed;
    try vm_client.syncLibrary(ctx);
    const created = ctx.library_view.findResource(2) orelse return error.LibraryDirectoryMissing;
    if (created.kind == null or created.kind.? != .owned or created.provenance == null or created.provenance.? != .created or !std.mem.eql(u8, created.label, "created.png")) return error.LibraryDirectoryMismatch;
    const folder = createLibraryFolder(ctx, state, 0, "素材") orelse return error.LibraryFolderCreateFailed;
    const child = createLibraryFolder(ctx, state, folder, "角色") orelse return error.LibraryFolderCreateFailed;
    if (moveLibrary(ctx, state, folder, child)) return error.LibraryFolderCycleAccepted;
    if (!moveLibrary(ctx, state, 2, child)) return error.LibraryMoveFailed;
    if (!renameLibrary(ctx, state, child, "主角")) return error.LibraryRenameFailed;
    if (!renameLibrary(ctx, state, 2, "renamed.png")) return error.LibraryRenameFailed;
    const moved = ctx.library_view.findResource(2) orelse return error.LibraryDirectoryMissing;
    if (moved.parent_id != child or !std.mem.eql(u8, moved.label, "renamed.png")) return error.LibraryHierarchyMismatch;
    for (ctx.asset_view.items[0..ctx.asset_view.count]) |item| {
        if (item.library_id == 2) return error.LibraryPreloadedUnselectedAsset;
    }
    if (!selectLibrary(ctx, state, 2)) return error.LibraryOnDemandLoadFailed;
    if (!insertSelected(ctx, state)) return error.LibraryInsertFailed;
    const frame = state.frame orelse return error.AssetPreviewMissing;
    if (ctx.document.count != 1 or ctx.document.nodes[0].op != .image or !ctx.document.nodes[0].asset_hash_present) return error.AssetDocumentMismatch;
    if (!std.mem.eql(u8, ctx.document.nodes[0].asset(), "library://2")) return error.AssetSourceNotPersistent;
    std.debug.print("CUTRANS_SHELL_ASSETS_OK selected=1 preview={d}x{d} inserted=1 source_uri=1 snapshot=1 library=1 catalog_unloaded=1 folder_ops=1\n", .{ frame.width, frame.height });
}

fn drawLibraryChildren(ctx: *RuntimeContext, state: *State, parent_id: u64, depth: usize) void {
    if (depth > ctx.library_view.count) {
        zgui.textColored(theme.danger, "目录层级无效，已停止展开。", .{});
        return;
    }
    for (ctx.library_view.items[0..ctx.library_view.count]) |item| {
        if (item.node_kind != .folder or item.parent_id != parent_id) continue;
        var buffer: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "文件夹 · {s} #{d}##library-folder-{d}", .{ item.label, item.id, item.id }) catch continue;
        buffer[label.len] = 0;
        const opened = zgui.treeNodeFlags(buffer[0..label.len :0], .{
            .selected = state.selected_folder == item.id and state.selected_library == 0,
            .default_open = true,
            .open_on_arrow = true,
            .open_on_double_click = true,
            .span_avail_width = true,
        });
        if (zgui.isItemClicked(.left) or zgui.isItemClicked(.right)) selectFolder(ctx, state, item.id);
        if (zgui.beginPopupContextItem()) {
            drawLibraryContext(ctx, state, item);
            zgui.endPopup();
        }
        if (opened) {
            drawLibraryChildren(ctx, state, item.id, depth + 1);
            zgui.treePop();
        }
    }
    for (ctx.library_view.items[0..ctx.library_view.count]) |item| {
        if (item.node_kind != .resource or item.parent_id != parent_id) continue;
        var buffer: [256]u8 = undefined;
        const ownership = if (item.kind.? == .reference) "外部引用" else "库内拥有";
        const provenance = switch (item.provenance.?) {
            .external => "原处引用",
            .created => "库内创建",
            .detached => "已独立",
        };
        const label = std.fmt.bufPrint(&buffer, "{s}  #{d} · {s} · {s}", .{ item.label, item.id, ownership, provenance }) catch continue;
        buffer[label.len] = 0;
        if (zgui.selectable(buffer[0..label.len :0], .{ .selected = state.selected_library == item.id, .w = 0, .h = 30 })) _ = selectLibrary(ctx, state, item.id);
        if (zgui.isItemClicked(.right)) _ = selectLibrary(ctx, state, item.id);
        if (zgui.beginPopupContextItem()) {
            drawLibraryContext(ctx, state, item);
            zgui.endPopup();
        }
    }
}

pub fn draw(ctx: *RuntimeContext, state: *State, x: f32, y: f32, width: f32, height: f32) void {
    if (state.selected != 0 and ctx.asset_view.find(state.selected) == null) {
        state.clearPreview(ctx);
        state.selected = 0;
    }
    zgui.setCursorPos(.{ x, y });
    if (zgui.beginChild("##asset_workspace", .{ .w = width, .h = height })) {
        zgui.textColored(theme.text, "资源库", .{});
        zgui.textColored(theme.dim, "真实 Catalog · 虚拟层级 · 右键管理 · 点击资源才载入", .{});
        if (zgui.button("选择外部 PNG 并导入根目录…", .{ .w = width - 32, .h = 30 })) _ = pickExternal(ctx, state);
        if (state.selected_folder != 0 and ctx.library_view.find(state.selected_folder) != null) {
            const folder = ctx.library_view.find(state.selected_folder).?;
            zgui.textColored(theme.dim, "新建位置：{s} #{d}", .{ folder.label, folder.id });
        } else {
            zgui.textColored(theme.dim, "新建位置：根目录", .{});
        }
        zgui.pushItemWidth(width - 32);
        _ = zgui.inputTextWithHint("##new_folder_label", .{ .hint = "新文件夹逻辑名称", .buf = &state.new_folder_label });
        zgui.popItemWidth();
        if (zgui.button("新建文件夹", .{ .w = width - 32, .h = 30 })) {
            const input = std.mem.sliceTo(&state.new_folder_label, 0);
            const label = if (input.len == 0) "新建文件夹" else input;
            if (createLibraryFolder(ctx, state, state.selected_folder, label) != null) state.new_folder_label[0] = 0;
        }
        if (zgui.selectable("资源库（根目录）", .{ .selected = state.selected_folder == 0 and state.selected_library == 0, .w = width - 32, .h = 28 })) selectFolder(ctx, state, 0);
        if (zgui.isItemClicked(.right)) selectFolder(ctx, state, 0);
        if (zgui.beginPopupContextItem()) {
            if (zgui.menuItem("新建子文件夹", .{})) _ = createLibraryFolder(ctx, state, 0, "新建文件夹");
            zgui.endPopup();
        }
        if (ctx.library_view.count == 0) {
            zgui.textColored(theme.dim, "目录为空；尚未导入或创建资源。", .{});
        } else {
            drawLibraryChildren(ctx, state, 0, 0);
        }
        if (state.rename_target != 0) {
            zgui.separator();
            zgui.textColored(theme.dim, "重命名 #{d}；只改逻辑名称，不改 ID", .{state.rename_target});
            zgui.pushItemWidth(width - 32);
            const submit = zgui.inputText("##library_rename", .{ .buf = &state.rename_buffer, .flags = .{ .enter_returns_true = true } });
            zgui.popItemWidth();
            if (submit) _ = renameSelected(ctx, state);
            if (zgui.button("应用重命名", .{ .w = width - 32, .h = 30 })) _ = renameSelected(ctx, state);
        }
        zgui.separator();
        zgui.textColored(theme.text, "内存对象", .{});
        zgui.textColored(theme.dim, "Station · 选择预览 ≠ 插入文档 · 不按目录批量加载", .{});
        if (zgui.button("加载 Pack 示例（不进入资源库）", .{ .w = width - 32, .h = 30 })) _ = openPackExample(ctx, state);
        if (ctx.asset_view.count == 0) {
            zgui.textColored(theme.dim, "Station 为空；目录仍然保留。", .{});
            zgui.textColored(theme.dim, "也可通过 CLI asset.open 显式加载。", .{});
        }
        for (ctx.asset_view.items[0..ctx.asset_view.count]) |item| {
            if (item.library_kind != 0) {
                const label = if (item.library_kind == 1) "外部引用" else "库内拥有";
                zgui.textColored(if (item.library_kind == 1) theme.dim else theme.accent, "{s}", .{label});
            }
            var buffer: [160]u8 = undefined;
            const kind = switch (item.source_kind) {
                0 => "Pack",
                1 => "外部",
                2 => "快照",
                3 => "库项",
                else => "未知",
            };
            const label = std.fmt.bufPrint(&buffer, "#{d} · {s} · {d} B · 租约 {d}", .{ item.handle, kind, item.byte_length, item.leases }) catch continue;
            buffer[label.len] = 0;
            if (zgui.selectable(buffer[0..label.len :0], .{ .selected = state.selected == item.handle, .w = width - 32, .h = 28 })) _ = select(ctx, state, item.handle);
        }
        if (ctx.asset_view.find(state.selected)) |item| {
            zgui.separator();
            zgui.textColored(theme.dim, "Source", .{});
            zgui.text("{s}", .{item.source});
            if (item.library_id != 0) {
                zgui.textColored(theme.dim, "{s}", .{vm_client.sourceStatusText(item.source_state)});
                if (zgui.button("核对已加载来源", .{ .w = width - 32, .h = 30 })) _ = checkSelectedSource(ctx, state);
            }
            if (state.frame) |*frame| {
                const scale = @min(1, @min(@max(1, width - 32) / @as(f32, @floatFromInt(frame.width)), 220 / @as(f32, @floatFromInt(frame.height))));
                if (updateTexture(state, frame)) |texture| {
                    zgui.image(textureRef(texture), .{ .w = @as(f32, @floatFromInt(frame.width)) * scale, .h = @as(f32, @floatFromInt(frame.height)) * scale });
                } else {
                    zgui.textColored(theme.dim, "正在更新素材纹理", .{});
                }
                zgui.textColored(theme.dim, "PNG {d}x{d} · 完整覆盖", .{ frame.width, frame.height });
            } else {
                zgui.textColored(theme.danger, "尚无成功预览；请检查状态信息。", .{});
            }
            switch (item.source_kind) {
                0 => {
                    if (zgui.button("插入 Pack Source", .{ .w = width - 32, .h = 30 })) _ = insertSelected(ctx, state);
                },
                1 => {
                    if (zgui.button("插入硬盘 Source", .{ .w = width - 32, .h = 30 })) _ = insertSelected(ctx, state);
                    if (zgui.button("固定为快照并插入", .{ .w = width - 32, .h = 30 })) _ = exportSnapshotAndInsert(ctx, state);
                    zgui.textColored(theme.dim, "原处引用可恢复;独立副本由你显式选择。", .{});
                },
                2 => {
                    if (zgui.button("插入快照 Source", .{ .w = width - 32, .h = 30 })) _ = insertSelected(ctx, state);
                },
                3 => switch (item.library_kind) {
                    1 => {
                        if (zgui.button("从原文件重新载入", .{ .w = width - 32, .h = 30 })) _ = refreshLibrary(ctx, state);
                        if (zgui.button("保存为库内独立副本", .{ .w = width - 32, .h = 30 })) _ = detachLibrary(ctx, state);
                        if (zgui.button("插入库内引用", .{ .w = width - 32, .h = 30 })) _ = insertSelected(ctx, state);
                    },
                    2 => {
                        if (zgui.button("插入库内资源", .{ .w = width - 32, .h = 30 })) _ = insertSelected(ctx, state);
                    },
                    else => zgui.textColored(theme.danger, "资源目录缺少归属信息,拒绝插入。", .{}),
                },
                else => zgui.textColored(theme.danger, "未知 Source 类型,拒绝插入。", .{}),
            }
        } else if (ctx.library_view.findResource(state.selected_library)) |item| {
            zgui.separator();
            zgui.textColored(theme.dim, "library://{d} · 尚未载入内存", .{item.id});
            zgui.textColored(theme.dim, "目录项仍在；缺失或损坏不会生成预览。", .{});
            if (zgui.button("载入并预览当前库项", .{ .w = width - 32, .h = 30 })) _ = selectLibrary(ctx, state, item.id);
            if (item.kind == .reference) {
                if (zgui.button("从原文件重新载入", .{ .w = width - 32, .h = 30 })) _ = refreshLibrary(ctx, state);
                if (zgui.button("保存为库内独立副本", .{ .w = width - 32, .h = 30 })) _ = detachLibrary(ctx, state);
            }
        }
    }
    zgui.endChild();
}
