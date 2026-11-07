//! workspace.zig — 系统工作区几何与系统任务栏
//!
//! 桌面是其中的一个 full App;本文件不属于桌面。任务栏合并固定入口与运行
//! Surface,并提供启动/恢复/聚焦/隐藏/关闭,不伪造后台 Task 进度。

const std = @import("std");
const zgui = @import("zgui");
const surfaces = @import("runtime").surfaces;
const RuntimeContext = @import("runtime").context.Context;
const paint = @import("uikit").paint;
const theme = @import("uikit").theme;

pub const taskbar_h: f32 = 44;
pub const taskbar_bottom: f32 = 16;
pub const taskbar_reserve = taskbar_h + taskbar_bottom;
pub const footer_h: f32 = 56;

pub const WorkArea = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn workArea(disp: [2]f32) WorkArea {
    return .{ .x = 0, .y = 0, .w = @max(0, disp[0]), .h = @max(0, disp[1] - taskbar_reserve) };
}

pub const Layout = struct {
    side_w: f32,
    content_x: f32,
    content_w: f32,
    body_h: f32,
    taskbar_h: f32,
};

pub fn layoutFor(disp: [2]f32, show_sidebar: bool) Layout {
    const work = workArea(disp);
    const side_w: f32 = if (show_sidebar) @min(320, work.w * 0.28) else 0;
    const gap: f32 = if (show_sidebar) 4 else 0;
    const available = @max(0, work.w - side_w - gap);
    const content_w = @min(1080, available);
    return .{
        .side_w = side_w,
        .content_x = side_w + gap + @max(0, (available - content_w) / 2),
        .content_w = content_w,
        .body_h = @max(0, work.h - 48 - footer_h),
        .taskbar_h = taskbar_h,
    };
}

pub fn layout(disp: [2]f32) Layout {
    return layoutFor(disp, true);
}

const TaskbarItem = struct { surface: surfaces.Surface };

const TaskbarVisual = struct {
    running: bool,
    workspace_active: bool,
    focused: bool,
    minimized: bool,
    background: [4]f32,
    text: [4]f32,
    running_indicator: bool,
    focus_outline: bool,
};

fn visualFor(ctx: *RuntimeContext, surface: surfaces.Surface) TaskbarVisual {
    const running = surface.is_open;
    const workspace_active = ctx.surfaces.isActiveFull(surface.owner_kind, surface.id);
    const focused = surface.focused;
    const minimized = surface.is_minimized;
    return .{
        .running = running,
        .workspace_active = workspace_active,
        .focused = focused,
        .minimized = minimized,
        .background = if (workspace_active) theme.hover_bg else theme.card,
        .text = if (!running) theme.dim else if (minimized) theme.caption else theme.accent,
        .running_indicator = running,
        .focus_outline = focused,
    };
}

fn refOf(surface: surfaces.Surface) surfaces.SurfaceRef {
    return .{ .owner_kind = surface.owner_kind, .id = surface.id };
}

fn findSurface(ctx: *RuntimeContext, ref: surfaces.SurfaceRef) ?surfaces.Surface {
    for (ctx.surfaces.all()) |surface| {
        if (refOf(surface).eql(ref)) return surface;
    }
    return null;
}

fn contains(items: []const TaskbarItem, ref: surfaces.SurfaceRef) bool {
    for (items) |item| {
        if (refOf(item.surface).eql(ref)) return true;
    }
    return false;
}

fn buildItems(ctx: *RuntimeContext, buf: []TaskbarItem) []TaskbarItem {
    var count: usize = 0;
    for (ctx.session.pinned()) |ref| {
        if (count == buf.len) break;
        if (findSurface(ctx, ref)) |surface| {
            buf[count] = .{ .surface = surface };
            count += 1;
        }
    }
    for (ctx.surfaces.all()) |surface| {
        if (count == buf.len or !surface.is_open or contains(buf[0..count], refOf(surface))) continue;
        buf[count] = .{ .surface = surface };
        count += 1;
    }
    return buf[0..count];
}

