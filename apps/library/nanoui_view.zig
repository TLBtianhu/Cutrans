const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const State = @import("nanoui_model.zig").State;
const palette = @import("palette");

pub fn metalTheme() ui.Theme {
    return .{
        .dark = true,
        .background = .hex(palette.background),
        .surface = .hex(palette.surface),
        .surface_hover = .hex(palette.surface_hover),
        .text = .hex(palette.text),
        .muted = .hex(palette.muted),
        .border = .hex(palette.border),
        .accent = .hex(palette.accent),
        .accent_hover = .hex(palette.accent_hover),
        .accent_text = .hex(palette.ink),
        .track = .hex(palette.selection),
        .knob = .hex(palette.accent),
        .danger = .hex(palette.danger),
        .success = .hex(palette.success),
        .shadow = .{ .a = 0.35 },
        .font = "Segoe UI",
        .mono_font = "Cascadia Mono",
    };
}

/// 小幅静态渐变进已有图集。背景只画不命中,尺寸随父框布局更新。
fn material(c: *ui.Context, backdrop: bool) void {
    const name = if (backdrop) "cutrans-backdrop-v1" else "cutrans-panel-v1";
    _ = c.leaf(.{
        .width = .fill,
        .height = .fill,
        .absolute = true,
        .fixed = backdrop,
        .radius = if (backdrop) 0 else 7,
    }, .{ .image = .{
        .key = std.hash.Wyhash.hash(0x1a9e, name),
        .source = .{ .pixels = .{
            .bgra = if (backdrop) &palette.backdrop_bgra else &palette.panel_bgra,
            .width = palette.material_width,
            .height = palette.material_height,
        } },
    } }, null);
}

fn panel(c: *ui.Context, style: ui.Style, padding: f32, gap: f32) void {
    ui.column(c, style);
    material(c, false);
    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .absolute = true,
        .offset = .{ .y = 1 },
        .background = ui.Color.hex(palette.highlight).alpha(0.24),
    }, .none, null);
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(padding), .gap = gap });
}

fn openMenu(state: *State, id: u64, anchor: ?ui.Rect) void {
    state.menu_target = id;
    state.menu_anchor = anchor;
    state.menu_open = true;
}

fn drawChildren(state: *State, c: *ui.Context, parent_id: u64, depth: usize) void {
    if (depth > state.catalog.count) {
        ui.text(c, "目录层级无效，已停止展开", .{ .color = c.theme.danger });
        return;
    }
    for (state.catalog.items[0..state.catalog.count]) |item| {
        if (item.parent_id == parent_id and item.node_kind == .folder) drawNode(state, c, item, depth);
    }
    for (state.catalog.items[0..state.catalog.count]) |item| {
        if (item.parent_id == parent_id and item.node_kind == .resource) drawNode(state, c, item, depth);
    }
}

fn drawNode(state: *State, c: *ui.Context, item: @import("vne").library.Item, depth: usize) void {
    ui.key(c, c.print("library-node-{d}", .{item.id}));
    const selected = if (item.node_kind == .folder)
        state.selected_library == 0 and state.selected_folder == item.id
    else
        state.selected_library == item.id;
    var row = ui.div(c).row().wFull().h(34).pl(8 + @as(f32, @floatFromInt(depth)) * 17).pr(8).gap(8).itemsCenter().rounded(5).control();
    row = if (selected) row.bg(c.theme.accent.alpha(0.18)) else row.hover(c.theme.surface_hover);
    const interaction = row.interaction();
    ui.text(c, if (item.node_kind == .folder) "▾" else "·", .{ .color = c.theme.muted, .mono = true });
    ui.text(c, item.label, .{ .color = c.theme.text, .truncate = .middle });
    ui.spacer(c);
    if (item.node_kind == .resource) {
        ui.text(c, if (item.kind.? == .reference) "引用" else "拥有", .{ .size = 11, .color = if (item.kind.? == .reference) c.theme.muted else c.theme.success });
    }
    row.end();
    if (interaction.clicked) {
        if (item.node_kind == .folder) {
            state.selectFolder(item.id) catch |err| state.fail("无法选择文件夹", err);
        } else {
            state.selectLibrary(item.id) catch |err| state.fail("库项无法载入或完整预览", err);
        }
    }
    if (interaction.right_clicked) openMenu(state, item.id, interaction.rect);
    if (item.node_kind == .folder) drawChildren(state, c, item.id, depth + 1);
}

fn drawRoot(state: *State, c: *ui.Context) void {
    ui.key(c, "library-root");
    var row = ui.div(c).row().wFull().h(36).px(8).gap(8).itemsCenter().rounded(5).control();
    row = if (state.selected_folder == 0 and state.selected_library == 0) row.bg(c.theme.accent.alpha(0.18)) else row.hover(c.theme.surface_hover);
    const interaction = row.interaction();
    defer row.end();
    if (interaction.clicked) state.selectFolder(0) catch |err| state.fail("无法选择根目录", err);
    if (interaction.right_clicked) openMenu(state, 0, interaction.rect);
    ui.text(c, "资源库", .{ .weight = .semibold });
    ui.spacer(c);
    ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "{d} 项", .{state.catalog.count});
}

