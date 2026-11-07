//! shell.zig — 桌面应用的视图外壳:品牌、应用内页签与视图挂载
//!
//! 首页只显示真实最近启用;应用页显示注册表目录。系统任务栏与空工作区归
//! consoles/gui,桌面不拥有系统窗口管理权。

const std = @import("std");
const zgui = @import("zgui");
const w = @import("uikit").widgets;
const paint = @import("uikit").paint;
const theme = @import("uikit").theme;
const anim = @import("uikit").anim;
const n = @import("uikit").node;
const view = @import("view.zig");
const catalog = @import("catalog.zig");
const recent = @import("recent.zig");
const workspace = @import("system_workspace");
const RuntimeContext = @import("runtime").context.Context;

const titlebar_h: f32 = theme.bar_h;
var view_started: f32 = 0;

fn titleBar(width: f32, branded: bool) void {
    const dl = zgui.getWindowDrawList();
    if (branded) {
        dl.addRectFilledMultiColor(.{
            .pmin = .{ 0, 0 },
            .pmax = .{ width, titlebar_h },
            .col_upr_left = paint.pack(theme.bar_tl),
            .col_upr_right = paint.pack(theme.bar_tr),
            .col_bot_right = paint.pack(theme.bar_br),
            .col_bot_left = paint.pack(theme.bar_bl),
        });
        dl.addRectFilledMultiColor(.{
            .pmin = .{ 0, titlebar_h },
            .pmax = .{ width, titlebar_h + 4 },
            .col_upr_left = paint.pack(.{ 0, 0, 0, 0.18 }),
            .col_upr_right = paint.pack(.{ 0, 0, 0, 0.18 }),
            .col_bot_right = paint.pack(.{ 0, 0, 0, 0 }),
            .col_bot_left = paint.pack(.{ 0, 0, 0, 0 }),
        });
        dl.addLine(.{ .p1 = .{ 0, 1 }, .p2 = .{ width, 1 }, .col = paint.pack(theme.highlight) });
    } else {
        paint.metalSurface(dl, .{ 0, 0 }, width, titlebar_h, 0, theme.card_top, theme.card_bottom, theme.border_l);
    }
    const foreground = if (branded) theme.white else theme.text;
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = .{ 0, 0, 0, 0 } });
    if (zgui.beginChild("##titlebar", .{ .w = -1, .h = titlebar_h })) {
        const brand_size = if (branded) theme.f_brand else theme.f_title;
        zgui.setCursorPos(.{ 19, (titlebar_h - brand_size * 1.35) / 2 + 1.5 });
        paint.pushFontBold(brand_size);
        zgui.textColored(foreground, "Cutrans", .{});
        paint.popFontBold();

        const item_w: f32 = theme.nav_item_w;
        const nav_w = item_w * @as(f32, @floatFromInt(view.all().len));
        const nav_x = @max(0, (width - nav_w) / 2);
        zgui.setCursorPos(.{ nav_x, (titlebar_h - theme.nav_h) / 2 });
        for (view.all(), 0..) |item, i| {
            if (w.navPill(item.id, item.icon, item.label, i == view.currentIndex(), item_w - 12, branded)) {
                if (view.select(i)) view_started = anim.now();
            }
            zgui.sameLine(.{ .spacing = theme.g3 });
        }

        zgui.setCursorPos(.{ width - 48, (titlebar_h - theme.f_small * 1.35) / 2 });
        paint.pushFontSize(theme.f_small);
        zgui.textColored(if (branded) theme.warm else theme.dim, "◆", .{});
        paint.popFontSize(theme.f_small);
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
}

fn currentView() view.View {
    return view.current();
}

pub fn draw(ctx: *RuntimeContext) void {
    const configure_serial = ctx.surfaces.configurationSerial(.app, "desktop");
    const disp = zgui.io.getDisplaySize();
    const layout = workspace.layoutFor(disp, false);
    const main_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_focus_on_appearing = true,
        .no_bring_to_front_on_focus = true,
    };
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = disp[0], .h = disp[1] });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = theme.bg });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = theme.text });
    if (zgui.begin("##root", .{ .flags = main_flags })) {
        const def = currentView();
        const branded = std.mem.eql(u8, def.id, "home");
        const bgdl = zgui.getWindowDrawList();
        bgdl.addRectFilledMultiColor(.{
            .pmin = .{ 0, 0 },
            .pmax = .{ disp[0], disp[1] },
            .col_upr_left = paint.pack(if (branded) theme.card_top else theme.bg),
            .col_upr_right = paint.pack(if (branded) theme.bar_br else theme.bg),
            .col_bot_right = paint.pack(theme.bg),
            .col_bot_left = paint.pack(theme.bg),
        });
        titleBar(disp[0], branded);
        const trans_t = std.math.clamp((anim.now() - view_started) / (theme.view_ms / 1000), 0, 1);
        const trans_e = anim.easeAt(.{ .out_fluent = .strong }, trans_t);
        const rise = (1 - trans_e) * theme.view_rise;
        zgui.pushStyleVar1f(.{ .idx = .alpha, .v = trans_e });
        const body_flags = zgui.WindowFlags{ .no_collapse = true };
        if (zgui.beginChild("##body", .{ .w = -1, .h = layout.body_h, .window_flags = body_flags })) {
            zgui.setCursorPos(.{ layout.content_x, 0 });
            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = .{ 0, 0, 0, 0 } });
            if (zgui.beginChild("##content", .{ .w = layout.content_w, .h = -1, .window_flags = body_flags })) {
                var layout_ctx = n.Ctx{ .x = 0, .y = theme.g4 + rise, .width = layout.content_w, .runtime = ctx };
                if (std.mem.eql(u8, def.id, "apps")) {
                    catalog.draw(ctx, layout_ctx.x, layout_ctx.y, layout_ctx.width);
                } else if (std.mem.eql(u8, def.id, "home")) {
                    if (recent.draw(ctx, layout_ctx.x, layout_ctx.y, layout_ctx.width)) {
                        if (view.selectId("apps")) view_started = anim.now();
                    }
                } else {
                    _ = n.layout(&layout_ctx, def.content);
                }
            }
            zgui.endChild();
            zgui.popStyleColor(.{});
        }
        zgui.endChild();
        zgui.popStyleVar(.{});

        paint.pushFontSize(theme.f_small);
        const foot_y = titlebar_h + layout.body_h + 8;
        zgui.setCursorPos(.{ theme.g4, foot_y });
        zgui.textColored(theme.caption, "苏ICP备2026075632号", .{});
        paint.leftMargin(theme.g4);
        zgui.textColored(theme.caption, "{s}", .{ctx.status.get()});
        paint.popFontSize(theme.f_small);
    }
    zgui.end();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 2 });
    _ = ctx.surfaces.ackConfiguration(.app, "desktop", configure_serial);
}
