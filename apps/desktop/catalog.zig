//! catalog.zig — 桌面应用目录:Surface 注册表的实时投影

const std = @import("std");
const zgui = @import("zgui");
const surfaces = @import("runtime").surfaces;
const RuntimeContext = @import("runtime").context.Context;
const widgets = @import("uikit").widgets;
const theme = @import("uikit").theme;

fn refOf(surface: surfaces.Surface) surfaces.SurfaceRef {
    return .{ .owner_kind = surface.owner_kind, .id = surface.id };
}

pub fn stateInfo(surface: surfaces.Surface) [:0]const u8 {
    if (!surface.is_open) return "未运行";
    if (surface.is_minimized) return "已最小化";
    if (!surface.is_visible) return "后台运行";
    if (surface.focused) return "当前";
    return "运行中";
}

pub fn openSurface(ctx: *RuntimeContext, surface: surfaces.Surface) void {
    if (surface.owner_kind == .app) {
        _ = ctx.command.dispatch(.{ .name = "app.open", .arg = surface.id });
    } else {
        _ = ctx.command.dispatch(.{ .name = "console.open", .arg = surface.id });
    }
}

fn drawGroup(ctx: *RuntimeContext, title: [:0]const u8, items: []const surfaces.Surface, start_y: f32, width: f32) f32 {
    if (items.len == 0) return start_y;
    zgui.setCursorPos(.{ 16, start_y });
    zgui.textColored(theme.text, "{s}", .{title});
    var y = start_y + 28;
    for (items) |surface| {
        zgui.setCursorPos(.{ 16, y });
        var id_buf: [128]u8 = undefined;
        const owner = if (surface.owner_kind == .app) "app" else "console";
        const id = std.fmt.bufPrint(&id_buf, "{s}:{s}##desktop:catalog", .{ owner, surface.id }) catch continue;
        id_buf[id.len] = 0;
        const selected = surface.focused or ctx.surfaces.isActiveFull(surface.owner_kind, surface.id);
        if (widgets.listItem(id_buf[0..id.len :0], surface.icon, surface.title, stateInfo(surface), selected, @max(0, width - 32))) {
            openSurface(ctx, surface);
        }
        y += theme.list_double + theme.list_tail;
    }
    return y;
}

pub fn draw(ctx: *RuntimeContext, x: f32, y: f32, width: f32) void {
    var app_buf: [16]surfaces.Surface = undefined;
    var console_buf: [16]surfaces.Surface = undefined;
    var app_count: usize = 0;
    var console_count: usize = 0;
    for (ctx.surfaces.all()) |surface| {
        if (ctx.session.isShell(refOf(surface))) continue;
        if (surface.owner_kind == .app) {
            app_buf[app_count] = surface;
            app_count += 1;
        } else {
            console_buf[console_count] = surface;
            console_count += 1;
        }
    }
    const row_h = theme.list_double + theme.list_tail;
    const total = app_count + console_count;
    var groups: usize = 0;
    if (app_count > 0) groups += 1;
    if (console_count > 0) groups += 1;
    const content_h = if (total == 0) 64 else 16 + row_h * @as(f32, @floatFromInt(total)) + 28 * @as(f32, @floatFromInt(groups)) + 16;
    zgui.setCursorPos(.{ x, y });
    if (widgets.cardBegin("##desktop:catalog", width, content_h)) {
        var row_y: f32 = 16;
        row_y = drawGroup(ctx, "应用", app_buf[0..app_count], row_y, width);
        row_y = drawGroup(ctx, "操作台", console_buf[0..console_count], row_y, width);
        if (total == 0) {
            zgui.setCursorPos(.{ 16, 20 });
            zgui.textColored(theme.dim, "暂无可启动应用", .{});
        }
    }
    widgets.cardEnd();
}