fn sidebar(state: *State, c: *ui.Context) void {
    panel(c, .{
        .width = .{ .px = 470 },
        .height = .fill,
        .padding = .all(1),
        .background = c.theme.surface,
        .border = c.theme.border,
        .radius = 8,
        .clip = true,
    }, 13, 10);
    defer {
        ui.end(c);
        ui.end(c);
    }
    ui.text(c, "虚拟资源目录", .{ .size = 17, .weight = .semibold });
    ui.label(c, "点击资源预览 · 右键整理文件夹与素材");
    if (ui.button(c, "导入外部 PNG…", .{ .width = .fill }).clicked) state.pickExternal() catch |err| state.fail("外部素材导入失败", err);
    ui.row(c, .{ .width = .fill, .gap = 8 });
    {
        defer ui.end(c);
        _ = ui.textField(c, &state.new_folder_buffer, .{ .placeholder = "新文件夹名称", .width = .fill });
        if (ui.button(c, "新建文件夹", .{}).clicked) {
            const input = state.new_folder_buffer.text();
            _ = state.createFolder(state.selected_folder, if (input.len == 0) "新建文件夹" else input) catch |err| {
                state.fail("新建文件夹失败", err);
                return;
            };
            state.new_folder_buffer.clear();
        }
    }
    ui.divider(c);
    ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .gap = 2 });
    defer ui.end(c);
    drawRoot(state, c);
    drawChildren(state, c, 0, 1);
    if (state.catalog.count == 0) ui.text(c, "目录为空；导入或创建素材后显示在这里。", .{ .color = c.theme.muted, .wrap = true });
}

fn previewPanel(state: *State, c: *ui.Context) void {
    ui.text(c, "检查器", .{ .size = 17, .weight = .semibold });
    ui.label(c, "查看素材预览与归属；预览不会修改文档。");
    ui.divider(c);
    if (state.rename_target != 0) {
        ui.text(c, "重命名", .{ .weight = .medium });
        _ = ui.textField(c, &state.rename_buffer, .{ .placeholder = "输入新名称", .width = .fill });
        if (ui.button(c, "应用重命名", .{ .variant = .primary }).clicked) state.applyRename() catch |err| state.fail("重命名失败", err);
        ui.divider(c);
    }
    if (state.preview) |*preview| {
        const item = state.catalog.findResource(state.selected_library);
        if (item) |resource| {
            ui.text(c, resource.label, .{ .size = 16, .weight = .medium, .truncate = .middle });
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            ui.badge(c, if (resource.kind.? == .reference) "外部引用" else "库内拥有", if (resource.kind.? == .reference) c.theme.accent else c.theme.success);
        }
        const hash = std.fmt.bytesToHex(preview.info.content_hash, .lower);
        if (!ui.image(c, .{
            .key = c.print("library-preview-{d}-{s}", .{ state.selected_handle, hash }),
            .source = .{ .encoded = preview.bytes },
            .max_width = 560,
            .max_height = 390,
            .scale = 1,
            .radius = 4,
        })) ui.text(c, "无法显示这张图片，请重新载入。", .{ .color = c.theme.danger });
        ui.textf(c, .{ .color = c.theme.muted, .mono = true }, "PNG {d}×{d} · {d} B · 完整预览", .{ preview.info.width, preview.info.height, preview.info.byte_length });
        if (state.assets.find(state.selected_handle)) |loaded| {
            ui.text(c, @import("shell").mirror.sourceStatusText(loaded.source_state), .{ .color = c.theme.muted, .wrap = true });
            if (ui.button(c, "核对已加载来源", .{}).clicked) state.checkSelectedSource() catch |err| state.fail("来源核对未完成；已加载预览保持可用", err);
        }
        if (item != null and item.?.kind.? == .reference) {
            ui.row(c, .{ .gap = 8 });
            defer ui.end(c);
            if (ui.button(c, "从原文件重新载入", .{}).clicked) state.refreshLibrary(state.selected_library) catch |err| state.fail("原文件重新载入失败", err);
            if (ui.button(c, "保存为库内独立副本", .{ .variant = .primary }).clicked) state.detachLibrary(state.selected_library) catch |err| state.fail("独立化失败", err);
        }
    } else if (state.catalog.findResource(state.selected_library)) |resource| {
        ui.text(c, resource.label, .{ .size = 16, .weight = .medium, .truncate = .middle });
        ui.label(c, "素材仍在资源库中；当前预览不可用。");
        if (ui.button(c, "载入并预览", .{ .variant = .primary }).clicked) state.selectLibrary(resource.id) catch |err| state.fail("库项无法载入或完整预览", err);
        if (resource.kind.? == .reference) {
            if (ui.button(c, "保存为库内独立副本", .{}).clicked) state.detachLibrary(resource.id) catch |err| state.fail("独立化失败", err);
        }
    } else {
        ui.spacer(c);
        ui.text(c, "选择左侧资源查看完整 PNG 预览。", .{ .color = c.theme.muted });
        ui.text(c, "在左侧文件夹中选择素材即可预览。", .{ .color = c.theme.muted, .wrap = true });
        ui.spacer(c);
    }
}