fn openSurface(ctx: *RuntimeContext, surface: surfaces.Surface) void {
    if (surface.focused and surface.is_visible and !surface.is_minimized) {
        var arg_buf: [128]u8 = undefined;
        const arg = std.fmt.bufPrint(&arg_buf, "{s}:{s}", .{ ownerText(surface.owner_kind), surface.id }) catch return;
        _ = ctx.command.dispatch(.{ .name = "surface.hide", .arg = arg });
    } else if (surface.owner_kind == .app) {
        _ = ctx.command.dispatch(.{ .name = "app.open", .arg = surface.id });
    } else {
        _ = ctx.command.dispatch(.{ .name = "console.open", .arg = surface.id });
    }
}

fn closeSurface(ctx: *RuntimeContext, surface: surfaces.Surface) void {
    if (surface.owner_kind == .app) {
        _ = ctx.command.dispatch(.{ .name = "app.close", .arg = surface.id });
    } else {
        _ = ctx.command.dispatch(.{ .name = "console.close", .arg = surface.id });
    }
}

fn ownerText(kind: surfaces.OwnerKind) [:0]const u8 {
    return if (kind == .app) "app" else "console";
}

fn drawOpenButton(ctx: *RuntimeContext, surface: surfaces.Surface) void {
    const visual = visualFor(ctx, surface);
    zgui.pushStyleColor4f(.{ .idx = .button, .c = visual.background });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = visual.text });
    var id_buf: [160]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{s}##taskbar:open:{s}:{s}", .{ surface.title, ownerText(surface.owner_kind), surface.id }) catch {
        zgui.popStyleColor(.{ .count = 4 });
        return;
    };
    id_buf[id.len] = 0;
    const pos = zgui.getCursorScreenPos();
    const clicked = zgui.button(id_buf[0..id.len :0], .{ .w = 104, .h = 30 });
    if (visual.running_indicator) {
        const dl = zgui.getWindowDrawList();
        const cx = pos[0] + 52;
        dl.addRectFilled(.{ .pmin = .{ cx - 6, pos[1] + 27 }, .pmax = .{ cx + 6, pos[1] + 29 }, .col = paint.pack(theme.accent), .rounding = 1 });
    }
    if (visual.focus_outline) {
        const dl = zgui.getWindowDrawList();
        dl.addRect(.{ .pmin = .{ pos[0] - 1, pos[1] - 1 }, .pmax = .{ pos[0] + 105, pos[1] + 31 }, .col = paint.pack(theme.accent_deep), .rounding = theme.r_s, .thickness = 1.5 });
    }
    if (clicked) openSurface(ctx, surface);
    zgui.popStyleColor(.{ .count = 4 });
    if (zgui.beginPopupContextItem()) {
        if (surface.is_open and !surface.protected) {
            var close_buf: [160]u8 = undefined;
            const close_id = std.fmt.bufPrint(&close_buf, "关闭 {s}##taskbar:context:close:{s}:{s}", .{ surface.title, ownerText(surface.owner_kind), surface.id }) catch {
                zgui.endPopup();
                return;
            };
            close_buf[close_id.len] = 0;
            if (zgui.menuItem(close_buf[0..close_id.len :0], .{})) closeSurface(ctx, surface);
        }
        zgui.endPopup();
    }
}

fn drawOverflow(ctx: *RuntimeContext, items: []const TaskbarItem) void {
    if (zgui.button("更多##taskbar:overflow", .{ .w = 48, .h = 30 })) zgui.openPopup("##taskbar:overflow_popup", .{});
    if (zgui.beginPopup("##taskbar:overflow_popup", .{})) {
        for (items) |item| {
            const surface = item.surface;
            var id_buf: [160]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "{s}##taskbar:overflow:{s}:{s}", .{ surface.title, ownerText(surface.owner_kind), surface.id }) catch continue;
            id_buf[id.len] = 0;
            if (zgui.menuItem(id_buf[0..id.len :0], .{})) {
                openSurface(ctx, surface);
                zgui.closeCurrentPopup();
            }
            if (surface.is_open and !surface.protected) {
                var close_buf: [160]u8 = undefined;
                const close_id = std.fmt.bufPrint(&close_buf, "关闭 {s}##taskbar:overflow:close:{s}:{s}", .{ surface.title, ownerText(surface.owner_kind), surface.id }) catch continue;
                close_buf[close_id.len] = 0;
                if (zgui.menuItem(close_buf[0..close_id.len :0], .{})) {
                    closeSurface(ctx, surface);
                    zgui.closeCurrentPopup();
                }
            }
        }
        zgui.endPopup();
    }
}

