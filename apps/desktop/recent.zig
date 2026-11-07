//! recent.zig — 首页最近启用:真实 Surface 激活历史的轻量投影

const std = @import("std");
const zgui = @import("zgui");
const surfaces = @import("runtime").surfaces;
const RuntimeContext = @import("runtime").context.Context;
const catalog = @import("catalog.zig");
const widgets = @import("uikit").widgets;
const theme = @import("uikit").theme;

fn refOf(surface: surfaces.Surface) surfaces.SurfaceRef {
    return .{ .owner_kind = surface.owner_kind, .id = surface.id };
}

/// 返回 true 表示用户要求切换到应用目录,不是启动另一个应用。
pub fn draw(ctx: *RuntimeContext, x: f32, y: f32, width: f32) bool {
    var recent_buf: [16]surfaces.Surface = undefined;
    const all_recent = ctx.surfaces.recent(&recent_buf);
    var items: [4]surfaces.Surface = undefined;
    var count: usize = 0;
    for (all_recent) |surface| {
        if (ctx.session.isShell(refOf(surface))) continue;
        if (count == items.len) break;
        items[count] = surface;
        count += 1;
    }
    const row_h = theme.list_double + theme.list_tail;
    const rows = @max(count, 1);
    const content_h = 44 + row_h * @as(f32, @floatFromInt(rows)) + 52;
    var show_all = false;
    zgui.setCursorPos(.{ x, y });
    if (widgets.cardBegin("##desktop:recent", width, content_h)) {
        zgui.setCursorPos(.{ 16, 12 });
        zgui.textColored(theme.text, "最近启用", .{});
        if (count == 0) {
            zgui.setCursorPos(.{ 16, 44 });
            zgui.textColored(theme.dim, "暂无最近使用", .{});
        }
        for (items[0..count], 0..) |surface, i| {
            zgui.setCursorPos(.{ 16, 44 + row_h * @as(f32, @floatFromInt(i)) });
            var id_buf: [128]u8 = undefined;
            const owner = if (surface.owner_kind == .app) "app" else "console";
            const id = std.fmt.bufPrint(&id_buf, "{s}:{s}##desktop:recent", .{ owner, surface.id }) catch continue;
            id_buf[id.len] = 0;
            const selected = surface.focused or ctx.surfaces.isActiveFull(surface.owner_kind, surface.id);
            if (widgets.listItem(id_buf[0..id.len :0], surface.icon, surface.title, catalog.stateInfo(surface), selected, @max(0, width - 32))) {
                catalog.openSurface(ctx, surface);
            }
        }
        zgui.setCursorPos(.{ 16, 44 + row_h * @as(f32, @floatFromInt(rows)) + 8 });
        show_all = widgets.ghostButton("recent:show-all", "查看全部应用", @max(0, width - 32), 34);
    }
    widgets.cardEnd();
    return show_all;
}