fn inspector(state: *State, c: *ui.Context) void {
    panel(c, .{
        .grow = 1,
        .height = .fill,
        .padding = .all(1),
        .background = c.theme.surface,
        .border = c.theme.border,
        .radius = 8,
        .clip = true,
    }, 17, 12);
    defer {
        ui.end(c);
        ui.end(c);
    }
    previewPanel(state, c);
}

const MenuAction = struct {
    kind: enum { preview, check_source, new_folder, rename, refresh, detach, move },
    destination: u64 = 0,
};

fn isDescendant(catalog: *const @import("vne").library.View, folder_id: u64, ancestor_id: u64) bool {
    var current = folder_id;
    for (0..catalog.count + 1) |_| {
        if (current == ancestor_id) return true;
        if (current == 0) return false;
        const folder = catalog.find(current) orelse return true;
        if (folder.node_kind != .folder) return true;
        current = folder.parent_id;
    }
    return true;
}

fn addMenuAction(c: *ui.Context, items: []kit.MenuItem, actions: []MenuAction, count: *usize, label: []const u8, action: MenuAction) void {
    if (count.* >= items.len or count.* >= actions.len) return;
    items[count.*] = .{ .label = label };
    actions[count.*] = action;
    count.* += 1;
    _ = c;
}

fn contextMenu(state: *State, c: *ui.Context) void {
    if (!state.menu_open) return;
    var items: [@import("vne").library.max_items + 8]kit.MenuItem = undefined;
    var actions: [@import("vne").library.max_items + 8]MenuAction = undefined;
    var count: usize = 0;
    if (state.menu_target == 0) {
        addMenuAction(c, &items, &actions, &count, "新建子文件夹", .{ .kind = .new_folder });
    } else if (state.catalog.find(state.menu_target)) |item| {
        if (item.node_kind == .folder) {
            addMenuAction(c, &items, &actions, &count, "新建子文件夹", .{ .kind = .new_folder });
        } else {
            addMenuAction(c, &items, &actions, &count, "载入并预览", .{ .kind = .preview });
            if (state.selected_library == item.id and state.assets.find(state.selected_handle) != null)
                addMenuAction(c, &items, &actions, &count, "核对已加载来源", .{ .kind = .check_source });
            if (item.kind.? == .reference) {
                addMenuAction(c, &items, &actions, &count, "从原文件重新载入", .{ .kind = .refresh });
                addMenuAction(c, &items, &actions, &count, "保存为库内独立副本", .{ .kind = .detach });
            }
        }
        addMenuAction(c, &items, &actions, &count, "重命名", .{ .kind = .rename });
        if (item.parent_id != 0) addMenuAction(c, &items, &actions, &count, "移动到根目录", .{ .kind = .move, .destination = 0 });
        for (state.catalog.items[0..state.catalog.count]) |candidate| {
            if (candidate.node_kind != .folder or candidate.id == item.id or candidate.id == item.parent_id) continue;
            if (item.node_kind == .folder and isDescendant(&state.catalog, candidate.id, item.id)) continue;
            addMenuAction(c, &items, &actions, &count, c.print("移动到 “{s}”", .{candidate.label}), .{ .kind = .move, .destination = candidate.id });
        }
    } else {
        state.menu_open = false;
        return;
    }
    if (kit.menu(c, "library-context-menu", &state.menu_open, state.menu_anchor, items[0..count], .{ .width = 258, .glass = false })) |chosen| {
        const id = state.menu_target;
        const action = actions[chosen];
        switch (action.kind) {
            .preview => state.selectLibrary(id) catch |err| state.fail("库项无法载入或完整预览", err),
            .check_source => state.checkSelectedSource() catch |err| state.fail("来源核对未完成；已加载预览保持可用", err),
            .new_folder => {
                _ = state.createFolder(id, "新建文件夹") catch |err| state.fail("新建文件夹失败", err);
            },
            .rename => state.beginRename(id) catch |err| state.fail("无法开始重命名", err),
            .refresh => state.refreshLibrary(id) catch |err| state.fail("原文件重新载入失败", err),
            .detach => state.detachLibrary(id) catch |err| state.fail("独立化失败", err),
            .move => state.moveLibrary(id, action.destination) catch |err| state.fail("移动失败", err),
        }
    }
}

pub fn view(state: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
    defer ui.end(c);
    material(c, true);
    ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 12 });
    {
        defer ui.end(c);
        ui.text(c, "◆", .{ .size = 12, .color = .hex(palette.gold) });
        ui.text(c, "CUTRANS / 资源库", .{ .size = 13, .weight = .semibold, .color = c.theme.accent });
        ui.spacer(c);
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d} 项资源与文件夹", .{state.catalog.count});
    }
    ui.row(c, .{ .grow = 1, .width = .fill, .height = .fill, .gap = 14 });
    {
        defer ui.end(c);
        sidebar(state, c);
        inspector(state, c);
    }
    ui.text(c, state.status(), .{ .size = 12, .color = c.theme.muted });
    contextMenu(state, c);
}