/// 没有活动 full App 时的系统空工作区;桌面不在场也不影响 CLI 和任务栏。
pub fn drawEmpty(ctx: *RuntimeContext) void {
    const disp = zgui.io.getDisplaySize();
    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_mouse_inputs = true,
        .no_focus_on_appearing = true,
        .no_bring_to_front_on_focus = true,
    };
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = disp[0], .h = disp[1] });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = theme.bg });
    if (zgui.begin("##system_empty", .{ .flags = flags })) {
        const text = "没有活动应用 · 从任务栏启动或恢复";
        const tw = zgui.calcTextSize(text, .{})[0];
        zgui.setCursorPos(.{ @max(16, (disp[0] - tw) / 2), @max(24, disp[1] * 0.42) });
        zgui.textColored(theme.dim, "{s}", .{text});
        if (ctx.status.get().len > 0) {
            zgui.setCursorPos(.{ 24, @max(24, disp[1] - taskbar_reserve - 40) });
            zgui.textColored(theme.caption, "{s}", .{ctx.status.get()});
        }
    }
    zgui.end();
    zgui.popStyleColor(.{});
    zgui.popStyleVar(.{});
}

pub fn drawTaskbar(ctx: *RuntimeContext) void {
    const disp = zgui.io.getDisplaySize();
    var item_buf: [32]TaskbarItem = undefined;
    const items = buildItems(ctx, &item_buf);
    const margin: f32 = if (disp[0] >= 32) 16 else 0;
    const max_width = @max(0, disp[0] - 2 * margin);
    const base_w: f32 = 16;
    const item_w: f32 = 112;
    const overflow_w: f32 = 56;
    const needed = base_w + item_w * @as(f32, @floatFromInt(items.len));
    var visible_count = items.len;
    if (needed > max_width) {
        const available = @max(0, max_width - base_w - overflow_w);
        visible_count = @intFromFloat(@floor(available / item_w));
    }
    const overflowing = visible_count < items.len;
    const empty_width: f32 = if (items.len == 0) 180 else 0;
    const width = if (overflowing) max_width else @min(max_width, @max(empty_width, needed));
    const x = margin + @max(0, (max_width - width) / 2);
    const y = @max(0, disp[1] - taskbar_h - taskbar_bottom);
    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_focus_on_appearing = true,
    };
    zgui.setNextWindowPos(.{ .x = x, .y = y });
    zgui.setNextWindowSize(.{ .w = width, .h = taskbar_h });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.r_pill });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 8, 4 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = theme.card });
    paint.pushFontSize(theme.f_small);
    if (zgui.begin("##system_taskbar", .{ .flags = flags })) {
        paint.softShadow(zgui.getWindowDrawList(), .{ x, y + 2 }, width, taskbar_h, theme.r_pill);
        for (items[0..visible_count], 0..) |item, i| {
            if (i > 0) zgui.sameLine(.{ .spacing = 8 });
            drawOpenButton(ctx, item.surface);
        }
        if (items.len == 0) {
            zgui.textColored(theme.dim, "暂无固定入口", .{});
        }
        if (overflowing) {
            if (visible_count > 0) zgui.sameLine(.{ .spacing = 8 });
            drawOverflow(ctx, items[visible_count..]);
        }
    }
    zgui.end();
    paint.popFontSize(theme.f_small);
    zgui.popStyleColor(.{});
    zgui.popStyleVar(.{ .count = 2 });
}

test "work area reserves taskbar and layout never goes negative" {
    const area = workArea(.{ 800, 600 });
    try std.testing.expectEqual(@as(f32, 800), area.w);
    try std.testing.expectEqual(@as(f32, 540), area.h);
    const small = layout(.{ 320, 200 });
    try std.testing.expect(small.content_w >= 0);
    try std.testing.expect(small.body_h >= 0);
    const wide = layout(.{ 2560, 1600 });
    try std.testing.expect(wide.content_w <= 1080);
    try std.testing.expect(wide.content_x >= wide.side_w);
    const without_sidebar = layoutFor(.{ 2560, 1600 }, false);
    try std.testing.expectEqual(@as(f32, 0), without_sidebar.side_w);
    try std.testing.expectEqual(@as(f32, 740), without_sidebar.content_x);
}

fn testOpen(_: *anyopaque) bool {
    return true;
}

fn testClose(_: *anyopaque) void {}

fn testDraw(_: *anyopaque) void {}

fn registerDummy(ctx: *RuntimeContext, ref: surfaces.SurfaceRef, title: [:0]const u8) bool {
    return ctx.surfaces.register(.{
        .owner_kind = ref.owner_kind,
        .id = ref.id,
        .title = title,
        .open = testOpen,
        .close = testClose,
        .draw = testDraw,
    });
}

test "taskbar merges pins and running surfaces without duplicates" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    const desktop = surfaces.SurfaceRef{ .owner_kind = .app, .id = "desktop" };
    const editor = surfaces.SurfaceRef{ .owner_kind = .app, .id = "editor" };
    const cli = surfaces.SurfaceRef{ .owner_kind = .console, .id = "cli" };
    try std.testing.expect(registerDummy(&ctx, desktop, "Desktop"));
    try std.testing.expect(registerDummy(&ctx, editor, "Editor"));
    try std.testing.expect(registerDummy(&ctx, cli, "CLI"));
    try std.testing.expect(ctx.session.pin(desktop));
    try std.testing.expect(ctx.session.pin(editor));
    try std.testing.expect(ctx.session.pin(cli));
    try std.testing.expect(ctx.surfaces.open(editor.owner_kind, editor.id));
    var buf: [32]TaskbarItem = undefined;
    var items = buildItems(&ctx, &buf);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[1].surface.is_open);
    try std.testing.expect(!items[0].surface.is_open);
    try std.testing.expect(registerDummy(&ctx, .{ .owner_kind = .app, .id = "other" }, "Other"));
    try std.testing.expect(ctx.surfaces.open(.app, "other"));
    items = buildItems(&ctx, &buf);
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[3].surface.is_open);
}

test "taskbar visual state separates running, workspace activity and input focus" {
    var ctx: RuntimeContext = undefined;
    ctx.init(std.testing.allocator);
    defer ctx.deinit();
    const editor = surfaces.SurfaceRef{ .owner_kind = .app, .id = "editor" };
    const cli = surfaces.SurfaceRef{ .owner_kind = .console, .id = "cli" };
    try std.testing.expect(registerDummy(&ctx, editor, "Editor"));
    try std.testing.expect(ctx.surfaces.register(.{
        .owner_kind = .console,
        .id = cli.id,
        .title = "CLI",
        .mode = .floating,
        .open = testOpen,
        .close = testClose,
        .draw = testDraw,
    }));
    try std.testing.expect(ctx.surfaces.open(editor.owner_kind, editor.id));
    try std.testing.expect(ctx.surfaces.open(cli.owner_kind, cli.id));
    const editor_visual = visualFor(&ctx, findSurface(&ctx, editor).?);
    try std.testing.expect(editor_visual.running);
    try std.testing.expect(editor_visual.workspace_active);
    try std.testing.expect(!editor_visual.focused);
    try std.testing.expect(!editor_visual.focus_outline);
    try std.testing.expectEqual(theme.hover_bg, editor_visual.background);
    const cli_visual = visualFor(&ctx, findSurface(&ctx, cli).?);
    try std.testing.expect(cli_visual.running);
    try std.testing.expect(!cli_visual.workspace_active);
    try std.testing.expect(cli_visual.focused);
    try std.testing.expect(cli_visual.focus_outline);
    try std.testing.expectEqual(theme.card, cli_visual.background);
    try std.testing.expectEqual(theme.accent, cli_visual.text);
    try std.testing.expect(ctx.surfaces.hide(cli.owner_kind, cli.id));
    const minimized_visual = visualFor(&ctx, findSurface(&ctx, cli).?);
    try std.testing.expect(minimized_visual.minimized);
    try std.testing.expect(minimized_visual.running_indicator);
    try std.testing.expectEqual(theme.caption, minimized_visual.text);
    try std.testing.expect(ctx.surfaces.close(cli.owner_kind, cli.id));
    const closed_visual = visualFor(&ctx, findSurface(&ctx, cli).?);
    try std.testing.expect(!closed_visual.running);
    try std.testing.expect(!closed_visual.running_indicator);
    try std.testing.expectEqual(theme.dim, closed_visual.text);
}
